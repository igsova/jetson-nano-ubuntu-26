#!/usr/bin/env python3
"""Summarize the system calls of a probe run, and compare two runs' failed calls.

Usage: python3 -I strace_diff.py summary TRACE [--root PATH TAG]
       python3 -I strace_diff.py diff TRACE_A TRACE_B [--root PATH TAG] [--max N]

TRACE is the log probe-l4t-codec.sh writes with CODEC_STRACE=1 (strace -f -qq
-y -e trace=%file,ioctl,mmap). summary prints one STRACE line (calls, failed
calls by error, threads) and, if a thread died of a signal, a STRACE_SIGNAL
line and the last calls that thread made before it (STRACE_LAST, at most 20,
numbered back to 0, the last).

diff prints the calls that failed in A and never in B (STRACE_ONLY_FAILED,
with how often and the error) and the files A opened and B never did
(STRACE_ONLY_OPENED), at most N of each (default 40): run on the H.264
encoder's run against the H.265 one's, what the crashing encoder asked of the
system that the working one did not. The last line is STRACE_DIFF with the
counts.

A call is named by its system call and its target: the path for a file
call, the device and request for an ioctl or mmap. PATH (the scratch or
package folder) is shown as TAG, process numbers in /proc paths as N, and
the working folder is left out. Pure Python; changes nothing.
"""
import re
import sys
from collections import Counter, deque

LINE = re.compile(r'^(\d+)\s+(.*)$')
CALL = re.compile(r'^(\w+)\((.*)\)\s+=\s+(\S+)(?:\s+(E[A-Z0-9]+)\b)?')
QUOTED = re.compile(r'"((?:[^"\\]|\\.)*)"')
FD = re.compile(r'\b\d+<([^>]*)>')
LAST = 20


def target(name, args):
    """What the call is about: a path, or a device and request."""
    if name == 'ioctl':
        m = FD.match(args)
        device = m.group(1) if m else args.split(',', 1)[0]
        rest = args[m.end():] if m else args.split(',', 1)[-1]
        rest = rest.lstrip(', ')
        if rest.startswith('_IOC('):
            request = rest[:rest.find(')') + 1]
        else:
            request = rest.split(', ', 1)[0]
        return f'{device} {request}'
    m = QUOTED.search(args)
    if m:
        return m.group(1)
    m = FD.search(args)
    return m.group(1) if m else None


class Trace:
    def __init__(self, path, root=None):
        self.calls, self.failed, self.errors = 0, Counter(), Counter()
        self.opened, self.threads = set(), set()
        self.signal, self.before = None, []
        pending, recent = {}, {}

        def tidy(text):
            if root:
                text = text.replace(root[0], root[1])
            return re.sub(r'AT_FDCWD<[^>]*>', 'AT_FDCWD', re.sub(r'/proc/\d+/', '/proc/N/', text))

        with open(path, errors='replace') as f:
            for raw in f:
                m = LINE.match(raw.rstrip('\n'))
                if not m:
                    continue
                pid, rest = m.group(1), m.group(2)
                self.threads.add(pid)
                if rest.startswith('<... '):
                    rest = pending.pop(pid, '') + rest[rest.find('>') + 1:]
                elif rest.endswith('<unfinished ...>'):
                    pending[pid] = rest[:-len('<unfinished ...>')].rstrip()
                    continue
                if rest.startswith('--- SIG'):
                    if self.signal is None:
                        self.signal = (pid, rest.strip('- '))
                        self.before = list(recent.get(pid, ()))
                    continue
                call = CALL.match(rest)
                if not call:
                    continue
                name, args, ret, errno = call.groups()
                self.calls += 1
                what = target(name, args)
                shown = tidy(f'{name} {what}' if what else name)
                recent.setdefault(pid, deque(maxlen=LAST)).append(tidy(f'{rest[:220]}'))
                if ret == '-1' and errno:
                    self.errors[errno] += 1
                    self.failed[(shown, errno)] += 1
                elif name in ('open', 'openat', 'openat2') and what and ret.isdigit():
                    self.opened.add(tidy(what))

    def failed_keys(self):
        return {key for key, _ in self.failed}


def options(argv):
    args, root, most = [], None, 40
    i = 0
    while i < len(argv):
        if argv[i] == '--root' and i + 2 < len(argv):
            root, i = (argv[i + 1].rstrip('/'), argv[i + 2]), i + 3
        elif argv[i] == '--max' and i + 1 < len(argv):
            most, i = int(argv[i + 1]), i + 2
        else:
            args.append(argv[i])
            i += 1
    return args, root, most


def main(argv):
    args, root, most = options(argv)
    if len(args) == 2 and args[0] == 'summary':
        t = Trace(args[1], root)
        errors = ','.join(f'{e}:{n}' for e, n in t.errors.most_common(6)) or '-'
        print(f'STRACE calls={t.calls} failed={sum(t.errors.values())} errors={errors} threads={len(t.threads)}')
        if t.signal:
            print(f'STRACE_SIGNAL thread={t.signal[0]} {t.signal[1]}')
            for i, call in enumerate(t.before, 1 - len(t.before)):
                print(f'STRACE_LAST {i} {call}')
        return 0
    if len(args) == 3 and args[0] == 'diff':
        a, b = Trace(args[1], root), Trace(args[2], root)
        only = sorted((key for key in a.failed if key[0] not in {k for k, _ in b.failed}),
                      key=lambda key: (-a.failed[key], key))
        for shown, errno in only[:most]:
            print(f'STRACE_ONLY_FAILED {a.failed[(shown, errno)]}x {errno} {shown}')
        opened = sorted(a.opened - b.opened)
        for path in opened[:most]:
            print(f'STRACE_ONLY_OPENED {path}')
        print(f'STRACE_DIFF only_failed={len(only)} only_opened={len(opened)} calls={a.calls}/{b.calls}')
        return 0
    print(__doc__.split('\n\n')[0], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

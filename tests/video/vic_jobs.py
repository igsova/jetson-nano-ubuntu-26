#!/usr/bin/env python3
"""Read the VIC jobs vic_record.c recorded, and compare two converters' jobs.

Usage: python3 -I vic_jobs.py show DIR [--methods]
       python3 -I vic_jobs.py compare DIR_A DIR_B [--pair A:B ...] [--max N]
       python3 -I vic_jobs.py words DIR JOB METHOD

DIR is one case's folder of records (probe-l4t-video.sh's
vic-jobs/<case>). Each job's command buffers are decoded as host1x commands:
writes to VIC's method registers (0x10 takes a method's offset divided by
four, 0x11 its value) give the job's methods in order. A method whose value
the kernel relocates, or whose value shifted left by 8 falls in a buffer
mapped to the channel, points at a buffer: VIC's settings block, its filter
coefficients, a picture and the like. Its region of the buffer runs from
there to the next region another method points at in the same buffer, or
to the buffer's end.

show prints one JOB line a job: its class, method and buffer counts and a
signature of its method offsets (two jobs with the same signature set the
same methods); with --methods every method follows, with its buffer's size,
a SHA-256 prefix and its count of non-zero words.

compare pairs job I of DIR_A with job I of DIR_B (or as --pair gives, with
the jobs' 1-based places), and for each pair prints the methods whose
values differ, the methods only one sets, and for each buffer both point at
with the same method, the 32-bit words that differ (at most N a buffer,
default 48), with their byte offsets in the region, over the shorter
region's length. Addresses are not compared, only what they point at;
buffers too large to have been read (pictures) only by size. A pair with
the same differences as an earlier one is named, not repeated.

words prints every non-zero 32-bit word of the region METHOD (hex, such as
0x708) points at in job JOB (its place, 1-based), with its byte offset.

Method names are given where the kernel (flcn.h) or libdrm's VIC 4.0 test
header (tests/tegra/vic40.h) names them; other methods are shown by offset.
Settings fields are not named. Pure Python.
"""
import hashlib
import re
import struct
import sys
from pathlib import Path

METHOD_OFFSET, METHOD_DATA = 0x10, 0x11  # FLCN_UCLASS_METHOD_OFFSET and _DATA
NAMES = {0x200: 'SET_APPLICATION_ID', 0x300: 'EXECUTE', 0x400: 'SET_SURFACE0_SLOT0_LUMA_OFFSET',
         0x404: 'SET_SURFACE0_SLOT0_CHROMA_U_OFFSET', 0x408: 'SET_SURFACE0_SLOT0_CHROMA_V_OFFSET',
         0x704: 'SET_CONTROL_PARAMS', 0x708: 'SET_CONFIG_STRUCT_OFFSET', 0x714: 'SET_HIST_OFFSET',
         0x71c: 'SET_FCE_UCODE_SIZE', 0x720: 'SET_OUTPUT_SURFACE_LUMA_OFFSET', 0x72c: 'SET_FCE_UCODE_OFFSET'}
FIELD = re.compile(r'(\w+)=(\S+)')


def fields(line):
    return dict(FIELD.findall(line))


def number(text):
    return int(text, 0) if text not in ('-', None) else None


class Job:
    def __init__(self, path):
        self.path, self.name = path, path.name
        self.submit, self.cmdbufs, self.relocs, self.buffers = {}, [], [], {}
        for line in (path / 'submit.txt').read_text().splitlines():
            kind, _, rest = line.partition(' ')
            f = fields(rest)
            if kind == 'SUBMIT':
                self.submit = f
            elif kind == 'CMDBUF':
                self.cmdbufs.append(f)
            elif kind == 'RELOC':
                self.relocs.append(f)
            elif kind == 'BUFFER':
                data = None
                if f['dumped'] not in ('no',) and (path / f['dumped']).is_file():
                    data = (path / f['dumped']).read_bytes()
                self.buffers[int(f['ino'])] = {'size': number(f['size']), 'iova': number(f['iova']),
                                               'data': data, 'why': rest.split('dumped=', 1)[1]}
        self.notes, self.methods = [], []
        for c in self.cmdbufs:
            file = path / c['read'] if c['read'] != 'no' else None
            if not file or not file.is_file():
                self.notes.append(f"command buffer {c['mem']} not read")
                continue
            words = struct.unpack(f'<{file.stat().st_size // 4}I', file.read_bytes())
            self.decode(words, int(c['mem']), int(c['offset'], 0))
        self.point()

    def decode(self, words, mem, base):
        """Register writes of one command buffer, then its VIC methods in order."""
        writes, i = [], 0

        def take(register, place):
            if place < len(words):
                writes.append((register, words[place], base + 4 * place))

        while i < len(words):
            w, op = words[i], words[i] >> 28
            offset = (w >> 16) & 0xfff
            if op == 0:  # SETCLASS: class, and the registers its mask names
                self.submit.setdefault('class', hex((w >> 6) & 0x3ff))
                i += 1
                for bit in range(6):
                    if w >> bit & 1:
                        take(offset + bit, i)
                        i += 1
            elif op in (1, 2):  # INCR, NONINCR
                count = w & 0xffff
                for k in range(count):
                    take(offset + (k if op == 1 else 0), i + 1 + k)
                i += 1 + count
            elif op == 3:  # MASK
                i += 1
                for bit in range(16):
                    if w >> bit & 1:
                        take(offset + bit, i)
                        i += 1
            elif op == 4:  # IMM
                writes.append((offset, w & 0xffff, None))
                i += 1
            elif op == 6:  # GATHER: its words are elsewhere
                self.notes.append(f'GATHER of {w & 0x3fff} words at word {i} (not followed)')
                i += 2
            elif op == 14:  # EXTEND (module lock)
                i += 1
            else:
                self.notes.append(f'opcode {op} at word {i}')
                i += 1
        method = None
        for register, value, at in writes:
            if register == METHOD_OFFSET:
                method = value << 2
            elif register == METHOD_DATA and method is not None:
                self.methods.append({'method': method, 'value': value, 'mem': mem, 'at': at})

    def point(self):
        """Which methods point at a buffer, and the region each one starts."""
        relocs = {(int(r['cmdbuf_mem']), int(r['cmdbuf_offset'], 0)): r for r in self.relocs}
        mapped = [(b['iova'], b['iova'] + (b['size'] or 0), ino) for ino, b in self.buffers.items() if b['iova']]
        for m in self.methods:
            r = relocs.get((m['mem'], m['at']))
            if r:
                m['buffer'], m['start'] = int(r['target_ino']), int(r['target_offset'], 0)
                continue
            address = m['value'] << 8
            for low, high, ino in mapped:
                if low <= address < high:
                    m['buffer'], m['start'] = ino, address - low
        starts = {}
        for m in self.methods:
            if 'buffer' in m:
                starts.setdefault(m['buffer'], set()).add(m['start'])
        for m in self.methods:
            if 'buffer' not in m:
                continue
            b = self.buffers.get(m['buffer'], {})
            later = [s for s in starts[m['buffer']] if s > m['start']]
            m['end'] = min(later) if later else (b.get('size') or m['start'])

    def region(self, m):
        b = self.buffers.get(m.get('buffer'), {})
        if b.get('data') is None:
            return None
        return b['data'][m['start']:m['end']]

    def describe(self, m):
        if 'buffer' not in m:
            return f"0x{m['value']:08x}"
        b = self.buffers.get(m['buffer'], {})
        data = self.region(m)
        if data is None:
            return f"-> buffer ino {m['buffer']} +0x{m['start']:x} ({b.get('size')} bytes; {b.get('why', 'not listed')})"
        nonzero = sum(1 for w in words(data) if w)
        return (f"-> buffer ino {m['buffer']} +0x{m['start']:x} (region {len(data)} bytes, "
                f"sha256 {hashlib.sha256(data).hexdigest()[:12]}, non-zero words {nonzero})")

    def signature(self):
        return hashlib.sha256(' '.join(f"{m['method']:x}" for m in self.methods).encode()).hexdigest()[:8]


def words(data):
    usable = len(data) // 4 * 4
    return struct.unpack(f'<{usable // 4}I', data[:usable])


def label(method):
    return f'0x{method:04x}' + (f' {NAMES[method]}' if method in NAMES else '')


def load(folder):
    folder = Path(folder)
    jobs = [Job(p) for p in sorted(folder.glob('p*-j*')) if (p / 'submit.txt').is_file()]
    requests = []
    for file in sorted(folder.glob('p*-requests.txt')):
        requests += [fields(line) for line in file.read_text().splitlines() if line.startswith('REQUEST')]
    return jobs, requests


def header(folder, jobs, requests):
    vic = [r for r in requests if 'vic' in r['dev']]
    kinds = ' '.join(f"nr{r['nr']}x{r['calls']}" + (f"!{r['failed']}" if r['failed'] != '0' else '')
                     for r in vic)
    print(f'JOBS {folder}: {len(jobs)} recorded; VIC channel requests (nr x calls, !failed): {kinds or "none"}')
    if not jobs:  # where the converter's requests went instead
        for r in requests:
            print(f"  REQUEST dev={r['dev']} type={r['type']} nr={r['nr']} size={r['size']} calls={r['calls']} "
                  f"failed={r['failed']}")


def show(argv):
    full = '--methods' in argv
    folder = [a for a in argv if a != '--methods'][0]
    jobs, requests = load(folder)
    header(folder, jobs, requests)
    for job in jobs:
        pointing = sum(1 for m in job.methods if 'buffer' in m)
        dumped = sum(1 for b in job.buffers.values() if b['data'] is not None)
        print(f"JOB {job.name} class={job.submit.get('class', '-')} cmdbufs={len(job.cmdbufs)} "
              f"relocs={len(job.relocs)} methods={len(job.methods)} pointing={pointing} "
              f"buffers={dumped}/{len(job.buffers)} dumped signature={job.signature()}")
        for note in job.notes:
            print(f'  NOTE {note}')
        if full:
            for m in job.methods:
                print(f"  METHOD {label(m['method'])} {job.describe(m)}")
    return 0


def keyed(job):
    """Methods by (offset, occurrence), so a method set twice pairs in order."""
    seen, out = {}, {}
    for m in job.methods:
        n = seen[m['method']] = seen.get(m['method'], 0) + 1
        out[(m['method'], n)] = m
    return out


def compare(argv):
    limit, pairs, rest = 48, [], []
    args = iter(argv)
    for a in args:
        if a == '--max':
            limit = int(next(args))
        elif a == '--pair':
            left, right = next(args).split(':')
            pairs.append((int(left) - 1, int(right) - 1))
        else:
            rest.append(a)
    if len(rest) != 2:
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    (jobs_a, req_a), (jobs_b, req_b) = load(rest[0]), load(rest[1])
    header('A ' + rest[0], jobs_a, req_a)
    header('B ' + rest[1], jobs_b, req_b)
    for name, jobs in (('A', jobs_a), ('B', jobs_b)):
        print(f'{name}_SIGNATURES ' + ' '.join(f'{i + 1}:{j.signature()}' for i, j in enumerate(jobs)))
    if not pairs:
        pairs = [(i, i) for i in range(min(len(jobs_a), len(jobs_b)))]
    seen = {}
    for ia, ib in pairs:
        if not (0 <= ia < len(jobs_a) and 0 <= ib < len(jobs_b)):
            print(f'PAIR {ia + 1}:{ib + 1} skipped (no such job)')
            continue
        a, b = jobs_a[ia], jobs_b[ib]
        ka, kb = keyed(a), keyed(b)
        same = sum(1 for k in ka if k in kb and 'buffer' not in ka[k] and 'buffer' not in kb[k]
                   and ka[k]['value'] == kb[k]['value'])
        lines = []
        for k in sorted(set(ka) | set(kb)):
            ma, mb = ka.get(k), kb.get(k)
            if not mb:
                lines.append(f'  ONLY_A {label(k[0])} {a.describe(ma)}')
            elif not ma:
                lines.append(f'  ONLY_B {label(k[0])} {b.describe(mb)}')
            elif ('buffer' in ma) != ('buffer' in mb):
                lines.append(f'  METHOD {label(k[0])} A {a.describe(ma)} B {b.describe(mb)}')
            elif 'buffer' not in ma:
                if ma['value'] != mb['value']:
                    lines.append(f"  METHOD {label(k[0])} A=0x{ma['value']:08x} B=0x{mb['value']:08x}")
            else:
                lines += diff_regions(label(k[0]), a, ma, b, mb, limit)
        head = (f'PAIR A {ia + 1} ({a.name}) with B {ib + 1} ({b.name}): methods A={len(a.methods)} '
                f'B={len(b.methods)} same_values={same}')
        key = '\n'.join(lines)
        if not lines:
            print(head + ': no differences')
            continue
        if key in seen:
            print(f'{head}: the same differences as pair {seen[key]}')
            continue
        seen[key] = f'{ia + 1}:{ib + 1}'
        print(head)
        print(key)
    return 0


def diff_regions(name, a, ma, b, mb, limit):
    """The differing words of the regions two methods point at, over their common length."""
    ra, rb = a.region(ma), b.region(mb)
    if ra is None and rb is None:  # pictures: only their sizes
        sa, sb = (j.buffers.get(m['buffer'], {}).get('size') for j, m in ((a, ma), (b, mb)))
        return [] if sa == sb else [f'  BUFFER {name} sizes A={sa} B={sb} (not read)']
    if ra is None or rb is None:
        return [f'  BUFFER {name} not compared: A {a.describe(ma)} B {b.describe(mb)}']
    wa, wb = words(ra), words(rb)
    common = min(len(wa), len(wb))
    differ = [i for i in range(common) if wa[i] != wb[i]]
    if not differ and len(ra) == len(rb):
        return []
    lines = [f'  BUFFER {name} region A={len(ra)} B={len(rb)} bytes: words differ={len(differ)} of {common}'
             + ('' if len(ra) == len(rb) else ' compared (the shorter region\'s length)')]
    lines += [f'    +0x{4 * i:04x} A=0x{wa[i]:08x} B=0x{wb[i]:08x}' for i in differ[:limit]]
    if len(differ) > limit:
        lines.append(f'    ({len(differ) - limit} more)')
    return lines


def dump_words(argv):
    folder, place, method = argv[0], int(argv[1]), int(argv[2], 0)
    jobs, _ = load(folder)
    job = jobs[place - 1]
    for m in job.methods:
        if m['method'] == method and 'buffer' in m:
            data = job.region(m)
            print(f"WORDS {job.name} {label(method)} {job.describe(m)}")
            if data is not None:
                for i, w in enumerate(words(data)):
                    if w:
                        print(f'  +0x{4 * i:04x} 0x{w:08x}')
            return 0
    print(f'no buffer for method {label(method)} in {job.name}', file=sys.stderr)
    return 1


def main(argv):
    commands = {'show': (show, 1), 'compare': (compare, 2), 'words': (dump_words, 3)}
    if not argv or argv[0] not in commands or len(argv) - 1 < commands[argv[0]][1]:
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    return commands[argv[0]][0](argv[1:])


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

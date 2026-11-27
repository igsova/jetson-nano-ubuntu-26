#!/usr/bin/env python3
"""Package CUDA 12 for the Nano beside CUDA 11.4: NVIDIA's CUDA 12.2 driver for
JetPack 5, CUDA 12.6's libraries and compiler, and cuDNN 9.

Usage: python3 scripts/host/build-nano-cuda12-debs.py --key jetson-ota-public.asc
           [--reuse DIR ...] [--mirror DIR] OUT_DIR

On the Nano's 5.10 kernel, NVIDIA's CUDA upgrade driver for JetPack 5
(cuda-compat-12-2) runs CUDA 12.2, and on it JetPack 6's CUDA 12.6 runtime,
cuBLAS and cuDNN 9.3 gave exact results (2026-10-17). This downloads, checked as fetch-cuda12-probe.py checks them
(both indexes signed, the CUDA repository's key pinned, each .deb against
its index; a .deb in a --reuse folder is copied when it matches):
- cuda-compat-12-2 from NVIDIA's CUDA repository for Jetson;
- from JetPack 6's signed common r36.4 index, for the newest CUDA 12 there
  (12.6): the packages NVIDIA's cuda-libraries-12-6 (the runtime set),
  cuda-compiler-12-6 and cuda-libraries-dev-12-6 depend on, and cuDNN 9
  (libcudnn9-cuda-12, libcudnn9-dev-cuda-12), with what those depend on in
  that index, except the packages NOT_TAKEN names;
and builds two packages from their files:
- nano-cuda12: the 12.2 driver in /usr/local/cuda-12.2/compat, CUDA 12.6's
  runtime libraries and cuDNN 9's in /usr/local/cuda-12.6/targets/
  aarch64-linux/lib, and /usr/bin/nano-cuda12, which runs a program with
  both first in the library path;
- nano-cuda12-dev: CUDA 12.6's compiler and tools, the headers and link
  names of its libraries and of cuDNN 9, and only the static libraries
  nvcc itself links (KEEP_ARCHIVES).
Nothing enters the system's library path and /usr/local/cuda stays CUDA
11.4's: NVIDIA's config-common packages (update-alternatives for
/usr/local/cuda, /etc/ld.so.conf.d entries) are not taken, files under /etc
and the pkg-config files for /usr/lib/pkgconfig (cublas-12.6.pc and the
like) are left out, and none of NVIDIA's maintainer scripts is kept; the
packages have none. cuDNN 9's files move from Ubuntu's library and include
folders into CUDA 12.6's, its headers without their _v9 suffix, the names
they include each other by.

Two changes let nvcc 12.6 compile on Ubuntu 26.04's glibc 2.43, as CUDA
11.4's nvcc needed on the Nano (2026-10-15):
crt/math_functions.h declares sinpi, cospi, rsqrt and their float forms
noexcept, as glibc 2.41 and later declare them; and nano-glibc/bits/
math-vector.h, put on nvcc's include path by a line added to bin/
nvcc.profile, hides glibc's AArch64 vector math declarations from nvcc's
compiles, since they use GCC builtin types CUDA's front end may not know.
Compiling with -DNANO_CUDA12_ORIGINAL_MATH or -DNANO_CUDA12_GLIBC_VECTOR_MATH
turns each off, which check-nano-cuda12.sh uses to see whether each is
needed.

--mirror DIR reads both repositories from a copy of them in DIR, laid out as
the servers are (DIR/repo.download.nvidia.com/jetson/...), as nano26-convert
saves them on a new card for its stage 2; every check is the same.

OUT_DIR (created; must be empty) receives sources/, the .debs downloaded
(for --reuse in a later build); report.txt, each ELF file's SONAME, NEEDED
and newest glibc version; maintainer.txt, the source packages'
relationships and the maintainer scripts left out; packages.json; and
nano/, the folder for the Nano: the two .debs, nano-cuda12-files.txt (each
file with its SHA-256), the diffs of the two changed NVIDIA files,
install-nano-cuda12.sh and check-nano-cuda12.sh with their test files, and
SHA256SUMS. The .debs reach nano/ only once every check has passed. A file
in an unknown folder (UNEXPECTED), a link to nothing (BROKEN_LINK) and a
library not found (UNRESOLVED) are reported together before the build stops;
pass the failed build's sources/ to the next one with --reuse.

Runs as an ordinary user; needs gpg, gpgv and dpkg-deb, and about 12 GB free
in OUT_DIR. NVIDIA's files stay in OUT_DIR and never go into git.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
_spec = importlib.util.spec_from_file_location('fetch_cuda12_probe', HERE / 'fetch-cuda12-probe.py')
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)
fetch = probe.fetch

R36_RELEASE = 'r36.4'
REVISION = '+u26.1'
ARCH = 'arm64'
TARGET = 'targets/aarch64-linux'
COMPAT = 'cuda-compat-12-2'
COMPAT_DIR = 'usr/local/cuda-12.2/compat/'
# Dependency groups (first alternative in the index); {m} is CUDA 12's minor version.
RUNTIME_ROOTS = ['cuda-libraries-12-{m}', 'libcudnn9-cuda-12']
DEV_ROOTS = ['cuda-compiler-12-{m} | cuda-nvcc-12-{m}', 'cuda-libraries-dev-12-{m} | cuda-cudart-dev-12-{m}',
             'libcudnn9-dev-cuda-12']
NOT_TAKEN = [
    (r'cuda-toolkit(-12(-\d+)?)?-config-common',
     'points /usr/local/cuda and the library path at CUDA 12 (update-alternatives, /etc/ld.so.conf.d)'),
    (r'libcudla(-dev)?-12-\d+', "Orin's deep learning accelerator; the Nano has none"),
    (r'libcufile(-dev)?-12-\d+', 'GPUDirect Storage, which needs the nvidia-fs kernel module'),
    (r'.*-static(-.*)?', 'static libraries only'),
]
# The static libraries nvcc links by itself (the runtime by default, device-side
# runtime with -rdc) and the name demangler's; the others (several GB) are left out.
KEEP_ARCHIVES = {'libcudart_static.a', 'libcudadevrt.a', 'libculibos.a', 'libcufilt.a'}
# glibc 2.41 (sinpi, cospi) and 2.42 (rsqrt) declare these noexcept; CUDA 11.4's
# extern declarations of all six clashed with glibc 2.43 on the Nano (2026-10-15).
NOEXCEPT = ['sinpi', 'sinpif', 'cospi', 'cospif', 'rsqrt', 'rsqrtf']
UBUNTU_LIBS = {  # library: Ubuntu 26.04 package
    'libc.so.6': 'libc6', 'libm.so.6': 'libc6', 'libdl.so.2': 'libc6', 'libpthread.so.0': 'libc6',
    'librt.so.1': 'libc6', 'libutil.so.1': 'libc6', 'libresolv.so.2': 'libc6',
    'ld-linux-aarch64.so.1': 'libc6', 'libstdc++.so.6': 'libstdc++6', 'libgcc_s.so.1': 'libgcc-s1',
    'libatomic.so.1': 'libatomic1', 'libz.so.1': 'zlib1g',
}
GLIBC = (2, 43)  # Ubuntu 26.04's
# JetPack 5's GPU libraries (libnvrm_gpu and the like), which the 12.2 driver
# (and only it) loads from the installed nano-l4t R35.6 set, as in the probe.
DRIVER_SET = re.compile(r'libnv[A-Za-z0-9_]*\.so(\.[0-9]+)*$')
DRIVER_DEPENDS = 'nano-l4t-core (>= 35.6), nano-l4t-core (<< 35.7)'
NEED_FREE = 12 * 1024 ** 3
NANO_FILES = [REPO / 'scripts/jetson/install-nano-cuda12.sh', REPO / 'scripts/jetson/check-nano-cuda12.sh',
              REPO / 'tests/cuda/cuda11_probe.py', REPO / 'tests/cuda/cuda_libs_probe.py',
              REPO / 'tests/cuda/vector_add.cu', REPO / 'tests/cuda/gpu_probe.cu',
              REPO / 'tests/cuda/cuda12_dev_check.cu']

LAUNCHER = """\
#!/bin/sh
# Run a program with CUDA 12 from nano-cuda12: NVIDIA's CUDA 12.2 driver for
# JetPack 5 (cuda-compat-12-2, in /usr/local/cuda-12.2/compat), which runs on
# the installed JetPack 5 GPU libraries, and CUDA {minor}'s libraries with
# cuDNN 9 (in {cuda}).
# They stay out of the system's library path, so programs started any other
# way keep CUDA 11.4. CUDA {minor}'s compiler (nano-cuda12-dev) is first in
# the path here too. For example:
#   nano-cuda12 nvcc -ccbin g++-11 -arch=sm_53 -o vector_add vector_add.cu
#   nano-cuda12 ./vector_add
# The driver is CUDA 12.2's: a program needs sm_53 machine code, or PTX no
# newer than CUDA 12.2 makes, and features that need a newer driver fail.
cuda={cuda}
if [ $# -eq 0 ]; then
    echo 'usage: nano-cuda12 PROGRAM [ARGUMENT...]' >&2
    exit 2
fi
LD_LIBRARY_PATH=/{compat}:$cuda/{target}/lib${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}
PATH=$cuda/bin${{PATH:+:$PATH}}
CUDA_HOME=$cuda
export LD_LIBRARY_PATH PATH CUDA_HOME
exec "$@"
"""

NOEXCEPT_HEADER = """\
/* nano-cuda12-dev: glibc 2.41 and later declare sinpi, cospi, rsqrt and their
   float forms noexcept, and g++ rejects this header's declarations of them
   without it. Compile with -DNANO_CUDA12_ORIGINAL_MATH for NVIDIA's original
   declarations. */
#if !defined(__NANO_GLIBC_NOEXCEPT)
#if defined(__cplusplus) && !defined(NANO_CUDA12_ORIGINAL_MATH)
#define __NANO_GLIBC_NOEXCEPT noexcept (true)
#else
#define __NANO_GLIBC_NOEXCEPT
#endif
#endif
"""

MATH_VECTOR = """\
/* nano-cuda12-dev: glibc 2.38 and later declare AArch64 vector math functions
   (libmvec) in <bits/math-vector.h> with GCC builtin vector types such as
   __Float32x4_t and __SVFloat32_t, which CUDA's front end may not know (CUDA
   11.4's did not, with glibc 2.43 on the Nano). nvcc finds this file first
   (a line in its nvcc.profile) and, while it compiles CUDA code, reads
   glibc's header as though GCC were older than 9, which leaves those
   declarations out; device code never calls them. Compile with
   -DNANO_CUDA12_GLIBC_VECTOR_MATH to read glibc's header unchanged. */
#if defined __CUDACC__ && !defined NANO_CUDA12_GLIBC_VECTOR_MATH
# undef __GNUC_PREREQ
# define __GNUC_PREREQ(maj, min) 0
# include_next <bits/math-vector.h>
/* As glibc's <features.h> defines it. */
# undef __GNUC_PREREQ
# if defined __GNUC__ && defined __GNUC_MINOR__
#  define __GNUC_PREREQ(maj, min) \\
	((__GNUC__ << 16) + __GNUC_MINOR__ >= ((maj) << 16) + (min))
# else
#  define __GNUC_PREREQ(maj, min) 0
# endif
#else
# include_next <bits/math-vector.h>
#endif
"""
PROFILE_LINE = 'INCLUDES        +=  "-I$(TOP)/nano-glibc" $(_SPACE_)'


def fail(message):
    raise SystemExit('NANO_CUDA12_DEBS=FAIL: ' + message)


probe.fail = fetch.fail = fail  # also for the index and download checks they make


def excluded(name):
    for pattern, reason in NOT_TAKEN:
        if re.fullmatch(pattern, name):
            return reason
    return None


def closure(entries, roots, taken, not_taken, outside):
    """The packages ROOTS reach through Pre-Depends and Depends in the index, in
    order, leaving out those in TAKEN and those NOT_TAKEN names (noted in
    not_taken). Dependencies the index cannot meet are noted in OUTSIDE."""
    order, queue = [], [(group, None) for group in roots]
    while queue:
        group, parent = queue.pop(0)
        name = fetch.resolve(entries, group)
        if name is None:
            if parent is None:
                fail(f'nothing in the common {R36_RELEASE} index meets {group}')
            outside.setdefault(group.strip(), set()).add(parent)
            continue
        if name in taken or name in order:
            continue
        reason = excluded(name)
        if reason:
            not_taken.setdefault(name, reason)
            continue
        entry = fetch.newest(entries, name, 'common')
        order.append(name)
        for field in ('Pre-Depends', 'Depends'):
            queue += [(g, name) for g in entry.get(field, '').split(',') if g.strip()]
    return order


def destination(source, rel, cuda):
    """Where a file at REL in SOURCE's .deb goes: (path, None), or (None, reason)
    to leave it out, or ('doc', rest) for a file of its doc folder."""
    base = posixpath.basename(rel)
    if base.endswith('.a') and base not in KEEP_ARCHIVES:
        return None, 'static'
    if rel.startswith('usr/share/doc/'):
        return 'doc', rel.split('/', 4)[-1] if rel.count('/') >= 4 else base
    if rel.startswith('etc/'):
        return None, 'etc'
    if rel.startswith('usr/share/lintian/'):
        return None, 'lintian'
    if re.fullmatch(r'usr/lib/pkgconfig/[\w.+-]+-' + re.escape(cuda.rsplit('-', 1)[1]) + r'[.]pc', rel):
        return None, 'pkgconfig'  # in the system's pkg-config path; nothing here builds with them
    if source == COMPAT:
        if rel.startswith(COMPAT_DIR):
            return rel, None
    elif rel.startswith(cuda + '/'):
        return rel, None
    if source.startswith('libcudnn9'):
        if rel.startswith('usr/lib/aarch64-linux-gnu/') and rel.count('/') == 3 and base.startswith('libcudnn'):
            return f'{cuda}/{TARGET}/lib/{base}', None
        if rel.startswith('usr/include/') and re.fullmatch(r'cudnn\w*\.h', base):
            return f'{cuda}/{TARGET}/include/{re.sub(r"_v9[.]h$", ".h", base)}', None
    return None, 'unexpected'


class Stage:
    """The two packages' file trees, filled from the source .debs as they stream."""

    def __init__(self, work, cuda):
        self.work, self.cuda = work, cuda
        self.files = {}  # path: {package, kind ('file'|'link'), sha256 or target, size, mode, source}
        self.dropped = {}  # reason: [count, bytes, examples]
        self.epoch = 0

    def root(self, package):
        return self.work / 'stage' / package

    def drop(self, reason, rel, size=0):
        entry = self.dropped.setdefault(reason, [0, 0, []])
        entry[0] += 1
        entry[1] += size
        if len(entry[2]) < 12 or reason == 'unexpected':
            entry[2].append(rel)

    def place(self, package, dest, source, member, stream=None, data=None):
        existing = self.files.get(dest)
        root = self.root(package)
        path = root / dest
        for parent in Path(dest).parents:
            if parent != Path('.') and str(parent) in self.files:
                fail(f'{source}: {dest} lies under {parent}, which a package holds as a file or link')
        if member is not None and member.issym():
            if member.linkname.startswith('/'):
                self.drop('absolute link', f'{source}: /{dest} -> {member.linkname}')
                return
            record = {'package': package, 'kind': 'link', 'target': member.linkname, 'source': source}
            if existing:
                if existing['kind'] == 'link' and existing['target'] == member.linkname:
                    return
                fail(f'{source} and {existing["source"]} both hold /{dest}, differently')
            path.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(member.linkname, path)
            self.files[dest] = record
            return
        digest = hashlib.sha256()
        if existing:  # compare without keeping a second copy
            for block in iter(lambda: stream.read(1 << 20), b'') if stream else [data]:
                digest.update(block)
            if existing['kind'] == 'file' and existing['sha256'] == digest.hexdigest():
                return
            fail(f'{source} and {existing["source"]} both hold /{dest}, differently')
        path.parent.mkdir(parents=True, exist_ok=True)
        size = 0
        with open(path, 'wb') as out:
            for block in iter(lambda: stream.read(1 << 20), b'') if stream else [data]:
                digest.update(block)
                out.write(block)
                size += len(block)
        mode = (member.mode if member is not None else 0o644) & 0o755 | 0o644
        os.chmod(path, mode)
        self.files[dest] = {'package': package, 'kind': 'file', 'sha256': digest.hexdigest(), 'size': size,
                            'mode': mode, 'source': source}

    def take(self, source, deb, package):
        """Stream SOURCE's .deb DEB into PACKAGE's tree."""
        tar = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(deb)], stdout=subprocess.PIPE)
        kept, placed = 0, {}  # placed: the .deb's path of each file kept: where it went
        with tarfile.open(fileobj=tar.stdout, mode='r|') as archive:
            for member in archive:
                rel = os.path.normpath(member.name)
                if rel == '.' or member.isdir():
                    continue
                if not (member.isfile() or member.issym() or member.islnk()):
                    fail(f'{source}: /{rel} is neither a file, a link nor a folder')
                dest, note = destination(source, rel, self.cuda)
                if dest is None:
                    self.drop(note, f'{source}: /{rel}', member.size)
                    continue
                if dest == 'doc':
                    dest = f'usr/share/doc/{package}/nvidia/{source}/{note}'
                self.epoch = max(self.epoch, int(member.mtime))
                if member.islnk():  # a second name for a file earlier in the archive: a copy here
                    first = placed.get(os.path.normpath(member.linkname))
                    if first is None or self.files.get(first, {}).get('kind') != 'file':
                        fail(f'{source}: /{rel} is a hard link to /{member.linkname}, which is left out')
                    with open(self.root(self.files[first]['package']) / first, 'rb') as copy:
                        self.place(package, dest, source, member, copy)
                else:
                    self.place(package, dest, source, member, archive.extractfile(member) if member.isfile() else None)
                placed[rel] = dest
                kept += 1
        if tar.wait():
            fail(f'dpkg-deb could not read {deb}')
        return kept

    def write(self, package, dest, text, mode=0o644, note='nano-cuda12'):
        data = text.encode() if isinstance(text, str) else text
        if dest in self.files:
            fail(f'/{dest} is already in {self.files[dest]["package"]}')
        self.place(package, dest, note, None, data=data)
        os.chmod(self.root(package) / dest, mode)
        self.files[dest]['mode'] = mode

    def link(self, package, dest, target):
        info = tarfile.TarInfo(dest)
        info.type, info.linkname = tarfile.SYMTYPE, target
        self.place(package, dest, 'nano-cuda12', info)

    def replace(self, dest, data):
        entry = self.files[dest]
        path = self.root(entry['package']) / dest
        path.write_bytes(data)
        entry.update(sha256=hashlib.sha256(data).hexdigest(), size=len(data), source=entry['source'] + ' (changed)')

    def of(self, package):
        return {d: e for d, e in self.files.items() if e['package'] == package}


def patch_math_functions(stage, cuda, out):
    """noexcept, through __NANO_GLIBC_NOEXCEPT, on the extern declarations of NOEXCEPT."""
    dest = f'{cuda}/{TARGET}/include/crt/math_functions.h'
    if dest not in stage.files:
        fail(f'no /{dest} among the compiler packages')
    path = stage.root(stage.files[dest]['package']) / dest
    original = path.read_text(encoding='latin-1')
    text = original
    for name in NOEXCEPT:
        pattern = re.compile(r'^([ \t]*extern\b[^;\n]*\b' + name + r'\([^()]*\))[ \t]*;', re.M)
        lines = pattern.findall(text)
        already = [line for line in lines if 'noexcept' in line or '__THROW' in line]
        if not lines:
            print(f'NVCC_PATCH {name}: no extern declaration in crt/math_functions.h, left alone')
        elif already:
            print(f'NVCC_PATCH {name}: declared with an exception specification already, left alone')
        else:
            text = pattern.sub(r'\1 __NANO_GLIBC_NOEXCEPT;', text)
            print(f'NVCC_PATCH {name}: noexcept on {len(lines)} extern declaration(s)')
    if text == original:
        print('NVCC_PATCH crt/math_functions.h unchanged')
        return
    text = NOEXCEPT_HEADER + text
    stage.replace(dest, text.encode('latin-1'))
    diff = subprocess.run(['diff', '-u', '--label', f'a/{dest}', '--label', f'b/{dest}', '-', str(path)],
                          input=original.encode('latin-1'), capture_output=True, check=False).stdout
    (out / 'math_functions.diff').write_bytes(diff)


def patch_profile(stage, cuda, out):
    """nano-glibc/bits/math-vector.h, and its folder on nvcc's include path."""
    dest = f'{cuda}/bin/nvcc.profile'
    if dest not in stage.files:
        fail(f'no /{dest} among the compiler packages')
    package = stage.files[dest]['package']
    path = stage.root(package) / dest
    original = path.read_text()
    lines = original.splitlines(keepends=True)
    at = [i for i, line in enumerate(lines) if re.match(r'\s*INCLUDES\s*\+?=', line)]
    if not at:
        fail(f'/{dest} has no INCLUDES line to add nano-glibc after')
    lines.insert(at[-1] + 1, PROFILE_LINE + '\n')
    stage.replace(dest, ''.join(lines).encode())
    diff = subprocess.run(['diff', '-u', '--label', f'a/{dest}', '--label', f'b/{dest}', '-', str(path)],
                          input=original.encode(), capture_output=True, check=False).stdout
    (out / 'nvcc.profile.diff').write_bytes(diff)
    stage.write(package, f'{cuda}/nano-glibc/bits/math-vector.h', MATH_VECTOR)
    print('NVCC_PATCH nvcc.profile: nano-glibc first on the include path, for bits/math-vector.h')


class Data:
    def __init__(self, path):
        self.path = path

    def read_bytes(self):
        return self.path.read_bytes()


def scan(stage, packages, lines):
    """Check every ELF file: arm64, glibc no newer than 26.04's, and every library
    it links found in the packages, in Ubuntu 26.04 (UBUNTU_LIBS) or, for the
    12.2 driver's libnv* libraries, in the installed driver set. Returns each
    package's Ubuntu dependencies, the newest glibc version needed, and whether
    a library was not found (UNRESOLVED lines)."""
    provided = {p: set() for p in packages}
    infos = {}
    for dest, entry in sorted(stage.files.items()):
        name = posixpath.basename(dest)
        stubs = '/stubs/' in dest
        if entry['kind'] == 'link':
            if not stubs:
                provided[entry['package']].add(name)
            continue
        path = stage.root(entry['package']) / dest
        with open(path, 'rb') as f:
            head = f.read(20)
        if head[:4] != b'\x7fELF' or head[18:20] == b'\xbe\x00':  # EM_CUDA: GPU code
            continue
        if head[4:6] != b'\x02\x01' or head[18:20] != b'\xb7\x00':
            fail(f'/{dest} is not a 64-bit arm64 ELF file')
        info = fetch.elf_info(Data(path))
        infos[dest] = info
        if not stubs:
            provided[entry['package']].add(name)
            if info['soname']:
                provided[entry['package']].add(info['soname'])
    depends = {p: set() for p in packages}
    glibc = {p: (2, 17) for p in packages}
    unresolved, driver_set = {}, {}
    runtime = packages[0]
    for dest, info in infos.items():
        package = stage.files[dest]['package']
        need = fetch.glibc_max(info['versions'])
        if need != '-':
            version = tuple(map(int, need[6:].split('.')))
            if version > GLIBC:
                fail(f'/{dest} needs {need}, newer than Ubuntu 26.04 has')
            glibc[package] = max(glibc[package], version)
        lines.append(f"/{dest} [{package}] soname={info['soname'] or '-'} glibc={need} "
                     f"needed={' '.join(info['needed']) or '-'}")
        for lib in info['needed']:
            if lib in provided[package] or lib in provided[runtime]:
                continue
            if lib in UBUNTU_LIBS:
                depends[package].add(UBUNTU_LIBS[lib])
            elif DRIVER_SET.fullmatch(lib) and dest.startswith(COMPAT_DIR):
                driver_set.setdefault(lib, set()).add(posixpath.basename(dest))
            else:
                unresolved.setdefault(lib, set()).add(posixpath.basename(dest))
    for lib, users in sorted(driver_set.items()):
        print(f"FROM_DRIVER_SET {lib} (linked by {', '.join(sorted(users)[:4])}{' ...' if len(users) > 4 else ''})")
    for lib, users in sorted(unresolved.items()):
        print(f"UNRESOLVED {lib} (linked by {', '.join(sorted(users))})")
    print(f'ELF_FILES={len(infos)} UBUNTU_DEPENDS={",".join(sorted(set().union(*depends.values())))}')
    return depends, glibc, bool(unresolved)


def check_links(stage):
    """Every link resolves to a file or link in the packages; False if one does not."""
    broken = []
    for dest, entry in stage.files.items():
        if entry['kind'] != 'link':
            continue
        seen, current = 0, dest
        while seen < 16:
            target = posixpath.normpath(posixpath.join(posixpath.dirname(current), stage.files[current]['target']))
            if target not in stage.files:
                # A folder link (lib64 -> targets/...) resolves when files lie under it.
                if not any(d.startswith(target + '/') for d in stage.files):
                    broken.append(f'/{dest} -> {entry["target"]}')
                break
            if stage.files[target]['kind'] == 'file':
                break
            current, seen = target, seen + 1
    for line in broken:
        print(f'BROKEN_LINK {line}')
    return not broken


def control(stage, package, version, depends, description, note, extra=''):
    root = stage.root(package)
    files = stage.of(package)
    size = sum(e.get('size', 0) for e in files.values()) // 1024 + 1
    debian = root / 'DEBIAN'
    debian.mkdir(mode=0o755)
    (debian / 'control').write_text(
        f'Package: {package}\nVersion: {version}\nArchitecture: {ARCH}\n'
        f'Maintainer: jetson-ubuntu-26 <noreply@localhost>\nInstalled-Size: {size}\n'
        f'Depends: {depends}\n{extra}Section: non-free/devel\nPriority: optional\n'
        f'Description: {description}\n{note}')
    md5 = []
    for dest, entry in sorted(files.items()):
        if entry['kind'] == 'file':
            digest = hashlib.md5()
            with open(root / dest, 'rb') as f:
                for block in iter(lambda: f.read(1 << 20), b''):
                    digest.update(block)
            md5.append(f'{digest.hexdigest()}  {dest}\n')
    (debian / 'md5sums').write_text(''.join(md5))
    for item in ('control', 'md5sums'):
        os.chmod(debian / item, 0o644)


def build_deb(stage, package, version, out):
    root = stage.root(package)
    epoch = stage.epoch
    for path in [root, *root.rglob('*')]:
        if path.is_dir() and not path.is_symlink():
            os.chmod(path, 0o755)
        os.utime(path, (epoch, epoch), follow_symlinks=False)
    deb = out / f'{package}_{version}_{ARCH}.deb'
    print(f'BUILDING {deb.name} (xz; the runtime package takes a few minutes)', flush=True)
    subprocess.check_call(['dpkg-deb', '--root-owner-group', '-Zxz', '--build', str(root), str(deb)],
                          stdout=subprocess.DEVNULL, env={**os.environ, 'SOURCE_DATE_EPOCH': str(epoch)})
    return deb


def readme(package, cuda, minor, sources, version):
    lines = [f'{package} {version}', '',
             'Built by scripts/host/build-nano-cuda12-debs.py (jetson-ubuntu-26) for Ubuntu 26.04',
             "on the Jetson Nano's JetPack 5 kernel, beside the system's CUDA 11.4. Files from:"]
    lines += [f'  {name} {entry["Version"]} (sha256 {entry["SHA256"]})' for name, entry in sources]
    if package == 'nano-cuda12':
        lines += ['', f'Run programs through nano-cuda12, which puts /{COMPAT_DIR.rstrip("/")} and',
                  f'/{cuda}/{TARGET}/lib first in the library path. Nothing here is in the',
                  "system's library path, and /usr/local/cuda stays CUDA 11.4's. cuDNN 9's",
                  "libraries are in CUDA's library folder. No maintainer script."]
    else:
        lines += ['', f'Changes to NVIDIA\'s files: {cuda}/{TARGET}/include/crt/math_functions.h declares',
                  ' ' + ', '.join(NOEXCEPT) + ' noexcept (glibc 2.41 and later; off with',
                  ' -DNANO_CUDA12_ORIGINAL_MATH), and bin/nvcc.profile adds nano-glibc to the include',
                  ' path, whose bits/math-vector.h hides glibc\'s AArch64 vector math from CUDA',
                  ' compiles (off with -DNANO_CUDA12_GLIBC_VECTOR_MATH). Static libraries other than',
                  ' ' + ', '.join(sorted(KEEP_ARCHIVES)) + ' are left out; cuDNN 9\'s headers are in',
                  f' CUDA\'s include folder without their _v9 suffix. nvcc {minor} supports GCC up to 13:',
                  ' use -ccbin g++-11.']
    return '\n'.join(lines) + '\n'


def mirrored(folder, url):
    """URL's place in a copy of the repositories under FOLDER, as a file:// URL."""
    return folder.resolve().as_uri() + '/' + url.split('://', 1)[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--key', type=Path, required=True,
                        help="NVIDIA's jetson-ota-public.asc (or a binary keyring)")
    parser.add_argument('--reuse', type=Path, action='append', default=[],
                        help='a folder of .debs to copy from when they match the index')
    parser.add_argument('--mirror', type=Path,
                        help="read NVIDIA's repositories from this copy (laid out as the servers, "
                             'as nano26-convert saves them), checked as from the servers')
    parser.add_argument('out', type=Path, help='output folder (created; must be empty)')
    args = parser.parse_args()
    if args.mirror:
        fetch.BASE = mirrored(args.mirror, fetch.BASE)
        probe.CUDA_REPO = mirrored(args.mirror, probe.CUDA_REPO)
    for tool in ('gpg', 'gpgv', 'dpkg-deb', 'diff'):
        if not shutil.which(tool):
            fail(f'{tool} is not installed')
    for source in NANO_FILES:
        if not source.is_file():
            fail(f'no {source}')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        fail(f'{out} is not empty')
    free = shutil.disk_usage(out).free
    if free < NEED_FREE:
        fail(f'needs {NEED_FREE // 1024 ** 3} GB free in {out} (has {free // 1024 ** 3} GB)')
    work = Path(tempfile.mkdtemp(prefix='.work-', dir=out))
    try:
        result = build(args, out, work)
    finally:
        shutil.rmtree(work)
    nano = out / 'nano'
    sums = [f'{fetch.sha256_file(p)}  {p.relative_to(nano)}' for p in sorted(nano.rglob('*'))
            if p.is_file() and p.name != 'SHA256SUMS']
    (nano / 'SHA256SUMS').write_text('\n'.join(sums) + '\n')
    for line in sums:
        if line.endswith('.deb'):
            print(line)
    size = sum(p.stat().st_size for p in nano.rglob('*') if p.is_file())
    print(f'NANO_FOLDER_SIZE={size // 1024 ** 2} MiB to copy to the Nano')
    print(f'NANO_CUDA12_DEBS=PASS version={result} nano={nano}')
    return 0


def choose(url, entries, cuda_entries):
    """What the build takes: from the common r36.4 index (ENTRIES, its packages
    under URL) the closures of RUNTIME_ROOTS and DEV_ROOTS for the newest CUDA
    12, and from the CUDA repository's (CUDA_ENTRIES) the newest COMPAT.
    Returns the minor version, cuda-cudart-12-N's entry, the plan [(name,
    base URL, entry, package)], the packages left out (name: reason) and the
    dependencies left to Ubuntu (group: parents). nano26-convert uses this to
    know what to download."""
    cudart, cudart_entry = probe.pick(entries, r'cuda-cudart-12-\d+', 'common')
    minor = int(cudart.rsplit('-', 1)[1])
    not_taken, outside = {}, {}
    runtime = closure(entries, [g.format(m=minor) for g in RUNTIME_ROOTS], set(), not_taken, outside)
    dev = closure(entries, [g.format(m=minor) for g in DEV_ROOTS], set(runtime), not_taken, outside)
    if COMPAT not in cuda_entries:
        fail(f'{COMPAT} is not in the CUDA repository index')
    plan = [(COMPAT, probe.CUDA_REPO, fetch.newest(cuda_entries, COMPAT, 'cuda'), 'nano-cuda12')]
    plan += [(n, url, fetch.newest(entries, n, 'common'), 'nano-cuda12') for n in runtime]
    plan += [(n, url, fetch.newest(entries, n, 'common'), 'nano-cuda12-dev') for n in dev]
    return minor, cudart_entry, plan, not_taken, outside


def build(args, out, work):
    gnupg, keyring = fetch.prepare_keyring(work, args.key)
    fetch.RELEASE = R36_RELEASE
    url, entries, _ = fetch.fetch_index(work, gnupg, keyring, 'common')
    cuda_entries = probe.flat_index(work, *probe.cuda_keyring(work))
    minor, cudart_entry, plan, not_taken, outside = choose(url, entries, cuda_entries)
    cuda = f'usr/local/cuda-12.{minor}'
    version = cudart_entry['Version'].split('-', 1)[0] + REVISION
    for name, reason in sorted(not_taken.items()):
        print(f'NOT_TAKEN {name}: {reason}')
    for group, parents in sorted(outside.items()):
        print(f"FROM_UBUNTU {group} (a dependency of {', '.join(sorted(parents))}; not in the index)")

    sources_dir = out / 'sources'
    sources_dir.mkdir()
    total = sum(int(e['Size']) for _, _, e, _ in plan)
    runtime = sum(package == 'nano-cuda12' for _, _, _, package in plan)
    print(f'SOURCES runtime={runtime} dev={len(plan) - runtime} bytes={total}', flush=True)
    stage = Stage(work, cuda)
    record, maintainer, sources = {}, [], {'nano-cuda12': [], 'nano-cuda12-dev': []}
    for name, base, entry, package in plan:
        deb = fetch.obtain(base, entry, sources_dir, args.reuse)
        kept = stage.take(name, deb, package)
        print(f"DEB {package} {name} {entry['Version']} size={entry['Size']} files={kept}", flush=True)
        record[name] = {k: entry.get(k) for k in ('Version', 'Filename', 'Size', 'SHA256', 'Depends')}
        record[name]['package'] = package
        maintainer += fetch.maintainer_text(name, deb, work) + ['']
        sources[package].append((name, entry))

    for reason, (count, size, examples) in sorted(stage.dropped.items()):
        print(f'LEFT_OUT {reason}: {count} files, {size} bytes (e.g. {", ".join(examples[:3])})')
    # Problems that leave the rest checkable are reported together, before any .deb is built.
    problems = []
    if 'unexpected' in stage.dropped:
        for line in stage.dropped['unexpected'][2]:
            print(f'UNEXPECTED {line}')
        problems.append('a source package holds files outside the folders this build knows (UNEXPECTED)')

    nano = out / 'nano'
    nano.mkdir()
    patch_math_functions(stage, cuda, nano)
    patch_profile(stage, cuda, nano)
    # Link names (libX.so) for the runtime libraries the -dev packages have none for.
    added = []
    lib = f'{cuda}/{TARGET}/lib/'
    for dest, entry in sorted(stage.of('nano-cuda12').items()):
        if not dest.startswith(lib) or '/' in dest[len(lib):] or entry['kind'] != 'file':
            continue
        info = fetch.elf_info(Data(stage.root('nano-cuda12') / dest))
        soname = info and info['soname']
        if soname and '.so.' in soname:
            plain = lib + soname.split('.so.', 1)[0] + '.so'
            if plain not in stage.files:
                stage.link('nano-cuda12-dev', plain, soname)
                added.append(posixpath.basename(plain))
    print(f"DEV_LINKS_ADDED {' '.join(added) or 'none'}")
    for name, package, target in (('include', 'nano-cuda12-dev', f'{TARGET}/include'),
                                  ('lib64', 'nano-cuda12', f'{TARGET}/lib')):
        if f'{cuda}/{name}' not in stage.files:
            stage.link(package, f'{cuda}/{name}', target)
            print(f'ADDED_LINK /{cuda}/{name} -> {target}')
    stage.write('nano-cuda12', 'usr/bin/nano-cuda12',
                LAUNCHER.format(cuda='/' + cuda, minor=f'12.{minor}', compat=COMPAT_DIR.rstrip('/'),
                                target=TARGET), 0o755)
    for package in ('nano-cuda12', 'nano-cuda12-dev'):
        stage.write(package, f'usr/share/doc/{package}/README',
                    readme(package, cuda, f'12.{minor}', sources[package], version))
    if not check_links(stage):
        problems.append('a packaged link points at nothing in the packages (BROKEN_LINK)')

    report = []
    depends, glibc, unresolved = scan(stage, ['nano-cuda12', 'nano-cuda12-dev'], report)
    (out / 'report.txt').write_text('\n'.join(report) + '\n')
    (out / 'maintainer.txt').write_text('\n'.join(maintainer) + '\n')
    if unresolved:
        problems.append('a packaged file links a library in neither package nor UBUNTU_LIBS (UNRESOLVED)')
    if problems:
        fail('; '.join(problems) + f'; the downloads stay in {out / "sources"} for --reuse')

    def depends_line(package, extra):
        libs = sorted(depends[package] - {'libc6'})
        return ', '.join([f'libc6 (>= {".".join(map(str, glibc[package]))})'] + libs + extra)

    control(stage, 'nano-cuda12', version, depends_line('nano-cuda12', [DRIVER_DEPENDS]),
            f'CUDA 12 for Jetson Nano beside CUDA 11.4: 12.2 driver, CUDA 12.{minor} libraries, cuDNN 9',
            f' NVIDIA\'s CUDA 12.2 upgrade driver for JetPack 5 (cuda-compat-12-2) and\n'
            f' CUDA 12.{minor}\'s runtime libraries and cuDNN 9 from JetPack 6, in\n'
            f' /usr/local/cuda-12.2/compat and /{cuda}, out of the system\'s\n'
            f' library path. nano-cuda12 runs a program with them.\n')
    control(stage, 'nano-cuda12-dev', version, depends_line('nano-cuda12-dev', [f'nano-cuda12 (= {version})']),
            f'CUDA 12.{minor} compiler, headers and link names for Jetson Nano (nano-cuda12)',
            f' CUDA 12.{minor}\'s nvcc and tools, and the headers and link names of its\n'
            f' libraries and cuDNN 9, in /{cuda}, with two header changes for\n'
            f' glibc 2.43. Build with nano-cuda12 nvcc -ccbin g++-11 -arch=sm_53.\n',
            'Suggests: g++-11\n')
    staged = work / 'debs'
    staged.mkdir()
    debs = [build_deb(stage, p, version, staged) for p in ('nano-cuda12', 'nano-cuda12-dev')]
    for deb in debs:  # every check has passed
        shutil.move(str(deb), nano / deb.name)
    listing = []
    for dest, entry in sorted(stage.files.items()):
        if entry['kind'] == 'link':
            listing.append(f'{"symlink":64}  {entry["package"]}  /{dest} -> {entry["target"]}')
        else:
            listing.append(f'{entry["sha256"]}  {entry["package"]}  /{dest}')
    (nano / 'nano-cuda12-files.txt').write_text('\n'.join(listing) + '\n')
    for source in NANO_FILES:
        shutil.copy2(source, nano / source.name)
    (out / 'packages.json').write_text(json.dumps({
        'r36_release': R36_RELEASE, 'cuda': f'12.{minor}', 'version': version,
        'jetson_key_fingerprint': fetch.KEY_FINGERPRINT, 'cuda_repo': probe.CUDA_REPO,
        'cuda_key_fingerprint': probe.CUDA_KEY_FINGERPRINT, 'not_taken': not_taken,
        'from_ubuntu': {g: sorted(p) for g, p in outside.items()}, 'sources': record}, indent=2) + '\n')
    for package in ('nano-cuda12', 'nano-cuda12-dev'):
        files = stage.of(package)
        print(f"PACKAGE {package} {version} files={sum(e['kind'] == 'file' for e in files.values())} "
              f"links={sum(e['kind'] == 'link' for e in files.values())} "
              f"bytes={sum(e.get('size', 0) for e in files.values())}")
    return version


if __name__ == '__main__':
    sys.exit(main())

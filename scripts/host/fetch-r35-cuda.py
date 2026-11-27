#!/usr/bin/env python3
"""Download JetPack 5's CUDA driver and CUDA 11.4 runtime for the Nano's CUDA 11 probe.

Usage: python3 scripts/host/fetch-r35-cuda.py --key jetson-ota-public.asc
           [--set driver|toolkit|tensorrt|install|video] [--release r35.6|r32.7]
           [--reuse DIR ...] OUT_DIR

Fetches NVIDIA's L4T R35.6 indexes for jetson/t194 (or --platform t234) and
jetson/common, checks each Release file's signature with gpgv against
NVIDIA's Jetson key (KEY_FINGERPRINT below, the key the Nano's JetPack 4 trusts
and that signed the r32.7 indexes), checks the Packages index against the
Release file, and downloads:
- nvidia-l4t-cuda (libcuda, CUDA 11.4's driver), nvidia-l4t-3d-core (for
  libnvidia-ptxjitcompiler, which libcuda loads to compile PTX but which
  nvidia-l4t-cuda does not depend on) and the nvidia-l4t-* packages they list
  among their dependencies that are in ALLOWED_DEPENDS;
- cuda-cudart-11-4 (the CUDA 11.4 runtime library).
With --set toolkit it downloads instead CUDA 11.4's compiler and headers
(TOOLKIT_PACKAGES and the cuda-*-11-4 packages they depend on), for building
programs on the Nano next to a driver set, and adds the test sources and
add-u26-gcc11.sh (GCC 11, the host compiler) to OUT_DIR.
With --set tensorrt it downloads TensorRT 8.5 with trtexec, cuDNN 8.6, cuBLAS,
NVRTC and cuDLA (TENSORRT_PACKAGES and the common packages they depend on, without
-dev packages), for the TensorRT test next to a driver set. Then, while the
packages, together with the driver set's, need an NVIDIA library (lib(nv|cu)*)
that none of them provides, it tries the platform packages in
PLATFORM_CANDIDATES in turn and keeps each one that provides a missing
library; the driver set's own packages count as present but stay out of
OUT_DIR. The test files are delivered separately, so OUT_DIR holds packages
only. With --set install it downloads what install-u26-r35.sh installs in
26.04 next to the nano-l4t packages: CUDA 11.4's runtime libraries
(cuda-libraries-11-4, as CUDA 10.2's cuda-libraries-10-2 is installed now),
cuDNN 8.6 and TensorRT 8.5 with trtexec (INSTALL_PACKAGES), with every common
package they depend on, picking the first alternative of each dependency that
a package in the index is or provides; dependencies the index cannot meet must
come from 26.04 and are listed. NVIDIA libraries these link must be in the
driver set (counted as present, as above, and never in OUT_DIR), and
maintainer.txt gives each package's relationships, conffiles and maintainer
scripts in full, for review before they are pinned. --reuse names folders
whose .debs (such as the GPU survey's) are copied instead of downloaded when
their SHA-256 and size match the index.
With --set video it downloads JetPack 5's GStreamer plugins and video
libraries from the platform index (VIDEO_PACKAGES: nvidia-l4t-gstreamer, with
the video converter nvvidconv, and nvidia-l4t-multimedia and -multimedia-utils,
with NvBufSurface), for scripts/jetson/probe-l4t-video.sh next to the R35.6
driver set that the nano-l4t packages installed on the Nano. Their other
dependencies are listed, not taken; a package in VIDEO_CANDIDATES is kept only
if it provides an NVIDIA library the set links that neither the set nor the
driver set has, and libraries no package has are listed (not an error: the
probe tests the converter only). maintainer.txt is written as for the install.
With --set tensorrt --release r32.7 it takes JetPack 4's TensorRT 8.2 with
trtexec, cuDNN 8.2, cuBLAS 10.2, the CUDA 10.2 runtime and NVRTC
(TENSORRT_PACKAGES_R32 and the common r32.7 packages they depend on, without
-dev packages), for scripts/jetson/yolo/probe-trt82.sh. They run on the
Nano's installed R35.6 driver, as JetPack 4's CUDA 10.2 programs did
(2026-10-15), so no platform package is taken; the NVIDIA libraries they
link that none of them provides are listed (FROM_DRIVER), for the probe to
find in the driver.
With --set video --release r32.7 it takes JetPack 4's (L4T R32.7.6) video
set instead, from the signed t210 r32.7 index, for the same probe: the three
packages and nvidia-l4t-core, because the Nano's installed driver set is
R35.6's and the two releases' libraries share names. Nothing installed counts
as present: while the set links an NVIDIA library none of its packages has,
the packages in VIDEO_CANDIDATES_R32 (t210) and VIDEO_COMMON_R32 (common
r32.7) are tried, and each one that provides a missing library is kept.
Each .deb is checked against the index's SHA-256 and size. OUT_DIR receives
the .debs, scripts/jetson/probes/probe-cuda11.sh and tests/cuda/cuda11_probe.py,
SHA256SUMS over all of them (checked again on the Nano), packages.json, and
report.txt: for each ELF file in the packages, its SONAME, NEEDED libraries,
the newest glibc version it requires, and which GPU names its strings carry
(gm20b and T210 are the Nano's). The report lists the NEEDED libraries no
package here provides; those must come from Ubuntu 26.04.

Runs as an ordinary user; needs gpg, gpgv and dpkg-deb. Writes nothing outside
OUT_DIR (gpg runs with a temporary home in OUT_DIR, removed at the end).
NVIDIA's files stay in OUT_DIR and never go into git.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request

BASE = 'https://repo.download.nvidia.com/jetson/'
RELEASE = 'r35.6'
# NVIDIA Corporation <linux-tegra-bugs@nvidia.com>, created 2019-05-09: the
# primary key of jetson-ota-public.asc (byte-identical on the Nano, 2026-10-15).
KEY_FINGERPRINT = '3C6D1FF3100C8C3ABB0869C0E6543461A9996195'
# The first Nano run (2026-10-15) found libcuda loading JetPack 4's PTX compiler
# from the system, because R35's is not in nvidia-l4t-cuda.
PLATFORM_PACKAGES = ['nvidia-l4t-cuda', 'nvidia-l4t-3d-core']
ALLOWED_DEPENDS = {'nvidia-l4t-core', 'nvidia-l4t-3d-core', 'nvidia-l4t-cuda'}
COMMON_PACKAGES = ['cuda-cudart-11-4']
TOOLKIT_PACKAGES = ['cuda-nvcc-11-4', 'cuda-cudart-dev-11-4', 'cuda-driver-dev-11-4']
# trtexec is in libnvinfer-bin. TensorRT loads cuDNN and cuBLAS at run time, and
# may load NVRTC, so they are named even if no package depends on them. The
# first fetch (2026-10-15) found libnvinfer.so.8.5.2 linking libcudla.so.1 (the
# DLA runtime) although no package lists it.
TENSORRT_PACKAGES = ['libnvinfer-bin', 'libnvinfer8', 'libnvinfer-plugin8', 'libnvonnxparsers8',
                     'libnvparsers8', 'libcudnn8', 'libcublas-11-4', 'cuda-cudart-11-4',
                     'cuda-nvrtc-11-4', 'libcudla-11-4']
# JetPack 4's TensorRT 8.2 (--release r32.7), built with sm_53 kernels: the same
# roles on CUDA 10.2.
TENSORRT_PACKAGES_R32 = ['libnvinfer-bin', 'libnvinfer8', 'libnvinfer-plugin8', 'libnvonnxparsers8',
                         'libnvparsers8', 'libcudnn8', 'libcublas10', 'cuda-cudart-10-2', 'cuda-nvrtc-10-2']
# The permanent install: CUDA 11.4's runtime libraries, cuDNN and TensorRT.
INSTALL_PACKAGES = ['cuda-libraries-11-4', 'libcudnn8', 'libnvinfer8', 'libnvinfer-plugin8',
                    'libnvparsers8', 'libnvonnxparsers8', 'libnvinfer-bin']
# Tried in order while an NVIDIA library is missing (JetPack's TensorRT may link
# the DLA compiler or NvMedia libraries even where no DLA exists).
PLATFORM_CANDIDATES = ['nvidia-l4t-core', 'nvidia-l4t-cuda', 'nvidia-l4t-3d-core',
                       'nvidia-l4t-dla-compiler', 'nvidia-l4t-nvsci', 'nvidia-l4t-multimedia']
# JetPack 5's video converter and the libraries it uses (the probe tests the
# converter through the Nano's VIC; decoding needs NVDEC, off in the 5.10 device tree).
VIDEO_PACKAGES = ['nvidia-l4t-gstreamer', 'nvidia-l4t-multimedia', 'nvidia-l4t-multimedia-utils']
VIDEO_CANDIDATES = ['nvidia-l4t-nvsci', 'nvidia-l4t-camera']
# Installed on the Nano with CUDA 11.4's runtime libraries (install-u26-r35.sh).
VIDEO_INSTALLED = {'libcudart.so.11.0'}
# JetPack 4's video set (--release r32.7): its own core libraries too, since
# the Nano's installed driver set is R35.6's; tried in turn while an NVIDIA
# library is missing.
VIDEO_CANDIDATES_R32 = ['nvidia-l4t-cuda', 'nvidia-l4t-3d-core', 'nvidia-l4t-camera']
VIDEO_COMMON_R32 = ['cuda-cudart-10-2']
REPO = Path(__file__).resolve().parents[2]
PROBE_FILES = [REPO / 'scripts/jetson/probes/probe-cuda11.sh', REPO / 'tests/cuda/cuda11_probe.py']
TOOLKIT_FILES = PROBE_FILES + [REPO / 'tests/cuda/vector_add.cu', REPO / 'tests/cuda/gpu_probe.cu',
                               REPO / 'scripts/jetson/add-u26-gcc11.sh']
VIDEO_FILES = [REPO / 'scripts/jetson/probe-l4t-video.sh', REPO / 'tests/video/frame_check.py',
               REPO / 'tests/video/colour_fit.py']
SET_FILES = {'driver': PROBE_FILES, 'toolkit': TOOLKIT_FILES, 'tensorrt': [], 'install': [], 'video': VIDEO_FILES}
CHIP_TAGS = [b'gm20b', b'GM20B', b'gm20', b'tegra210', b't210', b'T210',
             b'gp10b', b'gv11b', b'ga10b', b'tegra194', b'tegra234']


def fail(message):
    raise SystemExit('R35_CUDA_FETCH=FAIL: ' + message)


def download(url, target):
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    target.write_bytes(data)
    return data


def fetch_file(url, target):
    """URL into TARGET a block at a time, as a .deb can be larger than memory. A
    file:// URL (a copy of the repository, such as nano26-convert saves) is
    hard-linked where the filesystem allows it."""
    if url.startswith('file://'):
        try:
            os.link(urllib.request.url2pathname(url[len('file://'):]), str(target))
            return
        except OSError:
            pass
    with urllib.request.urlopen(url, timeout=120) as response, open(str(target), 'wb') as f:
        shutil.copyfileobj(response, f, 1 << 20)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def obtain(url, entry, folder, reuse):
    """ENTRY's .deb in FOLDER, copied from a REUSE folder when it matches, else downloaded."""
    target = folder / Path(entry['Filename']).name
    for other in reuse:
        source = other / target.name
        if source.is_file() and source.stat().st_size == int(entry['Size']) \
                and sha256_file(source) == entry['SHA256']:
            shutil.copyfile(source, target)
            print(f'REUSED {target.name} from {other}')
            break
    else:
        fetch_file(url + entry['Filename'], target)
    if sha256_file(target) != entry['SHA256'] or target.stat().st_size != int(entry['Size']):
        fail(f'{target.name} does not match the signed index')
    return target


# --- Debian version order (dpkg's algorithm), to pick the newest entry.
def _order(c):
    if c == '~':
        return -1
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    return ord(c) + 256


def _compare_part(a, b):
    while a or b:
        ta = re.match(r'[^\d]*', a).group()
        tb = re.match(r'[^\d]*', b).group()
        a, b = a[len(ta):], b[len(tb):]
        for i in range(max(len(ta), len(tb))):
            oa = _order(ta[i]) if i < len(ta) else 0
            ob = _order(tb[i]) if i < len(tb) else 0
            if oa != ob:
                return oa - ob
        da = re.match(r'\d*', a).group()
        db = re.match(r'\d*', b).group()
        a, b = a[len(da):], b[len(db):]
        if int(da or 0) != int(db or 0):
            return int(da or 0) - int(db or 0)
    return 0


def version_key(version):
    class Key:
        def __init__(self, v):
            epoch, _, rest = v.partition(':') if ':' in v else ('0', '', v)
            upstream, _, revision = rest.rpartition('-') if '-' in rest else (rest, '', '0')
            self.parts = (int(epoch or 0), upstream, revision)

        def __lt__(self, other):
            if self.parts[0] != other.parts[0]:
                return self.parts[0] < other.parts[0]
            c = _compare_part(self.parts[1], other.parts[1])
            if c:
                return c < 0
            return _compare_part(self.parts[2], other.parts[2]) < 0
    return Key(version)


# --- Signed index.
def fetch_index(run, gnupg, keyring, suite):
    folder = run / 'index' / suite
    folder.mkdir(parents=True, exist_ok=True)
    url = f'{BASE}{suite}/dists/{RELEASE}/'
    release = download(url + 'Release', folder / 'Release')
    download(url + 'Release.gpg', folder / 'Release.gpg')
    status = subprocess.run(
        ['gpgv', '--homedir', str(gnupg), '--status-fd', '1', '--keyring', str(keyring),
         str(folder / 'Release.gpg'), str(folder / 'Release')],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    (folder / 'gpgv-status.txt').write_text(status.stdout + status.stderr)
    valid = [line.split() for line in status.stdout.splitlines()
             if line.startswith('[GNUPG:] VALIDSIG ')]
    if status.returncode or not valid or valid[0][-1] != KEY_FINGERPRINT:
        fail(f'{suite} Release signature did not verify against {KEY_FINGERPRINT}')
    text = release.decode()
    fields = dict(line.split(': ', 1) for line in text.split('\nMD5Sum:')[0].splitlines()
                  if ': ' in line and not line.startswith(' '))
    sums = {}
    in_sha = False
    for line in text.splitlines():
        if not line.startswith(' '):
            in_sha = line.startswith('SHA256:')
            continue
        if in_sha:
            digest, size, name = line.split()
            sums[name] = (digest, int(size))
    for name, decode in (('main/binary-arm64/Packages', lambda d: d),
                         ('main/binary-arm64/Packages.gz', gzip.decompress)):
        if name in sums:
            data = download(url + name, folder / Path(name).name)
            digest, size = sums[name]
            if hashlib.sha256(data).hexdigest() != digest or len(data) != size:
                fail(f'{suite} {name} does not match its signed Release entry')
            packages = decode(data).decode()
            break
    else:
        fail(f'{suite} Release lists no arm64 Packages index')
    entries = {}
    for block in packages.split('\n\n'):
        values = {}
        for line in block.splitlines():
            if ': ' in line and not line.startswith(' '):
                key, value = line.split(': ', 1)
                values[key] = value
        if 'Package' in values:
            entries.setdefault(values['Package'], []).append(values)
    print(f"INDEX {suite} {RELEASE}: Label={fields.get('Label', '?')} "
          f"Date={fields.get('Date', '?')} packages={len(entries)} "
          f"signed_by={valid[0][2]} primary={valid[0][-1]}")
    return url.rsplit('dists/', 1)[0], entries, fields


def newest(entries, name, suite):
    if name not in entries:
        fail(f'{name} is not in the {suite} {RELEASE} index')
    return max(entries[name], key=lambda e: version_key(e['Version']))


def resolve(entries, group):
    """The package meeting a dependency GROUP: the first alternative that a package is or provides."""
    for alternative in group.split('|'):
        name = re.split(r'[\s(:]', alternative.strip(), maxsplit=1)[0]
        if name in entries:
            return name
        providers = sorted({e['Package'] for es in entries.values() for e in es
                            if name in [re.split(r'[\s(]', p.strip(), maxsplit=1)[0]
                                        for p in e.get('Provides', '').split(',')]})
        if providers:
            return providers[0]
    return None


def maintainer_text(name, deb, work):
    """DEB's relationships, conffiles and maintainer scripts, for review."""
    fields = subprocess.run(['dpkg-deb', '-f', str(deb), 'Package', 'Version', 'Pre-Depends', 'Depends',
                             'Provides', 'Conflicts', 'Breaks', 'Replaces'],
                            stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout
    control = Path(tempfile.mkdtemp(prefix='control-', dir=work))
    subprocess.run(['dpkg-deb', '-e', str(deb), str(control)], check=True)
    lines = [f'## {name} ({deb.name})', fields.rstrip()]
    scripts = sorted(p.name for p in control.iterdir() if p.name not in ('control', 'md5sums'))
    lines.append(f"control files: {' '.join(scripts) or 'none'}")
    for script in scripts:
        lines.append(f'--- {script}')
        lines.append((control / script).read_text(errors='replace').rstrip())
    shutil.rmtree(control)
    return lines


def dependency_names(entry):
    names = []
    for field in ('Pre-Depends', 'Depends'):
        for group in entry.get(field, '').split(','):
            first = group.split('|')[0].strip()
            if first:
                names.append(re.split(r'[\s(:]', first, maxsplit=1)[0])
    return names


# --- ELF (64-bit little-endian, as on arm64): SONAME, NEEDED, glibc versions.
def elf_info(path):
    data = path.read_bytes()
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        return None
    phoff, = struct.unpack_from('<Q', data, 0x20)
    phentsize, phnum = struct.unpack_from('<HH', data, 0x36)
    loads, dynamic = [], None
    for i in range(phnum):
        p_type, _, p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from(
            '<IIQQQQQQ', data, phoff + i * phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:
            dynamic = (p_offset, p_filesz)

    def offset(vaddr):
        for start, off, size in loads:
            if start <= vaddr < start + size:
                return off + vaddr - start
        return None

    info = {'soname': None, 'needed': [], 'versions': []}
    if not dynamic:
        return info
    tags = {}
    needed = []
    for i in range(dynamic[1] // 16):
        tag, value = struct.unpack_from('<qQ', data, dynamic[0] + i * 16)
        if tag == 0:
            break
        if tag == 1:
            needed.append(value)
        else:
            tags[tag] = value
    strtab = offset(tags.get(5, 0))
    if strtab is None:
        return info

    def string(index):
        end = data.index(b'\0', strtab + index)
        return data[strtab + index:end].decode(errors='replace')

    info['needed'] = [string(v) for v in needed]
    if 14 in tags:
        info['soname'] = string(tags[14])
    verneed = offset(tags.get(0x6ffffffe, 0)) if 0x6ffffffe in tags else None
    for _ in range(tags.get(0x6fffffff, 0) if verneed is not None else 0):
        _, count, file_index, aux, next_entry = struct.unpack_from('<HHIII', data, verneed)
        library = string(file_index)
        at = verneed + aux
        for _ in range(count):
            _, _, _, name, next_aux = struct.unpack_from('<IHHII', data, at)
            info['versions'].append((library, string(name)))
            if not next_aux:
                break
            at += next_aux
        if not next_entry:
            break
        verneed += next_entry
    info['chips'] = sorted({t.decode() for t in CHIP_TAGS if t in data})
    return info


def glibc_max(versions):
    found = [tuple(int(x) for x in v.split('_', 1)[1].split('.'))
             for _, v in versions if v.startswith('GLIBC_2')]
    return 'GLIBC_' + '.'.join(map(str, max(found))) if found else '-'


_scanned = {}


def scan(deb, work):
    """Report lines for DEB's files, the libraries it provides, and what its ELF files need."""
    if deb in _scanned:
        return _scanned[deb]
    target = Path(tempfile.mkdtemp(prefix='unpack-', dir=work))
    subprocess.run(['dpkg-deb', '-x', str(deb), str(target)], check=True)
    lines, provided, needed = [], set(), {}
    for path in sorted(target.rglob('*')):
        rel = '/' + str(path.relative_to(target))
        if path.is_symlink():
            if '.so' in path.name:
                lines.append(f'  link {rel} -> {path.readlink()}')
                provided.add(path.name)
            continue
        if not path.is_file():
            continue
        info = elf_info(path)
        if info is None:
            if '/doc/' not in rel:
                lines.append(f'  file {rel}')
            continue
        provided.add(path.name)
        if info['soname']:
            provided.add(info['soname'])
        for lib in info['needed']:
            needed.setdefault(lib, set()).add(path.name)
        lines.append(f"  elf  {rel} soname={info['soname'] or '-'} "
                     f"glibc={glibc_max(info['versions'])} chips={','.join(info.get('chips', [])) or '-'}")
        lines.append(f"       needed: {' '.join(info['needed']) or '-'}")
    shutil.rmtree(target)
    _scanned[deb] = lines, provided, needed
    return _scanned[deb]


def report(run, debs):
    lines, provided, needed_all = [], set(), {}
    for name, deb in debs:
        found, libs, needs = scan(deb, run)
        lines += [f'## {name} ({deb.name})'] + found
        provided |= libs
        for lib, users in needs.items():
            needed_all.setdefault(lib, set()).update(users)
    lines.append('## NEEDED by these files and provided by none of them (must come from 26.04)')
    for lib in sorted(set(needed_all) - provided):
        lines.append(f"  {lib}  (by {', '.join(sorted(needed_all[lib]))})")
    return lines


def prepare_keyring(run, key_path):
    """A gpg home and a binary keyring under RUN, from an armored or binary key."""
    gnupg = run / 'gnupg'
    gnupg.mkdir(mode=0o700)
    keyring = run / 'jetson-ota.gpg'
    key = key_path.read_bytes()
    if key.lstrip().startswith(b'-----BEGIN PGP'):
        subprocess.run(['gpg', '--homedir', str(gnupg), '--batch', '--quiet', '--yes',
                        '--dearmor', '--output', str(keyring), str(key_path)], check=True)
    else:
        keyring.write_bytes(key)
    print(f'KEY {key_path} sha256={hashlib.sha256(key).hexdigest()}')
    return gnupg, keyring


def main():
    global RELEASE
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--key', type=Path, required=True,
                        help="NVIDIA's jetson-ota-public.asc (or a binary keyring)")
    parser.add_argument('--platform', default='t194', choices=['t194', 't234'])
    parser.add_argument('--set', default='driver', choices=['driver', 'toolkit', 'tensorrt', 'install', 'video'])
    parser.add_argument('--release', default=RELEASE, choices=['r35.6', 'r32.7'],
                        help="r32.7: JetPack 4's set for the Nano (t210), with --set video or tensorrt")
    parser.add_argument('--reuse', type=Path, action='append', default=[],
                        help='a folder of .debs to copy from when they match the index')
    parser.add_argument('out', type=Path, help='output folder (created; must be empty)')
    args = parser.parse_args()
    RELEASE = args.release
    jetpack4 = RELEASE == 'r32.7'
    if jetpack4:
        if args.set not in ('video', 'tensorrt'):
            fail('--release r32.7 is for --set video or tensorrt only')
        args.platform = 't210'
    for tool in ('gpg', 'gpgv', 'dpkg-deb'):
        if not shutil.which(tool):
            fail(f'{tool} is not installed')
    args.out.mkdir(parents=True, exist_ok=True)
    if any(args.out.iterdir()):
        fail(f'{args.out} is not empty')
    run = Path(tempfile.mkdtemp(prefix='.work-', dir=args.out))
    gnupg, keyring = prepare_keyring(run, args.key)

    picked, elsewhere = [], []
    if args.set == 'driver':
        url, entries, _ = fetch_index(run, gnupg, keyring, args.platform)
        queue = list(PLATFORM_PACKAGES)
        while queue:
            name = queue.pop(0)
            if any(name == p[0] for p in picked):
                continue
            entry = newest(entries, name, args.platform)
            picked.append((name, url, entry))
            queue += [d for d in dependency_names(entry) if d in ALLOWED_DEPENDS]
        url, entries, _ = fetch_index(run, gnupg, keyring, 'common')
        for name in COMMON_PACKAGES:
            picked.append((name, url, newest(entries, name, 'common')))
    elif args.set == 'toolkit':
        url, entries, _ = fetch_index(run, gnupg, keyring, 'common')
        queue = list(TOOLKIT_PACKAGES)
        while queue:
            name = queue.pop(0)
            if any(name == p[0] for p in picked):
                continue
            entry = newest(entries, name, 'common')
            picked.append((name, url, entry))
            queue += [d for d in dependency_names(entry) if re.fullmatch(r'cuda-[a-z0-9-]+-11-4', d)
                      and 'config-common' not in d and d in entries]
    elif args.set == 'install':
        url, entries, _ = fetch_index(run, gnupg, keyring, 'common')
        queue = list(INSTALL_PACKAGES)
        while queue:
            name = queue.pop(0)
            if any(name == p[0] for p in picked):
                continue
            if name.endswith('-dev'):
                print(f'DEV_PACKAGE {name} (a dependency; headers and static libraries)')
            entry = newest(entries, name, 'common')
            picked.append((name, url, entry))
            for field in ('Pre-Depends', 'Depends'):
                for group in filter(str.strip, entry.get(field, '').split(',')):
                    found = resolve(entries, group)
                    if found:
                        queue.append(found)
                    elif group.strip() not in elsewhere:
                        elsewhere.append(group.strip())
        print(f"FROM_UBUNTU {'; '.join(elsewhere) or 'none'}")
    elif args.set == 'video':
        url, entries, _ = fetch_index(run, gnupg, keyring, args.platform)
        video = VIDEO_PACKAGES + (['nvidia-l4t-core'] if jetpack4 else [])
        skip = set(video) | (set() if jetpack4 else ALLOWED_DEPENDS)
        for name in video:
            entry = newest(entries, name, args.platform)
            picked.append((name, url, entry))
            for field in ('Pre-Depends', 'Depends'):
                for group in filter(str.strip, entry.get(field, '').split(',')):
                    first = re.split(r'[\s(:]', group.split('|')[0].strip(), maxsplit=1)[0]
                    if first not in skip and group.strip() not in elsewhere:
                        elsewhere.append(group.strip())
        print(f"DEPENDS_NOT_TAKEN {'; '.join(elsewhere) or 'none'}")
    else:
        url, entries, _ = fetch_index(run, gnupg, keyring, 'common')
        queue = list(TENSORRT_PACKAGES_R32 if jetpack4 else TENSORRT_PACKAGES)
        while queue:
            name = queue.pop(0)
            if any(name == p[0] for p in picked) or name in elsewhere:
                continue
            if name not in entries:
                elsewhere.append(name)
                continue
            entry = newest(entries, name, 'common')
            picked.append((name, url, entry))
            queue += [d for d in dependency_names(entry)
                      if not d.endswith('-dev') and 'config-common' not in d]
        print(f"NOT_IN_COMMON {' '.join(elsewhere) or 'none'}")

    debs, record = [], {}

    def take(name, entry, target):
        print(f"DEB {name} {entry['Version']} size={entry['Size']} sha256={entry['SHA256']}")
        for field in ('Pre-Depends', 'Depends'):
            if field in entry:
                print(f'    {field}: {entry[field]}')
        debs.append((name, target))
        record[name] = {k: entry.get(k) for k in
                        ('Version', 'Filename', 'Size', 'SHA256', 'Depends', 'Pre-Depends')}

    for name, url, entry in picked:
        take(name, entry, obtain(url, entry, args.out, args.reuse))
    driver, driver_versions = [], {}
    if args.set == 'tensorrt' and jetpack4:
        # On the Nano's R35.6 driver: its libcuda and platform libraries, never R32's.
        provided, needed = set(), {}
        for _, deb in debs:
            _, libs, needs = scan(deb, run)
            provided |= libs
            for lib, users in needs.items():
                needed.setdefault(lib, set()).update(users)
        from_driver = sorted(lib for lib in needed if lib not in provided and re.match(r'lib(nv|cu)', lib))
        print(f"FROM_DRIVER {' '.join(from_driver) or 'none'}")
    elif args.set in ('tensorrt', 'install', 'video'):
        if args.set != 'video':  # the video set's index is the platform's already
            url, entries, _ = fetch_index(run, gnupg, keyring, args.platform)
        provided, needed = set(), {}

        def count(deb, needs_too=True):
            _, libs, needs = scan(deb, run)
            provided.update(libs)
            for lib, users in needs.items() if needs_too else ():
                needed.setdefault(lib, set()).update(users)
            return libs

        installed = VIDEO_INSTALLED if args.set == 'video' and not jetpack4 else set()

        def missing():
            return {lib for lib in needed if lib not in provided and lib not in installed
                    and re.match(r'lib(nv|cu)', lib)}

        for _, deb in debs:
            count(deb)
        # The driver set, already on the Nano (R35.6's: not JetPack 4's).
        for name in [] if jetpack4 else sorted(ALLOWED_DEPENDS):
            entry = newest(entries, name, args.platform)
            # For the install, only what the install set itself links must be met.
            count(obtain(url, entry, run, args.reuse), needs_too=args.set == 'tensorrt')
            driver.append((name, run / Path(entry['Filename']).name))
            driver_versions[name] = entry['Version']
            print(f"DRIVER_SET {name} {entry['Version']} (counted as present; not in {args.out})")
        declared = [n for n in elsewhere if n.startswith('nvidia-l4t-') and n not in ALLOWED_DEPENDS]
        candidates = [n for n in PLATFORM_CANDIDATES if n not in declared and n not in ALLOWED_DEPENDS]
        if args.set == 'install':  # nano-l4t packages, never NVIDIA's platform packages
            declared, candidates = [], []
        elif args.set == 'video':  # only a package that provides a missing library
            declared, candidates = [], []
        fetched, declined = {}, set()

        def consider(name, suite, suite_url, suite_entries):
            """Keep NAME from SUITE if declared or if it provides a missing library."""
            wanted = missing()
            if name not in suite_entries:
                print(f'PLATFORM {name}: not in the {suite} {RELEASE} index')
                return False
            entry = newest(suite_entries, name, suite)
            if name not in fetched:
                fetched[name] = obtain(suite_url, entry, run, args.reuse)
            deb = fetched[name]
            libs = scan(deb, run)[1]
            if name in declared or libs & wanted:
                target = args.out / deb.name
                shutil.move(deb, target)
                _scanned[target] = _scanned.pop(deb)
                count(target)
                print(f"PLATFORM {name}: kept for {' '.join(sorted(libs & wanted)) or 'a declared dependency'}")
                take(name, entry, target)
                return True
            if name not in declined:  # said once, though a later pass may ask again
                print(f'PLATFORM {name}: provides none of the missing libraries; left out')
                declined.add(name)
            return False

        for name in declared + candidates:
            if not missing() and name not in declared:
                break
            consider(name, args.platform, url, entries)
        if args.set == 'video':
            # Again while a pass keeps something, since a kept package may link
            # a library that an earlier candidate provides.
            sources = [(args.platform, n) for n in (VIDEO_CANDIDATES_R32 if jetpack4 else VIDEO_CANDIDATES)]
            sources += [('common', n) for n in (VIDEO_COMMON_R32 if jetpack4 else [])]
            indexes = {args.platform: (url, entries)}
            changed = True
            while changed and missing():
                changed = False
                for suite, name in sources:
                    if not missing():
                        break
                    if any(name == taken for taken, _ in debs):
                        continue
                    if suite not in indexes:
                        indexes[suite] = fetch_index(run, gnupg, keyring, suite)[:2]
                    changed |= consider(name, suite, *indexes[suite])
        print(f"UNRESOLVED_NVIDIA={' '.join(sorted(missing())) or 'none'}")
        if args.set == 'install' and missing():
            fail(f"the install set links NVIDIA libraries no package has: {' '.join(sorted(missing()))}")
        if args.set in ('install', 'video'):
            text = []
            for name, deb in debs:
                text += maintainer_text(name, deb, run) + ['']
            (args.out / 'maintainer.txt').write_text('\n'.join(text))
            print(f"INSTALLED_SIZE_KIB={sum(int(e.get('Installed-Size', 0)) for _, _, e in picked)}")
    for source in SET_FILES[args.set]:
        shutil.copy2(source, args.out / source.name)
    (args.out / 'packages.json').write_text(json.dumps({
        'release': RELEASE, 'platform': args.platform, 'set': args.set,
        'key_fingerprint': KEY_FINGERPRINT, 'not_in_common': elsewhere,
        'driver_set': driver_versions, 'packages': record}, indent=2) + '\n')
    lines = report(run, debs + [(f'{name} (driver set; not in this folder)', deb) for name, deb in driver])
    (args.out / 'report.txt').write_text('\n'.join(lines) + '\n')
    sums = []
    for path in sorted(args.out.iterdir()):
        if path.is_file() and path.name != 'SHA256SUMS':
            sums.append(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}')
    (args.out / 'SHA256SUMS').write_text('\n'.join(sums) + '\n')
    for path in (run / 'index').rglob('*'):
        if path.is_file() and path.name in ('Release', 'Release.gpg', 'gpgv-status.txt'):
            dest = args.out / 'index' / path.parent.name
            dest.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest / path.name)
    shutil.rmtree(run)
    print(f'R35_CUDA_FETCH=PASS out={args.out} report={args.out / "report.txt"}')


if __name__ == '__main__':
    sys.exit(main())

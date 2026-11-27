#!/usr/bin/env python3
"""List the GPU architectures JetPack 5's CUDA 11.4, cuDNN and TensorRT libraries carry.

Usage: python3 scripts/host/survey-r35-gpu-archs.py --key jetson-ota-public.asc
           [--control DEB ...] OUT_DIR

The Nano's GPU is compute capability 5.3 (sm_53). A library's kernels run on it
when its fat binaries hold machine code (SASS) for sm_50, sm_52 or sm_53
(same major version, equal or lower minor), or PTX for compute_53 or lower,
which the driver compiles at load time. JetPack 5 targets Xavier (sm_72) and
Orin (sm_87), so this reads, without running anything, which of its
libraries still carry Maxwell code.

Downloads the packages in SURVEY from NVIDIA's signed L4T R35.6 common index
(checked as in fetch-r35-cuda.py) into OUT_DIR/debs, keeping any .deb already
there whose SHA-256 matches, unpacks each in turn, scans every ELF file for
fat binaries, and writes OUT_DIR/archs.txt. --control scans local .debs too,
such as JetPack 4's CUDA 10.2 libcublas10, which must show sm_53. Runs as an
ordinary user; needs gpg, gpgv and dpkg-deb. Writes nothing outside OUT_DIR.
NVIDIA's files stay there and never go into git.
"""
import argparse
import collections
import hashlib
import importlib.util
import mmap
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('fetch_r35_cuda', HERE / 'fetch-r35-cuda.py')
fetch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fetch)

SURVEY = [  # r35.6 common
    'libcublas-11-4', 'libcufft-11-4', 'libcurand-11-4', 'libcusparse-11-4',
    'libcusolver-11-4', 'libnpp-11-4', 'libcudnn8', 'libnvinfer8',
    'libnvinfer-plugin8',
]
FATBIN_MAGIC = b'\x50\xed\x55\xba'
MAXWELL_SASS = {50, 52, 53}


def fatbin_archs(data):
    """Fat binaries in DATA: their count, and SASS and PTX architectures with counts.

    Layout (as read by community fatbin tools; checked on PyPI's cuRAND
    10.3.0.86 for aarch64, sm_35 to sm_90): a 16-byte header (magic, version 1,
    header size 16, payload size), then entries of kind 1 (PTX) or 2 (ELF),
    each with its header size, payload size and, at offset 28, the
    architecture as a number (53 for sm_53).
    """
    sass, ptx, blobs = collections.Counter(), collections.Counter(), 0
    at = data.find(FATBIN_MAGIC)
    while at != -1:
        end = None
        if at + 16 <= len(data):
            _, version, header, size = struct.unpack_from('<IHHQ', data, at)
            if version == 1 and header == 16 and at + 16 + size <= len(data):
                end = at + 16 + size
                blobs += 1
                entry = at + 16
                while entry + 64 <= end:
                    kind, _, entry_header, payload = struct.unpack_from('<HHIQ', data, entry)
                    arch, = struct.unpack_from('<I', data, entry + 28)
                    if kind not in (1, 2) or entry_header < 64 or payload == 0:
                        break
                    (ptx if kind == 1 else sass)[arch] += 1
                    entry += entry_header + payload
        at = data.find(FATBIN_MAGIC, end if end else at + 4)
    return blobs, sass, ptx


def verdict(sass, ptx):
    if not sass and not ptx:
        return 'no GPU code'
    if MAXWELL_SASS & set(sass):
        return 'runs on sm_53 (Maxwell SASS)'
    if any(a <= 53 for a in ptx):
        return 'runs on sm_53 through PTX JIT'
    return 'NOT for sm_53'


def scan_deb(deb, work):
    """Lines for each ELF file with GPU code in DEB, and the package's verdict."""
    target = Path(tempfile.mkdtemp(prefix='unpack-', dir=work))
    subprocess.run(['dpkg-deb', '-x', str(deb), str(target)], check=True)
    lines, all_sass, all_ptx = [], collections.Counter(), collections.Counter()
    for path in sorted(target.rglob('*')):
        if path.is_symlink() or not path.is_file() or path.stat().st_size < 64:
            continue
        with open(path, 'rb') as f:
            if f.read(4) != b'\x7fELF':
                continue
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
                blobs, sass, ptx = fatbin_archs(data)
        if not blobs:
            continue
        all_sass.update(sass)
        all_ptx.update(ptx)
        rel = '/' + str(path.relative_to(target))
        lines.append(f'  {rel}: fatbins={blobs} sass={sorted(sass)} ptx={sorted(ptx)} '
                     f'-> {verdict(sass, ptx)}')
    shutil.rmtree(target)
    return lines, verdict(all_sass, all_ptx), sorted(all_sass), sorted(all_ptx)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--control', type=Path, action='append', default=[],
                        help='a local .deb to scan as well (for example libcublas10)')
    parser.add_argument('out', type=Path)
    args = parser.parse_args()
    for tool in ('gpg', 'gpgv', 'dpkg-deb'):
        if not shutil.which(tool):
            fetch.fail(f'{tool} is not installed')
    debs_dir = args.out / 'debs'
    debs_dir.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='.work-', dir=args.out))
    gnupg, keyring = fetch.prepare_keyring(run, args.key)
    url, entries, _ = fetch.fetch_index(run, gnupg, keyring, 'common')

    report = []
    for deb in args.control:
        lines, result, sass, ptx = scan_deb(deb, run)
        print(f'CONTROL {deb.name}: {result} sass={sass} ptx={ptx}')
        report += [f'## control {deb.name}: {result}'] + lines
    for name in SURVEY:
        if name not in entries:
            print(f'MISSING {name} (not in the common {fetch.RELEASE} index)')
            report.append(f'## {name}: not in the index')
            continue
        entry = fetch.newest(entries, name, 'common')
        target = debs_dir / Path(entry['Filename']).name
        have = target.exists() and target.stat().st_size == int(entry['Size']) and \
            hashlib.sha256(target.read_bytes()).hexdigest() == entry['SHA256']
        if not have:
            data = fetch.download(url + entry['Filename'], target)
            if hashlib.sha256(data).hexdigest() != entry['SHA256'] or len(data) != int(entry['Size']):
                fetch.fail(f'{target.name} does not match the signed index')
        lines, result, sass, ptx = scan_deb(target, run)
        print(f"SURVEY {name} {entry['Version']} size={entry['Size']}: {result} sass={sass} ptx={ptx}")
        report += [f"## {name} {entry['Version']} (sha256 {entry['SHA256']}): {result}"] + lines
    (args.out / 'archs.txt').write_text('\n'.join(report) + '\n')
    shutil.rmtree(run)
    print(f"R35_ARCH_SURVEY=DONE report={args.out / 'archs.txt'}")


if __name__ == '__main__':
    sys.exit(main())

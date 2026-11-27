#!/usr/bin/env python3
"""Read whether JetPack 6's GPU user space still supports the Nano's GPU.

Usage: python3 scripts/host/survey-r36-nano.py --key jetson-ota-public.asc
           [--release r36.4] [--driver-only] OUT_DIR

JetPack 6 (L4T R36) is made for Orin (sm_87). Its GPU kernel driver still
carries the Nano's GM20B (R36.5 sources, 2026-10-17); this
reads, without running anything, whether its user space does too:

- the GPU driver libraries: whether `libcuda` (nvidia-l4t-cuda) lists sm_53
  among its targets and `libnvrm_gpu` (nvidia-l4t-core) names GM20B, from the
  signed t234 index, next to R35.6's same two packages (t194 index), which
  run on the Nano;
- unless --driver-only, the architectures in the fat binaries of CUDA 12's
  libraries, cuDNN 9 and TensorRT 10 (common index), read as
  survey-r35-gpu-archs.py reads JetPack 5's: a library runs on sm_53 if it
  holds SASS for sm_50, sm_52 or sm_53, or PTX for compute_53 or lower.

Checks each index's signature and each .deb's SHA-256 as fetch-r35-cuda.py
does, keeps .debs already in OUT_DIR/debs that match, and writes
OUT_DIR/r36-survey.txt. Runs as an ordinary user; needs gpg, gpgv and
dpkg-deb. Writes nothing outside OUT_DIR. NVIDIA's files stay there and never
go into git.
"""
import argparse
import importlib.util
import mmap
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('survey_r35', HERE / 'survey-r35-gpu-archs.py')
survey = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(survey)
fetch = survey.fetch


def fail(message):
    raise SystemExit('R36_NANO_SURVEY=FAIL: ' + message)


fetch.fail = fail  # also for the index and download checks inside fetch-r35-cuda.py

CONTROL_RELEASE, CONTROL_SUITE = 'r35.6', 't194'
DRIVER_SUITE = 't234'
DRIVER_PACKAGES = ['nvidia-l4t-cuda', 'nvidia-l4t-core']
DRIVER_FILES = re.compile(r'lib(cuda|nvrm_gpu)\.so[.\d]*$')
GM20B = {'gm20b', 'GM20B'}
# The newest package whose whole name matches, CUDA 12's minor version included.
LIBRARIES = [
    ('cuBLAS', r'libcublas-12-\d+'), ('cuFFT', r'libcufft-12-\d+'),
    ('cuRAND', r'libcurand-12-\d+'), ('cuSPARSE', r'libcusparse-12-\d+'),
    ('cuSOLVER', r'libcusolver-12-\d+'), ('NPP', r'libnpp-12-\d+'),
    ('CUDA runtime', r'cuda-cudart-12-\d+'), ('cuDNN 9', r'libcudnn9-cuda-12'),
    ('TensorRT 10', r'libnvinfer10'), ('TensorRT 10 plugins', r'libnvinfer-plugin10'),
]
SM = re.compile(rb'sm_(\d{2,3})\b')


def obtain(url, entry, folder):
    """ENTRY's .deb in FOLDER, kept if it matches the signed index, else downloaded and checked."""
    target = folder / Path(entry['Filename']).name
    size, digest = int(entry['Size']), entry['SHA256']
    if target.is_file() and target.stat().st_size == size and fetch.sha256_file(target) == digest:
        print(f'KEPT {target.name}')
        return target
    fetch.download(url + entry['Filename'], target)
    if target.stat().st_size != size or fetch.sha256_file(target) != digest:
        fail(f'{target.name} does not match the signed index')
    return target


def pick(entries, pattern):
    """The newest entry among the packages whose whole name matches PATTERN, highest name first."""
    names = [n for n in entries if re.fullmatch(pattern, n)]
    if not names:
        return None
    best = max(names, key=lambda n: tuple(int(x) for x in re.findall(r'\d+', n)))
    return fetch.newest(entries, best, 'common')


def driver_files(deb, work):
    """For each libcuda and libnvrm_gpu file in DEB: its name, the chip names and the sm_ targets it holds."""
    target = Path(tempfile.mkdtemp(prefix='unpack-', dir=work))
    subprocess.run(['dpkg-deb', '-x', str(deb), str(target)], check=True)
    found = []
    for path in sorted(target.rglob('*')):
        if path.is_symlink() or not path.is_file() or not DRIVER_FILES.search(path.name) \
                or not path.stat().st_size:
            continue
        with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
            chips = sorted({t.decode() for t in fetch.CHIP_TAGS if data.find(t) != -1})
            sms = sorted({int(m) for m in SM.findall(data)})
        found.append((path.name, chips, sms))
    shutil.rmtree(target)
    return found


def drivers(run, keys, release, suite, debs):
    """Report lines for RELEASE's GPU driver packages, and whether they name the Nano (None: unread)."""
    fetch.RELEASE = release
    url, entries, _ = fetch.fetch_index(run / release, *keys, suite)
    lines, seen = [], {}
    for name in DRIVER_PACKAGES:
        if name not in entries:
            print(f'DRIVER {release} {name}: not in the {suite} index')
            lines.append(f'## {release} {name}: not in the {suite} index')
            continue
        entry = fetch.newest(entries, name, suite)
        deb = obtain(url, entry, debs)
        lines.append(f"## {release} {name} {entry['Version']} (sha256 {entry['SHA256']})")
        for file, chips, sms in driver_files(deb, run):
            text = f"{file} chips={','.join(chips) or '-'} sm={','.join(map(str, sms)) or '-'}"
            print(f"DRIVER {release} {name} {entry['Version']}: {text}")
            lines.append('  ' + text)
            seen[file.split('.so')[0]] = (chips, sms)
    if 'libcuda' not in seen or 'libnvrm_gpu' not in seen:
        missing = ' and '.join(lib for lib in ('libcuda', 'libnvrm_gpu') if lib not in seen)
        return lines, None, f'{missing} not found in {" or ".join(DRIVER_PACKAGES)}'
    sm53, gm20b = 53 in seen['libcuda'][1], bool(GM20B & set(seen['libnvrm_gpu'][0]))
    return lines, sm53 and gm20b, f'libcuda sm_53 {sm53}, libnvrm_gpu GM20B {gm20b}'


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--key', type=Path, required=True,
                        help="NVIDIA's jetson-ota-public.asc (or a binary keyring)")
    parser.add_argument('--release', default='r36.4', help='the R36 index to read (default r36.4)')
    parser.add_argument('--driver-only', action='store_true', help='read only the GPU driver libraries')
    parser.add_argument('out', type=Path, help='output folder (created; .debs kept in OUT/debs)')
    args = parser.parse_args()
    if not re.fullmatch(r'r36\.\d+', args.release):
        fail(f'--release {args.release}: expected r36.N')
    for tool in ('gpg', 'gpgv', 'dpkg-deb'):
        if not shutil.which(tool):
            fail(f'{tool} is not installed')
    debs = args.out / 'debs'
    debs.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='.work-', dir=args.out))
    try:
        keys = fetch.prepare_keyring(run, args.key)
        report, control, control_text = drivers(run, keys, CONTROL_RELEASE, CONTROL_SUITE, debs)
        lines, named, text = drivers(run, keys, args.release, DRIVER_SUITE, debs)
        report += lines
        if not control:
            verdict = f'unreliable: the control {CONTROL_RELEASE}, which runs on the Nano, gives {control_text}'
        elif named is None:
            verdict = f'unread: {text}'
        else:
            verdict = ('names the Nano' if named else 'does not name the Nano') + f' ({text})'
        print(f'DRIVER_VERDICT {args.release}: {verdict}')
        report.append(f'## driver verdict {args.release}: {verdict}'
                      + (f' (control {CONTROL_RELEASE}: {control_text})' if control else ''))

        if not args.driver_only:
            fetch.RELEASE = args.release
            url, entries, _ = fetch.fetch_index(run / f'{args.release}-libs', *keys, 'common')
            for label, pattern in LIBRARIES:
                entry = pick(entries, pattern)
                if entry is None:
                    stem = re.split(r'-?\d', pattern)[0]
                    near = sorted(n for n in entries if n.startswith(stem))[:8]
                    print(f"MISSING {label}: {pattern} is not in the common {args.release} index "
                          f"(similar: {' '.join(near) or 'none'})")
                    report.append(f'## {label}: {pattern} is not in the index')
                    continue
                deb = obtain(url, entry, debs)
                lines, result, sass, ptx = survey.scan_deb(deb, run)
                print(f"SURVEY {label} {entry['Package']} {entry['Version']} size={entry['Size']}: "
                      f'{result} sass={sass} ptx={ptx}')
                report.append(f"## {label} {entry['Package']} {entry['Version']} "
                              f"(sha256 {entry['SHA256']}): {result}")
                report += lines
    except urllib.error.URLError as error:
        fail(f'download failed ({error}); is {args.release} published? r36.4 is JetPack 6.1 and 6.2')
    finally:
        shutil.rmtree(run)
    (args.out / 'r36-survey.txt').write_text('\n'.join(report) + '\n')
    print(f"R36_NANO_SURVEY=DONE report={args.out / 'r36-survey.txt'}")


if __name__ == '__main__':
    sys.exit(main())

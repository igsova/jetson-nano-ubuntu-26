#!/usr/bin/env python3
"""Download what probe-cuda12.sh needs to try CUDA 12 on the Nano's 5.10 kernel.

Usage: python3 scripts/host/fetch-cuda12-probe.py --key jetson-ota-public.asc
           [--reuse DIR ...] OUT_DIR

The Nano runs JetPack 5's GPU kernel driver (L4T R35.6 on 5.10). JetPack 6's
CUDA 12.6 libraries and cuDNN 9 carry sm_53 code (survey-r36-nano.py,
2026-10-17); this fetches two CUDA 12 drivers to try under
that kernel, and the libraries to test them with, into three folders:
- r36-driver/: JetPack 6's CUDA 12.6 driver, nvidia-l4t-cuda, with
  nvidia-l4t-core (its GPU and memory libraries) and nvidia-l4t-3d-core (for
  the PTX compiler) from the signed t234 r36.4 index, and the nvidia-l4t-*
  packages they depend on among R36_ALLOWED; others are listed, not taken;
- cuda12-libs/: CUDA 12's runtime, cuBLAS, NVRTC and cuDNN 9 from the signed
  common r36.4 index (CUDA_LIBRARIES; the survey's packages);
- compat-12-2/: NVIDIA's CUDA 12.2 upgrade driver for JetPack 5
  (cuda-compat-12-2, the newest CUDA that NVIDIA's CUDA for Tegra notes give
  JetPack 5) and CUDA 12.2's runtime, from NVIDIA's CUDA repository for
  Jetson (CUDA_REPO). Its key is downloaded from that repository and used
  only if its fingerprint is CUDA_KEY_FINGERPRINT; the Release file's
  signature is checked against it with gpgv, and the Packages index against
  the Release file.
The Jetson indexes are checked as fetch-r35-cuda.py checks them, against
NVIDIA's Jetson key. Each .deb is checked against its index's SHA-256 and
size; --reuse names folders whose matching .debs (such as the survey's
OUT_DIR/debs) are copied instead of downloaded.

OUT_DIR (created; must be empty) also receives probe-cuda12.sh,
cuda11_probe.py and cuda_libs_probe.py; packages.json; report.txt, with
fetch-r35-cuda.py's ELF report for each folder (SONAME, NEEDED, newest glibc
version, GPU names) and the NEEDED libraries none of the folder's packages
provides; the checked index files under index/; and SHA256SUMS over every
file, by path, checked again on the Nano.

Runs as an ordinary user; needs gpg, gpgv and dpkg-deb. Writes nothing outside
OUT_DIR (gpg runs with a temporary home in OUT_DIR, removed at the end).
NVIDIA's files stay in OUT_DIR and never go into git.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('fetch_r35', HERE / 'fetch-r35-cuda.py')
fetch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fetch)

R36_RELEASE = 'r36.4'
R36_PACKAGES = ['nvidia-l4t-cuda', 'nvidia-l4t-core', 'nvidia-l4t-3d-core']
R36_ALLOWED = {'nvidia-l4t-cuda', 'nvidia-l4t-core', 'nvidia-l4t-3d-core', 'nvidia-l4t-nvsci'}
# The newest package whose whole name matches, CUDA 12's minor version included.
CUDA_LIBRARIES = [r'cuda-cudart-12-\d+', r'libcublas-12-\d+', r'cuda-nvrtc-12-\d+', r'libcudnn9-cuda-12']
CUDA_REPO = 'https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/arm64/'
CUDA_KEY_FILE = '3bf863cc.pub'
# cudatools <cudatools@nvidia.com>, the CUDA repositories' signing key since 2022.
CUDA_KEY_FINGERPRINT = 'EB693B3035CD5710E231E123A4B469963BF863CC'
COMPAT_PACKAGES = ['cuda-compat-12-2', 'cuda-cudart-12-2']
REPO = Path(__file__).resolve().parents[2]
PROBE_FILES = [REPO / 'scripts/jetson/probes/probe-cuda12.sh', REPO / 'tests/cuda/cuda11_probe.py',
               REPO / 'tests/cuda/cuda_libs_probe.py']


def fail(message):
    raise SystemExit('CUDA12_FETCH=FAIL: ' + message)


fetch.fail = fail  # also for the index and download checks inside fetch-r35-cuda.py


def cuda_keyring(run):
    """A keyring with the CUDA repository's key, used only if its fingerprint is the pinned one."""
    gnupg = run / 'gnupg-cuda'
    gnupg.mkdir(mode=0o700)
    key = run / CUDA_KEY_FILE
    fetch.download(CUDA_REPO + CUDA_KEY_FILE, key)
    # --import-options show-only, as GnuPG 2.2.4 (JetPack 4's) has no --show-keys.
    shown = subprocess.run(['gpg', '--homedir', str(gnupg), '--batch', '--with-colons',
                            '--import-options', 'show-only', '--import', str(key)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                           check=True).stdout
    fingerprints = [line.split(':')[9] for line in shown.splitlines() if line.startswith('fpr:')]
    print(f"CUDA_KEY {CUDA_KEY_FILE} sha256={fetch.sha256_file(key)} fingerprints={' '.join(fingerprints)}")
    if not fingerprints or fingerprints[0] != CUDA_KEY_FINGERPRINT:
        fail(f'{CUDA_KEY_FILE} is not the key {CUDA_KEY_FINGERPRINT}')
    keyring = run / 'cuda.gpg'
    subprocess.run(['gpg', '--homedir', str(gnupg), '--batch', '--quiet', '--yes', '--dearmor',
                    '--output', str(keyring), str(key)], check=True)
    return gnupg, keyring


def flat_index(run, gnupg, keyring):
    """CUDA_REPO's entries ({name: [fields]}), from its signed Release file (a flat repository)."""
    folder = run / 'index' / 'cuda'
    folder.mkdir(parents=True)
    release = fetch.download(CUDA_REPO + 'Release', folder / 'Release')
    fetch.download(CUDA_REPO + 'Release.gpg', folder / 'Release.gpg')
    status = subprocess.run(
        ['gpgv', '--homedir', str(gnupg), '--status-fd', '1', '--keyring', str(keyring),
         str(folder / 'Release.gpg'), str(folder / 'Release')],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    (folder / 'gpgv-status.txt').write_text(status.stdout + status.stderr)
    valid = [line.split() for line in status.stdout.splitlines() if line.startswith('[GNUPG:] VALIDSIG ')]
    if status.returncode or not valid or valid[0][-1] != CUDA_KEY_FINGERPRINT:
        fail(f'the CUDA repository Release signature did not verify against {CUDA_KEY_FINGERPRINT}')
    text = release.decode()
    sums, in_sha = {}, False
    for line in text.splitlines():
        if not line.startswith(' '):
            in_sha = line.startswith('SHA256:')
            continue
        if in_sha:
            digest, size, name = line.split()
            sums[name] = (digest, int(size))
    for name, decode in (('Packages.gz', gzip.decompress), ('Packages', lambda d: d)):
        if name in sums:
            data = fetch.download(CUDA_REPO + name, folder / name)
            if hashlib.sha256(data).hexdigest() != sums[name][0] or len(data) != sums[name][1]:
                fail(f'the CUDA repository {name} does not match its signed Release entry')
            packages = decode(data).decode()
            break
    else:
        fail('the CUDA repository Release lists no Packages index')
    entries = {}
    for block in packages.split('\n\n'):
        values = dict(line.split(': ', 1) for line in block.splitlines() if ': ' in line and not line.startswith(' '))
        if 'Package' in values:
            filename = values.get('Filename', '')
            values['Filename'] = filename[2:] if filename.startswith('./') else filename
            entries.setdefault(values['Package'], []).append(values)
    fields = dict(line.split(': ', 1) for line in text.splitlines() if ': ' in line and not line.startswith(' '))
    print(f"INDEX cuda {CUDA_REPO}: Label={fields.get('Label', '?')} Date={fields.get('Date', '?')} "
          f'packages={len(entries)} signed_by={valid[0][2]} primary={valid[0][-1]}')
    return entries


def pick(entries, pattern, suite):
    names = [n for n in entries if re.fullmatch(pattern, n)]
    if not names:
        fail(f'no package matching {pattern} in the {suite} {fetch.RELEASE} index')
    best = max(names, key=lambda n: tuple(int(x) for x in re.findall(r'\d+', n)))
    return best, fetch.newest(entries, best, suite)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--key', type=Path, required=True,
                        help="NVIDIA's jetson-ota-public.asc (or a binary keyring)")
    parser.add_argument('--reuse', type=Path, action='append', default=[],
                        help='a folder of .debs to copy from when they match the index')
    parser.add_argument('out', type=Path, help='output folder (created; must be empty)')
    args = parser.parse_args()
    for tool in ('gpg', 'gpgv', 'dpkg-deb'):
        if not shutil.which(tool):
            fail(f'{tool} is not installed')
    args.out.mkdir(parents=True, exist_ok=True)
    if any(args.out.iterdir()):
        fail(f'{args.out} is not empty')
    run = Path(tempfile.mkdtemp(prefix='.work-', dir=args.out))
    try:
        gnupg, keyring = fetch.prepare_keyring(run, args.key)
        fetch.RELEASE = R36_RELEASE

        picked = {'r36-driver': [], 'cuda12-libs': [], 'compat-12-2': []}  # folder: [(name, url, entry)]
        not_taken = []
        url, entries, _ = fetch.fetch_index(run, gnupg, keyring, 't234')
        queue = list(R36_PACKAGES)
        while queue:
            name = queue.pop(0)
            if any(name == p[0] for p in picked['r36-driver']):
                continue
            entry = fetch.newest(entries, name, 't234')
            picked['r36-driver'].append((name, url, entry))
            for dep in fetch.dependency_names(entry):
                if dep in R36_ALLOWED:
                    queue.append(dep)
                elif dep.startswith('nvidia-l4t-') and dep not in not_taken:
                    not_taken.append(dep)
        print(f"DEPENDS_NOT_TAKEN {' '.join(not_taken) or 'none'}")
        url, entries, _ = fetch.fetch_index(run, gnupg, keyring, 'common')
        for pattern in CUDA_LIBRARIES:
            name, entry = pick(entries, pattern, 'common')
            picked['cuda12-libs'].append((name, url, entry))
        entries = flat_index(run, *cuda_keyring(run))
        for name in COMPAT_PACKAGES:
            if name not in entries:
                fail(f'{name} is not in the CUDA repository index')
            picked['compat-12-2'].append((name, CUDA_REPO, fetch.newest(entries, name, 'cuda')))

        record, report, total = {}, [], 0
        for folder, items in picked.items():
            (args.out / folder).mkdir()
            debs = []
            for name, source, entry in items:
                print(f"DEB {folder} {name} {entry['Version']} size={entry['Size']} sha256={entry['SHA256']}")
                for field in ('Pre-Depends', 'Depends'):
                    if field in entry:
                        print(f'    {field}: {entry[field]}')
                deb = fetch.obtain(source, entry, args.out / folder, args.reuse)
                debs.append((name, deb))
                total += int(entry['Size'])
                record.setdefault(folder, {})[name] = {k: entry.get(k) for k in
                                                       ('Version', 'Filename', 'Size', 'SHA256', 'Depends')}
            report += [f'# {folder}'] + fetch.report(run, debs) + ['']
        for source in PROBE_FILES:
            shutil.copy2(source, args.out / source.name)
        (args.out / 'packages.json').write_text(json.dumps({
            'r36_release': R36_RELEASE, 'jetson_key_fingerprint': fetch.KEY_FINGERPRINT,
            'cuda_repo': CUDA_REPO, 'cuda_key_fingerprint': CUDA_KEY_FINGERPRINT,
            'depends_not_taken': not_taken, 'packages': record}, indent=2) + '\n')
        (args.out / 'report.txt').write_text('\n'.join(report))
        for path in (run / 'index').rglob('*'):
            if path.is_file() and path.name in ('Release', 'Release.gpg', 'gpgv-status.txt'):
                dest = args.out / 'index' / path.parent.name
                dest.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, dest / path.name)
    finally:
        shutil.rmtree(run)
    sums = [f'{fetch.sha256_file(path)}  {path.relative_to(args.out)}'
            for path in sorted(args.out.rglob('*')) if path.is_file() and path.name != 'SHA256SUMS']
    (args.out / 'SHA256SUMS').write_text('\n'.join(sums) + '\n')
    print(f'DOWNLOAD_BYTES={total}')
    print(f'CUDA12_FETCH=PASS out={args.out} report={args.out / "report.txt"}')


if __name__ == '__main__':
    sys.exit(main())

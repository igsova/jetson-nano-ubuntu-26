"""Stand-ins for NVIDIA's package servers, for nano26-convert's host tests.

make(folder, convert) writes, under folder/servers, copies laid out as
NVIDIA's Jetson repository (the five suites and releases the converter
reads), NVIDIA's CUDA repository for Jetson and Ubuntu's ports pool, with
small .debs of the packages the converter takes (same names and versions as
the real ones, a stand-in file each), Packages and Release files signed by
two keys made here, and returns the test plan for --nvidia-test-plan: the
stand-in URLs, the keys' fingerprints and the stand-ins' SHA-256 in place of
the repository's pins. Needs gpg and dpkg-deb. CONVERT is the converter
loaded as a module (test_nano26_convert.load_tool()), read for the package
names and versions.
"""
import gzip
import hashlib
import os
import shutil
import subprocess

JETSON = 'https://repo.download.nvidia.com/jetson/'
CUDA = 'https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/arm64/'
PORTS = 'https://ports.ubuntu.com/ubuntu-ports/'
TRT82 = [  # JetPack 4's TensorRT 8.2 set, with the dependencies the converter walks (and skips)
    ('libnvinfer-bin', '8.2.1-1+cuda10.2', 'libnvinfer8 (= 8.2.1-1+cuda10.2), libnvinfer-plugin8, libnvparsers8, '
                                           'libnvonnxparsers8'),
    ('libnvinfer8', '8.2.1-1+cuda10.2', 'libcudnn8, libcublas10, cuda-cudart-10-2'),
    ('libnvinfer-plugin8', '8.2.1-1+cuda10.2', 'libnvinfer8 (= 8.2.1-1+cuda10.2)'),
    ('libnvonnxparsers8', '8.2.1-1+cuda10.2', 'libnvinfer8 (= 8.2.1-1+cuda10.2)'),
    ('libnvparsers8', '8.2.1-1+cuda10.2', 'libnvinfer8 (= 8.2.1-1+cuda10.2)'),
    ('libcudnn8', '8.2.1.32-1+cuda10.2', ''),
    ('libcublas10', '10.2.3.300-1', 'cuda-toolkit-config-common'),
    ('cuda-cudart-10-2', '10.2.300-1', 'cuda-toolkit-10-2-config-common'),
    ('cuda-nvrtc-10-2', '10.2.300-1', ''),
    ('libnvinfer-dev', '8.2.1-1+cuda10.2', 'libnvinfer8 (= 8.2.1-1+cuda10.2)'),       # not taken: -dev
    ('cuda-toolkit-10-2-config-common', '10.2.300-1', ''),                             # not taken
    ('libnvinfer8', '8.0.1-1+cuda10.2', ''),                                           # an older entry
]
CUDA12_COMMON = [  # JetPack 6's common r36.4: enough for build-nano-cuda12-debs.py's choice
    ('cuda-cudart-12-6', '12.6.68-1', ''),
    ('cuda-cudart-12-4', '12.4.99-1', ''),
    ('cuda-libraries-12-6', '12.6.11-1', 'cuda-cudart-12-6 (>= 12.6.68), libcublas-12-6, cuda-nvrtc-12-6, '
                                         'libcufile-12-6, cuda-toolkit-12-config-common'),
    ('libcublas-12-6', '12.6.1.4-1', ''),
    ('cuda-nvrtc-12-6', '12.6.68-1', ''),
    ('libcufile-12-6', '1.11.1.6-1', ''),
    ('cuda-toolkit-12-config-common', '12.6.68-1', ''),
    ('libcudnn9-cuda-12', '9.3.0.75-1', ''),
    ('cuda-compiler-12-6', '12.6.11-1', 'cuda-nvcc-12-6'),
    ('cuda-nvcc-12-6', '12.6.68-1', 'cuda-cudart-dev-12-6, build-essential'),
    ('cuda-libraries-dev-12-6', '12.6.11-1', 'cuda-cudart-dev-12-6, libcublas-dev-12-6'),
    ('cuda-cudart-dev-12-6', '12.6.68-1', 'cuda-cudart-12-6'),
    ('libcublas-dev-12-6', '12.6.1.4-1', 'libcublas-12-6'),
    ('libcudnn9-dev-cuda-12', '9.3.0.75-1', 'libcudnn9-cuda-12'),
]
COMPAT = ('cuda-compat-12-2', '12.2.34086590-1', '')


def sh(*cmd, **kw):
    return subprocess.run(list(cmd), check=True, stdout=subprocess.PIPE, universal_newlines=True, **kw).stdout


def sha256(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def make_key(gnupg, name):
    """A signing key; its fingerprint."""
    sh('gpg', '--homedir', gnupg, '--batch', '--pinentry-mode', 'loopback', '--passphrase', '',
       '--quick-gen-key', name, 'ed25519', 'sign', 'never', stderr=subprocess.DEVNULL)
    for line in sh('gpg', '--homedir', gnupg, '--batch', '--with-colons', '--list-keys', name,
                   stderr=subprocess.DEVNULL).splitlines():
        if line.startswith('fpr:'):
            return line.split(':')[9]
    raise RuntimeError('no key made for ' + name)


def make_deb(path, name, version, arch='arm64'):
    """A .deb with one stand-in file and no dependencies (an index entry may still list some)."""
    tree = path + '.tree'
    os.makedirs(os.path.join(tree, 'DEBIAN'))
    control = 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: stand-in <nobody@example.invalid>\n' \
              'Description: stand-in for %s\n' % (name, version, arch, name)
    with open(os.path.join(tree, 'DEBIAN', 'control'), 'w') as f:
        f.write(control)
    doc = os.path.join(tree, 'usr', 'share', 'doc', name)
    os.makedirs(doc)
    with open(os.path.join(doc, 'stand-in'), 'w') as f:
        f.write('%s %s, a stand-in for nano26-convert\'s tests\n' % (name, version))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sh('dpkg-deb', '--root-owner-group', '-Zgzip', '--build', tree, path, stderr=subprocess.DEVNULL)
    shutil.rmtree(tree)
    return path


def write_index(folder, entries, release_dir, packages_rel, key, gnupg, flat=False):
    """Packages (and .gz) under release_dir, Release with their SHA-256, Release.gpg signed by KEY."""
    text = ''
    for e in entries:
        text += ''.join('%s: %s\n' % (k, e[k]) for k in ('Package', 'Version', 'Architecture', 'Depends',
                                                         'Filename', 'Size', 'SHA256', 'Description') if e.get(k))
        text += '\n'
    data = text.encode()
    names = [(packages_rel, data), (packages_rel + '.gz', gzip.compress(data))]
    for rel, blob in names:
        os.makedirs(os.path.dirname(os.path.join(release_dir, rel)), exist_ok=True)
        with open(os.path.join(release_dir, rel), 'wb') as f:
            f.write(blob)
    release = 'Origin: stand-in\nLabel: stand-in %s\nDate: Mon, 19 Oct 2026 00:00:00 UTC\n' \
              'Architectures: arm64\n%sSHA256:\n' % (folder, '' if flat else 'Components: main\n')
    release += ''.join(' %s %d %s\n' % (hashlib.sha256(blob).hexdigest(), len(blob), rel) for rel, blob in names)
    with open(os.path.join(release_dir, 'Release'), 'w') as f:
        f.write(release)
    sh('gpg', '--homedir', gnupg, '--batch', '--yes', '--local-user', key, '--output',
       os.path.join(release_dir, 'Release.gpg'), '--detach-sign', os.path.join(release_dir, 'Release'),
       stderr=subprocess.DEVNULL)


def entry(path, rel, name, version, arch, depends):
    return {'Package': name, 'Version': version, 'Architecture': arch, 'Depends': depends, 'Filename': rel,
            'Size': os.path.getsize(path), 'SHA256': sha256(path), 'Description': 'stand-in'}


def make(folder, convert):
    servers = os.path.join(folder, 'servers')
    gnupg = os.path.join(folder, 'gnupg')
    os.makedirs(gnupg, mode=0o700)
    jetson_key = make_key(gnupg, 'Stand-in Jetson <jetson@example.invalid>')
    cuda_key = make_key(gnupg, 'Stand-in CUDA <cuda@example.invalid>')
    root = {JETSON: os.path.join(servers, JETSON.split('://', 1)[1]),
            CUDA: os.path.join(servers, CUDA.split('://', 1)[1]),
            PORTS: os.path.join(servers, PORTS.split('://', 1)[1])}
    l = convert.l4t()

    suites = {('t210', 'r32.7'): [], ('common', 'r32.7'): [], ('t194', 'r35.6'): [], ('common', 'r35.6'): [],
              ('common', 'r36.4'): []}
    pins = {'NVIDIA_DEBS': {}, 'VIDEO_NVIDIA_DEBS': {}, 'R35_NVIDIA_DEBS': {}, 'R35_VIDEO_DEBS': {},
            'UBUNTU_DEBS': {}}

    def jetson_deb(suite, release, name, version, arch='arm64', depends=''):
        rel = 'pool/main/%s/%s/%s_%s_%s.deb' % (name[0], name, name, version, arch)
        path = make_deb(os.path.join(root[JETSON], suite, rel), name, version, arch)
        suites[(suite, release)].append(entry(path, rel, name, version, arch, depends))
        return sha256(path)

    for table in ('NVIDIA_DEBS', 'VIDEO_NVIDIA_DEBS'):
        for name in getattr(l, table):
            pins[table][name] = jetson_deb('t210', 'r32.7', name, l.L4T)
    for table in ('R35_NVIDIA_DEBS', 'R35_VIDEO_DEBS'):
        for name in getattr(l, table):
            pins[table][name] = jetson_deb('t194', 'r35.6', name, l.R35_L4T)
    jetson_deb('t194', 'r35.6', 'nvidia-l4t-core', '35.6.0-20240828200000')   # another version, not taken
    install = {}
    for filename in sorted(convert.install_pins()):
        name, version, arch = filename[:-len('.deb')].split('_')
        install[filename] = jetson_deb('common', 'r35.6', name, version, arch)
    for name, version, depends in TRT82:
        jetson_deb('common', 'r32.7', name, version, depends=depends)
    for name, version, depends in CUDA12_COMMON:
        jetson_deb('common', 'r36.4', name, version, depends=depends)
    for name, (version, _) in sorted(l.UBUNTU_DEBS.items()):
        path = os.path.join(root[PORTS], convert.FOCAL_POOL[name], '%s_%s_arm64.deb' % (name, version.split(':', 1)[-1]))
        make_deb(path, name, version)
        pins['UBUNTU_DEBS'][name] = [version, sha256(path)]
    for (suite, release), entries in suites.items():
        write_index(suite, entries, os.path.join(root[JETSON], suite, 'dists', release),
                    'main/binary-arm64/Packages', jetson_key, gnupg)

    name, version, depends = COMPAT
    rel = '%s_%s_arm64.deb' % (name, version)
    path = make_deb(os.path.join(root[CUDA], rel), name, version)
    write_index('cuda', [entry(path, './' + rel, name, version, 'arm64', depends)], root[CUDA], 'Packages',
                cuda_key, gnupg, flat=True)
    with open(os.path.join(root[CUDA], convert.cuda12().probe.CUDA_KEY_FILE), 'w') as f:
        f.write(sh('gpg', '--homedir', gnupg, '--armor', '--export', cuda_key))
    jetson_asc = os.path.join(folder, 'jetson-ota-public.asc')
    with open(jetson_asc, 'w') as f:
        f.write(sh('gpg', '--homedir', gnupg, '--armor', '--export', jetson_key))
    plan = {
        'sources': {url: 'file://' + path + '/' for url, path in root.items()},
        'fingerprints': {'jetson': jetson_key, 'cuda': cuda_key},
        'l4t': pins,
        'install_pins': install,
    }
    return plan, jetson_asc

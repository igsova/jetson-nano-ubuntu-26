#!/usr/bin/env python3
"""Host test for scripts/jetson/convert/nano26-convert, run on a PC (no Nano).

Usage: python3 tests/convert/test_nano26_convert.py [--keep]

Builds a stand-in Nano in a temporary folder: a sparse source card image
with a 14-partition GPT made by sfdisk (APP first by number, last on the card;
the boot partitions' starts and sizes approximate NVIDIA's Nano SD layout,
from memory: the converter reads whatever table the card has), and a tree
with the device tree, L4T release file, dpkg status, mountinfo, sysfs block
devices (a USB card reader, a non-USB disk and the boot card), mounts, the
account, network profiles and USB 3 firmware, and a stand-in kernel folder
laid out as build-jp5-kernel.sh's out/, and stand-ins for NVIDIA's servers
with keys made here (nvidia_stand_in.py), which every run names with
--nvidia-test-plan. Then runs the converter in each case below, up to the
point where it would write, and checks its exit status and lines
(test_convert_image.py tests the writing). It packs the stand-in kernel with
pack-jp5-kernel.sh, twice (the same file), serves it in place of the kernel
release and has the converter download, check and unpack it in-process, and
refuse it under another SHA-256. It also runs the converter's
NVIDIA step in-process against the stand-ins and checks the copy of the
repositories it saves: its layout, each step's set, and that
build-nano-cuda12-debs.py --mirror (its index checks, package choice and
downloads) and build-nano-l4t-debs.py and package-trt82.sh (their file
names) read it; and that nano26-stage2 writes the reference card's desktop settings as
add-u26-desktop.sh, add-u26-gpu-desktop.sh and add-u26-unity.sh do. The last
line is NANO26_CONVERT_TEST=PASS or FAIL. Needs sfdisk (util-linux), gpg,
gpgv, dpkg-deb, GNU tar, xz and Python 3, and 11 GB free in the temporary
folder (TMPDIR): the image cases check that an image could be built there,
though none is.
"""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TOOL = os.path.join(REPO, 'scripts', 'jetson', 'convert', 'nano26-convert')
PACK = os.path.join(REPO, 'scripts', 'host', 'pack-jp5-kernel.sh')
STAGE2 = os.path.join(REPO, 'scripts', 'jetson', 'convert', 'nano26-stage2')
KEY = '/etc/apt/trusted.gpg.d/jetson-ota-public.asc'
PLAN = None  # the stand-ins' test plan, which run() passes
GIB = 1024 ** 3
BOOT_PARTS = [  # number, name, start, sectors
    (2, 'TBC', 2048, 256), (3, 'RP1', 4096, 896), (4, 'EBT', 6144, 1152), (5, 'WB0', 8192, 128),
    (6, 'BPF', 10240, 384), (7, 'BPF-DTB', 12288, 768), (8, 'FX', 14336, 128), (9, 'TOS', 16384, 896),
    (10, 'DTB', 18432, 896), (11, 'LNX', 20480, 1536), (12, 'EKS', 22528, 128), (13, 'BMP', 24576, 592),
    (14, 'RP4', 26624, 256),
]
APP_START = 28672
LINUX = '0FC63DAF-8483-4772-8E79-3D69D8477DE4'
failures = []


def write(root, rel, data, mode=None):
    p = os.path.join(root, rel.lstrip('/'))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb' if isinstance(data, bytes) else 'w') as f:
        f.write(data)
    if mode is not None:
        os.chmod(p, mode)


def make_source(path, size=32 * GIB):
    with open(path, 'wb') as f:
        f.truncate(size)
    lines = ['label: gpt', 'unit: sectors', '']
    lines.append('src1 : start=%d, size=%d, type=%s, name="APP"' % (APP_START, (size // 512) - 34 - APP_START - 2048, LINUX))
    for n, name, start, sectors in BOOT_PARTS:
        lines.append('src%d : start=%d, size=%d, type=%s, name="%s"' % (n, start, sectors, LINUX, name))
    subprocess.run(['sfdisk', '--quiet', '--no-reread', '--no-tell-kernel', path],
                   input='\n'.join(lines) + '\n', universal_newlines=True, check=True)
    return json.loads(subprocess.run(['sfdisk', '--json', path], stdout=subprocess.PIPE,
                                     universal_newlines=True, check=True).stdout)['partitiontable']


def make_root(root):
    write(root, '/proc/device-tree/compatible',
          b'nvidia,p3449-0000-b00+p3448-0000-b00\0nvidia,jetson-nano\0nvidia,tegra210\0')
    write(root, '/proc/device-tree/model', b'NVIDIA Jetson Nano Developer Kit\0')
    write(root, '/etc/nv_tegra_release',
          '# R32 (release), REVISION: 7.6, GCID: 38171779, BOARD: t210ref, EABI: aarch64, DATE: Tue Nov  5 07:46:14 UTC 2024\n')
    write(root, '/var/lib/dpkg/status', '\n\n'.join([
        'Package: bash\nStatus: install ok installed\nVersion: 4.4.18-2ubuntu1.3',
        'Package: nvidia-l4t-bootloader\nStatus: install ok installed\nArchitecture: arm64\nVersion: 32.7.6-20241104234540\nDescription: NVIDIA Bootloader Package\n multi-line description',
        'Package: nvidia-l4t-core\nStatus: install ok installed\nVersion: 32.7.6-20241104234540',
    ]) + '\n')
    write(root, '/proc/self/mountinfo',
          '21 1 179:1 / / rw,relatime shared:1 - ext4 /dev/mmcblk0p1 rw\n'
          '22 21 0:5 / /dev rw,nosuid shared:2 - devtmpfs devtmpfs rw\n')
    write(root, '/sys/class/block/mmcblk0p1/dev', '179:1\n')
    write(root, '/proc/mounts', '/dev/mmcblk0p1 / ext4 rw,relatime 0 0\ntmpfs /run tmpfs rw 0 0\n')
    write(root, '/proc/swaps', 'Filename\tType\tSize\tUsed\tPriority\n/dev/zram0 partition 1000 0 5\n')
    # sysfs: the boot card, a 64 GB card in a USB reader, a non-USB disk
    devices = os.path.join(root, 'sys/devices')
    disks = {
        'mmcblk0': ('platform/sdhci-tegra.0/mmc_host/mmc0/mmc0:aaaa/block/mmcblk0', 63864569856 // 512, '0', 'mmcblk0p1'),
        'sda': ('platform/70090000.xusb/usb2/2-1/2-1:1.0/host0/target0:0:0/0:0:0:0/block/sda', 63864569856 // 512, '1', 'sda1'),
        'sdb': ('platform/ahci.0/ata1/host1/target1:0:0/1:0:0:0/block/sdb', 500107862016 // 512, '0', 'sdb1'),
    }
    os.makedirs(os.path.join(root, 'sys/block'), exist_ok=True)
    for name, (rel, sectors, removable, part) in disks.items():
        d = os.path.join(devices, rel)
        write(d, 'size', '%d\n' % sectors)
        write(d, 'removable', removable + '\n')
        write(d, 'queue/logical_block_size', '512\n')
        os.makedirs(os.path.join(d, 'holders'), exist_ok=True)
        os.makedirs(os.path.join(d, part, 'holders'), exist_ok=True)
        if name == 'sda':
            write(d, 'device/vendor', 'Generic \n')
            write(d, 'device/model', 'STORAGE DEVICE  \n')
        os.symlink(os.path.relpath(d, os.path.join(root, 'sys/block')), os.path.join(root, 'sys/block', name))
    write(root, '/etc/passwd', 'root:x:0:0:root:/root:/bin/bash\n'
          'gdm:x:121:125:Gnome Display Manager:/var/lib/gdm3:/bin/false\n'
          'nano:x:1000:1000:Nano user,,,:/home/nano:/bin/bash\n'
          'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n')
    write(root, '/home/nano/.ssh/authorized_keys', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStandIn one\n# comment\n')
    write(root, '/etc/hostname', 'nano-test\n')
    write(root, '/etc/timezone', 'Asia/Tokyo\n')
    write(root, '/etc/default/locale', 'LANG="en_US.UTF-8"\n')
    write(root, '/etc/NetworkManager/system-connections/StandInWifi.nmconnection', '[connection]\nid=StandInWifi\n')
    write(root, '/etc/NetworkManager/system-connections/Wired.nmconnection', '[connection]\nid=Wired\n')
    write(root, '/etc/shadow', 'root:*:20000:0:99999:7:::\ngdm:*:20000:0:99999:7:::\n'
          'nano:$6$standin$notarealhash:20000:0:99999:7:::\nnobody:*:20000:0:99999:7:::\n')
    write(root, '/etc/group', 'root:x:0:\nadm:x:4:syslog,nano\nsudo:x:27:nano\nvideo:x:44:gdm,nano\n'
          'gpio:x:999:nano\nnano:x:1000:\n')
    for k in ('rsa', 'ecdsa', 'ed25519'):
        write(root, '/etc/ssh/ssh_host_%s_key' % k, 'stand-in\n')
        write(root, '/etc/ssh/ssh_host_%s_key.pub' % k, 'stand-in\n')
    write(root, '/lib/firmware/tegra21x_xusb_firmware', b'stand-in USB 3 firmware\0')


KERNEL = '5.10.216-tegra'
DTB = 'tegra210-p3448-0000-p3449-0000-b00-r35.dtb'


def make_kernel(folder, release=KERNEL):
    """A stand-in for build-jp5-kernel.sh's out/: the files the converter checks and copies."""
    image = bytearray(4096)
    image[56:60] = b'ARM\x64'
    banner = ('Linux version %s (stand-in@test) (aarch64-linux-gnu-gcc-13 (Ubuntu 13.3.0) 13.3.0, GNU ld 2.42) '
              '#35 SMP PREEMPT Tue Sep 16 12:00:00 UTC 2026\n' % release).encode().ljust(160, b'\0')
    image[1024:1024 + len(banner)] = banner
    write(folder, 'Image', bytes(image))
    write(folder, 'dtb/' + DTB, b'\xd0\x0d\xfe\xed' + b'\0' * 60 + b'nvidia,p3449-0000-b00+p3448-0000-b00\0')
    mods = 'modules/lib/modules/%s/' % release
    write(folder, mods + 'kernel/drivers/video/tegra/nvmap/nvmap.ko', b'stand-in nvmap')
    write(folder, mods + 'kernel/drivers/gpu/nvgpu/nvgpu.ko', b'stand-in nvgpu')
    write(folder, mods + 'modules.dep', 'kernel/drivers/video/tegra/nvmap/nvmap.ko:\n'
          'kernel/drivers/gpu/nvgpu/nvgpu.ko: kernel/drivers/video/tegra/nvmap/nvmap.ko\n')
    write(folder, 'config-' + release, 'CONFIG_ARM64=y\n')
    write(folder, 'build-info.txt', 'release=%s\nbuilt_utc=2026-09-16T12:00:00Z\n' % release)
    sums = []
    for top, dirs, files in os.walk(folder):
        for name in files:
            rel = os.path.relpath(os.path.join(top, name), folder)
            if rel != 'SHA256SUMS':
                with open(os.path.join(top, name), 'rb') as f:
                    sums.append('%s  %s\n' % (hashlib.sha256(f.read()).hexdigest(), rel))
    write(folder, 'SHA256SUMS', ''.join(sorted(sums, key=lambda l: l.split('  ', 1)[1])))


def load_tool():
    """The converter as a module, for its functions."""
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader('nano26_convert', TOOL)
    spec = importlib.util.spec_from_loader('nano26_convert', loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def human_bytes(n):
    return '%.1f GiB' % (n / GIB) if n >= GIB else '%.1f MiB' % (n / 1024 ** 2)


def run(root, source, *args, stdin='', tool=TOOL, plan=True):
    """The converter on the stand-in; PLAN unless plan names another test plan or is False."""
    cmd = [sys.executable, tool, '--root', root, '--source-disk', source] + list(args)
    if plan:
        cmd += ['--nvidia-test-plan', PLAN if plan is True else plan]
    env = dict(os.environ, HOME=os.path.join(root, '..', 'home'))
    p = subprocess.run(cmd, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True, env=env)
    return p.returncode, p.stdout


def expect(label, result, code, present=(), absent=()):
    rc, out = result
    bad = []
    if rc != code:
        bad.append('exit %d, expected %d' % (rc, code))
    for s in present:
        if s not in out:
            bad.append('missing %r' % s)
    for s in absent:
        if s in out:
            bad.append('unexpected %r' % s)
    print('%-34s %s%s' % (label, 'PASS' if not bad else 'FAIL', '' if not bad else ': ' + '; '.join(bad)))
    if bad:
        failures.append(label)
        print('    ' + out.replace('\n', '\n    '))
    return out

def report(label, ok, detail=''):
    print('%-34s %s%s' % (label, 'PASS' if ok else 'FAIL', '' if ok or not detail else ': %s' % (detail,)))
    if not ok:
        failures.append(label)
    return ok


def make_stand_ins(tmp, root):
    """Stand-ins for NVIDIA's servers, their test plan in tmp/plan.json, and
    the Jetson key in the stand-in root, where JetPack 4 keeps NVIDIA's."""
    global PLAN
    sys.path.insert(0, HERE)
    import nvidia_stand_in
    plan, key = nvidia_stand_in.make(os.path.join(tmp, 'nvidia'), load_tool())
    PLAN = os.path.join(tmp, 'plan.json')
    with open(PLAN, 'w') as f:
        json.dump(plan, f, indent=1)
    os.makedirs(os.path.join(root, os.path.dirname(KEY).lstrip('/')), exist_ok=True)
    shutil.copyfile(key, os.path.join(root, KEY.lstrip('/')))
    return plan


def pack_kernel(kernel, dest):
    p = subprocess.run(['bash', PACK, kernel, dest], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True)
    return p.returncode, p.stdout


def make_kernel_bundle(tmp, kernel, plan_file):
    """KERNEL packed by pack-jp5-kernel.sh, served in place of its release, and
    a copy of the test plan PLAN_FILE that pins it. Returns the new plan's path
    and the bundle's, or None for both if packing failed."""
    url_dir, name = load_tool().KERNEL_BUNDLE_URL.rsplit('/', 1)
    dest = os.path.join(tmp, 'kernel-release')
    os.makedirs(dest)
    out = expect('kernel packed', pack_kernel(kernel, dest), 0,
                 ['KERNEL_BUNDLE=PASS file=%s/%s sha256=' % (os.path.realpath(dest), name),
                  'Image: %s, build #35' % KERNEL,
                  'banner: Linux version %s (stand-in@test) (aarch64-linux-gnu-gcc-13 (Ubuntu 13.3.0) 13.3.0, '
                  'GNU ld 2.42) #35\n' % KERNEL])
    if 'KERNEL_BUNDLE=PASS' not in out:
        return None, None
    with open(os.path.join(dest, name + '.sha256')) as f:
        digest = f.read().split()[0]
    with open(plan_file) as f:
        plan = json.load(f)
    plan['sources'][url_dir + '/'] = 'file://' + dest + '/'
    plan['kernel_bundle_sha256'] = digest
    path = os.path.join(tmp, 'plan-kernel-release.json')
    with open(path, 'w') as f:
        json.dump(plan, f, indent=1)
    return path, os.path.join(dest, name)


def kernel_download_test(tmp, root, source, kernel):
    """pack-jp5-kernel.sh, and the converter taking its bundle in place of --kernel."""
    plan, bundle = make_kernel_bundle(tmp, kernel, PLAN)
    if not plan:
        return
    again = os.path.join(tmp, 'kernel-release-again')
    os.makedirs(again)
    out = expect('kernel packed again', pack_kernel(kernel, again), 0, ['KERNEL_BUNDLE=PASS'])
    with open(bundle, 'rb') as a, open(os.path.join(again, os.path.basename(bundle)), 'rb') as b:
        report('kernel packed the same each time', 'KERNEL_BUNDLE=PASS' in out and a.read() == b.read())
    expect('kernel bundle not overwritten', pack_kernel(kernel, os.path.dirname(bundle)), 1,
           ['KERNEL_BUNDLE=FAIL', 'already exists'])
    changed = os.path.join(tmp, 'kernel-changed')
    shutil.copytree(kernel, changed)
    write(changed, 'modules/lib/modules/%s/kernel/drivers/gpu/nvgpu/nvgpu.ko' % KERNEL, b'changed')
    expect('changed kernel not packed', pack_kernel(changed, again), 1, ['does not match SHA256SUMS'])
    expect('dry run, kernel downloaded', run(root, source, '--target', '/dev/sda', '--dry-run', '--offline',
                                             plan=plan), 0,
           ['CHECK kernel   PASS  %s, downloaded when writing (pinned SHA-256)' % os.path.basename(bundle),
            '   - the 5.10 kernel with this project\'s patches', 'NANO26_CHECKS=PASS'],
           ['Not downloaded:', 'give the 5.10 kernel'])

    # the converter's download and unpacking, in-process
    mod = load_tool()
    folder = tempfile.mkdtemp(prefix='fetched-', dir=tmp)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        mod.apply_test_plan(plan)
        try:
            got = mod.fetch_kernel(folder)
            error = None
        except Exception as e:  # reported below
            got, error = None, e
    same = got and all(open(os.path.join(got, rel), 'rb').read() == open(os.path.join(kernel, rel), 'rb').read()
                       for rel in [line.split('  ', 1)[1] for line in open(os.path.join(kernel, 'SHA256SUMS')).read()
                                   .splitlines()] + ['SHA256SUMS'])
    report('kernel downloaded and unpacked', error is None and same and os.listdir(folder) == ['nano26-kernel'],
           '%r\n%s' % (error, out.getvalue()))
    mod.KERNEL_BUNDLE_SHA256 = '0' * 64
    folder = tempfile.mkdtemp(prefix='fetched-', dir=tmp)
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            mod.fetch_kernel(folder)
            error = None
        except mod.Failed as e:
            error = e
    report('other kernel download refused', 'does not match its pinned SHA-256' in str(error)
           and not os.listdir(folder), error)


def load_file(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mirror_test(tmp, root, plan):
    """The converter's NVIDIA step against the stand-ins, and what stage 2's
    builders need from the copy it saves."""
    mod = load_tool()
    mod.ROOT = root
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        mod.apply_test_plan(PLAN)
        app = os.path.join(tmp, 'app')
        os.makedirs(app)
        try:
            mod.nvidia_packages(app)
            error = None
        except Exception as e:  # reported below
            error = e
    if not report('NVIDIA step against stand-ins', error is None, '%r\n%s' % (error, out.getvalue())):
        return
    mirror = os.path.join(app, mod.MIRROR)
    sets = {}
    for name in sorted(os.listdir(os.path.join(mirror, 'sets'))):
        with open(os.path.join(mirror, 'sets', name)) as f:
            sets[name[:-len('.txt')]] = [line.split('  ', 1) for line in f.read().splitlines()]
    counts = {name: len(lines) for name, lines in sets.items()}
    report('sets and their sizes', counts == {'l4t': 20, 'install': 19, 'trt82': 9, 'cuda12': 12}, counts)
    bad = [rel for lines in sets.values() for digest, rel in lines
           if not os.path.isfile(os.path.join(mirror, rel)) or hashlib.sha256(
               open(os.path.join(mirror, rel), 'rb').read()).hexdigest() != digest]
    report('every set file in place and matching', not bad, bad[:3])
    base = {name: sorted(os.path.basename(rel) for _, rel in lines) for name, lines in sets.items()}
    report('install set is the 19 pins', base['install'] == sorted(plan['install_pins']), base['install'])
    l = mod.l4t()
    wanted = [(n, v) for n, v, _ in l.RELEASES['r35']['nvidia'] + l.VIDEOS['r32']['release']['nvidia']
              + l.VIDEOS['r35']['release']['nvidia']] + [(n, v) for n, (v, _) in l.UBUNTU_DEBS.items()]
    names = sorted({'%s_%s_arm64.deb' % (n, v.split(':', 1)[-1]) for n, v in wanted})
    report('l4t set holds the l4t builder\'s files', names == base['l4t'], sorted(set(names) ^ set(base['l4t'])))
    trt = sorted(re.sub(r'_.*', '', b) for b in base['trt82'])
    report('trt82 set: TensorRT 8.2, no -dev or config', trt == sorted(
        ['cuda-cudart-10-2', 'cuda-nvrtc-10-2', 'libcublas10', 'libcudnn8', 'libnvinfer-bin', 'libnvinfer-plugin8',
         'libnvinfer8', 'libnvonnxparsers8', 'libnvparsers8']) and 'libnvinfer8_8.2.1-1+cuda10.2_arm64.deb' in base['trt82'],
           base['trt82'])
    script = open(os.path.join(REPO, 'scripts/jetson/yolo/package-trt82.sh')).read()
    required = re.search(r'^REQUIRED=\(([^)]*)\)', script, re.M).group(1).split()
    report('trt82 set has package-trt82.sh\'s', set(required) <= set(trt), required)
    indexes = ['repo.download.nvidia.com/jetson/%s/dists/%s/%s' % (suite, release, name)
               for suite, release in mod.JETSON_INDEXES
               for name in ('Release', 'Release.gpg', 'main/binary-arm64/Packages')]
    indexes += ['developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/arm64/' + n
                for n in ('Release', 'Release.gpg', 'Packages.gz', '3bf863cc.pub')]
    missing = [i for i in indexes if not os.path.isfile(os.path.join(mirror, i))]
    report('signed indexes and keys saved', not missing and os.path.isfile(os.path.join(mirror, 'keys/jetson-ota-public.asc')),
           missing)
    report('work folder removed', not os.path.exists(os.path.join(app, mod.STATE, 'nvidia-work')))

    # build-nano-cuda12-debs.py --mirror, as stage 2 runs it, up to its downloads.
    b = load_file(os.path.join(REPO, 'scripts/host/build-nano-cuda12-debs.py'), 'cuda12_mirror_test')
    b.fetch.KEY_FINGERPRINT = plan['fingerprints']['jetson']
    b.probe.CUDA_KEY_FINGERPRINT = plan['fingerprints']['cuda']
    b.fetch.BASE = b.mirrored(Path(mirror), b.fetch.BASE)
    b.probe.CUDA_REPO = b.mirrored(Path(mirror), b.probe.CUDA_REPO)
    work = Path(tmp) / 'cuda12-from-mirror'
    work.mkdir()
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            gnupg, keyring = b.fetch.prepare_keyring(work, Path(mirror) / 'keys/jetson-ota-public.asc')
            b.fetch.RELEASE = b.R36_RELEASE
            url, entries, _ = b.fetch.fetch_index(work, gnupg, keyring, 'common')
            cuda_entries = b.probe.flat_index(work, *b.probe.cuda_keyring(work))
            minor, cudart, chosen, _, _ = b.choose(url, entries, cuda_entries)
            sources = work / 'sources'
            sources.mkdir()
            got = [b.fetch.obtain(base_url, entry, sources, []) for _, base_url, entry, _ in chosen]
        linked = all(os.stat(str(g)).st_nlink == 2 for g in got)
        report('CUDA 12 builder reads the copy', minor == 6 and len(got) == 12 and linked,
               'minor %s, %d packages, hard-linked %s' % (minor, len(got), linked))
        report('CUDA 12 builder takes the same set', sorted(g.name for g in got) == base['cuda12'])
    except SystemExit as e:
        report('CUDA 12 builder reads the copy', False, e)


def heredocs(text):
    """{file name: body} of the cat > FILE <<EOF and python3 - <<PY blocks in a bash script."""
    out = {}
    for target, body in re.findall(r"cat > (\S+) <<'?EOF'?\n(.*?)\nEOF\n", text, re.S):
        out['80-nano-hide-card.rules' if '$HIDE' in target else os.path.basename(target.strip('"'))] = body
    for body in re.findall(r"python3 - <<'PY'.*?\n(.*?)\nPY\n", text, re.S):
        out['python'] = body
    return out


def stage2_settings_test():
    """nano26-stage2 writes the reference card's desktop settings as the add-u26 scripts do."""
    with open(STAGE2) as f:
        stage2 = f.read()
    mine = heredocs(stage2)
    theirs = {}
    for name in ('add-u26-desktop.sh', 'add-u26-gpu-desktop.sh', 'add-u26-unity.sh'):
        with open(os.path.join(REPO, 'scripts/reference-card', name)) as f:
            text = f.read()
        for key, body in heredocs(text).items():
            theirs.setdefault(key, body)
        for var in ('XSERVER', 'WALLPAPER', 'FAVORITES'):
            m = re.search(r'^%s=(.*?)\n(?=[A-Z_]+=|$)' % var, text, re.M | re.S)
            if m:
                theirs['$' + var] = m.group(1)
    for var in ('XSERVER', 'WALLPAPER', 'FAVORITES'):
        mine['$' + var] = re.search(r'^%s=(.*?)\n(?=[A-Z_]+=|$)' % var, stage2, re.M | re.S).group(1)
    keys = ['20-jetson-framebuffer.conf', '50-jetson-desktop.conf', '60-jetson-gpu.conf', 'xfwm4.xml',
            '80-nano-hide-card.rules', 'python', '$XSERVER', '$WALLPAPER', '$FAVORITES']
    differ = [k for k in keys if k not in mine or mine.get(k) != theirs.get(k)]
    report('stage 2 settings as the reference', not differ, differ)
    mod = load_tool()
    script = open(os.path.join(REPO, 'scripts/reference-card/add-u26-desktop.sh')).read()
    report('zram swap as the reference', "printf '%s'" % mod.ZRAM.replace('\n', '\\n') in script)


def main():
    keep = '--keep' in sys.argv
    tmp = tempfile.mkdtemp(prefix='nano26-test-')
    try:
        root = os.path.join(tmp, 'root')
        source = os.path.join(tmp, 'source.img')
        os.makedirs(os.path.join(tmp, 'home'))
        table = make_source(source)
        make_root(root)
        plan = make_stand_ins(tmp, root)

        # the converter's GPT reader against sfdisk's view of the same table
        mod = load_tool()
        with open(source, 'rb') as f:
            info, parts = mod.read_gpt(f)
        mismatched = []
        for p in table['partitions']:
            n = int(p['node'][len(source):])
            mine = parts[n]
            if (mine['start'], mine['size'], mine['name'], mine['uuid'].upper(), mine['type'].upper()) != \
                    (p['start'], p['size'], p['name'], p['uuid'].upper(), p['type'].upper()):
                mismatched.append(n)
        ok = not mismatched and len(parts) == len(table['partitions']) == 14 and info['disk_guid'].upper() == table['id'].upper()
        print('%-34s %s' % ('GPT reader matches sfdisk', 'PASS' if ok else 'FAIL %s' % mismatched))
        if not ok:
            failures.append('gpt reader')
        layout = mod.target_layout(parts, 63864569856)
        app = layout[1]
        total = 63864569856 // 512
        ok = app['start'] == APP_START and app['size'] % 2048 == 0 and app['start'] + app['size'] - 1 <= total - 34 \
            and total - 34 - (app['start'] + app['size'] - 1) < 2048 \
            and all(layout[n] == parts[n] for n in range(2, 15))
        print('%-34s %s' % ('target layout', 'PASS' if ok else 'FAIL %r' % app))
        if not ok:
            failures.append('layout')

        kernel = os.path.join(tmp, 'kernel')
        make_kernel(kernel)
        expect('dry run, USB card', run(root, source, '--target', '/dev/sda', '--dry-run', '--offline',
                                        '--kernel', kernel), 0,
               ['CHECK board    PASS', 'CHECK l4t      PASS', 'CHECK boot     PASS', 'CHECK source   PASS',
                'CHECK target   PASS', 'CHECK kernel   PASS', 'CHECK helpers  PASS', 'CHECK stage2   PASS',
                'CHECK nvidia-key PASS  /etc/apt/trusted.gpg.d/jetson-ota-public.asc, primary key '
                + plan['fingerprints']['jetson'], 'CHECK accounts PASS',
                'CHECK clock    PASS', 'NANO26_CHECKS=PASS', 'NANO26_DRY_RUN=DONE', 'p1  APP',
                'p14 RP4', 'account nano (uid 1000)', '1 SSH authorized key\n', 'hostname nano-test',
                'time zone Asia/Tokyo, locale en_US.UTF-8', '2 network profiles', '3 SSH host keys',
                'Generic STORAGE DEVICE on USB', 'JetPack 5 (L4T R35.6): GPU driver set',
                'Not downloaded: the 5.10 kernel', 'builds the NVIDIA\n   packages as nano',
                'under NVIDIA\'s terms', 'Test plan '],
               ['StandInWifi', 'gdm', 'Note: below 64 GB', 'notarealhash', 'Do you accept', 'Not in this version'])
        expect('dry run, image file', run(root, source, '--target-image', os.path.join(tmp, 'new.img'),
                                          '--dry-run', '--offline'), 0,
               ['CHECK target   PASS  image file', ', built in ', ', then cut to its contents', 'CHECK kernel   SKIP',
                '6 GB, estimate). Written to a whole card of 32 GB or more', 'APP to the card\'s end',
                'p1  APP      start', 'to the end  new ext4', 'NANO26_DRY_RUN=DONE'], ['Note: below 64 GB'])
        expect('dry run, nothing copied', run(root, source, '--target', '/dev/sda', '--dry-run', '--offline',
                                              '--no-copy-ssh-host-keys', '--no-copy-hostname', '--no-copy-network'), 0,
               ['hostname jetson-nano (not copied)', '2 network profiles (Wi-Fi included; names are not shown): not copied',
                '3 SSH host keys: not copied'])
        expect('list', run(root, source, '--list'), 0, ['/dev/sda', 'on USB'], ['/dev/sdb', 'mmcblk0'])
        expect('boot card refused', run(root, source, '--target', '/dev/mmcblk0', '--dry-run', '--offline'), 1,
               ['CHECK target   FAIL  /dev/mmcblk0 is the card this system runs from', 'NANO26_CHECKS=FAIL target'])
        expect('partition refused', run(root, source, '--target', '/dev/sda1', '--dry-run', '--offline'), 1,
               ['give a whole disk'])
        expect('non-USB disk refused', run(root, source, '--target', '/dev/sdb', '--dry-run', '--offline'), 1,
               ['not a USB or removable disk'])
        expect('small working size refused', run(root, source, '--target-image', os.path.join(tmp, 'small.img'),
                                                 '--size', '8G', '--dry-run', '--offline'), 1,
               ['it needs 9.3 GiB to be built in (estimate)'])
        expect('image beyond the free space refused', run(root, source, '--target-image', os.path.join(tmp, 'x.img'),
                                                          '--size', '900T', '--dry-run', '--offline'), 1,
               ['free there, keeping 1.0 GiB for this system, not 818.5 TiB'])
        expect('image in a missing folder refused', run(root, source, '--target-image',
                                                        os.path.join(tmp, 'none', 'x.img'), '--dry-run', '--offline'),
               1, ['its folder does not exist'])
        expect('offline needs dry run', run(root, source, '--target', '/dev/sda', '--offline'), 2, ['--offline is for'])
        p = subprocess.run([sys.executable, TOOL, '--target', '/dev/sda', '--dry-run', '--nvidia-test-plan', PLAN],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        expect('test plan needs a stand-in root', (p.returncode, p.stdout), 2, ['for tests with --root only'])
        expect('real NVIDIA key expected', run(root, source, '--target', '/dev/sda', '--dry-run', '--offline',
                                               plan=False), 1,
               ['CHECK nvidia-key FAIL', 'expected 3C6D1FF3100C8C3ABB0869C0E6543461A9996195',
                'NANO26_CHECKS=FAIL nvidia-key'])

        # the converter outside a whole copy of the repository
        lone = os.path.join(tmp, 'lone', 'scripts', 'jetson', 'convert')
        os.makedirs(lone)
        for name in ('nano26-convert', 'nano26-first-boot'):
            shutil.copy2(os.path.join(os.path.dirname(TOOL), name), lone)
        expect('repository copy needed', run(root, source, '--target', '/dev/sda', '--dry-run', '--offline',
                                             tool=os.path.join(lone, 'nano26-convert'), plan=False), 1,
               ['CHECK stage2   FAIL', 'nano26-stage2 is not beside this script', 'not in this copy of the repository'])

        # the kernel folder
        def kernel_variant(label, change, present):
            k2 = os.path.join(tmp, 'kernel-' + label.replace(' ', '-'))
            shutil.copytree(kernel, k2)
            change(k2)
            expect(label, run(root, source, '--target', '/dev/sda', '--dry-run', '--offline', '--kernel', k2), 1,
                   ['CHECK kernel   FAIL'] + present)
        kernel_variant('changed module refused', lambda k: write(
            k, 'modules/lib/modules/%s/kernel/drivers/gpu/nvgpu/nvgpu.ko' % KERNEL, b'changed'),
            ['nvgpu.ko does not match SHA256SUMS'])
        kernel_variant('extra file refused', lambda k: write(k, 'extra.txt', 'x'),
                       ['files and SHA256SUMS differ: extra.txt'])
        k_old = os.path.join(tmp, 'kernel-old-release')
        make_kernel(k_old, '5.10.120-tegra')
        expect('other kernel release refused', run(root, source, '--target', '/dev/sda', '--dry-run', '--offline',
                                                   '--kernel', k_old), 1,
               ['Image is not a 5.10.216-tegra arm64 kernel', 'no modules for 5.10.216-tegra'])
        kernel_download_test(tmp, root, source, kernel)

        # failures from the Nano's side, each in a copy of the stand-in
        def variant(label, change, code, present):
            r2 = os.path.join(tmp, 'root-' + label.replace(' ', '-'))
            shutil.copytree(root, r2, symlinks=True)
            src = change(r2) or source
            expect(label, run(r2, src, '--target', '/dev/sda', '--dry-run', '--offline'), code, present)

        variant('2GB Nano refused', lambda r: write(r, '/proc/device-tree/compatible',
                b'nvidia,p3541-0000+p3448-0003\0nvidia,jetson-nano-2gb\0nvidia,tegra210\0'), 1,
                ['CHECK board    FAIL', 'tested only on nvidia,p3449-0000-b00+p3448-0000-b00'])
        variant('JetPack 4.6.1 refused', lambda r: write(r, '/etc/nv_tegra_release',
                '# R32 (release), REVISION: 7.1, GCID: 1, BOARD: t210ref\n'), 1,
                ['CHECK l4t      FAIL  L4T R32.7.1', 'update to JetPack 4.6.6'])

        def old_bootloader(r):
            p = os.path.join(r, 'var/lib/dpkg/status')
            t = open(p).read().replace('Version: 32.7.6-20241104234540\nDescription', 'Version: 32.7.1-20220219090432\nDescription')
            open(p, 'w').write(t)
        variant('old bootloader refused', old_bootloader, 1, ['nvidia-l4t-bootloader 32.7.1-20220219090432'])
        variant('USB boot refused', lambda r: write(r, '/proc/self/mountinfo',
                '21 1 8:1 / / rw - ext4 /dev/sda1 rw\n'), 1, ['CHECK boot     FAIL  root on 8:1'])
        variant('mounted target refused', lambda r: write(r, '/proc/mounts',
                '/dev/mmcblk0p1 / ext4 rw 0 0\n/dev/sda1 /media/nano/card vfat rw 0 0\n'), 1,
                ['IN USE: sda1', 'in use: sda1 (unmount it first)'])
        variant('no USB 3 firmware refused', lambda r: os.unlink(os.path.join(r, 'lib/firmware/tegra21x_xusb_firmware')),
                1, ['CHECK helpers  FAIL', 'no /lib/firmware/tegra21x_xusb_firmware'])
        variant('no account refused', lambda r: write(r, '/etc/passwd', 'root:x:0:0:root:/root:/bin/bash\n'), 1,
                ['CHECK accounts FAIL  0 accounts', 'no login'])
        variant('no NVIDIA key refused', lambda r: os.unlink(os.path.join(r, KEY.lstrip('/'))), 1,
                ['CHECK nvidia-key FAIL  no /etc/apt/trusted.gpg.d/jetson-ota-public.asc'])

        def corrupt(r):
            bad = os.path.join(r, '..', 'corrupt-%s.img' % os.path.basename(r))
            with open(source, 'rb') as f:
                head = f.read(1024 * 1024)          # the primary GPT; the rest stays sparse
            with open(bad, 'wb') as f:
                f.write(head)
                f.truncate(os.path.getsize(source))
                f.seek(2 * 512 + 40)
                f.write(b'\x55')
            return bad
        variant('corrupt source table refused', corrupt, 1, ['CHECK source   FAIL', 'checksum mismatch'])

        # up to writing (test_convert_image.py writes)
        image = os.path.join(tmp, 'never.img')
        expect('writing needs a kernel', run(root, source, '--skip-network-check', '--target-image', image,
                                             '--confirm', 'never.img'), 1,
               ['CHECK kernel   FAIL  give the 5.10 kernel with --kernel DIR'])
        expect('wrong name refused', run(root, source, '--skip-network-check', '--target-image', image,
                                         '--kernel', kernel, '--confirm', 'other.img',
                                         '--accept-nvidia-licences'), 1,
               ['NANO26_CHECKS=PASS', 'the name did not match', 'Nothing was written'])
        expect('no terminal, no confirmation', run(root, source, '--skip-network-check', '--target-image', image,
                                                   '--kernel', kernel, '--accept-nvidia-licences'), 1,
               ['pass --confirm never.img'])
        expect('NVIDIA\'s terms needed', run(root, source, '--skip-network-check', '--target-image', image,
                                              '--kernel', kernel, '--confirm', 'never.img'), 1,
               ['pass --accept-nvidia-licences', 'NVIDIA\'s terms were not accepted. Nothing was written.'])
        print('%-34s %s' % ('nothing written', 'FAIL' if os.path.lexists(image) else 'PASS'))
        if os.path.lexists(image):
            failures.append('nothing written')
        expect('device not written in a test', run(root, source, '--skip-network-check', '--target', '/dev/sda',
                                                   '--kernel', kernel, '--confirm', 'sda', '--accept-nvidia-licences'), 1,
               ['only checks a device target', 'NANO26_CHECKS=FAIL target'], ['STEP 1/6'])
        print('%-34s %s' % ('record saved under HOME', 'PASS' if os.path.isdir(os.path.join(tmp, 'home', '.cache', 'nano26-convert')) else 'FAIL'))
        if not os.path.isdir(os.path.join(tmp, 'home', '.cache', 'nano26-convert')):
            failures.append('record')

        mirror_test(tmp, root, plan)
        stage2_settings_test()
    finally:
        if keep:
            print('kept: ' + tmp)
        else:
            shutil.rmtree(tmp)
    print('NANO26_CONVERT_TEST=%s%s' % ('FAIL ' if failures else 'PASS', ', '.join(failures)))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())

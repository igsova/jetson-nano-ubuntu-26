#!/usr/bin/env python3
"""Host test: nano26-convert writes an image file, then nano26-first-boot
installs it and nano26-stage2 runs in a chroot (docs/CONVERTER.md, Testing).
Run on a PC, no Nano.

Usage: sudo python3 tests/convert/test_convert_image.py [--keep] [--no-first-boot]
       sudo python3 tests/convert/test_convert_image.py --stage2-again KEPT

Needs root (loop devices, mounts, chroot), the network (Ubuntu's servers),
sfdisk, mke2fs, debugfs, losetup, unshare and openssl, and on a PC that is
not arm64, qemu-user-static registered with binfmt_misc so the arm64 chroot
runs, and gpg and dpkg-deb for the stand-ins for NVIDIA's servers
(nvidia_stand_in.py, named with --nvidia-test-plan). About 8 GB of disk
(estimate); the first boot installs the desktops under emulation, which
takes long.

The source is test_nano26_convert.py's stand-in Nano, with random bytes in
the 13 boot partitions and an ext4 in APP made with the features of NVIDIA's
APP, and its stand-in kernel, packed by pack-jp5-kernel.sh and served in place
of its release, so the converter downloads it as it does without --kernel
(and leaves nothing in /var/tmp). The converter writes an image, in as much of
the temporary folder's free space as it would take on the Nano (up to 16
GiB), and cuts it to its contents; the test reads its table, checks that the
image ends with the backup GPT, that its SHA-256 file matches and only its
owner can read it, compares the boot partitions, checks APP's files and the
staged identity, and that the record leaves out the password hash and
network names, the copy of NVIDIA's (stand-in) repositories and stage 2
with its repository files. Then, unless --no-first-boot, it makes the image
as long as a 32 GB card and grows APP as the first boot does on the
Nano, with the PC's sfdisk and resize2fs (offline: the first boot grows the
mounted ext4, which needs a right a container may not give); it runs the
first boot in a chroot of the image's APP with no network (not as PID 1, so
it neither mounts, grows nor restarts) and checks the installed system: systemd 259,
the account, the firmware, the settings, the everyday boot entry and stage
2's service. Then stage 2 runs in the chroot, outside systemd, with stubs in
place of the repository's builders, installers and checks (each checks what
it is given and as which account, and logs its call; the builders make
small .debs): once with the TensorRT 8.2 build made to fail, then again,
which must resume there; and the test checks the installed packages, the
desktop settings, the boot target, the report and the clean-up. This shows
the logic only: under emulation on the PC's kernel, not the Nano's 5.10, and
without NVIDIA's packages. With --stage2-again KEPT, it runs only stage 2
again, the working tree's script from its first step, on the image a --keep
run left in KEPT, if that stage 2 did not finish. The last line is
NANO26_IMAGE_TEST=PASS or FAIL.
"""
import glob
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_nano26_convert as fixture  # noqa: E402

TOOL = fixture.TOOL
FIRST_BOOT = os.path.join(os.path.dirname(TOOL), 'nano26-first-boot')
STAGE2 = os.path.join(os.path.dirname(TOOL), 'nano26-stage2')
NVIDIA_APP_FEATURES = ('has_journal,ext_attr,resize_inode,dir_index,filetype,extent,flex_bg,'
                       'sparse_super,large_file,huge_file,dir_nlink,extra_isize')
CARD_BYTES = 31914983424    # a 32 GB card, the one the converter was tested on
PASSWORD_HASH = None
failures = []


def check(label, ok, detail=''):
    print('%-40s %s%s' % (label, 'PASS' if ok else 'FAIL', '' if ok or not detail else ': ' + str(detail)))
    if not ok:
        failures.append(label)
    return ok


def sh(*cmd, **kw):
    return subprocess.run(list(cmd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          universal_newlines=True, **kw)


def got(p):
    """A file's text, or '' when it is missing."""
    return read(p) if os.path.exists(p) else ''


def ext4_features(spec):
    out = sh('debugfs', '-R', 'stats -h', spec).stdout
    for line in out.splitlines():
        if line.startswith('Filesystem features:'):
            return sorted(line.split(':', 1)[1].split())
    return []


def read(p, mode='r'):
    with open(p, mode) as f:
        return f.read()


def make_source(tmp):
    source = os.path.join(tmp, 'source.img')
    fixture.make_source(source)
    with open(source, 'r+b') as f:
        for n, name, start, sectors in fixture.BOOT_PARTS:
            f.seek(start * 512)
            f.write(os.urandom(sectors * 512))
    p = sh('mke2fs', '-q', '-F', '-t', 'ext4', '-O', 'none,' + NVIDIA_APP_FEATURES,
           '-E', 'offset=%d' % (fixture.APP_START * 512), source, '256M')
    if p.returncode:
        raise SystemExit('mke2fs: ' + p.stdout)
    return source


def make_root(tmp):
    global PASSWORD_HASH
    root = os.path.join(tmp, 'root')
    fixture.make_root(root)
    PASSWORD_HASH = sh('openssl', 'passwd', '-6', '-salt', 'standinsalt', 'stand-in password').stdout.strip()
    shadow = read(os.path.join(root, 'etc/shadow')).replace('$6$standin$notarealhash', PASSWORD_HASH)
    fixture.write(root, '/etc/shadow', shadow)
    fixture.write(root, '/etc/NetworkManager/system-connections/StandInWifi.nmconnection',
                  '[connection]\nid=StandInWifi\ntype=wifi\n\n[wifi]\nssid=StandInWifi\n')
    return root


def check_image(tmp, source, image, kernel, root, out):
    mod = fixture.load_tool()
    with open(source, 'rb') as f:
        sinfo, sparts = mod.read_gpt(f)
    with open(image, 'rb') as f:
        info, parts = mod.read_gpt(f)
    check('14 partitions', sorted(parts) == list(range(1, 15)), sorted(parts))
    same = all(parts[n] == sparts[n] for n in range(2, 15))
    check('boot partition entries copied', same)
    with open(source, 'rb') as s, open(image, 'rb') as t:
        equal = True
        for n in range(2, 15):
            s.seek(sparts[n]['start'] * 512)
            t.seek(parts[n]['start'] * 512)
            n_bytes = sparts[n]['size'] * 512
            equal = equal and s.read(n_bytes) == t.read(n_bytes)
    check('boot partition bytes copied', equal)
    app = parts[1]
    check('APP from the same start to the end', app['start'] == sparts[1]['start'] and app['name'] == 'APP'
          and app['size'] % 2048 == 0 and 0 <= info['last'] - (app['start'] + app['size'] - 1) < 2048, app)
    size = os.path.getsize(image)
    print('    image cut to %s' % fixture.human_bytes(size))
    check('image cut after APP, backup GPT last', info['backup'] == size // 512 - 1 == info['last'] + 33
          and size < 10 ** 10, (size, info))
    verify = sh('sfdisk', '--verify', image)
    check('table verifies', verify.returncode == 0 and 'No errors detected' in verify.stdout, verify.stdout)
    check('image for its owner only', os.stat(image).st_mode & 0o777 == 0o600
          and os.stat(image + '.sha256').st_mode & 0o777 == 0o600)
    with open(image, 'rb') as f:
        digest = hashlib.sha256()
        for block in iter(lambda: f.read(1 << 20), b''):
            digest.update(block)
    check('SHA-256 file', read(image + '.sha256') == '%s  new.img\n' % digest.hexdigest())
    check('image ready message', 'STEP 7/7 the image cut to its contents' in out and 'The image is ready' in out
          and "scp 'USER@ADDRESS:%s*' ." % image in out)
    check('new disk and APP GUIDs', info['disk_guid'] != sinfo['disk_guid'] and app['uuid'] != sparts[1]['uuid'])
    offset = app['start'] * 512
    check('APP ext4 features as the source',
          ext4_features('%s?offset=%d' % (image, offset)) ==
          ext4_features('%s?offset=%d' % (source, fixture.APP_START * 512)))

    loop = sh('losetup', '--find', '--show', '--offset', str(offset), '--sizelimit', str(app['size'] * 512),
              image).stdout.strip()
    mnt = os.path.join(tmp, 'app')
    os.makedirs(mnt)
    sh('mount', '-t', 'ext4', loop, mnt)
    try:
        a = lambda p: os.path.join(mnt, p)  # noqa: E731
        st = os.statvfs(mnt)
        check('room in APP for the first boot', st.f_bfree * st.f_frsize >= 200 * 2 ** 20,
              fixture.human_bytes(st.f_bfree * st.f_frsize))
        check('Ubuntu 26.04 base', 'VERSION_ID="26.04"' in read(a('etc/os-release')))
        check('no base tarball left', not os.path.exists(a('ubuntu-base.tar.gz')))
        check('kernel Image', read(a('boot/jp5/Image'), 'rb') == read(os.path.join(kernel, 'Image'), 'rb'))
        check('device tree', read(a('boot/jp5/' + fixture.DTB), 'rb') == read(os.path.join(kernel, 'dtb', fixture.DTB), 'rb'))
        initrd = read(a('boot/jp5/initrd-firmware.cpio'), 'rb')
        check('initrd with the USB 3 firmware', initrd.startswith(b'070701') and initrd.count(b'stand-in USB 3 firmware') == 2
              and b'lib/firmware/nvidia/tegra210/xusb.bin' in initrd)
        check('modules', os.path.isfile(a('usr/lib/modules/%s/kernel/drivers/gpu/nvgpu/nvgpu.ko' % fixture.KERNEL))
              and os.stat(a('usr/lib/modules/%s/modules.dep' % fixture.KERNEL)).st_uid == 0)
        conf = read(a('boot/extlinux/extlinux.conf'))
        everyday = read(a('var/lib/nano26/extlinux.conf'))
        check('first boot entry', 'DEFAULT first-boot' in conf and 'init=/usr/lib/nano26/first-boot' in conf
              and 'root=PARTUUID=%s ' % app['uuid'] in conf, conf)
        check('everyday entry staged', 'DEFAULT u26' in everyday and 'init=' not in everyday
              and 'root=PARTUUID=%s ' % app['uuid'] in everyday and 'panic=10 log_buf_len=4M' in everyday)
        check('first boot script', read(a('usr/lib/nano26/first-boot')) == read(FIRST_BOOT)
              and os.stat(a('usr/lib/nano26/first-boot')).st_mode & 0o777 == 0o755)
        debs = os.listdir(a('var/cache/apt/archives'))
        check('systemd 259 downloaded, not installed', any(d.startswith('systemd_259') for d in debs)
              and not os.path.exists(a('usr/lib/systemd/systemd')))
        check('firmware packages downloaded', len([d for d in os.listdir(a('var/lib/nano26/firmware'))
                                                    if d.endswith('.deb')]) == 2)
        fs_uuid = sh('blkid', '-p', '-s', 'UUID', '-o', 'value', loop).stdout.strip()
        check('fstab by the new UUID', read(a('etc/fstab')).startswith('UUID=%s / ext4 ' % fs_uuid))
        check('policy-rc.d for the first boot', os.path.exists(a('usr/sbin/policy-rc.d')))
        accounts = read(a('var/lib/nano26/identity/accounts'))
        check('account staged', accounts == 'nano:1000:1000:nano:Nano user,,,:/home/nano:'
              'adm,audio,cdrom,dip,gpio,input,netdev,plugdev,render,sudo,video\n', accounts)
        check('password hash staged, root only', read(a('var/lib/nano26/identity/shadow')) == 'nano:%s\n' % PASSWORD_HASH
              and os.stat(a('var/lib/nano26/identity/shadow')).st_mode & 0o777 == 0o600
              and os.stat(a('var/lib/nano26/identity')).st_mode & 0o777 == 0o700)
        check('authorized keys staged', read(a('var/lib/nano26/identity/keys/nano')).startswith('ssh-ed25519 '))
        settings = read(a('var/lib/nano26/settings'))
        check('settings staged', settings == 'zone=Asia/Tokyo\nlocale=LANG=en_US.UTF-8\nowner=nano\n'
              'card-min=30000000000\n', settings)
        check('hostname', read(a('etc/hostname')) == 'nano-test\n' and '127.0.1.1 nano-test' in read(a('etc/hosts')))
        nm = a('etc/NetworkManager/system-connections')
        check('network profiles, root only', sorted(os.listdir(nm)) == ['StandInWifi.nmconnection', 'Wired.nmconnection']
              and all(os.stat(os.path.join(nm, n)).st_mode & 0o777 == 0o600 for n in os.listdir(nm)))
        check('SSH host keys', all(read(a('etc/ssh/ssh_host_%s_key' % k)) == 'stand-in\n'
                                   for k in ('rsa', 'ecdsa', 'ed25519')))
        check('sshd setting: no EF marking', read(a('etc/ssh/sshd_config.d/50-nano26-ipqos.conf')).endswith('IPQoS none\n'))
        mod = fixture.load_tool()
        stage2_debs = mod.stage2_packages()
        check('packages to install: boot and stage 2\'s',
              read(a('var/lib/nano26/packages')).split() == mod.BOOT_PACKAGES + stage2_debs, len(stage2_debs))
        check('desktop packages downloaded', any(d.startswith('lightdm_') for d in debs)
              and any(d.startswith('g++-11_') for d in debs) and any(d.startswith('unity_') for d in debs))
        mirror = a('var/lib/nano26/mirror')
        check('NVIDIA copy: four sets', sorted(os.listdir(os.path.join(mirror, 'sets'))) ==
              ['cuda12.txt', 'install.txt', 'l4t.txt', 'trt82.txt'])
        sums = sh('sh', '-c', 'cd "$1" && for s in sets/*.txt; do sha256sum -c --quiet "$s" || exit 1; done', 'sh', mirror)
        check('NVIDIA copy matches its sets', sums.returncode == 0, sums.stdout)
        check('stage 2 script', read(a('usr/lib/nano26/stage2')) == read(STAGE2)
              and os.stat(a('usr/lib/nano26/stage2')).st_mode & 0o777 == 0o755)
        check('stage 2 unit', read(a('etc/systemd/system/nano26-stage2.service')) == read(STAGE2 + '.service'))
        repo = sh('sh', '-c', 'cd "$1" && sha256sum -c --quiet SHA256SUMS && wc -l < SHA256SUMS', 'sh',
                  a('usr/lib/nano26/repo'))
        check('stage 2 repository files', repo.returncode == 0 and repo.stdout.strip() == str(len(mod.REPO_FILES)),
              repo.stdout)
        check('zram swap', read(a('etc/systemd/zram-generator.conf')) == mod.ZRAM)
        record = out.split('Record: ')[-1].strip()
        text = read(os.path.join(record, 'log.txt'))
        check('record has the commands', '$ sfdisk' in text and '$ chroot' in text)
        check('record leaves out hash and network names', PASSWORD_HASH not in text and 'StandInWifi' not in text
              and 'StandInWifi' not in out)
        check('record leaves out proxy settings', 'proxy=' not in text.lower())
    finally:
        sh('umount', mnt)
        sh('losetup', '--detach', loop)
    return app, offset, loop


def grow_like_a_card(image, app):
    """The image written to a card: the file as long as the card, then APP and its
    ext4 grown to the end as the first boot does. Returns the grown APP."""
    mod = fixture.load_tool()
    with open(image, 'rb') as f:
        before = mod.read_gpt(f)[1]
    os.truncate(image, CARD_BYTES)
    p = sh('sfdisk', '--no-reread', '--no-tell-kernel', '-N', '1', image, input=', +\n')
    check('sfdisk grows APP', p.returncode == 0, p.stdout)
    with open(image, 'rb') as f:
        info, parts = mod.read_gpt(f)
    grown = parts[1]
    same = ('start', 'uuid', 'name', 'type', 'attrs')
    check('APP to the card\'s end', all(grown[k] == app[k] for k in same)
          and 0 <= info['last'] - (grown['start'] + grown['size'] - 1) < 2048, grown)
    check('backup GPT at the card\'s end', info['backup'] == CARD_BYTES // 512 - 1, info)
    check('boot partitions unchanged by it', all(parts[n] == before[n] for n in range(2, 15)))
    loop = sh('losetup', '--find', '--show', '--offset', str(grown['start'] * 512), '--sizelimit',
              str(grown['size'] * 512), image).stdout.strip()
    try:
        fsck = sh('e2fsck', '-f', '-y', loop)
        resize = sh('resize2fs', loop)
        check('ext4 grown', fsck.returncode in (0, 1) and resize.returncode == 0, fsck.stdout + resize.stdout)
        blocks = ext4_header(loop)
        check('ext4 fills APP', grown['size'] * 512 - int(blocks['Block count']) * int(blocks['Block size']) < 4096,
              blocks.get('Block count'))
    finally:
        sh('losetup', '--detach', loop)
    return grown


def ext4_header(spec):
    fields = {}
    for line in sh('debugfs', '-R', 'stats -h', spec).stdout.splitlines():
        key, sep, value = line.partition(':')
        if sep:
            fields[key.strip()] = value.strip()
    return fields


def first_boot(tmp, image, app, root):
    loop = sh('losetup', '--find', '--show', '--offset', str(app['start'] * 512), '--sizelimit',
              str(app['size'] * 512), image).stdout.strip()
    mnt = os.path.join(tmp, 'app')
    sh('mount', '-t', 'ext4', loop, mnt)
    a = lambda p: os.path.join(mnt, p)  # noqa: E731
    mounts = [a('proc'), a('sys'), a('dev'), a('run')]
    done = False
    try:
        sh('mount', '-t', 'proc', 'proc', a('proc'))
        sh('mount', '--rbind', '/sys', a('sys'))
        sh('mount', '--rbind', '/dev', a('dev'))
        sh('mount', '-t', 'tmpfs', '-o', 'mode=0755', 'tmpfs', a('run'))   # no DNS: the first boot is offline
        env = ['PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'HOME=/root', 'TERM=dumb']
        print('running the first boot in the chroot (emulated: this takes a while)', flush=True)
        p = sh('chroot', mnt, '/usr/bin/env', '-i', *env, '/usr/lib/nano26/first-boot')
        print('    ' + p.stdout.strip().replace('\n', '\n    '))
        done = check('first boot finished', p.returncode == 0 and 'NANO26_FIRST_BOOT=DONE' in p.stdout, p.returncode)

        def chroot(*cmd):
            return sh('chroot', mnt, '/usr/bin/env', '-i', *env, *cmd).stdout.strip()
        check('systemd 259 installed', chroot('dpkg-query', '-W', '-f', '${Version}', 'systemd').startswith('259'))
        check('dpkg audit clean', chroot('dpkg', '--audit') == '')
        check('account', chroot('getent', 'passwd', 'nano') == 'nano:x:1000:1000:Nano user,,,:/home/nano:/bin/bash')
        groups = chroot('id', '-nG', 'nano').split()
        check('groups', {'nano', 'sudo', 'video', 'adm', 'render', 'input'} <= set(groups) and 'gpio' not in groups,
              groups)
        check('password hash', (chroot('getent', 'shadow', 'nano').split(':') + [''])[1] == PASSWORD_HASH)
        keys = a('home/nano/.ssh/authorized_keys')
        st = os.stat(keys) if os.path.exists(keys) else None
        check('authorized keys', st and (st.st_uid, st.st_gid, st.st_mode & 0o777) == (1000, 1000, 0o600)
              and read(keys) == read(os.path.join(root, 'home/nano/.ssh/authorized_keys')))
        check('time zone', os.readlink(a('etc/localtime')) == '/usr/share/zoneinfo/Asia/Tokyo'
              and os.path.isfile(a('usr/share/zoneinfo/Asia/Tokyo')))
        check('locale', read(a('etc/default/locale')) == 'LANG="en_US.UTF-8"\n'
              and 'en_US.utf8' in chroot('localedef', '--list-archive'))
        rtl = a('usr/lib/firmware/rtlwifi/rtl8188eufw.bin')
        data = read(rtl, 'rb') if os.path.isfile(rtl) else b''
        check('Realtek firmware uncompressed', data and not data.startswith(b'\x28\xb5\x2f\xfd'))
        print('    rtl8188eufw.bin sha256 %s (the reference card pinned 2ff74315...)' % hashlib.sha256(data).hexdigest())
        intel = [n for n in os.listdir(a('usr/lib/firmware')) if n.startswith('iwlwifi-8265-')]
        check('Intel 8265 firmware uncompressed', bool(intel) and not any(n.endswith('.zst') for n in intel)
              and all(os.path.isfile(a('usr/lib/firmware/' + n)) for n in intel), intel)
        conf = read(a('boot/extlinux/extlinux.conf'))
        check('everyday boot entry', 'DEFAULT u26' in conf and 'init=' not in conf)
        check('staged secrets removed', not os.path.exists(a('var/lib/nano26/identity'))
              and not os.path.exists(a('var/lib/nano26/firmware')))
        check('policy-rc.d removed', not os.path.exists(a('usr/sbin/policy-rc.d')))
        check('clock floor for later boots', os.path.isfile(a('usr/lib/clock-epoch')))
        check('machine id', len(read(a('etc/machine-id')).strip()) == 32)
        check('persistent journal', os.path.isdir(a('var/log/journal')))
        check('multi-user target', os.readlink(a('etc/systemd/system/default.target')).endswith('multi-user.target'))
        enabled = chroot('systemctl', 'is-enabled', 'NetworkManager.service', 'systemd-resolved.service',
                         'ssh.socket')
        check('services enabled', enabled.split() == ['enabled', 'enabled', 'enabled'], enabled)
        check('SSH host keys kept', all(read(a('etc/ssh/ssh_host_%s_key' % k)) == 'stand-in\n'
                                        for k in ('rsa', 'ecdsa', 'ed25519')))
        # sshd's effective settings, with a key made for the test (the stand-in keys are not keys).
        sshd = chroot('sh', '-c', "ssh-keygen -q -t ed25519 -N '' -f /tmp/nano26-test-key && mkdir -p /run/sshd"
                      " && sshd -T -h /tmp/nano26-test-key; rm -f /tmp/nano26-test-key /tmp/nano26-test-key.pub")
        check('sshd sends no EF marking', 'ipqos none none' in sshd.splitlines(),
              [line for line in sshd.splitlines() if line.startswith('ipqos')])
        check('network profiles kept', len(os.listdir(a('etc/NetworkManager/system-connections'))) == 2)
        check('resolv.conf is resolved\'s stub', os.readlink(a('etc/resolv.conf')).endswith('run/systemd/resolve/stub-resolv.conf'))
        check('stage 2 enabled', chroot('systemctl', 'is-enabled', 'nano26-stage2.service') == 'enabled')
        installed = chroot('dpkg-query', '-W', '-f', '${Package}\\n', 'lightdm', 'unity-session', 'g++-11', 'gpg',
                           'gstreamer1.0-tools', 'mesa-utils').split()
        check('desktops and tools installed', len(installed) == 6, installed)
        check('first boot log', 'NANO26_FIRST_BOOT=DONE' in read(a('var/log/nano26/first-boot.log'))
              and PASSWORD_HASH not in read(a('var/log/nano26/first-boot.log')))
    finally:
        for m in reversed(mounts):
            if sh('umount', '--recursive', m).returncode:
                sh('umount', '--recursive', '--lazy', m)
        sh('umount', mnt)
        sh('losetup', '--detach', loop)
    return done


# Stand-ins for the repository files stage 2 runs. Each checks what it is
# given and as which account, logs its call to STUB_LOG, and ends with the
# result line of the script it stands in for.
STUB_LOG = '/var/log/nano26/stubs.log'
# The stubs write their .debs themselves: dpkg-deb --build runs tar, which
# under this PC's qemu-aarch64 fails (no openat2, syscall 437).
STUB_PY = '''#!/usr/bin/env python3
import hashlib, io, os, shutil, subprocess, sys, tarfile
def log(*words):
    with open(%(log)r, 'a') as f:
        f.write(' '.join([os.path.basename(sys.argv[0]), str(os.getuid())] + list(words)) + '\\n')
def fail(why):
    print(why)
    sys.exit(1)
def sums_ok(folder):
    return subprocess.run(['sha256sum', '--quiet', '-c', 'SHA256SUMS'], cwd=folder).returncode == 0
def targz(members):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode='w:gz', format=tarfile.GNU_FORMAT) as t:
        for name, data in members:
            i = tarfile.TarInfo(name)
            if data is None:
                i.type, i.mode = tarfile.DIRTYPE, 0o755
                t.addfile(i)
            else:
                i.size, i.mode = len(data), 0o644
                t.addfile(i, io.BytesIO(data))
    return b.getvalue()
def ar(name, data):
    head = '%%-16s%%-12d%%-6d%%-6d%%-8s%%-10d`\\n' %% (name, 0, 0, 0, '100644', len(data))
    return head.encode() + data + b'\\n' * (len(data) %% 2)
def deb(out, name, version):
    control = ('Package: %%s\\nVersion: %%s\\nArchitecture: arm64\\nMaintainer: stub <stub@example.invalid>\\n'
               'Description: stub\\n' %% (name, version)).encode()
    doc = './usr/share/doc/' + name
    data = targz([('./', None), ('./usr/', None), ('./usr/share/', None), ('./usr/share/doc/', None),
                  (doc + '/', None), (doc + '/stub', b'')])
    path = os.path.join(out, '%%s_%%s_arm64.deb' %% (name, version))
    with open(path, 'wb') as f:
        f.write(b'!<arch>\\n' + ar('debian-binary', b'2.0\\n')
                + ar('control.tar.gz', targz([('./', None), ('./control', control)])) + ar('data.tar.gz', data))
    return path
'''
STUBS = {
    'scripts/host/build-nano-l4t-debs.py': STUB_PY + '''
args = sys.argv[1:]
log(*args)
if os.getuid() == 0:
    fail('as root')
inputs, out = args[-2:]
if not sums_ok(inputs):
    fail('inputs do not match')
cc = args[args.index('--cc') + 1] if '--cc' in args else None
if cc and not shutil.which(cc):
    fail('no ' + cc)
os.makedirs(out)
if '--set' in args:
    release = args[args.index('--release') + 1]
    built = [deb(out, 'nano-l4t-%%s-video' %% release, '9.%%s+u26.1' %% release[1:])]
else:
    built = [deb(out, 'nano-l4t-' + p, '35.6.5-20260701022834+u26.1') for p in ('core', 'cuda', 'gl', 'power', 'x11')]
open(os.path.join(out, 'nano-l4t-files.txt'), 'w').close()
with open(os.path.join(out, 'SHA256SUMS'), 'w') as f:
    for p in built + [os.path.join(out, 'nano-l4t-files.txt')]:
        f.write('%%s  %%s\\n' %% (hashlib.sha256(open(p, 'rb').read()).hexdigest(), os.path.basename(p)))
print('NANO_L4T_DEBS=PASS release=stub')
''',
    'scripts/host/build-nano-cuda12-debs.py': STUB_PY + '''
args = sys.argv[1:]
log(*args)
if os.getuid() == 0:
    fail('as root')
key, mirror, out = args[args.index('--key') + 1], args[args.index('--mirror') + 1], args[-1]
if not os.path.isfile(key):
    fail('no key')
os.makedirs(os.path.join(out, 'sources'))
# As the real builder takes its sources: hard links, which need files this account owns.
with open(os.path.join(mirror, 'sets', 'cuda12.txt')) as f:
    for line in f:
        rel = line.split()[1]
        os.link(os.path.join(mirror, rel), os.path.join(out, 'sources', os.path.basename(rel)))
nano = os.path.join(out, 'nano')
os.makedirs(nano)
deb(nano, 'nano-cuda12', '12.6.68+u26.1')
with open(os.path.join(nano, 'install-nano-cuda12.sh'), 'w') as f:
    f.write(\'\'\'#!/bin/bash
echo "install-nano-cuda12.sh $(id -u) SUDO_USER=$SUDO_USER" >> %(log)s
[ "$(id -u)" = 0 ] && [ -n "$SUDO_USER" ] || { echo not root; exit 1; }
dpkg -i "$(dirname "$0")"/nano-cuda12_*.deb || exit 1
echo NANO_CUDA12_INSTALL=PASS record=stub
\'\'\')
print('NANO_CUDA12_DEBS=PASS version=stub')
''',
}
STUB_SH = '''#!/bin/bash
echo "${0##*/} $(id -u) $* SUDO_USER=${SUDO_USER:-}" >> %(log)s
'''
STUBS.update({
    'scripts/jetson/check-u26-r35.sh': STUB_SH + '''
[ "$(id -u)" != 0 ] || { echo as root; exit 1; }
cd "$(dirname "$0")" && sha256sum --quiet -c SHA256SUMS && [ "$(wc -l < SHA256SUMS)" = 7 ] || exit 1
[ "$(dpkg-query -W -f '${Version}' nano-l4t-core)" = 35.6.5-20260701022834+u26.1 ] || exit 1
dpkg-query -W cuda-cudart-11-4 libnvinfer8 > /dev/null || exit 1
echo U26_R35_CHECK=PASS record=stub
''',
    'scripts/jetson/yolo/package-trt82.sh': STUB_SH + '''
[ "$(id -u)" != 0 ] || { echo as root; exit 1; }
[ ! -e /var/lib/nano26/test-fail-trt82 ] || { echo TRT82_PACKAGE=FAIL made to fail; exit 1; }
(cd "$1" && sha256sum --quiet -c SHA256SUMS) || exit 1
for p in libnvinfer-bin libnvinfer8 libnvinfer-plugin8 libnvonnxparsers8 libcudnn8 libcublas10 cuda-cudart-10-2; do
    ls "$1/${p}_"*.deb > /dev/null || exit 1
done
mkdir -p "$HOME/nano-trt82-package" && touch "$HOME/nano-trt82-package/nano-trt82.deb"
echo TRT82_PACKAGE=PASS deb=stub
''',
    'scripts/jetson/yolo/install-trt82.sh': STUB_SH + '''
[ "$(id -u)" = 0 ] && [ -n "$SUDO_USER" ] && [ -f "$1/nano-trt82.deb" ] || exit 1
echo TRT82_INSTALL=PASS record=stub
''',
    'scripts/jetson/enable-u26-fan.sh': STUB_SH + '''
[ "$(id -u)" = 0 ] || exit 1
echo U26_FAN=PASS
''',
    'scripts/jetson/enable-hdmi-wake.sh': STUB_SH + '''
[ "$(id -u)" = 0 ] || exit 1
echo HDMI_WAKE_FIX=PASS
''',
    'scripts/jetson/probe-l4t-video.sh': STUB_SH + '''
[ "$(id -u)" != 0 ] || { echo as root; exit 1; }
cd "$(dirname "$0")" && sha256sum --quiet -c SHA256SUMS && [ "$(wc -l < SHA256SUMS)" = 4 ] || exit 1
dpkg-query -W "nano-l4t-$2-video" > /dev/null || exit 1
echo L4T_VIDEO_PROBE=PASS release=$2
''',
})


def stage2(tmp, image, app, again=False):
    loop = sh('losetup', '--find', '--show', '--offset', str(app['start'] * 512), '--sizelimit',
              str(app['size'] * 512), image).stdout.strip()
    mnt = os.path.join(tmp, 'app')
    sh('mount', '-t', 'ext4', loop, mnt)
    a = lambda p: os.path.join(mnt, p.lstrip('/'))  # noqa: E731
    mounts = [a('proc'), a('sys'), a('dev'), a('run')]
    env = ['PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'HOME=/root', 'TERM=dumb']

    def chroot(*cmd):
        return sh('chroot', mnt, '/usr/bin/env', '-i', *env, *cmd)
    try:
        sh('mount', '-t', 'proc', 'proc', a('proc'))
        sh('mount', '--rbind', '/sys', a('sys'))
        sh('mount', '--rbind', '/dev', a('dev'))
        sh('mount', '-t', 'tmpfs', '-o', 'mode=0755', 'tmpfs', a('run'))   # no systemd: stage 2 does not restart
        if again:   # --stage2-again: the working tree's stage 2, from its start
            if os.path.exists(a('var/lib/nano26/stage2.done')):
                return check('kept image\'s stage 2 not finished', False)
            shutil.copyfile(STAGE2, a('usr/lib/nano26/stage2'))
            for rel in ('var/lib/nano26/stage2', 'var/lib/nano26/build'):
                shutil.rmtree(a(rel), ignore_errors=True)
            for rel in ('var/log/nano26/stage2.log', 'var/log/nano26/report.txt'):
                if os.path.exists(a(rel)):
                    os.unlink(a(rel))
        repo = a('usr/lib/nano26/repo')
        for rel, text in STUBS.items():
            with open(os.path.join(repo, rel), 'w') as f:
                f.write(text % {'log': STUB_LOG})
        sh('sh', '-c', 'cd "$1" && sha256sum $(cut -c 67- SHA256SUMS) > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS',
           'sh', repo)
        with open(a(STUB_LOG), 'w') as f:
            os.fchmod(f.fileno(), 0o666)
        with open(a('var/lib/nano26/test-fail-trt82'), 'w'):
            pass
        print('running stage 2 in the chroot with stubs, made to fail at the TensorRT 8.2 build', flush=True)
        p = chroot('/usr/lib/nano26/stage2')
        print('    ' + p.stdout.strip().replace('\n', '\n    '))
        check('stage 2 stops at the failed step', p.returncode == 1 and 'FAILED: trt82-build' in p.stdout
              and 'NANO26_STAGE2=FAILED' in p.stdout, p.returncode)
        marks = sorted(os.listdir(a('var/lib/nano26/stage2')))
        check('steps before it marked', marks == sorted(n + '.done' for n in (
            'l4t-build', 'l4t-install', 'r35-check', 'cuda12-build', 'cuda12-install')), marks)
        sets = sorted(os.listdir(a('var/lib/nano26/mirror/sets')))
        check('installed sets dropped from the copy', sets == ['trt82.txt'], sets)
        check('still the text login', os.readlink(a('etc/systemd/system/default.target')).endswith('multi-user.target'))

        os.unlink(a('var/lib/nano26/test-fail-trt82'))
        print('running stage 2 again', flush=True)
        p = chroot('/usr/lib/nano26/stage2')
        print('    ' + p.stdout.strip().replace('\n', '\n    '))
        check('stage 2 finished', p.returncode == 0 and 'NANO26_STAGE2=DONE' in p.stdout, p.returncode)
        check('it resumed at the failed step', 'l4t-build: passed before' in p.stdout
              and 'cuda12-install: passed before' in p.stdout)
        calls = [line.split() for line in read(a(STUB_LOG)).splitlines()]
        who = [(c[0], c[1]) for c in calls]
        check('stubs called in order, as whom', who == [
            ('build-nano-l4t-debs.py', '1000')] * 3 + [
            ('check-u26-r35.sh', '1000'), ('build-nano-cuda12-debs.py', '1000'), ('install-nano-cuda12.sh', '0'),
            ('package-trt82.sh', '1000'), ('package-trt82.sh', '1000'), ('install-trt82.sh', '0'),
            ('enable-u26-fan.sh', '0'), ('enable-hdmi-wake.sh', '0'),
            ('probe-l4t-video.sh', '1000'), ('probe-l4t-video.sh', '1000')], who)
        line = ' '.join(' '.join(c) for c in calls)
        check('builders\' arguments', '--release r35 /var/lib/nano26/build/l4t-inputs /var/lib/nano26/build/l4t-r35' in line
              and '--set video --release r32 --cc gcc-11' in line and '--set video --release r35 --cc gcc-11' in line
              and '--key /var/lib/nano26/mirror/keys/jetson-ota-public.asc --mirror /var/lib/nano26/mirror' in line
              and 'SUDO_USER=nano' in line and '--installed r35' in line and '--installed r32' in line)
        versions = dict(l.split(' ', 1) for l in chroot('dpkg-query', '-W', '-f', '${Package} ${Version}\\n').stdout.splitlines())
        plan = json.load(open(fixture.PLAN))
        nvidia = [f[:-len('.deb')].split('_')[:2] for f in plan['install_pins']]
        check('NVIDIA\'s 19 installed', all(versions.get(n) == v for n, v in nvidia), nvidia)
        check('nano-l4t set installed', all(versions.get('nano-l4t-' + p) == '35.6.5-20260701022834+u26.1'
                                            for p in ('core', 'cuda', 'gl', 'power', 'x11'))
              and 'nano-l4t-r32-video' in versions and 'nano-l4t-r35-video' in versions)
        check('nano-cuda12 installed', 'nano-cuda12' in versions)
        check('dpkg audit clean', chroot('dpkg', '--audit').stdout == '')
        try:   # reads that a failed step leaves without a file fail their check, not the test
            gpu = got(a('etc/lightdm/lightdm.conf.d/60-jetson-gpu.conf'))
            check('LightDM on the GPU X server', 'xserver-command=/usr/lib/nano-xorg/Xorg -nolisten tcp' in gpu)
            greeter = got(a('etc/lightdm/lightdm-gtk-greeter.conf'))
            check('greeter with the session menu', 'indicators=~host;~spacer;~clock;~spacer;~session;~power\n' in greeter
                  and 'theme-name=Yaru-dark' in greeter, greeter)
            check('Unity defaults compiled', os.path.isfile(a('usr/share/glib-2.0/schemas/90_nano-u26-unity.gschema.override'))
                  and os.path.getmtime(a('usr/share/glib-2.0/schemas/gschemas.compiled'))
                  >= os.path.getmtime(a('usr/share/glib-2.0/schemas/90_nano-u26-unity.gschema.override')))
            check('xsettings themed', 'Yaru-dark' in got(a('etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml')))
            check('card partitions hidden', 'UDISKS_IGNORE' in got(a('etc/udev/rules.d/80-nano-hide-card.rules')))
            enabled = chroot('systemctl', 'is-enabled', 'lightdm.service', 'nano26-stage2.service').stdout.split()
            check('LightDM on, stage 2 off', enabled == ['enabled', 'disabled'], enabled)
            check('desktop by default', os.readlink(a('etc/systemd/system/default.target')).endswith('graphical.target'))
            check('copy and builds removed', not os.path.exists(a('var/lib/nano26/mirror'))
                  and not os.path.exists(a('var/lib/nano26/build')) and not os.path.exists(a('home/nano/nano-trt82-package')))
            report = got(a('var/log/nano26/report.txt'))
            check('report', 'FAILED trt82-build' in report and report.count('PASS ') >= 10 and 'DONE ' in report
                  and 'U26_R35_CHECK=PASS' in report and 'L4T_VIDEO_PROBE=PASS release=r32' in report, report)
            check('stage 2 done', os.path.isfile(a('var/lib/nano26/stage2.done')))
            unit = chroot('systemd-analyze', 'verify', '--man=no', '/etc/systemd/system/nano26-stage2.service')
            check('stage 2 unit verifies', unit.returncode == 0, unit.stdout)
        except OSError as e:
            check('stage 2\'s files', False, e)
    finally:
        for m in reversed(mounts):
            if sh('umount', '--recursive', m).returncode:
                sh('umount', '--recursive', '--lazy', m)
        sh('umount', mnt)
        sh('losetup', '--detach', loop)


def main():
    if os.geteuid() != 0:
        raise SystemExit('run as root: the test uses loop devices, mounts and a chroot')
    if os.environ.get('NANO26_TEST_NS') != '1':
        os.environ['NANO26_TEST_NS'] = '1'
        os.execvp('unshare', ['unshare', '--mount', '--propagation', 'private', sys.executable,
                              os.path.abspath(__file__)] + sys.argv[1:])
    if '--stage2-again' in sys.argv:
        tmp = os.path.abspath(sys.argv[sys.argv.index('--stage2-again') + 1])
        fixture.PLAN = os.path.join(tmp, 'plan.json')
        image = os.path.join(tmp, 'new.img')
        with open(image, 'rb') as f:
            app = fixture.load_tool().read_gpt(f)[1][1]
        stage2(tmp, image, app, again=True)
        print('NANO26_IMAGE_TEST=%s%s' % ('FAIL ' if failures else 'PASS', ', '.join(failures)))
        return 1 if failures else 0
    keep = '--keep' in sys.argv
    tmp = tempfile.mkdtemp(prefix='nano26-image-')
    try:
        os.makedirs(os.path.join(tmp, 'home'))
        source = make_source(tmp)
        root = make_root(tmp)
        fixture.make_stand_ins(tmp, root)
        kernel = os.path.join(tmp, 'kernel')
        fixture.make_kernel(kernel)
        plan, bundle = fixture.make_kernel_bundle(tmp, kernel, fixture.PLAN)
        if not check('kernel packed as its release', plan is not None):
            return 1
        fixture.PLAN = plan
        fetched = set(glob.glob('/var/tmp/nano26-kernel-*'))
        image = os.path.join(tmp, 'new.img')
        print('writing the image (downloads from Ubuntu: this takes a while)', flush=True)
        env = dict(os.environ, HOME=os.path.join(tmp, 'home'))
        for key in ('NANO26_NS', 'SUDO_USER', 'SUDO_UID', 'SUDO_GID'):
            env.pop(key, None)
        p = sh(sys.executable, TOOL, '--root', root, '--source-disk', source, '--target-image', image,
               '--skip-network-check', '--confirm', 'new.img',
               '--accept-nvidia-licences', '--nvidia-test-plan', fixture.PLAN, env=env)
        print('    ' + p.stdout.strip().replace('\n', '\n    '))
        if not check('converter finished', p.returncode == 0 and 'NANO26_CONVERT=DONE' in p.stdout, p.returncode):
            return 1
        check('kernel downloaded, its folder removed', 'The 5.10 kernel: downloading %s' % os.path.basename(bundle)
              in p.stdout and set(glob.glob('/var/tmp/nano26-kernel-*')) == fetched)
        app, offset, _ = check_image(tmp, source, image, kernel, root, p.stdout)
        if '--no-first-boot' not in sys.argv:
            app = grow_like_a_card(image, app)
            if first_boot(tmp, image, app, root):
                stage2(tmp, image, app)
        print('image file: %s of %s used' % (fixture.human_bytes(os.stat(image).st_blocks * 512),
                                             fixture.human_bytes(os.path.getsize(image))))
    finally:
        if keep:
            print('kept: ' + tmp)
        else:
            shutil.rmtree(tmp)
    print('NANO26_IMAGE_TEST=%s%s' % ('FAIL ' if failures else 'PASS', ', '.join(failures)))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())

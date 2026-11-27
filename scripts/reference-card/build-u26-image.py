#!/usr/bin/env python3
"""Build the reference card's image with only Ubuntu 26.04 and the 5.10 kernel (stage 6).

Usage: python3 scripts/reference-card/build-u26-image.py BACKUP_DIR [OUT_DIR]

BACKUP_DIR is a passed backup-card.sh record of the reference card, read after
set-u26-default.sh made 26.04 the default boot and the Nano shut down from
26.04. Run as the ordinary user: it reads that backup and writes only under
OUT_DIR/<stamp>/ (an existing folder; artifacts/u26-image by default), never
to a card. restore-card.sh then writes
the image to the reference card (its stage 6: a card holding only Ubuntu 26.04).

The image, reference-card-u26.img, is the card's size and sparse:
- The GPT and the 13 small JetPack boot partitions (2 to 14): every byte and
  every table entry as on the card.
- UBUNTU26 (partition 15) removed, and APP (partition 1: same start, type,
  name and attributes) grown to the end of the card.
- APP's filesystem is UBUNTU26's, checked, given the ext4 features of APP's
  old filesystem, which U-Boot reads today (resize2fs -s turns 64bit off,
  tune2fs turns metadata_csum off), grown to fit, with a new UUID that
  /etc/fstab names. /boot holds the 5.10 kernel, device tree and initrd that
  APP's u26 entry boots now, and an extlinux.conf with that one entry, root=
  on APP's new PARTUUID. JetPack 4's kernel and Ubuntu 18.04 (APP's old
  filesystem) are not in it.
- A new disk GUID and APP PARTUUID, so the card no longer shares those of the card it was copied from.

Every step is checked by reading it back. The last line is
U26_IMAGE=PASS or FAIL.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

CARD_BYTES = 63864569856
SECTOR = 512
APP_PARTUUID = '5ac80d7c-40fb-4796-bd56-4110e389819b'
U26_PARTUUID = '8926eb56-1d64-469c-83cd-1b44d9501894'
KERNEL = '5.10.216-tegra'
PROJECT = Path(__file__).resolve().parents[2]
CHUNK = 4 << 20
ZERO = bytes(CHUNK)
# ext4 features UBUNTU26 may have that APP's old filesystem lacks, and the
# command that turns each off. U-Boot reads APP's old filesystem today, so the
# new one gets exactly its features.
TURN_OFF = {'64bit': ('resize2fs', '-s'), 'metadata_csum': ('tune2fs', '-O', '^metadata_csum')}
OUT_NAME = 'reference-card-u26.img'


def tool(name):
    found = shutil.which(name) or next((p for p in (f'/usr/sbin/{name}', f'/sbin/{name}')
                                        if os.access(p, os.X_OK)), None)
    assert found, f'no {name}'
    return found


def run(*args, ok=(0,), stdin=None):
    proc = subprocess.run([tool(args[0]), *args[1:]], input=stdin, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, universal_newlines=True,
                          env={**os.environ, 'LC_ALL': 'C'})
    assert proc.returncode in ok, f'{" ".join(args)} exited {proc.returncode}:\n{proc.stdout}'
    return proc.stdout


def say(*parts):
    print(*parts, flush=True)


def sha256_of(path, start=0, length=None):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        f.seek(start)
        left = os.fstat(f.fileno()).st_size - start if length is None else length
        while left:
            data = f.read(min(CHUNK, left))
            assert data, f'{path} ends early'
            h.update(data)
            left -= len(data)
    return h.hexdigest()


def copy_region(src, dst, src_off, dst_off, length):
    """Copy length bytes, leaving all-zero chunks as holes in dst; return their SHA-256."""
    h = hashlib.sha256()
    with open(src, 'rb') as s, open(dst, 'r+b') as d:
        s.seek(src_off)
        done = 0
        while done < length:
            data = s.read(min(CHUNK, length - done))
            assert data, f'{src} ends early'
            h.update(data)
            if data != ZERO[:len(data)]:
                d.seek(dst_off + done)
                d.write(data)
            done += len(data)
        d.flush()
        os.fsync(d.fileno())
    return h.hexdigest()


def table(path):
    pt = json.loads(run('sfdisk', '--json', str(path)))['partitiontable']
    assert pt['label'] == 'gpt' and pt.get('sectorsize', SECTOR) == SECTOR, pt
    parts = {}
    for p in pt['partitions']:
        number = int(re.search(r'(\d+)$', p['node']).group(1))
        parts[number] = {k: p.get(k) for k in ('start', 'size', 'type', 'uuid', 'name', 'attrs')}
        parts[number]['uuid'] = parts[number]['uuid'].lower()
    return pt, parts


def superblock(spec):
    # debugfs, as dumpe2fs 1.47.1 and later reject a FILE?offset=N name.
    out = run('debugfs', '-R', 'stats -h', spec)
    sb = {}
    for line in out.splitlines():
        key, sep, value = line.partition(':')
        if sep:
            sb.setdefault(key.strip(), value.strip())
    assert sb.get('Filesystem magic number') == '0xEF53', f'no ext4 superblock in {spec}:\n{out}'
    return sb


def debugfs(spec, *commands, write=False):
    with tempfile.NamedTemporaryFile('w', suffix='.debugfs') as f:
        f.write('\n'.join(commands) + '\n')
        f.flush()
        return run('debugfs', *(['-w'] if write else []), '-f', f.name, spec)


def cat(spec, path):
    """A file's bytes from an ext4 filesystem, through debugfs dump."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / 'f'
        debugfs(spec, f'dump {path} {out}')
        assert out.exists(), f'no {path} in {spec}'
        return out.read_bytes()


def inode(spec, path):
    """Type, mode, owner and size of path, or None if it does not exist."""
    out = run('debugfs', '-R', f'stat {path}', spec)
    m = re.search(r'Type: (\S+)\s+Mode:\s+(\d+).*?User:\s+(\d+)\s+Group:\s+(\d+).*?Size: (\d+)', out, re.S)
    return None if not m else {'type': m[1], 'mode': m[2], 'uid': int(m[3]), 'gid': int(m[4]),
                               'size': int(m[5])}


def fsck(path, label):
    """e2fsck -f must find nothing to fix (exit 0); it also marks the check done."""
    run('e2fsck', '-f', '-y', str(path))
    say(f'FSCK {label}: clean')


def u26_entry(conf):
    """The u26 entry's LINUX, FDT, INITRD and APPEND from APP's default extlinux file."""
    text = conf.decode()
    assert re.findall(r'^DEFAULT (\S+)$', text, re.M) == ['u26'], \
        "APP's extlinux.conf does not boot u26 by default: run set-u26-default.sh first"
    starts = [m.start() for m in re.finditer(r'(?m)^LABEL ', text)]
    blocks = [text[a:b] for a, b in zip(starts, starts[1:] + [len(text)])]
    u26 = [b for b in blocks if b.startswith('LABEL u26\n')]
    assert len(u26) == 1, 'no single u26 entry'
    entry = {}
    for line in u26[0].splitlines()[1:]:
        key, _, value = line.strip().partition(' ')
        if key in ('LINUX', 'FDT', 'INITRD', 'APPEND'):
            assert key not in entry, f'two {key} lines in the u26 entry'
            entry[key] = value.strip()
    assert set(entry) == {'LINUX', 'FDT', 'INITRD', 'APPEND'}, entry
    args = entry['APPEND'].split()
    assert args.count('root=PARTUUID=' + U26_PARTUUID) == 1 and not any(
        a.startswith(('init=', 'systemd.mask=')) for a in args), entry['APPEND']
    for key in ('LINUX', 'FDT', 'INITRD'):
        assert re.fullmatch(r'/boot/[A-Za-z0-9._/-]+', entry[key]) and '..' not in entry[key], entry[key]
    return entry


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__.split('\n\n')[1])
    backup = Path(sys.argv[1]).resolve()
    if len(sys.argv) == 3:
        root = Path(sys.argv[2]).resolve()
        assert root.is_dir(), f'no folder {root}'
    else:
        root = PROJECT / 'artifacts/u26-image'
    record = (backup / 'backup.txt').read_text()
    assert re.search(r'^status=PASS$', record, re.M) and re.search(rf'^bytes={CARD_BYTES}$', record, re.M), \
        f'{backup}/backup.txt is not a passed backup of a card of {CARD_BYTES} bytes'
    sums = (backup / 'SHA256SUMS').read_text().split()
    assert len(sums) == 2 and re.fullmatch(r'[0-9a-f]{64}', sums[0]) and '/' not in sums[1], sums
    source, source_sha = backup / sums[1], sums[0]
    assert source.stat().st_size == CARD_BYTES, f'{source} is not {CARD_BYTES} bytes'

    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out_dir = root / stamp
    out_dir.mkdir(parents=True)
    MADE.append(out_dir)
    os.chmod(out_dir, 0o700)
    work = out_dir / 'work'
    work.mkdir()
    assert not re.search(r'\s', str(work)), f'debugfs cannot take the path {work}'

    out = out_dir / OUT_NAME
    say(f'RECORD={out_dir}\nSOURCE={source}')
    say('Checking the backup against its SHA-256 (reads the whole file)...')
    assert sha256_of(source) == source_sha, f'{source} does not match its SHA256SUMS'
    say(f'SOURCE_SHA256={source_sha}')

    # --- The card's table: the reference card's 15 partitions, APP and UBUNTU26 last.
    pt, parts = table(source)
    assert sorted(parts) == list(range(1, 16)), f'partitions {sorted(parts)}, not 1 to 15'
    app, u26 = parts[1], parts[15]
    assert app['name'] == 'APP' and app['uuid'] == APP_PARTUUID, app
    assert u26['name'] == 'UBUNTU26' and u26['uuid'] == U26_PARTUUID, u26
    end = lambda p: p['start'] + p['size'] - 1
    boot = {n: parts[n] for n in range(2, 15)}
    assert all(end(p) < app['start'] for p in boot.values()), 'a boot partition lies after APP'
    assert end(app) < u26['start'] and end(u26) <= pt['lastlba'], 'UBUNTU26 does not follow APP'
    say(f'DISK_ID {pt["id"].lower()} firstlba {pt["firstlba"]} lastlba {pt["lastlba"]}')
    for n, p in sorted(parts.items()):
        say(f'PART {n} {p["name"]} start {p["start"]} size {p["size"]} {p["uuid"]}')

    # --- The 26.04 filesystem, and APP's boot files and features.
    app_spec = f'{source}?offset={app["start"] * SECTOR}'
    app_sb = superblock(app_spec)
    entry = u26_entry(cat(app_spec, '/boot/extlinux/extlinux.conf'))
    say(f'U26_ENTRY LINUX {entry["LINUX"]} FDT {entry["FDT"]} INITRD {entry["INITRD"]}')
    boot_files = {}
    for key in ('LINUX', 'FDT', 'INITRD'):
        assert (inode(app_spec, entry[key]) or {}).get('type') == 'regular', f'{entry[key]} is not a file on APP'
        data = cat(app_spec, entry[key])
        local = work / Path(entry[key]).name
        local.write_bytes(data)
        os.chmod(local, 0o644)
        boot_files[entry[key]] = hashlib.sha256(data).hexdigest()
        say(f'BOOT_FILE {entry[key]} {len(data)} bytes {boot_files[entry[key]]}')
    nvgpu_rel = re.search(r'^(kernel/\S*/nvgpu\.ko):', cat(app_spec, f'/lib/modules/{KERNEL}/modules.dep')
                          .decode(), re.M).group(1)
    nvgpu = hashlib.sha256(cat(app_spec, f'/lib/modules/{KERNEL}/{nvgpu_rel}')).hexdigest()

    # A working copy of the filesystem and the image each hold its used blocks.
    sb = superblock(f'{source}?offset={u26["start"] * SECTOR}')
    used = (int(sb['Block count']) - int(sb['Free blocks'])) * int(sb['Block size'])
    need = 2 * used + 2 * 2**30
    free = shutil.disk_usage(out_dir).free
    assert free > need, f'{free} bytes free under {out_dir}; {need} needed'
    say(f'UBUNTU26_USED={used} FREE={free}')
    fs = work / 'app.ext4'
    with open(fs, 'wb') as f:
        f.truncate(u26['size'] * SECTOR)
    say('Copying UBUNTU26 out of the backup...')
    copy_region(source, fs, u26['start'] * SECTOR, 0, u26['size'] * SECTOR)
    sb = superblock(str(fs))
    old_uuid = sb['Filesystem UUID'].lower()
    features = set(sb['Filesystem features'].split())
    app_features = set(app_sb['Filesystem features'].split())
    say(f'UBUNTU26_FS {old_uuid} label {sb.get("Filesystem volume name")} state {sb["Filesystem state"]}'
        f' features {" ".join(sorted(features))}')
    say(f'OLD_APP_FS features {" ".join(sorted(app_features))}')
    assert sb['Filesystem state'] == 'clean' and 'needs_recovery' not in features, \
        'UBUNTU26 was not cleanly unmounted: shut the Nano down from 26.04 and take the backup again'
    extra = features - app_features
    assert extra <= set(TURN_OFF), \
        f'UBUNTU26 uses {sorted(extra - set(TURN_OFF))}, which APP does not, and this cannot turn them off'
    fstab = cat(str(fs), '/etc/fstab').decode()
    root_lines = [l for l in fstab.splitlines() if l.split()[1:2] == ['/'] and not l.startswith('#')]
    assert len(root_lines) == 1 and root_lines[0].split()[0].lower() == f'uuid={old_uuid}', \
        f"/etc/fstab's root line is not UUID={old_uuid}: {root_lines}"
    for path in ('/usr/lib/systemd/systemd', f'/usr/lib/modules/{KERNEL}/modules.dep'):
        assert inode(str(fs), path), f'the 26.04 root has no {path}'
    root_nvgpu = hashlib.sha256(cat(str(fs), f'/usr/lib/modules/{KERNEL}/{nvgpu_rel}')).hexdigest()
    assert root_nvgpu == nvgpu, "26.04's nvgpu.ko is not the one APP's kernel was built with"
    say(f'MODULES nvgpu.ko {nvgpu} in both')
    os_release = cat(str(fs), '/usr/lib/os-release').decode()
    assert re.search(r'^VERSION_ID="26\.04"$', os_release, re.M), 'the root is not Ubuntu 26.04'
    boot_dir = inode(str(fs), '/boot')
    assert boot_dir and boot_dir['type'] == 'directory', '/boot is not a directory in the 26.04 root'
    for path in {str(Path(p).parent) for p in boot_files} | {'/boot/extlinux'}:
        assert inode(str(fs), path) is None, f'the 26.04 root already has {path}'
    fsck(fs, 'UBUNTU26 as read')
    for feature in sorted(extra):
        say(f'Turning off {feature}...')
        run(*TURN_OFF[feature], str(fs))
        fsck(fs, f'without {feature}')
    features = set(superblock(str(fs))['Filesystem features'].split())
    assert features == app_features, \
        f"the filesystem's features {sorted(features)} are not APP's {sorted(app_features)}"
    say(f'FEATURES as APP: {" ".join(sorted(features))}')

    # --- The new table: UBUNTU26 out, APP to the end of the card, new identifiers.
    with open(out, 'wb') as f:
        f.truncate(CARD_BYTES)
    head = app['start'] * SECTOR
    tail = (pt['lastlba'] + 1) * SECTOR
    copy_region(source, out, 0, 0, head)
    copy_region(source, out, tail, tail, CARD_BYTES - tail)
    disk_id, app_uuid = str(uuid.uuid4()), str(uuid.uuid4())
    sf = ('sfdisk', '-q', '--no-reread', '--no-tell-kernel', '--wipe', 'never')
    run(*sf, '--delete', str(out), '15')
    run(*sf, '--wipe-partitions', 'never', '-N', '1', str(out), stdin=', +\n')
    run(*sf, '--disk-id', str(out), disk_id)
    run(*sf, '--part-uuid', str(out), '1', app_uuid)
    run('sfdisk', '--verify', str(out))
    new_pt, new_parts = table(out)
    assert sorted(new_parts) == list(range(1, 15)), sorted(new_parts)
    assert all(new_parts[n] == boot[n] for n in boot), 'a boot partition entry changed'
    new_app = new_parts[1]
    assert {k: new_app[k] for k in ('start', 'type', 'name', 'attrs')} == \
        {k: app[k] for k in ('start', 'type', 'name', 'attrs')}, new_app
    assert new_app['uuid'] == app_uuid and end(new_app) == pt['lastlba'], new_app
    assert new_pt['id'].lower() == disk_id and (new_pt['firstlba'], new_pt['lastlba']) == \
        (pt['firstlba'], pt['lastlba']), new_pt
    say(f'NEW_TABLE disk {disk_id}, APP {app_uuid} start {new_app["start"]} size {new_app["size"]}')

    # --- The filesystem: grown, new UUID, fstab and /boot.
    with open(fs, 'r+b') as f:
        f.truncate(new_app['size'] * SECTOR)
    say('Growing the filesystem...')
    run('resize2fs', str(fs))
    fsck(fs, 'grown')
    fs_uuid = str(uuid.uuid4())
    run('tune2fs', '-U', fs_uuid, str(fs))
    fsck(fs, 'new UUID')
    old_fstab = inode(str(fs), '/etc/fstab')
    new_fstab = work / 'fstab'
    new_fstab.write_text(re.sub(rf'(?im)^UUID={old_uuid}(?=\s)', f'UUID={fs_uuid}', fstab, count=1))
    os.chmod(new_fstab, 0o644)
    conf = '\n'.join([
        'TIMEOUT 30', 'DEFAULT u26', '', 'MENU TITLE L4T boot options', '',
        'LABEL u26', '      MENU LABEL Ubuntu 26.04 on the JetPack 5 kernel',
        f'      LINUX {entry["LINUX"]}', f'      FDT {entry["FDT"]}', f'      INITRD {entry["INITRD"]}',
        '      APPEND ' + entry['APPEND'].replace('root=PARTUUID=' + U26_PARTUUID,
                                                  'root=PARTUUID=' + app_uuid)]) + '\n'
    local_conf = work / 'extlinux.conf'
    local_conf.write_text(conf)
    os.chmod(local_conf, 0o644)
    commands = ['rm /etc/fstab', 'cd /etc', f'write {new_fstab} fstab',
                f'sif /etc/fstab mode 0{int(old_fstab["mode"], 8) | 0o100000:o}',
                f'sif /etc/fstab uid {old_fstab["uid"]}', f'sif /etc/fstab gid {old_fstab["gid"]}']
    wanted = {'/etc/fstab': (new_fstab, old_fstab['mode'], old_fstab['uid'], old_fstab['gid']),
              '/boot/extlinux/extlinux.conf': (local_conf, '0644', 0, 0)}
    for path in [entry['LINUX'], entry['FDT'], entry['INITRD']]:
        wanted[path] = (work / Path(path).name, '0644', 0, 0)
    made = set()
    for path, (local, _, _, _) in wanted.items():
        if path == '/etc/fstab':
            continue
        parent = str(Path(path).parent)
        if parent not in made:
            commands.append(f'mkdir {parent}')
            made.add(parent)
        commands += [f'cd {parent}', f'write {local} {Path(path).name}', 'cd /']
    debugfs(str(fs), *commands, write=True)
    for path, (local, mode, uid, gid) in wanted.items():
        got = inode(str(fs), path)
        assert got and got['type'] == 'regular' and (got['mode'], got['uid'], got['gid']) == \
            (mode, uid, gid), f'{path}: {got}'
        assert cat(str(fs), path) == local.read_bytes(), f'{path} did not take'
    for path in {str(Path(p).parent) for p in wanted if p.startswith('/boot/')}:
        got = inode(str(fs), path)
        assert got and (got['type'], got['mode'], got['uid'], got['gid']) == ('directory', '0755', 0, 0), got
    fsck(fs, 'with /boot')
    sb = superblock(str(fs))
    assert sb['Filesystem UUID'].lower() == fs_uuid and set(sb['Filesystem features'].split()) == features, sb
    say(f'NEW_FS {fs_uuid} {int(sb["Block count"]) * int(sb["Block size"])} bytes')

    # --- APP into the image, and the whole image read back.
    say('Writing APP into the image...')
    # resize2fs leaves the file at a whole number of blocks; the rest of the
    # partition is zeros.
    assert fs.stat().st_size <= new_app['size'] * SECTOR, 'the filesystem is larger than APP'
    with open(fs, 'r+b') as f:
        f.truncate(new_app['size'] * SECTOR)
    fs_sha = copy_region(fs, out, 0, new_app['start'] * SECTOR, fs.stat().st_size)
    say('Checking the image...')
    assert sha256_of(out, new_app['start'] * SECTOR, new_app['size'] * SECTOR) == fs_sha, 'APP did not take'
    firmware = {}
    for n, p in sorted(boot.items()):
        a = sha256_of(source, p['start'] * SECTOR, p['size'] * SECTOR)
        b = sha256_of(out, p['start'] * SECTOR, p['size'] * SECTOR)
        assert a == b, f'partition {n} ({p["name"]}) differs from the card'
        firmware[p['name']] = a
    image_spec = f'{out}?offset={new_app["start"] * SECTOR}'
    assert cat(image_spec, '/boot/extlinux/extlinux.conf').decode() == conf, "the image's extlinux.conf differs"
    assert superblock(image_spec)['Filesystem UUID'].lower() == fs_uuid, "the image's APP has another UUID"
    shutil.rmtree(work)
    say('Hashing the image...')
    image_sha = sha256_of(out)
    (out_dir / 'SHA256SUMS').write_text(f'{image_sha}  {OUT_NAME}\n')
    manifest = {
        'made_utc': stamp, 'source': str(source), 'source_sha256': source_sha,
        'image': OUT_NAME, 'image_sha256': image_sha, 'bytes': CARD_BYTES,
        'disk_id': {'card': pt['id'].lower(), 'image': disk_id},
        'app': {'start': new_app['start'], 'size': new_app['size'], 'partuuid': app_uuid,
                'card_partuuid': APP_PARTUUID, 'fs_uuid': fs_uuid, 'from_fs_uuid': old_uuid,
                'features': sorted(features), 'sha256': fs_sha},
        'removed': {'partition': 15, **u26},
        'boot_files': boot_files, 'nvgpu_ko': nvgpu, 'extlinux_conf': conf,
        'firmware_partitions': firmware,
    }
    (out_dir / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    say('extlinux.conf:\n' + conf.rstrip())
    say(f'IMAGE={out}\nIMAGE_SHA256={image_sha}')
    say(f'U26_IMAGE=PASS record={out_dir}')


MADE = []  # the record folder, once made

if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as e:
        # The working copy and a partial image are large and of no use.
        for folder in MADE:
            shutil.rmtree(folder / 'work', ignore_errors=True)
            if (folder / OUT_NAME).exists():
                (folder / OUT_NAME).unlink()
        print(f'U26_IMAGE=FAIL: {e or repr(e)}', file=sys.stderr)
        sys.exit(1)

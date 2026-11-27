#!/usr/bin/env python3
"""Add a partition for Ubuntu 26.04 in the reference card's free space, offline in the PC's reader.

Usage: sudo python3 scripts/reference-card/add-u26-partition.py DISK [--dry-run]

DISK is the reference card's freshly identified whole-disk device (for example /dev/sdd),
with none of its partitions mounted. The script checks that it is the reference card: its
size, a USB reader, a GPT with 14 partitions, APP with the reference card's size and
PARTUUID as the last partition on the card, and the backup GPT at the card's
end. It then appends one partition, UBUNTU26, in the space after APP, with new
random identifiers, and makes an ext4 filesystem on it with features the 5.10
kernel supports. Partitions 1 to 14 are checked unchanged afterwards.

If an earlier run added UBUNTU26 but stopped before mkfs, a rerun finds that
entry where the plan puts it, checks that it holds no filesystem or other
signature, and only makes the filesystem.

Before touching the card it rehearses both steps on sparse files under
artifacts/u26/: the card's table copied onto a file of the card's size gets the
same append, and a file of the new partition's size gets the same mkfs, with
the same checks. That catches a different sfdisk or mke2fs on this PC.

It writes only the GPT (both copies) and the new partition. It never writes
the other partitions, the Nano's QSPI or another disk. --dry-run prints the
plan, rehearses it and writes nothing to the card. A record goes to
artifacts/u26/.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

CARD_BYTES = 63864569856                   # the reference card (2026-10-13)
APP_BYTES = 31253835776
APP_PARTUUID = '5ac80d7c-40fb-4796-bd56-4110e389819b'
PARTITIONS = 14                            # 13 small JetPack partitions and APP
MIN_BYTES = 32 * 10**9                     # 32,596,037,120 free after APP (2026-10-13)
NAME = 'UBUNTU26'
LINUX_FS = '0FC63DAF-8483-4772-8E79-3D69D8477DE4'
ALIGN = 2048                               # 1 MiB in 512-byte sectors
# Spelled out rather than taken from the PC's mke2fs.conf, whose defaults may
# include features 5.10 lacks (orphan_file came in 5.15).
FEATURES = ['has_journal', 'ext_attr', 'resize_inode', 'dir_index', 'filetype',
            'extent', '64bit', 'flex_bg', 'sparse_super', 'large_file', 'huge_file',
            'dir_nlink', 'extra_isize', 'metadata_csum']
PROJECT = Path(__file__).resolve().parents[2]


def run(*args, stdin=None):
    return subprocess.run(args, input=stdin, stdout=subprocess.PIPE, check=True,
                          universal_newlines=True, env={**os.environ, 'LC_ALL': 'C'}).stdout.strip()


def table(disk):
    return json.loads(run('sfdisk', '--json', disk))['partitiontable']


def devices(disk, columns):
    """Every lsblk entry for disk and its partitions, nested or flat.

    Without NAME among the columns, util-linux 2.41's lsblk -J prints a flat
    list instead of nesting partitions under "children"; walk both shapes.
    """
    stack = json.loads(run('lsblk', '-J', '-o', columns, disk))['blockdevices']
    found = []
    while stack:
        dev = stack.pop()
        found.append(dev)
        stack += dev.get('children') or []
    return found


def mounted(disk):
    return [f'{dev["path"]} on {m}' for dev in devices(disk, 'PATH,MOUNTPOINTS')
            for m in dev.get('mountpoints') or [] if m]


def identify(disk):
    """Return the reference card's table without UBUNTU26, APP, and an UBUNTU26 entry if one exists."""
    assert re.fullmatch(r'/dev/[a-z0-9]+', disk), f'{disk}: give the whole-disk path, such as /dev/sdd'
    assert run('lsblk', '-ndo', 'TYPE', disk) == 'disk', f'{disk} is not a whole disk'
    size = int(run('blockdev', '--getsize64', disk))
    assert size == CARD_BYTES, f'{disk} has {size} bytes, not the reference card\'s {CARD_BYTES}'
    assert run('lsblk', '-ndo', 'TRAN', disk) == 'usb', 'the card must be in a USB reader'
    busy = mounted(disk)
    assert not busy, 'unmount these first: ' + ', '.join(busy)
    pt = table(disk)
    assert pt['label'] == 'gpt' and pt.get('sectorsize', 512) == 512, pt['label']
    ours = [p for p in pt['partitions'] if p.get('name') == NAME]
    parts = [p for p in pt['partitions'] if p.get('name') != NAME]
    assert len(ours) <= 1 and len(parts) == PARTITIONS, \
        f'{len(pt["partitions"])} partitions, expected {PARTITIONS} (or {PARTITIONS} and {NAME})'
    app = [p for p in parts if p.get('name') == 'APP']
    assert len(app) == 1, 'no single APP partition'
    app = app[0]
    assert app['size'] * 512 == APP_BYTES, 'APP is not the reference card\'s size'
    assert app['uuid'].lower() == APP_PARTUUID, 'APP is not the reference card\'s (PARTUUID)'
    assert all(p['start'] + p['size'] <= app['start'] + app['size'] for p in parts), \
        'APP is not the last partition on the card'
    # The backup GPT sits in the last 33 sectors, right after the last usable one.
    assert pt['lastlba'] == size // 512 - 34, 'the backup GPT is not at the card\'s end'
    return {**pt, 'partitions': parts}, app, (ours[0] if ours else None)


def plan(pt, app):
    start = -(-(app['start'] + app['size']) // ALIGN) * ALIGN
    end = (pt['lastlba'] + 1) // ALIGN * ALIGN      # exclusive
    assert (end - start) * 512 >= MIN_BYTES, f'only {(end - start) * 512} bytes free after APP'
    return {'start': start, 'size': end - start, 'type': LINUX_FS,
            'uuid': str(uuid.uuid4()).upper(), 'name': NAME}


def same(a, b):
    keys = ['start', 'size', 'type', 'uuid', 'name', 'attrs']
    return [a.get(k) for k in keys] == [b.get(k) for k in keys]


def node_for(disk, partuuid):
    for attempt in range(20):
        if attempt == 5:  # sfdisk's own re-read did not show it yet
            subprocess.run(['partx', '-u', disk], check=False)
        run('udevadm', 'settle')
        found = [dev['path'] for dev in devices(disk, 'PATH,TYPE,PARTUUID')
                 if dev.get('type') == 'part' and (dev.get('partuuid') or '').lower() == partuuid.lower()]
        assert len(found) <= 1, found
        if found:
            return found[0]
        time.sleep(1)
    raise AssertionError(f'the kernel shows no partition {partuuid}; replug the reader and rerun --dry-run')


def superblock(node):
    fields = {}
    for line in run('dumpe2fs', '-h', node).splitlines():
        key, _, value = line.partition(':')
        fields[key.strip()] = value.strip()
    return fields


def append(target, pt, new):
    """Append the new partition to target's GPT and check that nothing else changed."""
    script = (f'start={new["start"]}, size={new["size"]}, type={new["type"]}, '
              f'uuid={new["uuid"]}, name="{new["name"]}"\n')
    extra = [] if target.startswith('/dev/') else ['--no-reread', '--no-tell-kernel']
    run('sfdisk', '--append', '--lock', '--wipe', 'never', *extra, target, stdin=script)
    after = table(target)
    parts = after['partitions']
    assert len(parts) == PARTITIONS + 1, f'{len(parts)} partitions after the write'
    number = lambda p: re.search(r'(\d+)$', p['node']).group(1)
    old = {number(p): p for p in pt['partitions']}
    assert all(same(old[number(p)], p) for p in parts if number(p) in old) and \
        len([p for p in parts if number(p) in old]) == PARTITIONS, 'an existing partition changed'
    added = [p for p in parts if number(p) not in old][0]
    assert same(added, {**new, 'attrs': None}), f'the new partition reads back as {added}'
    assert [after.get(k) for k in ('id', 'firstlba', 'lastlba')] == \
        [pt.get(k) for k in ('id', 'firstlba', 'lastlba')], 'the disk header changed'
    return after


def make_fs(node, fs_uuid):
    run('mkfs.ext4', '-q', '-F', '-L', NAME, '-U', fs_uuid,
        '-O', 'none,' + ','.join(FEATURES), '-E', 'nodiscard,root_owner=0:0', node)
    sb = superblock(node)
    assert sb['Filesystem UUID'] == fs_uuid and sb['Filesystem volume name'] == NAME, sb
    assert sorted(sb['Filesystem features'].split()) == sorted(FEATURES), sb['Filesystem features']
    return sb


def signatures(node):
    """What blkid finds on node beyond its own GPT entry: a filesystem, RAID or table.

    On a partition, blkid -p always reports the GPT entry (PART_ENTRY_*) and then
    exits 0, so only the other lines count. Exit 8 means conflicting signatures.
    """
    probe = subprocess.run(['blkid', '-p', '-o', 'export', node], stdout=subprocess.PIPE,
                           universal_newlines=True, env={**os.environ, 'LC_ALL': 'C'})
    assert probe.returncode in (0, 2, 8), f'blkid -p {node} exited {probe.returncode}'
    found = [l for l in probe.stdout.splitlines()
             if l and not l.startswith(('DEVNAME=', 'PART_ENTRY_'))]
    return found + ([f'ambivalent probe (exit 8)'] if probe.returncode == 8 else [])


def rehearse(disk, pt, new, with_table=True):
    """Run the append and mkfs on sparse files first, so a surprise stops before the card."""
    work = PROJECT / 'artifacts/u26'
    work.mkdir(parents=True, exist_ok=True)
    give_to_invoking_user(work)
    with tempfile.TemporaryDirectory(prefix='rehearse-', dir=work) as tmp:
        if with_table:
            card = Path(tmp) / 'card.img'
            with open(card, 'wb') as f:
                f.truncate(CARD_BYTES)
            run('sfdisk', '--no-reread', '--no-tell-kernel', '--wipe', 'never', str(card),
                stdin=run('sfdisk', '--dump', disk) + '\n')
            copy = table(str(card))
            assert len(copy['partitions']) == PARTITIONS and all(
                same(a, b) for a, b in zip(pt['partitions'], copy['partitions'])) and \
                [copy.get(k) for k in ('id', 'firstlba', 'lastlba')] == \
                [pt.get(k) for k in ('id', 'firstlba', 'lastlba')], 'the copied table differs'
            append(str(card), copy, new)
        part = Path(tmp) / 'part.img'
        with open(part, 'wb') as f:
            f.truncate(new['size'] * 512)
        sb = make_fs(str(part), str(uuid.uuid4()))
    return sb['Filesystem features']


def add(disk, pt, new, existing):
    after = table(disk) if existing else append(disk, pt, new)
    node = node_for(disk, new['uuid'])
    assert not existing or not signatures(node), \
        f'{node} already holds {signatures(node)}; not formatting it'
    assert int(run('blockdev', '--getsize64', node)) == new['size'] * 512, node
    fs_uuid = str(uuid.uuid4())
    sb = make_fs(node, fs_uuid)
    return after, node, fs_uuid, sb


def give_to_invoking_user(path):
    uid, gid = os.environ.get('SUDO_UID'), os.environ.get('SUDO_GID')
    if uid and gid:
        for item in [p for p in path.parents if PROJECT / 'artifacts' in p.parents] + [path]:
            os.chown(item, int(uid), int(gid))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('disk')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('run as root: it reads and writes the card\'s partition table')
    pt, app, existing = identify(args.disk)
    new = plan(pt, app)
    print(f'{args.disk}: the reference card, {CARD_BYTES} bytes, APP {APP_PARTUUID} ends at sector '
          f'{app["start"] + app["size"] - 1}')
    if existing:
        assert same(existing, {**new, 'uuid': existing['uuid'], 'attrs': None}), \
            f'{NAME} exists but not where the plan puts it: {existing}'
        new['uuid'] = existing['uuid']
        found = signatures(node_for(args.disk, new['uuid']))
        assert not found, f'{NAME} already holds {found}; not formatting it'
        print(f'{NAME} is already in the table with no filesystem (an earlier run stopped '
              f'before mkfs); only the filesystem is made')
    print(f'{"" if existing else "new "}partition {NAME}: start sector {new["start"]}, '
          f'{new["size"] * 512} bytes, PARTUUID {new["uuid"].lower()}')
    print(f'rehearsal on sparse files: {"ext4" if existing else "table and ext4"} '
          f'({rehearse(args.disk, pt, new, with_table=not existing)}) as planned')
    if args.dry_run:
        print('U26_PARTITION=DRY-RUN; nothing written to the card.')
        return 0
    assert identify(args.disk) == (pt, app, existing), 'the card changed during the rehearsal'
    after, node, fs_uuid, sb = add(args.disk, pt, new, existing)
    stamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    record = PROJECT / 'artifacts/u26' / f'add-partition-{stamp}.json'
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps({
        'utc': stamp, 'disk': args.disk, 'model': run('lsblk', '-ndo', 'MODEL', args.disk),
        'card_bytes': CARD_BYTES, 'table_before': pt, 'table_after': after,
        'partition': node, 'partuuid': new['uuid'].lower(), 'fs_uuid': fs_uuid,
        'table_entry_from_earlier_run': bool(existing),
        'features': sb['Filesystem features'], 'block_count': sb['Block count']}, indent=1) + '\n')
    give_to_invoking_user(record)
    late = mounted(args.disk)
    print(f'{node}: ext4 {NAME}, filesystem UUID {fs_uuid}')
    print(f'record: {record}')
    if late:
        print('mounted since (desktop automount): ' + ', '.join(late) + '; unmount before removal')
    print(f'U26_PARTITION=PASS partuuid={new["uuid"].lower()}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

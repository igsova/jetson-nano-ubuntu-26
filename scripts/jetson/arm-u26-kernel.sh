#!/usr/bin/env bash
# Boot a new 5.10 kernel Image once on Ubuntu 26.04, then keep it or
# not.
#
# Usage: sudo bash arm-u26-kernel.sh IMAGE SHA256 [DTB DTB_SHA256]
#                                                  arm one boot of IMAGE (and DTB)
#        sudo bash arm-u26-kernel.sh --disarm       undo the arming before that boot
#        sudo bash arm-u26-kernel.sh --keep         make the tried Image the default
#
# Run as root on a Nano running this project's Ubuntu 26.04, with
# nano-u26-kernel-once next to this script. It was written for and tested on
# the project's own card; a converted card has the same u26 boot entry, but
# this script has not been run on one. IMAGE is a kernel Image from
# build-jp5-kernel.sh with the running release (5.10.216-tegra), so the
# installed modules, device tree and initrd stay as they are; SHA256 is its
# hash from the build's output. Arming copies IMAGE into /boot next to the
# u26 entry's kernel as Image-<first 12 hex digits>, installs that init with
# the SHA-256 of the current and the armed extlinux.conf, and makes
# extlinux.conf the current file with one more entry, u26-next, selected by
# default: IMAGE with u26's device tree, initrd and options, plus init= that
# init, which puts the current file back before starting systemd. So the next
# boot is IMAGE and the one after is the u26 kernel again, also after a crash
# or power cut (panic=10 restarts the Nano 10 s after a kernel panic). U-Boot's
# menu still lists u26.
#
# With DTB and its SHA-256 (the build's dtb/tegra210-p3448-0000-p3449-0000-
# b00-r35.dtb), the device tree is tried too: it is copied next to u26's as
# <its name>-<first 12 hex digits>.dtb and u26-next boots it in place of
# u26's. IMAGE may then be the Image u26 already boots, to try a device tree
# alone.
#
# --keep, after that boot put the file back: u26 boots the tried Image (and
# device tree) by default, and u26-prev, listed after it, the kernel u26
# booted before. The previous Image and device tree stay in /boot. It writes
# only /boot (the Image, the device tree and extlinux.conf), the init in
# /usr/local/sbin and its records in /var/lib/nano-u26-kernel, never the boot
# partitions or the QSPI.
set -euo pipefail

KERNEL=5.10.216-tegra
COMPATIBLE=nvidia,p3449-0000-b00+p3448-0000-b00  # the Nano B01 device tree's
ROOT=''  # where this system's root is ('' for /)
CONF=$ROOT/boot/extlinux/extlinux.conf
INIT=/usr/local/sbin/nano-u26-kernel-once
STATE=$ROOT/var/lib/nano-u26-kernel
LOGS=$ROOT/var/log/nano-u26

die() { printf 'U26_KERNEL=FAIL: %s\n' "$*" >&2; exit 1; }
usage() {
    printf 'Usage: sudo bash %s IMAGE SHA256 [DTB DTB_SHA256] | --disarm | --keep\n' "$0" >&2
    exit 2
}
mode=arm
case ${1:-} in
    --disarm) mode=disarm; shift ;;
    --keep) mode=keep; shift ;;
    -*) usage ;;
esac
if [[ $mode == arm ]]; then
    [[ $# -eq 2 || $# -eq 4 ]] || usage
else
    [[ $# -eq 0 ]] || usage
fi
[[ $EUID == 0 ]] || die 'run this with sudo'
. "$ROOT/etc/os-release"
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "running $(uname -r), not $KERNEL"
for tool in python3 sha256sum findmnt blkid; do
    command -v "$tool" > /dev/null || die "no $tool"
done
sha() { sha256sum "$1" | cut -d' ' -f1; }
# Replace extlinux.conf with FILE in one rename, and check it took.
put_conf() {
    cp "$1" "$CONF.u26-next" && sync && mv -f "$CONF.u26-next" "$CONF" && sync
    [[ $(sha "$CONF") == "$(sha "$1")" ]] || die 'extlinux.conf did not take'
}

# The entries of an extlinux file: prints KEY=VALUE lines for LABEL's LINUX,
# FDT, INITRD and APPEND, or fails.
entry() {  # FILE LABEL
    python3 -I - "$1" "$2" << 'PY'
import re, sys
text = open(sys.argv[1]).read()
starts = [m.start() for m in re.finditer(r'(?m)^LABEL ', text)]
blocks = [text[a:b] for a, b in zip([0] + starts, starts + [len(text)])]
found = [b for b in blocks if b.startswith('LABEL %s\n' % sys.argv[2])]
assert len(found) == 1, 'no single %s entry' % sys.argv[2]
entry = {}
for line in found[0].split('\n')[1:]:
    key, _, value = line.strip().partition(' ')
    if key in ('LINUX', 'FDT', 'INITRD', 'APPEND'):
        assert key not in entry, 'two %s lines' % key
        entry[key] = value.strip()
assert set(entry) == {'LINUX', 'FDT', 'INITRD', 'APPEND'}, entry
for key in ('LINUX', 'FDT', 'INITRD'):
    assert re.fullmatch(r'/boot/[A-Za-z0-9._/-]+', entry[key]) and '..' not in entry[key], entry[key]
for key in ('LINUX', 'FDT', 'INITRD', 'APPEND'):
    print('%s=%s' % (key, entry[key]))
PY
}
field() { sed -n "s/^$1=//p" <<< "$2"; }

# The root must be the partition u26 boots.
current_entry=$(entry "$CONF" u26) || die "$CONF has no usable u26 entry"
append=$(field APPEND "$current_entry")
partuuid=$(grep -oE 'root=PARTUUID=[0-9a-f-]{36}' <<< "$append" | head -n 1 | cut -d= -f3)
[[ -n $partuuid ]] || die 'the u26 entry has no root=PARTUUID='
root_dev=$(findmnt -n -o SOURCE /)
[[ $(blkid -s PARTUUID -o value "$root_dev") == "$partuuid" ]] || die "the root ($root_dev) is not the u26 entry's"
mkdir -p "$STATE"

if [[ $mode == disarm ]]; then
    if [[ ! -f $STATE/armed.sha256 || $(sha "$CONF") != "$(cat "$STATE/armed.sha256")" ]]; then
        printf 'U26_KERNEL=DISARMED already: extlinux.conf is not the armed file\n'
        exit 0
    fi
    [[ $(sha "$STATE/before.conf") == "$(cat "$STATE/before.sha256")" ]] || die 'the saved extlinux.conf does not match its record'
    put_conf "$STATE/before.conf"
    printf 'U26_KERNEL=DISARMED extlinux.conf %s\n' "$(sha "$CONF")"
    exit 0
fi

if [[ $mode == keep ]]; then
    [[ -f $STATE/armed.sha256 && -f $STATE/image ]] || die 'nothing was armed'
    dtb=''
    [[ -f $STATE/dtb ]] && dtb=$(cat "$STATE/dtb")
    if [[ $(field LINUX "$current_entry") == "$(cat "$STATE/image")" &&
          ( -z $dtb || $(field FDT "$current_entry") == "$dtb" ) ]]; then
        printf 'U26_KERNEL=KEPT already: u26 boots %s%s\n' "$(cat "$STATE/image")" "${dtb:+ with $dtb}"
        exit 0
    fi
    [[ $(sha "$CONF") == "$(cat "$STATE/before.sha256")" ]] \
        || die 'extlinux.conf is not the file from before the arming (boot the tried kernel once first, or --disarm)'
    # The tried boot's init must have put it back from this armed file (the
    # Nano's clock at that point may be behind, so no times are compared).
    once=$(grep -lx "RESTORED=before $(cat "$STATE/before.sha256") armed=$(cat "$STATE/armed.sha256")" \
        "$LOGS"/kernel-once-*.log 2> /dev/null | head -n 1 || true)
    [[ -n $once ]] || die "no record that the armed kernel booted (no RESTORED line in $LOGS/kernel-once-*.log)"
    image=$(cat "$STATE/image")
    [[ -f $ROOT$image && $(sha "$ROOT$image") == "$(cat "$STATE/image.sha256")" ]] || die "$image is missing or changed"
    if [[ -n $dtb ]]; then
        [[ -f $ROOT$dtb && $(sha "$ROOT$dtb") == "$(cat "$STATE/dtb.sha256")" ]] || die "$dtb is missing or changed"
    fi
    kept=$(mktemp /run/u26-kernel.XXXXXX)
    trap 'rm -f "$kept"' EXIT
    python3 -I - "$CONF" "$kept" "$image" "$dtb" << 'PY'
import re, sys
src, dst, image, dtb = sys.argv[1:]
text = open(src).read()
starts = [m.start() for m in re.finditer(r'(?m)^LABEL ', text)]
blocks = [text[a:b] for a, b in zip([0] + starts, starts + [len(text)])]
head, entries = blocks[0], blocks[1:]
assert re.findall(r'(?m)^DEFAULT (\S+)$', head) == ['u26'], 'u26 is not the default'
u26 = [b for b in entries if b.startswith('LABEL u26\n')]
assert len(u26) == 1
old = u26[0].rstrip('\n') + '\n'
new = re.sub(r'(?m)^(\s*LINUX ).*$', lambda m: m.group(1) + image, old, count=1)
if dtb:
    new = re.sub(r'(?m)^(\s*FDT ).*$', lambda m: m.group(1) + dtb, new, count=1)
prev = re.sub(r'^LABEL u26\n', 'LABEL u26-prev\n', old, count=1)
prev = re.sub(r'(?m)^(\s*MENU LABEL .*?)(?: \(previous kernel\))?$', r'\1 (previous kernel)', prev, count=1)
rest = [b.rstrip('\n') + '\n' for b in entries if not b.startswith(('LABEL u26\n', 'LABEL u26-prev\n'))]
out = head.rstrip('\n') + '\n\n' + new + '\n' + prev + ''.join('\n' + b for b in rest)
open(dst, 'w').write(out)
PY
    put_conf "$kept"
    printf 'extlinux.conf:\n'
    sed 's/^/  /' "$CONF"
    printf 'U26_KERNEL=KEPT %s (sha256 %s)%s (tried boot %s) extlinux.conf %s\n' "$image" \
        "$(cat "$STATE/image.sha256")" "${dtb:+ with $dtb (sha256 $(cat "$STATE/dtb.sha256"))}" \
        "${once##*/}" "$(sha "$CONF")"
    exit 0
fi

# --- Arming.
src=$(realpath -e -- "$1") || die "no $1"
want=${2,,}
[[ $want =~ ^[0-9a-f]{64}$ ]] || die 'SHA256 must be 64 hex digits'
here=$(dirname -- "$(realpath -e -- "$0")")
[[ -f $here/nano-u26-kernel-once ]] || die "no nano-u26-kernel-once next to $0"
sh -n "$here/nano-u26-kernel-once" || die 'the init does not parse with sh'
for tool in sh mountpoint mount sha256sum cut cp mv sync cat mkdir uname; do
    command -v "$tool" > /dev/null || die "this root lacks $tool for the init"
done
[[ -x $ROOT/usr/lib/systemd/systemd ]] || die 'no /usr/lib/systemd/systemd'
grep -q '^LABEL u26-next$' "$CONF" && die 'extlinux.conf is already armed (run --disarm first)'
grep -q '^DEFAULT u26$' "$CONF" || die 'u26 is not the default entry'
grep -q 'init=' <<< "$append" && die 'the u26 entry already has an init='
got=$(sha "$src")
[[ $got == "$want" ]] || die "$1 has SHA-256 $got, not $want"
size=$(stat -L -c %s "$src")
(( size > 8000000 && size < 100000000 )) || die "$1 is $size bytes, not a kernel Image"
# arm64 Image header: magic "ARMd" at byte 56, and the running release.
[[ $(dd if="$src" bs=1 skip=56 count=4 status=none) == ARM$'\x64' ]] || die "$1 is not an arm64 Image"
LC_ALL=C grep -qaF "Linux version $KERNEL " "$src" || die "$1 is not a $KERNEL kernel"
linux=$(field LINUX "$current_entry")
fdt=$(field FDT "$current_entry")
if [[ $# -eq 4 ]]; then
    dtb_src=$(realpath -e -- "$3") || die "no $3"
    dtb_want=${4,,}
    [[ $dtb_want =~ ^[0-9a-f]{64}$ ]] || die 'DTB_SHA256 must be 64 hex digits'
    dtb_got=$(sha "$dtb_src")
    [[ $dtb_got == "$dtb_want" ]] || die "$3 has SHA-256 $dtb_got, not $dtb_want"
    dtb_size=$(stat -L -c %s "$dtb_src")
    (( dtb_size > 50000 && dtb_size < 2000000 )) || die "$3 is $dtb_size bytes, not a device tree"
    [[ $(od -An -tx1 -N4 "$dtb_src" | tr -d ' \n') == d00dfeed ]] || die "$3 is not a device tree blob"
    LC_ALL=C grep -qaF "$COMPATIBLE" "$dtb_src" || die "$3 is not the Nano B01 device tree"
    [[ $(sha "$ROOT$fdt") != "$dtb_got" ]] || die "u26 already boots this device tree ($fdt)"
    # Named after u26's device tree, less the hash an earlier --keep left on it.
    stem=${fdt##*/}
    stem=${stem%.dtb}
    [[ $stem =~ ^(.+)-[0-9a-f]{12}$ ]] && stem=${BASH_REMATCH[1]}
    dtb=$(dirname -- "$fdt")/$stem-${dtb_got:0:12}.dtb
    if [[ ! -f $ROOT$dtb || $(sha "$ROOT$dtb") != "$dtb_got" ]]; then
        cp "$dtb_src" "$ROOT$dtb.part" && sync && mv -f "$ROOT$dtb.part" "$ROOT$dtb" && sync
    fi
    [[ $(sha "$ROOT$dtb") == "$dtb_got" ]] || die "the copy at $dtb does not match"
else
    dtb=''
    [[ $(sha "$ROOT$linux") != "$got" ]] || die "u26 already boots this Image ($linux)"
fi
if [[ $(sha "$ROOT$linux") == "$got" ]]; then
    image=$linux
else
    image=$(dirname -- "$linux")/Image-${got:0:12}
    if [[ ! -f $ROOT$image || $(sha "$ROOT$image") != "$got" ]]; then
        cp "$src" "$ROOT$image.part" && sync && mv -f "$ROOT$image.part" "$ROOT$image" && sync
    fi
fi
[[ $(sha "$ROOT$image") == "$got" ]] || die "the copy at $image does not match"

before=$(mktemp /run/u26-kernel.XXXXXX)
armed=$(mktemp /run/u26-kernel.XXXXXX)
trap 'rm -f "$before" "$armed"' EXIT
cp "$CONF" "$before"
python3 -I - "$before" "$armed" "$image" "$INIT" "$dtb" << 'PY'
import re, sys
src, dst, image, init, dtb = sys.argv[1:]
text = open(src).read()
starts = [m.start() for m in re.finditer(r'(?m)^LABEL ', text)]
blocks = [text[a:b] for a, b in zip([0] + starts, starts + [len(text)])]
u26 = [b for b in blocks if b.startswith('LABEL u26\n')]
assert len(u26) == 1
lines = ['LABEL u26-next', '      MENU LABEL Ubuntu 26.04 on a new JetPack 5 kernel (one boot)']
for line in u26[0].rstrip('\n').split('\n')[1:]:
    key = line.strip().split(' ', 1)[0]
    if key == 'LINUX':
        lines.append('      LINUX ' + image)
    elif key == 'FDT' and dtb:
        lines.append('      FDT ' + dtb)
    elif key in ('FDT', 'INITRD'):
        lines.append(line)
    elif key == 'APPEND':
        lines.append(line.rstrip() + ' init=' + init)
assert [l.strip().split(' ', 1)[0] for l in lines[2:]] == ['LINUX', 'FDT', 'INITRD', 'APPEND'], lines
out = re.sub(r'(?m)^DEFAULT u26$', 'DEFAULT u26-next', text, count=1)
out = out if out.endswith('\n') else out + '\n'
open(dst, 'w').write(out + '\n' + '\n'.join(lines) + '\n')
PY
entry "$armed" u26-next > /dev/null || die 'the armed file has no usable u26-next entry'
[[ $(entry "$armed" u26) == "$current_entry" ]] || die 'the armed file changed the u26 entry'

# The init and its records, then the boot file last.
install -m 0755 "$here/nano-u26-kernel-once" "$ROOT$INIT"
cp "$before" "$STATE/before.conf"
sha "$before" > "$STATE/before.sha256"
sha "$armed" > "$STATE/armed.sha256"
printf '%s\n' "$image" > "$STATE/image"
printf '%s\n' "$got" > "$STATE/image.sha256"
if [[ -n $dtb ]]; then
    printf '%s\n' "$dtb" > "$STATE/dtb"
    printf '%s\n' "$dtb_got" > "$STATE/dtb.sha256"
else
    rm -f "$STATE/dtb" "$STATE/dtb.sha256"
fi
mkdir -p "$LOGS"
sync
put_conf "$armed"
printf 'u26-next entry:\n'
sed -n '/^LABEL u26-next$/,$p' "$CONF" | sed 's/^/  /'
printf 'U26_KERNEL=ARMED %s (sha256 %s)%s extlinux.conf %s (before %s); reboot to boot it once\n' \
    "$image" "$got" "${dtb:+ with $dtb (sha256 $dtb_got)}" "$(cat "$STATE/armed.sha256")" \
    "$(cat "$STATE/before.sha256")"

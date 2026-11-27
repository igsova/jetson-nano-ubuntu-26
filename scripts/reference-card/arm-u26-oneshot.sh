#!/usr/bin/env bash
# Arm (or disarm) one boot of Ubuntu 26.04 from the reference card's UBUNTU26 partition.
#
# Usage: sudo bash arm-u26-oneshot.sh [--disarm] DIR
#
# Run as root on the Nano under the reference card's everyday 5.10 boot, after
# build-u26-root.sh passed. DIR holds this script and nano-u26-oneshot-init.
# It installs that init in the 26.04 root with the SHA-256 of the two APP files
# it may swap, then makes APP's extlinux.conf the everyday file with one more
# entry, u26, selected by default: the same 5.10 kernel, device tree and
# initrd, with root= on UBUNTU26 and init= the one-shot init, which restores
# the everyday file before starting systemd. So the next boot is 26.04 and the
# one after is JetPack 4 on 5.10 again, also after a crash or power cut in
# 26.04. panic=10 restarts the Nano 10 s after a kernel panic. --disarm puts
# the everyday file back if the one-shot entry is still in place. It writes
# only APP's extlinux.conf and the 26.04 root, never the boot partitions or
# the QSPI.
set -euo pipefail

KERNEL=5.10.216-tegra
CARD_BYTES=63864569856
APP_PARTUUID=5ac80d7c-40fb-4796-bd56-4110e389819b
PART=/dev/mmcblk0p15
NAME=UBUNTU26
CONF=/boot/extlinux/extlinux.conf
EVERYDAY=/var/lib/jp5-trial/extlinux.everyday.conf
INIT=/usr/local/sbin/nano-u26-oneshot-init
LIB=/usr/local/lib/nano-u26
# Kernel log access for the owner's PC over SSH, as in the trials, and a
# restart after a panic.
EXTRA_ARGS="init=$INIT panic=10 log_buf_len=4M printk.devkmsg=on sysctl.kernel.dmesg_restrict=0"

die() { printf 'U26_ONESHOT=FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: sudo bash %s [--disarm] DIR\n' "$0" >&2; exit 2; }
disarm=0
if [[ ${1:-} == --disarm ]]; then disarm=1; shift; fi
[[ $# -eq 1 ]] || usage
[[ $EUID == 0 && $(uname -m) == aarch64 ]] || die 'run as root on the Nano'
dir=$(realpath -e -- "$1")
self=$(realpath -e -- "$0")
if [[ ${U26_ARM_NS:-} != 1 ]]; then
    again=("$dir")
    if ((disarm)); then again=(--disarm "$dir"); fi
    exec unshare --mount --propagation private env U26_ARM_NS=1 bash "$self" "${again[@]}"
fi

[[ $(uname -r) == "$KERNEL" ]] || die "running $(uname -r); boot the reference card's everyday 5.10 entry"
[[ $(blockdev --getsize64 /dev/mmcblk0) == "$CARD_BYTES" ]] || die 'mmcblk0 is not the reference card'
[[ $(findmnt -n -o SOURCE /) == /dev/mmcblk0p1 ]] || die 'the root is not mmcblk0p1'
[[ $(blkid -s PARTUUID -o value /dev/mmcblk0p1) == "$APP_PARTUUID" ]] || die 'mmcblk0p1 is not the reference card APP'
[[ $(lsblk -dno PARTLABEL "$PART") == "$NAME" && $(blkid -s LABEL -o value "$PART") == "$NAME" ]] \
    || die "$PART is not $NAME"
partuuid=$(blkid -s PARTUUID -o value "$PART")
fs_uuid=$(blkid -s UUID -o value "$PART")
[[ $partuuid =~ ^[0-9a-f-]{36}$ ]] || die "no PARTUUID for $PART"
sha256sum --check --status /var/lib/jp5-trial/everyday.sha256 || die "$EVERYDAY does not match its record"
everyday_sha=$(sha256sum "$EVERYDAY" | cut -d' ' -f1)
current_sha=$(sha256sum "$CONF" | cut -d' ' -f1)

if ((disarm)); then
    if [[ $current_sha == "$everyday_sha" ]]; then
        printf 'U26_ONESHOT=DISARMED already: extlinux.conf is the everyday file\n'
        exit 0
    fi
    grep -q '^DEFAULT u26$' "$CONF" || die 'extlinux.conf is neither the everyday file nor armed'
    cp "$EVERYDAY" "$CONF.u26-next" && sync && mv -f "$CONF.u26-next" "$CONF" && sync
    [[ $(sha256sum "$CONF" | cut -d' ' -f1) == "$everyday_sha" ]] || die 'restore did not take'
    printf 'U26_ONESHOT=DISARMED extlinux.conf %s\n' "$everyday_sha"
    exit 0
fi
[[ $current_sha == "$everyday_sha" ]] || die 'extlinux.conf is not the everyday file; run --disarm or the collect first'

# The newest build must have passed, on this partition's filesystem.
user=$(getent passwd 1000 | cut -d: -f1)
home=$(getent passwd 1000 | cut -d: -f6)
build=$(find "$home/u26-build" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | sort | tail -n 1)
[[ -n $build && -f $build/build.log && -f $build/summary.txt ]] || die 'no build record'
[[ $(tail -n 1 "$build/build.log") == U26_ROOT=PASS* ]] || die "the newest build ($build) did not pass"
grep -qx "fs_uuid=$fs_uuid" "$build/summary.txt" || die 'the build record names another filesystem'
stamp=${build##*/}
# So must the newest desktop, GPU desktop and Unity steps, if they ran
# (add-u26-desktop.sh, add-u26-gpu-desktop.sh, add-u26-unity.sh).
step_passed() {  # DIR LOG RESULT: prints the newest record, or nothing if none
    local newest
    newest=$(find "$home/$1" -mindepth 1 -maxdepth 1 -type d -name '20*Z' 2>/dev/null | sort | tail -n 1 || true)
    [[ -z $newest ]] && return 0
    [[ -f $newest/$2 && $(tail -n 1 "$newest/$2") == "$3"=PASS* ]] || die "the newest step in $newest did not pass"
    grep -qx "fs_uuid=$fs_uuid" "$newest/summary.txt" || die "the record $newest names another filesystem"
    printf '%s\n' "$newest"
}
desktop=$(step_passed u26-desktop desktop.log U26_DESKTOP)
gpu=$(step_passed u26-gpu-desktop gpu-desktop.log U26_GPU_DESKTOP)
unity=$(step_passed u26-unity unity.log U26_UNITY)

# The one-shot file: the everyday file with u26 by default, every other entry kept.
oneshot=$(mktemp /run/u26-oneshot.XXXXXX)
python3 - "$EVERYDAY" "$oneshot" "$APP_PARTUUID" "$partuuid" "$EXTRA_ARGS" <<'PY'
import re, sys
src, dst, app, new, extra = sys.argv[1:]
text = open(src).read()
assert len(re.findall(r'^DEFAULT jp5$', text, re.M)) == 1, 'no DEFAULT jp5'
# Split before each LABEL line. Python 3.6 (JetPack 4's) rejects re.split on
# an empty match, so cut at the match positions instead.
starts = [m.start() for m in re.finditer(r'(?m)^LABEL ', text)]
blocks = [text[a:b] for a, b in zip([0] + starts, starts + [len(text)])]
jp5 = [b for b in blocks if b.startswith('LABEL jp5\n')]
assert len(jp5) == 1, 'no single jp5 entry'
lines = jp5[0].rstrip('\n').split('\n')
append = [l for l in lines if l.strip().startswith('APPEND ')]
assert len(append) == 1
args = append[0].strip()[len('APPEND '):].split()
assert args.count('root=PARTUUID=' + app) == 1, 'jp5 entry does not boot APP'
# The masks name JetPack 4's units; 26.04 has none of them.
args = ['root=PARTUUID=' + new if a == 'root=PARTUUID=' + app else a
        for a in args if not a.startswith(('systemd.mask=', 'init='))]
entry = ['LABEL u26', '      MENU LABEL Ubuntu 26.04 on the JetPack 5 kernel (one boot)']
for l in lines[1:]:
    key = l.strip().split(' ', 1)[0]
    if key in ('LINUX', 'FDT', 'INITRD'):
        entry.append(l)
entry.append('      APPEND ' + ' '.join(args + extra.split()))
assert [l.strip().split(' ', 1)[0] for l in entry[2:]] == ['LINUX', 'FDT', 'INITRD', 'APPEND'], entry
out = re.sub(r'(?m)^DEFAULT jp5$', 'DEFAULT u26', text, count=1)
out = out if out.endswith('\n') else out + '\n'
open(dst, 'w').write(out + '\n' + '\n'.join(entry) + '\n')
PY
oneshot_sha=$(sha256sum "$oneshot" | cut -d' ' -f1)

# Install the init and its hashes in the 26.04 root.
root=/run/u26-arm/root
install -d -m 0700 /run/u26-arm
install -d -m 0755 "$root"
mount -t ext4 -o noatime "$PART" "$root"
trap 'umount "$root" || true; rm -f "$oneshot"' EXIT
[[ -f $root/var/log/nano-u26/build-$stamp.txt && -x $root/usr/lib/systemd/systemd ]] \
    || die "the 26.04 root lacks build $stamp or systemd"
install -m 0755 "$dir/nano-u26-oneshot-init" "$root$INIT"
install -d -m 0755 "$root$LIB/app"
printf '%s\n' "$oneshot_sha" > "$root$LIB/oneshot.sha256"
printf '%s\n' "$everyday_sha" > "$root$LIB/everyday.sha256"
chroot "$root" /bin/sh -n "$INIT" || die 'the init does not parse with 26.04 sh'
for tool in sh mountpoint mount umount sha256sum cut cp mv sync cat mkdir uname; do
    chroot "$root" /bin/sh -c "command -v $tool" >/dev/null || die "26.04 root lacks $tool"
done
sync
umount "$root"
trap 'rm -f "$oneshot"' EXIT

# Switch APP's boot file last, atomically.
cp "$oneshot" "$CONF.u26-next" && sync && mv -f "$CONF.u26-next" "$CONF" && sync
[[ $(sha256sum "$CONF" | cut -d' ' -f1) == "$oneshot_sha" ]] || die 'extlinux.conf did not take'
printf 'u26 entry:\n'
sed -n '/^LABEL u26$/,$p' "$CONF"
printf 'U26_ONESHOT=ARMED build=%s desktop=%s gpu=%s unity=%s extlinux.conf %s (everyday %s); reboot to start 26.04 once\n' \
    "$stamp" "${desktop##*/}" "${gpu##*/}" "${unity##*/}" "$oneshot_sha" "$everyday_sha"

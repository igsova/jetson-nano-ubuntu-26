#!/usr/bin/env bash
# Make Ubuntu 26.04 on the reference card's UBUNTU26 partition the Nano's default boot.
#
# Usage, from an SSH login to the Nano: sudo bash set-u26-default.sh [--undo]
#
# Run in the reference card's 26.04, booted from UBUNTU26 on the 5.10 kernel. APP's
# extlinux.conf must be the everyday file (DEFAULT jp5) that
# /var/lib/jp5-trial/everyday.sha256 on APP records. It becomes that file with
# one more entry, u26, selected by default: jp5's kernel, device tree and
# initrd, root= on UBUNTU26, panic=10 and the trials' kernel-log arguments,
# as in the one-shot entry of arm-u26-oneshot.sh, but with no init=, so
# Ubuntu's systemd starts directly and every boot is 26.04. The JetPack 4
# entries (primary on 4.9, jp5 on 5.10) stay in U-Boot's menu until JetPack 4
# leaves the card (the reference card's stage 6). The file is replaced
# atomically and checked by SHA-256. Run again after a pass, it changes
# nothing.
#
# --undo puts the everyday file back when APP's file selects u26 (this
# script's file or an armed one-shot). It also runs from the JetPack 4 boot on
# APP, reached from U-Boot's menu if 26.04 stops booting.
#
# Only APP's /boot/extlinux/extlinux.conf changes: never the card's boot
# partitions, the kernel files or the QSPI. The record goes to
# ~/u26-default/<stamp>. The last line is U26_DEFAULT=PASS or FAIL.
set -euo pipefail

CARD_BYTES=63864569856
APP=/dev/mmcblk0p1
APP_PARTUUID=5ac80d7c-40fb-4796-bd56-4110e389819b
PART=/dev/mmcblk0p15
NAME=UBUNTU26
CONF=/boot/extlinux/extlinux.conf
EVERYDAY=/var/lib/jp5-trial/extlinux.everyday.conf
EVERYDAY_SHA=/var/lib/jp5-trial/everyday.sha256
MNT=/run/u26-default/app
# As the one-shot entry, without its init=: a restart 10 s after a kernel
# panic, and the kernel log readable by the owner's account over SSH.
EXTRA_ARGS="panic=10 log_buf_len=4M printk.devkmsg=on sysctl.kernel.dmesg_restrict=0"

die() { printf 'U26_DEFAULT=FAIL: %s\n' "$*" >&2; exit 1; }
undo=0
if [[ ${1:-} == --undo ]]; then undo=1; shift; fi
(( $# == 0 )) || { printf 'Usage: sudo bash %s [--undo]\n' "$0" >&2; exit 2; }
[[ $(id -u) -eq 0 ]] || die 'run this with sudo'
[[ $(uname -m) == aarch64 ]] || die 'run this on the Nano'
owner=${SUDO_USER:-}
[[ -n $owner && $owner != root ]] || die 'run this with sudo from your own account'
IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || die "no account $owner"
[[ -d $home ]] || die "no home folder for $owner"
if [[ ${U26_DEFAULT_NS:-} != 1 ]]; then
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    again=()
    if (( undo )); then again=(--undo); fi
    # APP is mounted only in this private mount namespace, gone when it ends.
    exec unshare --mount --propagation private env U26_DEFAULT_NS=1 bash "$self" "${again[@]}"
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
parent=$home/u26-default
record=$parent/$stamp
[[ -d $parent ]] || { mkdir -m 0755 "$parent" && chown "$uid:$gid" "$parent"; } || die "cannot create $parent"
mkdir -m 0755 "$record" || die "cannot create $record"

main() {
    printf 'RECORD=%s\nMODE=%s\nKERNEL=%s\n' "$record" "$( (( undo )) && echo undo || echo set)" "$(uname -r)"
    [[ $(blockdev --getsize64 /dev/mmcblk0) == "$CARD_BYTES" ]] || die 'mmcblk0 is not the reference card'
    [[ $(blkid -s PARTUUID -o value "$APP") == "$APP_PARTUUID" ]] || die "$APP is not the reference card's APP"
    [[ $(lsblk -dno PARTLABEL "$PART") == "$NAME" && $(blkid -s LABEL -o value "$PART") == "$NAME" ]] \
        || die "$PART is not $NAME"
    local partuuid root
    partuuid=$(blkid -s PARTUUID -o value "$PART")
    [[ $partuuid =~ ^[0-9a-f-]{36}$ ]] || die "no PARTUUID for $PART"
    root=$(findmnt -n -o SOURCE /)
    printf 'ROOT=%s\n' "$root"

    # APP: the running root in the JetPack 4 boot (--undo only), else mounted here.
    local app
    if [[ $root == "$APP" ]]; then
        (( undo )) || die 'this is the JetPack 4 boot; boot 26.04 to make it the default'
        app=
    else
        [[ $root == "$PART" ]] || die "the root is $root, neither $APP nor $PART"
        if (( ! undo )); then
            . /etc/os-release
            [[ ${VERSION_ID:-} == 26.04 ]] || die "the root on $PART is ${PRETTY_NAME:-unknown}, not Ubuntu 26.04"
            [[ -x /usr/lib/systemd/systemd ]] || die 'the 26.04 root has no systemd'
        fi
        findmnt -n -S "$APP" -o TARGET,OPTIONS | sed 's/^/APP_ALREADY_MOUNTED /' || true
        install -d -m 0700 "${MNT%/*}"
        install -d -m 0755 "$MNT"
        mount -t ext4 -o rw,noatime "$APP" "$MNT" || die "cannot mount $APP read-write (unmount it if it is mounted read-only)"
        app=$MNT
    fi
    local conf=$app$CONF everyday=$app$EVERYDAY
    [[ -f $conf && -f $everyday && -f $app$EVERYDAY_SHA ]] || die "APP lacks $CONF, $EVERYDAY or $EVERYDAY_SHA"
    local everyday_sha current_sha
    everyday_sha=$(sha256sum "$everyday" | cut -d' ' -f1)
    [[ $(cut -d' ' -f1 "$app$EVERYDAY_SHA") == "$everyday_sha" ]] || die "$EVERYDAY does not match its record"
    current_sha=$(sha256sum "$conf" | cut -d' ' -f1)
    printf 'EVERYDAY_SHA256=%s\nBEFORE_SHA256=%s\n' "$everyday_sha" "$current_sha"
    cp "$conf" "$record/extlinux.conf.before"

    local target
    if (( undo )); then
        if [[ $current_sha == "$everyday_sha" ]]; then
            printf 'UNDO=already: extlinux.conf is the everyday file\n'
            return 0
        fi
        grep -qx 'DEFAULT u26' "$conf" || die 'extlinux.conf is neither the everyday file nor one that selects u26'
        target=$everyday
    else
        # The default file: the everyday file with u26 by default, every other entry kept.
        target=$(mktemp "${MNT%/*}/extlinux.XXXXXX")
        local files
        files=$(python3 - "$everyday" "$target" "$APP_PARTUUID" "$partuuid" "$EXTRA_ARGS" <<'PY'
import re, sys
src, dst, app, new, extra = sys.argv[1:]
text = open(src).read()
assert len(re.findall(r'^DEFAULT jp5$', text, re.M)) == 1, 'no DEFAULT jp5'
assert not re.search(r'^LABEL u26$', text, re.M), 'already a u26 entry'
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
# The masks name JetPack 4's units; 26.04 has none of them. No init=: systemd.
args = ['root=PARTUUID=' + new if a == 'root=PARTUUID=' + app else a
        for a in args if not a.startswith(('systemd.mask=', 'init='))]
entry = ['LABEL u26', '      MENU LABEL Ubuntu 26.04 on the JetPack 5 kernel']
for l in lines[1:]:
    key = l.strip().split(' ', 1)[0]
    if key in ('LINUX', 'FDT', 'INITRD'):
        entry.append(l)
        print(l.split()[1])
entry.append('      APPEND ' + ' '.join(args + extra.split()))
assert [l.strip().split(' ', 1)[0] for l in entry[2:]] == ['LINUX', 'FDT', 'INITRD', 'APPEND'], entry
out = re.sub(r'(?m)^DEFAULT jp5$', 'DEFAULT u26', text, count=1)
out = out if out.endswith('\n') else out + '\n'
open(dst, 'w').write(out + '\n' + '\n'.join(entry) + '\n')
PY
        ) || die 'cannot compose the u26 entry from the everyday file'
        local file
        for file in $files; do
            [[ -f $app$file ]] || die "the jp5 entry names $file, which APP lacks"
            printf 'BOOT_FILE %s %s\n' "$file" "$(sha256sum "$app$file" | cut -d' ' -f1)"
        done
        if [[ $current_sha == "$(sha256sum "$target" | cut -d' ' -f1)" ]]; then
            printf 'SET=already: extlinux.conf selects u26\n'
            sed -n '/^LABEL u26$/,$p' "$conf"
            return 0
        fi
        [[ $current_sha == "$everyday_sha" ]] \
            || die 'extlinux.conf is not the everyday file; run with --undo first if it is an armed one-shot'
    fi

    # Switch APP's boot file atomically.
    local want
    want=$(sha256sum "$target" | cut -d' ' -f1)
    cp "$target" "$conf.u26-next" && sync && mv -f "$conf.u26-next" "$conf" && sync
    [[ $(sha256sum "$conf" | cut -d' ' -f1) == "$want" ]] || die 'extlinux.conf did not take'
    cp "$conf" "$record/extlinux.conf.after"
    printf 'AFTER_SHA256=%s\n' "$want"
    grep -E '^(DEFAULT|TIMEOUT|LABEL) ' "$conf" | sed 's/^/MENU /'
    if (( undo )); then
        printf 'UNDO=done: the next boot is JetPack 4 on the 5.10 kernel (jp5)\n'
    else
        printf 'u26 entry:\n'
        sed -n '/^LABEL u26$/,$p' "$conf"
        printf 'SET=done: every boot from now is Ubuntu 26.04 (u26)\n'
    fi
}

set +e
main 2>&1 | tee "$record/summary.txt"
status=${PIPESTATUS[0]}
if mountpoint -q "$MNT"; then umount "$MNT" || { printf 'APP_UNMOUNT=FAIL\n'; status=1; }; fi
rm -f "${MNT%/*}"/extlinux.??????
rmdir "$MNT" "${MNT%/*}" 2> /dev/null
chown -R "$uid:$gid" "$record"
if (( status == 0 )); then result=PASS; else result=FAIL; fi
printf 'U26_DEFAULT=%s record=%s\n' "$result" "$record" | tee -a "$record/summary.txt"
exit "$status"

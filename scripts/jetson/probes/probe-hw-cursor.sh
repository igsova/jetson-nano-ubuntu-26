#!/usr/bin/env bash
# Find out why JetPack 5's X driver shows no hardware mouse pointer on the
# 5.10 kernel's display controller (tegradc), where JetPack 4's showed one.
#
# Usage, from an SSH login to the Nano: sudo bash probe-hw-cursor.sh
#
# Ubuntu 26.04 on the 5.10 kernel, with Option "HWCursor" "false" in
# /etc/X11/nano-xorg.conf (the software pointer). This restarts the display
# manager twice, which ends any desktop session:
#   1. with "HWCursor" "true", so X uses the controller's cursor;
#   2. at the login screen, for SECONDS_TRACE seconds in which the owner moves
#      the mouse across the screen and over the password box and off it:
#      - the kernel's function tracer records X's threads (its own trace
#        instance; the kernel has no function filter, so every kernel function
#        X runs is recorded and only tegradc's cursor and buffer calls and
#        what they call are kept);
#      - strace, when installed, records X's ioctls with their results;
#   3. the controller's registers (debugfs tegradc.0/regs) before and after,
#      with the cursor ones decoded (enable, image address, size, clip window,
#      position, colours) and the windows that are on;
#   4. nano-xorg.conf back byte for byte, whatever happened, and the display
#      manager restarted with it.
# It runs in its own session, so a lost SSH connection still ends in step 4.
# Nothing else changes. The record goes to ~/hw-cursor-probe/<stamp>; the last
# line is HW_CURSOR_PROBE=DONE or FAIL.
set -euo pipefail

KERNEL=5.10.216-tegra
CONF=/etc/X11/nano-xorg.conf
CONFDIR=/etc/X11/nano-xorg.conf.d
XORG=/usr/lib/nano-xorg/Xorg
REGS=/sys/kernel/debug/tegradc.0/regs
TRACEFS=/sys/kernel/tracing
SECONDS_TRACE=20
OFF='Option "HWCursor" "false"'
ON='Option "HWCursor" "true"'
# tegradc's ioctl entry, its cursor code and the buffer pinning a cursor image
# goes through (all in the R35 kernel's System.map); a trace line is kept when
# its function or its caller is one of these.
KEEP='tegra_dc_ioctl|tegra_dc_ext_(get_cursor|put_cursor|set_cursor_image|set_cursor|cursor_clip|pin_window|unpin_window|unpin_handles|flip)|tegra_dc_cursor_[a-z_]+|dma_buf_(get|put|attach|detach|map_attachment|unmap_attachment)'
CURSOR='tegra_dc_ext_(get_cursor|put_cursor|set_cursor_image|set_cursor|cursor_clip)|tegra_dc_cursor_[a-z_]+'

die() { printf 'HW_CURSOR_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

if [[ ${HW_CURSOR_PROBE_INNER:-} != 1 ]]; then
    [[ $(id -u) -eq 0 ]] || die 'run this with sudo'
    [[ $(uname -m) == aarch64 && $(uname -r) == "$KERNEL" ]] || die "run this on the Nano's $KERNEL kernel"
    owner=${SUDO_USER:-}
    [[ -n $owner && $owner != root ]] || die 'run this with sudo from your own account'
    IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || die "no account $owner"
    [[ -d $home ]] || die "no home folder for $owner"
    [[ $(grep -c -F -- "$OFF" "$CONF" 2> /dev/null) == 1 ]] \
        || die "$CONF needs exactly one line $OFF (the software pointer)"
    ! grep -q -i 'hwcursor' <(grep -v -F -- "$OFF" "$CONF") || die "$CONF names HWCursor more than once"
    ! grep -r -q -i 'hwcursor' "$CONFDIR" 2> /dev/null || die "$CONFDIR names HWCursor too"
    [[ -x $XORG ]] || die "no $XORG"
    systemctl is-active --quiet display-manager || die 'the display manager is not running'
    [[ -r $REGS ]] || die "no $REGS (debugfs)"
    for tool in setsid pgrep sha256sum mktemp tail awk stat; do command -v "$tool" > /dev/null || die "no $tool"; done
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    parent=$home/hw-cursor-probe
    [[ -d $parent ]] || { mkdir -m 0755 "$parent" && chown "$uid:$gid" "$parent"; } || die "cannot create $parent"
    record=$parent/$stamp
    mkdir -m 0755 "$record" || die "cannot create $record"
    : > "$record/summary.txt"
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    # Its own session: neither Ctrl+C nor a lost connection stops it before
    # nano-xorg.conf is back.
    HW_CURSOR_PROBE_INNER=1 RECORD=$record OWNER_IDS=$uid:$gid \
        setsid bash "$self" < /dev/null >> "$record/summary.txt" 2>&1 &
    inner=$!
    tail -n +1 --pid="$inner" -f "$record/summary.txt" || true
    wait "$inner"
    exit
fi

record=$RECORD
changed=0
inst=
spid=
before_sha=
xpid=

dm_xorg() { pgrep -n -f "^$XORG .*-seat seat0"; }  # LightDM's X server; the pattern cannot match pgrep itself
xlog() {  # the log file of X server $1
    local args log
    args=$(tr '\0' '\n' < "/proc/$1/cmdline" 2> /dev/null) || return 1
    log=$(grep -A1 -x -- -logfile <<< "$args" | tail -n 1)
    [[ $log == /* && -f $log ]] || log=/var/log/Xorg.0.log
    printf '%s\n' "$log"
}
# Restart the display manager and wait for a new X server that has started
# with a new log: one showing Option "HWCursor" set to $1, or, if X does not
# log the option, one that has set its mode and enabled its input.
restart_x() {
    local want=$1 old new log oldino='' settled=0
    old=$(dm_xorg) || old=
    if [[ -n $old ]] && log=$(xlog "$old"); then oldino=$(stat -L -c %i "$log" 2> /dev/null) || oldino=; fi
    systemctl restart display-manager || return 1
    for _ in $(seq 120); do
        sleep 1
        new=$(dm_xorg) || continue
        [[ $new != "$old" ]] && log=$(xlog "$new") || continue
        [[ $(stat -L -c %i "$log" 2> /dev/null) != "$oldino" ]] || continue
        if grep -q -i "Option \"HWCursor\" \"$want\"" "$log" 2> /dev/null; then
            say "XLOG_OPTION=Option \"HWCursor\" \"$want\""
        elif grep -q 'Silken mouse' "$log" 2> /dev/null; then
            (( ++settled >= 5 )) || continue  # the option line would be out by now
            say "XLOG_OPTION=not logged ($CONF has $(grep -i -o 'Option "HWCursor" "[a-z]*"' "$CONF"))"
        else
            continue
        fi
        sleep 8  # the login screen draws
        xpid=$new
        say "XORG_PID=$xpid LOG=$log"
        return 0
    done
    return 1
}
# Decode the cursor registers of a debugfs dump (T21x, dc_reg.h), and the
# windows that are on, as the cursor can be clipped to one.
decode() {  # $1: the dump, $2: its tag
    local tag=$2 name off val win='' w a hi p x y l opt
    local -A v=()
    local -a clips=(display A B C)
    while read -r name off val; do
        if [[ $name == WINDOW && $off =~ ^([A-Z]):$ ]]; then win=${BASH_REMATCH[1]}_; continue; fi
        if [[ $val =~ ^[0-9a-f]{1,16}$ ]]; then v[$win$name]=$((16#$val)); fi
    done < "$1"
    if [[ -z ${v[DC_DISP_CURSOR_START_ADDR]:-} ]]; then
        say "$tag REGS=EMPTY (the display controller was off)"
        return 0
    fi
    w=${v[DC_DISP_DISP_WIN_OPTIONS]:-0} a=${v[DC_DISP_CURSOR_START_ADDR]}
    hi=${v[DC_DISP_CURSOR_START_ADDR_HI]:-0} p=${v[DC_DISP_CURSOR_POSITION]:-0}
    x=$(( p & 0x3fff )) y=$(( (p >> 16) & 0x3fff ))
    (( x < 0x2000 )) || x=$(( x - 0x4000 ))
    (( y < 0x2000 )) || y=$(( y - 0x4000 ))
    printf '%s CURSOR_ENABLE=%d WIN_OPTIONS=0x%08x\n' "$tag" $(( (w >> 16) & 1 )) "$w"
    printf '%s CURSOR_ADDR=0x%x SIZE=%d CLIP=%s START_ADDR=0x%08x HI=0x%08x\n' "$tag" \
        $(( ((hi & 3) << 32) | ((a & 0x3fffff) << 10) )) $(( 32 << ((a >> 24) & 3) )) \
        "${clips[(a >> 28) & 3]}" "$a" "$hi"
    printf '%s CURSOR_POSITION x=%d y=%d (0x%08x)\n' "$tag" "$x" "$y" "$p"
    printf '%s CURSOR_FG=0x%06x BG=0x%06x STATE_CONTROL=0x%08x ACT_CONTROL=0x%08x\n' "$tag" \
        "${v[DC_DISP_CURSOR_FOREGROUND]:-0}" "${v[DC_DISP_CURSOR_BACKGROUND]:-0}" \
        "${v[DC_CMD_STATE_CONTROL]:-0}" "${v[DC_CMD_REG_ACT_CONTROL]:-0}"
    for l in A B C D H T; do
        opt=${v[${l}_DC_WIN_WIN_OPTIONS]:-}
        [[ -n $opt ]] || continue
        printf '%s WINDOW_%s ENABLE=%d POSITION=%dx%d SIZE=%dx%d DEPTH=%d\n' "$tag" "$l" \
            $(( (opt >> 30) & 1 )) \
            $(( ${v[${l}_DC_WIN_POSITION]:-0} & 0xffff )) $(( ${v[${l}_DC_WIN_POSITION]:-0} >> 16 )) \
            $(( ${v[${l}_DC_WIN_SIZE]:-0} & 0xffff )) $(( ${v[${l}_DC_WIN_SIZE]:-0} >> 16 )) \
            $(( ${v[${l}_DC_WIN_COLOR_DEPTH]:-0} & 0x7f ))
    done
}
regs() {  # $1: file name in the record
    cat "$REGS" > "$record/$1" || { say "REGS=FAIL $1"; return 0; }
    decode "$record/$1" "${1%.txt}"
}
strace_stop() {
    [[ -n $spid ]] || return 0
    # TERM, as a background job ignores INT; strace detaches from X on it.
    kill -TERM "$spid" 2> /dev/null || true
    wait "$spid" 2> /dev/null || true
    spid=
}
trace_stop() {
    [[ -n $inst ]] || return 0
    echo 0 > "$inst/tracing_on" 2> /dev/null
    echo nop > "$inst/current_tracer" 2> /dev/null
    echo > "$inst/set_ftrace_pid" 2> /dev/null
    rmdir "$inst" 2> /dev/null || say "TRACE_INSTANCE_LEFT=$inst"
    inst=
}
finish() {
    local status=$? now
    trap - EXIT
    trap '' INT TERM HUP
    set +e
    strace_stop
    trace_stop
    if (( changed )); then
        cp -p "$record/nano-xorg.conf.before" "$CONF.hwcursor-probe" && mv -f "$CONF.hwcursor-probe" "$CONF"
        now=$(sha256sum "$CONF" | cut -d' ' -f1)
        if [[ $now == "$before_sha" ]]; then
            say "CONF_RESTORED=PASS $now"
            say 'Restarting the display manager with the software pointer (log in again after this)...'
            restart_x false && say 'DESKTOP=back with the software pointer' \
                || { say 'DESKTOP=FAIL the display manager did not come back'; status=1; }
        else
            say "CONF_RESTORED=FAIL $CONF is $now, not $before_sha; the original is $record/nano-xorg.conf.before"
            status=1
        fi
    fi
    chown -R "$OWNER_IDS" "$record"
    if (( status == 0 )); then say "HW_CURSOR_PROBE=DONE record=$record"
    else say "HW_CURSOR_PROBE=FAIL record=$record"; fi
    exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM HUP

say "RECORD=$record"
say "KERNEL=$(uname -r)"
cp -p "$CONF" "$record/nano-xorg.conf.before"
before_sha=$(sha256sum "$CONF" | cut -d' ' -f1)
say "CONF_SHA256=$before_sha"
regs regs-software-pointer.txt

# 1. X with the controller's cursor.
tmp=$(mktemp "$CONF.XXXXXX")
sed "s/$OFF/$ON/" "$CONF" > "$tmp"
chmod --reference="$CONF" "$tmp" && chown --reference="$CONF" "$tmp"
[[ $(grep -c -F -- "$ON" "$tmp") == 1 ]] || { rm -f "$tmp"; die 'could not turn HWCursor on'; }
changed=1
mv -f "$tmp" "$CONF"
say 'Restarting the display manager with the hardware pointer (the desktop session ends)...'
restart_x true || die 'X did not start again with HWCursor on'
log=$(xlog "$xpid")
grep -n -i -E 'hwcursor|cursor|\(EE\)|\(WW\)|NVIDIA\(0\): (Setting mode|Virtual|Validated)' "$log" | sed 's/^/XLOG_HW /' || true
for fd in "/proc/$xpid/fd"/*; do  # X's open devices, by descriptor
    if dev=$(readlink "$fd") && [[ $dev == /dev/* ]]; then printf '%s %s\n' "${fd##*/}" "$dev"; fi
done > "$record/x-device-fds.txt"
sed 's/^/X_FD /' "$record/x-device-fds.txt"
regs regs-hw-before.txt

# 2. Trace X's threads while the owner moves the mouse.
[[ -d $TRACEFS/instances ]] || mount -t tracefs nodev "$TRACEFS" || die "cannot mount $TRACEFS"
inst=$TRACEFS/instances/hwcursor-probe
[[ ! -d $inst ]] || rmdir "$inst" 2> /dev/null || true  # left by a run that was killed
mkdir "$inst" || { inst=; die "cannot make the trace instance $TRACEFS/instances/hwcursor-probe"; }
grep -qw function "$inst/available_tracers" || die 'the function tracer is not available in a trace instance'
echo 16384 > "$inst/buffer_size_kb"
threads=$(cd "/proc/$xpid/task" && echo *)
echo "$threads" > "$inst/set_ftrace_pid"
say "TRACED_THREADS=$(for t in $threads; do printf '%s:%s ' "$t" "$(cat "/proc/$xpid/task/$t/comm" 2> /dev/null)"; done)"
if command -v strace > /dev/null; then
    strace -f -tt -e trace=ioctl -e signal=none -o "$record/strace-ioctl.txt" -p "$xpid" 2> "$record/strace.err" &
    spid=$!
    sleep 1
    kill -0 "$spid" 2> /dev/null || { say "STRACE=FAIL $(tail -n 1 "$record/strace.err")"; spid=; }
else
    say 'STRACE=not installed (the function trace alone)'
fi
echo function > "$inst/current_tracer"
echo 1 > "$inst/tracing_on"
say "MOVE_THE_MOUSE_NOW for $SECONDS_TRACE seconds: across the login screen, then over the password box and off it, a few times."
sleep "$SECONDS_TRACE"
echo 0 > "$inst/tracing_on"
strace_stop
say 'Tracing stopped.'
grep -m 1 -E '^# entries-in-buffer' "$inst/trace" | sed 's/^# /TRACE_/' || true
grep -E "(^|[ -])($KEEP)( |$)" "$inst/trace" | head -n 200000 > "$record/trace-dc.txt" || true
trace_stop
# How often each kept function ran, and from where.
awk '!/^#/ && NF >= 2 { n[$(NF - 1) " " $NF]++ } END { for (k in n) printf "TRACE_CALLS %d %s\n", n[k], k }' \
    "$record/trace-dc.txt" | sort -k3,3 -k4,4
# The first cursor calls in order, with what they called.
grep -E "(^|[ -])($CURSOR)( |$)" "$record/trace-dc.txt" | head -n 60 | sed 's/^ */TRACE_FIRST /' || true
if [[ -s $record/strace-ioctl.txt ]]; then
    # X's ioctls on the display controller's device, by request and result.
    fds=$(awk '$2 ~ /^\/dev\/tegra_dc/ { printf "%s%s", sep, $1; sep = "|" }' "$record/x-device-fds.txt")
    say "STRACE_DC_FDS=${fds:-none}"
    [[ -z $fds ]] || grep -E "ioctl\(($fds), " "$record/strace-ioctl.txt" \
        | sed -E 's/^[0-9]+ +[0-9:.]+ +//; s/^ioctl\(([0-9]+), (_IOC\([^)]*\)|[A-Z0-9_]+|0x[0-9a-f]+), .*\) += (.*)$/\1 \2 = \3/' \
        | sort | uniq -c | sort -rn | head -n 40 | sed 's/^ */STRACE_DC /' || true
fi
regs regs-hw-after.txt

# 3. The kernel's display and SMMU messages.
dmesg | grep -i -E 'tegradc|tegra_dc|dc\.|smmu|cursor|is not a dma-buf|cannot (attach|map)|contiguous|mc-err|EMEM' \
    | tail -n 40 | sed 's/^/DMESG /' || true
cp "$log" "$record/Xorg.hw-cursor.log" 2> /dev/null || true
say 'Restoring nano-xorg.conf and the software pointer...'

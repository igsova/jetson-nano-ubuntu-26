#!/usr/bin/env bash
# Find out what JetPack 5's X driver puts in the hardware mouse pointer's image
# on the Nano's 5.10 kernel, and where the pointer shows. probe-hw-cursor.sh
# showed that X sets the image, position and enable in tegradc's cursor
# registers with no error; the owner had seen no pointer in Unity.
#
# Usage, from an SSH login to the Nano (ssh -t), with tests/cursor/cursor_shim.c
# copied next to this script:
#   sudo bash probe-hw-cursor-image.sh           the four phases below
#   sudo bash probe-hw-cursor-image.sh session   the login screen and Unity
#
# Ubuntu 26.04 on the 5.10 kernel, with Option "HWCursor" "false" in
# /etc/X11/nano-xorg.conf. Every display manager restart ends any desktop
# session. Phases:
#   1. builds cursor_shim.so with GCC, adds a LightDM drop-in that starts X with
#      it (LD_PRELOAD) and turns HWCursor on;
#   2. at the login screen, four phases of SECONDS_PHASE seconds, in each of
#      which the owner moves the mouse over the password box and off it, so X
#      sets new pointer images, and notes whether a pointer shows:
#        log    images passed on as X made them (logged and saved)
#        sync   the CPU caches written back for each image first
#        flags  also marked as premultiplied RGBA for tegradc
#        rgba   also each pixel's alpha moved to the low byte, which tegradc's
#               header gives as its RGBA layout
#   3. X's 256 KB nvmap buffers (their cache mode) and the cursor registers;
#   4. the drop-in removed and nano-xorg.conf put back byte for byte, whatever
#      happened, and the display manager restarted with both.
# Session: HWCursor on, X first without the shim, then with it (logging only).
# Each time the owner answers, at the terminal, whether a pointer shows at the
# login screen and then in Unity after logging in; the cursor registers are
# read at each answer, and the registers that changed between the login screen
# and Unity are listed. With the shim, its log also has X's other cursor calls
# (visibility changes and errors). Then step 4. An unanswered question (10 minutes) ends
# the run in step 4.
# It runs in its own session, so a lost SSH connection still ends in step 4.
# Nothing else changes. The record goes to ~/hw-cursor-image/<stamp>; the last
# line is HW_CURSOR_IMAGE=DONE or FAIL.
set -euo pipefail

KERNEL=5.10.216-tegra
CONF=/etc/X11/nano-xorg.conf
CONFDIR=/etc/X11/nano-xorg.conf.d
XORG=/usr/lib/nano-xorg/Xorg
GPU_DM=/etc/lightdm/lightdm.conf.d/60-jetson-gpu.conf
DROPIN=/etc/lightdm/lightdm.conf.d/99-hwcursor-image.conf
REGS=/sys/kernel/debug/tegradc.0/regs
NVMAP=/sys/kernel/debug/nvmap/iovmm/allocations
SECONDS_PHASE=15
MODES=(log sync flags rgba)
OFF='Option "HWCursor" "false"'
ON='Option "HWCursor" "true"'

die() { printf 'HW_CURSOR_IMAGE=FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

if [[ ${HW_CURSOR_IMAGE_INNER:-} != 1 ]]; then
    probe=${1:-phases}
    [[ $probe == phases || $probe == session ]] || die "unknown run '$probe' (phases or session)"
    [[ $probe == phases ]] || { : < /dev/tty; } 2> /dev/null || die 'the session run asks questions: log in with ssh -t'
    [[ $(id -u) -eq 0 ]] || die 'run this with sudo'
    [[ $(uname -m) == aarch64 && $(uname -r) == "$KERNEL" ]] || die "run this on the Nano's $KERNEL kernel"
    owner=${SUDO_USER:-}
    [[ -n $owner && $owner != root ]] || die 'run this with sudo from your own account'
    IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || die "no account $owner"
    [[ -d $home ]] || die "no home folder for $owner"
    here=$(cd "$(dirname "$0")" && pwd)
    [[ -f $here/cursor_shim.c ]] || die "no cursor_shim.c next to this script (copy tests/cursor/cursor_shim.c to $here)"
    [[ $(grep -c -F -- "$OFF" "$CONF" 2> /dev/null) == 1 ]] \
        || die "$CONF needs exactly one line $OFF (the software pointer)"
    ! grep -q -i 'hwcursor' <(grep -v -F -- "$OFF" "$CONF") || die "$CONF names HWCursor more than once"
    ! grep -r -q -i 'hwcursor' "$CONFDIR" 2> /dev/null || die "$CONFDIR names HWCursor too"
    [[ $(grep -c '^xserver-command=' "$GPU_DM" 2> /dev/null) == 1 ]] \
        && grep -q "^xserver-command=$XORG " "$GPU_DM" || die "$GPU_DM needs one xserver-command line starting $XORG"
    [[ ! -e $DROPIN ]] || die "$DROPIN is left from an earlier run; look at it, remove it and restart LightDM"
    systemctl is-active --quiet display-manager || die 'the display manager is not running'
    [[ -r $REGS ]] || die "no $REGS (debugfs)"
    for tool in setsid pgrep sha256sum mktemp tail awk stat lightdm /usr/bin/env; do command -v "$tool" > /dev/null || die "no $tool"; done
    cc=$(command -v gcc-11 || command -v gcc || command -v cc) || die 'no C compiler (gcc-11 from add-u26-gcc11.sh)'
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    parent=$home/hw-cursor-image
    [[ -d $parent ]] || { mkdir -m 0755 "$parent" && chown "$uid:$gid" "$parent"; } || die "cannot create $parent"
    record=$parent/$stamp
    mkdir -m 0755 "$record" || die "cannot create $record"
    : > "$record/summary.txt"
    # Its own session: neither Ctrl+C nor a lost connection stops it before
    # the drop-in is gone and nano-xorg.conf is back.
    HW_CURSOR_IMAGE_INNER=1 PROBE=$probe RECORD=$record OWNER_IDS=$uid:$gid SHIM_SRC=$here/cursor_shim.c CC=$cc \
        setsid bash "$here/$(basename "$0")" < /dev/null >> "$record/summary.txt" 2>&1 &
    inner=$!
    tail -n +1 --pid="$inner" -f "$record/summary.txt" &
    tailer=$!
    # Pass the owner's answers on: the run asks through $record/ask.
    while kill -0 "$inner" 2> /dev/null; do
        if [[ -f $record/ask ]]; then
            id=$(cat "$record/ask")
            rm -f "$record/ask"
            answer=
            read -r -t 600 answer < /dev/tty || true
            printf '%s\n' "${answer:-(none)}" > "$record/answer.tmp" && mv -f "$record/answer.tmp" "$record/answer-$id"
        fi
        sleep 0.5
    done
    wait "$tailer" 2> /dev/null || true
    wait "$inner"
    exit
fi

record=$RECORD
shim=$record/shim
changed=0
dropin=0
restarted=0
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
# with a new log showing Option "HWCursor" set to $1 (as probe-hw-cursor.sh
# found X 1.20 logs it).
restart_x() {
    local want=$1 old new log oldino=''
    old=$(dm_xorg) || old=
    if [[ -n $old ]] && log=$(xlog "$old"); then oldino=$(stat -L -c %i "$log" 2> /dev/null) || oldino=; fi
    systemctl restart display-manager || return 1
    for _ in $(seq 120); do
        sleep 1
        new=$(dm_xorg) || continue
        [[ $new != "$old" ]] && log=$(xlog "$new") || continue
        [[ $(stat -L -c %i "$log" 2> /dev/null) != "$oldino" ]] || continue
        grep -q -i "Option \"HWCursor\" \"$want\"" "$log" 2> /dev/null || continue
        sleep 8  # the login screen draws
        xpid=$new
        say "XORG_PID=$xpid HWCURSOR=$want"
        return 0
    done
    return 1
}
has_shim() { grep -q -F "$record/cursor_shim.so" "/proc/$1/maps" 2> /dev/null; }
mark() { printf '[0.000] MARK %s\n' "$*" >> "$shim/log.txt"; }  # a heading in the shim's log
ask() {  # $1: answer id, $2: question; the outer part reads the answer at the terminal
    say ''
    say "QUESTION: $2"
    say '(type your answer here and press Enter)'
    printf '%s\n' "$1" > "$record/ask.tmp" && mv -f "$record/ask.tmp" "$record/ask"
    for _ in $(seq 600); do
        if [[ -s $record/answer-$1 ]]; then
            say "ANSWER $1: $(head -c 200 "$record/answer-$1" | tr -cd '[:print:]')"
            return 0
        fi
        sleep 1
    done
    die "no answer within 10 minutes"
}
# The cursor registers of tegradc's debugfs dump (T21x, dc_reg.h).
cursor_regs() {  # $1: tag
    local name val w a p
    local -A v=()
    cat "$REGS" > "$record/regs-$1.txt" 2> /dev/null || { say "REGS=FAIL $1"; return 0; }
    while read -r name _ val; do
        [[ $name == WINDOW ]] && break
        if [[ $val =~ ^[0-9a-f]{1,8}$ ]]; then v[$name]=$((16#$val)); fi
    done < "$record/regs-$1.txt"
    [[ -n ${v[DC_DISP_CURSOR_START_ADDR]:-} ]] || { say "$1 REGS=EMPTY"; return 0; }
    w=${v[DC_DISP_DISP_WIN_OPTIONS]:-0} a=${v[DC_DISP_CURSOR_START_ADDR]} p=${v[DC_DISP_CURSOR_POSITION]:-0}
    printf '%s CURSOR_ENABLE=%d ADDR=0x%x SIZE=%d POSITION=%d,%d\n' "$1" $(( (w >> 16) & 1 )) \
        $(( ((${v[DC_DISP_CURSOR_START_ADDR_HI]:-0} & 3) << 32) | ((a & 0x3fffff) << 10) )) \
        $(( 32 << ((a >> 24) & 3) )) $(( p & 0x3fff )) $(( (p >> 16) & 0x3fff ))
}
regdiff() {  # $1, $2: tags; the registers that differ between the two readings
    local out
    out=$(awk '
        FNR == 1 { win = "-"; file++ }
        /^WINDOW [A-Z]+:/ { win = substr($2, 1, length($2) - 1); next }
        NF == 3 && $3 ~ /^[0-9a-f]+$/ { key = win " " $1; if (file == 1) a[key] = $3; else b[key] = $3; order[key] = NR }
        END {
            for (k in b) if ((k in a) && a[k] != b[k] && k !~ /INT_STATUS|CRC|CURSOR_POSITION/) print order[k], k, a[k], b[k]
        }' "$record/regs-$1.txt" "$record/regs-$2.txt" 2> /dev/null | sort -n | cut -d' ' -f2-)
    if [[ -z $out ]]; then
        say "REGDIFF $1 $2: none"
    else
        say "REGDIFF $1 $2 (window, register, before, after):"
        head -n 40 <<< "$out" | sed 's/^/  /'
    fi
}
finish() {
    local status=$? now
    trap - EXIT
    trap '' INT TERM HUP
    set +e
    if (( dropin )); then
        rm -f "$DROPIN"
        [[ ! -e $DROPIN ]] && say "DROPIN_REMOVED=PASS" || { say "DROPIN_REMOVED=FAIL $DROPIN"; status=1; }
    fi
    if (( changed )); then
        cp -p "$record/nano-xorg.conf.before" "$CONF.hwcursor-image" && mv -f "$CONF.hwcursor-image" "$CONF"
        now=$(sha256sum "$CONF" | cut -d' ' -f1)
        if [[ $now == "$before_sha" ]]; then
            say "CONF_RESTORED=PASS $now"
        else
            say "CONF_RESTORED=FAIL $CONF is $now, not $before_sha; the original is $record/nano-xorg.conf.before"
            status=1
        fi
    fi
    if (( restarted )); then
        say 'Restarting the display manager as before (log in again after this)...'
        if restart_x false; then
            has_shim "$xpid" && { say 'DESKTOP=FAIL X still has the shim'; status=1; } \
                || say 'DESKTOP=back with the software pointer, without the shim'
        else
            say 'DESKTOP=FAIL the display manager did not come back'
            status=1
        fi
    fi
    chown -R "$OWNER_IDS" "$record"
    if (( status == 0 )); then say "HW_CURSOR_IMAGE=DONE record=$record"
    else say "HW_CURSOR_IMAGE=FAIL record=$record"; fi
    exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM HUP

say "RECORD=$record"
cp -p "$CONF" "$record/nano-xorg.conf.before"
before_sha=$(sha256sum "$CONF" | cut -d' ' -f1)
say "CONF_SHA256=$before_sha"

# 1. The shim; the drop-in that starts X with it; the controller's cursor.
cp "$SHIM_SRC" "$record/cursor_shim.c"
"$CC" -O2 -Wall -shared -fPIC -o "$record/cursor_shim.so" "$record/cursor_shim.c" -ldl 2> "$record/build.log" \
    || die "the shim did not build: $(tail -n 3 "$record/build.log")"
say "SHIM_BUILT=$("$CC" --version | head -n 1)"
mkdir -m 0755 "$shim"
echo log > "$shim/mode"
command=$(sed -n 's/^xserver-command=//p' "$GPU_DM")
add_dropin() {
    dropin=1
    cat > "$DROPIN" <<EOF
# probe-hw-cursor-image.sh: X with the cursor shim; removed when it ends.
[Seat:*]
xserver-command=/usr/bin/env LD_PRELOAD=$record/cursor_shim.so CURSOR_SHIM_DIR=$shim CURSOR_SHIM_MODE=$shim/mode $command
EOF
    chmod 0644 "$DROPIN"
    lightdm --show-config > "$record/lightdm-config.txt" 2>&1 || true
    grep -q -F "xserver-command=/usr/bin/env LD_PRELOAD=$record/cursor_shim.so" "$record/lightdm-config.txt" \
        || die "LightDM does not take the drop-in's xserver-command (see $record/lightdm-config.txt)"
}
hwcursor_on() {
    local tmp
    tmp=$(mktemp "$CONF.XXXXXX")
    sed "s/$OFF/$ON/" "$CONF" > "$tmp"
    chmod --reference="$CONF" "$tmp" && chown --reference="$CONF" "$tmp"
    [[ $(grep -c -F -- "$ON" "$tmp") == 1 ]] || { rm -f "$tmp"; die 'could not turn HWCursor on'; }
    changed=1
    mv -f "$tmp" "$CONF"
}
greeter='At the login screen now: move the mouse around and over the password box. Is there a mouse pointer?'
unity='Now log in to Unity, wait for the desktop, and move the mouse over it and over a window. Is there a mouse pointer?'

if [[ $PROBE == session ]]; then
    hwcursor_on
    say 'ROUND 1 of 2: X with the hardware pointer, without the shim. Restarting the display manager (the desktop session ends)...'
    restarted=1
    restart_x true || die 'X did not start again with HWCursor on'
    ! has_shim "$xpid" || die 'X has the shim in round 1'
    cursor_regs plain-start
    ask plain-greeter "$greeter"
    cursor_regs plain-greeter
    ask plain-unity "$unity"
    cursor_regs plain-unity
    add_dropin
    say ''
    say 'ROUND 2 of 2: the same with the shim, logging only. Restarting the display manager (this logs you out)...'
    mark 'round 2: X started with the shim'
    restart_x true || die 'X did not start again with the shim'
    has_shim "$xpid" || die 'X started without the shim'
    say 'SHIM_LOADED=yes'
    cursor_regs shim-start
    mark 'login screen'
    echo log-greeter > "$shim/mode"  # the shim describes and saves the first images of each mode
    ask shim-greeter "$greeter"
    cursor_regs shim-greeter
    mark 'Unity, after logging in'
    echo log-unity > "$shim/mode"
    ask shim-unity "$unity"
    cursor_regs shim-unity
    mark 'end'
    MODES=()
    regdiff plain-greeter plain-unity
    regdiff shim-greeter shim-unity
else
    add_dropin
    hwcursor_on
    say 'Restarting the display manager with the hardware pointer and the shim (the desktop session ends)...'
    restarted=1
    restart_x true || die 'X did not start again with HWCursor on'
    has_shim "$xpid" || die 'X started without the shim'
    say 'SHIM_LOADED=yes'
    cursor_regs start
fi

# 2. The phases.
n=0
for mode in "${MODES[@]}"; do
    n=$((n + 1))
    echo "$mode" > "$shim/mode"
    say ''
    say "PHASE $n of ${#MODES[@]} ($mode) starts now, for $SECONDS_PHASE seconds: move the mouse over the password box and off it a few times. Is there a pointer?"
    sleep "$SECONDS_PHASE"
    say "PHASE $n ($mode) ended: $(grep -c " mode=$mode " "$shim/log.txt" 2> /dev/null || true) pointer images"
done
echo log > "$shim/mode"
say ''
[[ $PROBE == session ]] || cursor_regs end

# 3. What X sent, in short, in each part of the shim's log (headed by MARK
# lines): the other cursor calls as events, the first image of each mode in
# detail (the first of each part with its picture, without blank rows at the
# bottom), then the images grouped by what they were and what happened to
# them.
if [[ -s $shim/log.txt ]]; then
    python3 -I - "$shim/log.txt" <<'EOF' | sed 's/^/SHIM /' || say 'SHIM=summary failed'
import re, sys

parts = [{'mark': None, 'pre': [], 'events': [], 'images': []}]
for line in open(sys.argv[1], errors='replace').read().splitlines():
    line = re.sub(r'^\[[0-9.]+\] ', '', line)
    if line.startswith('MARK '):
        parts.append({'mark': line[5:], 'pre': [], 'events': [], 'images': []})
        continue
    part = parts[-1]
    if line.startswith('EVENT '):
        part['events'].append(line[6:])
        continue
    m = re.match(r'#(\d+) mode=(\S+) .*?size=(\S+) (format=\S+) (colorfmt_flags=\S+) '
                 r'colorfmt=(\d+) alpha=(\d+) fg=(\w+) bg=(\w+)', line)
    if m:
        part['images'].append({'n': int(m[1]), 'mode': m[2], 'body': [],
                               'what': '%s %s %s colorfmt=%s alpha=%s fg=%s bg=%s' % m.group(3, 4, 5, 6, 7, 8, 9)})
    elif part['images']:
        part['images'][-1]['body'].append(line)
    else:
        part['pre'].append(line)
for part in parts:
    pictured = False
    if part['mark'] is not None:
        print('== %s: %d image(s), %d event(s)' % (part['mark'], len(part['images']), len(part['events'])))
    for line in part['pre']:
        print(line)
    for event in part['events'][:30]:
        print('event: ' + event)
    if len(part['events']) > 30:
        print('event: ... %d more' % (len(part['events']) - 30))
    seen, groups = set(), {}
    for img in part['images']:
        if img['mode'] not in seen:
            seen.add(img['mode'])
            print('first %s image #%d: %s' % (img['mode'], img['n'], img['what']))
            body = img['body']
            if not pictured:
                rows = [k for k, b in enumerate(body) if re.match(r'\s*\|', b)]
                blank = [k for k in rows if re.match(r'\s*\|\s*\|$', body[k])]
                while rows and blank and rows[-1] == blank[-1]:
                    body = body[:rows[-1]] + body[rows[-1] + 1:]
                    rows.pop()
                    blank.pop()
            for b in body:
                if not pictured or not re.match(r'\s*[|(]', b):
                    print(b)
            pictured = True
        notes = ' | '.join(b.strip() for b in img['body']
                           if re.search(r'returned|flags now|alpha (moved|already)|failed|left alone|caches', b))
        groups.setdefault((img['mode'], img['what'], notes), []).append(img['n'])
    for (mode, what, notes), ns in groups.items():
        print('%d image(s) #%d-#%d %s: %s: %s' % (len(ns), ns[0], ns[-1], mode, what, notes))
EOF
else
    say 'SHIM=no cursor images logged'
fi
xpid=$(dm_xorg) || true
# X's nvmap buffers of 256 KB (a 256x256 RGBA image) and their cache mode.
if [[ -r $NVMAP ]]; then
    awk -v pid="$xpid" '
        /^[^ ]/ { inx = ($3 == pid) }
        inx && /^ / && $2 == "256K" {
            f = $3
            # FLAGS is hex; its low two bits are the cache mode.
            d = index("0123456789abcdef", tolower(substr(f, length(f), 1))) - 1
            split("uncached write-combined inner-cacheable cacheable", m, " ")
            printf "NVMAP_256K flags=0x%s cache=%s refs=%s pins=%s umaps=%s\n", f, m[d % 4 + 1], $4, $6, $8
        }' "$NVMAP" | sort | uniq -c | sed -E 's/^ *([0-9]+) /\1x /' || true
else
    say "NVMAP=no $NVMAP"
fi
dmesg | grep -i -E 'tegradc|smmu|mc-err|EMEM|cursor|dma-buf|cannot (attach|map)' | tail -n 15 | sed 's/^/DMESG /' || true
say 'Removing the drop-in and restoring nano-xorg.conf...'

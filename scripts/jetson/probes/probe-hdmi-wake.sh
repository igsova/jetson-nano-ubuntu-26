#!/usr/bin/env bash
# Find what brings the HDMI picture back after the desktop's screen blank, on
# Ubuntu 26.04 with JetPack 5's X driver. The owner reports
# (2026-10-18) that once the screen sleeps, neither keys nor the mouse wake it,
# and the kernel logs an HDMI unplug and replug about every 7 s while it is
# blanked (2026-10-17).
#
# Usage, from an SSH login to the Nano (ssh -t, as it asks questions):
#   sudo bash probe-hdmi-wake.sh          the screen is dark now
#   sudo bash probe-hdmi-wake.sh force    blank it now with X's DPMS, then test
#
# Do not touch the Nano's keyboard or mouse during the run; answer at the
# terminal. Steps:
#   1. state: what the monitor shows (the owner's answer), X's DPMS state and
#      outputs (xset, xrandr), the display's kernel lines (tegradc, HDMI) since
#      boot and for 20 s, the X log's display lines, the programs that manage
#      blanking, and tegradc's registers (debugfs);
#   2. with force: X's DPMS off, then the kernel lines for WAIT seconds, and
#      a key press (with enable-hdmi-wake.sh's helper installed, its log);
#   3. wake attempts, one at a time, each followed by the same state readings
#      and the question whether the picture is back, stopping at the first
#      that works:
#        dpms     xset dpms force on (what X does on a key or mouse event)
#        xrandr   xrandr --output OUTPUT --auto (a new mode set on the output)
#        console  a switch to text console 1 and back to X's console (the
#                 VT_ACTIVATE ioctl from Python, as the system has no chvt)
#        fb       fb0's blank set to 0 (tegradc's own unblank)
#      and the registers that changed between the dark screen and the wake.
# Nothing is installed or changed on disk outside the record; the attempts only
# change the display's state. If none works, restarting the display manager
# (ending the desktop session) or a reboot brings the screen back.
# The record goes to ~/hdmi-wake/<stamp>; the last line is
# HDMI_WAKE=DONE wake=<attempt|none> or HDMI_WAKE=FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
XORG=/usr/lib/nano-xorg/Xorg
REGS=/sys/kernel/debug/tegradc.0/regs
FB_BLANK=/sys/class/graphics/fb0/blank
WAIT=${WAIT:-90}
WATCH=20
KPAT='tegradc|hdmi|extcon|tegra_fb|nvdisp|\bsor\b'

die() { printf 'HDMI_WAKE=FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

mode=${1:-dark}
[[ $mode == dark || $mode == force ]] || die "unknown mode '$mode' (none, or force)"
[[ $(id -u) -eq 0 ]] || die 'run this with sudo'
{ : < /dev/tty; } 2> /dev/null || die 'this asks questions: log in with ssh -t'
[[ $(uname -m) == aarch64 && $(uname -r) == "$KERNEL" ]] || die "run this on the Nano's $KERNEL kernel"
owner=${SUDO_USER:-}
[[ -n $owner && $owner != root ]] || die 'run this with sudo from your own account'
IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || die "no account $owner"
[[ -d $home ]] || die "no home folder for $owner"
for tool in journalctl pgrep python3 awk sort timeout; do command -v "$tool" > /dev/null || die "no $tool"; done
have_xset=0 have_xrandr=0
command -v xset > /dev/null && have_xset=1
command -v xrandr > /dev/null && have_xrandr=1
HELPER_UNIT=nano-hdmi-wake.service
helper=0
[[ -f /etc/systemd/system/$HELPER_UNIT ]] && helper=1

stamp=$(date -u +%Y%m%dT%H%M%SZ)
parent=$home/hdmi-wake
[[ -d $parent ]] || { mkdir -m 0755 "$parent" && chown "$uid:$gid" "$parent"; } || die "cannot create $parent"
record=$parent/$stamp
mkdir -m 0755 "$record" || die "cannot create $record"
exec > >(tee -a "$record/summary.txt") 2>&1
trap 'chown -R "$uid:$gid" "$record" 2> /dev/null' EXIT

# Console number: vt get prints the foreground console; vt N switches to N and
# waits until it is in front (chvt's ioctls; the system has no kbd package).
vt() {
    timeout 15 python3 - "$1" <<'EOF'
import fcntl, os, struct, sys
VT_GETSTATE, VT_ACTIVATE, VT_WAITACTIVE = 0x5603, 0x5606, 0x5607
fd = os.open('/dev/tty0', os.O_RDWR | os.O_NOCTTY)
if sys.argv[1] == 'get':
    print(struct.unpack('HHH', fcntl.ioctl(fd, VT_GETSTATE, bytes(6)))[0])
else:
    fcntl.ioctl(fd, VT_ACTIVATE, int(sys.argv[1]))
    fcntl.ioctl(fd, VT_WAITACTIVE, int(sys.argv[1]))
EOF
}

say "RECORD=$record"
say "START=$stamp MODE=$mode"
say "KERNEL=$(uname -r)"
. /etc/os-release && say "OS=${PRETTY_NAME:-unknown}"
say "BOOT_SECONDS=$(cut -d' ' -f1 /proc/uptime)"

# LightDM's X server: its display, authority file, log and console.
xpid=$(pgrep -n -f "^$XORG ") || xpid=$(pgrep -n -x Xorg) || xpid=
display='' auth='' xlog='' xvt=''
if [[ -n $xpid ]]; then
    mapfile -t args < <(tr '\0' '\n' < "/proc/$xpid/cmdline")
    for ((i = 0; i < ${#args[@]}; i++)); do
        case ${args[i]} in
            :[0-9]*) display=${args[i]} ;;
            -auth) auth=${args[i + 1]:-} ;;
            -logfile) xlog=${args[i + 1]:-} ;;
            vt[0-9]*) xvt=${args[i]#vt} ;;
        esac
    done
fi
[[ -n $xlog && -f $xlog ]] || xlog=/var/log/Xorg.${display#:}.log
say "XORG_PID=${xpid:-none} DISPLAY=${display:-none} X_CONSOLE=${xvt:-unknown} FOREGROUND_CONSOLE=$(vt get 2> /dev/null || echo unknown)"
x_ok=0
if [[ -n $display && -n $auth && -r $auth ]]; then
    x_ok=1
else
    say 'X: no running X server with a readable authority file; the dpms and xrandr attempts are skipped'
fi
xrun() { DISPLAY=$display XAUTHORITY=$auth timeout 15 "$@"; }

ask() {  # $1: question; the answer goes to $answer
    say ''
    say "QUESTION: $1"
    answer=
    read -r -t 600 answer < /dev/tty || true
    answer=$(printf '%s' "$answer" | tr -cd '[:print:]' | head -c 200)
    say "ANSWER: ${answer:-(none)}"
}
yes_answer() { [[ ${answer,,} == y* ]]; }

kernel_since() {  # $1: epoch seconds; the display's kernel lines since then
    journalctl -k --no-pager -o short-monotonic --since "@$1" 2> /dev/null | grep -iE "$KPAT"
}
output_name() {  # the HDMI output's RandR name, or the first output's
    local list
    list=$(xrun xrandr --query 2> /dev/null | awk '$2 == "connected" || $2 == "disconnected" { print $1 }')
    grep -m1 -i '^hdmi' <<< "$list" || head -n 1 <<< "$list"
}
regs() {  # $1: tag; tegradc's registers to the record, without waiting on a busy driver
    local reader
    [[ -r $REGS ]] || { say "REGS $1: unreadable"; return 0; }
    timeout 5 cat "$REGS" > "$record/regs-$1.txt" 2> /dev/null &
    reader=$!
    for _ in 1 2 3 4 5 6; do kill -0 "$reader" 2> /dev/null || break; sleep 1; done
    if kill -0 "$reader" 2> /dev/null; then
        say "REGS $1: the read is still blocked after 6 s; left behind"
        return 0
    fi
    wait "$reader"
    # tegradc's dump is empty while the head is power-gated.
    [[ -s $record/regs-$1.txt ]] || say "REGS $1: empty (the display head is powered down)"
}
regdiff() {  # $1, $2: tags; the registers that differ between the two readings
    local out
    [[ -s $record/regs-$1.txt && -s $record/regs-$2.txt ]] || { say "REGDIFF $1 $2: no readings"; return 0; }
    out=$(awk '
        FNR == 1 { win = "-"; file++ }
        /^WINDOW [A-Z]+:/ { win = substr($2, 1, length($2) - 1); next }
        NF == 3 && $3 ~ /^[0-9a-f]+$/ { key = win " " $1; if (file == 1) a[key] = $3; else b[key] = $3; order[key] = NR }
        END {
            for (k in b) if ((k in a) && a[k] != b[k] && k !~ /INT_STATUS|CRC|CURSOR_POSITION/) print order[k], k, a[k], b[k]
        }' "$record/regs-$1.txt" "$record/regs-$2.txt" | sort -n | cut -d' ' -f2-)
    if [[ -z $out ]]; then
        say "REGDIFF $1 $2: none"
    else
        say "REGDIFF $1 $2 (window, register, before, after):"
        head -n 60 <<< "$out" | sed 's/^/  /'
    fi
}
helper_lines() {  # $1: epoch seconds; enable-hdmi-wake.sh's helper, when installed, and its log since then
    (( helper )) || return 0
    say "HELPER $HELPER_UNIT: $(systemctl is-active "$HELPER_UNIT" 2> /dev/null)"
    journalctl -u "$HELPER_UNIT" --no-pager -o short-monotonic --since "@$1" 2> /dev/null | grep -v '^-- ' \
        | tee "$record/helper-$1.txt" | tail -n 8 | cut -c1-160 | sed 's/^/  helper: /'
}
state() {  # $1: tag; $2: epoch seconds the kernel lines start from
    local tag=$1 since=$2 lines out
    if (( x_ok && have_xset )); then
        xrun xset -q > "$record/xset-$tag.txt" 2>&1
        say "$tag X_MONITOR=$(grep -o 'Monitor is [A-Za-z ]*' "$record/xset-$tag.txt" | head -n 1 || echo unknown)"
    fi
    if (( x_ok && have_xrandr )); then
        xrun xrandr --query > "$record/xrandr-$tag.txt" 2>&1
        out=$(awk '$2 == "connected" || $2 == "disconnected" { s = $1 " " $2; if ($3 ~ /^[0-9]+x[0-9]+/) s = s " " $3; print s }' \
            "$record/xrandr-$tag.txt" | paste -sd';')
        say "$tag XRANDR=${out:-none}"
    fi
    lines=$(kernel_since "$since")
    printf '%s\n' "$lines" > "$record/kernel-$tag.txt"
    say "$tag KERNEL_LINES=$(grep -c . <<< "$lines") UNPLUGS=$(grep -ci 'unplug' <<< "$lines")"
    [[ -n $lines ]] && tail -n 12 <<< "$lines" | cut -c1-160 | sed "s/^/  $tag kernel: /"
    regs "$tag"
}

# 1. State.
ask 'What does the monitor show now? 1 = dark, its power light in standby; 2 = a "no signal" message; 3 = black but lit; 4 = the desktop; 5 = something else (describe)'
first=$answer
say "BOOT_UNPLUGS=$(journalctl -k -b --no-pager 2> /dev/null | grep -ci 'unplugged')"
journalctl -k -b --no-pager -o short-monotonic 2> /dev/null | grep -iE "$KPAT" > "$record/kernel-boot.txt"
say "BOOT_DISPLAY_LINES=$(grep -c . "$record/kernel-boot.txt")"
tail -n 8 "$record/kernel-boot.txt" | cut -c1-160 | sed 's/^/  boot kernel: /'
if [[ -f $xlog ]]; then
    tail -n 300 "$xlog" > "$record/xorg-tail.txt"
    grep -E '\((EE|WW)\)|DFP|HDMI|[Cc]onnect|DPMS|[Hh]otplug' "$record/xorg-tail.txt" | tail -n 15 | cut -c1-160 | sed 's/^/  X log: /'
fi
if (( x_ok && have_xset )); then
    xrun xset -q > "$record/xset-start.txt" 2>&1
    sed -n '/DPMS/,$p' "$record/xset-start.txt" | sed 's/^/  xset: /'
fi
(( x_ok && have_xrandr )) && xrun xrandr --verbose > "$record/xrandr-verbose-start.txt" 2>&1
say "BLANKING_MANAGERS=$(pgrep -a -f 'unity-settings-daemon|gsd-power|gnome-screensaver|light-locker|xfce4-power-manager|xfce4-screensaver|xscreensaver|unity-panel' \
    | awk '{ print $2 }' | xargs -r -n1 basename | sort -u | paste -sd, || true)"
loginctl list-sessions --no-legend 2> /dev/null | awk '{ print "  session: " $0 }'

if [[ $mode == dark && $first == 4* ]]; then
    say 'The desktop shows, so there is nothing to wake. To test now: sudo bash probe-hdmi-wake.sh force'
    say "HDMI_WAKE=DONE wake=not-needed record=$record"
    exit 0
fi

# 2. With force: blank through X's DPMS, as the idle timeout does.
if [[ $mode == force ]]; then
    (( x_ok && have_xset )) || die 'force needs X and xset'
    say "FORCE: X's DPMS off; watching the kernel for $WAIT s. Do not touch the Nano's keyboard or mouse."
    t=$(date +%s)
    xrun xset dpms force off || say 'FORCE: xset dpms force off failed'
    for ((s = 10; s <= WAIT; s += 10)); do
        sleep 10
        say "FORCE +${s}s: kernel lines $(kernel_since "$t" | grep -c .), unplugs $(kernel_since "$t" | grep -ci 'unplug')"
    done
    state forced "$t"
    ask 'Is the monitor dark now (asleep or no signal)? (y/n)'
    yes_answer || { say "The blank did not leave the screen dark; nothing to wake."; say "HDMI_WAKE=DONE wake=not-needed record=$record"; exit 0; }
    ask 'Now press a key on the Nano keyboard once and wait 10 s. Did the picture come back? (y/n)'
    woke=0
    yes_answer && woke=1
    helper_lines "$t"
    if (( woke )); then
        state key "$t"
        if (( helper )); then
            say "A key woke the screen after a forced blank, with the $HELPER_UNIT helper running."
            say "HDMI_WAKE=DONE wake=key-with-helper record=$record"
        else
            say "A key woke the screen after a forced blank: the failure needs the idle blank (or a longer sleep) to show."
            say "HDMI_WAKE=DONE wake=key record=$record"
        fi
        exit 0
    fi
fi

say "WATCH: the display's kernel lines for $WATCH s. Do not touch the Nano's keyboard or mouse."
t=$(date +%s)
sleep "$WATCH"
state dark "$t"

# 3. Wake attempts, the least intrusive first.
attempt() {  # $1: name; $2: what it does; the command follows
    local name=$1 what=$2 t rc
    shift 2
    say ''
    say "ATTEMPT $name: $what"
    t=$(date +%s)
    "$@" > "$record/attempt-$name.txt" 2>&1
    rc=$?
    say "ATTEMPT $name: exit $rc$( [[ -s $record/attempt-$name.txt ]] && printf ' (%s)' "$(head -c 160 "$record/attempt-$name.txt" | tr '\n' ' ')")"
    sleep 6
    state "$name" "$t"
    ask "After '$name': is the picture back on the monitor? (y/n)"
    if yes_answer; then
        say "WOKE_BY=$name"
        regdiff dark "$name"
        say "HDMI_WAKE=DONE wake=$name record=$record"
        exit 0
    fi
}
console_switch() {
    local back=${xvt:-$(vt get)}
    [[ $back =~ ^[0-9]+$ ]] || { echo "X's console is unknown"; return 1; }
    vt 1 && sleep 3 && vt "$back"
}
fb_unblank() { printf '0\n' > "$FB_BLANK"; }

if (( x_ok && have_xset )); then
    attempt dpms 'xset dpms force on' xrun xset dpms force on
fi
if (( x_ok && have_xrandr )); then
    out=$(output_name)
    if [[ -n $out ]]; then
        attempt xrandr "xrandr --output $out --auto" xrun xrandr --output "$out" --auto
    else
        say 'ATTEMPT xrandr: skipped, xrandr lists no output'
    fi
fi
attempt console "console 1, 3 s, then back to console ${xvt:-$(vt get 2> /dev/null)}" console_switch
if [[ -w $FB_BLANK ]]; then
    attempt fb "0 into $FB_BLANK" fb_unblank
fi

say ''
say 'Nothing woke the screen. To get it back: sudo systemctl restart display-manager (this ends the desktop session), or reboot.'
say "HDMI_WAKE=DONE wake=none record=$record"

#!/usr/bin/env bash
# Bring the HDMI picture back after the screen blank on Ubuntu 26.04
# with JetPack 5's X driver, which otherwise leaves the screen dark until a
# reboot.
#
# Usage, from an SSH login to the Nano:
#   sudo bash enable-hdmi-wake.sh          install the helper and start it
#   sudo bash enable-hdmi-wake.sh --undo   stop it and remove it
#
# What happens (probe-hdmi-wake.sh, 2026-10-18): after X's DPMS blank the
# monitor (a Samsung S27C31x) toggles its hotplug line about every 7 s. Each
# time, tegradc turns the display head on, and R35.6's X driver powers it down
# again 5 ms later ("blank - powerdown"), which is right while X has the
# monitor off. After a key or the mouse, X has the monitor on again, but the
# driver neither turns the head on nor stops powering it down after each
# hotplug, so the picture never returns; xset dpms force on does not help
# either. A new mode set (xrandr --output HDMI-0 --auto) brings it back at once.
#
# This installs HELPER, a small service run as root (UNIT, enabled at boot).
# It follows the kernel's tegradc lines, and while the head has been powered
# down for GRACE seconds it reads X's monitor state once a second (xset -q).
# When X has the monitor on with the head down, it runs xrandr --auto on the
# connected HDMI output, at most MAX_PER_MIN times a minute, and logs it
# (journalctl -u nano-hdmi-wake). It talks to the X server on the console in
# front with that server's own authority file, so it works at LightDM's login
# screen and in a session. The monitor still sleeps; nothing else changes, and
# the X configuration and packages are left alone. Files that carry MARK are
# this script's: it updates them and --undo removes them, and it refuses any
# other file in their place. The last line is HDMI_WAKE_FIX=PASS or
# HDMI_WAKE_FIX=FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
HELPER=/usr/local/sbin/nano-hdmi-wake
UNIT=/etc/systemd/system/nano-hdmi-wake.service
NAME=nano-hdmi-wake.service
MARK="Written by jetson-ubuntu-26's enable-hdmi-wake.sh"
read -r -d '' HELPER_TEXT << 'EOF'
#!/usr/bin/env bash
# Jetson Nano: a new HDMI mode set when JetPack 5's X driver leaves the
# display head powered down while X has the monitor on (after the screen
# blank, the monitor's hotplug toggles make it do that until a mode set).
# Written by jetson-ubuntu-26's enable-hdmi-wake.sh; its --undo removes it.
set -u
XORG=/usr/lib/nano-xorg/Xorg
ACTIVE=/sys/class/tty/tty0/active
GRACE=2        # seconds the head stays down before X's monitor state is read
MAX_PER_MIN=3  # mode sets a minute at most

xpid='' xvt='' display='' auth=''
x_env() {  # display and auth of the X server on the console in front
    local fg exe pid args i vt
    read -r fg < "$ACTIVE" 2> /dev/null || return 1
    if [[ -n $xpid && $fg == "$xvt" ]] && { read -r -d '' exe < "/proc/$xpid/cmdline"; } 2> /dev/null \
        && [[ $exe == "$XORG" ]]; then
        return 0
    fi
    xpid=''
    for pid in $(pgrep -f "^$XORG "); do
        mapfile -t args < <(tr '\0' '\n' < "/proc/$pid/cmdline" 2> /dev/null)
        display='' auth='' vt=''
        for ((i = 0; i < ${#args[@]}; i++)); do
            case ${args[i]} in
                :[0-9]*) display=${args[i]} ;;
                -auth) auth=${args[i + 1]:-} ;;
                vt[0-9]*) vt=tty${args[i]#vt} ;;
            esac
        done
        if [[ $vt == "$fg" && -n $display && -r $auth ]]; then
            xpid=$pid xvt=$vt
            return 0
        fi
    done
    return 1
}
xrun() { DISPLAY=$display XAUTHORITY=$auth timeout 10 "$@"; }
monitor_on() { x_env && [[ $(xrun xset -q 2> /dev/null) == *'Monitor is On'* ]]; }
noted='' noted_at=0
note() {  # $1: a message, repeated at most every 10 minutes
    [[ $1 == "$noted" ]] && (( SECONDS - noted_at < 600 )) && return 0
    echo "$1"
    noted=$1 noted_at=$SECONDS
}

echo "following the kernel's tegradc lines (grace $GRACE s, at most $MAX_PER_MIN mode sets a minute)"
down=0 down_at=0 checked=-1
times=()
while true; do
    if IFS= read -r -t 1 line; then
        case $line in
            *tegradc*': blank - powerdown'*) down=1 down_at=$SECONDS ;;
            *tegradc*': unblank'*) down=0 ;;
        esac
    elif (( $? <= 128 )); then
        echo 'the kernel log ended'
        exit 1
    fi
    # While the head is down, X's monitor state once a second.
    (( down && SECONDS - down_at >= GRACE && SECONDS != checked )) || continue
    checked=$SECONDS
    monitor_on || continue
    out=$(xrun xrandr --current 2> /dev/null | awk '$2 == "connected" && $1 ~ /^HDMI/ { print $1; exit }')
    if [[ -z $out ]]; then
        note 'the head is down with the monitor on, but xrandr shows no connected HDMI output'
        continue
    fi
    now=$SECONDS recent=()
    for t in "${times[@]}"; do (( now - t < 60 )) && recent+=("$t"); done
    times=("${recent[@]}")
    if (( ${#times[@]} >= MAX_PER_MIN )); then
        note "the head is still down with the monitor on after $MAX_PER_MIN mode sets in a minute; waiting"
        continue
    fi
    times+=("$now")
    if xrun xrandr --output "$out" --auto; then
        echo "the head was powered down with the monitor on: new mode set on $out"
    else
        echo "the head was powered down with the monitor on: xrandr --output $out --auto failed"
    fi
    down_at=$SECONDS  # the mode set gets GRACE seconds to bring the head up
done < <(journalctl -k -f -n 0 -o cat)
EOF
read -r -d '' UNIT_TEXT << 'EOF'
# Written by jetson-ubuntu-26's enable-hdmi-wake.sh; its --undo removes it.
[Unit]
Description=Jetson Nano: new HDMI mode set when the X driver leaves the display off
Documentation=https://github.com/igsova/jetson-nano-ubuntu-26
After=systemd-journald.service

[Service]
ExecStart=/usr/local/sbin/nano-hdmi-wake
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF

die() { printf 'HDMI_WAKE_FIX=FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

mode=${1:-apply}
[[ $mode == apply || $mode == --undo ]] || die "unknown option '$mode' (none, or --undo)"
[[ $(id -u) -eq 0 ]] || die 'run this with sudo'
[[ $(uname -r) == "$KERNEL" ]] || die "run this on the Nano's $KERNEL kernel"
for tool in systemctl journalctl pgrep xset xrandr awk timeout; do command -v "$tool" > /dev/null || die "no $tool"; done

ours() {  # $1: path; true when the file is one this script wrote
    [[ -f $1 ]] && grep -qF "$MARK" "$1"
}
put() {  # $1: path, $2: text, $3: mode
    local tmp
    if [[ -e $1 ]]; then
        ours "$1" || die "$1 exists and is not this script's; look at it first"
        if [[ $(cat "$1") == "$2" ]]; then
            say "IN_PLACE $1"
            return 0
        fi
    fi
    tmp=$(mktemp "$1.XXXXXX") || die "cannot write in ${1%/*}"
    printf '%s\n' "$2" > "$tmp" && chmod "$3" "$tmp" && mv -f "$tmp" "$1" || { rm -f "$tmp"; die "cannot write $1"; }
    say "WRITTEN $1"
}

if [[ $mode == --undo ]]; then
    for f in "$HELPER" "$UNIT"; do
        [[ ! -e $f ]] || ours "$f" || die "$f is not this script's; look at it first"
    done
    systemctl disable --now "$NAME" > /dev/null 2>&1 || true
    rm -f "$UNIT" "$HELPER"
    systemctl daemon-reload
    if [[ -e $UNIT || -e $HELPER ]] || systemctl is-active --quiet "$NAME"; then
        say 'HDMI_WAKE_FIX=FAIL: the helper is still there or running'
        exit 1
    fi
    say "REMOVED $HELPER $UNIT"
    say 'HDMI_WAKE_FIX=PASS undone'
    exit 0
fi

install -d -m 0755 "${HELPER%/*}" || die "cannot create ${HELPER%/*}"
put "$HELPER" "$HELPER_TEXT" 0755
bash -n "$HELPER" || die "$HELPER does not parse"
put "$UNIT" "$UNIT_TEXT" 0644
systemctl daemon-reload || die 'systemctl daemon-reload failed'
systemctl enable "$NAME" > /dev/null 2>&1 || die "cannot enable $NAME"
systemctl restart "$NAME" || die "cannot start $NAME"
sleep 3
if systemctl is-enabled --quiet "$NAME"; then say 'ENABLED=PASS'; else say 'ENABLED=FAIL'; say 'HDMI_WAKE_FIX=FAIL'; exit 1; fi
if systemctl is-active --quiet "$NAME"; then
    say 'ACTIVE=PASS'
else
    say 'ACTIVE=FAIL'
    journalctl -u "$NAME" -n 10 --no-pager -o cat | sed 's/^/  log: /'
    say 'HDMI_WAKE_FIX=FAIL'
    exit 1
fi
journalctl -u "$NAME" -n 3 --no-pager -o cat | sed 's/^/  log: /'
say 'Test: sudo bash probe-hdmi-wake.sh force, and press a key when it asks.'
say 'HDMI_WAKE_FIX=PASS'

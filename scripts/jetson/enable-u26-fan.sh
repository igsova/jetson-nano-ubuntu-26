#!/usr/bin/env bash
# Switch on the Nano's fan control at every boot on Ubuntu 26.04
# under the 5.10 kernel.
#
# Usage, from an SSH login to the Nano:
#   sudo bash enable-u26-fan.sh          add the rule and apply it now
#   sudo bash enable-u26-fan.sh --undo   remove it and switch the control off
#
# The fan follows the thermal zone of NVIDIA's fan-temperature estimator
# (therm_fan_est, zone type thermal-fan-est): its trips (51, 61, 71 and 82 C)
# drive the pwm-fan cooling device through the zone's governor. Under 5.10 a
# thermal zone stays disabled until its driver enables it, which R35.6's
# therm_fan_est does not, so the fan never ran (check-u26-power.sh,
# 2026-10-16: 66 C with the fan at 0; on with the zone enabled by hand).
# This writes one udev rule, RULE below, that enables that zone whenever it
# appears, reloads udev and applies the rule to the thermal zones now, then
# checks that the zone is enabled. Nothing else changes. The last line is
# U26_FAN=PASS or U26_FAN=FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
SYS=/sys
RULE=/etc/udev/rules.d/60-nano-fan-zone.rules
ZONE_TYPE=thermal-fan-est
read -r -d '' RULE_TEXT << 'EOF'
# Jetson Nano: enable the fan's thermal zone (NVIDIA's therm_fan_est). Under
# the 5.10 kernel a thermal zone stays disabled until its driver enables it,
# and R35.6's therm_fan_est does not, so the fan never ran. Written by
# jetson-ubuntu-26's enable-u26-fan.sh; its --undo removes it.
ACTION=="add|change", SUBSYSTEM=="thermal", KERNEL=="thermal_zone*", ATTR{type}=="thermal-fan-est", ATTR{mode}="enabled"
EOF

die() { printf 'U26_FAN=FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

mode=${1:-apply}
[[ $mode == apply || $mode == --undo ]] || die "unknown option '$mode' (none, or --undo)"
[[ $(id -u) -eq 0 ]] || die 'run this with sudo'
[[ $(uname -r) == "$KERNEL" ]] || die "run this on the Nano's $KERNEL kernel"
command -v udevadm > /dev/null || die 'no udevadm'
zone=
for z in "$SYS"/class/thermal/thermal_zone*; do
    [[ $(cat "$z/type" 2> /dev/null) == "$ZONE_TYPE" ]] && { zone=$z; break; }
done
[[ -n $zone ]] || die "no $ZONE_TYPE thermal zone"
cooling=
for d in "$SYS"/class/thermal/cooling_device*; do
    [[ $(cat "$d/type" 2> /dev/null) == pwm-fan ]] && { cooling=$d; break; }
done
state() {
    say "$1 zone=${zone##*/} mode=$(cat "$zone/mode" 2> /dev/null) temp=$(cat "$zone/temp" 2> /dev/null)" \
        "fan_state=$(cat "$cooling/cur_state" 2> /dev/null || echo -)" \
        "cur_pwm=$(cat "$SYS/bus/platform/devices/pwm-fan/cur_pwm" 2> /dev/null || echo -)"
}
ours() { [[ -f $RULE && $(cat "$RULE") == "$RULE_TEXT" ]]; }
reload() {
    udevadm control --reload || return 1
    udevadm trigger --subsystem-match=thermal --action=change || return 1
    udevadm settle --timeout=30
}

state BEFORE
if [[ $mode == --undo ]]; then
    if [[ -e $RULE ]]; then
        ours || die "$RULE is not the one this script writes; look at it first"
        rm -f "$RULE" || die "cannot remove $RULE"
        reload || say 'UDEV_RELOAD=FAIL'
    fi
    echo disabled > "$zone/mode" 2> /dev/null || say "ZONE_MODE=FAIL cannot write $zone/mode"
    state AFTER
    [[ ! -e $RULE && $(cat "$zone/mode") == disabled ]] || { say 'U26_FAN=FAIL'; exit 1; }
    say 'U26_FAN=PASS undone'
    exit 0
fi

if [[ -e $RULE ]]; then
    ours || die "$RULE exists with other contents; look at it first"
    say "RULE=already in place ($RULE)"
else
    tmp=$(mktemp "$RULE.XXXXXX") || die "cannot write in ${RULE%/*}"
    printf '%s\n' "$RULE_TEXT" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$RULE" \
        || { rm -f "$tmp"; die "cannot write $RULE"; }
    say "RULE=written ($RULE)"
fi
if command -v udevadm > /dev/null && udevadm verify --help > /dev/null 2>&1; then
    udevadm verify --no-style "$RULE" > /dev/null 2>&1 && say 'RULE_SYNTAX=PASS' || say 'RULE_SYNTAX=FAIL'
fi
reload && say 'UDEV_RELOAD=PASS' || say 'UDEV_RELOAD=FAIL'
sleep 2  # the estimator re-reads its sensors about once a second
state AFTER
[[ $(cat "$zone/mode" 2> /dev/null) == enabled ]] || { say 'U26_FAN=FAIL the zone is not enabled'; exit 1; }
say 'U26_FAN=PASS'

#!/usr/bin/env bash
# Check the Nano's board features that were still to verify on Ubuntu 26.04
# under the 5.10 kernel, without changing anything.
#
# Usage, from an SSH login to the Nano:
#   sudo bash check-u26-board.sh
#
# Root only to read debugfs (the memory clock) and the kernel log. It writes
# nothing but its record, ~/u26-board-check/<stamp> of the account that ran
# sudo, and checks:
#   1. the system: 26.04 on 5.10.216-tegra, running, no failed unit;
#   2. USB: each device and its speed, the onboard hub's USB 2 and USB 3 halves
#      (0bda:5411 at 480 Mb/s, 0bda:0411 at 5 Gb/s), the input devices, and
#      enumeration errors since boot;
#   3. the network: the PCIe Ethernet and any Wi-Fi adapter (driver, link, an
#      IPv4 address), the default route, a name lookup and network time.
#      Addresses, MAC addresses and network names are not recorded;
#   4. serial: ttyTHS1 and ttyTHS2 on the Tegra serial driver (data over the
#      header pins needs a loopback wire and is not tested);
#   5. power: nvpmodel's mode and its boot service, then the CPU cores online
#      and the CPU and GPU top clocks against that mode in /etc/nvpmodel.conf,
#      the CPU governor and the memory clock;
#   6. the fan driver's state, its thermal zone enabled, and every thermal zone;
#   7. one tegrastats sample and the kernel's warnings since boot.
# The last line is U26_BOARD_CHECK=PASS or FAIL. UNTESTED marks a feature with
# nothing attached (no cable, no adapter); it does not fail the check.
set -uo pipefail

KERNEL=5.10.216-tegra
SYS=/sys
DEV=/dev
PROC=/proc
OS_RELEASE=/etc/os-release
NVPMODEL_CONF=/etc/nvpmodel.conf
DEBUGFS=/sys/kernel/debug
LOOKUP=ports.ubuntu.com

die() { printf 'U26_BOARD_CHECK=FAIL: %s\n' "$*" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || die 'run this with sudo'
# shellcheck disable=SC1090  # the path is a variable for the host test
. "$OS_RELEASE"
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for tool in systemctl journalctl ip getent timedatectl awk timeout; do
    command -v "$tool" > /dev/null || die "no $tool"
done
user=${SUDO_USER:-root}
home=$(getent passwd "$user" | cut -d: -f6)
[[ -d $home ]] || die "no home folder for $user"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$home/u26-board-check/$stamp
mkdir -p "${record%/*}" && mkdir "$record" || die "cannot create a new record folder $record"
exec 3>&1 4>&2
exec > >(tee "$record/summary.txt") 2>&1
tee_pid=$!
printf 'RECORD=%s\nKERNEL=%s\nOS=%s\nUPTIME=%s\n' "$record" "$(uname -r)" "$PRETTY_NAME" "$(uptime -p 2> /dev/null)"

result=PASS
check() {  # NAME VALUE: PASS, UNTESTED or FAIL, with details after it
    printf '%s=%s\n' "$1" "$2"
    [[ $2 == FAIL* ]] && result=FAIL
    return 0
}
finish() {
    printf 'U26_BOARD_CHECK=%s record=%s\n' "$result" "$record"
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    chown -R "$user:" "${record%/*}" 2> /dev/null
    [[ $result == PASS ]] && exit 0
    exit 1  # explicit: in a trap, a bare exit keeps the status from before it
}
trap 'printf "INTERRUPTED\n"; result=FAIL; finish' INT TERM
get() { local v; v=$(cat "$1" 2> /dev/null) && printf '%s' "$v" || printf -- '-'; }
driver_of() { local link; link=$(readlink "$1/driver" 2> /dev/null) && printf '%s' "${link##*/}" || printf -- '-'; }
journalctl -k -b --no-pager -o short-monotonic > "$record/kernel.log" 2>&1

# --- 1. The system.
state=$(systemctl is-system-running 2>&1)
failed=$(systemctl --failed --no-legend --plain 2> /dev/null | awk '{print $1}' | tr '\n' ' ')
printf 'SYSTEM_STATE=%s\nFAILED_UNITS=%s\n' "$state" "${failed:-none}"
[[ $state == running && -z $failed ]] && check SYSTEM PASS || check SYSTEM "FAIL $state ${failed}"

# --- 2. USB.
for dev in "$SYS"/bus/usb/devices/*; do
    [[ -f $dev/idVendor ]] || continue
    printf 'USB %s %s:%s speed=%s %s\n' "${dev##*/}" "$(get "$dev/idVendor")" "$(get "$dev/idProduct")" \
        "$(get "$dev/speed")" "$(get "$dev/product")"
done | tee "$record/usb.txt"
grep -q ' 0bda:5411 speed=480 ' "$record/usb.txt" && check USB2_HUB PASS || check USB2_HUB 'FAIL no 0bda:5411 at 480'
grep -q ' 0bda:0411 speed=5000 ' "$record/usb.txt" && check USB3_HUB PASS || check USB3_HUB 'FAIL no 0bda:0411 at 5000'
# Input devices that are a pointer or a keyboard, by name.
awk '/^N: Name=/ { sub(/^N: Name=/, ""); name = $0 }
     /^H: Handlers=/ { if ($0 ~ /mouse|kbd/) { sub(/^H: Handlers=/, ""); print "INPUT " name " (" $0 ")" } }' \
    "$PROC/bus/input/devices" 2> /dev/null
grep -E 'usb [0-9]+-[0-9.]+: .*(error -[0-9]+|unable to enumerate|not accepting address|descriptor read)' \
    "$record/kernel.log" > "$record/usb-errors.txt"
count=$(wc -l < "$record/usb-errors.txt")
head -n 6 "$record/usb-errors.txt" | cut -c1-160 | sed 's/^/USB_ERROR /'
(( count == 0 )) && check USB_ENUMERATION PASS || check USB_ENUMERATION "FAIL $count error lines since boot"

# --- 3. The network.
for dev in "$SYS"/bus/pci/devices/*; do
    [[ -f $dev/vendor ]] || continue
    printf 'PCI %s %s:%s driver=%s\n' "${dev##*/}" "$(get "$dev/vendor" | sed 's/^0x//')" \
        "$(get "$dev/device" | sed 's/^0x//')" "$(driver_of "$dev")"
done
ethernet=UNSEEN wifi=UNSEEN
for net in "$SYS"/class/net/*; do
    name=${net##*/}
    [[ -e $net/device ]] || continue  # lo, bridges and other virtual interfaces
    driver=$(driver_of "$net/device")
    kind=other
    [[ -e $net/wireless || -e $net/phy80211 ]] && kind=wifi
    [[ $driver == r8168 || $driver == r8169 ]] && kind=ethernet
    operstate=$(get "$net/operstate") carrier=$(get "$net/carrier")
    ipv4=no
    ip -4 -o addr show dev "$name" 2> /dev/null | grep -q ' inet ' && ipv4=yes
    printf 'NET %s kind=%s driver=%s state=%s carrier=%s speed=%s ipv4=%s\n' "$name" "$kind" "$driver" \
        "$operstate" "$carrier" "$(get "$net/speed")" "$ipv4"
    if [[ $operstate == up && $ipv4 == yes ]]; then status=PASS
    elif [[ $kind == ethernet && $carrier != 1 ]]; then status='UNTESTED no link (no cable?)'
    else status="FAIL $name $operstate, IPv4 $ipv4"; fi
    case $kind in
        ethernet) [[ $ethernet == PASS ]] || ethernet=$status ;;
        wifi) [[ $wifi == PASS ]] || wifi=$status ;;
    esac
done
[[ $ethernet == UNSEEN ]] && ethernet='FAIL no r8168 or r8169 interface'
[[ $wifi == UNSEEN ]] && wifi='UNTESTED no Wi-Fi adapter'
check ETHERNET "$ethernet"
check WIFI "$wifi"
command -v nmcli > /dev/null && nmcli -t -f DEVICE,TYPE,STATE device 2> /dev/null | sed 's/^/NM /'
route=$(ip -4 route show default 2> /dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
[[ -n $route ]] && check DEFAULT_ROUTE "PASS dev $route" || check DEFAULT_ROUTE 'FAIL none'
timeout 15 getent ahostsv4 "$LOOKUP" > /dev/null 2>&1 && check NAME_LOOKUP "PASS $LOOKUP" \
    || check NAME_LOOKUP "FAIL $LOOKUP"
synced=$(timedatectl show -p NTPSynchronized --value 2>&1)
[[ $synced == yes ]] && check TIME_SYNC PASS || check TIME_SYNC "FAIL NTPSynchronized=$synced"

# --- 4. Serial.
bad=()
for port in ttyTHS1 ttyTHS2; do
    dev=- driver=-
    if [[ -e $SYS/class/tty/$port/device ]]; then
        dev=$(readlink -f "$SYS/class/tty/$port/device") driver=$(driver_of "$SYS/class/tty/$port/device")
    fi
    printf 'SERIAL %s node=%s device=%s driver=%s\n' "$port" "$([[ -c $DEV/$port ]] && echo yes || echo no)" \
        "${dev##*/}" "$driver"
    [[ -c $DEV/$port && $driver == serial-tegra ]] || bad+=("$port")
done
printf 'SERIAL_CONSOLE %s getty=%s\n' "$(grep -o 'console=ttyS0[^ ]*' "$PROC/cmdline" | tail -n 1)" \
    "$(systemctl is-active serial-getty@ttyS0.service 2>&1)"
(( ${#bad[@]} == 0 )) && check SERIAL 'PASS (loopback untested)' || check SERIAL "FAIL ${bad[*]}"

# --- 5. Power.
nvpmodel -q > "$record/nvpmodel.txt" 2>&1
mode=$(grep -E '^[0-9]+$' "$record/nvpmodel.txt" | tail -n 1)
mode_name=$(sed -n 's/^NV Power Mode: *//p' "$record/nvpmodel.txt" | tail -n 1)
service=$(systemctl show -p Result --value nvpmodel.service 2>&1)
printf 'NVPMODEL mode=%s name=%s service_result=%s\n' "${mode:--}" "${mode_name:--}" "$service"
[[ -n $mode && $service == success ]] && check NVPMODEL PASS || check NVPMODEL FAIL
# This mode's lines in the config: CPU_ONLINE CORE_n 0|1, CPU_A57 MAX_FREQ and
# GPU MAX_FREQ (-1: the highest clock).
limits=$(awk -v id="${mode:-x}" '
    /^< *POWER_MODEL / { inmode = ($0 ~ ("ID=" id "[ >]")); next }
    /^</ { inmode = 0; next }
    inmode && $1 == "CPU_ONLINE" { sub(/^CORE_/, "", $2); print "online", $2, $3 }
    inmode && $1 == "CPU_A57" && $2 == "MAX_FREQ" { print "cpu_max", $3 }
    inmode && $1 == "GPU" && $2 == "MAX_FREQ" { print "gpu_max", $3 }' "$NVPMODEL_CONF" 2> /dev/null)
printf 'MODE_LIMITS %s\n' "$(tr '\n' ' ' <<< "$limits")"
highest_at_most() {  # LIMIT FREQUENCIES...: the highest frequency not above LIMIT (-1: no limit)
    local limit=$1 f best=-; shift
    [[ $limit =~ ^-?[0-9]+$ ]] || { printf -- '-'; return; }
    for f in "$@"; do
        [[ $f =~ ^[0-9]+$ ]] || continue
        (( limit < 0 || f <= limit )) && { [[ $best == - ]] || (( f > best )); } && best=$f
    done
    printf '%s' "$best"
}
bad=()
[[ -n $limits ]] || bad+=("no POWER_MODEL ID=${mode:-?} in $NVPMODEL_CONF")
while read -r what a b; do
    case $what in
        online)
            now=1
            [[ -f $SYS/devices/system/cpu/cpu$a/online ]] && now=$(get "$SYS/devices/system/cpu/cpu$a/online")
            [[ $now == "$b" ]] || bad+=("cpu$a online=$now, mode $b") ;;
    esac
done <<< "$limits"
policy=$SYS/devices/system/cpu/cpufreq/policy0
read -ra cpu_freqs <<< "$(get "$policy/scaling_available_frequencies")"
cpu_limit=$(awk '$1 == "cpu_max" { print $2 }' <<< "$limits")
printf 'CPU driver=%s governor=%s min=%s max=%s cur=%s available=%s\n' "$(get "$policy/scaling_driver")" \
    "$(get "$policy/scaling_governor")" "$(get "$policy/scaling_min_freq")" "$(get "$policy/scaling_max_freq")" \
    "$(get "$policy/scaling_cur_freq")" "${cpu_freqs[*]:--}"
if [[ -n $cpu_limit && ${#cpu_freqs[@]} -gt 0 ]]; then
    want=$(highest_at_most "$cpu_limit" "${cpu_freqs[@]}")
    have=$(highest_at_most "$(get "$policy/scaling_max_freq")" "${cpu_freqs[@]}")
    [[ $want != - && $want == "$have" ]] || bad+=("CPU top $have kHz (max $(get "$policy/scaling_max_freq")), mode $want")
else
    bad+=('CPU top clock not compared')
fi
gpu=$SYS/class/devfreq/57000000.gpu
read -ra gpu_freqs <<< "$(get "$gpu/available_frequencies")"
gpu_limit=$(awk '$1 == "gpu_max" { print $2 }' <<< "$limits")
printf 'GPU governor=%s min=%s max=%s cur=%s available=%s\n' "$(get "$gpu/governor")" "$(get "$gpu/min_freq")" \
    "$(get "$gpu/max_freq")" "$(get "$gpu/cur_freq")" "${gpu_freqs[*]:--}"
if [[ -n $gpu_limit && ${#gpu_freqs[@]} -gt 0 ]]; then
    want=$(highest_at_most "$gpu_limit" "${gpu_freqs[@]}")
    have=$(highest_at_most "$(get "$gpu/max_freq")" "${gpu_freqs[@]}")
    [[ $want != - && $want == "$have" ]] || bad+=("GPU top $have Hz (max $(get "$gpu/max_freq")), mode $want")
else
    bad+=('GPU top clock not compared')
fi
(( ${#bad[@]} == 0 )) && check MODE_LIMITS "PASS mode ${mode_name:-$mode}" || check MODE_LIMITS "FAIL ${bad[*]}"
governor=$(get "$policy/scaling_governor")
[[ $governor == schedutil ]] && check CPU_GOVERNOR PASS || check CPU_GOVERNOR "FAIL $governor"
emc=$(get "$DEBUGFS/clk/emc/clk_rate")
printf 'MEMORY_CLOCK_HZ=%s\n' "$emc"
[[ $emc =~ ^[0-9]+$ ]] && (( emc >= 1600000000 )) && check MEMORY_CLOCK PASS || check MEMORY_CLOCK "FAIL $emc"

# --- 6. Fan and temperatures.
fan=$SYS/bus/platform/devices/pwm-fan
if [[ -e $fan ]]; then
    line="driver=$(driver_of "$fan")"
    for attr in temp_control fan_profile target_pwm cur_pwm rpm_measured; do
        line+=" $attr=$(get "$fan/$attr" | tr '\n' ' ')"
    done
    # The fan follows the thermal-fan-est zone, which 5.10 leaves disabled
    # unless enable-u26-fan.sh's udev rule enables it.
    zone_mode=-
    for zone in "$SYS"/class/thermal/thermal_zone*; do
        [[ $(get "$zone/type") == thermal-fan-est ]] && zone_mode=$(get "$zone/mode")
    done
    line+=" zone_mode=$zone_mode"
    printf 'FAN %s\n' "$line"
    if [[ $(driver_of "$fan") == - || ! $(get "$fan/cur_pwm") =~ ^[0-9]+$ ]]; then check FAN FAIL
    elif [[ $zone_mode != enabled ]]; then check FAN "FAIL its thermal zone is $zone_mode (enable-u26-fan.sh)"
    else check FAN PASS; fi
else
    check FAN 'FAIL no pwm-fan device'
fi
hot=()
seen=0
for zone in "$SYS"/class/thermal/thermal_zone*; do
    [[ -d $zone ]] || continue
    type=$(get "$zone/type") temp=$(get "$zone/temp")
    printf 'THERMAL %s %s\n' "$type" "$temp"
    case $type in
        CPU-therm|GPU-therm)
            seen=$((seen + 1))
            [[ $temp =~ ^-?[0-9]+$ ]] && (( temp < 85000 )) || hot+=("$type=$temp") ;;
    esac
done
(( seen == 2 && ${#hot[@]} == 0 )) && check TEMPERATURES PASS || check TEMPERATURES "FAIL seen=$seen ${hot[*]}"

# --- 7. tegrastats and the kernel's warnings.
if command -v tegrastats > /dev/null; then
    timeout 4 tegrastats --interval 1000 2>&1 | head -n 2 | cut -c1-400 | sed 's/^/TEGRASTATS /'
fi
warnings=$(grep -cE 'WARNING:|Call trace:|Oops|BUG:' "$record/kernel.log")
grep -E 'WARNING:|Call trace:|Oops|BUG:' "$record/kernel.log" | head -n 5 | cut -c1-200 | sed 's/^/KERNEL /'
(( warnings == 0 )) && check KERNEL_WARNINGS PASS || check KERNEL_WARNINGS "FAIL $warnings lines"
finish

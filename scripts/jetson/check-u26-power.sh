#!/usr/bin/env bash
# Check nvpmodel's power modes and the fan under load on Ubuntu 26.04
# under the 5.10 kernel. check-u26-board.sh showed MAXN's limits with the fan
# off at idle; this switches to 5W and back and warms the board.
#
# Usage, from an SSH login to the Nano:
#   sudo bash check-u26-power.sh
#
# Steps (about 5 to 12 minutes):
#   1. the starting mode (nvpmodel -q) and its limits from /etc/nvpmodel.conf:
#      the CPU cores online and the CPU and GPU top clocks, as the kernel has
#      them, and the memory clock;
#   2. 5W (by its name in the config): the same comparison, then 10 s of load
#      on the online cores, whose clock must stay within 5W's top;
#   3. back to the starting mode, compared again;
#   4. load on every core (sha512sum of /dev/zero) for up to LOAD_SECONDS,
#      sampling the CPU, GPU and fan-estimate temperatures and the fan's PWM
#      every SAMPLE_SECONDS, until the fan has run for two samples or a CPU or
#      GPU zone reaches STOP_C; then COOL_SECONDS of samples without load.
#      The fan passes when its PWM rose; UNTESTED when the fan estimate never
#      reached the fan's first active trip point above 0 C. Its thermal zone
#      must be enabled (enable-u26-fan.sh) for the fan to run at all;
#   5. whatever happened, the load stopped, the starting mode set again, and
#      nvpmodel's saved mode (/var/lib/nvpmodel/status, which the next boot
#      applies) put back byte for byte.
# It runs in its own session, so neither Ctrl+C nor a lost connection stops it
# before step 5. Nothing else changes. The record goes to
# ~/u26-power-check/<stamp>; the last line is U26_POWER_CHECK=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
SYS=/sys
DEBUGFS=/sys/kernel/debug
NVPMODEL_CONF=/etc/nvpmodel.conf
STATUS=/var/lib/nvpmodel/status
LOW_MODE=5W
LOAD_SECONDS=600
SAMPLE_SECONDS=10
COOL_SECONDS=60
STOP_C=80

die() { printf 'U26_POWER_CHECK=FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

if [[ ${U26_POWER_INNER:-} != 1 ]]; then
    [[ $(id -u) -eq 0 ]] || die 'run this with sudo'
    [[ $(uname -r) == "$KERNEL" ]] || die "run this on the Nano's $KERNEL kernel"
    owner=${SUDO_USER:-}
    [[ -n $owner && $owner != root ]] || die 'run this with sudo from your own account'
    IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || die "no account $owner"
    [[ -d $home ]] || die "no home folder for $owner"
    for tool in setsid nvpmodel sha512sum sha256sum timeout tail awk; do
        command -v "$tool" > /dev/null || die "no $tool"
    done
    [[ -r $NVPMODEL_CONF ]] || die "no $NVPMODEL_CONF"
    pgrep -f '^sha512sum /dev/zero$' > /dev/null && die 'a sha512sum load is already running (an earlier run?)'
    here=$(cd "$(dirname "$0")" && pwd)
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    parent=$home/u26-power-check
    [[ -d $parent ]] || { mkdir -m 0755 "$parent" && chown "$uid:$gid" "$parent"; } || die "cannot create $parent"
    record=$parent/$stamp
    mkdir -m 0755 "$record" || die "cannot create $record"
    : > "$record/summary.txt"
    U26_POWER_INNER=1 RECORD=$record OWNER_IDS=$uid:$gid \
        setsid bash "$here/$(basename "$0")" < /dev/null >> "$record/summary.txt" 2>&1 &
    inner=$!
    tail -n +1 --pid="$inner" -f "$record/summary.txt"
    wait "$inner"
    exit
fi

record=$RECORD
result=PASS
start_mode=
status_saved=0
loads=()

check() {  # NAME VALUE: PASS, UNTESTED or FAIL, with details after it
    say "$1=$2"
    [[ $2 == FAIL* ]] && result=FAIL
    return 0
}
get() { local v; v=$(cat "$1" 2> /dev/null) && printf '%s' "$v" || printf -- '-'; }
mode_now() { timeout 30 nvpmodel -q < /dev/null 2> /dev/null | grep -E '^[0-9]+$' | tail -n 1; }
mode_name() {  # ID: its NAME in the config
    awk -v id="$1" '/^< *POWER_MODEL / && $0 ~ ("ID=" id "[ >]") {
        if (match($0, /NAME=[^ >]+/)) print substr($0, RSTART + 5, RLENGTH - 5) }' "$NVPMODEL_CONF"
}
mode_id() {  # NAME: its ID in the config
    awk -v name="$1" '/^< *POWER_MODEL / && $0 ~ ("NAME=" name "[ >]") {
        if (match($0, /ID=[0-9]+/)) print substr($0, RSTART + 3, RLENGTH - 3) }' "$NVPMODEL_CONF"
}
limits() {  # ID: lines "online N 0|1", "cpu_max F", "gpu_max F", "emc_max F" (-1 or 0: none)
    awk -v id="$1" '
        /^< *POWER_MODEL / { inmode = ($0 ~ ("ID=" id "[ >]")); next }
        /^</ { inmode = 0; next }
        inmode && $1 == "CPU_ONLINE" { sub(/^CORE_/, "", $2); print "online", $2, $3 }
        inmode && $1 == "CPU_A57" && $2 == "MAX_FREQ" { print "cpu_max", $3 }
        inmode && $1 == "GPU" && $2 == "MAX_FREQ" { print "gpu_max", $3 }
        inmode && $1 == "EMC" && $2 == "MAX_FREQ" { print "emc_max", $3 }' "$NVPMODEL_CONF"
}
highest_at_most() {  # LIMIT FREQUENCIES...: the highest frequency not above LIMIT (-1: no limit)
    local limit=$1 f best=-; shift
    [[ $limit =~ ^-?[0-9]+$ ]] || { printf -- '-'; return; }
    for f in "$@"; do
        [[ $f =~ ^[0-9]+$ ]] || continue
        (( limit < 0 || f <= limit )) && { [[ $best == - ]] || (( f > best )); } && best=$f
    done
    printf '%s' "$best"
}
policy=$SYS/devices/system/cpu/cpufreq/policy0
gpu=$SYS/class/devfreq/57000000.gpu
fan=$SYS/bus/platform/devices/pwm-fan
online_cpus() {
    local cpu list=0
    for cpu in "$SYS"/devices/system/cpu/cpu[1-9]*; do
        [[ $(get "$cpu/online") == 1 ]] && list+=",${cpu##*cpu}"
    done
    printf '%s' "$list"
}
compare() {  # TAG ID: the kernel's state against mode ID's limits
    local tag=$1 id=$2 what a b now want have bad=() cpu_freqs gpu_freqs lim
    lim=$(limits "$id")
    read -ra cpu_freqs <<< "$(get "$policy/scaling_available_frequencies")"
    read -ra gpu_freqs <<< "$(get "$gpu/available_frequencies")"
    say "$tag mode=$(mode_now) cores=$(online_cpus) cpu_max=$(get "$policy/scaling_max_freq")" \
        "gpu_max=$(get "$gpu/max_freq") emc=$(get "$DEBUGFS/clk/emc/clk_rate") limits: $(tr '\n' ' ' <<< "$lim")"
    [[ -n $lim ]] || bad+=("no POWER_MODEL ID=$id")
    [[ $(mode_now) == "$id" ]] || bad+=("nvpmodel reports mode $(mode_now)")
    while read -r what a b; do
        case $what in
            online)
                now=1
                [[ -f $SYS/devices/system/cpu/cpu$a/online ]] && now=$(get "$SYS/devices/system/cpu/cpu$a/online")
                [[ $now == "$b" ]] || bad+=("cpu$a online=$now, mode $b") ;;
            cpu_max)
                want=$(highest_at_most "$a" "${cpu_freqs[@]}")
                have=$(highest_at_most "$(get "$policy/scaling_max_freq")" "${cpu_freqs[@]}")
                [[ $want != - && $want == "$have" ]] || bad+=("CPU top $have, mode $want") ;;
            gpu_max)
                want=$(highest_at_most "$a" "${gpu_freqs[@]}")
                have=$(highest_at_most "$(get "$gpu/max_freq")" "${gpu_freqs[@]}")
                [[ $want != - && $want == "$have" ]] || bad+=("GPU top $have, mode $want") ;;
            emc_max)
                now=$(get "$DEBUGFS/clk/emc/clk_rate")
                [[ $a =~ ^[0-9]+$ ]] && (( a > 0 )) && { [[ $now =~ ^[0-9]+$ ]] && (( now <= a )) || bad+=("memory $now, cap $a"); } ;;
        esac
    done <<< "$lim"
    (( ${#bad[@]} == 0 )) && check "$tag" "PASS $(mode_name "$id")" || check "$tag" "FAIL ${bad[*]}"
}
set_mode() {  # ID
    local log status
    log=$record/nvpmodel-m$1-$(date +%H%M%S).txt
    timeout 60 nvpmodel -m "$1" < /dev/null > "$log" 2>&1
    status=$?
    grep -iE 'warn|err|reboot|fail' "$log" | head -n 5 | cut -c1-200 | sed "s/^/NVPMODEL -m $1: /"
    sleep 2
    (( status == 0 )) && [[ $(mode_now) == "$1" ]]
}
load_start() {
    local n
    for (( n = 0; n < $1; n++ )); do
        sha512sum /dev/zero > /dev/null 2>&1 &
        loads+=($!)
    done
}
load_stop() {
    (( ${#loads[@]} )) || return 0
    kill "${loads[@]}" 2> /dev/null
    wait "${loads[@]}" 2> /dev/null
    loads=()
}
celsius() { [[ $1 =~ ^[0-9]+$ ]] && printf '%d.%d' $(( $1 / 1000 )) $(( ($1 % 1000) / 100 )) || printf -- '-'; }
c() { celsius "$(get "$1")"; }  # a thermal zone file's millidegrees as degrees
zone() {  # TYPE: its thermal zone folder
    local z
    for z in "$SYS"/class/thermal/thermal_zone*; do
        [[ $(get "$z/type") == "$1" ]] && { printf '%s' "$z"; return 0; }
    done
    return 1
}
finish() {
    local status=$? now
    trap - EXIT
    trap '' INT TERM HUP
    load_stop
    if [[ -n $start_mode ]]; then
        if [[ $(mode_now) != "$start_mode" ]]; then
            set_mode "$start_mode" || say "MODE_SET=FAIL nvpmodel -m $start_mode"
        fi
        compare MODE_RESTORED "$start_mode"
    fi
    if (( status_saved )); then
        if ! cmp -s "$record/status.before" "$STATUS"; then
            cp -p "$record/status.before" "$STATUS.u26-power" && mv -f "$STATUS.u26-power" "$STATUS"
        fi
        now=$(sha256sum "$STATUS" 2> /dev/null | cut -d' ' -f1)
        [[ $now == "$(sha256sum "$record/status.before" | cut -d' ' -f1)" ]] \
            && check SAVED_MODE "PASS $STATUS as before" || check SAVED_MODE "FAIL $STATUS is not as before"
    fi
    (( status == 0 )) || result=FAIL
    chown -R "$OWNER_IDS" "$record" 2> /dev/null
    say "U26_POWER_CHECK=$result record=$record"
    [[ $result == PASS ]] && exit 0
    exit 1  # explicit: in a trap, a bare exit keeps the status from before it
}
trap finish EXIT
trap 'say INTERRUPTED; exit 1' INT TERM HUP

say "RECORD=$record"
say "KERNEL=$(uname -r)"
# 1. The starting mode.
start_mode=$(mode_now)
[[ -n $start_mode ]] || { start_mode=; check START_MODE 'FAIL nvpmodel -q gave no mode'; exit 1; }
low=$(mode_id "$LOW_MODE")
[[ -n $low ]] || { check LOW_MODE "FAIL no POWER_MODEL NAME=$LOW_MODE in $NVPMODEL_CONF"; exit 1; }
if [[ -f $STATUS ]]; then
    cp -p "$STATUS" "$record/status.before" && status_saved=1
    say "SAVED_MODE_FILE=$(tr '\n' ' ' < "$STATUS")"
fi
compare START_MODE "$start_mode"

# 2. 5W.
if [[ $start_mode != "$low" ]]; then
    say "Switching to $LOW_MODE (mode $low)..."
    if set_mode "$low"; then
        compare LOW_LIMITS "$low"
        IFS=, read -ra cores <<< "$(online_cpus)"
        load_start "${#cores[@]}"
        top=0
        for (( i = 0; i < 10; i++ )); do
            sleep 1
            f=$(get "$policy/scaling_cur_freq")
            [[ $f =~ ^[0-9]+$ ]] && (( f > top )) && top=$f
        done
        load_stop
        max=$(get "$policy/scaling_max_freq")
        say "LOW_LOAD cores=$(online_cpus) top_clock=$top max=$max"
        [[ $max =~ ^[0-9]+$ ]] && (( top > 0 && top <= max )) && check LOW_LOAD PASS \
            || check LOW_LOAD "FAIL top $top, max $max"
    else
        check LOW_LIMITS "FAIL nvpmodel -m $low did not set mode $low (now $(mode_now))"
    fi
    # 3. Back.
    say "Switching back to $(mode_name "$start_mode") (mode $start_mode)..."
    [[ $(mode_now) == "$start_mode" ]] || set_mode "$start_mode" || check SWITCH_BACK "FAIL nvpmodel -m $start_mode"
    compare BACK_LIMITS "$start_mode"
else
    check LOW_LIMITS "UNTESTED the starting mode is already $LOW_MODE"
fi

# 4. The fan under load.
fan_zone=$(zone thermal-fan-est) || fan_zone=
cpu_zone=$(zone CPU-therm) || cpu_zone=
gpu_zone=$(zone GPU-therm) || gpu_zone=
trip=
if [[ -n $fan_zone ]]; then
    for t in "$fan_zone"/trip_point_*_type; do
        [[ $(get "$t") == active ]] || continue
        v=$(get "${t%_type}_temp")
        [[ $v =~ ^[0-9]+$ ]] && (( v > 0 )) && { [[ -z $trip ]] || (( v < trip )); } && trip=$v
    done
fi
cooling=
for d in "$SYS"/class/thermal/cooling_device*; do
    [[ $(get "$d/type") == *fan* ]] && { cooling=$d; break; }
done
driver=$(readlink "$fan/driver" 2> /dev/null) || driver=-
say "FAN_SETUP driver=${driver##*/} temp_control=$(get "$fan/temp_control") zone_mode=$(get "$fan_zone/mode")" \
    "first_active_trip=$(celsius "$trip")" \
    "cooling_device=${cooling##*/} type=$(get "$cooling/type") max_state=$(get "$cooling/max_state")"
sample() {  # LABEL
    printf '%s cpu=%s gpu=%s fan_est=%s target_pwm=%s cur_pwm=%s rpm=%s state=%s clock=%s\n' "$1" \
        "$(c "$cpu_zone/temp")" "$(c "$gpu_zone/temp")" "$(c "$fan_zone/temp")" "$(get "$fan/target_pwm")" \
        "$(get "$fan/cur_pwm")" "$(get "$fan/rpm_measured")" "$(get "$cooling/cur_state")" \
        "$(get "$policy/scaling_cur_freq")"
}
say "Loading every core for up to $LOAD_SECONDS s, until the fan runs..."
IFS=, read -ra cores <<< "$(online_cpus)"
load_start "${#cores[@]}"
started=0 running=0 hottest_est=0 hottest=0 t=0
while (( t <= LOAD_SECONDS )); do
    line=$(sample "LOAD+${t}s")
    say "$line"
    pwm=$(get "$fan/cur_pwm")
    if [[ $pwm =~ ^[0-9]+$ ]] && (( pwm > 0 )); then running=$((running + 1)); else running=0; fi
    est=$(get "$fan_zone/temp")
    [[ $est =~ ^[0-9]+$ ]] && (( est > hottest_est )) && hottest_est=$est
    for z in "$cpu_zone" "$gpu_zone"; do
        v=$(get "$z/temp")
        [[ $v =~ ^[0-9]+$ ]] && (( v > hottest )) && hottest=$v
    done
    (( running >= 2 )) && { started=1; break; }
    (( hottest >= STOP_C * 1000 )) && { say "STOPPED at $STOP_C C"; break; }
    sleep "$SAMPLE_SECONDS"
    t=$((t + SAMPLE_SECONDS))
done
load_stop
say "Load stopped; cooling for $COOL_SECONDS s..."
for (( u = SAMPLE_SECONDS; u <= COOL_SECONDS; u += SAMPLE_SECONDS )); do
    sleep "$SAMPLE_SECONDS"
    say "$(sample "COOL+${u}s")"
done
say "FAN_RESULT hottest_cpu_gpu=$(celsius "$hottest") hottest_fan_est=$(celsius "$hottest_est")"
if (( started )); then
    check FAN_UNDER_LOAD PASS
elif [[ -n $trip ]] && (( hottest_est < trip )); then
    check FAN_UNDER_LOAD 'UNTESTED the fan estimate stayed below the first active trip point'
elif [[ -z $trip ]]; then
    check FAN_UNDER_LOAD 'UNTESTED no active trip point found for the fan'
else
    check FAN_UNDER_LOAD 'FAIL the fan did not run'
fi
exit 0

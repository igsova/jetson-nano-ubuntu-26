#!/usr/bin/env bash
# Find what keeps VIC's jobs from completing on the 26.04 card: run JetPack 4's
# video converter (nvvidconv, L4T R32.7.6) as the ordinary account and as root,
# in trial 36's pipeline and in the probe's, and optionally with the desktop
# stopped.
#
# Usage: sudo bash vic-compare.sh [--stop-desktop] INPUTS_DIR
#
# Trial 36 (Ubuntu 18.04 with JetPack 4's userspace, run as root by the check
# service) completed 120 VIC jobs on the 5.10 kernel; build #34 and its device
# tree kept that in trial 39. On Ubuntu 26.04, with the same kernel,
# device tree and VIC firmware, every job of the same converter times out after
# 10 s, from the first one after a restart (2026-10-16). This script tries the differences left that a run can change.
#
# Run with sudo from the owner's ordinary account (SUDO_USER) on
# Ubuntu 26.04 under the 5.10 kernel. INPUTS_DIR is the folder
# scripts/host/fetch-r35-cuda.py --set video wrote (JetPack 4's with
# --release r32.7), with probe-l4t-video.sh in it. In order:
#   1. probe-l4t-video.sh runs from INPUTS_DIR as the ordinary account with
#      KEEP_ROOT=1: its usual checks and smoke run, and its scratch folder
#      with the converter's libraries, kept for the runs below;
#   2. the kernel's boot lines about VIC, host1x, the falcon, its firmware,
#      the memory controller and the SMMU;
#   3. GStreamer as root loads the same nvvidconv (gst-inspect-1.0);
#   4. four cases of two frames each, CASE_SECONDS at most: trial 36's
#      pipeline (1280x720 I420 into NV12 NVMM buffers and back, to fakesink)
#      and the probe's smoke pipeline (I420 into RGBA NVMM buffers and back),
#      each as the ordinary account and as root. For each: gst-launch's exit
#      and time, the kernel's job timeouts (cdma_handle_timeout) and other
#      lines during it, VIC's power-on time, VIC's clocks 3 s in (debugfs:
#      rate, prepare and enable counts) and the converter's ioctl requests
#      (syscall trace events, as trial 36 traced them);
#   5. with --stop-desktop: the display manager is stopped, the four cases
#      run again, and the display manager is started again.
# A case passes when gst-launch exits 0 and the kernel timed out no job.
#
# What it changes, all undone before it exits (also on Ctrl-C or an error):
# the kernel's trace settings (events, pid filter, tracing_on as it was),
# the display manager with --stop-desktop (started again), and a GStreamer
# registry for root's runs in a temporary folder (removed). The results go
# to <probe record>/vic-compare, owned by the ordinary account; the probe's
# scratch folder is removed at the end.
set -uo pipefail

KERNEL=5.10.216-tegra
LIB=/usr/lib/aarch64-linux-gnu
CASE_SECONDS=60
# Kernel lines worth reading in a case, and the lines nvhost prints for every
# job timeout (its syncpoint and channel dump), which are counted instead.
FILTER='vic|host1x|nvhost|falcon|flcn|firmware|nvmap|smmu|iommu|memory-controller|mc-err|emem'
DUMP='cdma_handle_timeout|stuck waiting|previous client|SYNCPT_|FIRST_GET|TIMEOUT +[0-9]|NUM_SLOTS|NUM_HANDLES|channel [0-9]+ - |vic \([0-9]+\): *$'
BOOT_FILTER='vic|host1x|falcon|flcn|tegra21x|memory-controller|mc-err|emem|smmu'

user='' group='' home='' root='' record='' tmp='' out='' tracefs='' tracing_was='' dm_stopped=0
cleanup() {
    # Ctrl-C reaches the whole terminal group: finish the cleanup regardless.
    trap '' INT TERM HUP PIPE
    if [[ -n $tracefs && -n $tracing_was ]]; then
        trace_off
        echo "$tracing_was" > "$tracefs/tracing_on"
    fi
    if (( dm_stopped )); then
        systemctl start display-manager
        printf 'DESKTOP_RESTARTED=%s\n' "$(systemctl is-active display-manager)"
        dm_stopped=0
    fi
    if [[ -z $root && -n $tmp && -f $tmp/probe.txt ]]; then  # stopped during the probe
        record=$(sed -n 's/^RECORD=//p' "$tmp/probe.txt" | head -n 1)
        [[ $record == "$home"/l4t-video-probe/* ]] && root=$record/root
    fi
    [[ -n $tmp && -d $tmp ]] && rm -rf -- "${tmp:?}"
    if [[ -n $root && -d $root ]]; then
        runuser -u "$user" -- rm -rf -- "${root:?}" "${record:?}/frames" && printf 'ROOT_REMOVED=%s\n' "$root"
    fi
    [[ -n $out && -d $out ]] && chown -R "$user:$group" "$out"
}
die() { printf 'VIC_COMPARE=FAIL: %s\n' "$*" >&2; exit 1; }

stop_desktop=0
if [[ ${1:-} == --stop-desktop ]]; then
    stop_desktop=1
    shift
fi
(( $# == 1 )) || die 'usage: sudo bash vic-compare.sh [--stop-desktop] INPUTS_DIR'
(( $(id -u) == 0 )) || die 'run this with sudo'
user=${SUDO_USER:-}
[[ -n $user && $user != root ]] || die 'run this with sudo from the ordinary account'
home=$(getent passwd "$user" | cut -d: -f6)
[[ -n $home && -d $home ]] || die "no home folder for $user"
group=$(id -gn "$user")
[[ -d $1 ]] || die "no inputs folder $1"
inputs=$(cd "$1" && pwd)
[[ -f $inputs/probe-l4t-video.sh ]] || die "no probe-l4t-video.sh in $inputs"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for tool in runuser setpriv journalctl systemctl gst-launch-1.0 gst-inspect-1.0 timeout; do
    command -v "$tool" > /dev/null || die "no $tool"
done

trap cleanup EXIT
trap 'exit 130' INT TERM HUP
tmp=$(mktemp -d /tmp/vic-compare.XXXXXX) || die 'cannot create a temporary folder'
chmod 700 "$tmp"

# --- 1. The probe, as the ordinary account, keeping its scratch folder.
printf '== probe-l4t-video.sh as %s (KEEP_ROOT=1)\n' "$user"
runuser -u "$user" -- env HOME="$home" KEEP_ROOT=1 bash "$inputs/probe-l4t-video.sh" "$inputs" 2>&1 \
    | (trap '' INT TERM HUP; exec tee "$tmp/probe.txt")
root=$(sed -n 's/^ROOT_KEPT=//p' "$tmp/probe.txt" | tail -n 1)
record=${root%/root}
[[ -d $root && $record == "$home"/l4t-video-probe/* ]] || die 'the probe kept no scratch folder (see its output above)'
grep -q '^INSPECT=PASS$' "$tmp/probe.txt" || die "GStreamer did not load the probe's nvvidconv"
release=$(sed -n 's/^RELEASE=\([a-z0-9]*\).*/\1/p' "$tmp/probe.txt" | head -n 1)
out=$record/vic-compare
mkdir "$out" || die "cannot create $out"
exec > >(trap '' INT TERM HUP; exec tee "$out/summary.txt") 2>&1
printf 'RECORD=%s\nRELEASE=%s\nSTART=%s\n' "$out" "${release:--}" "$(date -u +%Y%m%dT%H%M%SZ)"

plugins=$root$LIB/gstreamer-1.0
mapfile -t dirs < <(find "$root" \( -type f -o -type l \) -name 'lib*.so*' ! -path "$plugins/*" -printf '%h\n' | sort -u)
(( ${#dirs[@]} )) || die 'no libraries in the scratch folder'
libdirs=$(IFS=:; echo "${dirs[*]}")
gst_env=(env -u DISPLAY -u WAYLAND_DISPLAY LD_LIBRARY_PATH="$libdirs" GST_PLUGIN_PATH="$plugins" GST_DEBUG_NO_COLOR=1)
# setpriv runs the converter in place of the traced shell, as the account with
# its groups (the video group opens the device nodes).
user_cmd=(setpriv --reuid="$user" --regid="$group" --init-groups -- "${gst_env[@]}" HOME="$home" USER="$user"
          GST_REGISTRY="$record/registry.bin")
root_cmd=("${gst_env[@]}" GST_REGISTRY="$tmp/registry.bin")

# --- 2. The kernel's boot lines.
journalctl -k -b --no-pager -o short-monotonic 2>&1 | grep -iE "$BOOT_FILTER" | grep -vE "$DUMP" \
    | head -n 30 | cut -c1-200 | sed 's/^/BOOT: /'

# --- 3. GStreamer as root (this also builds root's registry).
timeout -k 10 "$CASE_SECONDS" "${root_cmd[@]}" gst-inspect-1.0 nvvidconv > "$out/root-inspect.txt" 2>&1
status=$?
if (( status == 0 )) && grep -q 'Factory Details' "$out/root-inspect.txt"; then
    printf 'ROOT_INSPECT=PASS\n'
else
    head -n 5 "$out/root-inspect.txt" | sed 's/^/root-inspect: /'
    die "GStreamer as root did not load nvvidconv (exit $status)"
fi

# --- VIC's state: power-on time, clocks, devfreq.
vic_dir=$(find /sys/bus/platform/devices/ -maxdepth 1 -name '*.vic' | head -n 1)
vic_time() { cat "$vic_dir/power/runtime_active_time" 2> /dev/null || echo 0; }
clocks() {
    local clk d line=''
    for clk in c2bus vic03.cbus vic.floor.cbus vic03; do
        d=/sys/kernel/debug/clk/$clk
        if [[ -d $d ]]; then
            line+=" $clk=$(cat "$d/clk_rate" 2>&1)/$(cat "$d/clk_prepare_count" 2>&1)/$(cat "$d/clk_enable_count" 2>&1)"
        else
            line+=" $clk=-"
        fi
    done
    for d in /sys/class/devfreq/*vic*; do
        [[ -d $d ]] || continue
        line+=" devfreq=$(cat "$d/governor" 2>&1)@$(cat "$d/cur_freq" 2>&1)[$(cat "$d/min_freq" 2>&1)-$(cat "$d/max_freq" 2>&1)]"
    done
    printf '%s\n' "${line# }"
}
printf 'VIC_DEVICE=%s status=%s\n' "${vic_dir:--}" "$(cat "$vic_dir/power/runtime_status" 2> /dev/null || echo -)"
printf 'CLOCKS_IDLE (rate/prepare/enable) %s\n' "$(clocks)"

# --- Trace events for the converter's ioctl requests (trial 36's method).
for dir in /sys/kernel/tracing /sys/kernel/debug/tracing; do
    if [[ -d $dir/events/syscalls/sys_enter_ioctl ]]; then
        tracefs=$dir
        break
    fi
done
trace_off() {
    echo 0 > "$tracefs/tracing_on"
    echo 0 > "$tracefs/events/syscalls/sys_enter_ioctl/enable"
    echo 0 > "$tracefs/events/syscalls/sys_exit_ioctl/enable"
    echo > "$tracefs/set_event_pid"
    echo 0 > "$tracefs/options/event-fork"
}
if [[ -n $tracefs ]]; then
    tracing_was=$(cat "$tracefs/tracing_on")
    printf 'IOCTL_TRACE=%s\n' "$tracefs"
else
    printf 'IOCTL_TRACE=none (no syscall trace events)\n'
fi
# The trace summary of jp5-trial-check.sh (trial 36): each request number's
# calls and errors, the first failed calls and the last calls.
ioctl_summary() {
    awk '
    function hex(h,   i, v) {
        v = 0
        for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
        return v
    }
    /entries-in-buffer/ { print "ioctl trace: entries-in-buffer/entries-written " $3; next }
    /^#/ { next }
    match($0, /-[0-9]+ +\[[0-9]+\]/) {
        tid = substr($0, RSTART + 1, RLENGTH - 1); sub(/ .*/, "", tid)
        comm = substr($0, 1, RSTART - 1); sub(/^ +/, "", comm)
        ts = $0; sub(/: sys_ioctl.*/, "", ts); sub(/.* /, "", ts)
        if (index($0, "sys_ioctl(")) {
            x = $0; sub(/.*sys_ioctl\(fd: /, "", x)
            fd[tid] = x; sub(/,.*/, "", fd[tid])
            cmd[tid] = x; sub(/.*cmd: (0x)?/, "", cmd[tid]); sub(/,.*/, "", cmd[tid])
            # A request number passed as a signed int arrives sign-extended.
            if (length(cmd[tid]) == 16 && substr(cmd[tid], 1, 8) == "ffffffff") cmd[tid] = substr(cmd[tid], 9)
            next
        }
        if (!index($0, "sys_ioctl -> 0x") || !(tid in cmd)) next
        r = $0; sub(/.*sys_ioctl -> 0x/, "", r)
        neg = length(r) == 16 && substr(r, 1, 8) == "ffffffff"
        ret = neg ? -(4294967296 - hex(substr(r, 9, 8))) : hex(r)
        c = cmd[tid]
        if (!(c in calls)) order[++ncmds] = c
        calls[c]++; total++
        line = ts " " comm " fd=" fd[tid] " cmd=" c " ret=" ret
        if (neg) {
            nfail++
            if (!((c, ret) in seen)) errs[c] = errs[c] " " ret
            if (++seen[c, ret] <= 3 && ++shown <= 30) print "ioctl failed: " line
        }
        last[total % 12] = line
        delete cmd[tid]
    }
    END {
        printf "ioctl trace: %d calls, %d failed\n", total, nfail
        for (i = 1; i <= ncmds; i++)
            print "ioctl cmd=" order[i] " calls=" calls[order[i]] (errs[order[i]] == "" ? "" : " errors:" errs[order[i]])
        for (i = (total > 12 ? total - 11 : 1); i <= total; i++) print "ioctl last: " last[i % 12]
    }' "$1"
}

# --- 4. The cases (run_case reads the two pipelines by name).
# shellcheck disable=SC2034
nv12=(videotestsrc num-buffers=2 ! 'video/x-raw,width=1280,height=720,format=I420' ! nvvidconv
      ! 'video/x-raw(memory:NVMM),format=NV12' ! nvvidconv ! 'video/x-raw,format=I420' ! fakesink)
# shellcheck disable=SC2034
rgba=(videotestsrc num-buffers=2 pattern=smpte
      ! 'video/x-raw,format=I420,width=1280,height=720,framerate=30/1,colorimetry=bt601' ! nvvidconv
      ! 'video/x-raw(memory:NVMM),format=RGBA' ! nvvidconv ! 'video/x-raw,format=RGBA' ! fakesink)
passed=0 total=0 matrix=()
run_case() {  # DESKTOP WHO PIPELINE
    local name=$1-$2-$3 status seconds began since timeouts result vic_before sampler
    local -n pipeline=$3
    local cmd=("${root_cmd[@]}")
    [[ $2 == user ]] && cmd=("${user_cmd[@]}")
    sleep 2  # the previous case's kernel lines stay before this one's start
    since=$(date +%s)
    vic_before=$(vic_time)
    if [[ -n $tracefs ]]; then
        trace_off
        echo > "$tracefs/trace"
        echo 1 > "$tracefs/options/event-fork"
        echo 1 > "$tracefs/events/syscalls/sys_enter_ioctl/enable"
        echo 1 > "$tracefs/events/syscalls/sys_exit_ioctl/enable"
    fi
    (sleep 3; clocks > "$out/$name-clocks.txt") &
    sampler=$!
    began=$SECONDS
    # The shell adds itself to the traced pids and becomes the converter's
    # process; event-fork adds the converter's threads and children.
    timeout -k 10 "$CASE_SECONDS" bash -c 'if [[ -n $1 ]]; then echo $$ > "$1/set_event_pid"; echo 1 > "$1/tracing_on"; fi
        shift; exec "$@"' trace "$tracefs" "${cmd[@]}" gst-launch-1.0 -q "${pipeline[@]}" > "$out/$name.log" 2>&1
    status=$?
    seconds=$(( SECONDS - began ))
    wait "$sampler"
    if [[ -n $tracefs ]]; then
        trace_off
        cp "$tracefs/trace" "$out/$name-ioctl-trace.txt"
        echo > "$tracefs/trace"
        ioctl_summary "$out/$name-ioctl-trace.txt" > "$out/$name-ioctl.txt"
    fi
    sleep 2
    journalctl -k --since "@$since" --no-pager -o short-monotonic > "$out/$name-kernel.txt" 2>&1
    timeouts=$(grep -c 'cdma_handle_timeout' "$out/$name-kernel.txt")
    if (( status == 0 && timeouts == 0 )); then
        result=PASS
        passed=$(( passed + 1 ))
    elif (( timeouts > 0 )); then
        result=HANG
    else
        result=FAIL
    fi
    total=$(( total + 1 ))
    matrix+=("$name=$result")
    printf 'CASE %s result=%s exit=%s seconds=%s timeouts=%s vic_on_ms=%s\n' "$name" "$result" "$status" "$seconds" \
        "$timeouts" "$(( $(vic_time) - vic_before ))"
    printf '%s: CLOCKS_3S %s\n' "$name" "$(cat "$out/$name-clocks.txt" 2> /dev/null)"
    grep -E 'ERROR|WARNING|error|Segmentation|Bus error|Aborted|core dumped' "$out/$name.log" \
        | head -n 5 | cut -c1-200 | sed "s/^/$name: /"
    if [[ -n $tracefs ]]; then
        grep -E '^ioctl (trace: [0-9]|failed|cmd=)' "$out/$name-ioctl.txt" | head -n 60 | sed "s/^/$name: /"
    fi
    grep -iE "$FILTER" "$out/$name-kernel.txt" | grep -vE "$DUMP" | head -n 6 | cut -c1-200 | sed "s/^/$name: KERNEL: /"
}
cases() {  # DESKTOP
    local who kind
    for kind in nv12 rgba; do
        for who in user root; do
            run_case "$1" "$who" "$kind"
        done
    done
}
printf '== desktop %s\n' "$(systemctl is-active display-manager)"
cases desktop
if (( stop_desktop )); then
    if systemctl is-active --quiet display-manager; then
        printf '== stopping the display manager (%s)\n' "$(systemctl show -p Id --value display-manager)"
        systemctl stop display-manager && dm_stopped=1
        sleep 3
        printf 'X_SERVERS_LEFT=%s\n' "$(ps -C Xorg,X -o pid= | wc -l)"
        cases nodesktop
    else
        printf 'DESKTOP=not running; the cases above already ran without it\n'
    fi
fi
printf 'MATRIX %s\n' "${matrix[*]}"
printf 'VIC_COMPARE=DONE passed=%s/%s record=%s\n' "$passed" "$total" "$out"

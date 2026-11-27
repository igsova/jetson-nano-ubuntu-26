#!/usr/bin/env bash
# Does JetPack 4's display start-up decide whether VIC completes its jobs on the
# 26.04 card? Run JetPack 4's video converter (nvvidconv, L4T R32.7.6) with
# JetPack 4's own libdrm and libgbm, which probe-l4t-video.sh (and the nano-l4t
# driver set) leave out for Ubuntu's, and then as the probe runs it.
#
# Usage: sudo bash vic-r32-display.sh [--after-hang] INPUTS_DIR
#
# Under Ubuntu 18.04 (trial 39: the same kernel, device tree and VIC firmware)
# the converter made 16 requests of the display driver (tegra_dc's control node,
# a head and the framebuffer) between its GPU setup and its first VIC job, and
# its jobs completed. On the 26.04 card it makes the same requests except those
# 16, and every job times out (2026-10-16). Its
# libnvdc.so, the only JetPack 4 library that names those devices, was loaded.
# NVIDIA's libdrm.so.2 is built on it; the probe sets that aside, with
# NVIDIA's libgbm.so.1, for Ubuntu's, which looks for /dev/dri, and this kernel
# has none.
#
# Run with sudo from the owner's ordinary account (SUDO_USER) on
# Ubuntu 26.04 under the 5.10 kernel, as the first VIC use after a restart: a
# hung job may leave VIC hung for the rest of the boot, so the script refuses
# when the kernel has already timed out a VIC job this boot, unless
# --after-hang (a hang then says nothing about the libraries). INPUTS_DIR is
# JetPack 4's video inputs folder (scripts/host/fetch-r35-cuda.py --set video
# --release r32.7), checked against its SHA256SUMS. In order:
#   1. its .debs are unpacked with dpkg-deb -x into a temporary folder; nothing
#      is installed. As in the probe, a library Ubuntu also has is set aside,
#      except JetPack 4's libdrm.so.2 and libgbm.so.1, which go in a folder of
#      their own (the tegra folder's copy where the packages have two);
#   2. GStreamer as root loads nvvidconv from there (gst-inspect-1.0);
#   3. case r32-display: trial 36's pipeline (two 1280x720 I420 frames into
#      NV12 NVMM buffers and back, to fakesink) as root, with that folder ahead
#      of the others;
#   4. if it passed, case probe-display: the same without that folder, as the
#      probe runs it; and if that one hung, case r32-display-again, to see
#      whether VIC recovers within a boot.
# glvnd keeps its own list of EGL vendors in every case, as in the probe.
# For each case: gst-launch's exit, time and messages; the kernel's job
# timeouts (cdma_handle_timeout) and its other lines; VIC's power-on time; the
# converter's ioctl requests per type (syscall trace events, trial 36's method)
# with the display driver's counted ('C' and 'D' tegra_dc, 'F' the
# framebuffer); the display and EGL libraries it loaded, and every library it
# asked for and did not get (LD_DEBUG=libs,files). A case passes when
# gst-launch exits 0 and the kernel timed out no job.
#
# What it changes, all undone before it exits (also on Ctrl-C or an error): the
# kernel's trace settings (events, pid filter, tracing_on as it was) and the
# temporary folder under /var/tmp (removed). The record is
# ~/l4t-video-probe/<stamp>-r32-display, owned by the account.
set -uo pipefail

KERNEL=5.10.216-tegra
LIB=/usr/lib/aarch64-linux-gnu
CASE_SECONDS=60
# JetPack 4's display libraries that the probe sets aside for Ubuntu's.
DISPLAY_LIBS='libdrm.so.2|libgbm.so.1'
# Kernel lines worth reading in a case, and the lines nvhost prints for every
# job timeout (its syncpoint and channel dump), which are counted instead.
FILTER='vic|host1x|nvhost|falcon|flcn|firmware|nvmap|smmu|iommu|memory-controller|mc-err|emem|tegradc|tegra_dc|tegra_fb'
# (also the dump's job, gather and FIFO lines, and its bare words)
DUMP='cdma_handle_timeout|stuck waiting|previous client|SYNCPT_|FIRST_GET|TIMEOUT +[0-9]|NUM_SLOTS|NUM_HANDLES|channel [0-9]+ - |vic \([0-9]+\): *$|JOB, syncpt|GATHER at|FIFOSTAT|kernel: +([0-9a-f]{8} +)*[0-9a-f]{8} *$'
# The display and EGL libraries shown from the linker's record.
LIBS_SHOWN='drm|gbm|EGL|egl|GLdispatch|nvdc|glsi|tegra-egl'

user='' group='' home='' tmp='' out='' tracefs='' tracing_was=''
cleanup() {
    # Ctrl-C reaches the whole terminal group: finish the cleanup regardless.
    trap '' INT TERM HUP PIPE
    if [[ -n $tracefs && -n $tracing_was ]]; then
        trace_off
        echo "$tracing_was" > "$tracefs/tracing_on"
    fi
    [[ -n $tmp && -d $tmp ]] && rm -rf -- "${tmp:?}"
    [[ -n $out && -d $out ]] && chown -R "$user:$group" "$out"
}
die() { printf 'VIC_R32_DISPLAY=FAIL: %s\n' "$*" >&2; exit 1; }

after_hang=0
if [[ ${1:-} == --after-hang ]]; then
    after_hang=1
    shift
fi
(( $# == 1 )) || die 'usage: sudo bash vic-r32-display.sh [--after-hang] INPUTS_DIR'
(( $(id -u) == 0 )) || die 'run this with sudo'
user=${SUDO_USER:-}
[[ -n $user && $user != root ]] || die 'run this with sudo from the ordinary account'
home=$(getent passwd "$user" | cut -d: -f6)
[[ -n $home && -d $home ]] || die "no home folder for $user"
group=$(id -gn "$user")
[[ -d $1 ]] || die "no inputs folder $1"
inputs=$(cd "$1" && pwd)
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for tool in dpkg-deb ldconfig journalctl gst-launch-1.0 gst-inspect-1.0 timeout sha256sum; do
    command -v "$tool" > /dev/null || die "no $tool"
done
(cd "$inputs" && sha256sum --quiet -c SHA256SUMS) > /dev/null 2>&1 \
    || die "the files in $inputs do not match its SHA256SUMS"
shopt -s nullglob
converter=("$inputs"/nvidia-l4t-gstreamer_*.deb)
(( ${#converter[@]} == 1 )) || die "no nvidia-l4t-gstreamer .deb in $inputs, or more than one"
l4t=$(dpkg-deb -f "${converter[0]}" Version)
[[ $l4t == 32.7.6-* ]] || die "nvidia-l4t-gstreamer is $l4t, not JetPack 4's 32.7.6"
debs=()
for deb in "$inputs"/*.deb; do
    [[ $(basename "$deb") =~ ^(nvidia-l4t-[a-z0-9-]+|cuda-[a-z0-9-]+-10-2)_ ]] && debs+=("$deb")
done

# VIC's state this boot: a job the kernel already timed out may leave it hung.
vic_dir=$(find /sys/bus/platform/devices/ -maxdepth 1 -name '*.vic' | head -n 1)
vic_time() { cat "$vic_dir/power/runtime_active_time" 2> /dev/null || echo 0; }
earlier=$(journalctl -k -b --no-pager 2> /dev/null | grep -c 'cdma_handle_timeout.*vic')
if (( earlier > 0 && ! after_hang )); then
    die "the kernel already timed out $earlier VIC job(s) this boot; restart the Nano and run this first (or add --after-hang)"
fi

trap cleanup EXIT
trap 'exit 130' INT TERM HUP
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=$home/l4t-video-probe/$stamp-r32-display
runuser -u "$user" -- mkdir -p "$home/l4t-video-probe" && mkdir "$out" || die "cannot create $out"
exec > >(trap '' INT TERM HUP; exec tee "$out/summary.txt") 2>&1
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nL4T=%s\n' "$out" "$stamp" "$(uname -r)" "$l4t"
printf 'BOOT_VIC_TIMEOUTS=%s%s\n' "$earlier" "$( (( earlier )) && echo ' (--after-hang: a hang below says nothing about the libraries)')"
printf 'VIC_DEVICE=%s status=%s on_ms=%s\n' "${vic_dir:--}" \
    "$(cat "$vic_dir/power/runtime_status" 2> /dev/null || echo -)" "$(vic_time)"
printf 'DISPLAY_NODES=%s\n' "$(ls -d /dev/tegra_dc* /dev/fb* /dev/dri 2> /dev/null | tr '\n' ' ')"

# --- 1. The packages, unpacked into a temporary folder.
tmp=$(mktemp -d /var/tmp/vic-r32-display.XXXXXX) || die 'cannot create a temporary folder'
chmod 700 "$tmp"
root=$tmp/root
mkdir "$root" "$tmp/display" "$tmp/set-aside" || die "cannot create folders in $tmp"
for deb in "${debs[@]}"; do
    printf 'UNPACK=%s\n' "$(basename "$deb")"
    dpkg-deb -x "$deb" "$root" || die "dpkg-deb could not unpack $deb"
done
plugins=$root$LIB/gstreamer-1.0
[[ -f $plugins/libgstnvvidconv.so ]] || die "no ${plugins#"$root"}/libgstnvvidconv.so in the packages"
libdirs_of() {
    find "$root" \( -type f -o -type l \) -name 'lib*.so*' ! -path "$plugins/*" -printf '%h\n' | sort -u
}
mapfile -t dirs < <(libdirs_of)
(( ${#dirs[@]} )) || die 'no libraries in the packages'
ldconfig -n "${dirs[@]}" 2>&1 | sed 's/^/LDCONFIG: /'
# A file in the packages, with its links followed inside the scratch folder
# (an absolute link names the packages' own path, not this system's).
resolve() {
    local f=$1 t n=0
    while [[ -L $f ]] && (( n++ < 10 )); do
        t=$(readlink "$f")
        if [[ $t == /* ]]; then f=$root$t; else f=$(dirname "$f")/$t; fi
    done
    printf '%s\n' "$f"
}
# Ubuntu's libraries stay Ubuntu's (the probe's rule), except the display
# libraries, which are copied to a folder of their own and removed here.
ldconfig -p | awk -v lib="$LIB/tegra" '/ => / && index($NF, lib) != 1 {print $1}' | sort -u > "$tmp/system-libs.txt"
drop=()
while IFS= read -r file; do
    name=$(basename "$file")
    grep -qxF "$name" "$tmp/system-libs.txt" || continue
    if [[ $name =~ ^($DISPLAY_LIBS)$ ]]; then
        src=$(resolve "$file")
        [[ -f $src ]] || die "${file#"$root"} leads to ${src#"$root"}, which the packages do not have"
        printf 'DISPLAY_LIB=%s -> %s bytes=%s sha256=%s\n' "${file#"$root"}" "${src#"$root"}" "$(stat -c %s "$src")" \
            "$(sha256sum < "$src" | cut -c1-16)"
        # The tegra folder's copy wins over another of the same name.
        if [[ $file == "$root$LIB"/tegra/* || ! -e $tmp/display/$name ]]; then
            cp -- "$src" "$tmp/display/$name" || die "cannot copy ${src#"$root"}"
        fi
        drop+=("$file")
    else
        mv -- "$file" "$tmp/set-aside/" && printf 'SET_ASIDE=%s (Ubuntu has its own)\n' "${file#"$root"}"
    fi
done < <(find "$root" \( -type f -o -type l \) -name 'lib*.so*' ! -path "$plugins/*" | LC_ALL=C sort)
(( ${#drop[@]} )) && rm -f -- "${drop[@]}"
mapfile -t dirs < <(libdirs_of)
libdirs=$(IFS=:; echo "${dirs[*]}")
[[ -f $tmp/display/libdrm.so.2 ]] || die "the packages have no libdrm.so.2 that the probe would set aside"
for file in "$tmp/display"/*; do
    printf 'DISPLAY_DIR=%s sha256=%s\n' "$(basename "$file")" "$(sha256sum < "$file" | cut -c1-16)"
done
base_env=(env -u DISPLAY -u WAYLAND_DISPLAY GST_PLUGIN_PATH="$plugins" GST_REGISTRY="$tmp/registry.bin"
          GST_DEBUG_NO_COLOR=1)
# shellcheck disable=SC2034
r32_env=("${base_env[@]}" LD_LIBRARY_PATH="$tmp/display:$libdirs")
# shellcheck disable=SC2034
probe_env=("${base_env[@]}" LD_LIBRARY_PATH="$libdirs")

# --- 2. GStreamer as root (this also builds the registry).
timeout -k 10 "$CASE_SECONDS" "${probe_env[@]}" gst-inspect-1.0 nvvidconv > "$out/inspect.txt" 2>&1
status=$?
if (( status == 0 )) && grep -q 'Factory Details' "$out/inspect.txt"; then
    grep -E '^ +(Filename|Version) ' "$out/inspect.txt" | sed -E 's/^ +/inspect: /'
    printf 'INSPECT=PASS\n'
else
    head -n 5 "$out/inspect.txt" | sed 's/^/inspect: /'
    die "GStreamer did not load nvvidconv (exit $status)"
fi

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
# The trace summary of jp5-trial-check.sh (trial 36), as in vic-compare.sh:
# each request number's calls and errors, the first failed calls and the last
# calls.
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
# The display driver's requests in a summary: tegra_dc's 'C' (control node)
# and 'D' (a head), and the framebuffer's 'F', by the request's type byte.
display_requests() {
    awk '/^ioctl cmd=/ {
        c = $2; sub(/^cmd=/, "", c); n = $3; sub(/^calls=/, "", n)
        t = length(c) >= 4 ? substr(c, length(c) - 3, 2) : ""
        if (t == "43" || t == "44" || t == "46") total += n
    } END { print total + 0 }' "$1"
}

# --- 3 and 4. The cases.
pipeline=(videotestsrc num-buffers=2 ! 'video/x-raw,width=1280,height=720,format=I420' ! nvvidconv
          ! 'video/x-raw(memory:NVMM),format=NV12' ! nvvidconv ! 'video/x-raw,format=I420' ! fakesink)
matrix=()
run_case() {  # NAME ENVIRONMENT; sets result
    local name=$1 status seconds began since timeouts vic_before display
    local -n case_env=$2
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
    mkdir "$out/$name-ld"
    began=$SECONDS
    # The shell adds itself to the traced pids and becomes the converter's
    # process; event-fork adds the converter's threads and children.
    timeout -k 10 "$CASE_SECONDS" bash -c 'if [[ -n $1 ]]; then echo $$ > "$1/set_event_pid"; echo 1 > "$1/tracing_on"; fi
        shift; exec "$@"' trace "$tracefs" "${case_env[@]}" LD_DEBUG=libs,files LD_DEBUG_OUTPUT="$out/$name-ld/ld" \
        gst-launch-1.0 -q "${pipeline[@]}" > "$out/$name.log" 2>&1
    status=$?
    seconds=$(( SECONDS - began ))
    display=-
    if [[ -n $tracefs ]]; then
        trace_off
        cp "$tracefs/trace" "$out/$name-ioctl-trace.txt"
        echo > "$tracefs/trace"
        ioctl_summary "$out/$name-ioctl-trace.txt" > "$out/$name-ioctl.txt"
        display=$(display_requests "$out/$name-ioctl.txt")
    fi
    sleep 2
    journalctl -k --since "@$since" --no-pager -o short-monotonic > "$out/$name-kernel.txt" 2>&1
    timeouts=$(grep -c 'cdma_handle_timeout' "$out/$name-kernel.txt")
    if (( status == 0 && timeouts == 0 )); then
        result=PASS
    elif (( timeouts > 0 )); then
        result=HANG
    else
        result=FAIL
    fi
    matrix+=("$name=$result")
    printf 'CASE %s result=%s exit=%s seconds=%s timeouts=%s vic_on_ms=%s display_requests=%s\n' "$name" "$result" \
        "$status" "$seconds" "$timeouts" "$(( $(vic_time) - vic_before ))" "$display"
    head -n 8 "$out/$name.log" | cut -c1-200 | sed "s/^/$name: OUTPUT: /"
    # The display and EGL libraries the converter loaded, and every library a
    # process asked for (linked or dlopened) that the linker never mapped.
    awk '
        /file=.*;  (dynamically loaded|needed) by / {
            n = $0; sub(/.*file=/, "", n); sub(/ .*/, "", n)
            b = $0; sub(/.* by /, "", b); sub(/ \[.*/, "", b)
            asked[FILENAME, n] = b
        }
        /file=.*;  generating link map/ { n = $0; sub(/.*file=/, "", n); sub(/ .*/, "", n); mapped[FILENAME, n] = 1 }
        END { for (k in asked) if (!(k in mapped)) { split(k, p, SUBSEP); print p[2] " (by " asked[k] ")" } }
    ' "$out/$name-ld"/ld.* 2> /dev/null | sort -u > "$out/$name-not-loaded.txt"
    cat "$out/$name-ld"/ld.* 2> /dev/null > "$out/$name-ld.txt"
    rm -rf -- "${out:?}/${name:?}-ld"
    grep -oE 'calling init: /[^ ]+' "$out/$name-ld.txt" | sed 's/^calling init: //' | sort -u > "$out/$name-loaded.txt"
    grep -E "$LIBS_SHOWN" "$out/$name-loaded.txt" | sed "s|^$tmp/root||; s|^|$name: LOADED: |"
    head -n 12 "$out/$name-not-loaded.txt" | sed "s|$tmp/root||g; s|^|$name: NOT_LOADED: |"
    if [[ -n $tracefs ]]; then
        grep -E '^ioctl (trace: [0-9]|failed|cmd=)' "$out/$name-ioctl.txt" | head -n 60 | sed "s/^/$name: /"
    fi
    grep -iE "$FILTER" "$out/$name-kernel.txt" | grep -vE "$DUMP" | head -n 8 | cut -c1-200 | sed "s/^/$name: KERNEL: /"
}
result=''
run_case r32-display r32_env
if [[ $result == PASS ]]; then
    run_case probe-display probe_env
    [[ $result == HANG ]] && run_case r32-display-again r32_env
fi
printf 'MATRIX %s\n' "${matrix[*]}"
printf 'VIC_R32_DISPLAY=DONE %s record=%s\n' "${matrix[*]}" "$out"

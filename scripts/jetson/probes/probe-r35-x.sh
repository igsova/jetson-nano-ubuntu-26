#!/usr/bin/env bash
# Try JetPack 5's X driver and GLX on the Nano's display, from a scratch folder.
#
# Usage, from an SSH login to the Nano (not from a terminal on its desktop):
#   sudo bash probe-r35-x.sh INPUTS_DIR...
#
# Ubuntu 26.04 under the 5.10 kernel, with JetPack 4's X driver on
# the desktop (add-u26-gpu-desktop.sh). Each INPUTS_DIR is a folder
# scripts/host/fetch-r35-cuda.py wrote: NVIDIA's L4T R35.6 nvidia-l4t-core,
# nvidia-l4t-3d-core and nvidia-l4t-cuda .debs with SHA256SUMS. Only those
# three are unpacked, with dpkg-deb -x, into ~/r35-x-probe/<stamp> of the
# account that ran sudo, and R35.6's own libdrm.so.2 is set aside there, as
# nano-l4t-core sets JetPack 4's aside. Nothing is installed and no system file
# is changed.
#
# The test closes the desktop: it stops the display manager, so save work
# first. Then, each step logged in the record folder:
#   1. control: the X server 1.20 in /usr/lib/nano-xorg on :0 (vt7) with
#      LightDM's configuration and JetPack 4's X driver; then, as the account,
#      xrandr, glxinfo -B and 12 s of glxgears full screen without vsync;
#   2. trial: the same X server and configuration with R35.6's nvidia_drv.so
#      and libglxserver_nvidia.so first in the module path and LD_LIBRARY_PATH
#      at R35.6's libraries, the clients likewise; every NVIDIA library the X
#      server and glxgears map must come from the scratch folder;
#   3. the display manager started again (the login screen returns) and its
#      X server checked;
#   4. the kernel's messages since the start.
# The GL shader disk cache is off. The last line is R35_X_PROBE=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
PACKAGES='nvidia-l4t-core|nvidia-l4t-3d-core|nvidia-l4t-cuda'
XORG=/usr/lib/nano-xorg/Xorg
XMODULES=/usr/lib/nano-xorg/modules
XCONF=/etc/X11/nano-xorg.conf
XCONFDIR=/etc/X11/nano-xorg.conf.d
CONTROL_RELEASE=32.7.6
TRIAL_RELEASE=35.6.5
GEARS_SECONDS=12

die() { printf 'R35_X_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
(( $# )) || die 'give the folder holding the R35.6 driver .debs (for example ~/cuda11-inputs-2)'
inputs=()
for dir in "$@"; do
    [[ -d $dir ]] || die "no inputs folder $dir"
    inputs+=("$(cd "$dir" && pwd)")
done
[[ $(id -u) -eq 0 ]] || die 'run this with sudo'
owner=${SUDO_USER:-}
[[ -n $owner && $owner != root ]] || die 'run this with sudo from your own account'
IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || die "no account $owner"
[[ -d $home ]] || die "no home folder for $owner"
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
(cd "$here" && grep -E '  probe-r35-x\.sh$' SHA256SUMS | sha256sum --quiet -c -) > /dev/null 2>&1 \
    || die 'this script does not match the SHA256SUMS next to it'

# The test stops the desktop, and with it any terminal open on it: refuse
# unless an SSH login or a text console started this.
from_login() {
    local pid=$$ comm
    while (( pid > 1 )); do
        comm=$(< "/proc/$pid/comm") || return 1
        [[ $comm == sshd* || $comm == login ]] && return 0
        pid=$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status") || return 1
    done
    return 1
}
from_login || die 'start this from an SSH login from your PC: the test closes the desktop and its terminals'
for tool in dpkg-deb runuser systemctl pgrep glxinfo glxgears timeout; do
    command -v "$tool" > /dev/null || die "no $tool"
done
[[ -x $XORG && -f $XCONF ]] || die "no $XORG or $XCONF (add-u26-gpu-desktop.sh)"
xrandr=$(command -v xrandr || true)

# Whether the account may read and write NODE. Through bash's own test: 26.04's
# /usr/bin/test (uutils) answers no when the access comes from a supplementary
# group such as video (seen on the Nano, 2026-10-15).
owner_can_open() { as_owner '' bash -c '[[ -r $1 && -w $1 ]]' _ "$1"; }
as_owner() {  # LIBDIRS COMMAND...: run as the account on :0, with LIBDIRS first when given
    local libs=$1 envs
    shift
    envs=(PATH=/usr/local/bin:/usr/bin:/bin HOME="$home" USER="$owner" LOGNAME="$owner"
          DISPLAY=:0 __GL_SHADER_DISK_CACHE=0)
    [[ -z $libs ]] || envs+=(LD_LIBRARY_PATH="$libs")
    runuser -u "$owner" -- env -i "${envs[@]}" "$@"
}

# The GPU's device nodes, which the account's GL clients open. The 5.10
# kernel's /dev/nvgpu/igpu0 nodes have no rule in 26.04 yet; until a package
# carries R35.6's, the temporary chmod from the GL test covers them, and R35.6
# needs it. The other nodes are only reported, below.
NODES=(/dev/nvhost-ctrl /dev/nvhost-ctrl-gpu /dev/nvhost-gpu /dev/nvhost-as-gpu /dev/nvmap
       /dev/nvgpu/igpu0/power /dev/nvgpu/igpu0/ctrl /dev/nvgpu/igpu0/as
       /dev/nvgpu/igpu0/channel /dev/nvgpu/igpu0/tsg)
for node in /dev/nvgpu/igpu0/{power,ctrl,as,channel,tsg}; do
    owner_can_open "$node" \
        || die "$owner cannot open $node; give the GPU nodes to the video group first (see the GL test)"
done

stamp=$(date -u +%Y%m%dT%H%M%SZ)
parent=$home/r35-x-probe
record=$parent/$stamp
root=$record/root
[[ -d $parent ]] || { mkdir -m 0755 "$parent" && chown "$uid:$gid" "$parent"; } || die "cannot create $parent"
mkdir -m 0755 "$record" "$root" || die "cannot create $record"
# The record stays root's until the end, so that nothing the X server loads
# can change under it; the finish hands it to the account. Losing the SSH
# connection or pressing Ctrl+C still ends with the desktop back.
trap '' HUP PIPE
exec > >(trap '' INT TERM; exec tee --output-error=warn "$record/summary.txt") 2>&1
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\nACCOUNT=%s\n' \
    "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME" "$(id "$owner")"

result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || result=FAIL; }
alive() { local state; state=$(sed 's/.*) //' "/proc/$1/stat" 2> /dev/null | cut -c 1); [[ -n $state && $state != Z ]]; }
dm_xorg() { pgrep -n -f "^$XORG .*-seat seat0"; }  # LightDM's X server
nvidia_maps() {  # PID: the NVIDIA libraries and X modules it has mapped
    awk '$6 ~ /^\// { print $6 }' "/proc/$1/maps" 2> /dev/null | sort -u \
        | awk -F/ '$NF ~ /^(libnv|libcuda|nvidia_drv)|_nvidia/'
}

xpid=
dm_stopped=0
stop_x() {
    [[ -n $xpid ]] || return 0
    kill -TERM "$xpid" 2> /dev/null
    for _ in $(seq 20); do alive "$xpid" || break; sleep 0.5; done
    if alive "$xpid"; then
        kill -KILL "$xpid" 2> /dev/null
        sleep 2
    fi
    if alive "$xpid"; then
        check X_STOP "FAIL (pid $xpid did not exit)"
    else
        wait "$xpid" 2> /dev/null
    fi
    xpid=
}
restore_desktop() {
    local pid=
    systemctl start display-manager || printf 'DISPLAY_MANAGER_START=FAIL\n'
    for _ in $(seq 60); do
        pid=$(dm_xorg)
        [[ -n $pid ]] && grep -q '/nvidia_drv\.so$' <(nvidia_maps "$pid") && break
        pid=
        sleep 0.5
    done
    sleep 3
    if [[ -n $pid ]] && alive "$pid" && systemctl is-active --quiet display-manager; then
        printf 'DESKTOP_XORG=%s\n' "$(tr '\0' ' ' < "/proc/$pid/cmdline")"
        check DESKTOP_RESTORED PASS
    else
        check DESKTOP_RESTORED FAIL
    fi
}
finish() {
    trap - EXIT
    trap '' INT TERM
    stop_x
    (( dm_stopped )) && restore_desktop
    if journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1; then
        printf 'KERNEL_LOG=read lines=%s\n' "$(wc -l < "$record/kernel.log")"
        grep -iE 'tegradc|tegra-dc|dc\.|hdmi|sor|nvdc|nvgpu|nvmap|smmu|mmu_fault|host1x|error|fault|oops|bug' \
            "$record/kernel.log" | tail -n 40 | sed 's/^/KERNEL: /'
    fi
    chown -R "$uid:$gid" "$record"
    printf 'R35_X_PROBE=%s record=%s\n' "$result" "$record"
    [[ $result == PASS ]] && exit 0  # (exit with no status in a trap keeps the status before it)
    exit 1
}
trap finish EXIT
trap 'printf "INTERRUPTED\n"; result=FAIL; exit 130' INT TERM

# --- Inputs, as the PC wrote them.
shopt -s nullglob
debs=()
for dir in "${inputs[@]}"; do
    name=$(basename "$dir")
    if (cd "$dir" && sha256sum --quiet -c SHA256SUMS) > "$record/sha256-check-$name.txt" 2>&1; then
        printf 'INPUTS_SHA256=PASS %s\n' "$dir"
    else
        cat "$record/sha256-check-$name.txt"
        check INPUTS_SHA256 "FAIL $dir"
        exit 1
    fi
    cp "$dir/SHA256SUMS" "$record/SHA256SUMS-$name"
    for deb in "$dir"/*.deb; do
        [[ $(basename "$deb") =~ ^($PACKAGES)_ ]] && debs+=("$deb")
    done
done
(( ${#debs[@]} )) || die 'no nvidia-l4t-core, -3d-core or -cuda .debs in the inputs'
for deb in "${debs[@]}"; do
    printf 'UNPACK=%s\n' "$(basename "$deb")"
    [[ $(dpkg-deb -f "$deb" Version) == 35.6.* ]] || die "$(basename "$deb") is not from R35.6"
    dpkg-deb -x "$deb" "$root" || die "dpkg-deb could not unpack $deb"
done
tegra=$root/usr/lib/aarch64-linux-gnu/tegra
[[ -d $tegra ]] || die 'no usr/lib/aarch64-linux-gnu/tegra in the R35 packages'
if [[ -e $tegra/libdrm.so.2 ]]; then
    mv "$tegra/libdrm.so.2" "$record/libdrm.so.2.r35-set-aside"
    printf 'SET_ASIDE=libdrm.so.2 (R35.6 core; Ubuntu libdrm stays in charge)\n'
fi
egl_vendor=$(find "$root" -name 'libEGL_nvidia.so.0' | head -n 1)
dirs=("$tegra")
[[ -z $egl_vendor || ${egl_vendor%/*} == "$tegra" ]] || dirs+=("${egl_vendor%/*}")
libdirs=$(IFS=:; echo "${dirs[*]}")
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
"$ldconfig" -n "${dirs[@]}" 2>&1 | sed 's/^/LDCONFIG: /'
ls -l "${dirs[@]}" > "$record/libraries.txt"
xmodules=$record/xmodules
mkdir -p "$xmodules/drivers" "$xmodules/extensions"
for module in drivers/nvidia_drv.so extensions/libglxserver_nvidia.so; do
    found=$(find "$root" -path "*/xorg/modules/$module" | head -n 1)
    [[ -n $found ]] || die "no $module in the R35 packages (nvidia-l4t-3d-core)"
    ln -s "$found" "$xmodules/$module"
    printf 'TRIAL_MODULE=%s sha256=%s\n' "${found#"$root"}" "$(sha256sum < "$found" | cut -d ' ' -f 1)"
done
glx_vendor=$(find "$root" -name 'libGLX_nvidia.so.0' | head -n 1)
[[ -n $glx_vendor ]] || die 'no libGLX_nvidia.so.0 in the R35 packages'
[[ ${glx_vendor%/*} == "$tegra" ]] || die "libGLX_nvidia.so.0 is outside $tegra"
printf 'TRIAL_LIBDIRS=%s\n' "$libdirs"
for node in "${NODES[@]}"; do
    if [[ ! -e $node ]]; then state=missing
    elif owner_can_open "$node"; then state=read-write
    else state=no-access; fi
    printf 'NODE %s %s %s\n' "$node" "$state" "$(stat -c '%U:%G %a' "$node" 2> /dev/null)"
done
printf 'XRANDR=%s\n' "${xrandr:-unavailable}"

# --- One X server on :0 at a time, as LightDM starts it but with access control
# off for the account's clients.
start_x() {  # NAME LIBDIRS MODULEPATH
    local name=$1 libs=$2 modules=$3 ready=$record/$1-displayfd envs
    envs=(PATH=/usr/sbin:/usr/bin:/sbin:/bin)
    [[ -z $libs ]] || envs+=(LD_LIBRARY_PATH="$libs")
    : > "$ready"
    env -i "${envs[@]}" "$XORG" :0 vt7 -novtswitch -nolisten tcp -noreset -ac \
        -modulepath "$modules" -config "$XCONF" -configdir "$XCONFDIR" \
        -logfile "$record/$name-xorg.log" -displayfd 3 \
        3> "$ready" < /dev/null > "$record/$name-xorg.out" 2>&1 &
    xpid=$!
    for _ in $(seq 90); do
        [[ -s $ready ]] && return 0
        if ! alive "$xpid"; then
            wait "$xpid"
            printf '%s_X_EXIT=%s\n' "${name^^}" "$?"
            xpid=
            return 1
        fi
        sleep 0.5
    done
    printf '%s_X_READY=not within 45 s\n' "${name^^}"
    return 1
}
lib_mix() {  # CHECK MAPS_FILE: every NVIDIA file in MAPS_FILE comes from the scratch folder
    local outside
    if [[ ! -s $2 ]]; then
        check "$1" 'FAIL (no NVIDIA libraries mapped)'
        return
    fi
    outside=$(awk -v r="$root/" 'index($0, r) != 1' "$2")
    if [[ -z $outside ]]; then
        printf '%s_FILES=%s\n' "$1" "$(awk -F/ '{ printf "%s%s", sep, $NF; sep = " " }' "$2")"
        check "$1" PASS
    else
        printf '%s_OUTSIDE=%s\n' "$1" "$(tr '\n' ' ' <<< "$outside")"
        check "$1" FAIL
    fi
}
phase() {  # NAME RELEASE LIBDIRS MODULEPATH
    local name=$1 release=$2 libs=$3 modules=$4 tag=${1^^} log=$record/$1-xorg.log gears pid fps
    printf '%s_MODULEPATH=%s\n' "$tag" "$modules"
    if ! start_x "$name" "$libs" "$modules"; then
        check "${tag}_X_START" FAIL
        grep -hE '\(EE\)|error|Error' "$log" "$record/$name-xorg.out" 2> /dev/null | head -n 30 \
            | sed "s/^/$name-xorg: /"
        stop_x
        return
    fi
    check "${tag}_X_START" PASS
    sleep 2
    grep -E 'X\.Org X Server|NVIDIA dlloader X Driver|NVIDIA GLX Module|\(EE\)|NVIDIA\(0\): +(Valid display|NVIDIA GPU|Memory|.*: connected|Virtual screen)|Setting mode' \
        "$log" | head -n 40 | sed "s/^/$name-xorg: /"
    if grep -qE "NVIDIA dlloader X Driver +${release//./\\.} " "$log" && grep -q 'Setting mode "' "$log"; then
        check "${tag}_X_DRIVER" PASS
    else
        check "${tag}_X_DRIVER" FAIL
    fi
    if [[ -n $xrandr ]]; then
        as_owner "$libs" timeout -k 5 20 "$xrandr" --current > "$record/$name-xrandr.txt" 2>&1
        grep -E ' connected|\*' "$record/$name-xrandr.txt" | head -n 6 | sed "s/^/$name-xrandr: /"
        if grep -q ' connected' "$record/$name-xrandr.txt" && grep -qE '[0-9]\*' "$record/$name-xrandr.txt"; then
            check "${tag}_XRANDR" PASS
        else
            check "${tag}_XRANDR" FAIL
        fi
    fi
    as_owner "$libs" timeout -k 5 30 glxinfo -B > "$record/$name-glxinfo.txt" 2>&1
    grep -E 'direct rendering|OpenGL (vendor|renderer|version|core profile version|ES profile version) string|rror' \
        "$record/$name-glxinfo.txt" | head -n 12 | sed "s/^/$name-glxinfo: /"
    if grep -qx 'direct rendering: Yes' "$record/$name-glxinfo.txt" \
            && grep -qE "^OpenGL (core profile )?version string: .*NVIDIA ${release//./\\.}" "$record/$name-glxinfo.txt"; then
        check "${tag}_GLX" PASS
    else
        check "${tag}_GLX" FAIL
    fi
    as_owner "$libs" env __GL_SYNC_TO_VBLANK=0 timeout -k 5 "$GEARS_SECONDS" glxgears -fullscreen \
        > "$record/$name-glxgears.txt" 2>&1 &
    gears=$!
    sleep 6
    pid=$(pgrep -n -x -u "$owner" glxgears)
    [[ -z $pid ]] || nvidia_maps "$pid" > "$record/$name-glxgears-maps.txt"
    nvidia_maps "$xpid" > "$record/$name-xorg-maps.txt"
    wait "$gears"
    grep -E 'FPS|rror' "$record/$name-glxgears.txt" | head -n 6 | sed "s/^/$name-glxgears: /"
    fps=$(grep -oE '= *[0-9.]+ FPS' "$record/$name-glxgears.txt" | tail -n 1 | grep -oE '[0-9.]+')
    printf '%s_GLXGEARS_FPS=%s\n' "$tag" "${fps:-none}"
    if [[ -n $fps ]] && awk -v f="$fps" 'BEGIN { exit !(f > 10) }'; then
        check "${tag}_GLXGEARS" PASS
    else
        check "${tag}_GLXGEARS" FAIL
    fi
    if [[ $name == trial ]]; then
        lib_mix TRIAL_X_LIB_MIX "$record/$name-xorg-maps.txt"
        lib_mix TRIAL_GLX_LIB_MIX "$record/$name-glxgears-maps.txt"
    fi
    stop_x
    sleep 2
}

# --- The desktop, stopped for the test.
if systemctl is-active --quiet display-manager; then
    printf 'DESKTOP_XORG_BEFORE=%s\n' "$(dm_xorg | head -n 1)"
    printf 'STOPPING_DESKTOP\n'
    dm_stopped=1
    systemctl stop display-manager || die 'could not stop the display manager'
    for _ in $(seq 40); do [[ -z $(dm_xorg) ]] && break; sleep 0.5; done
    [[ -z $(dm_xorg) ]] || die "LightDM's X server is still running"
else
    printf 'DESKTOP=not running\n'
fi
[[ ! -e /tmp/.X11-unix/X0 ]] || printf 'NOTE=/tmp/.X11-unix/X0 left over\n'

# --- 1. Control: JetPack 4's X driver, as the desktop uses it.
phase control "$CONTROL_RELEASE" '' "$XMODULES"
# --- 2. Trial: R35.6's X driver, GLX module and libraries from the scratch folder.
phase trial "$TRIAL_RELEASE" "$libdirs" "$xmodules,$XMODULES"
# --- 3 and 4 in finish: the desktop back, then the kernel's messages.

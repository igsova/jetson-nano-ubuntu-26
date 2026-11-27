#!/usr/bin/env bash
# Try JetPack 5's OpenGL ES (EGL) libraries on the Nano's GPU from a scratch folder.
#
# Usage: bash probe-r35-gl.sh INPUTS_DIR...
#
# Run as the owner's ordinary account, without sudo, on Ubuntu 26.04
# under the 5.10 kernel. Each INPUTS_DIR is a folder scripts/host/fetch-r35-cuda.py
# wrote (the driver set: NVIDIA's L4T R35.6 nvidia-l4t-core, nvidia-l4t-3d-core
# and nvidia-l4t-cuda .debs, with SHA256SUMS); this script's own folder holds it,
# egl_probe.py and a SHA256SUMS for the two. Only those three .debs are
# unpacked, with dpkg-deb -x, into ~/r35-gl-probe/<stamp>; nothing is
# installed, and the system's JetPack 4 GL, X and CUDA files are left as they
# are. No window system is used: DISPLAY and WAYLAND_DISPLAY are unset.
#
# Steps, each logged in the record folder:
#   1. control: egl_probe.py on the system's JetPack 4 EGL and CUDA 10.2 driver;
#   2. trial: the same probe with libglvnd pointed at R35.6's libEGL_nvidia and
#      LD_LIBRARY_PATH at its libraries, every NVIDIA library required to come
#      from the scratch folder, and R35.6's libcuda in the same process;
#   3. after: the control again, to show the system's GL is as it was;
#   4. the kernel's messages since the start, when the account may read them.
# The GL shader disk cache and CUDA's JIT cache are off, so nothing is
# written outside the record folder. The last line is R35_GL_PROBE=PASS or
# FAIL; it passes when the trial passes and the after step matches the
# control.
set -uo pipefail

KERNEL=5.10.216-tegra
PACKAGES='nvidia-l4t-core|nvidia-l4t-3d-core|nvidia-l4t-cuda'

die() { printf 'R35_GL_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
(( $# )) || die 'give the folder holding the R35.6 driver .debs (for example ~/cuda11-inputs-2)'
inputs=()
for dir in "$@"; do
    [[ -d $dir ]] || die "no inputs folder $dir"
    inputs+=("$(cd "$dir" && pwd)")
done
[[ $(id -u) -ne 0 ]] || die 'run this as the ordinary account, not with sudo'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
probe=$here/egl_probe.py
[[ -f $probe ]] || die "no egl_probe.py next to this script"
(cd "$here" && grep -E '  (probe-r35-gl\.sh|egl_probe\.py)$' SHA256SUMS | sha256sum --quiet -c -) \
    > /dev/null 2>&1 || die 'this script or egl_probe.py does not match the SHA256SUMS next to it'

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$HOME/r35-gl-probe/$stamp
root=$record/root
mkdir -p "$root" || die "cannot create $record"
exec > >(tee "$record/summary.txt") 2>&1
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\n' "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME"
printf 'ACCOUNT=%s\n' "$(id)"

result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || result=FAIL; }

# --- Inputs, as the PC wrote them.
shopt -s nullglob
debs=()
for dir in "${inputs[@]}"; do
    name=$(basename "$dir")
    if (cd "$dir" && sha256sum --quiet -c SHA256SUMS) > "$record/sha256-check-$name.txt" 2>&1; then
        printf 'INPUTS_SHA256=PASS %s\n' "$dir"
    else
        cat "$record/sha256-check-$name.txt"
        printf 'INPUTS_SHA256=FAIL %s\n' "$dir"
        printf 'R35_GL_PROBE=FAIL record=%s\n' "$record"
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
    dpkg-deb -x "$deb" "$root" || die "dpkg-deb could not unpack $deb"
done
tegra=$root/usr/lib/aarch64-linux-gnu/tegra
[[ -d $tegra ]] || die "no usr/lib/aarch64-linux-gnu/tegra in the R35 packages"
egl_vendor=$(find "$root" -name 'libEGL_nvidia.so.0' | head -n 1)
[[ -n $egl_vendor ]] || die 'no libEGL_nvidia.so.0 in the R35 packages (nvidia-l4t-3d-core)'
dirs=("$tegra")
[[ ${egl_vendor%/*} == "$tegra" ]] || dirs+=("${egl_vendor%/*}")
libdirs=$(IFS=:; echo "${dirs[*]}")
# Soname links (libcuda.so.1 and the like), in the scratch folder only.
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
"$ldconfig" -n "${dirs[@]}" 2>&1 | sed 's/^/LDCONFIG: /'
ls -l "$tegra" "${egl_vendor%/*}" > "$record/libraries.txt"
libcuda=$tegra/libcuda.so.1
[[ -e $libcuda ]] || die 'no libcuda.so.1 after ldconfig -n'
vendor_json=$record/10_nvidia_r35.json
printf '{\n    "file_format_version" : "1.0.0",\n    "ICD" : {\n        "library_path" : "%s"\n    }\n}\n' \
    "$egl_vendor" > "$vendor_json"
printf 'TRIAL_EGL_VENDOR=%s\nTRIAL_LIBCUDA=%s\n' "$(readlink -f "$egl_vendor")" "$(readlink -f "$libcuda")"
for lib in libnvidia-eglcore libnvidia-glsi libnvidia-glcore libGLESv2_nvidia libnvidia-ptxjitcompiler; do
    found=$(find "$root" -name "$lib.so*" -type f | head -n 1)
    printf 'TRIAL_%s=%s\n' "$lib" "${found:-missing}"
done

# --- The GPU's device nodes, as this account sees them.
{
    ls -l /dev/nvhost-ctrl-gpu /dev/nvhost-gpu /dev/nvhost-as-gpu /dev/nvhost-ctrl /dev/nvmap
    ls -lR /dev/nvgpu
    ls -l /dev/dri /dev/tegra_dc_* /dev/host1x* 2>&1
} > "$record/device-nodes.txt" 2>&1
for node in /dev/nvhost-ctrl /dev/nvhost-ctrl-gpu /dev/nvhost-gpu /dev/nvhost-as-gpu /dev/nvmap \
        /dev/nvgpu/igpu0/ctrl /dev/nvgpu/igpu0/channel /dev/nvgpu/igpu0/as /dev/nvgpu/igpu0/tsg; do
    if [[ ! -e $node ]]; then state=missing
    elif [[ -r $node && -w $node ]]; then state=read-write
    else state=no-access; fi
    printf 'NODE %s %s\n' "$node" "$state"
done

run_probe() {  # NAME then the environment and probe arguments
    local name=$1; shift
    env -u DISPLAY -u WAYLAND_DISPLAY __GL_SHADER_DISK_CACHE=0 CUDA_CACHE_DISABLE=1 "$@" \
        > "$record/$name.log" 2>&1
    local status=$?
    grep -E '^(LOAD_ERROR|SYMBOL_ERROR|EGL_DEVICES|EGL_PLATFORM|EGL_INIT|EGL_VENDOR|EGL_VERSION|EGL_SURFACE|EGL_CONTEXT|GL_VENDOR|GL_RENDERER|GL_VERSION|GLSL_VERSION|GL_[A-Z_]+|CUDA_INIT|CUDA_MEMORY|LIB_MIX|PROBE)=|=FAIL' \
        "$record/$name.log" | sed "s/^/$name: /"
    printf '%s_EXIT=%s\n' "${name^^}" "$status"
    return "$status"
}

# --- 1. Control: the system's JetPack 4 EGL and CUDA 10.2 driver.
run_probe control timeout -k 10 120 python3 -I "$probe" --cuda libcuda.so.1
control=$?
printf 'CONTROL=%s\n' "$( (( control == 0 )) && echo PASS || echo FAIL)"

# --- 2. Trial: R35.6's EGL, GL ES and CUDA libraries from the scratch folder.
run_probe trial __EGL_VENDOR_LIBRARY_FILENAMES="$vendor_json" LD_LIBRARY_PATH="$libdirs" \
    timeout -k 10 120 python3 -I "$probe" --cuda "$libcuda" --lib-root "$root" \
    && check R35_GL PASS || check R35_GL FAIL

# --- 3. After: the control again.
run_probe after timeout -k 10 120 python3 -I "$probe" --cuda libcuda.so.1
after=$?
(( (after == 0) == (control == 0) )) && check SYSTEM_GL_UNCHANGED PASS || check SYSTEM_GL_UNCHANGED FAIL

# --- 4. Kernel messages since the start (needs the adm or systemd-journal group).
if journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1 \
        && ! grep -q 'No journal files were opened\|not seeing messages' "$record/kernel.log"; then
    printf 'KERNEL_LOG=read lines=%s\n' "$(wc -l < "$record/kernel.log")"
    grep -iE 'nvgpu|nvmap|smmu|mmu_fault|mc-err|gk20a|gm20b|host1x|tegra' "$record/kernel.log" \
        | tail -n 40 | sed 's/^/KERNEL: /'
else
    printf 'KERNEL_LOG=unavailable (%s)\n' "$(head -n 1 "$record/kernel.log")"
fi

printf 'R35_GL_PROBE=%s record=%s\n' "$result" "$record"
[[ $result == PASS ]]

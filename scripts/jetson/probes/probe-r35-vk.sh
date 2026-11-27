#!/usr/bin/env bash
# Try JetPack 5's Vulkan driver on the Nano's GPU from a scratch folder.
#
# Usage: bash probe-r35-vk.sh INPUTS_DIR...
#
# Run as the owner's ordinary account, without sudo, on Ubuntu 26.04
# under the 5.10 kernel. Each INPUTS_DIR is a folder scripts/host/fetch-r35-cuda.py
# wrote (NVIDIA's L4T R35.6 nvidia-l4t-core, nvidia-l4t-3d-core and
# nvidia-l4t-cuda .debs, with SHA256SUMS); this script's own folder holds it,
# vk_probe.py and a SHA256SUMS for the two. Only those three .debs are
# unpacked, with dpkg-deb -x, into ~/r35-vk-probe/<stamp>, with R35.6's
# libdrm.so.2 set aside there as in the X test; nothing is installed and no
# system file is changed. The 26.04 root has the Vulkan loader but no Vulkan
# driver manifest, so the script writes one for each driver in the record
# folder and names it in VK_DRIVER_FILES. No window system is used: DISPLAY
# and WAYLAND_DISPLAY are unset.
#
# Steps, each logged in the record folder:
#   1. control: vk_probe.py on JetPack 4's Vulkan driver (the system's
#      libGLX_nvidia.so.0);
#   2. trial: the same probe on R35.6's libGLX_nvidia.so.0, LD_LIBRARY_PATH at
#      its libraries, every NVIDIA library required to come from the scratch
#      folder;
#   3. the kernel's messages since the start, when the account may read them.
# The shader disk cache is off. The last line is R35_VK_PROBE=PASS or FAIL;
# it passes when the trial passes.
set -uo pipefail

KERNEL=5.10.216-tegra
PACKAGES='nvidia-l4t-core|nvidia-l4t-3d-core|nvidia-l4t-cuda'
SYSTEM_GLX=/usr/lib/aarch64-linux-gnu/tegra/libGLX_nvidia.so.0
# The api_version of R32.7.6's own manifest (nvidia-l4t-3d-core 32.7.6,
# tegra/nvidia_icd.json, read on the owner's PC); nano-l4t-gl leaves it out.
CONTROL_API=1.2.131

die() { printf 'R35_VK_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }

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
probe=$here/vk_probe.py
[[ -f $probe ]] || die "no vk_probe.py next to this script"
(cd "$here" && grep -E '  (probe-r35-vk\.sh|vk_probe\.py)$' SHA256SUMS | sha256sum --quiet -c -) \
    > /dev/null 2>&1 || die 'this script or vk_probe.py does not match the SHA256SUMS next to it'

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$HOME/r35-vk-probe/$stamp
root=$record/root
mkdir -p "$root" || die "cannot create $record"
exec > >(tee "$record/summary.txt") 2>&1
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\n' "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME"
printf 'ACCOUNT=%s\n' "$(id)"
printf 'LOADER=%s\n' "$(readlink -f /usr/lib/aarch64-linux-gnu/libvulkan.so.1 2> /dev/null || echo missing)"

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
        printf 'R35_VK_PROBE=FAIL record=%s\n' "$record"
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
trial_glx=$tegra/libGLX_nvidia.so.0
[[ -f $trial_glx ]] || die 'no tegra/libGLX_nvidia.so.0 in the R35 packages (nvidia-l4t-3d-core)'
dirs=("$tegra")
egl_dir=$root/usr/lib/aarch64-linux-gnu/tegra-egl
[[ ! -d $egl_dir ]] || dirs+=("$egl_dir")
libdirs=$(IFS=:; echo "${dirs[*]}")
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
"$ldconfig" -n "${dirs[@]}" 2>&1 | sed 's/^/LDCONFIG: /'
ls -l "${dirs[@]}" > "$record/libraries.txt"
# R35.6's own manifest names its api_version; the library path is ours.
trial_api=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["ICD"]["api_version"])' \
    "$tegra/nvidia_icd.json" 2> /dev/null) || die 'cannot read api_version from R35.6 tegra/nvidia_icd.json'
manifest() {  # FILE LIBRARY API_VERSION
    printf '{\n    "file_format_version" : "1.0.0",\n    "ICD" : {\n        "library_path" : "%s",\n        "api_version" : "%s"\n    }\n}\n' \
        "$2" "$3" > "$1"
}
trial_json=$record/nvidia_icd_r35.json
manifest "$trial_json" "$trial_glx" "$trial_api"
printf 'TRIAL_DRIVER=%s api_version=%s\n' "$trial_glx" "$trial_api"
for node in /dev/nvhost-ctrl /dev/nvhost-ctrl-gpu /dev/nvhost-gpu /dev/nvhost-as-gpu /dev/nvmap \
        /dev/nvgpu/igpu0/power /dev/nvgpu/igpu0/ctrl /dev/nvgpu/igpu0/as \
        /dev/nvgpu/igpu0/channel /dev/nvgpu/igpu0/tsg; do
    if [[ ! -e $node ]]; then state=missing
    elif [[ -r $node && -w $node ]]; then state=read-write  # bash's test; 26.04's uutils test misreads groups
    else state=no-access; fi
    printf 'NODE %s %s\n' "$node" "$state"
done

run_probe() {  # NAME then the environment and probe arguments
    local name=$1; shift
    env -u DISPLAY -u WAYLAND_DISPLAY __GL_SHADER_DISK_CACHE=0 "$@" > "$record/$name.log" 2>&1
    local status=$?
    grep -E '^(LOAD_ERROR|SYMBOL_ERROR|VK_ERROR|VK_LOADER|VK_INSTANCE|VK_DEVICE_[0-9]+|VK_PHYSICAL_DEVICE|VK_FEATURES|VK_FEATURES_SHOWN|VK_DEVICE_EXTENSIONS|VK_DEVICE_EXTENSIONS_SHOWN|VK_MEMORY_HEAPS|VK_QUEUE_FAMILIES|VK_DEVICE|VK_MEMORY|VK_PIPELINE|VK_COMPUTE|VK_COMPUTE_RATE|LIB_MIX|PROBE)=|=FAIL' \
        "$record/$name.log" | sed "s/^/$name: /"
    printf '%s_EXIT=%s\n' "${name^^}" "$status"
    return "$status"
}

# --- 1. Control: JetPack 4's Vulkan driver.
if [[ -f $SYSTEM_GLX ]]; then
    control_json=$record/nvidia_icd_r32.json
    manifest "$control_json" "$SYSTEM_GLX" "$CONTROL_API"
    run_probe control VK_DRIVER_FILES="$control_json" VK_ICD_FILENAMES="$control_json" \
        timeout -k 10 120 python3 -I "$probe"
    control=$?
    printf 'CONTROL=%s\n' "$( (( control == 0 )) && echo PASS || echo FAIL)"
else
    printf 'CONTROL=skipped (no %s)\n' "$SYSTEM_GLX"
fi

# --- 2. Trial: R35.6's Vulkan driver and libraries from the scratch folder.
run_probe trial VK_DRIVER_FILES="$trial_json" VK_ICD_FILENAMES="$trial_json" LD_LIBRARY_PATH="$libdirs" \
    timeout -k 10 120 python3 -I "$probe" --lib-root "$root" \
    && check R35_VK PASS || check R35_VK FAIL

# --- 3. Kernel messages since the start (needs the adm or systemd-journal group).
if journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1 \
        && ! grep -q 'No journal files were opened\|not seeing messages' "$record/kernel.log"; then
    printf 'KERNEL_LOG=read lines=%s\n' "$(wc -l < "$record/kernel.log")"
    grep -iE 'nvgpu|nvmap|smmu|mmu_fault|mc-err|gk20a|gm20b|host1x|tegra' "$record/kernel.log" \
        | tail -n 40 | sed 's/^/KERNEL: /'
else
    printf 'KERNEL_LOG=unavailable (%s)\n' "$(head -n 1 "$record/kernel.log")"
fi

printf 'R35_VK_PROBE=%s record=%s\n' "$result" "$record"
[[ $result == PASS ]]

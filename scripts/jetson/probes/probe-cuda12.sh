#!/usr/bin/env bash
# Try CUDA 12 on the Nano's GPU under the 5.10 kernel, from a scratch folder.
#
# Usage: bash probe-cuda12.sh [INPUTS_DIR]
#
# Run as the owner's ordinary account, without sudo, on Ubuntu 26.04
# under the 5.10 kernel, with JetPack 5's driver set and CUDA 11.4 installed
# (install-u26-r35.sh). INPUTS_DIR (default: this script's folder) is what
# scripts/host/fetch-cuda12-probe.py wrote: r36-driver/, cuda12-libs/ and
# compat-12-2/ with NVIDIA's .debs, this script, cuda11_probe.py,
# cuda_libs_probe.py and SHA256SUMS. Each folder's .debs are only unpacked,
# with dpkg-deb -x, into ~/cuda12-probe/<stamp>/root-<folder>; nothing is
# installed, and the system's CUDA 11.4 and driver files are left as they are.
#
# Steps, each logged in the record folder:
#   1. control: cuda11_probe.py on the system's CUDA 11.4 driver and runtime,
#      and cuda_libs_probe.py with its cuBLAS 11 and cuDNN 8.6, which shows
#      the library test itself passing on the Nano;
#   2. compat: NVIDIA's CUDA 12.2 upgrade driver for JetPack 5 (libcuda and
#      its PTX compiler from compat-12-2, the GPU libraries such as
#      libnvrm_gpu from the system's R35.6 set, as NVIDIA ships it):
#      cuda11_probe.py with CUDA 12.2's runtime, then cuda_libs_probe.py with
#      CUDA 12's runtime, cuBLAS and cuDNN 9 from cuda12-libs (a newer CUDA 12
#      runtime on the 12.2 driver);
#   3. r36: JetPack 6's CUDA driver with JetPack 6's own GPU libraries, every
#      NVIDIA library from the scratch folder: the same two tests with
#      cuda12-libs;
#   4. after: step 1's driver test again, to show the system's CUDA still works;
#   5. the kernel's messages since the start, when the account may read them.
# A CUDA 12 driver passes when both its tests pass. The driver's JIT cache is
# off (CUDA_CACHE_DISABLE=1). The unpacked folders (a few GB) are removed at
# the end unless KEEP_ROOT=1; the logs stay. The last line is
# CUDA12_PROBE=PASS (control, after and at least one CUDA 12 driver passed)
# or FAIL, with compat= and r36= saying which driver passed.
set -uo pipefail

KERNEL=5.10.216-tegra
NEED_KIB=$((5 * 1024 * 1024))
FOLDERS=(r36-driver cuda12-libs compat-12-2)

die() { printf 'CUDA12_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
inputs=$(cd "${1:-$here}" 2>/dev/null && pwd) || die "no inputs folder ${1:-}"
[[ $(id -u) -ne 0 ]] || die 'run this as the ordinary account, not with sudo'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for file in cuda11_probe.py cuda_libs_probe.py; do
    [[ -f $here/$file ]] || die "no $file next to this script"
done
probe=$here/cuda11_probe.py
libs_probe=$here/cuda_libs_probe.py
free=$(df -Pk "$HOME" | awk 'NR == 2 {print $4}')
(( free >= NEED_KIB )) || die "needs $((NEED_KIB / 1024 / 1024)) GiB free in $HOME (has $((free / 1024)) MiB)"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$HOME/cuda12-probe/$stamp
mkdir -p "$record" || die "cannot create $record"
exec > >(tee "$record/summary.txt") 2>&1
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\n' "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME"
printf 'ACCOUNT=%s\n' "$(id)"

result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || result=FAIL; }

# --- Inputs, as the PC wrote them.
if (cd "$inputs" && sha256sum --quiet -c SHA256SUMS) > "$record/sha256-check.txt" 2>&1; then
    printf 'INPUTS_SHA256=PASS %s\n' "$inputs"
else
    cat "$record/sha256-check.txt"
    printf 'INPUTS_SHA256=FAIL %s\nCUDA12_PROBE=FAIL record=%s\n' "$inputs" "$record"
    exit 1
fi
(cd "$here" && grep -E '  (probe-cuda12\.sh|cuda11_probe\.py|cuda_libs_probe\.py)$' "$inputs/SHA256SUMS" \
    | sha256sum --quiet -c -) > /dev/null 2>&1 \
    || die 'this script or its probes do not match the inputs SHA256SUMS'
cp "$inputs/SHA256SUMS" "$inputs/packages.json" "$record/" 2>/dev/null

shopt -s nullglob
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
declare -A ROOT DIRS
for folder in "${FOLDERS[@]}"; do
    root=$record/root-$folder
    mkdir -p "$root"
    debs=("$inputs/$folder"/*.deb)
    (( ${#debs[@]} )) || die "no .debs in $inputs/$folder"
    for deb in "${debs[@]}"; do
        printf 'UNPACK=%s/%s\n' "$folder" "$(basename "$deb")"
        dpkg-deb -x "$deb" "$root" || die "dpkg-deb could not unpack $deb"
    done
    # Every folder holding a shared library, with soname links made there only.
    dirs=$(find "$root" -name 'lib*.so*' \( -type f -o -type l \) -printf '%h\n' | sort -u | paste -sd:)
    [[ -n $dirs ]] || die "no libraries in $folder"
    IFS=: read -ra list <<< "$dirs"
    "$ldconfig" -n "${list[@]}" 2>&1 | sed 's/^/LDCONFIG: /'
    ROOT[$folder]=$root
    DIRS[$folder]=$dirs
    printf 'LIBDIRS %s=%s\n' "$folder" "${dirs//$record\//}"
    find "$root" -name 'lib*.so*' -printf '%P -> %l\n' | sort > "$record/libraries-$folder.txt"
done
find_lib() {  # FOLDER PATTERN: the first library there whose name matches
    find "${ROOT[$1]}" -name "$2" \( -type f -o -type l \) | sort | head -n 1
}
compat_cuda=$(find_lib compat-12-2 'libcuda.so.1')
compat_cudart=$(find_lib compat-12-2 'libcudart.so.12')
r36_cuda=$(find_lib r36-driver 'libcuda.so.1')
cudart12=$(find_lib cuda12-libs 'libcudart.so.12')
cublas12=$(find_lib cuda12-libs 'libcublas.so.12')
cudnn9=$(find_lib cuda12-libs 'libcudnn.so.9')
for var in compat_cuda compat_cudart r36_cuda cudart12 cublas12 cudnn9; do
    [[ -n ${!var} ]] || die "no ${var} library among the inputs"
    printf '%s=%s\n' "${var^^}" "${!var#"$record"/}"
done

# --- The GPU's device nodes, as this account sees them.
{
    ls -l /dev/nvhost-ctrl-gpu /dev/nvhost-gpu /dev/nvhost-as-gpu /dev/nvhost-ctrl \
        /dev/nvhost-prof-gpu /dev/nvhost-tsg-gpu /dev/nvmap /dev/host1x-fence
    ls -lR /dev/nvgpu
} > "$record/device-nodes.txt" 2>&1
for node in /dev/nvhost-ctrl-gpu /dev/nvhost-ctrl /dev/nvmap /dev/nvgpu/igpu0/ctrl \
        /dev/nvgpu/igpu0/channel /dev/nvgpu/igpu0/as; do
    if [[ ! -e $node ]]; then state=missing
    elif [[ -r $node && -w $node ]]; then state=read-write
    else state=no-access; fi
    printf 'NODE %s %s\n' "$node" "$state"
done

run_probe() {  # NAME then the environment and probe command
    local name=$1; shift
    env CUDA_CACHE_DISABLE=1 "$@" > "$record/$name.log" 2>&1
    local status=$?
    grep -E '^(LOAD_ERROR|SYMBOL_ERROR|CUDA_INIT|DRIVER_VERSION|DEVICE_NAME|DEVICE_COMPUTE_MAJOR|DEVICE_COMPUTE_MINOR|CONTEXT|DRIVER_MODULE|DRIVER_JIT_ERROR|DRIVER_VECTOR_ADD_1048579|DRIVER_TEST|RUNTIME_VERSION|RUNTIME_DRIVER_VERSION|RUNTIME_DEVICE_NAME|RUNTIME_VECTOR_ADD|RUNTIME_TEST|CUBLAS_VERSION|SGEMM_1024x1024x1024|SGEMM_RATE|CUBLAS_TEST|CUDNN_VERSION|CUDNN_TEST|LIB_MIX|PROBE|LIBS_PROBE)=|=FAIL' \
        "$record/$name.log" | sed "s/^/$name: /"
    printf '%s_EXIT=%s\n' "${name^^}" "$status"
    return "$status"
}
driver_from() {  # LOG DIR: the process mapped its libcuda from DIR
    grep -qE "^LIB=${2//./\\.}/libcuda\.so" "$1"
}

# --- 1. Control: the system's CUDA 11.4, cuBLAS 11 and cuDNN 8.6.
run_probe control timeout -k 10 300 python3 -I "$probe" \
    --driver libcuda.so.1 --runtime libcudart.so.11.0 --expect-driver 11040 --lib-root /usr \
    && check CONTROL PASS || check CONTROL FAIL
run_probe control-libs timeout -k 10 600 python3 -I "$libs_probe" --runtime libcudart.so.11.0 \
    --cublas libcublas.so.11 --cudnn libcudnn.so.8 --lib-root /usr \
    && check CONTROL_LIBS PASS || check CONTROL_LIBS FAIL

# --- 2. Compat: CUDA 12.2's upgrade driver for JetPack 5 on the system's R35.6 GPU libraries.
compat_dir=$(dirname "$compat_cuda")
compat=FAIL
if run_probe compat LD_LIBRARY_PATH="$compat_dir:$(dirname "$compat_cudart")" \
        timeout -k 10 300 python3 -I "$probe" --driver "$compat_cuda" --runtime "$compat_cudart" \
        --expect-driver 12020 && driver_from "$record/compat.log" "$compat_dir"; then
    printf 'COMPAT_DRIVER=PASS\n'
    if run_probe compat-libs LD_LIBRARY_PATH="$compat_dir:${DIRS[cuda12-libs]}" \
            timeout -k 10 600 python3 -I "$libs_probe" --runtime "$cudart12" --cublas "$cublas12" \
            --cudnn "$cudnn9" && driver_from "$record/compat-libs.log" "$compat_dir"; then
        printf 'COMPAT_LIBS=PASS\n'
        compat=PASS
    else
        printf 'COMPAT_LIBS=FAIL\n'
    fi
else
    printf 'COMPAT_DRIVER=FAIL\n'
fi

# --- 3. JetPack 6's CUDA driver and GPU libraries, all from the scratch folder.
r36=FAIL
if run_probe r36 LD_LIBRARY_PATH="${DIRS[r36-driver]}:${DIRS[cuda12-libs]}" \
        timeout -k 10 300 python3 -I "$probe" --driver "$r36_cuda" --runtime "$cudart12" \
        --lib-root "$record"; then
    printf 'R36_DRIVER=PASS\n'
    if run_probe r36-libs LD_LIBRARY_PATH="${DIRS[r36-driver]}:${DIRS[cuda12-libs]}" \
            timeout -k 10 600 python3 -I "$libs_probe" --runtime "$cudart12" --cublas "$cublas12" \
            --cudnn "$cudnn9" --lib-root "$record"; then
        printf 'R36_LIBS=PASS\n'
        r36=PASS
    else
        printf 'R36_LIBS=FAIL\n'
    fi
else
    printf 'R36_DRIVER=FAIL\n'
fi

# --- 4. After: the system's CUDA 11.4 again.
run_probe after timeout -k 10 300 python3 -I "$probe" \
    --driver libcuda.so.1 --runtime libcudart.so.11.0 --expect-driver 11040 --lib-root /usr \
    && check AFTER PASS || check AFTER FAIL

# --- 5. Kernel messages since the start (needs the adm or systemd-journal group).
if journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1 \
        && ! grep -q 'No journal files were opened\|not seeing messages' "$record/kernel.log"; then
    printf 'KERNEL_LOG=read lines=%s\n' "$(wc -l < "$record/kernel.log")"
    grep -iE 'nvgpu|nvmap|smmu|mmu_fault|mc-err|gk20a|gm20b|host1x|syncpt' "$record/kernel.log" \
        | tail -n 40 | sed 's/^/KERNEL: /'
else
    printf 'KERNEL_LOG=unavailable (%s)\n' "$(head -n 1 "$record/kernel.log")"
fi

if [[ ${KEEP_ROOT:-0} != 1 ]]; then
    rm -rf "$record"/root-*
    printf 'ROOTS=removed (KEEP_ROOT=1 keeps them)\n'
fi
[[ $compat == PASS || $r36 == PASS ]] || result=FAIL
printf 'CUDA12_PROBE=%s compat=%s r36=%s record=%s\n' "$result" "$compat" "$r36" "$record"
[[ $result == PASS ]]

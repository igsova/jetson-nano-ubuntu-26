#!/usr/bin/env bash
# Try JetPack 5's CUDA 11.4 driver on the Nano's GPU from a scratch folder.
#
# Usage: bash probe-cuda11.sh [INPUTS_DIR...]
#
# Run as the owner's ordinary account, without sudo, on Ubuntu 26.04
# under the 5.10 kernel. Each INPUTS_DIR (default: this script's folder) is
# what scripts/host/fetch-r35-cuda.py wrote: NVIDIA's L4T R35.6 .debs, this
# script, cuda11_probe.py and SHA256SUMS; give the driver set and, to build
# programs, the toolkit set (--set toolkit). The .debs are only unpacked, with
# dpkg-deb -x, into ~/cuda11-probe/<stamp>; nothing is installed, and the
# system's CUDA 10.2 and JetPack 4 driver files are left as they are.
#
# Steps, each logged in the record folder:
#   1. control: cuda11_probe.py on the system's CUDA 10.2 driver and runtime;
#   2. trial: the same probe on R35.6's libcuda (CUDA 11.4) and CUDA 11.4's
#      runtime, through LD_LIBRARY_PATH, with every NVIDIA library required
#      to come from the scratch folder;
#   3. build (toolkit set only): vector_add.cu and gpu_probe.cu with CUDA
#      11.4's nvcc and GCC 11 (add-u26-gcc11.sh) for sm_53, run on the 11.4
#      driver. Where 26.04's newer glibc headers clash with CUDA 11.4's, the
#      scratch copy of crt/math_functions.h gets noexcept on the named
#      functions (C23 additions glibc 2.41 declares noexcept), and a copy of
#      glibc's bits/math-vector.h in the record hides the AArch64 vector math
#      declarations from nvcc; each is logged as an NVCC_COMPAT line with a
#      diff in the record;
#   4. compat: CUDA 10.2's deviceQuery and vector_add on the 11.4 driver;
#   5. after: the same two on the system's CUDA 10.2 driver, to show the GPU
#      still works for the system's CUDA;
#   6. the kernel's messages since the start, when the account may read them.
# The driver's JIT cache is off (CUDA_CACHE_DISABLE=1), so nothing is written
# outside the record folder. The last line is CUDA11_PROBE=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
SYSTEM_PROBE=/opt/nano-cuda-probe

die() { printf 'CUDA11_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
(( $# )) || set -- "$here"
inputs=()
for dir in "$@"; do
    [[ -d $dir ]] || die "no inputs folder $dir"
    inputs+=("$(cd "$dir" && pwd)")
done
[[ $(id -u) -ne 0 ]] || die 'run this as the ordinary account, not with sudo'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
probe=$here/cuda11_probe.py
[[ -f $probe ]] || die "no cuda11_probe.py next to this script"
find_input() { local dir; for dir in "${inputs[@]}"; do [[ -f $dir/$1 ]] && { echo "$dir/$1"; return 0; }; done; return 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$HOME/cuda11-probe/$stamp
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
        printf 'CUDA11_PROBE=FAIL record=%s\n' "$record"
        exit 1
    fi
    cp "$dir/SHA256SUMS" "$record/SHA256SUMS-$name"
    cp "$dir/packages.json" "$record/packages-$name.json" 2>/dev/null
    debs+=("$dir"/*.deb)
done
(cd "$here" && grep -E '  (probe-cuda11\.sh|cuda11_probe\.py)$' SHA256SUMS | sha256sum --quiet -c -) \
    > /dev/null 2>&1 || die 'this script or cuda11_probe.py does not match the SHA256SUMS next to it'
(( ${#debs[@]} )) || die 'no .debs in the inputs'
for deb in "${debs[@]}"; do
    printf 'UNPACK=%s\n' "$(basename "$deb")"
    dpkg-deb -x "$deb" "$root" || die "dpkg-deb could not unpack $deb"
done
tegra=$root/usr/lib/aarch64-linux-gnu/tegra
cudart=$(find "$root" -name 'libcudart.so.11*' -type f -printf '%h\n' | head -n 1)
[[ -d $tegra ]] || die "no usr/lib/aarch64-linux-gnu/tegra in the R35 packages"
[[ -n $cudart ]] || die 'no libcudart.so.11 in the R35 packages'
# Soname links (libcuda.so.1 and the like), in the scratch folder only.
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
"$ldconfig" -n "$tegra" "$cudart" 2>&1 | sed 's/^/LDCONFIG: /'
ls -l "$tegra" "$cudart" > "$record/libraries.txt"
libcuda=$tegra/libcuda.so.1
[[ -e $libcuda ]] || die 'no libcuda.so.1 after ldconfig -n'
libcudart=$(ls "$cudart"/libcudart.so.11.? 2>/dev/null | head -n 1)
[[ -n $libcudart ]] || libcudart=$(ls "$cudart"/libcudart.so.11* | head -n 1)
printf 'TRIAL_LIBCUDA=%s\nTRIAL_LIBCUDART=%s\n' "$(readlink -f "$libcuda")" "$libcudart"
# libcuda loads its PTX compiler by soname; without R35's own here, the
# system's ld.so.cache hands it JetPack 4's (LIB_MIX then fails).
ptxjit=$tegra/libnvidia-ptxjitcompiler.so.1
if [[ -e $ptxjit ]]; then
    printf 'TRIAL_PTXJIT=%s\n' "$(readlink -f "$ptxjit")"
else
    printf 'TRIAL_PTXJIT=missing (the system copy will be loaded)\n'
fi

# --- The GPU's device nodes, as this account sees them.
{
    ls -l /dev/nvhost-ctrl-gpu /dev/nvhost-gpu /dev/nvhost-as-gpu /dev/nvhost-ctrl \
        /dev/nvhost-prof-gpu /dev/nvhost-tsg-gpu /dev/nvmap
    ls -lR /dev/nvgpu
} > "$record/device-nodes.txt" 2>&1
for node in /dev/nvhost-ctrl-gpu /dev/nvhost-gpu /dev/nvhost-as-gpu /dev/nvmap \
        /dev/nvgpu/igpu0/ctrl /dev/nvgpu/igpu0/channel /dev/nvgpu/igpu0/as; do
    if [[ ! -e $node ]]; then state=missing
    elif [[ -r $node && -w $node ]]; then state=read-write
    else state=no-access; fi
    printf 'NODE %s %s\n' "$node" "$state"
done

run_probe() {  # NAME then the environment and probe arguments
    local name=$1; shift
    env "$@" > "$record/$name.log" 2>&1
    local status=$?
    grep -E '^(LOAD_ERROR|SYMBOL_ERROR|CUDA_INIT|DRIVER_VERSION|DEVICE_NAME|DEVICE_COMPUTE_MAJOR|DEVICE_COMPUTE_MINOR|DEVICE_MEMORY_BYTES|CONTEXT|DRIVER_MODULE|DRIVER_JIT_ERROR|DRIVER_VECTOR_ADD_1048579|DRIVER_TEST|RUNTIME_VERSION|RUNTIME_DRIVER_VERSION|RUNTIME_DEVICE_NAME|RUNTIME_MODULE|RUNTIME_VECTOR_ADD|RUNTIME_TEST|LIB_MIX|PROBE)=|=FAIL' \
        "$record/$name.log" | sed "s/^/$name: /"
    printf '%s_EXIT=%s\n' "${name^^}" "$status"
    return "$status"
}

# --- 1. Control: the system's CUDA 10.2 through the same probe.
run_probe control CUDA_CACHE_DISABLE=1 timeout -k 10 300 python3 -I "$probe" \
    --driver libcuda.so.1 --runtime libcudart.so.10.2 --expect-driver 10020 \
    && check CONTROL PASS || check CONTROL FAIL

# --- 2. Trial: R35.6's CUDA 11.4 driver and runtime from the scratch folder.
run_probe trial CUDA_CACHE_DISABLE=1 LD_LIBRARY_PATH="$tegra:$cudart" \
    timeout -k 10 300 python3 -I "$probe" --driver "$libcuda" --runtime "$libcudart" \
    --expect-driver 11040 --lib-root "$root" \
    && check CUDA11_DRIVER PASS || check CUDA11_DRIVER FAIL

# --- 3. Build with CUDA 11.4's compiler, and run on the 11.4 driver.
nvcc=$root/usr/local/cuda-11.4/bin/nvcc
# glibc 2.41+ declares C23 functions such as sinpi and cospi noexcept; CUDA 11.4's
# extern "C" declarations of them lack it. Only those extern lines are patched: the
# C++ float overloads of the same names (sinpi(const float a)) are not glibc's.
patch_noexcept() {  # NAME: noexcept on its extern declarations in the scratch math_functions.h
    local name=$1 header extern="^[[:space:]]*extern[[:space:]]"
    header=$(find "$root/usr/local/cuda-11.4" -path '*/crt/math_functions.h' | head -n 1)
    [[ -n $header ]] || return 1
    [[ -f $record/math_functions.h.orig ]] || cp "$header" "$record/math_functions.h.orig"
    grep -qE "${extern}.*\b${name}\([^()]*\);" "$header" || return 1
    sed -E -i "/${extern}/ s/\b(${name}\([^()]*\));/\1 noexcept (true);/" "$header"
    printf 'NVCC_COMPAT=noexcept %s (crt/math_functions.h, scratch copy)\n' "$name"
}
# 26.04's glibc declares its AArch64 vector math (libmvec) with GCC's builtin vector
# types (__Float32x4_t, __SVFloat32_t, __SVBool_t), which CUDA 11.4's front end does not
# know. A copy of bits/math-vector.h in the record, first on nvcc's system include path,
# leaves those declarations out under __CUDACC__; device code never calls them.
math_vector_h() {  # the bits/math-vector.h that g++ reads for <math.h>
    "$cxx" -x c++ -E -o "$record/math-h.ii" - <<< '#include <math.h>' 2> /dev/null \
        && sed -n 's|^# [0-9]* "\(/[^"]*/bits/math-vector\.h\)".*|\1|p;T;q' "$record/math-h.ii"
    rm -f "$record/math-h.ii"
}
fix_math_vector() {
    local system fixed=$record/include-fix/bits/math-vector.h
    [[ ! -e $fixed ]] || return 1
    system=$(math_vector_h)
    [[ -n $system && -f $system ]] || return 1
    mkdir -p "${fixed%/*}"
    # "#if X" or "#elif X" just before "# define __ADVSIMD_VEC_MATH_SUPPORTED" or
    # "# define __SVE_VEC_MATH_SUPPORTED" becomes "#if (X) && !defined __CUDACC__".
    awk 'NR > 1 && /^#[ \t]*define[ \t]+__(ADVSIMD|SVE)_VEC_MATH_SUPPORTED/ && prev ~ /^#[ \t]*(el)?if[ \t]/ {
             match(prev, /^#[ \t]*(el)?if[ \t]+/)
             prev = substr(prev, 1, RLENGTH) "(" substr(prev, RLENGTH + 1) ") && !defined __CUDACC__"
             n++
         }
         NR > 1 { print prev }
         { prev = $0 }
         END { if (NR) print prev; exit n ? 0 : 1 }' "$system" > "$fixed" \
        || { rm -rf "$record/include-fix"; return 1; }
    diff -u "$system" "$fixed" > "$record/math-vector.diff"
    nvflags+=(-isystem "$record/include-fix")
    printf 'NVCC_COMPAT=math-vector.h without vector math under __CUDACC__ (%s, scratch copy)\n' "$system"
}
build() {  # NAME SOURCE
    local name=$1 source=$2 attempt log names name_ remedy
    for attempt in 1 2 3 4; do
        log=$record/build-$name-$attempt.log
        LC_ALL=C "$nvcc" "${nvflags[@]}" "$source" -o "$bin/$name" > "$log" 2>&1 && return 0
        remedy=0
        if grep -q 'unsupported GNU version' "$log" && [[ " ${nvflags[*]} " != *' -allow-unsupported-compiler '* ]]; then
            nvflags+=(-allow-unsupported-compiler)
            printf 'NVCC_COMPAT=-allow-unsupported-compiler\n'
            remedy=1
        fi
        names=$( { grep -o 'incompatible with that of previous function "[A-Za-z0-9_]*"' "$log" \
                       | sed 's/.*"\(.*\)"/\1/'
                   grep -oE "declaration of '[^']*' has a different exception specifier" "$log" \
                       | sed -E "s/^declaration of '[^(']* ([A-Za-z0-9_]+)\(.*/\1/"; } | sort -u)
        for name_ in $names; do
            patch_noexcept "$name_" && remedy=1
        done
        if grep -qE 'bits/math-vector\.h\([0-9]+\): error: identifier "__[A-Za-z0-9]+_t" is undefined' "$log"; then
            fix_math_vector && remedy=1
        fi
        (( remedy )) || break
    done
    grep -m 5 -E 'error|Error' "$log" | sed "s/^/BUILD_ERROR $name: /"
    return 1
}
if [[ -x $nvcc ]]; then
    "$nvcc" --version > "$record/nvcc-version.txt" 2>&1
    printf 'NVCC=%s\n' "$(grep -o 'release [0-9.]*, V[0-9.]*' "$record/nvcc-version.txt")"
    cxx=$(command -v g++-11)
    bin=$record/bin
    mkdir -p "$bin"
    if [[ -z $cxx ]]; then
        check CUDA11_BUILD 'FAIL (no g++-11; run add-u26-gcc11.sh with sudo first)'
    else
        printf 'HOST_CXX=%s\n' "$("$cxx" --version | head -n 1)"
        nvflags=(-ccbin "$cxx" -std=c++11 -O2 -arch=sm_53 --cudart shared)
        for program in vector_add gpu_probe; do
            source=$(find_input "$program.cu") || { check "CUDA11_BUILD_${program^^}" 'FAIL (no source)'; continue; }
            if build "$program" "$source"; then
                check "CUDA11_BUILD_${program^^}" PASS
            else
                check "CUDA11_BUILD_${program^^}" FAIL
                continue
            fi
            LD_LIBRARY_PATH="$tegra:$cudart" ldd "$bin/$program" > "$record/ldd-$program.txt" 2>&1
            grep -q "libcudart.so.11.0 => $cudart/" "$record/ldd-$program.txt" \
                && check "CUDA11_LINK_${program^^}" PASS || check "CUDA11_LINK_${program^^}" FAIL
            env CUDA_CACHE_DISABLE=1 LD_LIBRARY_PATH="$tegra:$cudart" timeout -k 10 300 \
                "$bin/$program" > "$record/run-$program.log" 2>&1
            printf '%s_EXIT=%s\n' "${program^^}" "$?"
            grep -E '^(device=|gpu memory|PASS count|FAIL|PROBE=|RESULT=)' "$record/run-$program.log" \
                | tail -n 4 | sed "s/^/$program: /"
        done
        [[ -f $record/math_functions.h.orig ]] && diff -u "$record/math_functions.h.orig" \
            "$(find "$root/usr/local/cuda-11.4" -path '*/crt/math_functions.h' | head -n 1)" \
            > "$record/math_functions.diff"
        grep -qx 'RESULT=PASS' "$record/run-vector_add.log" 2>/dev/null \
            && check CUDA11_RUN_VECTOR_ADD PASS || check CUDA11_RUN_VECTOR_ADD FAIL
        grep -qx 'PROBE=PASS' "$record/run-gpu_probe.log" 2>/dev/null \
            && check CUDA11_RUN_GPU_PROBE PASS || check CUDA11_RUN_GPU_PROBE FAIL
        built=("$bin"/*)  # nullglob: empty when nothing built (sha256sum would read the terminal)
        (( ${#built[@]} == 0 )) || sha256sum "${built[@]}" > "$record/bin-sha256.txt"
    fi
else
    printf 'CUDA11_BUILD=skipped (no toolkit set among the inputs)\n'
fi

# --- 4. Compat: CUDA 10.2 programs on the 11.4 driver.
env CUDA_CACHE_DISABLE=1 LD_LIBRARY_PATH="$tegra:$cudart" LD_DEBUG=libs timeout -k 10 120 \
    "$SYSTEM_PROBE/vector_add" > "$record/compat-vector_add.log" 2>&1
grep -E '^device=' "$record/compat-vector_add.log" | sed 's/^/compat vector_add: /'
grep -qx 'RESULT=PASS' "$record/compat-vector_add.log" \
    && grep -q 'driver=11040 runtime=10020' "$record/compat-vector_add.log" \
    && grep -q "calling init: $tegra/libcuda.so.1" "$record/compat-vector_add.log" \
    && check COMPAT_VECTOR_ADD PASS || check COMPAT_VECTOR_ADD FAIL
env CUDA_CACHE_DISABLE=1 LD_LIBRARY_PATH="$tegra:$cudart" timeout -k 10 120 \
    "$SYSTEM_PROBE/deviceQuery" > "$record/compat-deviceQuery.log" 2>&1
grep -E 'Driver Version / Runtime|Result =' "$record/compat-deviceQuery.log" | sed 's/^ */compat deviceQuery: /'
grep -q 'Result = PASS' "$record/compat-deviceQuery.log" \
    && check COMPAT_DEVICEQUERY PASS || check COMPAT_DEVICEQUERY FAIL

# --- 5. After: the system's CUDA 10.2 programs.
timeout -k 10 120 "$SYSTEM_PROBE/deviceQuery" > "$record/after-deviceQuery.log" 2>&1
grep -q 'Result = PASS' "$record/after-deviceQuery.log" \
    && check AFTER_DEVICEQUERY PASS || check AFTER_DEVICEQUERY FAIL
timeout -k 10 120 "$SYSTEM_PROBE/vector_add" > "$record/after-vector_add.log" 2>&1
grep -qx 'RESULT=PASS' "$record/after-vector_add.log" \
    && check AFTER_VECTOR_ADD PASS || check AFTER_VECTOR_ADD FAIL

# --- 6. Kernel messages since the start (needs the adm or systemd-journal group).
if journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1 \
        && ! grep -q 'No journal files were opened\|not seeing messages' "$record/kernel.log"; then
    printf 'KERNEL_LOG=read lines=%s\n' "$(wc -l < "$record/kernel.log")"
    grep -iE 'nvgpu|nvmap|smmu|mmu_fault|mc-err|gk20a|gm20b' "$record/kernel.log" \
        | tail -n 40 | sed 's/^/KERNEL: /'
else
    printf 'KERNEL_LOG=unavailable (%s)\n' "$(head -n 1 "$record/kernel.log")"
fi

printf 'CUDA11_PROBE=%s record=%s\n' "$result" "$record"
[[ $result == PASS ]]

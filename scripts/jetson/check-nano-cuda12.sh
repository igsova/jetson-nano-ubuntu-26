#!/usr/bin/env bash
# Check CUDA 12 as nano-cuda12 and nano-cuda12-dev installed it, beside the system's CUDA 11.4.
#
# Usage: bash check-nano-cuda12.sh
#
# Run as the owner's ordinary account, without sudo (install-nano-cuda12.sh
# runs it after installing), on Ubuntu 26.04 under the 5.10 kernel.
# The test files (cuda11_probe.py, cuda_libs_probe.py, vector_add.cu,
# gpu_probe.cu, cuda12_dev_check.cu) are next to this script. Steps, each
# logged in the record folder:
#   1. system: /usr/local/cuda is still CUDA 11.4's and the library path
#      holds no CUDA 12 or cuDNN 9 library; control: cuda11_probe.py and
#      cuda_libs_probe.py on the system's CUDA 11.4, cuBLAS 11 and cuDNN 8.6;
#   2. links: every library and program of the two packages finds every
#      library it links, under nano-cuda12 (ldd);
#   3. driver: cuda11_probe.py through nano-cuda12, with libcuda from
#      /usr/local/cuda-12.2/compat (driver 12020) and CUDA 12.6's runtime;
#   4. libraries: cuda_libs_probe.py through nano-cuda12, cuBLAS 12 and cuDNN
#      9 from CUDA 12.6's folder;
#   5. compiler: nvcc 12.6 with g++-11 builds, for sm_53, vector_add.cu (with
#      CUDA's runtime linked statically, nvcc's default), gpu_probe.cu
#      (shared) and cuda12_dev_check.cu (cuBLAS and cuDNN through their
#      headers and -l names); each is checked to hold sm_53 machine code and
#      run through nano-cuda12; two of them are also run without it, to show
#      that programs started any other way do not get CUDA 12; and
#      vector_add.cu is built once without each of the package's two glibc
#      changes, to record whether each is needed (NVCC_FIX lines, which do
#      not decide the result);
#   6. after: step 1's driver test again;
#   7. the kernel's messages since the start, when the account may read them.
# GPU_CLOCK lines give the GPU's clock before each timed run, since the
# SGEMM rates depend on it. The driver's JIT cache is off
# (CUDA_CACHE_DISABLE=1). The record goes to ~/nano-cuda12-check/<stamp>;
# the last line is NANO_CUDA12_CHECK=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
LAUNCHER=/usr/bin/nano-cuda12
COMPAT=/usr/local/cuda-12.2/compat
CUDA12_NAMES='lib(cudart\.so\.12|cublas(Lt)?\.so\.12|cudnn[a-z_]*\.so\.9|nvrtc\.so\.12|nvJitLink\.so\.12)'

die() { printf 'NANO_CUDA12_CHECK=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
[[ $(id -u) -ne 0 ]] || die 'run this as the ordinary account, not with sudo'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for file in cuda11_probe.py cuda_libs_probe.py vector_add.cu gpu_probe.cu cuda12_dev_check.cu; do
    [[ -f $here/$file ]] || die "no $file next to this script"
done
[[ -x $LAUNCHER ]] || die "no $LAUNCHER (install nano-cuda12 first)"
cuda=$(sed -n 's/^cuda=//p' "$LAUNCHER")
[[ $cuda == /usr/local/cuda-12.* && -d $cuda ]] || die "$LAUNCHER names no CUDA 12 folder"
minor=${cuda##*.}
probe=$here/cuda11_probe.py
libs_probe=$here/cuda_libs_probe.py

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$HOME/nano-cuda12-check/$stamp
mkdir -p "$record" || die "cannot create $record"
exec > >(tee "$record/summary.txt") 2>&1
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\nACCOUNT=%s\n' "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME" "$(id)"
dpkg-query -W -f '${Package} ${Version}\n' nano-cuda12 nano-cuda12-dev nano-l4t-core nano-l4t-cuda 2>&1 \
    | sed 's/^/PACKAGE /'
printf 'CUDA12=%s\n' "$cuda"

result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS* ]] || result=FAIL; }
gpu_clock() {  # LABEL: the GPU's current clock and its range, where the account may read them
    local dir
    for dir in /sys/class/devfreq/*gpu* /sys/class/devfreq/57000000.*; do
        [[ -r $dir/cur_freq ]] || continue
        printf 'GPU_CLOCK %s cur=%s min=%s max=%s governor=%s\n' "$1" "$(cat "$dir/cur_freq")" \
            "$(cat "$dir/min_freq" 2> /dev/null)" "$(cat "$dir/max_freq" 2> /dev/null)" \
            "$(cat "$dir/governor" 2> /dev/null)"
        return
    done
    printf 'GPU_CLOCK %s unreadable\n' "$1"
}
run_probe() {  # NAME then the command
    local name=$1; shift
    env CUDA_CACHE_DISABLE=1 "$@" > "$record/$name.log" 2>&1
    local status=$?
    grep -E '^(LOAD_ERROR|SYMBOL_ERROR|CUDA_INIT|DRIVER_VERSION|DEVICE_NAME|DRIVER_VECTOR_ADD_1048579|DRIVER_TEST|RUNTIME_VERSION|RUNTIME_DRIVER_VERSION|RUNTIME_VECTOR_ADD|RUNTIME_TEST|CUBLAS_VERSION|SGEMM_1024x1024x1024|SGEMM_RATE|CUBLAS_TEST|CUDNN_VERSION|CUDNN_TEST|LIB_MIX|PROBE|LIBS_PROBE)=|=FAIL' \
        "$record/$name.log" | sed "s/^/$name: /"
    printf '%s_EXIT=%s\n' "${name^^}" "$status"
    return "$status"
}
loaded_from() {  # LOG LIBRARY DIR: the process mapped LIBRARY from DIR
    grep -qE "^LIB=${3//./\\.}/${2//./\\.}" "$1"
}

# --- 1. The system's CUDA 11.4, unchanged.
usr_local_cuda=$(readlink -f /usr/local/cuda 2> /dev/null)
printf 'USR_LOCAL_CUDA=%s\n' "${usr_local_cuda:-none}"
[[ $usr_local_cuda == /usr/local/cuda-11.4 ]] && check SYSTEM_CUDA PASS || check SYSTEM_CUDA FAIL
ldconfig -p > "$record/ldconfig.txt" 2>&1 || /usr/sbin/ldconfig -p > "$record/ldconfig.txt" 2>&1
if grep -E "$CUDA12_NAMES" "$record/ldconfig.txt" | sed 's/^[[:space:]]*/IN_LIBRARY_PATH: /' | grep .; then
    check SYSTEM_PATH FAIL
else
    check SYSTEM_PATH PASS
fi
run_probe control timeout -k 10 300 python3 -I "$probe" \
    --driver libcuda.so.1 --runtime libcudart.so.11.0 --expect-driver 11040 --lib-root /usr \
    && check CONTROL PASS || check CONTROL FAIL
gpu_clock control-libs
# cuDNN 8.6, CUDA 11.4's, through nano-trt85 once nano-trt82 makes JetPack 4's
# cuDNN 8.2 the default (2026-10-19).
trt85=()
[[ -x /usr/bin/nano-trt85 ]] && trt85=(/usr/bin/nano-trt85) && printf 'CONTROL_LIBS_THROUGH=nano-trt85\n'
run_probe control-libs timeout -k 10 600 "${trt85[@]}" python3 -I "$libs_probe" --runtime libcudart.so.11.0 \
    --cublas libcublas.so.11 --cudnn libcudnn.so.8 --lib-root /usr \
    && check CONTROL_LIBS PASS || check CONTROL_LIBS FAIL

# --- 2. Every library and program of the packages finds what it links.
missing=0 checked=0
while IFS= read -r path; do
    [[ -f $path && ! -L $path && $path != */stubs/* ]] || continue
    [[ $(head -c 4 "$path" | od -An -tx1 | tr -d ' \n') == 7f454c46 ]] || continue
    # Only arm64 ELF files the loader can read: GPU code (EM_CUDA) is not for ldd.
    [[ $(od -An -tx1 -j 18 -N 2 "$path" | tr -d ' \n') == b700 ]] || continue
    checked=$((checked + 1))
    out=$("$LAUNCHER" ldd "$path" 2>&1)
    grep -q 'not a dynamic executable\|statically linked' <<< "$out" && continue
    if grep -q 'not found' <<< "$out"; then
        grep 'not found' <<< "$out" | sed "s|^[[:space:]]*|NOT_FOUND ${path}: |"
        missing=$((missing + 1))
    fi
done < <(dpkg -L nano-cuda12 nano-cuda12-dev 2> /dev/null | sort -u)
printf 'LINKS checked=%s missing=%s\n' "$checked" "$missing"
(( checked > 0 && missing == 0 )) && check LINKS PASS || check LINKS FAIL

# --- 3. The 12.2 driver and CUDA 12's runtime, through the launcher.
expect_runtime=$((12000 + minor * 10))
if run_probe driver timeout -k 10 300 "$LAUNCHER" python3 -I "$probe" --driver libcuda.so.1 \
        --runtime libcudart.so.12 --expect-driver 12020 --lib-root /usr \
        && loaded_from "$record/driver.log" libcuda.so "$COMPAT" \
        && loaded_from "$record/driver.log" libcudart.so "$cuda/targets/aarch64-linux/lib" \
        && grep -qx "RUNTIME_VERSION=$expect_runtime" "$record/driver.log"; then
    check CUDA12_DRIVER PASS
else
    check CUDA12_DRIVER FAIL
fi

# --- 4. cuBLAS 12 and cuDNN 9, through the launcher.
gpu_clock libs
if run_probe libs timeout -k 10 600 "$LAUNCHER" python3 -I "$libs_probe" --runtime libcudart.so.12 \
        --cublas libcublas.so.12 --cudnn libcudnn.so.9 --lib-root /usr \
        && loaded_from "$record/libs.log" libcuda.so "$COMPAT" \
        && loaded_from "$record/libs.log" libcublas.so "$cuda/targets/aarch64-linux/lib" \
        && loaded_from "$record/libs.log" libcudnn.so "$cuda/targets/aarch64-linux/lib"; then
    check CUDA12_LIBS PASS
else
    check CUDA12_LIBS FAIL
fi

# --- 5. The compiler.
nvcc=$cuda/bin/nvcc
bin=$record/bin
mkdir -p "$bin"
cxx=$(command -v g++-11)
if [[ ! -x $nvcc ]]; then
    check CUDA12_BUILD 'FAIL (no nvcc; is nano-cuda12-dev installed?)'
elif [[ -z $cxx ]]; then
    check CUDA12_BUILD 'FAIL (no g++-11, which nvcc 12 needs: add-u26-gcc11.sh installs it)'
else
    "$LAUNCHER" nvcc --version > "$record/nvcc-version.txt" 2>&1
    printf 'NVCC=%s\n' "$(grep -o 'release [0-9.]*, V[0-9.]*' "$record/nvcc-version.txt")"
    printf 'HOST_CXX=%s\n' "$("$cxx" --version | head -n 1)"
    build() {  # NAME SOURCE then extra nvcc arguments: builds bin/NAME
        local name=$1 source=$2; shift 2
        (cd "$bin" && LC_ALL=C "$LAUNCHER" nvcc -ccbin "$cxx" -O2 -arch=sm_53 -o "$bin/$name" "$here/$source" "$@") \
            > "$record/build-$name.log" 2>&1
    }
    sass() {  # NAME: the GPU code in bin/NAME
        if [[ -x $cuda/bin/cuobjdump ]]; then
            "$LAUNCHER" cuobjdump --list-elf "$bin/$1" 2>&1 | grep -oE 'sm_[0-9]+' | sort -u | paste -sd ' '
        else
            echo 'no cuobjdump'
        fi
    }
    declare -A EXPECT=([vector_add]='RESULT=PASS' [gpu_probe]='PROBE=PASS' [cuda12_dev_check]='RESULT=PASS')
    declare -A ARGS=([vector_add]='' [gpu_probe]='--cudart shared' [cuda12_dev_check]='--cudart shared -lcublas -lcudnn')
    for program in vector_add gpu_probe cuda12_dev_check; do
        tag=${program^^}
        # shellcheck disable=SC2086  # ARGS holds separate words
        if build "$program" "$program.cu" ${ARGS[$program]}; then
            check "CUDA12_BUILD_$tag" PASS
        else
            grep -m 5 -E 'error|Error' "$record/build-$program.log" | sed "s/^/BUILD_ERROR $program: /"
            check "CUDA12_BUILD_$tag" FAIL
            continue
        fi
        grep -iq warning "$record/build-$program.log" \
            && grep -m 3 -i warning "$record/build-$program.log" | sed "s/^/BUILD_WARNING $program: /"
        found=$(sass "$program")
        printf 'SASS %s: %s\n' "$program" "$found"
        [[ " $found " == *' sm_53 '* || $found == 'no cuobjdump' ]] && check "CUDA12_SASS_$tag" PASS \
            || check "CUDA12_SASS_$tag" FAIL
        env CUDA_CACHE_DISABLE=1 timeout -k 10 300 "$LAUNCHER" "$bin/$program" > "$record/run-$program.log" 2>&1
        printf '%s_EXIT=%s\n' "$tag" "$?"
        grep -E '^(device=|driver=|gpu memory|KERNEL=|CUBLAS=|CUDNN=|FAIL|PROBE=|RESULT=)' "$record/run-$program.log" \
            | tail -n 6 | sed "s/^/$program: /"
        grep -qx "${EXPECT[$program]}" "$record/run-$program.log" && check "CUDA12_RUN_$tag" PASS \
            || check "CUDA12_RUN_$tag" FAIL
    done
    grep -qE "^device=.* driver=12020 runtime=$expect_runtime\$" "$record/run-vector_add.log" 2> /dev/null \
        && check CUDA12_VERSIONS PASS || check CUDA12_VERSIONS FAIL
    # Without the launcher: the static build meets the system's 11.4 driver, and
    # the shared one cannot find CUDA 12's runtime.
    if [[ -x $bin/vector_add ]]; then
        env CUDA_CACHE_DISABLE=1 timeout -k 10 120 "$bin/vector_add" > "$record/plain-vector_add.log" 2>&1
        printf 'ISOLATION vector_add (static runtime) without nano-cuda12: exit %s, %s\n' "$?" \
            "$(grep -m 1 -E 'FAIL|RESULT=' "$record/plain-vector_add.log")"
    fi
    if [[ -x $bin/gpu_probe ]]; then
        env CUDA_CACHE_DISABLE=1 timeout -k 10 120 "$bin/gpu_probe" > "$record/plain-gpu_probe.log" 2>&1
        printf 'ISOLATION gpu_probe (shared runtime) without nano-cuda12: exit %s, %s\n' "$?" \
            "$(grep -m 1 -E 'libcudart|FAIL|PROBE=' "$record/plain-gpu_probe.log")"
    fi
    # Whether each glibc change is needed: vector_add.cu without it.
    for fix in ORIGINAL_MATH:noexcept GLIBC_VECTOR_MATH:math-vector; do
        macro=NANO_CUDA12_${fix%%:*}
        if build "without-${fix#*:}" vector_add.cu "-D$macro"; then
            printf 'NVCC_FIX %s=not needed (vector_add.cu builds with -D%s)\n' "${fix#*:}" "$macro"
        else
            printf 'NVCC_FIX %s=needed (vector_add.cu fails with -D%s: %s)\n' "${fix#*:}" "$macro" \
                "$(grep -m 1 -E 'error' "$record/build-without-${fix#*:}.log" | cut -c 1-200)"
        fi
    done
    built=("$bin"/*)
    [[ -e ${built[0]} ]] && sha256sum "${built[@]}" > "$record/bin-sha256.txt"
fi

# --- 6. After: the system's CUDA 11.4 again.
run_probe after timeout -k 10 300 python3 -I "$probe" \
    --driver libcuda.so.1 --runtime libcudart.so.11.0 --expect-driver 11040 --lib-root /usr \
    && check AFTER PASS || check AFTER FAIL

# --- 7. Kernel messages since the start (needs the adm or systemd-journal group).
if journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1 \
        && ! grep -q 'No journal files were opened\|not seeing messages' "$record/kernel.log"; then
    printf 'KERNEL_LOG=read lines=%s\n' "$(wc -l < "$record/kernel.log")"
    grep -iE 'nvgpu|nvmap|smmu|mmu_fault|mc-err|gk20a|gm20b|host1x|syncpt' "$record/kernel.log" \
        | tail -n 40 | sed 's/^/KERNEL: /'
else
    printf 'KERNEL_LOG=unavailable (%s)\n' "$(head -n 1 "$record/kernel.log")"
fi

printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
printf 'NANO_CUDA12_CHECK=%s record=%s\n' "$result" "$record"
[[ $result == PASS ]]

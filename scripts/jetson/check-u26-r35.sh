#!/usr/bin/env bash
# Check JetPack 5's GPU stack as installed in Ubuntu 26.04.
#
# Usage, as your own account (no sudo), from the folder it was delivered in:
#   bash check-u26-r35.sh
#
# Ubuntu 26.04 under the 5.10 kernel, after install-u26-r35.sh (which
# also runs this). Uses only what is installed, with the test files beside
# this script (checked against the SHA256SUMS there), and writes a record to
# ~/u26-r35-check/<stamp>:
#   1. packages: nano-l4t-* at 35.6.5, CUDA 11.4's runtime, cuDNN 8.6 and
#      TensorRT 8.5 installed, no CUDA 10.2 package left;
#   2. the GPU's device nodes: owner, group and mode as the udev rules set
#      them, and read-write for this account where the video group allows it;
#   3. libraries: what the dynamic linker finds for CUDA, cuDNN, TensorRT, EGL,
#      GLX and Vulkan, and trtexec's and TensorRT's libraries all resolving;
#   4. CUDA 11.4's driver and runtime (cuda11_probe.py), EGL and OpenGL ES with
#      CUDA in the same process (egl_probe.py) and Vulkan compute
#      (vk_probe.py), every NVIDIA library from /usr and none from JetPack 4;
#   5. TensorRT: tiny_cnn.onnx built in FP32 and FP16 by trtexec, its answers
#      checked against expected.json;
#      once nano-trt82 makes JetPack 4's TensorRT 8.2 and cuDNN 8.2 the default
#      (2026-10-19), TensorRT 8.5's and cuDNN 8.6's steps run through
#      nano-trt85, and CUDA 10.2's runtime may be in the library path in
#      nano-trt82's folder only;
#   6. when this account has a desktop session on :0: glxinfo -B, direct
#      rendering by NVIDIA 35.6.5 (otherwise skipped);
#   7. the kernel's GPU messages since the start.
# The last line is U26_R35_CHECK=PASS or U26_R35_CHECK=FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
NANO_L4T=35.6.5-20260701022834+u26.1
RELEASE=35.6.5
TRTEXEC=/usr/src/tensorrt/bin/trtexec
RUN_SECONDS=900
LIBDIR=/usr/lib/aarch64-linux-gnu
CUDA_LIB='/usr/local/cuda(-11(\.4)?)?/targets/aarch64-linux/lib'
FILES=(check-u26-r35.sh cuda11_probe.py egl_probe.py vk_probe.py trt_check.py tiny_cnn.onnx expected.json)

die() { printf 'U26_R35_CHECK=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
[[ $(id -u) -ne 0 ]] || die 'run this as your own account, without sudo'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for file in "${FILES[@]}"; do
    (cd "$here" && grep -E "  ${file//./\\.}\$" SHA256SUMS | sha256sum --quiet -c -) > /dev/null 2>&1 \
        || die "$file does not match the SHA256SUMS next to this script"
done
for tool in python3 dpkg-query ldd timeout; do command -v "$tool" > /dev/null || die "no $tool"; done
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)

stamp=$(date -u +%Y%m%dT%H%M%SZ)
parent=$HOME/u26-r35-check
record=$parent/$stamp
mkdir -p "$parent" && mkdir "$record" || die "cannot create a new record folder $record"
exec 3>&1 4>&2
exec > >(tee "$record/summary.txt") 2>&1
tee_pid=$!
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\nACCOUNT=%s\n' \
    "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME" "$(id)"

result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS* ]] || result=FAIL; }
finish() {
    rm -f "$record"/*.engine
    printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
    printf 'U26_R35_CHECK=%s record=%s\n' "$result" "$record"
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    [[ $result == PASS ]] && exit 0
    exit 1
}
trap 'printf "INTERRUPTED\n"; result=FAIL; finish' INT TERM

# --- 1. Packages.
dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' > "$record/packages.txt" 2>&1
version_of() { awk -v p="$1" '$1 ~ /^.i/ && $2 == p { print $3 }' "$record/packages.txt"; }
bad=()
for pkg in nano-l4t-core nano-l4t-cuda nano-l4t-gl nano-l4t-x11 nano-l4t-power; do
    [[ $(version_of "$pkg") == "$NANO_L4T" ]] || bad+=("$pkg=$(version_of "$pkg")")
done
for spec in cuda-libraries-11-4=11.4.* cuda-cudart-11-4=11.4.* libcudnn8=8.6.* libnvinfer8=8.5.2-* \
        libnvinfer-plugin8=8.5.2-* libnvonnxparsers8=8.5.2-* libnvinfer-bin=8.5.2-* libcudla-11-4=11.4.*; do
    # shellcheck disable=SC2053  # the right side is a pattern
    [[ $(version_of "${spec%%=*}") == ${spec#*=} ]] || bad+=("${spec%%=*}=$(version_of "${spec%%=*}")")
done
old=$(awk '$1 ~ /^.i/ && $2 ~ /(-10-2$|^libcublas10$)/ { print $2 }' "$record/packages.txt" | tr '\n' ' ')
[[ -z $old ]] || bad+=("CUDA 10.2 left: $old")
[[ ! -e /usr/local/cuda-10.2 ]] || bad+=('/usr/local/cuda-10.2 exists')
grep -E ' (nano-l4t-[a-z0-9]+|cuda-(cudart|libraries)-11-4|libcudnn8|libnvinfer8|libnvinfer-bin|nano-trt82) ' \
    "$record/packages.txt" | sed 's/^/PACKAGE /'
(( ${#bad[@]} == 0 )) && check PACKAGES PASS || check PACKAGES "FAIL ${bad[*]}"
trt85=()  # what runs TensorRT 8.5 and cuDNN 8.6 when nano-trt82's 8.2 is the default
if [[ -n $(version_of nano-trt82) ]]; then
    trt85=(/usr/bin/nano-trt85)
    printf 'NANO_TRT82=%s: TensorRT 8.5 and cuDNN 8.6 through nano-trt85\n' "$(version_of nano-trt82)"
fi

# --- 2. The GPU's device nodes, as udev sets them.
node_ok=1
node() {  # NODE OWNER:GROUP MODE WANT_ACCESS(yes/no)
    local state
    if [[ ! -e $1 ]]; then state=missing
    elif [[ -r $1 && -w $1 ]]; then state=read-write  # bash's test; 26.04's uutils test misreads groups
    else state=no-access; fi
    local now
    now=$(stat -c '%U:%G %a' "$1" 2> /dev/null)
    printf 'NODE %s %s %s\n' "$1" "$state" "$now"
    [[ $now == "$2 $3" && ( $4 == no || $state == read-write ) ]] || node_ok=0
}
for name in power ctrl as channel tsg; do node "/dev/nvgpu/igpu0/$name" root:video 660 yes; done
node /dev/nvgpu/igpu0/nvsched root:video 640 no
node /dev/nvgpu/igpu0/sched root:root 660 no
for name in nvhost-ctrl nvhost-ctrl-gpu nvhost-gpu nvhost-as-gpu nvmap; do node "/dev/$name" root:video 660 yes; done
node /dev/tegra_dc_ctrl root:video 660 yes  # NVIDIA's Vulkan driver opens it, and crashes without it
(( node_ok )) && check NODES PASS || check NODES FAIL

# --- 3. Libraries.
"$ldconfig" -p > "$record/ldconfig.txt" 2>&1
resolves() {  # SONAME PATH_REGEX
    grep -qE "^[[:space:]]$1 \(libc6,AArch64\) => $2/$1\$" "$record/ldconfig.txt"
}
bad=()
resolves 'libcuda\.so\.1' "$LIBDIR/tegra" || bad+=(libcuda.so.1)
resolves 'libGLX_nvidia\.so\.0' "$LIBDIR/tegra" || bad+=(libGLX_nvidia.so.0)
resolves 'libEGL_nvidia\.so\.0' "$LIBDIR/tegra-egl" || bad+=(libEGL_nvidia.so.0)
for soname in 'libcudart\.so\.11\.0' 'libcublas\.so\.11' 'libcublasLt\.so\.11' 'libcudla\.so\.1' 'libnvrtc\.so\.11\.2'; do
    resolves "$soname" "$CUDA_LIB" || bad+=("${soname//\\/}")
done
for soname in 'libcudnn\.so\.8' 'libnvinfer\.so\.8' 'libnvinfer_plugin\.so\.8' 'libnvonnxparser\.so\.8'; do
    resolves "$soname" "$LIBDIR" || bad+=("${soname//\\/}")
done
! grep -E 'libcudart\.so\.10|\.so\.32\.7\.6' "$record/ldconfig.txt" | grep -qvF "$LIBDIR/nano-trt82/lib/" \
    || bad+=('a JetPack 4 library is still known')
[[ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]] || bad+=('no Vulkan manifest')
(( ${#bad[@]} == 0 )) && check LIBRARY_PATHS PASS || check LIBRARY_PATHS "FAIL ${bad[*]}"
# What trtexec, CUDA 11.4's, cuDNN's and TensorRT's libraries and the driver
# libraries programs open link must resolve; the rest of the tegra folders'
# libraries (for Xavier and Orin hardware among them) are only reported.
unresolved=0
: > "$record/ldd.txt"
while IFS= read -r file; do
    printf '## %s\n' "$file" >> "$record/ldd.txt"
    "${trt85[@]}" ldd "$file" >> "$record/ldd.txt" 2>&1
    while read -r lib _; do
        if [[ $file =~ ^$LIBDIR/tegra(-egl)?/ && ! ${file##*/} =~ ^(libcuda\.so|libGLX_nvidia|libEGL_nvidia|libGLESv[12]|libnvidia-(glcore|eglcore|glsi|glvkspirv|ptxjitcompiler)|libnvdla_(runtime|compiler)) ]]; then
            printf 'UNRESOLVED_UNUSED %s (needed by %s)\n' "$lib" "$file"
        else
            printf 'UNRESOLVED %s (needed by %s)\n' "$lib" "$file"; unresolved=$(( unresolved + 1 ))
        fi
    done < <("${trt85[@]}" ldd "$file" 2>&1 | grep 'not found')
done < <({ printf '%s\n' "$TRTEXEC"
           find "$LIBDIR" -maxdepth 1 -type f \( -name 'libnvinfer*.so.*' -o -name 'libnvonnxparser*.so.*' \
               -o -name 'libnvparsers*.so.*' -o -name 'libcudnn*.so.*' \)
           find /usr/local/cuda-11.4/targets/aarch64-linux/lib -maxdepth 1 -type f -name 'lib*.so.*'
           find "$LIBDIR/tegra" "$LIBDIR/tegra-egl" -maxdepth 1 -type f -name '*.so*'
           find /usr/lib/nano-xorg/modules -name '*nvidia*.so'; } | sort)
(( unresolved == 0 )) && check LIBRARIES_LINK PASS || check LIBRARIES_LINK FAIL

# --- 4. CUDA, EGL and OpenGL ES, Vulkan: every NVIDIA library from /usr, none from JetPack 4.
run_probe() {  # NAME SCRIPT ARGS...
    local name=$1 script=$2; shift 2
    timeout -k 10 300 env -u DISPLAY -u WAYLAND_DISPLAY -u LD_LIBRARY_PATH __GL_SHADER_DISK_CACHE=0 \
        CUDA_CACHE_DISABLE=1 python3 -I "$here/$script" "$@" --lib-root /usr > "$record/$name.log" 2>&1
    local status=$?
    grep -E '^(LOAD_ERROR|SYMBOL_ERROR|DRIVER_VERSION|RUNTIME_VERSION|DEVICE|VECTOR_ADD|RUNTIME_TEST|EGL_INIT|EGL_VENDOR|GL_VERSION|GL_RENDERER|GL_SHADER_DRAW|GL_FILL|CUDA_INIT|CUDA_MEMORY|VK_INSTANCE|VK_PHYSICAL_DEVICE|VK_DEVICE|VK_COMPUTE|VK_COMPUTE_RATE|LIB_MIX|PROBE)=|=FAIL' \
        "$record/$name.log" | cut -c1-200 | sed "s/^/$name: /"
    if grep -E '^LIB=' "$record/$name.log" | grep -qE '\.so\.32\.7\.6|cuda-10'; then
        printf '%s: JETPACK4_LIBRARY=FAIL\n' "$name"; status=1
    fi
    (( status == 0 )) && grep -qx 'PROBE=PASS' "$record/$name.log"
}
run_probe cuda cuda11_probe.py --driver libcuda.so.1 --runtime libcudart.so.11.0 --expect-driver 11040 \
    && check CUDA PASS || check CUDA FAIL
run_probe egl egl_probe.py --cuda libcuda.so.1 && check EGL_GLES PASS || check EGL_GLES FAIL
run_probe vulkan vk_probe.py && check VULKAN PASS || check VULKAN FAIL

# --- 5. TensorRT.
cache=$record/cuda-cache
python3 -I "$here/trt_check.py" input "$record/input.bin" > /dev/null || die 'cannot write the TensorRT input'
run_trt() {  # NAME TOLERANCE then trtexec's arguments
    local name=$1 tolerance=$2; shift 2
    local log=$record/$name.log output=$record/$name-output.json
    timeout -k 10 "$RUN_SECONDS" env -u DISPLAY -u WAYLAND_DISPLAY -u LD_LIBRARY_PATH CUDA_CACHE_PATH="$cache" \
        "${trt85[@]}" "$TRTEXEC" --onnx="$here/tiny_cnn.onnx" --memPoolSize=workspace:256 --duration=2 --warmUp=200 "$@" \
        --loadInputs=input:"$record/input.bin" --exportOutput="$output" > "$log" 2>&1
    local status=$?
    grep -E 'TensorRT version:|Engine built in|Throughput:|GPU Compute Time:' "$log" \
        | sed -E 's/^\[[^]]*\] \[I\] //' | cut -c1-160 | sed "s/^/$name: /"
    grep -E '\] \[E\] ' "$log" | head -n 8 | cut -c1-240 | sed "s/^/$name: /"
    printf '%s: TRTEXEC_EXIT=%s\n' "$name" "$status"
    (( status == 0 )) || tail -n 3 "$log" | cut -c1-240 | sed "s/^/$name: LAST: /"
    [[ -s $output ]] || { printf '%s: TRT_OUTPUT=FAIL no output written\n' "$name"; return 1; }
    python3 -I "$here/trt_check.py" check "$output" "$here/expected.json" "$tolerance" | sed "s/^/$name: /"
    (( PIPESTATUS[0] == 0 && status == 0 ))
}
if [[ -x $TRTEXEC ]]; then
    run_trt fp32 1e-3 --saveEngine="$record/fp32.engine" && check TENSORRT_FP32 PASS || check TENSORRT_FP32 FAIL
    run_trt fp16 5e-2 --fp16 --saveEngine="$record/fp16.engine" && check TENSORRT_FP16 PASS || check TENSORRT_FP16 FAIL
else
    check TENSORRT "FAIL no $TRTEXEC"
fi

# --- 6. GLX on this account's desktop session, when there is one.
if command -v glxinfo > /dev/null && [[ -S /tmp/.X11-unix/X0 ]] \
        && timeout 20 env DISPLAY=:0 XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" glxinfo -B \
            > "$record/glxinfo.txt" 2>&1; then
    grep -E 'direct rendering|OpenGL vendor|OpenGL renderer|OpenGL version|server glx vendor' "$record/glxinfo.txt" \
        | sed 's/^/glx: /'
    grep -q '^direct rendering: Yes' "$record/glxinfo.txt" \
        && grep -qE "^OpenGL version string: .*NVIDIA $RELEASE" "$record/glxinfo.txt" \
        && check GLX PASS || check GLX FAIL
else
    printf 'GLX=skipped (no desktop session of %s on :0)\n' "$(id -un)"
fi

# --- 7. Kernel messages since the start (needs the adm or systemd-journal group).
if journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1 \
        && ! grep -q 'No journal files were opened\|not seeing messages' "$record/kernel.log"; then
    printf 'KERNEL_LOG=read lines=%s\n' "$(wc -l < "$record/kernel.log")"
    grep -iE 'nvgpu|nvmap|smmu|mmu_fault|mc-err|gk20a|gm20b|host1x' "$record/kernel.log" \
        | tail -n 30 | sed 's/^/KERNEL: /'
else
    printf 'KERNEL_LOG=unavailable\n'
fi
finish

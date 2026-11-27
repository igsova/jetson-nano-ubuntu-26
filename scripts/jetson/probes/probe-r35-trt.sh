#!/usr/bin/env bash
# Try JetPack 5's TensorRT 8.5 on the Nano's GPU from a scratch folder.
#
# Usage: bash probe-r35-trt.sh INPUTS_DIR...
#
# Run as the owner's ordinary account, without sudo, on Ubuntu 26.04
# under the 5.10 kernel, with the /dev/nvgpu/igpu0 nodes open to the video
# group. Each INPUTS_DIR is a folder scripts/host/fetch-r35-cuda.py wrote: the
# driver set (NVIDIA's L4T R35.6 nvidia-l4t-core, -3d-core and -cuda, and
# cuda-cudart-11-4) and the tensorrt set (TensorRT 8.5 with trtexec, cuDNN 8.6,
# cuBLAS, NVRTC, cuDLA and any platform package they need), each with
# SHA256SUMS. This script's own folder holds trt_check.py, tiny_cnn.onnx,
# expected.json, cudla_stub.c and cudla_stub.map (tests/trt) and a SHA256SUMS
# for them and this script. The .debs are only unpacked, with
# dpkg-deb -x, into ~/r35-trt-probe/<stamp>/root, with R35.6's libdrm.so.2 set
# aside as in the X test; nothing is installed and no system file is changed.
# The unpacked libraries (a few GB) are removed at the end unless KEEP_ROOT=1;
# the logs, engines and outputs stay in the record folder.
#
# TensorRT links libcudla.so.1, the runtime of the DLA engines the Nano lacks.
# NVIDIA's (libcudla-11-4) is used when the inputs hold it and its own
# libraries resolve; otherwise, or with CUDLA=stub, the script builds
# cudla_stub.c (no DLA devices) with the Nano's gcc into the scratch folder.
#
# Steps, each logged in the record folder:
#   1. libraries: every library trtexec and the TensorRT, cuDNN and cuBLAS
#      libraries link to resolves, the NVIDIA ones inside the scratch folder;
#   2. fp32: trtexec builds an FP32 engine for tiny_cnn.onnx on the GPU and
#      runs it on trt_check.py's input; the output must match expected.json
#      within 1e-3;
#   3. reload: the saved FP32 engine is loaded and run again, as an
#      application would (1e-3);
#   4. fp16: the same with FP16 allowed (5e-2);
#   5. own-kernels: the FP32 build with cuDNN and cuBLAS tactics turned off,
#      so only TensorRT's own kernels can serve (reported, not required);
#   6. control: JetPack 4's trtexec (TensorRT 8.2 on CUDA 10.2), when the
#      system has it (reported, not required);
#   7. the kernel's messages since the start, when the account may read them.
# Each JetPack 5 run records the libraries it loaded (LD_DEBUG=libs,scopes)
# and requires every NVIDIA one to come from the scratch folder. The last line
# is R35_TRT_PROBE=PASS or FAIL; it passes when steps 1 to 4 pass.
set -uo pipefail

KERNEL=5.10.216-tegra
# The .debs taken from the inputs; their versions are checked below.
PACKAGES='nvidia-l4t-[a-z0-9-]+|libnvinfer[a-z0-9-]*|libnvonnxparsers[0-9]+|libnvparsers[0-9]+|libcudnn[0-9]+|libcublas-11-4|libcudla-11-4|cuda-[a-z0-9-]+-11-4'
SYSTEM_TRTEXEC=/usr/src/tensorrt/bin/trtexec
NV_LIBS='^lib(nv|cuda|cudla|cudnn|cublas|cudart|nvrtc|myelin)'
RUN_SECONDS=900

root=
cleanup() {
    [[ -n $root && -d $root ]] || return 0
    if [[ ${KEEP_ROOT:-0} == 1 ]]; then
        printf 'ROOT_KEPT=%s\n' "$root"
    else
        rm -rf "$root" && printf 'ROOT_REMOVED=%s\n' "$root"
    fi
}
die() { cleanup; trap - EXIT; printf 'R35_TRT_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
(( $# )) || die 'give the driver and TensorRT input folders (for example ~/cuda11-inputs-2 ~/r35-trt-inputs)'
inputs=()
for dir in "$@"; do
    [[ -d $dir ]] || die "no inputs folder $dir"
    inputs+=("$(cd "$dir" && pwd)")
done
[[ $(id -u) -ne 0 ]] || die 'run this as the ordinary account, not with sudo'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for file in trt_check.py tiny_cnn.onnx expected.json cudla_stub.c cudla_stub.map; do
    [[ -f $here/$file ]] || die "no $file next to this script"
done
(cd "$here" && grep -E '  (probe-r35-trt\.sh|trt_check\.py|tiny_cnn\.onnx|expected\.json|cudla_stub\.(c|map))$' SHA256SUMS \
    | sha256sum --quiet -c -) > /dev/null 2>&1 \
    || die 'this script or its test files do not match the SHA256SUMS next to it'
nodes=()
for node in /dev/nvgpu/igpu0/power /dev/nvgpu/igpu0/ctrl /dev/nvgpu/igpu0/as \
        /dev/nvgpu/igpu0/channel /dev/nvgpu/igpu0/tsg; do
    [[ -r $node && -w $node ]] || nodes+=("$node")  # bash's test; 26.04's uutils test misreads groups
done
(( ${#nodes[@]} == 0 )) || die "this account cannot open ${nodes[*]}; give the GPU nodes to the video group first (see the CUDA 11 test)"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$HOME/r35-trt-probe/$stamp
mkdir -p "$HOME/r35-trt-probe" && mkdir "$record" || die "cannot create $record"
root=$record/root
mkdir "$root" || die "cannot create $root"
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
exec > >(tee "$record/summary.txt") 2>&1
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\n' "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME"
printf 'ACCOUNT=%s\n' "$(id)"

result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || result=FAIL; }
finish() {
    cleanup; trap - EXIT
    printf 'R35_TRT_PROBE=%s record=%s\n' "$result" "$record"
    [[ $result == PASS ]] && exit 0
    exit 1
}

# --- Inputs, as the PC wrote them.
shopt -s nullglob
debs=() names=()
for dir in "${inputs[@]}"; do
    name=$(basename "$dir")
    if (cd "$dir" && sha256sum --quiet -c SHA256SUMS) > "$record/sha256-check-$name.txt" 2>&1; then
        printf 'INPUTS_SHA256=PASS %s\n' "$dir"
    else
        cat "$record/sha256-check-$name.txt"
        printf 'INPUTS_SHA256=FAIL %s\n' "$dir"
        result=FAIL; finish
    fi
    cp "$dir/SHA256SUMS" "$record/SHA256SUMS-$name"
    for deb in "$dir"/*.deb; do
        [[ $(basename "$deb") =~ ^($PACKAGES)_ ]] || continue
        package=$(dpkg-deb -f "$deb" Package) version=$(dpkg-deb -f "$deb" Version)
        case $package in
            nvidia-l4t-*) want='35.6.*' ;;
            libnvinfer*|libnvonnxparsers*|libnvparsers*) want='8.5.*' ;;
            libcudnn*) want='8.6.*' ;;
            *) want='*' ;;
        esac
        # shellcheck disable=SC2053  # $want is a pattern
        [[ $version == $want ]] || die "$(basename "$deb") is $version, not $want"
        if [[ " ${names[*]} " == *" $package "* ]]; then
            printf 'DUPLICATE=%s (kept the first)\n' "$(basename "$deb")"
            continue
        fi
        names+=("$package") debs+=("$deb")
    done
done
for package in nvidia-l4t-core nvidia-l4t-cuda libnvinfer-bin libnvinfer8 libnvonnxparsers8 libcudnn8 libcublas-11-4; do
    [[ " ${names[*]} " == *" $package "* ]] || die "no $package .deb in the inputs"
done
need=0
for deb in "${debs[@]}"; do
    size=$(dpkg-deb -f "$deb" Installed-Size)
    need=$(( need + ${size:-0} ))
done
need=$(( need / 1024 + 1024 ))
free=$(python3 -I -c 'import os, sys; s = os.statvfs(sys.argv[1]); print(s.f_bavail * s.f_frsize >> 20)' "$record")
printf 'SPACE=%s MiB free, %s MiB needed\n' "$free" "$need"
(( free >= need )) || die "not enough space in $HOME: $free MiB free, $need MiB needed"
for deb in "${debs[@]}"; do
    printf 'UNPACK=%s\n' "$(basename "$deb")"
    dpkg-deb -x "$deb" "$root" || die "dpkg-deb could not unpack $deb"
done
tegra=$root/usr/lib/aarch64-linux-gnu/tegra
[[ -d $tegra ]] || die 'no usr/lib/aarch64-linux-gnu/tegra in the R35 packages'
if [[ -e $tegra/libdrm.so.2 ]]; then
    mv "$tegra/libdrm.so.2" "$record/libdrm.so.2.r35-set-aside"
    printf 'SET_ASIDE=libdrm.so.2 (R35.6 core; Ubuntu libdrm stays in charge)\n'
fi
dirs=("$tegra")
while IFS= read -r dir; do
    [[ $dir == "$tegra" || $dir == */stubs ]] || dirs+=("$dir")
done < <(find "$root" \( -type f -o -type l \) -name 'lib*.so*' -printf '%h\n' | sort -u)
libdirs=$(IFS=:; echo "${dirs[*]}")
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
"$ldconfig" -n "${dirs[@]}" 2>&1 | sed 's/^/LDCONFIG: /'
# cuDLA: NVIDIA's when it is there and resolves, else the stand-in.
cudla=$(find "${dirs[@]}" -maxdepth 1 -name 'libcudla.so.1' | head -n 1)
if [[ ${CUDLA:-} == stub ]]; then
    why='CUDLA=stub'
elif [[ -z $cudla ]]; then
    why='no libcudla.so.1 in the inputs'
elif LD_LIBRARY_PATH=$libdirs ldd "$cudla" > "$record/ldd-cudla.txt" 2>&1 \
        && ! grep -q 'not found' "$record/ldd-cudla.txt"; then
    why=
else
    why="NVIDIA's cannot resolve $(awk '/not found/ {printf "%s%s", sep, $1; sep = " "}' "$record/ldd-cudla.txt")"
fi
if [[ -z $why ]]; then
    printf 'CUDLA=NVIDIA %s\n' "${cudla#"$root"}"
else
    if [[ -n $cudla ]]; then
        mkdir -p "$record/libcudla-set-aside"
        mv "$(dirname "$cudla")"/libcudla.so* "$record/libcudla-set-aside/"
    fi
    cc=$(command -v gcc || command -v gcc-11 || command -v cc) || die "no C compiler for the cuDLA stand-in ($why)"
    mkdir -p "$root/cudla-stub"
    "$cc" -shared -fPIC -O2 -Wl,-soname,libcudla.so.1 -Wl,--version-script="$here/cudla_stub.map" \
        -o "$root/cudla-stub/libcudla.so.1" "$here/cudla_stub.c" > "$record/cudla-stub-build.txt" 2>&1 \
        || { cat "$record/cudla-stub-build.txt"; die "could not build the cuDLA stand-in with $cc"; }
    dirs+=("$root/cudla-stub")
    libdirs=$(IFS=:; echo "${dirs[*]}")
    printf 'CUDLA=stand-in built with %s (%s)\n' "$("$cc" --version | head -n 1)" "$why"
fi
printf 'LIBDIR=%s\n' "${dirs[@]#"$root"}"
ls -l "${dirs[@]}" > "$record/libraries.txt"
trtexec=$(find "$root" \( -type f -o -type l \) -name trtexec | head -n 1)
[[ -n $trtexec ]] || die 'no trtexec in the TensorRT packages (libnvinfer-bin)'
printf 'TRTEXEC=%s\n' "${trtexec#"$root"}"
model=$here/tiny_cnn.onnx
python3 -I "$here/trt_check.py" input "$record/input.bin" || die 'cannot write the input'

# --- 1. Libraries: what the dynamic linker finds for trtexec and TensorRT's libraries.
unresolved=0 outside=0
while IFS= read -r file; do
    LD_LIBRARY_PATH=$libdirs ldd "$file" > "$record/ldd.tmp" 2>&1
    printf '## %s\n' "${file#"$root"}" >> "$record/ldd.txt"
    cat "$record/ldd.tmp" >> "$record/ldd.txt"
    while read -r lib _ path _; do
        if [[ $path == not ]]; then
            printf 'UNRESOLVED %s (needed by %s)\n' "$lib" "$(basename "$file")"; unresolved=$(( unresolved + 1 ))
        elif [[ $lib =~ $NV_LIBS && $path == /* && $path != "$root"/* ]]; then
            printf 'OUTSIDE %s => %s (needed by %s)\n' "$lib" "$path" "$(basename "$file")"; outside=$(( outside + 1 ))
        fi
    done < <(grep '=>' "$record/ldd.tmp")
done < <(printf '%s\n' "$trtexec"; find "${dirs[@]:1}" -maxdepth 1 -type f \
    \( -name 'libnvinfer*.so*' -o -name 'libnvonnxparser*.so*' -o -name 'libnvparsers*.so*' \
       -o -name 'libcudnn*.so*' -o -name 'libcublas*.so*' -o -name 'libnvrtc*.so*' \
       -o -name 'libcudla*.so*' \) | sort)
rm -f "$record/ldd.tmp"
(( unresolved == 0 && outside == 0 )) && check LIBRARIES PASS || check LIBRARIES FAIL

# --- TensorRT runs. NAME TOLERANCE then trtexec's arguments.
cache=$record/cuda-cache
run_trt() {
    local name=$1 tolerance=$2; shift 2
    local log=$record/$name.log output=$record/$name-output.json ok=0
    timeout -k 10 "$RUN_SECONDS" env -u DISPLAY -u WAYLAND_DISPLAY LD_LIBRARY_PATH="$libdirs" \
        CUDA_CACHE_PATH="$cache" LD_DEBUG=libs,scopes LD_DEBUG_OUTPUT="$record/ld-$name" \
        "$trtexec" "$@" --loadInputs=input:"$record/input.bin" --exportOutput="$output" > "$log" 2>&1
    local status=$?
    grep -E 'Selected Device:|Compute Capability:|TensorRT version:|Engine built in|Engine deserialized in|Throughput:|GPU Compute Time:' \
        "$log" | sed -E 's/^\[[^]]*\] \[I\] //' | cut -c1-160 | sed "s/^/$name: /"
    grep -E '\] \[E\] ' "$log" | head -n 12 | cut -c1-240 | sed "s/^/$name: /"
    printf '%s_TRTEXEC_EXIT=%s\n' "${name^^}" "$status"
    (( status == 0 )) || { ok=1; tail -n 3 "$log" | cut -c1-240 | sed "s/^/$name: LAST: /"; }
    if [[ -s $output ]]; then
        python3 -I "$here/trt_check.py" check "$output" "$here/expected.json" "$tolerance" \
            | sed "s/^/$name: /"
        (( PIPESTATUS[0] == 0 )) || ok=1
    else
        printf '%s: TRT_OUTPUT=FAIL no output written\n' "$name"; ok=1
    fi
    # Every library the run loaded, from the linker's own record.
    cat "$record/ld-$name".* 2> /dev/null | grep -E 'calling init: |object=|scope [0-9]+:' \
        | grep -oE '/[^ ]+\.so[.0-9]*' | sort -u > "$record/$name-loaded.txt"
    local mixed
    mixed=$(while read -r path; do
        [[ $(basename "$path") =~ $NV_LIBS && $path != "$root"/* ]] && echo "$path"
    done < "$record/$name-loaded.txt")
    printf '%s: NV_LOADED=%s\n' "$name" "$(while read -r path; do
        [[ $(basename "$path") =~ $NV_LIBS ]] && basename "$path"; done < "$record/$name-loaded.txt" | tr '\n' ' ')"
    if [[ ! -s $record/$name-loaded.txt ]]; then
        printf '%s: LIB_MIX=FAIL the linker recorded nothing\n' "$name"; ok=1
    elif [[ -n $mixed ]]; then
        printf '%s: LIB_MIX=FAIL %s\n' "$name" "$(echo $mixed)"; ok=1
    else
        printf '%s: LIB_MIX=PASS every NVIDIA library from the scratch folder\n' "$name"
    fi
    rm -f "$record/ld-$name".*
    return "$ok"
}

common=(--onnx="$model" --memPoolSize=workspace:256 --profilingVerbosity=detailed --verbose
        --duration=2 --warmUp=200)

# --- 2. FP32 build and run.
run_trt fp32 1e-3 "${common[@]}" --saveEngine="$record/fp32.engine" \
    --exportLayerInfo="$record/fp32-layers.json" && check FP32 PASS || check FP32 FAIL

# --- 3. Reload the FP32 engine.
if [[ -s $record/fp32.engine ]]; then
    run_trt reload 1e-3 --loadEngine="$record/fp32.engine" --duration=2 --warmUp=200 \
        && check RELOAD PASS || check RELOAD FAIL
else
    check RELOAD 'FAIL no FP32 engine'
fi

# --- 4. FP16.
run_trt fp16 5e-2 "${common[@]}" --fp16 --saveEngine="$record/fp16.engine" \
    --exportLayerInfo="$record/fp16-layers.json" && check FP16 PASS || check FP16 FAIL

# --- 5. TensorRT's own kernels only (reported, not required).
if run_trt own_kernels 1e-3 "${common[@]}" --tacticSources=-CUDNN,-CUBLAS,-CUBLAS_LT \
        --saveEngine="$record/own-kernels.engine"; then
    printf 'OWN_KERNELS=PASS\n'
else
    printf 'OWN_KERNELS=FAIL (not required)\n'
fi

# --- 6. Control: JetPack 4's TensorRT, when installed (reported, not required).
if [[ -x $SYSTEM_TRTEXEC ]]; then
    timeout -k 10 "$RUN_SECONDS" env -u DISPLAY -u WAYLAND_DISPLAY CUDA_CACHE_PATH="$cache-control" \
        "$SYSTEM_TRTEXEC" --onnx="$model" --workspace=256 --saveEngine="$record/control.engine" \
        --loadInputs=input:"$record/input.bin" --exportOutput="$record/control-output.json" \
        --duration=2 --warmUp=200 > "$record/control.log" 2>&1
    printf 'CONTROL_TRTEXEC_EXIT=%s\n' "$?"
    grep -E 'TensorRT version:|Engine built in|Throughput:|GPU Compute Time:|\] \[E\] ' "$record/control.log" \
        | head -n 12 | sed -E 's/^\[[^]]*\] \[I\] //' | cut -c1-160 | sed 's/^/control: /'
    if [[ -s $record/control-output.json ]] && python3 -I "$here/trt_check.py" check \
            "$record/control-output.json" "$here/expected.json" 1e-3 | sed 's/^/control: /' \
            && (( PIPESTATUS[0] == 0 )); then
        printf 'CONTROL=PASS\n'
    else
        printf 'CONTROL=FAIL (not required)\n'
    fi
else
    printf 'CONTROL=skipped (no %s)\n' "$SYSTEM_TRTEXEC"
fi

# --- 7. Kernel messages since the start (needs the adm or systemd-journal group).
if journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1 \
        && ! grep -q 'No journal files were opened\|not seeing messages' "$record/kernel.log"; then
    printf 'KERNEL_LOG=read lines=%s\n' "$(wc -l < "$record/kernel.log")"
    grep -iE 'nvgpu|nvmap|smmu|mmu_fault|mc-err|gk20a|gm20b|host1x|tegra' "$record/kernel.log" \
        | tail -n 40 | sed 's/^/KERNEL: /'
else
    printf 'KERNEL_LOG=unavailable (%s)\n' "$(head -n 1 "$record/kernel.log")"
fi
printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
finish

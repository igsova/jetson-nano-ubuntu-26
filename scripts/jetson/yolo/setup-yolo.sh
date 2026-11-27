#!/usr/bin/env bash
# Set up live YOLO26 detection on the USB webcam with TensorRT on
# Ubuntu 26.04: build the engines and the runner yolo-cam.py uses, time them
# and check their detections.
#
# Usage, from an SSH login to the Nano, as your own account (no sudo), with
# this folder and the bundle from scripts/host/export-yolo26.py copied over:
#   bash setup-yolo.sh ~/yolo26-nano.tar [--quick]
#
# Needs OpenCV for Python 3 (sudo apt install python3-opencv), a C++ compiler
# (g++-11 from add-u26-gcc11.sh, or Ubuntu's g++), and the TensorRT programs
# get by default with its trtexec (trt-default.sh): JetPack 4's 8.2 once
# nano-trt82 is installed (install-trt82.sh), else JetPack 5's 8.5
# (install-u26-r35.sh). Into ~/yolo:
#   1. the bundle, checked against its SHA256SUMS and unpacked;
#   2. that TensorRT's runtime headers (github.com/NVIDIA/TensorRT, Apache-2.0),
#      fetched into src/include-<version> and checked against the SHA-256
#      values in trt-default.sh;
#   3. lib/libnano_trt.so from nano_trt.cpp, linking libnvinfer.so.8 and the
#      CUDA runtime where ldconfig finds them first, and yolo-cam.py;
#   4. per model, an FP16 engine built by trtexec on the GPU (several minutes
#      each) and timed for TIME_SECONDS: GPU time per picture and throughput;
#   5. per engine, yolo-cam.py --check on each test picture against
#      Ultralytics' own detections.
# Engines, their timing cache and the runner are for one TensorRT, named in
# engines/TENSORRT. Those of another (TensorRT 8.5's, after nano-trt82 is
# installed) move to ~/yolo/trt85 or ~/yolo/trt82 with its runner, for
# nano-trt85 python3 yolo-cam.py --engine ... --lib ... TensorRT 8.2's first
# timing cache comes from probe-trt82.sh's when there is one. --quick takes
# only YOLO26n with its NMS-free head (the one yolo-cam.py runs by default).
# Engines already built are reused; delete ~/yolo/engines to build them again.
# It runs again safely after a failure. The record goes to
# ~/yolo/setup/<stamp>; the last line is YOLO_SETUP=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
TIME_SECONDS=20
WORKSPACE_MIB=1024
MODELS=(yolo26n-640x480 yolo26n-640x480-raw yolo26s-640x480)
WORK=$HOME/yolo

die() { printf 'YOLO_SETUP=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
bundle_tar=${1:-}
quick=0
[[ ${2:-} == --quick ]] && quick=1
[[ -n $bundle_tar && ( -z ${2:-} || $quick == 1 ) ]] || die 'usage: bash setup-yolo.sh BUNDLE.tar [--quick]'
[[ -f $bundle_tar ]] || die "no $bundle_tar"
(( quick )) && MODELS=(yolo26n-640x480)
[[ $(id -u) -ne 0 ]] || die 'run this as your own account, without sudo'
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for file in nano_trt.cpp include/cuda_runtime_api.h yolo-cam.py trt-default.sh; do
    [[ -f $here/$file ]] || die "no $file next to this script"
done
for tool in python3 tar sha256sum; do command -v "$tool" > /dev/null || die "no $tool"; done
python3 -c 'import cv2, numpy' 2> /dev/null || die 'no OpenCV for Python 3: sudo apt install python3-opencv'
cxx=$(command -v g++-11 || command -v g++) || die 'no C++ compiler: sudo bash add-u26-gcc11.sh (or sudo apt install g++)'
. "$here/trt-default.sh"
trt_default || die 'no TensorRT to build for (the line above says why)'
[[ -x $TRTEXEC ]] || die "no $TRTEXEC (TensorRT $TRT_NAME's trtexec)"
workspace=$(workspace_flag "$WORKSPACE_MIB")
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
lib_path() { "$ldconfig" -p | awk -v n="$1" '$1 == n && /AArch64/ { print $NF; exit }'; }
nvinfer=$(lib_path libnvinfer.so.8)
cudart=$(lib_path "$CUDART")
[[ -n $nvinfer && -n $cudart ]] || die "ldconfig knows no libnvinfer.so.8 or $CUDART (${nvinfer:-none}, ${cudart:-none})"
include=$WORK/src/include-$TRT_NAME

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$WORK/setup/$stamp
mkdir -p "$WORK/setup" "$WORK/lib" "$WORK/engines" "$include" && mkdir "$record" \
    || die "cannot create $record"
exec 3>&1 4>&2
exec > >(tee "$record/summary.txt") 2>&1
tee_pid=$!
start=$(date +%s)
printf 'RECORD=%s\nKERNEL=%s\nCOMPILER=%s\nTENSORRT=%s (%s)\nNVINFER=%s\nCUDART=%s\n' "$record" "$(uname -r)" \
    "$("$cxx" --version | head -n 1)" "$TRT_NAME" "$TRTEXEC" "$nvinfer" "$cudart"
gpu=/sys/class/devfreq/57000000.gpu
printf 'GPU governor=%s clock=%s max=%s Hz\n' "$(cat "$gpu/governor" 2> /dev/null)" \
    "$(cat "$gpu/cur_freq" 2> /dev/null)" "$(cat "$gpu/max_freq" 2> /dev/null)"
grep -E '^(MemTotal|MemAvailable|SwapFree):' /proc/meminfo | tr -s ' ' | tr '\n' ' '; echo

result=PASS
failed=()
live=''  # the first engine that built and passed its checks, for yolo-cam.py
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS* ]] || { result=FAIL; failed+=("$1"); }; }
finish() {
    printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
    if [[ $live == "$WORK/engines/${MODELS[0]}-fp16.engine" && ${MODELS[0]} == yolo26n-640x480 ]]; then
        printf 'Next: python3 %s/yolo-cam.py --seconds 120\n' "$WORK"
    elif [[ -n $live ]]; then
        printf 'Next: python3 %s/yolo-cam.py --seconds 120 --engine %s\n' "$WORK" "$live"
    fi
    if [[ $result == PASS ]]; then
        printf 'YOLO_SETUP=PASS record=%s\n' "$record"
    else
        printf 'YOLO_SETUP=FAIL %s record=%s\n' "${failed[*]}" "$record"
    fi
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    [[ $result == PASS ]] && exit 0
    exit 1
}
trap 'printf "INTERRUPTED\n"; result=FAIL; failed+=(INTERRUPTED); finish' INT TERM

# --- Engines, their timing cache and the runner of another TensorRT move aside.
was=$(cat "$WORK/engines/TENSORRT" 2> /dev/null)
# Setups before nano-trt82 (2026-10-19) built for TensorRT 8.5 and named none.
[[ -z $was ]] && compgen -G "$WORK/engines/*.engine" > /dev/null && was=8502
if [[ -n $was && $was != "$TRT_VERSION" ]]; then
    keep=$WORK/trt${was:0:2}
    mkdir -p "$keep/engines" "$keep/lib" || die "cannot create $keep"
    moved=()
    for file in "$WORK"/engines/*.engine "$WORK/engines/timing.cache" "$WORK/engines/TENSORRT" "$WORK/lib/libnano_trt.so"; do
        [[ -f $file ]] || continue
        [[ $file == */lib/* ]] && to=$keep/lib || to=$keep/engines
        mv -f "$file" "$to/" || die "cannot move $file to $to"
        moved+=("${file##*/}")
    done
    printf 'MOVED=TensorRT %s.%s.%s'\''s %s to %s\n' "${was:0:1}" "${was:1:1}" "$(( 10#${was:2} ))" "${moved[*]}" "$keep"
    [[ $was == 85* ]] && printf '  with it: nano-trt85 python3 %s/yolo-cam.py --engine %s/engines/MODEL-fp16.engine --lib %s/lib/libnano_trt.so\n' \
        "$WORK" "$keep" "$keep"
fi
printf '%s\n' "$TRT_VERSION" > "$WORK/engines/TENSORRT"
# TensorRT 8.2's first timing cache: probe-trt82.sh's, from the same TensorRT and GPU.
if [[ $TRT_VERSION == 8201 && ! -f $WORK/engines/timing.cache && -f $WORK/trt82/timing.cache ]]; then
    cp "$WORK/trt82/timing.cache" "$WORK/engines/timing.cache" && printf 'TIMING_CACHE=%s\n' "$WORK/trt82/timing.cache"
fi

# --- 1. The bundle.
bundle=$WORK/yolo26-nano
rm -rf "$bundle" "$WORK/yolo26-nano.part"
mkdir "$WORK/yolo26-nano.part" && tar -xf "$bundle_tar" -C "$WORK/yolo26-nano.part" \
    && mv "$WORK/yolo26-nano.part/yolo26-nano" "$bundle" && rmdir "$WORK/yolo26-nano.part"
if [[ -f $bundle/SHA256SUMS ]] && (cd "$bundle" && sha256sum --quiet -c SHA256SUMS) > "$record/bundle.txt" 2>&1; then
    check BUNDLE "PASS $(wc -l < "$bundle/SHA256SUMS") files, $(sha256sum "$bundle_tar" | cut -c1-16)"
else
    check BUNDLE "FAIL (unpacking or SHA256SUMS: $(head -n 3 "$record/bundle.txt" | tr '\n' ' '))"
    finish
fi

# --- 2. TensorRT's headers.
bad=()
for entry in "${HEADERS[@]}"; do
    sum=${entry%%:*} name=${entry#*:} path=$include/${entry#*:}
    if [[ ! -f $path ]] || ! sha256sum "$path" | grep -q "^$sum "; then
        python3 -I - "$TRT_URL/$name" "$path.part" << 'EOF' 2>> "$record/headers.txt" || true
import shutil, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=60) as r, open(sys.argv[2], 'wb') as f:
    shutil.copyfileobj(r, f)
EOF
        if [[ -f $path.part ]] && sha256sum "$path.part" | grep -q "^$sum "; then
            mv "$path.part" "$path"
        else
            rm -f "$path.part"
            bad+=("$name")
        fi
    fi
done
if (( ${#bad[@]} )); then
    check HEADERS "FAIL ${bad[*]} (fetched from raw.githubusercontent.com: $(tail -n 1 "$record/headers.txt"))"
    finish
fi
check HEADERS "PASS TensorRT $(awk '/define NV_TENSORRT_(MAJOR|MINOR|PATCH) /{ printf "%s%s", s, $3; s="." }' \
    "$include/NvInferVersion.h")"

# --- 3. The runner.
copy() {  # FROM TO, unless this folder is already there
    [[ $1 -ef $2 ]] || cp "$1" "$2" || die "cannot copy $1 to $2"
}
copy "$here/nano_trt.cpp" "$WORK/src/nano_trt.cpp"
copy "$here/include/cuda_runtime_api.h" "$include/cuda_runtime_api.h"
copy "$here/yolo-cam.py" "$WORK/yolo-cam.py"
if "$cxx" -std=c++14 -O2 -Wall -Wno-deprecated-declarations -fPIC -shared -isystem "$include" -o "$WORK/lib/libnano_trt.so.part" \
        "$WORK/src/nano_trt.cpp" "$nvinfer" "$cudart" -ldl -Wl,--no-undefined > "$record/build.txt" 2>&1 \
    && mv "$WORK/lib/libnano_trt.so.part" "$WORK/lib/libnano_trt.so" \
    && version=$(python3 -I -c 'import ctypes, sys; print(ctypes.CDLL(sys.argv[1]).ntrt_version())' \
        "$WORK/lib/libnano_trt.so" 2>> "$record/build.txt") && [[ $version == "$TRT_VERSION" ]]; then
    check RUNNER "PASS libnano_trt.so, TensorRT library $version"
else
    sed 's/^/  build: /' "$record/build.txt" | tail -n 12
    check RUNNER "FAIL (TensorRT library ${version:-not loaded}, $TRT_VERSION wanted)"
    finish
fi

# --- 4. Engines, each built once and timed; 5. their detections.
table=()
for model in "${MODELS[@]}"; do
    engine=$WORK/engines/$model-fp16.engine
    log=$record/$model.trtexec.txt
    timing=(--warmUp=2000 --duration="$TIME_SECONDS")
    if [[ -f $engine ]]; then
        printf '%s: timing the engine built earlier (%s s)\n' "$model" "$TIME_SECONDS"
        "$TRTEXEC" --loadEngine="$engine" "${timing[@]}" > "$log" 2>&1
    else
        printf '%s: building the FP16 engine on the GPU (several minutes), then timing it (%s s)\n' \
            "$model" "$TIME_SECONDS"
        "$TRTEXEC" --onnx="$bundle/models/$model.onnx" --fp16 "$workspace" \
            --timingCacheFile="$WORK/engines/timing.cache" --saveEngine="$engine.part" "${timing[@]}" > "$log" 2>&1 \
            && mv "$engine.part" "$engine"
    fi
    status=$?
    rm -f "$engine.part"
    grep -E 'Engine built in|Engine deserialized in|Throughput:|GPU Compute Time:' "$log" | sed 's/^/  /'
    if (( status != 0 )) || [[ ! -f $engine ]]; then
        grep -E 'ERROR|Error|Could not find|failed' "$log" | tail -n 8 | sed 's/^/  trtexec: /'
        check "ENGINE_$model" "FAIL trtexec exit $status"
        table+=("$model | FAIL | | |")
        continue
    fi
    built=$(grep -oE 'Engine built in [0-9.]+ sec' "$log" | grep -oE '[0-9.]+')
    built=${built:+$built s}
    qps=$(grep -oE 'Throughput: [0-9.]+' "$log" | grep -oE '[0-9.]+$')
    gpu_line=$(grep -m 1 'GPU Compute Time:' "$log")
    mean=$(grep -oE 'mean = [0-9.]+' <<< "$gpu_line" | grep -oE '[0-9.]+$')
    median=$(grep -oE 'median = [0-9.]+' <<< "$gpu_line" | grep -oE '[0-9.]+$')
    check "ENGINE_$model" "PASS built ${built:-earlier}, GPU ${mean:-?} ms mean (${median:-?} median), ${qps:-?} per s"
    checks=()
    passed=1
    for json in "$bundle/test/$model".*.json; do
        image=${json%.json}
        image=${image##*.}
        out=$record/$model.$image.check.txt
        python3 "$WORK/yolo-cam.py" --check "$bundle/test/$image-640x480.png" "$json" --engine "$engine" \
            > "$out" 2>&1
        line=$(grep -E '^YOLO_CHECK=' "$out" || echo 'YOLO_CHECK=FAIL (no result line)')
        grep -E '^  (match|MISSING|EXTRA)' "$out" | sed "s/^/  $image:/"
        [[ $line == YOLO_CHECK=PASS* ]] || tail -n 5 "$out" | sed 's/^/  check: /'
        check "CHECK_${model}_$image" "${line#YOLO_CHECK=}"
        [[ $line == YOLO_CHECK=PASS* ]] || passed=0
        checks+=("$image ${line#YOLO_CHECK=}")
    done
    [[ -z $live && $passed == 1 && ${#checks[@]} -gt 0 ]] && live=$engine
    table+=("$model | ${built:-earlier} | ${mean:-?} ms (${median:-?}) | ${qps:-?} | ${checks[*]%% mean*}")
done

printf '\nmodel | engine built | GPU per picture, mean (median) | pictures per s | check\n'
printf '%s\n' "${table[@]}"
finish

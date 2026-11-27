#!/usr/bin/env bash
# Set up live metric depth (Depth Anything V2 Metric Small, indoor) on the USB
# webcam with TensorRT on Ubuntu 26.04: build the engines, time them
# and check their depth against PyTorch's.
#
# Usage, from an SSH login to the Nano, as your own account (no sudo), with
# this folder and the bundle from scripts/host/export-depth.py copied over:
#   bash setup-depth.sh ~/depth-nano.tar [--quick]
#
# Needs OpenCV for Python 3 (sudo apt install python3-opencv), the TensorRT
# programs get by default with its trtexec (trt-default.sh: JetPack 4's 8.2
# once nano-trt82 is installed), and ~/yolo/lib/libnano_trt.so, the runner
# setup-yolo.sh builds for that TensorRT. Into ~/depth:
#   1. the bundle, checked against its SHA256SUMS and unpacked;
#   2. depth-cam.py with yolo-cam.py, whose engine, camera and web stream it uses;
#   3. per model, an engine built by trtexec on the GPU (several minutes each)
#      and timed for TIME_SECONDS: GPU time per picture and throughput. FP16
#      at 336x252 first (depth-cam.py's default), then the same with
#      LayerNorm's means as convolutions (-convln, in case TensorRT 8.2 cannot
#      build the default's), then the other sizes; then the default model with
#      PyTorch's own LayerNorm (-plainln), in FP16, and in FP32, two references
#      for the checks: whether the FP16-safe LayerNorm matters, and what FP16
#      costs in accuracy;
#   4. per engine, depth-cam.py --check on each test picture against PyTorch's
#      depth, with a picture of the engine's depth map in the record. The
#      -plainln engine's checks are reported but decide nothing.
# --quick builds only the 336x252 FP16 engine. Engines are for one TensorRT,
# named in engines/TENSORRT; those of another move to engines-<its version>.
# An engine is reused while its model's SHA-256 (in NAME.engine.onnx-sha256)
# is the bundle's; delete ~/depth/engines to build them all again.
# probe-depth-trt.sh tells which pieces of the model TensorRT builds.
# It runs again safely after a failure. The record goes to
# ~/depth/setup/<stamp>; the last line is DEPTH_SETUP=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
TIME_SECONDS=20
WORKSPACE_MIB=1024
ENGINES=(  # model, precision
    'da2s-indoor-336x252 fp16'
    'da2s-indoor-336x252-convln fp16'
    'da2s-indoor-280x210 fp16'
    'da2s-indoor-448x336 fp16'
    'da2s-indoor-336x252-plainln fp16'
    'da2s-indoor-336x252 fp32'
)
WORK=$HOME/depth
RUNNER=$HOME/yolo/lib/libnano_trt.so

die() { printf 'DEPTH_SETUP=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
bundle_tar=${1:-}
quick=0
[[ ${2:-} == --quick ]] && quick=1
[[ -n $bundle_tar && ( -z ${2:-} || $quick == 1 ) ]] || die 'usage: bash setup-depth.sh BUNDLE.tar [--quick]'
[[ -f $bundle_tar ]] || die "no $bundle_tar"
(( quick )) && ENGINES=("${ENGINES[0]}")
[[ $(id -u) -ne 0 ]] || die 'run this as your own account, without sudo'
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for file in depth-cam.py yolo-cam.py trt-default.sh; do
    [[ -f $here/$file ]] || die "no $file next to this script"
done
for tool in python3 tar sha256sum; do command -v "$tool" > /dev/null || die "no $tool"; done
python3 -c 'import cv2, numpy' 2> /dev/null || die 'no OpenCV for Python 3: sudo apt install python3-opencv'
. "$here/trt-default.sh"
trt_default || die 'no TensorRT to build for (the line above says why)'
[[ -x $TRTEXEC ]] || die "no $TRTEXEC (TensorRT $TRT_NAME's trtexec)"
workspace=$(workspace_flag "$WORKSPACE_MIB")
runner=$(python3 -I -c 'import ctypes, sys; print(ctypes.CDLL(sys.argv[1]).ntrt_version())' "$RUNNER" 2> /dev/null)
[[ $runner == "$TRT_VERSION" ]] \
    || die "$RUNNER is ${runner:+for TensorRT $runner, }not TensorRT $TRT_NAME's runner: run setup-yolo.sh first, which builds it"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$WORK/setup/$stamp
mkdir -p "$WORK/setup" && mkdir "$record" || die "cannot create $record"
exec 3>&1 4>&2
exec > >(tee "$record/summary.txt") 2>&1
tee_pid=$!
start=$(date +%s)
printf 'RECORD=%s\nKERNEL=%s\nTENSORRT=%s (%s)\nRUNNER=%s\n' "$record" "$(uname -r)" "$TRT_NAME" "$TRTEXEC" "$RUNNER"
gpu=/sys/class/devfreq/57000000.gpu
printf 'GPU governor=%s clock=%s max=%s Hz\n' "$(cat "$gpu/governor" 2> /dev/null)" \
    "$(cat "$gpu/cur_freq" 2> /dev/null)" "$(cat "$gpu/max_freq" 2> /dev/null)"
grep -E '^(MemTotal|MemAvailable|SwapFree):' /proc/meminfo | tr -s ' ' | tr '\n' ' '; echo

result=PASS
failed=()
live=''  # the first engine that built and passed its checks, for depth-cam.py
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS* ]] || { result=FAIL; failed+=("$1"); }; }
finish() {
    printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
    if [[ $live == "$WORK/engines/da2s-indoor-336x252-fp16.engine" ]]; then
        printf 'Next: python3 %s/depth-cam.py --seconds 120\n' "$WORK"
    elif [[ -n $live ]]; then
        printf 'Next: python3 %s/depth-cam.py --seconds 120 --engine %s\n' "$WORK" "$live"
    fi
    if [[ $result == PASS ]]; then
        printf 'DEPTH_SETUP=PASS record=%s\n' "$record"
    else
        printf 'DEPTH_SETUP=FAIL %s record=%s\n' "${failed[*]}" "$record"
    fi
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    [[ $result == PASS ]] && exit 0
    exit 1
}
trap 'printf "INTERRUPTED\n"; result=FAIL; failed+=(INTERRUPTED); finish' INT TERM

# --- Engines of another TensorRT move aside.
was=$(cat "$WORK/engines/TENSORRT" 2> /dev/null)
if [[ -n $was && $was != "$TRT_VERSION" ]]; then
    aside=$WORK/engines-$was
    [[ -e $aside ]] && aside=$aside-$stamp
    mv "$WORK/engines" "$aside" || die "cannot move $WORK/engines to $aside"
    printf 'MOVED=TensorRT %s.%s.%s'\''s engines to %s\n' "${was:0:1}" "${was:1:1}" "$(( 10#${was:2} ))" "$aside"
fi
mkdir -p "$WORK/engines" || die "cannot create $WORK/engines"
printf '%s\n' "$TRT_VERSION" > "$WORK/engines/TENSORRT"

# --- 1. The bundle.
bundle=$WORK/depth-nano
rm -rf "$bundle" "$WORK/depth-nano.part"
mkdir "$WORK/depth-nano.part" && tar -xf "$bundle_tar" -C "$WORK/depth-nano.part" \
    && mv "$WORK/depth-nano.part/depth-nano" "$bundle" && rmdir "$WORK/depth-nano.part"
if [[ -f $bundle/SHA256SUMS ]] && (cd "$bundle" && sha256sum --quiet -c SHA256SUMS) > "$record/bundle.txt" 2>&1; then
    check BUNDLE "PASS $(wc -l < "$bundle/SHA256SUMS") files, $(sha256sum "$bundle_tar" | cut -c1-16)"
else
    check BUNDLE "FAIL (unpacking or SHA256SUMS: $(head -n 3 "$record/bundle.txt" | tr '\n' ' '))"
    finish
fi

# --- 2. The programs.
for file in depth-cam.py yolo-cam.py; do
    [[ $here/$file -ef $WORK/$file ]] || cp "$here/$file" "$WORK/$file" || die "cannot copy $file to $WORK"
done

# --- 3. Engines, each built once and timed; 4. their depth.
table=()
for entry in "${ENGINES[@]}"; do
    read -r model precision <<< "$entry"
    size=$(grep -oE '[0-9]+x[0-9]+' <<< "$model")
    name=$model-$precision
    engine=$WORK/engines/$name.engine
    log=$record/$name.trtexec.txt
    timing=(--warmUp=2000 --duration="$TIME_SECONDS")
    source_sum=$(sha256sum < "$bundle/models/$model.onnx" | cut -c1-64)
    if [[ -f $engine && $(cat "$engine.onnx-sha256" 2> /dev/null) != "$source_sum" ]]; then
        printf '%s: the engine built earlier is from another %s.onnx; building it again\n' "$name" "$model"
        rm -f "$engine" "$engine.onnx-sha256"
    fi
    if [[ -f $engine ]]; then
        printf '%s: timing the engine built earlier (%s s)\n' "$name" "$TIME_SECONDS"
        "$TRTEXEC" --loadEngine="$engine" "${timing[@]}" > "$log" 2>&1
    else
        printf '%s: building the %s engine on the GPU (several minutes), then timing it (%s s)\n' \
            "$name" "${precision^^}" "$TIME_SECONDS"
        flags=("$workspace")
        [[ $precision == fp16 ]] && flags+=(--fp16)
        "$TRTEXEC" --onnx="$bundle/models/$model.onnx" "${flags[@]}" --timingCacheFile="$WORK/engines/timing.cache" \
            --saveEngine="$engine.part" "${timing[@]}" > "$log" 2>&1 \
            && mv "$engine.part" "$engine" && printf '%s\n' "$source_sum" > "$engine.onnx-sha256"
    fi
    status=$?
    rm -f "$engine.part"
    grep -E 'Engine built in|Engine deserialized in|Throughput:|GPU Compute Time:' "$log" | sed 's/^/  /'
    if (( status != 0 )) || [[ ! -f $engine ]]; then
        grep -E 'ERROR|Error|Could not find|failed' "$log" | tail -n 8 | sed 's/^/  trtexec: /'
        check "ENGINE_$name" "FAIL trtexec exit $status"
        table+=("$name | FAIL | | |")
        continue
    fi
    built=$(grep -oE 'Engine built in [0-9.]+ sec' "$log" | grep -oE '[0-9.]+')
    built=${built:+$built s}
    qps=$(grep -oE 'Throughput: [0-9.]+' "$log" | grep -oE '[0-9.]+$')
    gpu_line=$(grep -m 1 'GPU Compute Time:' "$log")
    mean=$(grep -oE 'mean = [0-9.]+' <<< "$gpu_line" | grep -oE '[0-9.]+$')
    median=$(grep -oE 'median = [0-9.]+' <<< "$gpu_line" | grep -oE '[0-9.]+$')
    check "ENGINE_$name" "PASS built ${built:-earlier}, GPU ${mean:-?} ms mean (${median:-?} median), ${qps:-?} per s"
    checks=()
    passed=1
    for png in "$bundle"/test/*-640x480.png; do
        image=${png##*/}
        image=${image%-640x480.png}
        out=$record/$name.$image.check.txt
        python3 "$WORK/depth-cam.py" --check "$png" "$bundle/test/$image.$size.npy" --engine "$engine" \
            --save "$record/$name.$image.jpg" > "$out" 2>&1
        line=$(grep -E '^DEPTH_CHECK=' "$out" || echo 'DEPTH_CHECK=FAIL (no result line)')
        grep -E '^depth ' "$out" | sed "s/^/  $image: /"
        [[ $line == DEPTH_CHECK=PASS* ]] || grep -vE '^(TensorRT |depth |DEPTH_CHECK=)' "$out" | tail -n 5 | sed 's/^/  check: /'
        if [[ $model == *-plainln ]]; then  # a reference: reported, deciding nothing
            printf 'CHECK_%s_%s=%s (reported only)\n' "$name" "$image" "${line#DEPTH_CHECK=}"
        else
            check "CHECK_${name}_$image" "${line#DEPTH_CHECK=}"
        fi
        [[ $line == DEPTH_CHECK=PASS* ]] || passed=0
        checks+=("$image $(grep -oE '^DEPTH_CHECK=[A-Z]+ abs_rel=[0-9.]+' <<< "$line" | sed 's/DEPTH_CHECK=//')")
    done
    [[ -z $live && $passed == 1 && $precision == fp16 && $model != *-plainln && ${#checks[@]} -gt 0 ]] && live=$engine
    table+=("$name | ${built:-earlier} | ${mean:-?} ms (${median:-?}) | ${qps:-?} | ${checks[*]}")
done

printf '\nengine | built | GPU per picture, mean (median) | pictures per s | check\n'
printf '%s\n' "${table[@]}"
finish

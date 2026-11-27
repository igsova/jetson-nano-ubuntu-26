#!/usr/bin/env bash
# Profile a YOLO26 TensorRT engine layer by layer on the Nano: where the GPU's
# time per picture goes.
#
# Usage, from an SSH login to the Nano, as your own account (no sudo), after
# setup-yolo.sh:
#   bash profile-yolo.sh [MODEL]
# MODEL is a model in ~/yolo/yolo26-nano/models, yolo26n-640x480-raw by
# default (the engine yolo-cam.py ran live). The default TensorRT's trtexec
# (trt-default.sh: 8.2 once nano-trt82 is installed, else 8.5) builds its FP16
# engine again with per-layer details, with setup-yolo.sh's settings and timing
# cache (so the same kernels, inferred), times it for TIME_SECONDS, and runs it once
# more with a timer on every layer. A last timing run uses a CUDA graph, which
# shows what launching the many small layers one by one costs. The GPU's
# clock and load are sampled throughout. The summary gives the time by layer
# type and by data type, the format conversions (Reformat layers), the
# convolution kernels used and the slowest layers. It writes only the record,
# ~/yolo/profile/<stamp>, and adds to setup-yolo.sh's timing cache. Needs
# trt-profile.py (the summary) and trt-default.sh next to it. The last line is
# YOLO_PROFILE=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
TIME_SECONDS=20
WORKSPACE_MIB=1024
SLOWEST=20
WORK=$HOME/yolo
GPU=/sys/class/devfreq/57000000.gpu
GPU_LOAD=/sys/devices/gpu.0/load

die() { printf 'YOLO_PROFILE=FAIL: %s\n' "$*" >&2; exit 1; }

model=${1:-yolo26n-640x480-raw}
[[ $# -le 1 && $model != -* ]] || die 'usage: bash profile-yolo.sh [MODEL]'
onnx=$WORK/yolo26-nano/models/$model.onnx
[[ $(id -u) -ne 0 ]] || die 'run this as your own account, without sudo'
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
command -v python3 > /dev/null || die 'no python3'
here=$(cd "$(dirname "$0")" && pwd)
[[ -f $here/trt-profile.py && -f $here/trt-default.sh ]] || die 'no trt-profile.py or trt-default.sh next to this script'
[[ -f $onnx ]] || die "no $onnx (run setup-yolo.sh first)"
. "$here/trt-default.sh"
trt_default || die 'no TensorRT to profile (the line above says why)'
[[ -x $TRTEXEC ]] || die "no $TRTEXEC (TensorRT $TRT_NAME's trtexec)"
[[ $(cat "$WORK/engines/TENSORRT" 2> /dev/null || echo 8502) == "$TRT_VERSION" ]] \
    || die "setup-yolo.sh's engines are not TensorRT $TRT_NAME's: run setup-yolo.sh first"
workspace=$(workspace_flag "$WORKSPACE_MIB")
separate=()
"$TRTEXEC" --help 2>&1 | grep -q -- --separateProfileRun && separate=(--separateProfileRun)

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$WORK/profile/$stamp
mkdir -p "$WORK/profile" "$WORK/engines" && mkdir "$record" || die "cannot create $record"
exec 3>&1 4>&2
exec > >(tee "$record/summary.txt") 2>&1
tee_pid=$!
printf 'RECORD=%s\nMODEL=%s\nKERNEL=%s\nTENSORRT=%s (%s)\n' "$record" "$model" "$(uname -r)" "$TRT_NAME" "$TRTEXEC"
printf 'GPU governor=%s clock=%s min=%s max=%s Hz\n' "$(cat "$GPU/governor" 2> /dev/null)" \
    "$(cat "$GPU/cur_freq" 2> /dev/null)" "$(cat "$GPU/min_freq" 2> /dev/null)" "$(cat "$GPU/max_freq" 2> /dev/null)"

# The GPU's clock (Hz) and load (per mille) twice a second, as "seconds clock load".
(
    t0=$(date +%s.%N)
    while sleep 0.5; do
        printf '%s %s %s\n' "$(LC_ALL=C awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN { printf "%.1f", a - b }')" \
            "$(cat "$GPU/cur_freq" 2> /dev/null || echo -)" "$(cat "$GPU_LOAD" 2> /dev/null || echo -)"
    done
) > "$record/gpu.txt" &
sampler=$!

result=PASS
finish() {
    kill "$sampler" 2> /dev/null
    wait "$sampler" 2> /dev/null
    printf 'YOLO_PROFILE=%s record=%s\n' "$result" "$record"
    exec 1>&3 2>&4
    wait "$tee_pid" 2> /dev/null
    [[ $result == PASS ]] && exit 0
    exit 1
}
trap 'printf "INTERRUPTED\n"; result=FAIL; finish' INT TERM
gpu_time() {  # LOG: the mean and median GPU time of trtexec's timing run
    local line
    line=$(grep -m 1 'GPU Compute Time:' "$1")
    printf '%s ms mean (%s median)' "$(grep -oE 'mean = [0-9.]+' <<< "$line" | grep -oE '[0-9.]+$')" \
        "$(grep -oE 'median = [0-9.]+' <<< "$line" | grep -oE '[0-9.]+$')"
}

engine=$record/$model-fp16.engine
printf '%s: building the FP16 engine with layer details (a few minutes with the timing cache), timing it (%s s), then the profile run\n' \
    "$model" "$TIME_SECONDS"
"$TRTEXEC" --onnx="$onnx" --fp16 "$workspace" \
    --timingCacheFile="$WORK/engines/timing.cache" --profilingVerbosity=detailed --saveEngine="$engine" \
    --exportLayerInfo="$record/layers.json" --dumpProfile "${separate[@]}" --exportProfile="$record/profile.json" \
    --warmUp=2000 --duration="$TIME_SECONDS" > "$record/trtexec-profile.txt" 2>&1
status=$?
grep -E 'Engine built in|Throughput:' "$record/trtexec-profile.txt" | sed 's/^/  /'
if (( status != 0 )) || [[ ! -s $record/profile.json || ! -s $record/layers.json ]]; then
    grep -E 'ERROR|Error|Could not find|failed' "$record/trtexec-profile.txt" | tail -n 8 | sed 's/^/  trtexec: /'
    printf 'BUILD_PROFILE=FAIL trtexec exit %s\n' "$status"
    result=FAIL
    finish
fi
printf 'BUILD_PROFILE=PASS GPU %s\n' "$(gpu_time "$record/trtexec-profile.txt")"

printf '%s: timing the same engine launched as a CUDA graph (%s s)\n' "$model" "$TIME_SECONDS"
if "$TRTEXEC" --loadEngine="$engine" --useCudaGraph --warmUp=2000 --duration="$TIME_SECONDS" \
        > "$record/trtexec-cudagraph.txt" 2>&1; then
    printf 'CUDA_GRAPH=PASS GPU %s\n' "$(gpu_time "$record/trtexec-cudagraph.txt")"
else
    grep -E 'ERROR|Error|failed' "$record/trtexec-cudagraph.txt" | tail -n 4 | sed 's/^/  trtexec: /'
    printf 'CUDA_GRAPH=FAIL\n'  # informative only: the profile stands without it
fi
kill "$sampler" 2> /dev/null
LC_ALL=C awk '$2 ~ /^[0-9]+$/ { n++; mhz = $2 / 1e6; if (!lo || mhz < lo) lo = mhz; if (mhz > hi) hi = mhz;
                       if ($3 ~ /^[0-9]+$/) { l += $3; nl++ } }
     END { if (n) printf "GPU_CLOCK %d samples, %.1f to %.1f MHz, load %.0f%% mean\n", n, lo, hi, nl ? l / nl / 10 : -1 }' \
    "$record/gpu.txt"

python3 -I "$here/trt-profile.py" "$record" "$SLOWEST" || result=FAIL
finish

#!/usr/bin/env bash
# Find which pieces of the depth model (Depth Anything V2 Metric Small)
# TensorRT 8.2 builds on the Nano, and whether TensorRT 8.5 builds the model
# in DINOv2's own layout.
#
# Usage, from an SSH login to the Nano, as your own account (no sudo), with
# this folder and the bundle from scripts/host/export-depth.py copied over:
#   bash probe-depth-trt.sh ~/depth-nano.tar
#
# Why: TensorRT 8.2 built no engine from the model in DINOv2's layout, in FP16
# or FP32 (setup-depth.sh, 2026-10-19): it handed the whole transformer to its
# Myelin compiler as one node, which found no implementation for it. The
# bundle's models now lay the tokens out for convolutions instead, as YOLO26's
# attention does; its probes are the first transformer block's pieces in both
# layouts (tokens-*: DINOv2's, conv-*: the models'). Needs OpenCV for Python 3,
# TensorRT 8.2 as the default (trt-default.sh) and, for step 3, nano-trt85
# with TensorRT 8.5's runner, which setup-yolo.sh keeps in ~/yolo/trt85.
#   1. the bundle, checked against its SHA256SUMS and unpacked into ~/depth,
#      with depth-cam.py and yolo-cam.py, as setup-depth.sh does;
#   2. each probe built by TensorRT 8.2's trtexec in FP16 with --verbose (no
#      engine kept), and what became of it: BUILT from TensorRT's own layers,
#      BUILT through Myelin (a ForeignNode), or NOT_BUILT, with the reason;
#   3. the -tokens model (DINOv2's layout) built by TensorRT 8.5's trtexec
#      through nano-trt85 in FP16 and timed for TIME_SECONDS, then
#      depth-cam.py --check on each test picture through TensorRT 8.5's
#      runner. Its engine goes to ~/depth/engines-8502 and is reused while
#      its model's SHA-256 is the same.
# Nothing is installed. The record goes to ~/depth/probe/<stamp>; the last
# line is DEPTH_PROBE=DONE when every step ran, whatever TensorRT built, or
# DEPTH_PROBE=FAIL when one could not run.
set -uo pipefail

KERNEL=5.10.216-tegra
TIME_SECONDS=20
WORKSPACE_MIB=1024
PROBE_SECONDS=900
BUILD_SECONDS=3600
TRTEXEC85=/usr/src/tensorrt/bin/trtexec
TOKENS=da2s-indoor-336x252-tokens
WORK=$HOME/depth
RUNNER85=$HOME/yolo/trt85/lib/libnano_trt.so

die() { printf 'DEPTH_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
bundle_tar=${1:-}
[[ $# -eq 1 ]] || die 'usage: bash probe-depth-trt.sh BUNDLE.tar'
[[ -f $bundle_tar ]] || die "no $bundle_tar"
[[ $(id -u) -ne 0 ]] || die 'run this as your own account, without sudo'
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for file in depth-cam.py yolo-cam.py trt-default.sh; do
    [[ -f $here/$file ]] || die "no $file next to this script"
done
for tool in python3 tar sha256sum timeout; do command -v "$tool" > /dev/null || die "no $tool"; done
python3 -c 'import cv2, numpy' 2> /dev/null || die 'no OpenCV for Python 3: sudo apt install python3-opencv'
. "$here/trt-default.sh"
trt_default || die 'no TensorRT to build for (the line above says why)'
[[ $TRT_VERSION == 8201 ]] || die "made for TensorRT 8.2 as the default (this default is $TRT_NAME)"
[[ -x $TRTEXEC ]] || die "no $TRTEXEC (TensorRT $TRT_NAME's trtexec)"
workspace=$(workspace_flag "$WORKSPACE_MIB")

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$WORK/probe/$stamp
mkdir -p "$WORK/probe" && mkdir "$record" "$record/probes" || die "cannot create $record"
exec 3>&1 4>&2
exec > >(tee "$record/summary.txt") 2>&1
tee_pid=$!
start=$(date +%s)
printf 'RECORD=%s\nKERNEL=%s\nTENSORRT=%s (%s)\n' "$record" "$(uname -r)" "$TRT_NAME" "$TRTEXEC"

result=DONE
failed=()
cannot() { printf '%s=FAIL %s\n' "$1" "$2"; result=FAIL; failed+=("$1"); }
finish() {
    printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
    if [[ $result == DONE ]]; then
        printf 'DEPTH_PROBE=DONE record=%s\n' "$record"
    else
        printf 'DEPTH_PROBE=FAIL %s record=%s\n' "${failed[*]}" "$record"
    fi
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    [[ $result == DONE ]] && exit 0
    exit 1
}
trap 'printf "INTERRUPTED\n"; result=FAIL; failed+=(INTERRUPTED); finish' INT TERM

# trtexec's log to one line: what became of the build.
outcome() {  # LOG STATUS
    local log=$1 status=$2 foreign
    foreign=$(grep -cF '{ForeignNode[' "$log")
    if (( status == 0 )) && grep -qE 'Engine (built|loaded|deserialized) in' "$log"; then
        (( foreign > 0 )) && printf 'BUILT through Myelin' || printf 'BUILT from its own layers'
    elif (( status == 124 || status == 137 )); then
        printf 'NOT_BUILT: no engine within the time limit'
    elif grep -q 'Could not find any implementation for node {ForeignNode' "$log"; then
        printf 'NOT_BUILT: Myelin found no implementation'
    else
        printf 'NOT_BUILT: %s' "$(grep -E '\[E\]|ERROR|Error' "$log" | head -n 1 | sed -E 's/^\[[^]]*\] //' | cut -c1-200)"
    fi
}

# --- 1. The bundle and the programs.
bundle=$WORK/depth-nano
rm -rf "$bundle" "$WORK/depth-nano.part"
mkdir "$WORK/depth-nano.part" && tar -xf "$bundle_tar" -C "$WORK/depth-nano.part" \
    && mv "$WORK/depth-nano.part/depth-nano" "$bundle" && rmdir "$WORK/depth-nano.part"
if [[ -f $bundle/SHA256SUMS ]] && (cd "$bundle" && sha256sum --quiet -c SHA256SUMS) > "$record/bundle.txt" 2>&1; then
    printf 'BUNDLE=PASS %s files, %s\n' "$(wc -l < "$bundle/SHA256SUMS")" "$(sha256sum "$bundle_tar" | cut -c1-16)"
else
    cannot BUNDLE "(unpacking or SHA256SUMS: $(head -n 3 "$record/bundle.txt" | tr '\n' ' '))"
    finish
fi
compgen -G "$bundle/probes/*.onnx" > /dev/null || { cannot BUNDLE 'no probes: an older bundle'; finish; }
for file in depth-cam.py yolo-cam.py; do
    [[ $here/$file -ef $WORK/$file ]] || cp "$here/$file" "$WORK/$file" || { cannot PROGRAMS "cannot copy $file"; finish; }
done

# --- 2. The probes, with TensorRT 8.2.
printf 'TensorRT %s: building each probe in FP16\n' "$TRT_NAME"
table=()
for onnx in "$bundle"/probes/*.onnx; do
    name=${onnx##*/}
    name=${name%.onnx}
    log=$record/probes/$name.trtexec.txt
    t0=$(date +%s)
    timeout -k 30 "$PROBE_SECONDS" "$TRTEXEC" --onnx="$onnx" --fp16 "$workspace" --buildOnly --verbose --dumpLayerInfo \
        > "$log" 2>&1
    status=$?
    seconds=$(( $(date +%s) - t0 ))
    what=$(outcome "$log" "$status")
    printf 'PROBE_%s=%s (%s s)\n' "$name" "$what" "$seconds"
    if [[ $what == NOT_BUILT* ]]; then
        grep -E '\[(W|E)\]' "$log" | grep -iE 'myelin|foreignnode' | grep -v 'Could not find any implementation' \
            | sed -E 's/^\[[^]]*\] //' | sort -u | head -n 3 | cut -c1-240 | sed 's/^/  trtexec: /'
    fi
    table+=("$name | $what | $seconds s")
done
gzip -f "$record"/probes/*.trtexec.txt

# --- 3. The model in DINOv2's layout, with TensorRT 8.5.
printf '\nTensorRT 8.5: the %s model\n' "$TOKENS"
engines85=$WORK/engines-8502
engine=$engines85/$TOKENS-fp16.engine
onnx=$bundle/models/$TOKENS.onnx
log=$record/trt85-$TOKENS.trtexec.txt
built85='' check85=() passed85=1
if ! command -v nano-trt85 > /dev/null || [[ ! -x $TRTEXEC85 ]]; then
    cannot TRT85 "no nano-trt85 or $TRTEXEC85 (install-trt82.sh installs nano-trt85 with TensorRT 8.2)"
elif [[ $(nano-trt85 python3 -I -c 'import ctypes, sys; print(ctypes.CDLL(sys.argv[1]).ntrt_version())' "$RUNNER85" \
        2> /dev/null) != 8502 ]]; then
    cannot TRT85 "no TensorRT 8.5 runner at $RUNNER85 (setup-yolo.sh moves it there when 8.2 becomes the default)"
elif [[ ! -f $onnx ]]; then
    cannot TRT85 "no $onnx in the bundle"
else
    mkdir -p "$engines85" && printf '8502\n' > "$engines85/TENSORRT"
    source_sum=$(sha256sum < "$onnx" | cut -c1-64)
    [[ $(cat "$engine.onnx-sha256" 2> /dev/null) == "$source_sum" ]] || rm -f "$engine" "$engine.onnx-sha256"
    timing=(--warmUp=2000 --duration="$TIME_SECONDS" --dumpLayerInfo)
    t0=$(date +%s)
    if [[ -f $engine ]]; then
        printf 'timing the engine built earlier (%s s)\n' "$TIME_SECONDS"
        nano-trt85 "$TRTEXEC85" --loadEngine="$engine" "${timing[@]}" > "$log" 2>&1
    else
        printf 'building the FP16 engine (several minutes, if it builds), then timing it (%s s)\n' "$TIME_SECONDS"
        timeout -k 30 "$BUILD_SECONDS" nano-trt85 "$TRTEXEC85" --onnx="$onnx" --fp16 \
            --memPoolSize=workspace:"$WORKSPACE_MIB" --timingCacheFile="$engines85/timing.cache" \
            --saveEngine="$engine.part" "${timing[@]}" > "$log" 2>&1 \
            && mv "$engine.part" "$engine" && printf '%s\n' "$source_sum" > "$engine.onnx-sha256"
    fi
    status=$?
    rm -f "$engine.part"
    seconds=$(( $(date +%s) - t0 ))
    built85=$(outcome "$log" "$status")
    [[ -f $engine ]] || [[ $built85 == NOT_BUILT* ]] || built85="NOT_BUILT: trtexec exit $status"
    grep -E 'Engine built in|Throughput:|GPU Compute Time:' "$log" | sed -E 's/^\[[^]]*\] \[I\] //' | sed 's/^/  /'
    printf 'TRT85_%s=%s (%s s)\n' "$TOKENS" "$built85" "$seconds"
    [[ $built85 == NOT_BUILT* ]] && grep -E 'ERROR|Error|Could not find|failed' "$log" | tail -n 4 | cut -c1-240 \
        | sed 's/^/  trtexec: /'
    if [[ -f $engine ]]; then
        for png in "$bundle"/test/*-640x480.png; do
            image=${png##*/}
            image=${image%-640x480.png}
            out=$record/trt85-$TOKENS.$image.check.txt
            nano-trt85 python3 "$WORK/depth-cam.py" --check "$png" "$bundle/test/$image.336x252.npy" \
                --engine "$engine" --lib "$RUNNER85" --save "$record/trt85-$TOKENS.$image.jpg" > "$out" 2>&1
            line=$(grep -E '^DEPTH_CHECK=' "$out" || echo 'DEPTH_CHECK=FAIL (no result line)')
            [[ $line == DEPTH_CHECK=PASS* ]] || grep -vE '^(TensorRT |depth |DEPTH_CHECK=)' "$out" | tail -n 5 \
                | sed 's/^/  check: /'
            printf 'TRT85_CHECK_%s=%s\n' "$image" "${line#DEPTH_CHECK=}"
            [[ $line == DEPTH_CHECK=PASS* ]] || passed85=0
            check85+=("$image $(grep -oE '^DEPTH_CHECK=[A-Z]+ abs_rel=[0-9.]+' <<< "$line" | sed 's/DEPTH_CHECK=//')")
        done
        (( passed85 )) && printf 'With it: nano-trt85 python3 %s/depth-cam.py --seconds 120 --engine %s --lib %s\n' \
            "$WORK" "$engine" "$RUNNER85"
    fi
fi

printf '\nprobe | TensorRT %s, FP16 | build\n' "$TRT_NAME"
printf '%s\n' "${table[@]}"
[[ -n $built85 ]] && printf 'TensorRT 8.5, %s, FP16: %s; %s\n' "$TOKENS" "$built85" "${check85[*]:-no checks}"
finish

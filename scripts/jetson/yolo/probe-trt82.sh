#!/usr/bin/env bash
# Try JetPack 4's TensorRT 8.2 on a YOLO26 model on the Nano, from a scratch
# folder, against the installed TensorRT 8.5.
#
# Usage, from an SSH login to the Nano, as your own account (no sudo), after
# setup-yolo.sh, with this folder copied over:
#   bash probe-trt82.sh INPUTS_DIR BUNDLE.tar [MODEL]
# INPUTS_DIR is the folder scripts/host/fetch-r35-cuda.py --set tensorrt
# --release r32.7 wrote (TensorRT 8.2 with trtexec, cuDNN 8.2, cuBLAS 10.2, the
# CUDA 10.2 runtime and NVRTC, from JetPack 4's signed index); BUNDLE.tar is
# the bundle from scripts/host/export-yolo26.py with opset 13 models (the
# newest TensorRT 8.2 reads); MODEL is one of its models, yolo26n-640x480-raw
# by default (the one yolo-cam.py ran live).
#
# Why: TensorRT 8.5 has no convolution kernels of its own for the Nano's GPU
# (sm_53) and falls back to cuDNN (profile-yolo.sh, 2026-10-19), while
# JetPack 4's 8.2 was built for it. Nothing is installed and no system file
# changes: the .debs are only unpacked, with dpkg-deb -x, and run on the
# installed R35.6 driver (libcuda), as JetPack 4's CUDA 10.2 programs did
# (2026-10-15). Into ~/yolo/trt82:
#   1. root: the inputs, checked against their SHA256SUMS and versions, then
#      unpacked (kept for the next run while the inputs are the same), and
#      the bundle, checked against its SHA256SUMS;
#   2. run: a launcher that puts TensorRT 8.2's libraries first for any
#      command, such as yolo-cam.py;
#   3. every library trtexec and the unpacked libraries link resolves:
#      TensorRT's, cuDNN's, cuBLAS's and the CUDA runtime's in root, the
#      driver's from the system. An NVIDIA library that neither has (JetPack
#      4's libnvmedia.so on the Nano) gets a stand-in in stand-in/ with a stub
#      for each symbol TensorRT takes from it that no library here defines;
#      the stubs are listed, and so is any call to one during the runs;
#   4. engines: the model's FP16 engine built by TensorRT 8.2's own trtexec
#      (many minutes the first time; its timing cache is timing.cache), timed
#      for TIME_SECONDS and run once more with a timer on every layer; then the
#      same model built by the installed TensorRT 8.5 with setup-yolo.sh's
#      settings and timing cache, timed the same way. Engines already built
#      are reused;
#   5. lib/libnano_trt82.so: nano_trt.cpp built against TensorRT 8.2.1's
#      runtime headers (github.com/NVIDIA/TensorRT, tag 8.2.1, Apache-2.0;
#      fetched and checked against the SHA-256 values below) and root's
#      libraries;
#   6. yolo-cam.py --check on each test picture against Ultralytics' own
#      detections, for both engines (8.2's through the launcher with --lib).
# yolo-cam.py is copied to ~/yolo, as setup-yolo.sh does. Every TensorRT 8.2
# run records the libraries it loaded (LD_DEBUG) and requires TensorRT's,
# cuDNN's, cuBLAS's and the CUDA runtime's to come from root. Needs
# trt-profile.py, nano_trt.cpp, include/cuda_runtime_api.h and yolo-cam.py
# next to it. It stops once nano-trt82 is installed (package-trt82.sh), which
# makes 8.2 the default. The record goes to ~/yolo/trt82-probe/<stamp>; the
# last line is TRT82_PROBE=PASS or FAIL. Undo: rm -rf ~/yolo/trt82
set -uo pipefail

KERNEL=5.10.216-tegra
TRTEXEC85=/usr/src/tensorrt/bin/trtexec
TIME_SECONDS=20
PROFILE_SECONDS=10
BUILD_SECONDS=5400
WORKSPACE_MIB=1024
SLOWEST=20
# The .debs taken from the inputs; their versions are checked below.
PACKAGES='libnvinfer[a-z0-9-]*|libnvonnxparsers[0-9]+|libnvparsers[0-9]+|libcudnn[0-9]+|libcublas10|cuda-[a-z0-9-]+-10-2'
REQUIRED=(libnvinfer-bin libnvinfer8 libnvinfer-plugin8 libnvonnxparsers8 libcudnn8 libcublas10 cuda-cudart-10-2)
# Libraries that must come from root, never from the installed JetPack 5 stack.
TRT_LIBS='^lib(nvinfer|nvonnxparser|nvparsers|cudnn|cublas|cudart|nvrtc|myelin)'
TRT_URL=https://raw.githubusercontent.com/NVIDIA/TensorRT/6f38570b74066ef464744bc789f8512191f1cbc0/include
HEADERS=(  # TensorRT 8.2.1's headers that NvInferRuntime.h reads
    8882e5224424a336b546d3d53d192c4f9bb3d1cd297a07014fa77e16002c4383:NvInferRuntime.h
    9bce40c59b3236fe44ec10d2152e95f4d88dcc7c51f46bb646515901fb58a2d7:NvInferImpl.h
    d5415ce5902eb657cdd17ec1dbe707ede333e0829942ccf6e4ed82968d760ccf:NvInferRuntimeCommon.h
    3ec3cd66689a74d34049456976c270f0e4d86a319f8d682201ce454cc910ede8:NvInferVersion.h
    856cd6fa36bc855dfda61a06bc0fca82dc16d54b49bc844fee244f731aadf6f6:NvInferLegacyDims.h
)
WORK=$HOME/yolo
TRT=$WORK/trt82

die() { printf 'TRT82_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
inputs=${1:-} bundle_tar=${2:-} model=${3:-yolo26n-640x480-raw}
[[ $# -ge 2 && $# -le 3 && $model != -* ]] || die 'usage: bash probe-trt82.sh INPUTS_DIR BUNDLE.tar [MODEL]'
[[ -d $inputs ]] || die "no inputs folder $inputs"
inputs=$(cd "$inputs" && pwd)
[[ -f $bundle_tar ]] || die "no $bundle_tar"
[[ $(id -u) -ne 0 ]] || die 'run this as your own account, without sudo'
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for file in trt-profile.py nano_trt.cpp include/cuda_runtime_api.h yolo-cam.py; do
    [[ -f $here/$file ]] || die "no $file next to this script"
done
for tool in python3 tar sha256sum dpkg-deb ldd; do command -v "$tool" > /dev/null || die "no $tool"; done
python3 -c 'import cv2, numpy' 2> /dev/null || die 'no OpenCV for Python 3: sudo apt install python3-opencv'
cxx=$(command -v g++-11 || command -v g++) || die 'no C++ compiler: sudo bash add-u26-gcc11.sh (or sudo apt install g++)'
cc=$(command -v gcc-11 || command -v gcc || command -v cc) || die 'no C compiler'
[[ -x $TRTEXEC85 ]] || die "no $TRTEXEC85 (TensorRT 8.5 from install-u26-r35.sh)"
[[ $(dpkg-query -W -f '${db:Status-Abbrev}' nano-trt82 2> /dev/null) != ii* ]] \
    || die 'nano-trt82 is installed, so TensorRT 8.2 is the default: setup-yolo.sh builds and checks its engines (this probe compares a copy of it with TensorRT 8.5 as the default)'
[[ -f $WORK/lib/libnano_trt.so ]] || die "no $WORK/lib/libnano_trt.so (run setup-yolo.sh first)"
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
"$ldconfig" -p | grep -q 'libcuda\.so\.1 .*AArch64' || die 'ldconfig knows no libcuda.so.1 (the R35.6 driver from install-u26-r35.sh)'

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$WORK/trt82-probe/$stamp
mkdir -p "$WORK/trt82-probe" "$TRT/engines" "$TRT/lib" "$TRT/include" && mkdir "$record" \
    || die "cannot create $record"
exec 3>&1 4>&2
exec > >(tee "$record/summary.txt") 2>&1
tee_pid=$!
start=$(date +%s)
printf 'RECORD=%s\nMODEL=%s\nKERNEL=%s\nINPUTS=%s\n' "$record" "$model" "$(uname -r)" "$inputs"
gpu=/sys/class/devfreq/57000000.gpu
printf 'GPU governor=%s clock=%s max=%s Hz\n' "$(cat "$gpu/governor" 2> /dev/null)" \
    "$(cat "$gpu/cur_freq" 2> /dev/null)" "$(cat "$gpu/max_freq" 2> /dev/null)"
grep -E '^(MemTotal|MemAvailable|SwapFree):' /proc/meminfo | tr -s ' ' | tr '\n' ' '; echo

result=PASS
failed=()
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS* ]] || { result=FAIL; failed+=("$1"); }; }
finish() {
    rm -f "$TRT"/engines/*.part "$TRT/lib/libnano_trt82.so.part"
    printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
    if [[ $result == PASS ]]; then
        printf 'Next, live with TensorRT 8.2: %s/run python3 %s/yolo-cam.py --seconds 120 --engine %s --lib %s\n' \
            "$TRT" "$WORK" "$engine82" "$TRT/lib/libnano_trt82.so"
        printf 'TRT82_PROBE=PASS record=%s\n' "$record"
    else
        printf 'TRT82_PROBE=FAIL %s record=%s\n' "${failed[*]}" "$record"
    fi
    printf 'Undo: rm -rf %s\n' "$TRT"
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    [[ $result == PASS ]] && exit 0
    exit 1
}
trap 'printf "INTERRUPTED\n"; result=FAIL; failed+=(INTERRUPTED); finish' INT TERM
fail() { check "$1" "FAIL $2"; finish; }

# --- 1. The inputs, as the PC wrote them, and the bundle.
if (cd "$inputs" && sha256sum --quiet -c SHA256SUMS) > "$record/inputs-sha256.txt" 2>&1; then
    check INPUTS_SHA256 "PASS $(grep -c '\.deb$' "$inputs/SHA256SUMS") packages"
else
    sed 's/^/  /' "$record/inputs-sha256.txt" | head -n 8
    fail INPUTS_SHA256 "$inputs"
fi
cp "$inputs/SHA256SUMS" "$record/inputs-SHA256SUMS"
shopt -s nullglob
debs=() names=()
for deb in "$inputs"/*.deb; do
    if ! [[ $(basename "$deb") =~ ^($PACKAGES)_ ]]; then
        printf 'NOT_TAKEN=%s\n' "$(basename "$deb")"
        continue
    fi
    package=$(dpkg-deb -f "$deb" Package) version=$(dpkg-deb -f "$deb" Version)
    case $package in
        libnvinfer*|libnvonnxparsers*|libnvparsers*|libcudnn*) want='8.2.*' ;;
        *) want='10.2.*' ;;
    esac
    # shellcheck disable=SC2053  # $want is a pattern
    [[ $version == $want ]] || fail PACKAGES "$(basename "$deb") is $version, not $want"
    [[ " ${names[*]} " != *" $package "* ]] || fail PACKAGES "two .debs of $package"
    names+=("$package") debs+=("$deb")
    printf 'DEB=%s %s\n' "$package" "$version"
done
for package in "${REQUIRED[@]}"; do
    [[ " ${names[*]} " == *" $package "* ]] || fail PACKAGES "no $package .deb in $inputs"
done
check PACKAGES "PASS ${#debs[@]} packages"

if [[ -f $TRT/root.SHA256SUMS && -d $TRT/root ]] && cmp -s "$inputs/SHA256SUMS" "$TRT/root.SHA256SUMS"; then
    check UNPACK 'PASS kept from the last run (same inputs)'
else
    need=0
    for deb in "${debs[@]}"; do
        size=$(dpkg-deb -f "$deb" Installed-Size)
        need=$(( need + ${size:-0} ))
    done
    need=$(( need / 1024 + 1024 ))
    rm -rf "$TRT/root" "$TRT/root.part" "$TRT/root.SHA256SUMS"
    free=$(python3 -I -c 'import os, sys; s = os.statvfs(sys.argv[1]); print(s.f_bavail * s.f_frsize >> 20)' "$TRT")
    printf 'SPACE=%s MiB free, %s MiB needed\n' "$free" "$need"
    (( free >= need )) || fail UNPACK "not enough space in $TRT: $free MiB free, $need MiB needed"
    mkdir "$TRT/root.part" || fail UNPACK "cannot create $TRT/root.part"
    for deb in "${debs[@]}"; do
        dpkg-deb -x "$deb" "$TRT/root.part" || fail UNPACK "dpkg-deb could not unpack $deb"
    done
    mv "$TRT/root.part" "$TRT/root" && cp "$inputs/SHA256SUMS" "$TRT/root.SHA256SUMS" || fail UNPACK "cannot move $TRT/root.part"
    check UNPACK "PASS $(du -sm "$TRT/root" | cut -f1) MiB in $TRT/root"
fi
root=$TRT/root

bundle=$TRT/yolo26-nano
rm -rf "$bundle" "$bundle.part"
mkdir "$bundle.part" && tar -xf "$bundle_tar" -C "$bundle.part" && mv "$bundle.part/yolo26-nano" "$bundle" \
    && rmdir "$bundle.part"
if [[ -f $bundle/SHA256SUMS ]] && (cd "$bundle" && sha256sum --quiet -c SHA256SUMS) > "$record/bundle.txt" 2>&1; then
    check BUNDLE "PASS $(wc -l < "$bundle/SHA256SUMS") files, $(sha256sum "$bundle_tar" | cut -c1-16)"
else
    fail BUNDLE "unpacking or SHA256SUMS: $(head -n 3 "$record/bundle.txt" | tr '\n' ' ')"
fi
grep -q 'opset 13' "$bundle/README.txt" \
    || fail BUNDLE "its models are not opset 13 ($(grep -o 'opset [0-9]*' "$bundle/README.txt" | head -n 1)); export them again"
onnx=$bundle/models/$model.onnx
[[ -f $onnx ]] || fail BUNDLE "no $model in the bundle"

# --- 2. The launcher and 3. the libraries.
dirs=()
while IFS= read -r dir; do
    [[ $dir == */stubs ]] || dirs+=("$dir")
done < <(find "$root" \( -type f -o -type l \) -name 'lib*.so*' -printf '%h\n' | sort -u)
(( ${#dirs[@]} )) || fail LIBRARIES "no libraries in $root"
"$ldconfig" -n "${dirs[@]}" 2>&1 | sed 's/^/LDCONFIG: /'
rm -rf "$TRT/stand-in" && mkdir "$TRT/stand-in"
libdirs=$(IFS=:; echo "${dirs[*]}"):$TRT/stand-in
printf 'LIBDIR=%s\n' "${dirs[@]#"$TRT/"}"
cat > "$TRT/run" << EOF
#!/bin/sh
# probe-trt82.sh's launcher: runs a command with JetPack 4's TensorRT 8.2, cuDNN 8.2,
# cuBLAS 10.2 and CUDA 10.2 runtime from $root ahead of the installed ones.
LD_LIBRARY_PATH='$libdirs'\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export LD_LIBRARY_PATH
exec "\$@"
EOF
chmod +x "$TRT/run"
trtexec82=$(find "$root" -type f -name trtexec | head -n 1)
[[ -n $trtexec82 ]] || fail LIBRARIES 'no trtexec in the packages (libnvinfer-bin)'
nvinfer82=$(find "${dirs[@]}" -maxdepth 1 -name libnvinfer.so.8 | head -n 1)
cudart102=$(find "${dirs[@]}" -maxdepth 1 -name libcudart.so.10.2 | head -n 1)
[[ -n $nvinfer82 && -n $cudart102 ]] || fail LIBRARIES 'no libnvinfer.so.8 or libcudart.so.10.2 in the packages'

ldd_all() {  # every library trtexec and the unpacked libraries link, as "file lib path"
    local file
    while IFS= read -r file; do
        LD_LIBRARY_PATH=$libdirs ldd "$file" 2>&1 | awk -v f="${file##*/}" '$2 == "=>" { print f, $1, $3 }'
    done < <(printf '%s\n' "$trtexec82"; find "${dirs[@]}" -maxdepth 1 -type f -name 'lib*.so*' | sort)
}
ldd_all > "$record/ldd.txt"
# NVIDIA libraries no one has: an empty stand-in each (no functions; enough only if never called).
while read -r lib; do
    "$cc" -shared -fPIC -x c /dev/null -Wl,-soname,"$lib" -o "$TRT/stand-in/$lib" > "$record/stand-in.txt" 2>&1 \
        || fail LIBRARIES "cannot build a stand-in for $lib: $(head -n 2 "$record/stand-in.txt")"
    printf 'STAND_IN=%s (needed by %s; empty)\n' "$lib" \
        "$(awk -v l="$lib" '$2 == l && $3 == "not" { print $1 }' "$record/ldd.txt" | sort -u | xargs)"
done < <(awk '$3 == "not" && $2 ~ /^libnv/ { print $2 }' "$record/ldd.txt" | grep -vE "$TRT_LIBS" | sort -u)
[[ -n $(ls "$TRT/stand-in") ]] && ldd_all > "$record/ldd.txt"
bad=$(awk -v root="$TRT/" -v trt="$TRT_LIBS" '
    $3 == "not" { printf "UNRESOLVED %s (needed by %s)\n", $2, $1; next }
    $2 ~ trt && index($3, root) != 1 { printf "OUTSIDE %s => %s (needed by %s)\n", $2, $3, $1 }' "$record/ldd.txt" | sort -u)
printf 'FROM_SYSTEM=%s\n' "$(awk -v root="$TRT/" '$3 ~ /^\// && index($3, root) != 1 && $2 ~ /^lib(nv|cuda)/ { print $2 "=>" $3 }' \
    "$record/ldd.txt" | sort -u | xargs)"
if [[ -n $bad ]]; then
    printf '%s\n' "$bad" | head -n 20
    fail LIBRARIES "$(grep -c . <<< "$bad") problems (rm -rf $root to unpack the inputs again)"
fi
# TensorRT 8.2 binds its symbols at load (inferred: on the Nano, 2026-10-19,
# even trtexec --help stopped on the first NvMedia function), so what it takes
# from a stand-in, or from a driver library of another release, must exist.
# Each symbol no library here defines becomes a stub in the first stand-in,
# which says on stderr when it is called and returns an error
# (NVMEDIA_STATUS_NOT_SUPPORTED; a null handle for NvMedia*Create*). Except
# the DLA count: TensorRT 8.2 creates its builder only after NvMedia gives it
# a DLA handle and an engine count (on the Nano, 2026-10-19: "Assertion tmp
# != nullptr failed. dla creation failure"), so NvMediaDlaCreate gives a
# handle nothing else accepts, NvMediaDlaGetNumEngines counts no engines and
# NvMediaDlaDestroy takes the handle back, as JetPack 4's NvMedia must on a
# Nano, which has no DLA (inferred: TensorRT 8.2 builds there).
unbound() {  # every symbol the dynamic linker cannot bind, as "symbol referencing-file"
    local file
    while IFS= read -r file; do
        LD_LIBRARY_PATH=$libdirs ldd -r "$file" 2>&1 | awk '
            $1 == "undefined" && $2 == "symbol:" { n = split($NF, p, "/"); sub(/\)$/, "", p[n]); print $3, p[n] }
            / version .* not defined in file / { print "VERSIONED:" $2 "@" $4, $NF }'
    done < <(printf '%s\n' "$trtexec82"; find "${dirs[@]}" -maxdepth 1 -type f -name 'lib*.so*' | sort) | sort -u
}
unbound > "$record/unbound.txt"
if [[ -s $record/unbound.txt ]]; then
    first=$(find "$TRT/stand-in" -maxdepth 1 -name 'lib*' -printf '%f\n' | sort | head -n 1)
    if [[ -z $first ]] || grep -q '^VERSIONED:' "$record/unbound.txt"; then
        sed 's/^/  UNBOUND /' "$record/unbound.txt" | head -n 20
        fail LIBRARIES "$(awk '{ print $1 }' "$record/unbound.txt" | sort -u | grep -c .) symbols no library here defines"
    fi
    python3 -I - "$record/unbound.txt" "$record/stubs.c" << 'EOF' || fail LIBRARIES 'cannot write the stubs'
import sys
names = sorted({line.split()[0] for line in open(sys.argv[1]) if line.strip()})
out = ['/* probe-trt82.sh: symbols TensorRT 8.2 binds at load that no library here defines. */',
       '#include <stdint.h>',
       '#include <stdio.h>',
       'static void called(int *once, const char *name) {',
       '    if (!(*once)++) fprintf(stderr, "probe-trt82 stand-in: %s called\\n", name);',
       '}',
       'static long dla[64];  /* the one DLA handle: accepted only by the count and Destroy */']
# No DLA: a handle, no engines (the count comes second, after the handle, or first).
dla = {'NvMediaDlaCreate': 'return (long)dla;',
       'NvMediaDlaDestroy': 'return a == dla ? 0 : 1;',
       'NvMediaDlaGetNumEngines': 'uint16_t *n = a == dla ? b : a; if (!n) return 1; *n = 0; return 0;'}
for i, name in enumerate(names):
    value = 0 if not name.startswith('NvMedia') or 'Create' in name else 6
    body = dla.get(name, f'return {value};')
    out += [f'long s{i}(void *a, void *b) __asm__("{name}");',
            f'long s{i}(void *a, void *b) {{ static int once; (void)a; (void)b; called(&once, "{name}"); {body} }}']
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
EOF
    "$cc" -shared -fPIC -O1 -Wl,-soname,"$first" -o "$TRT/stand-in/$first" "$record/stubs.c" > "$record/stand-in.txt" 2>&1 \
        || fail LIBRARIES "cannot build the stubs: $(head -n 2 "$record/stand-in.txt")"
    printf 'STUBS=%s symbols in the %s stand-in: %s\n' "$(awk '{ print $1 }' "$record/unbound.txt" | sort -u | grep -c .)" \
        "$first" "$(awk '{ print $1 }' "$record/unbound.txt" | sort -u | head -n 8 | xargs)"
    unbound > "$record/unbound-after.txt"
    if [[ -s $record/unbound-after.txt ]]; then
        sed 's/^/  UNBOUND /' "$record/unbound-after.txt" | head -n 20
        fail LIBRARIES 'symbols still unbound after the stubs'
    fi
fi
check LIBRARIES "PASS TensorRT 8.2's libraries from $root, the driver's from the system"

lib_mix() {  # NAME [quiet]: the libraries the run NAME loaded, from its LD_DEBUG files
    local loaded=$record/$1-loaded.txt path wrong=()
    cat "$record/ld-$1".* 2> /dev/null | grep -E 'calling init: |object=|scope [0-9]+:' \
        | grep -oE '/[^ ]+\.so[.0-9]*' | sort -u > "$loaded"
    rm -f "$record/ld-$1".*
    [[ -s $loaded ]] || { printf '%s: LIB_MIX=FAIL the linker recorded nothing\n' "$1"; return 1; }
    while read -r path; do
        [[ $(basename "$path") =~ $TRT_LIBS && $path != "$TRT"/* ]] && wrong+=("$path")
    done < "$loaded"
    [[ ${2:-} == quiet ]] || printf '%s: DRIVER=%s\n' "$1" \
        "$(grep -vF "$TRT/" "$loaded" | grep -E '/lib(nv|cuda)[^/]*$' | xargs -r -n 1 basename | tr '\n' ' ')"
    if (( ${#wrong[@]} )); then
        printf '%s: LIB_MIX=FAIL %s\n' "$1" "${wrong[*]}"
        return 1
    fi
    [[ ${2:-} == quiet ]] || printf '%s: LIB_MIX=PASS TensorRT, cuDNN, cuBLAS and CUDA runtime from %s\n' "$1" "$root"
}
stub_calls() {  # LOG: the stand-in functions a TensorRT 8.2 run called
    local called
    called=$(grep -h '^probe-trt82 stand-in: ' "$1" | sed -E 's/^probe-trt82 stand-in: (.*) called$/\1/' | sort -u | xargs)
    [[ -z $called ]] || printf '  STUB_CALLED %s\n' "$called"
}
gpu_time() {  # LOG: the mean and median GPU time of trtexec's timing run
    local line
    line=$(grep -m 1 -E 'GPU Compute( Time)?:' "$1")
    printf '%s %s' "$(grep -oE 'mean = [0-9.]+' <<< "$line" | grep -oE '[0-9.]+$')" \
        "$(grep -oE 'median = [0-9.]+' <<< "$line" | grep -oE '[0-9.]+$')"
}

# --- 4. Engines. TensorRT 8.2 first: its own trtexec through the launcher.
help=$("$TRT/run" "$trtexec82" --help 2>&1)
has() { grep -q -- "$1" <<< "$help"; }
printf 'TRTEXEC82=%s %s\n' "${trtexec82#"$TRT/"}" "$(grep -m 1 -oE 'TensorRT v[0-9]+' <<< "$help")"
if has --memPoolSize; then workspace=--memPoolSize=workspace:$WORKSPACE_MIB; else workspace=--workspace=$WORKSPACE_MIB; fi
details=()
has --profilingVerbosity && details+=(--profilingVerbosity=detailed)
has --exportLayerInfo && details+=(--exportLayerInfo="$record/trt82/layers.json")
cache=()
has --timingCacheFile && cache+=(--timingCacheFile="$TRT/timing.cache")
mkdir "$record/trt82"
engine82=$TRT/engines/$model-trt82-fp16.engine
log=$record/trt82-build.txt
t0=$(date +%s)
if [[ -f $engine82 ]]; then
    built82=reused
    printf 'TensorRT 8.2: timing the engine built earlier (%s s)\n' "$TIME_SECONDS"
    LD_DEBUG=libs,scopes LD_DEBUG_OUTPUT=$record/ld-trt82 "$TRT/run" "$trtexec82" --loadEngine="$engine82" "${details[@]}" \
        --warmUp=2000 --duration="$TIME_SECONDS" > "$log" 2>&1
else
    built82=built
    printf 'TensorRT 8.2: building the FP16 engine (many minutes the first time), then timing it (%s s)\n' "$TIME_SECONDS"
    LD_DEBUG=libs,scopes LD_DEBUG_OUTPUT=$record/ld-trt82 timeout -k 30 "$BUILD_SECONDS" "$TRT/run" "$trtexec82" \
        --onnx="$onnx" --fp16 "$workspace" "${cache[@]}" "${details[@]}" --saveEngine="$engine82.part" \
        --warmUp=2000 --duration="$TIME_SECONDS" > "$log" 2>&1 && mv "$engine82.part" "$engine82"
fi
status=$?
rm -f "$engine82.part"
seconds82=$(( $(date +%s) - t0 ))
grep -E 'TensorRT version|Compute Capability|Engine built in|Throughput:|GPU Compute( Time)?:' "$log" \
    | sed -E 's/^\[[^]]*\] \[I\] //' | cut -c1-160 | sed 's/^/  /'
lib_mix trt82 || { result=FAIL; failed+=(LIB_MIX_trt82); }
stub_calls "$log"
read -r mean82 median82 <<< "$(gpu_time "$log")"
if (( status != 0 )) || [[ ! -f $engine82 ]]; then
    grep -E 'ERROR|Error|error|Could not find|failed|symbol lookup|cannot open' "$log" | tail -n 10 | cut -c1-240 | sed 's/^/  trtexec: /'
    fail ENGINE_trt82 "trtexec exit $status after $seconds82 s"
fi
[[ -n $mean82 ]] || fail ENGINE_trt82 "no GPU time in $log"
check ENGINE_trt82 "PASS $built82 and timed in $seconds82 s, GPU $mean82 ms mean ($median82 median)"

printf 'TensorRT 8.2: running the engine once more with a timer on every layer (%s s)\n' "$PROFILE_SECONDS"
LD_DEBUG=libs,scopes LD_DEBUG_OUTPUT=$record/ld-trt82-profile "$TRT/run" "$trtexec82" --loadEngine="$engine82" \
    --dumpProfile --exportProfile="$record/trt82/profile.json" --warmUp=500 --duration="$PROFILE_SECONDS" \
    > "$record/trt82-profile.txt" 2>&1
status=$?
lib_mix trt82-profile quiet || { result=FAIL; failed+=(LIB_MIX_trt82-profile); }
stub_calls "$record/trt82-profile.txt"
if (( status == 0 )) && [[ -s $record/trt82/profile.json ]]; then
    printf 'PROFILE_trt82=PASS\n'
else
    printf 'PROFILE_trt82=FAIL trtexec exit %s (reported, not required)\n' "$status"
fi

# The same model with the installed TensorRT 8.5, as setup-yolo.sh builds it.
engine85=$TRT/engines/$model-trt85-fp16.engine
log=$record/trt85-build.txt
t0=$(date +%s)
if [[ -f $engine85 ]]; then
    built85=reused
    printf 'TensorRT 8.5: timing the engine built earlier (%s s)\n' "$TIME_SECONDS"
    "$TRTEXEC85" --loadEngine="$engine85" --warmUp=2000 --duration="$TIME_SECONDS" > "$log" 2>&1
else
    built85=built
    printf 'TensorRT 8.5: building the FP16 engine from the same file (a few minutes with the timing cache), then timing it (%s s)\n' \
        "$TIME_SECONDS"
    timeout -k 30 "$BUILD_SECONDS" "$TRTEXEC85" --onnx="$onnx" --fp16 --memPoolSize=workspace:$WORKSPACE_MIB \
        --timingCacheFile="$WORK/engines/timing.cache" --saveEngine="$engine85.part" \
        --warmUp=2000 --duration="$TIME_SECONDS" > "$log" 2>&1 && mv "$engine85.part" "$engine85"
fi
status=$?
rm -f "$engine85.part"
seconds85=$(( $(date +%s) - t0 ))
grep -E 'Engine built in|Throughput:|GPU Compute Time:' "$log" | sed -E 's/^\[[^]]*\] \[I\] //' | sed 's/^/  /'
read -r mean85 median85 <<< "$(gpu_time "$log")"
if (( status != 0 )) || [[ ! -f $engine85 || -z $mean85 ]]; then
    grep -E 'ERROR|Error|Could not find|failed' "$log" | tail -n 8 | cut -c1-240 | sed 's/^/  trtexec: /'
    check ENGINE_trt85 "FAIL trtexec exit $status after $seconds85 s"
else
    check ENGINE_trt85 "PASS $built85 and timed in $seconds85 s, GPU $mean85 ms mean ($median85 median)"
fi

# --- 5. The runner for TensorRT 8.2's engines.
bad=()
for entry in "${HEADERS[@]}"; do
    sum=${entry%%:*} name=${entry#*:} path=$TRT/include/${entry#*:}
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
(( ${#bad[@]} == 0 )) \
    || fail HEADERS "${bad[*]} (fetched from raw.githubusercontent.com: $(tail -n 1 "$record/headers.txt" 2> /dev/null))"
cp "$here/include/cuda_runtime_api.h" "$TRT/include/cuda_runtime_api.h" || fail HEADERS 'cannot copy cuda_runtime_api.h'
check HEADERS "PASS TensorRT $(awk '/define NV_TENSORRT_(MAJOR|MINOR|PATCH) /{ printf "%s%s", s, $3; s="." }' \
    "$TRT/include/NvInferVersion.h")"
lib82=$TRT/lib/libnano_trt82.so
if "$cxx" -std=c++14 -O2 -Wall -Wno-deprecated-declarations -fPIC -shared -isystem "$TRT/include" -o "$lib82.part" \
        "$here/nano_trt.cpp" "$nvinfer82" "$cudart102" -ldl -Wl,--no-undefined -Wl,-rpath-link,"$libdirs" \
        > "$record/runner-build.txt" 2>&1 \
    && mv "$lib82.part" "$lib82" \
    && version=$("$TRT/run" python3 -I -c 'import ctypes, sys; print(ctypes.CDLL(sys.argv[1]).ntrt_version())' \
        "$lib82" 2>> "$record/runner-build.txt") && [[ $version == 82* ]]; then
    check RUNNER "PASS libnano_trt82.so, TensorRT library $version"
else
    sed 's/^/  build: /' "$record/runner-build.txt" | tail -n 12
    fail RUNNER "libnano_trt82.so (TensorRT library ${version:-not loaded})"
fi

# --- 6. Detections against Ultralytics', for each engine.
[[ $here/yolo-cam.py -ef $WORK/yolo-cam.py ]] || cp "$here/yolo-cam.py" "$WORK/yolo-cam.py" \
    || fail CHECKS "cannot copy yolo-cam.py to $WORK"
declare -A checks=([trt82]='' [trt85]='')
for json in "$bundle/test/$model".*.json; do
    image=${json%.json}
    image=${image##*.}
    for trt in trt82 trt85; do
        out=$record/$trt.$image.check.txt
        if [[ $trt == trt82 ]]; then
            LD_DEBUG=libs,scopes LD_DEBUG_OUTPUT=$record/ld-check-$image "$TRT/run" python3 "$WORK/yolo-cam.py" \
                --check "$bundle/test/$image-640x480.png" "$json" --engine "$engine82" --lib "$lib82" > "$out" 2>&1
            lib_mix "check-$image" quiet || { result=FAIL; failed+=("LIB_MIX_check-$image"); }
            stub_calls "$out"
        elif [[ -f $engine85 ]]; then
            python3 "$WORK/yolo-cam.py" --check "$bundle/test/$image-640x480.png" "$json" --engine "$engine85" \
                > "$out" 2>&1
        else
            continue
        fi
        line=$(grep -E '^YOLO_CHECK=' "$out" || echo 'YOLO_CHECK=FAIL (no result line)')
        grep -E '^  (match|MISSING|EXTRA)' "$out" | sed "s/^/  $trt $image:/"
        [[ $line == YOLO_CHECK=PASS* ]] || tail -n 5 "$out" | sed 's/^/  check: /'
        check "CHECK_${trt}_$image" "${line#YOLO_CHECK=}"
        verdict=${line#YOLO_CHECK=}
        checks[$trt]+="$image ${verdict%% *}, "
    done
done
[[ -n ${checks[trt82]} ]] || check CHECKS "FAIL no test pictures for $model in the bundle"

# --- The comparison.
printf '\nTensorRT | engine, then timed | GPU per picture, mean (median) | check\n'
printf '8.2 (JetPack 4, ~/%s) | %s, %s s | %s ms (%s) | %s\n' "${root#"$HOME/"}" "$built82" "$seconds82" "$mean82" \
    "$median82" "${checks[trt82]%, }"
printf '8.5 (JetPack 5, installed) | %s, %s s | %s ms (%s) | %s\n' "$built85" "$seconds85" "${mean85:-?}" \
    "${median85:-?}" "${checks[trt85]%, }"
[[ -n ${mean85:-} ]] && LC_ALL=C awk -v a="$mean85" -v b="$mean82" \
    'BEGIN { if (b > 0) printf "SPEEDUP=%.2f (TensorRT 8.5 mean / 8.2 mean)\n", a / b }'
if [[ -s $record/trt82/profile.json ]]; then
    printf '\nTensorRT 8.2, per layer:\n'
    python3 -I "$here/trt-profile.py" "$record/trt82" "$SLOWEST" || printf 'PROFILE_SUMMARY=FAIL (reported, not required)\n'
fi
finish

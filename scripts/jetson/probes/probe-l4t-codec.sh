#!/usr/bin/env bash
# Try the Nano's hardware video codecs (NVDEC, NVENC and NVJPG) with
# JetPack 4's GStreamer elements (L4T R32.7.6) or JetPack 5's (L4T R35.6) from
# a scratch folder, or as nano-l4t-r32-video or nano-l4t-r35-video installed them,
# on Ubuntu 26.04 under the 5.10 kernel with the three engines on in
# its device tree (from build #36).
#
# Usage: bash probe-l4t-codec.sh INPUTS_DIR
#        bash probe-l4t-codec.sh --installed [r32|r35]
#
# Run as the owner's ordinary account, without sudo. INPUTS_DIR is the folder
# scripts/host/fetch-r35-cuda.py --set video --release r32.7 wrote (here
# ~/r32-video-inputs), or for JetPack 5's elements the one --set video wrote
# (~/r35-video-inputs-2), checked against its SHA256SUMS; the release is read
# from its nvidia-l4t-gstreamer .deb. This script,
# frame_check.py, frame_hashes.py, frame_diff.py, v4l2_plugin_dir.c,
# crash_trace.c and, for JetPack 5, vic_record.c (tests/video) sit together
# in a folder of their own. It needs Ubuntu's GStreamer with the
# good, bad and ugly plugins and libav, for the test streams and the software
# references, and a C compiler (gcc-11 from add-u26-gcc11.sh):
#   sudo apt install --no-install-recommends gstreamer1.0-tools gstreamer1.0-plugins-base \
#       gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav
# The .debs are only unpacked, with dpkg-deb -x, into
# ~/l4t-codec-probe/<stamp>/root, as probe-l4t-video.sh does: nothing is
# installed and no system file changes. A library there that the system also
# has is set aside, so Ubuntu's stays in charge, except NVIDIA's own (names
# such as libnv*; nano-trt82's stand-in libnvmedia.so lacks the decoder's
# functions) and NVIDIA's libv4l2 and libv4lconvert: the codec elements reach
# the engines through libv4l2's plugin, libv4l2_nvvideocodec.so, which
# libv4l2 looks for with glob(), and v4l2_plugin_dir.so (built here from
# v4l2_plugin_dir.c, preloaded in every NVIDIA run) points that search into
# the scratch folder. The unpacked files and test frames are removed at the
# end unless KEEP_ROOT=1.
#
# JetPack 5's set has no nvidia-l4t-core: its other NVIDIA libraries may come
# from the installed R35.6 driver set (nano-l4t). NVIDIA never released it for
# the Nano, and its converter needs this project's VIC fix, so every NVIDIA
# run also preloads vic_record.c (built here; it sits next to this script)
# with VIC_PATCH=fix, as nano-r35-video does, and has it list the nvhost and
# nvmap requests the run made: each run prints the VIC jobs patched
# (VIC_PATCH) and any request the kernel refused (NVHOST_FAILED).
#
# In a scratch folder every NVIDIA run also preloads crash_trace.c (built
# here; it sits next to this script), which prints where a program crashed
# (CRASH, CRASH_REGS and CRASH_FRAME lines), and gst-launch-1.0 runs with
# --no-fault, so a crash ends the run at once.
#
# JetPack 5's H.264 encoder crashes on the Nano under every setting tried
# (2026-10-23), so with JetPack 5's elements step 4
# and the speed step skip it (ENCODE_H264=skipped) unless R35_H264=1.
#
# CODEC_STEPS, if set, runs only the named steps of 3 to 7 (decode, encode,
# jpeg, speed, webcam; separated by spaces); the others show as skipped.
# H264_ENC_VARIANTS, if set, repeats step 4's H.264 encoding for the record
# with each set of nvv4l2h264enc properties it lists (sets separated by ";",
# properties by spaces; a set starting with NV12 feeds the encoder NV12),
# 60 s at most each: one ENCODE_H264_VARIANT line a set.
#
# CODEC_STRACE=1 runs every NVIDIA run under strace (sudo apt install strace)
# for the file, ioctl and mmap calls of every thread, into the record's strace
# folder, and strace_diff.py (tests/video, next to this script) prints each
# run's failed calls by error and, for a thread that died of a signal, its
# last calls (STRACE lines). After step 4 it lists the calls the H.264
# encoder's run made that failed and never failed in the H.265 one, and the
# files only it opened (STRACE_ONLY_FAILED, STRACE_ONLY_OPENED): what the
# crashing encoder asks of the system that the working one does not. Run it
# with CODEC_STEPS=encode, and R35_H264=1 for JetPack 5's.
#
# With --installed (or --installed r32) it tests nano-l4t-r32-video +u26.2 or
# later instead (built by scripts/host/build-nano-l4t-debs.py --set video),
# which carries the same elements: the same steps, with every NVIDIA run
# started through its launcher, /usr/bin/nano-r32-video (which preloads the
# package's own v4l2_plugin_dir.so), and every NVIDIA library coming from the
# package's folder. With --installed r35 it tests nano-l4t-r35-video +u26.3 or
# later the same way, through /usr/bin/nano-r35-video (which also preloads
# the VIC fix), its other NVIDIA libraries coming from the installed driver
# set. Nothing is unpacked and no compiler is needed; frame_check.py,
# frame_hashes.py and frame_diff.py still sit next to this script.
#
# Steps, each logged in the record folder:
#   1. libraries: everything the NVIDIA GStreamer plugins and the V4L2 codec
#      plugin link resolves, every NVIDIA library from the scratch folder (or
#      the package's); the plugin folder that libv4l2 names is listed;
#   2. elements: GStreamer loads nvv4l2decoder, nvv4l2h264enc, nvv4l2h265enc
#      and nvvidconv (and lists nvjpegdec, not required);
#   3. decoding: 300 frames of the moving 1920x1080 test pattern, made into
#      an H.264 stream by Ubuntu's x264enc (veryfast: High profile, CABAC and
#      B-frames) and an H.265 stream by x265enc (ultrafast, Main), both at
#      8 Mbit/s, decoded by nvv4l2decoder (NVDEC) and nvvidconv (VIC, to
#      I420) and by libav (avdec_h264, avdec_h265). The standards define the
#      decoded picture exactly, so every frame must be identical
#      (frame_hashes.py, streamed through a FIFO). When not, the first 30
#      frames go to frame_diff.py for the record (frame offset, picture
#      shift, colour fit, chroma filter fit, where it differs, and a picture,
#      dec-<codec>-diff.png). The pattern is BT.709 (GStreamer's default at
#      1080p), and JetPack 4's nvvidconv turns the decoder's BT.709 pictures
#      into BT.601 unless asked otherwise, so the decode is repeated with
#      nvvidconv's output caps asking for BT.709, and then on a BT.601 stream,
#      into I420 and into NV12. It passes if any of these is identical, or
#      if Y is identical in every frame and every U and V value is within 1
#      of libav's with each row averaged with the one above or below, in
#      every frame (nvvidconv moved NVDEC's colour half a row on the Nano,
#      rounding the halves either way: MATCH in frame_hashes.py, which
#      counts the halves rounded each way and any other value off).
#      For the record, a 1280x720 BT.601 H.264 stream, whose picture needs
#      no padding rows, is decoded the same way (DECODE_720P_H264);
#   4. encoding (and, for the record, VIC's round trip from I420 into NV12
#      in NVMM buffers and back, pitch-linear and block-linear, the layout
#      NVDEC writes): 60 frames of the pattern through nvvidconv into NVMM buffers
#      and nvv4l2h264enc or nvv4l2h265enc (NVENC) at 8 Mbit/s, decoded back by
#      libav: each plane at least 30 dB against the pattern (frame_check.py);
#   5. JPEG: the 60 frames as JPEG (Ubuntu's jpegenc, quality 90), decoded by
#      nvjpegdec and by nvv4l2decoder mjpeg=1, against Ubuntu's jpegdec: at
#      least 40 dB a plane (decoders round the inverse transform
#      differently); it passes if either does. A failed way also goes to
#      frame_diff.py, and if nvv4l2decoder's fails, it is repeated with
#      nvvidconv cropping the picture to 1920x1080 (the decoder fills whole
#      16-row blocks, 1088 rows);
#   6. speed, for the record: on the 300-frame streams, each hardware decoder
#      and libav's into fakesink, and each hardware encoder after the test
#      source and nvvidconv, which are also timed alone; frames a second
#      (start-up included) and CPU seconds. The software encoders' figures
#      come from making the streams;
#   7. webcam, for the record, when WEBCAM (default /dev/video0) exists and
#      WEBCAM is not "none": 300 MJPEG frames at 1920x1080 and 30 a second
#      decoded by nvv4l2decoder mjpeg=1 and by jpegdec, CPU seconds;
#   8. for the record: each engine's runtime power counter around every
#      NVIDIA run (an engine that did the work was powered: ENGINES), the
#      engines' firmware files, the /dev/nvhost nodes and the kernel's
#      messages since the start.
# Each NVIDIA run records the colorimetry its caps carry into the NVMM
# element and into the sink (COLORIMETRY) and the libraries it loaded
# (LD_DEBUG=libs): every NVIDIA one must come from the scratch folder or the
# package's (LIB_MIX), and V4L2_PLUGIN says whether the codec plugin was
# loaded. The last line is L4T_CODEC_PROBE=PASS or FAIL with each test's
# result, the release and where the elements came from (source=scratch or
# installed); it passes when steps 1 to 5 pass.
set -uo pipefail

KERNEL=5.10.216-tegra
PACKAGES='nvidia-l4t-[a-z0-9-]+|cuda-[a-z0-9-]+-10-2'
NV_LIBS='^lib(nv|cuda|cudart|tegrav4l2|v4l2_nv|gstnv)'
KEEP_NVIDIA='^libv4l(2|convert)\.so'  # NVIDIA's own, kept for the codec plugin
LIB=/usr/lib/aarch64-linux-gnu
RUN_SECONDS=300
WIDTH=1920 HEIGHT=1080
CLIP_FRAMES=300 TEST_FRAMES=60 HEAD_FRAMES=30
BITRATE=8000  # kbit/s
GST_TOOLS='sudo apt install --no-install-recommends gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav'
ENGINES=(nvdec nvenc nvjpg vic)
TIMEFORMAT='%R %U %S'
VIDEO_PACKAGE=nano-l4t-r32-video  # JetPack 4's converter and codecs, installed (--installed)
LAUNCHER=/usr/bin/nano-r32-video
CODEC_SINCE=+u26.2  # the package version that brought the codec elements

root='' frames=''
cleanup() {
    [[ -n $root && -d $root ]] || return 0
    if [[ ${KEEP_ROOT:-0} == 1 ]]; then
        printf 'ROOT_KEPT=%s\n' "$root"
    else
        rm -rf "${root:?}" "${frames:?}" && printf 'ROOT_REMOVED=%s\n' "$root"
    fi
}
die() { cleanup; trap - EXIT; printf 'L4T_CODEC_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }
# The installed driver set (nano-l4t, L4T R35.6) and CUDA 11.4's runtime: in
# their folders, or a file one of their packages owns. JetPack 5's elements
# may use them; JetPack 4's may not.
release=r32
installed_nv() {
    [[ $release == r35 ]] || return 1
    case $1 in
        $LIB/tegra/*|$LIB/tegra-egl/*|/usr/local/cuda-11.4/*) return 0 ;;
    esac
    dpkg-query -S "$1" "$(readlink -f "$1")" 2> /dev/null \
        | grep -qE '^(nano-l4t-[a-z0-9]+|cuda-[a-z0-9-]+-11-4)(:[a-z0-9]+)?: '
}

here=$(cd "$(dirname "$0")" && pwd)
installed=0
if [[ ${1:-} == --installed ]]; then
    installed=1 release=${2:-r32}
    (( $# <= 2 )) && [[ $release == r3[25] ]] \
        || die 'give either the video inputs folder or --installed, with r32 (the default) or r35'
    if [[ $release == r35 ]]; then  # JetPack 5's, with the VIC fix
        VIDEO_PACKAGE=nano-l4t-r35-video LAUNCHER=/usr/bin/nano-r35-video CODEC_SINCE=+u26.3
    fi
    PACKAGE_DIR=$LIB/$VIDEO_PACKAGE
else
    (( $# == 1 )) || die 'give the video inputs folder (for example ~/r32-video-inputs), or --installed'
    [[ -d $1 ]] || die "no inputs folder $1"
    inputs=$(cd "$1" && pwd)
fi
[[ $(id -u) -ne 0 ]] || die 'run this as the ordinary account, not with sudo'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
driver=$(dpkg-query -W -f '${Version}' nano-l4t-core 2> /dev/null)
[[ $driver == 35.6.* ]] || die "needs the nano-l4t R35.6 driver set (nano-l4t-core is ${driver:-not installed})"
if (( installed )); then
    read -r state l4t < <(dpkg-query -W -f '${db:Status-Status} ${Version}\n' "$VIDEO_PACKAGE" 2> /dev/null)
    want=32.7.6-
    [[ $release == r35 ]] && want=35.6.5-
    [[ ${state:-} == installed && ${l4t:-} == "$want"* ]] \
        || die "needs $VIDEO_PACKAGE installed (it is ${state:-not installed}${l4t:+ $l4t})"
    [[ -x $LAUNCHER ]] || die "no $LAUNCHER (it comes with $VIDEO_PACKAGE)"
fi
for tool in gst-launch-1.0 gst-inspect-1.0; do
    command -v "$tool" > /dev/null || die "no $tool; install Ubuntu's GStreamer first: $GST_TOOLS"
done
for tool in python3 dpkg-deb timeout mkfifo ldd; do
    command -v "$tool" > /dev/null || die "no $tool"
done
own=(frame_check.py frame_hashes.py frame_diff.py)
if (( ! installed )); then  # the plugin-folder shim is built here; the package has its own
    cc=$(command -v gcc-11 || command -v gcc || command -v cc) || die 'no C compiler (gcc-11 from add-u26-gcc11.sh)'
    own+=(v4l2_plugin_dir.c crash_trace.c)
fi
tracer=()
if [[ ${CODEC_STRACE:-0} == 1 ]]; then
    command -v strace > /dev/null || die 'CODEC_STRACE=1 needs strace: sudo apt install strace'
    own+=(strace_diff.py)
    tracer=(strace -f -qq -y -s 160 -e 'trace=%file,ioctl,mmap' -e 'signal=SIGSEGV,SIGBUS,SIGILL,SIGABRT,SIGFPE')
    # Its traced programs go with it if timeout stops it (strace 6.1 or later).
    strace --kill-on-exit -o /dev/null true 2> /dev/null && tracer+=(--kill-on-exit)
fi
for file in "${own[@]}"; do
    [[ -f $here/$file ]] || die "no $file next to this script"
done
ALL_STEPS='decode encode jpeg speed webcam'
steps=${CODEC_STEPS:-$ALL_STEPS}
for step in $steps; do
    [[ " $ALL_STEPS " == *" $step "* ]] || die "CODEC_STEPS: no step $step (give some of: $ALL_STEPS)"
done
wants() { [[ " $steps " == *" $1 "* ]]; }
skip_h264() { [[ $1 == h264 && $release == r35 && ${R35_H264:-0} != 1 ]]; }  # CODEC: JetPack 5's H.264, unless R35_H264=1
sw=(env -u DISPLAY -u WAYLAND_DISPLAY GST_DEBUG_NO_COLOR=1)
missing=()
for element in videotestsrc filesrc filesink fakesink x264enc x265enc h264parse h265parse \
    avdec_h264 avdec_h265 jpegenc jpegdec jpegparse videoconvert; do
    "${sw[@]}" gst-inspect-1.0 "$element" > /dev/null 2>&1 || missing+=("$element")
done
(( ${#missing[@]} == 0 )) || die "GStreamer lacks ${missing[*]}; install Ubuntu's plugins first: $GST_TOOLS"
nodes=()
for node in /dev/nvmap /dev/nvhost-ctrl /dev/nvhost-vic /dev/nvhost-nvdec /dev/nvhost-msenc /dev/nvhost-nvjpg; do
    [[ -r $node && -w $node ]] || nodes+=("$node")  # bash's test; 26.04's uutils test misreads groups
done
(( ${#nodes[@]} == 0 )) || die "this account cannot open ${nodes[*]} (the engines need build #36's device tree; the video group should have them)"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$HOME/l4t-codec-probe/$stamp
mkdir -p "$HOME/l4t-codec-probe" && mkdir "$record" || die "cannot create $record"
root=$record/root frames=$record/frames
mkdir "$root" "$frames" || die "cannot create $root"
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
exec > >(tee "$record/summary.txt") 2>&1
kernel_start=$(dmesg 2> /dev/null | wc -l)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s %s\nOS=%s\nDRIVER_SET=nano-l4t-core %s\n' \
    "$record" "$stamp" "$(uname -r)" "$(uname -v)" "$PRETTY_NAME" "$driver"
printf 'GSTREAMER=%s\n' "$(gst-launch-1.0 --version | sed -n 's/^GStreamer //p' | head -n 1)"

result=PASS
declare -A outcome=()
check() { printf '%s=%s\n' "$1" "$2"; outcome[$1]=${2%% *}; [[ $2 == PASS* ]] || result=FAIL; }
skipped() { printf '%s=skipped (not in CODEC_STEPS)\n' "$1"; outcome[$1]=skipped; }
finish() {
    local kernel_lines
    dmesg 2> /dev/null | tail -n "+$(( kernel_start + 1 ))" > "$record/kernel.txt"
    kernel_lines=$(wc -l < "$record/kernel.txt")
    printf 'KERNEL_LINES=%s (all in kernel.txt)\n' "$kernel_lines"
    grep -iE 'nvdec|nvenc|msenc|nvjpg|falcon|flcn|host1x|nvhost|nvmap|smmu|mc-err|sync|fence|unknown|timeout|fault' \
        "$record/kernel.txt" | head -n 40 | cut -c1-240 | sed 's/^/KERNEL: /'
    cleanup; trap - EXIT
    printf 'L4T_CODEC_PROBE=%s decode_h264=%s decode_h265=%s encode_h264=%s encode_h265=%s jpeg=%s release=%s source=%s record=%s\n' \
        "$result" "${outcome[DECODE_H264]:--}" "${outcome[DECODE_H265]:--}" "${outcome[ENCODE_H264]:--}" \
        "${outcome[ENCODE_H265]:--}" "${outcome[JPEG]:--}" "$release" "$( (( installed )) && echo installed || echo scratch)" "$record"
    [[ $result == PASS ]] && exit 0
    exit 1
}

# --- What to test: the packages as the PC wrote them, unpacked into the
# scratch folder, or with --installed nano-l4t-r32-video as installed.
shopt -s nullglob
need=1600  # MiB of test frames at most, besides the unpacked packages
space() {
    free=$(python3 -I -c 'import os, sys; s = os.statvfs(sys.argv[1]); print(s.f_bavail * s.f_frsize >> 20)' "$record")
    printf 'SPACE=%s MiB free, %s MiB needed\n' "$free" "$need"
    (( free >= need )) || die "not enough space in $HOME: $free MiB free, $need MiB needed"
}
if (( installed )); then
    printf 'PACKAGE=%s %s (installed, run through %s)\n' "$VIDEO_PACKAGE" "$l4t" "$LAUNCHER"
    printf 'RELEASE=%s (L4T %s)\n' "$release" "${l4t%+*}"
    space
    # Paths are shown whole, and in libv4l2's messages the folder is "(package)".
    lib_root=$PACKAGE_DIR shown='' tag='(package)' where="$VIDEO_PACKAGE's folder"
    [[ $release == r35 ]] && where+=' or the installed R35.6 driver set'
    plugins=$PACKAGE_DIR/gstreamer-1.0 dirs=("$PACKAGE_DIR/lib")
    [[ -f $plugins/libgstnvvideo4linux2.so ]] \
        || die "no $plugins/libgstnvvideo4linux2.so: $VIDEO_PACKAGE $l4t has no codec elements (they came with $CODEC_SINCE)"
    libdirs=${dirs[0]}
    printf 'LIBDIR=%s\nPLUGIN_DIR=%s\n' "$libdirs" "$plugins"
    ls -l "$PACKAGE_DIR" "${dirs[@]}" "$plugins" "$PACKAGE_DIR/libv4l2-plugins" > "$record/libraries.txt" 2>&1
else
    if (cd "$inputs" && sha256sum --quiet -c SHA256SUMS) > "$record/sha256-check.txt" 2>&1; then
        printf 'INPUTS_SHA256=PASS %s\n' "$inputs"
    else
        cat "$record/sha256-check.txt"
        printf 'INPUTS_SHA256=FAIL %s\n' "$inputs"
        result=FAIL; finish
    fi
    cp "$inputs/SHA256SUMS" "$record/SHA256SUMS-inputs"
    plugin_deb=("$inputs"/nvidia-l4t-gstreamer_*.deb)
    (( ${#plugin_deb[@]} == 1 )) || die "no nvidia-l4t-gstreamer .deb in the inputs, or more than one"
    l4t=$(dpkg-deb -f "${plugin_deb[0]}" Version)
    case $l4t in
        32.7.6-*) release=r32 required=(nvidia-l4t-core) ;;
        35.6.*) release=r35 required=() ;;
        *) die "nvidia-l4t-gstreamer is $l4t, neither JetPack 4's 32.7.6 nor JetPack 5's 35.6" ;;
    esac
    printf 'RELEASE=%s (L4T %s)\n' "$release" "$l4t"
    [[ $release == r32 || -f $here/vic_record.c ]] || die "no vic_record.c next to this script (JetPack 5's runs need the VIC fix)"
    debs=() names=()
    for deb in "$inputs"/*.deb; do
        [[ $(basename "$deb") =~ ^($PACKAGES)_ ]] || continue
        package=$(dpkg-deb -f "$deb" Package) version=$(dpkg-deb -f "$deb" Version)
        if [[ $package == cuda-* ]]; then
            [[ $release == r32 && $version == 10.2.* ]] || die "$(basename "$deb") does not belong to $release's set"
        else
            [[ $version == "$l4t" ]] || die "$(basename "$deb") is $version, not $l4t"
        fi
        names+=("$package") debs+=("$deb")
        size=$(dpkg-deb -f "$deb" Installed-Size)
        need=$(( need + ${size:-0} / 1024 + 1 ))
    done
    for package in nvidia-l4t-gstreamer nvidia-l4t-multimedia nvidia-l4t-multimedia-utils "${required[@]}"; do
        [[ " ${names[*]} " == *" $package "* ]] || die "no $package .deb in the inputs"
    done
    space
    for deb in "${debs[@]}"; do
        printf 'UNPACK=%s\n' "$(basename "$deb")"
        dpkg-deb -x "$deb" "$root" || die "dpkg-deb could not unpack $deb"
    done
    # Paths are shown without the scratch folder, and in libv4l2's messages it is "(scratch)".
    lib_root=$root shown=$root tag='(scratch)' where='the scratch folder'
    [[ $release == r35 ]] && where='the scratch folder or the installed R35.6 driver set'
    plugins=$root$LIB/gstreamer-1.0
    [[ -f $plugins/libgstnvvideo4linux2.so ]] || die "no ${plugins#"$root"}/libgstnvvideo4linux2.so in the packages"
    libdirs_of() {
        find "$root" \( -type f -o -type l \) -name 'lib*.so*' ! -path "$plugins/*" ! -path '*/libv4l/plugins/*' \
            -printf '%h\n' | sort -u
    }
    ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
    mapfile -t dirs < <(libdirs_of)
    (( ${#dirs[@]} )) || die 'no libraries in the packages'
    "$ldconfig" -n "${dirs[@]}" 2>&1 | sed 's/^/LDCONFIG: /'
    # Ubuntu's own libraries stay Ubuntu's: set aside any name the packages also
    # carry (after ldconfig, so that no link to them is made again), but keep
    # NVIDIA's own, which the system may have from another release or as a
    # stand-in (nano-trt82's libnvmedia.so), and NVIDIA's libv4l2 and
    # libv4lconvert, which know where the codec plugin is.
    "$ldconfig" -p | awk -v lib="$LIB/tegra" '/ => / && index($NF, lib) != 1 {print $1}' | sort -u > "$record/system-libs.txt"
    while IFS= read -r file; do
        name=$(basename "$file")
        grep -qxF "$name" "$record/system-libs.txt" || continue
        if [[ $name =~ $KEEP_NVIDIA ]]; then
            printf 'KEPT_NVIDIA=%s (Ubuntu has its own; NVIDIA'"'"'s loads the codec plugin)\n' "${file#"$root"}"
            continue
        fi
        if [[ $name =~ $NV_LIBS ]]; then
            printf 'KEPT_NVIDIA=%s (the system has one too: %s)\n' "${file#"$root"}" \
                "$("$ldconfig" -p | awk -v n="$name" '$1 == n && / => / {print $NF; exit}')"
            continue
        fi
        mkdir -p "$record/set-aside"
        mv "$file" "$record/set-aside/$(tr / _ <<< "${file#"$root"/}")" && printf 'SET_ASIDE=%s (Ubuntu has its own)\n' "${file#"$root"}"
    done < <(find "$root" \( -type f -o -type l \) -name 'lib*.so*' ! -path "$plugins/*" ! -path '*/libv4l/plugins/*' | sort)
    mapfile -t dirs < <(libdirs_of)
    libdirs=$(IFS=:; echo "${dirs[*]}")
    printf 'LIBDIR=%s\n' "${dirs[@]#"$root"}"
    printf 'PLUGIN_DIR=%s\n' "${plugins#"$root"}"
    ls -l "${dirs[@]}" "$plugins" > "$record/libraries.txt"
fi

# libv4l2's plugin folder: where the codec plugin is, and the folder names
# NVIDIA's libv4l2 carries (which v4l2_plugin_dir.so redirects).
mapfile -t codec_plugins < <(find "$lib_root" -name 'libv4l2_nv*.so*' | sort)
printf 'V4L2_PLUGIN_FILE=%s\n' "${codec_plugins[@]#"$shown"}"
codec_plugin=''
for file in "${codec_plugins[@]}"; do
    [[ $file == */libv4l2_nvvideocodec.so* ]] && codec_plugin=$file
done
[[ -n $codec_plugin ]] || die "no libv4l2_nvvideocodec.so in $where"
while IFS= read -r file; do
    printf 'V4L2_LIBRARY=%s plugin folders: %s\n' "${file#"$shown"}" \
        "$(grep -aoE '[A-Za-z0-9_./%$-]*(libv4l/plugins|libv4l2_nv)[A-Za-z0-9_./%*-]*' "$file" | sort -u | tr '\n' ' ')"
done < <(find "$lib_root" \( -name 'libv4l2.so*' -o -name 'libnvv4l2*.so*' \) -type f | sort)

if (( installed )); then
    # The launcher sets the library and plugin paths and preloads the
    # package's plugin-folder shim (and for JetPack 5 the VIC fix), as for any
    # program run with it; the caller's VIC_PATCH is not passed on.
    shims=(v4l2_plugin_dir)
    [[ $release == r35 ]] && shims+=(vic_patch)
    for shim in "${shims[@]}"; do
        [[ -f $PACKAGE_DIR/$shim.so ]] || die "no $PACKAGE_DIR/$shim.so"
        printf 'SHIM=%s sha256=%s\n' "$PACKAGE_DIR/$shim.so" "$(sha256sum < "$PACKAGE_DIR/$shim.so" | cut -c1-16)"
    done
    printf 'LAUNCHER LD_PRELOAD=%s V4L2_PLUGIN_DIR=%s%s\n' "$(env -u VIC_PATCH "$LAUNCHER" printenv LD_PRELOAD)" \
        "$("$LAUNCHER" printenv V4L2_PLUGIN_DIR)" \
        "$([[ $release == r35 ]] && printf ' VIC_PATCH=%s' "$(env -u VIC_PATCH "$LAUNCHER" printenv VIC_PATCH)")"
    linker=(env -u VIC_PATCH "$LAUNCHER")
    nv=(env -u DISPLAY -u WAYLAND_DISPLAY -u VIC_PATCH GST_REGISTRY="$record/registry.bin" GST_DEBUG_NO_COLOR=1
        "$LAUNCHER" env)
else
    # The preloaded shims, built here: the plugin folder's, the crash report's, and for JetPack 5 the VIC fix.
    preload=() shims=(v4l2_plugin_dir crash_trace)
    [[ $release == r35 ]] && shims+=(vic_record)
    for shim in "${shims[@]}"; do
        "$cc" -shared -fPIC -O2 -Wall -o "$record/$shim.so" "$here/$shim.c" -ldl \
            > "$record/$shim-build.txt" 2>&1 || { cat "$record/$shim-build.txt"; die "$shim.c did not build"; }
        printf 'SHIM=%s from %s.c sha256=%s by %s\n' "$record/$shim.so" "$shim" \
            "$(sha256sum < "$here/$shim.c" | cut -c1-16)" "$("$cc" --version | head -n 1)"
        preload+=("$record/$shim.so")
    done
    linker=(env LD_LIBRARY_PATH="$libdirs")
    nv=(env -u DISPLAY -u WAYLAND_DISPLAY -u VIC_RECORD_DIR LD_LIBRARY_PATH="$libdirs" GST_PLUGIN_PATH="$plugins"
        GST_REGISTRY="$record/registry.bin" GST_DEBUG_NO_COLOR=1
        LD_PRELOAD="$(IFS=:; echo "${preload[*]}")" V4L2_PLUGIN_ROOT="$root")
    [[ $release == r35 ]] && nv+=(VIC_PATCH=fix)
fi

# --- 1. Libraries: what the dynamic linker finds for each NVIDIA plugin.
ldd_check() {  # FILE: prints problems, returns 1 if any
    local file=$1 bad=0 lib path
    "${linker[@]}" ldd "$file" > "$record/ldd.tmp" 2>&1
    printf '## %s\n' "${file#"$shown"}" >> "$record/ldd.txt"
    cat "$record/ldd.tmp" >> "$record/ldd.txt"
    while read -r lib _ path _; do
        if [[ $path == not ]]; then
            printf 'UNRESOLVED %s' "$lib"; bad=1
        elif [[ $lib =~ $NV_LIBS && $path == /* && $path != "$lib_root"/* ]] && ! installed_nv "$path"; then
            printf 'OUTSIDE %s=>%s' "$lib" "$path"; bad=1
        else
            continue
        fi
        printf ' (needed by %s)\n' "$(basename "$file")"
    done < <(grep '=>' "$record/ldd.tmp")
    rm -f "${record:?}/ldd.tmp"
    return "$bad"
}
bad=0
for file in "$plugins/libgstnvvideo4linux2.so" "$plugins/libgstnvvidconv.so" "$codec_plugin"; do
    ldd_check "$file" || bad=1
done
if (( bad )); then check LIBRARIES FAIL; else check LIBRARIES PASS; fi
# libv4l2 loads the codec plugin with dlopen(), which can fail where ldd
# finds every library (a missing symbol or symbol version, static TLS).
if out=$("${linker[@]}" python3 -I -c 'import ctypes, sys; ctypes.CDLL(sys.argv[1])' "$codec_plugin" 2>&1); then
    printf 'PLUGIN_DLOPEN=PASS %s\n' "${codec_plugin#"$shown"}"
else
    printf 'PLUGIN_DLOPEN=FAIL %s\n' "$(tail -n 1 <<< "$out" | sed "s|$lib_root|$tag|g")"
fi
for plugin in "$plugins"/libgstnvjpeg*.so; do
    ldd_check "$plugin" | sed 's/^/NVJPEG_PLUGIN: /'
done

# --- 2. Elements (this also builds the registry).
elements=PASS
for element in nvv4l2decoder nvv4l2h264enc nvv4l2h265enc nvvidconv nvjpegdec; do
    timeout -k 10 "$RUN_SECONDS" "${nv[@]}" gst-inspect-1.0 "$element" > "$record/inspect-$element.txt" 2>&1
    if grep -q 'Factory Details' "$record/inspect-$element.txt"; then
        printf 'ELEMENT %s %s\n' "$element" \
            "$(sed -nE 's/^ +Filename +//p' "$record/inspect-$element.txt" | sed "s|^$shown||")"
    else
        printf 'ELEMENT %s missing: %s\n' "$element" "$(head -n 1 "$record/inspect-$element.txt")"
        [[ $element == nvjpegdec ]] || elements=FAIL
    fi
done
"${nv[@]}" gst-inspect-1.0 > "$record/inspect-all.txt" 2>&1
printf 'NV_ELEMENTS=%s\n' "$(awk -F': +' '$1 ~ /^nv/ {printf "%s%s", sep, $2; sep = " "}' "$record/inspect-all.txt")"
check ELEMENTS "$elements"
has_property() {  # ELEMENT PROPERTY
    grep -qE "^ +$2 *:" "$record/inspect-$1.txt" 2> /dev/null
}

# --- The engines: their device nodes, firmware and power counters.
ls -l /dev/nvhost-* > "$record/nvhost-nodes.txt" 2>&1
printf 'NVHOST_NODES=%s\n' "$(sed -nE 's|.* /dev/(nvhost-[a-z0-9-]+)$|\1|p' "$record/nvhost-nodes.txt" | tr '\n' ' ')"
for firmware in /lib/firmware/tegra21x/nvhost_*; do
    owner=$(dpkg-query -S "$(readlink -f "$firmware")" 2> /dev/null | cut -d: -f1 | head -n 1)
    printf 'FIRMWARE %s bytes=%s package=%s\n' "${firmware##*/}" "$(stat -L -c %s "$firmware")" "${owner:--}"
done
declare -A engine_dir=()
for engine in "${ENGINES[@]}"; do
    engine_dir[$engine]=$(find /sys/bus/platform/devices/ -maxdepth 1 -name "*.$engine" | head -n 1)
done
engine_times() {
    local engine
    for engine in "${ENGINES[@]}"; do
        printf '%s ' "$(cat "${engine_dir[$engine]}/power/runtime_active_time" 2> /dev/null || echo -)"
    done
}
engine_delta() {  # BEFORE AFTER (from engine_times)
    local -a a b
    local i out=''
    read -ra a <<< "$1"; read -ra b <<< "$2"
    for i in "${!ENGINES[@]}"; do
        if [[ ${a[i]:-} =~ ^[0-9]+$ && ${b[i]:-} =~ ^[0-9]+$ ]]; then
            out+=" ${ENGINES[i]}=+$(( b[i] - a[i] ))ms"
        else
            out+=" ${ENGINES[i]}=-"
        fi
    done
    printf '%s' "${out# }"
}

# --- Runs. NAME then gst-launch-1.0's arguments.
timing() {  # NAME FRAMES: frames a second and CPU use from NAME's time file
    local real user sys
    read -r real user sys < <(tail -n 1 "$record/$1-time.txt") || return 0
    python3 -I -c 'import sys
num = lambda s: float(s.replace(",", "."))  # bash prints the locale'"'"'s decimal comma
frames, real, cpu = int(sys.argv[1]), num(sys.argv[2]), num(sys.argv[3]) + num(sys.argv[4])
print(f"frames={frames} seconds={real:.2f} fps={frames / real:.1f} cpu_seconds={cpu:.2f} cpu_of_4_cores={100 * cpu / real / 4:.0f}%")' \
        "$2" "$real" "$user" "$sys"
}
colours() {  # NAME: the colorimetry of raw video into NVMM buffers and into the sink (gst-launch -v)
    local nvmm sink
    nvmm=$(grep -E '\.GstPad:sink: caps = video/x-raw\(memory:NVMM\)' "$record/$1.log" | tail -n 1 \
        | grep -oE 'colorimetry=\(string\)[^,]+' | sed 's/.*)//')
    sink=$(grep -E 'Gst(File|Fake)Sink:[a-z0-9_]+\.GstPad:sink: caps = video/x-raw' "$record/$1.log" | tail -n 1 \
        | grep -oE 'colorimetry=\(string\)[^,]+' | sed 's/.*)//')
    [[ -n $nvmm$sink ]] && printf '%s: COLORIMETRY into_nvmm_element=%s into_sink=%s\n' "$1" "${nvmm:--}" "${sink:--}"
    return 0
}
run_sw() {  # Ubuntu's GStreamer alone
    local name=$1 status; shift
    { time timeout -k 10 "$RUN_SECONDS" "${sw[@]}" gst-launch-1.0 -q "$@" > "$record/$name.log" 2>&1; } \
        2> "$record/$name-time.txt"
    status=$?
    if (( status != 0 )); then
        printf '%s: GST_LAUNCH_EXIT=%s\n' "$name" "$status"
        tail -n 3 "$record/$name.log" | cut -c1-240 | sed "s/^/$name: /"
    fi
    return "$status"
}
run_nv() {  # with the NVIDIA elements from the scratch folder or the package
    local name=$1 status before after loaded outside ok=0 vic=() trace=(); shift
    if [[ $release == r35 ]]; then  # the VIC fix's counts and the run's nvhost and nvmap requests
        vic=(VIC_RECORD_DIR="$record/nvhost/$name" VIC_RECORD_JOBS=1)
        mkdir -p "$record/nvhost/$name"
    fi
    if (( ${#tracer[@]} )); then  # CODEC_STRACE=1
        mkdir -p "$record/strace"
        trace=("${tracer[@]}" -o "$record/strace/$name.txt")
    fi
    before=$(engine_times)
    { time timeout -k 10 "$RUN_SECONDS" "${trace[@]}" "${nv[@]}" "${vic[@]}" GST_DEBUG=2 GST_DEBUG_FILE="$record/$name-gst.log" \
        LD_DEBUG=libs LD_DEBUG_OUTPUT="$record/ld-$name" gst-launch-1.0 --no-fault -v "$@" > "$record/$name.log" 2>&1; } \
        2> "$record/$name-time.txt"
    status=$? last_exit=$?
    after=$(engine_times)
    printf '%s: GST_LAUNCH_EXIT=%s ENGINES %s\n' "$name" "$status" "$(engine_delta "$before" "$after")"
    colours "$name"
    grep -E '^CRASH' "$record/$name.log" | head -n 40 | sed "s|$lib_root|$tag|g; s/^/$name: /"
    if (( ${#trace[@]} )); then
        python3 -I "$here/strace_diff.py" summary "$record/strace/$name.txt" --root "$lib_root" "$tag" 2>&1 \
            | cut -c1-300 | sed "s/^/$name: /"
    fi
    if (( ${#vic[@]} )); then
        printf '%s: VIC_PATCH %s\n' "$name" "$(awk '/^vic_patch:/ {runs++; for (i = 3; i <= NF; i++) {split($i, kv, "="); n[kv[1]] += kv[2]}}
            END {printf "processes=%d jobs=%d patched=%d unchanged=%d skipped=%d failed=%d", runs, n["jobs"], n["patched"],
                 n["unchanged"], n["skipped"], n["failed"]}' "$record/nvhost/$name"/p*-log.txt 2> /dev/null)"
        cat "$record/nvhost/$name"/p*-requests.txt 2> /dev/null | grep -v ' failed=0$' | sed 's/^REQUEST //' | sort -u \
            | head -n 8 | sed "s/^/$name: NVHOST_FAILED /"
    fi
    (( status == 0 )) || ok=1
    grep -E 'ERROR|WARNING|rror|Segmentation|Bus error|Aborted|core dumped|NvMM|NVMEDIA|V4L2_PLUGIN_DIR' \
        "$record/$name.log" | grep -v '^libv4l2: ' | sort | uniq -c | sort -rn | head -n 10 | cut -c1-240 \
        | sed "s/^/$name: /"
    grep '^libv4l2: ' "$record/$name.log" | sort -u | head -n 3 | sed "s|$lib_root|$tag|g; s/^/$name: /"
    grep -E ' (ERROR|WARN) ' "$record/$name-gst.log" 2> /dev/null | head -n 6 | cut -c1-240 | sed "s/^/$name: GST: /"
    cat "$record/ld-$name".* 2> /dev/null | grep -oE 'calling init: /[^ ]+' | sed 's/^calling init: //' \
        | sort -u > "$record/$name-loaded.txt"
    rm -f "${record:?}/ld-${name:?}".*
    loaded=$(while read -r path; do
        [[ $(basename "$path") =~ $NV_LIBS ]] && basename "$path"; done < "$record/$name-loaded.txt" | tr '\n' ' ')
    outside=$(while read -r path; do
        [[ $(basename "$path") =~ $NV_LIBS && $path != "$lib_root"/* ]] && ! installed_nv "$path" && echo "$path"
    done < "$record/$name-loaded.txt" | tr '\n' ' ')
    printf '%s: NV_LOADED=%s\n' "$name" "$loaded"
    if grep -q '/libv4l2_nvvideocodec\.so' "$record/$name-loaded.txt"; then
        printf '%s: V4L2_PLUGIN=loaded' "$name"
    else
        printf '%s: V4L2_PLUGIN=not loaded' "$name"
    fi
    printf ' libv4l2=%s\n' "$(grep -m 1 '/libv4l2\.so' "$record/$name-loaded.txt" | sed "s|^$lib_root|$tag|")"
    if [[ ! -s $record/$name-loaded.txt ]]; then
        printf '%s: LIB_MIX=FAIL the linker recorded nothing\n' "$name"; ok=1
    elif [[ -n $outside ]]; then
        printf '%s: LIB_MIX=FAIL %s\n' "$name" "$outside"; ok=1
        result=FAIL
    else
        printf '%s: LIB_MIX=PASS every NVIDIA library from %s\n' "$name" "$where"
    fi
    return "$ok"
}
# hashed KIND NAME then a pipeline without its sink: KIND sw or nv; the
# frames go through a FIFO into frame_hashes.py, which keeps the first ones
# (and, run by with_rows, saves or checks the colour rows' averages).
hash_rows=()
with_rows() { local hash_rows=("$1" "$2"); shift 2; "$@"; }  # with_rows save-rows|check-rows FILE command...
hashed() {
    local kind=$1 name=$2 fifo reader status; shift 2
    fifo=$frames/$name.fifo
    rm -f "$fifo" && mkfifo "$fifo" || return 1
    python3 -I "$here/frame_hashes.py" "$WIDTH" "$HEIGHT" "$record/$name-hashes.txt" \
        "$frames/$name-head.raw" "$HEAD_FRAMES" "${hash_rows[@]}" < "$fifo" > "$record/$name-hashing.txt" 2>&1 &
    reader=$!
    "run_$kind" "$name" "$@" ! filesink location="$fifo"
    status=$?
    # A run that never opened the FIFO leaves the reader waiting for a writer.
    kill -0 "$reader" 2> /dev/null && timeout 5 bash -c ': > "$1"' _ "$fifo" 2> /dev/null
    wait "$reader"
    sed "s/^/$name: /" "$record/$name-hashing.txt"
    rm -f "$fifo"
    return "$status"
}
compare() {  # NAME REFERENCE OUTPUT MIN_PSNR
    python3 -I "$here/frame_check.py" I420 "$WIDTH" "$HEIGHT" "$2" "$3" "$4" > "$record/$1-frames.txt"
    local status=$?
    sed "s/^/$1: /" "$record/$1-frames.txt"
    return "$status"
}
explain() {  # NAME REFERENCE OUTPUT: how the frames differ, and a picture
    python3 -I "$here/frame_diff.py" "$WIDTH" "$HEIGHT" "$2" "$3" "$record/$1-diff.png" > "$record/$1-diff.txt" 2>&1
    sed "s/^/$1: /" "$record/$1-diff.txt"
}
# decoded NAME REFERENCE_HASHES then a pipeline without its sink: the
# frames' hashes against the reference's; true when every frame is identical.
decoded() {
    local name=$1 reference=$2 status; shift 2
    hashed nv "$name" "$@"
    python3 -I "$here/frame_hashes.py" --compare "$reference" "$record/$name-hashes.txt" > "$record/$name-compare.txt" 2>&1
    status=$?
    sed "s/^/$name: /" "$record/$name-compare.txt"
    return "$status"
}
identical() { sed -n 's/^IDENTICAL=//p' "$record/$1-compare.txt" 2> /dev/null | head -n 1; }
y_identical() {  # absent when every frame is identical
    local n
    n=$(sed -n 's/^Y_IDENTICAL=//p' "$record/$1-compare.txt" 2> /dev/null | head -n 1)
    [[ -n $n ]] || n=$(identical "$1")
    printf '%s\n' "${n:--}"
}
match() { sed -n 's/^MATCH=//p' "$record/$1-compare.txt" 2> /dev/null | head -n 1; }
value_of() { sed -n "s/.* $1=\([0-9.]*\).*/\1/p" <<< "$2"; }  # KEY LINE
half_rows() {  # NAME WAY: how the halves were rounded and what else was off
    local line off up down largest
    line=$(grep -m 1 "^CHROMA_HALF_ROW $2 " "$record/$1-compare.txt" 2> /dev/null) || return 0
    off=$(value_of not_rounded_average "$line") up=$(value_of halves_up "$line")
    down=$(value_of halves_down "$line") largest=$(value_of largest_difference "$line")
    printf 'halves rounded up %s times and down %s times, ' "$up" "$down"
    if [[ $off == 0 ]]; then printf 'no other value off\n'; else printf '%s other values off by up to %s\n' "$off" "$largest"; fi
}
# head_explain NAME REFERENCE_NAME [planes]: frame_diff.py (and with planes,
# frame_check.py) on the first frames that hashed kept of each.
head_explain() {
    [[ -s $frames/$1-head.raw && -s $frames/$2-head.raw ]] || return 0
    [[ ${3:-} == planes ]] && compare "$1" "$frames/$2-head.raw" "$frames/$1-head.raw" 40
    explain "$1" "$frames/$2-head.raw" "$frames/$1-head.raw"
}
with_limit() { local RUN_SECONDS=$1; shift; "$@"; }  # with_limit SECONDS command...: a shorter time limit
speed() {  # NAME FRAMES
    printf 'SPEED %s %s\n' "$1" "$(timing "$1" "$2")"
}

hd='video/x-raw,format=I420,width=1920,height=1080,framerate=30/1'
pattern() { printf '%s\n' videotestsrc "num-buffers=$1" pattern=smpte horizontal-speed=8 ! "${2:-$hd}"; }
mapfile -t clip_source < <(pattern "$CLIP_FRAMES")
mapfile -t test_source < <(pattern "$TEST_FRAMES")
to_i420=(nvvidconv ! 'video/x-raw,format=I420')
to_nvmm=(nvvidconv ! 'video/x-raw(memory:NVMM),format=I420')

# --- 3. Decoding: the 300-frame streams, by NVDEC and by libav, frame by frame.
declare -A encoder=([h264]="x264enc speed-preset=veryfast bitrate=$BITRATE key-int-max=60"
                    [h265]="x265enc speed-preset=ultrafast bitrate=$BITRATE key-int-max=60")
declare -A stream_caps=([h264]='video/x-h264,profile=high,stream-format=byte-stream'
                        [h265]='video/x-h265,profile=main,stream-format=byte-stream')
mapfile -t clip601_source < <(pattern "$CLIP_FRAMES" "$hd,colorimetry=bt601")
route_suffix=('' -bt709 -bt601 -bt601-nv12)
route_about=('the BT.709 stream' 'the BT.709 stream with nvvidconv asked to keep BT.709'
             'a BT.601 stream' 'a BT.601 stream through NV12')
for codec in h264 h265; do
    upper=${codec^^}
    wants decode || { skipped "DECODE_$upper"; continue; }
    clip=$frames/clip.$codec
    read -ra make <<< "${encoder[$codec]}"
    if ! run_sw "make-$codec" "${clip_source[@]}" ! "${make[@]}" ! "${stream_caps[$codec]}" ! filesink location="$clip"; then
        check "DECODE_$upper" 'FAIL the test stream was not made'
        continue
    fi
    speed "make-$codec" "$CLIP_FRAMES"
    printf 'STREAM_%s bytes=%s\n' "$upper" "$(stat -c %s "$clip")"
    hashed sw "ref-$codec" filesrc location="$clip" ! "${codec}parse" ! "avdec_$codec" ! video/x-raw,format=I420
    # The test pattern at 1080p is BT.709. On the Nano (2026-10-23) VIC's
    # output fitted libav's frames converted from BT.709 to BT.601, so ask
    # nvvidconv to keep BT.709, and failing that, try a BT.601 stream, which
    # needs no conversion, into I420 and into NV12. On that stream (run 5)
    # Y was identical in every frame and U and V were each row averaged with
    # the row below, its halves rounded either way, which frame_hashes.py
    # checks in every frame against libav's rows (MATCH).
    pass_route=''
    if decoded "dec-$codec" "$record/ref-$codec-hashes.txt" \
            filesrc location="$clip" ! "${codec}parse" ! nvv4l2decoder ! "${to_i420[@]}"; then
        pass_route=yes
    else
        head_explain "dec-$codec" "ref-$codec"
        if decoded "dec-$codec-bt709" "$record/ref-$codec-hashes.txt" filesrc location="$clip" ! "${codec}parse" \
                ! nvv4l2decoder ! nvvidconv ! 'video/x-raw,format=I420,colorimetry=bt709'; then
            pass_route=yes
        else
            head_explain "dec-$codec-bt709" "ref-$codec"
        fi
    fi
    if [[ -z $pass_route ]]; then
        clip601=$frames/clip601.$codec rows=$frames/ref601-$codec.rows
        if run_sw "make601-$codec" "${clip601_source[@]}" ! "${make[@]}" ! "${stream_caps[$codec]}" \
                ! filesink location="$clip601" \
            && with_rows save-rows "$rows" hashed sw "ref601-$codec" filesrc location="$clip601" ! "${codec}parse" \
                ! "avdec_$codec" ! video/x-raw,format=I420; then
            with_rows check-rows "$rows" decoded "dec-$codec-bt601" "$record/ref601-$codec-hashes.txt" \
                filesrc location="$clip601" ! "${codec}parse" ! nvv4l2decoder ! "${to_i420[@]}" \
                || head_explain "dec-$codec-bt601" "ref601-$codec" planes
            with_rows check-rows "$rows" decoded "dec-$codec-bt601-nv12" "$record/ref601-$codec-hashes.txt" \
                filesrc location="$clip601" ! "${codec}parse" ! nvv4l2decoder ! nvvidconv \
                ! 'video/x-raw,format=NV12' ! videoconvert ! 'video/x-raw,format=I420'
        fi
        rm -f "$clip601" "$rows"
    fi
    verdict='' tried=''
    for i in "${!route_suffix[@]}"; do
        name=dec-$codec${route_suffix[i]}
        how=$(match "$name")
        [[ -n $how ]] || continue
        rounding=$(half_rows "$name" below)
        tried+="${tried:+; }${route_about[i]}: $how (identical $(identical "$name"), Y identical $(y_identical "$name")${rounding:+; colour against the rows averaged with the row below: $rounding})"
        case $how in
            identical)
                verdict="PASS $CLIP_FRAMES frames identical to libav's on ${route_about[i]}"
                break ;;
            luma+chroma-half-row-*)
                [[ -n $verdict ]] || verdict="PASS on ${route_about[i]}: Y identical to libav's in all $CLIP_FRAMES frames, U and V libav's with each row averaged with the row ${how##*-} (nvvidconv) in all $CLIP_FRAMES, $(half_rows "$name" "${how##*-}")" ;;
        esac
    done
    [[ -n $verdict ]] || verdict="FAIL no route matched libav's frames ($tried)"
    check "DECODE_$upper" "$verdict"
    rm -f "$frames"/*"$codec"*-head.raw
done

# For the record: a 1280x720 BT.601 stream. 720 rows fill whole 16-row
# blocks, so the decoder's picture has no padding rows to crop, as 1080 rows
# do (it holds 1088): does nvvidconv move the colour there too?
at_720p() { local WIDTH=1280 HEIGHT=720; "$@"; }
mapfile -t small_source < <(pattern "$TEST_FRAMES" 'video/x-raw,format=I420,width=1280,height=720,framerate=30/1,colorimetry=bt601')
clip720=$frames/clip720.h264 rows=$frames/ref720-h264.rows
read -ra make <<< "${encoder[h264]}"
if ! wants decode; then
    printf 'DECODE_720P_H264 match=- (decoding skipped)\n'
elif run_sw make720-h264 "${small_source[@]}" ! "${make[@]}" ! "${stream_caps[h264]}" ! filesink location="$clip720" \
    && at_720p with_rows save-rows "$rows" hashed sw ref720-h264 filesrc location="$clip720" ! h264parse \
        ! avdec_h264 ! video/x-raw,format=I420; then
    at_720p with_rows check-rows "$rows" decoded dec720-h264 "$record/ref720-h264-hashes.txt" \
        filesrc location="$clip720" ! h264parse ! nvv4l2decoder ! "${to_i420[@]}"
    rounding=$(half_rows dec720-h264 below)
    printf 'DECODE_720P_H264 match=%s identical=%s y_identical=%s%s (for the record)\n' \
        "$(match dec720-h264)" "$(identical dec720-h264)" "$(y_identical dec720-h264)" "${rounding:+, $rounding}"
else
    printf 'DECODE_720P_H264 match=- (the stream was not made)\n'
fi
rm -f "$clip720" "$rows" "$frames"/*720*-head.raw

# --- 4. Encoding: 60 frames by NVENC, decoded back by libav.
if ! wants encode; then
    skipped ENCODE_H264
    skipped ENCODE_H265
elif ! run_sw enc-source "${test_source[@]}" ! filesink location="$frames/enc-source.raw"; then
    check ENCODE_H264 'FAIL the test frames were not made'
    check ENCODE_H265 'FAIL the test frames were not made'
else
    # VIC alone, for the record: I420 into NV12 in NVMM buffers and back,
    # pitch-linear and block-linear (the layout NVDEC writes).
    for layout in pitch blocklinear; do
        bl=()
        if [[ $layout == blocklinear ]]; then
            has_property nvvidconv bl-output || { printf 'VIC_BLOCKLINEAR=skipped (nvvidconv has no bl-output)\n'; continue; }
            bl=(bl-output=true)
        fi
        if run_nv "vic-$layout" "${test_source[@]}" ! nvvidconv "${bl[@]}" ! 'video/x-raw(memory:NVMM),format=NV12' \
                ! "${to_i420[@]}" ! filesink location="$frames/vic-$layout.raw" \
            && compare "vic-$layout" "$frames/enc-source.raw" "$frames/vic-$layout.raw" 40; then
            printf 'VIC_%s=PASS %s\n' "${layout^^}" "$(grep -o 'identical=[0-9]*' "$record/vic-$layout-frames.txt")"
        else
            printf 'VIC_%s=FAIL\n' "${layout^^}"
            [[ -s $frames/vic-$layout.raw ]] && explain "vic-$layout" "$frames/enc-source.raw" "$frames/vic-$layout.raw"
        fi
        rm -f "$frames/vic-$layout.raw"
    done
    for codec in h264 h265; do
        upper=${codec^^}
        out=$frames/enc.$codec
        if skip_h264 "$codec"; then
            printf 'ENCODE_H264=skipped (JetPack 5'"'"'s H.264 encoder crashes on the Nano; R35_H264=1 runs it)\n'
            outcome[ENCODE_H264]=skipped
            continue
        fi
        if run_nv "enc-$codec" "${test_source[@]}" ! "${to_nvmm[@]}" ! "nvv4l2${codec}enc" bitrate=$(( BITRATE * 1000 )) \
                ! "video/x-$codec,stream-format=byte-stream" ! filesink location="$out" \
            && run_sw "enc-$codec-back" filesrc location="$out" ! "${codec}parse" ! "avdec_$codec" \
                ! video/x-raw,format=I420 ! filesink location="$frames/enc-$codec-out.raw"; then
            printf 'ENCODED_%s bytes=%s kbit_per_s=%s\n' "$upper" "$(stat -c %s "$out")" \
                "$(( $(stat -c %s "$out") * 8 * 30 / TEST_FRAMES / 1000 ))"
            "${sw[@]}" timeout 60 gst-launch-1.0 -v filesrc location="$out" ! "${codec}parse" ! fakesink 2>&1 \
                | grep -oE 'profile=\(string\)[a-z0-9-]+' | head -n 1 | sed "s/^.*)/ENCODED_${upper}_PROFILE=/"
            if compare "enc-$codec" "$frames/enc-source.raw" "$frames/enc-$codec-out.raw" 30; then
                check "ENCODE_$upper" PASS
            else
                check "ENCODE_$upper" 'FAIL the decoded frames are not the pattern'
            fi
        else
            check "ENCODE_$upper" 'FAIL the run did not finish'
        fi
        rm -f "$out" "$frames/enc-$codec-out.raw"
    done
    if [[ -f $record/strace/enc-h264.txt && -f $record/strace/enc-h265.txt ]]; then  # CODEC_STRACE=1
        python3 -I "$here/strace_diff.py" diff "$record/strace/enc-h264.txt" "$record/strace/enc-h265.txt" \
            --root "$lib_root" "$tag" 2>&1 | cut -c1-300
    fi
    # For the record: the H.264 encoder with other settings (H264_ENC_VARIANTS).
    IFS=';' read -ra variants <<< "${H264_ENC_VARIANTS:-}"
    for i in "${!variants[@]}"; do
        read -ra props <<< "${variants[i]}"
        (( ${#props[@]} )) || continue
        format=I420
        [[ ${props[0]} == NV12 ]] && format=NV12 props=("${props[@]:1}")
        name=enc-h264-v$(( i + 1 )) out=$frames/enc-h264-v$(( i + 1 )).h264
        if with_limit 60 run_nv "$name" "${test_source[@]}" ! nvvidconv ! "video/x-raw(memory:NVMM),format=$format" \
                ! nvv4l2h264enc bitrate=$(( BITRATE * 1000 )) "${props[@]}" ! video/x-h264,stream-format=byte-stream \
                ! filesink location="$out" \
            && run_sw "$name-back" filesrc location="$out" ! h264parse ! avdec_h264 ! video/x-raw,format=I420 \
                ! filesink location="$frames/$name-out.raw" \
            && compare "$name" "$frames/enc-source.raw" "$frames/$name-out.raw" 30; then
            verdict=PASS
        else
            verdict=FAIL
        fi
        printf 'ENCODE_H264_VARIANT %s %s input=%s properties=%s exit=%s\n' "$name" "$verdict" "$format" \
            "${props[*]:-(defaults)}" "$last_exit"
        rm -f "$out" "$frames/$name-out.raw"
    done
fi

# --- 5. JPEG: the 60 frames as JPEG, by nvjpegdec and by nvv4l2decoder mjpeg=1.
jpeg=FAIL jpeg_detail=''
mjpeg=$frames/test.mjpeg
if wants jpeg && run_sw jpeg-make "${test_source[@]}" ! jpegenc quality=90 ! filesink location="$mjpeg" \
    && run_sw jpeg-ref filesrc location="$mjpeg" ! jpegparse ! jpegdec ! video/x-raw,format=I420 \
        ! filesink location="$frames/jpeg-ref.raw"; then
    printf 'STREAM_MJPEG bytes=%s\n' "$(stat -c %s "$mjpeg")"
    declare -A jpeg_decoder=(
        [nvjpegdec]='nvjpegdec ! video/x-raw,format=I420'
        [nvjpegdec-nvmm]="nvjpegdec ! video/x-raw(memory:NVMM),format=I420 ! ${to_i420[*]}"
        [nvv4l2]="nvv4l2decoder mjpeg=1 ! ${to_i420[*]}"
        [nvv4l2-crop]="nvv4l2decoder mjpeg=1 ! nvvidconv left=0 top=0 right=$WIDTH bottom=$HEIGHT ! video/x-raw,format=I420")
    for way in nvjpegdec nvjpegdec-nvmm nvv4l2 nvv4l2-crop; do
        # nvjpegdec in NVMM buffers only if it did not give system memory.
        [[ $way == nvjpegdec-nvmm && ${outcome[JPEG_NVJPEGDEC]:-} == PASS ]] && continue
        # On the Nano (2026-10-23) VIC scaled the decoder's 1088 rows (whole
        # 16-row blocks) into 1080: crop them instead, if that failed.
        [[ $way == nvv4l2-crop ]] && { [[ ${outcome[JPEG_NVV4L2]:-} == FAIL ]] && has_property nvvidconv bottom || continue; }
        [[ $way == nvjpeg* ]] && ! grep -q 'Factory Details' "$record/inspect-nvjpegdec.txt" && continue
        read -ra tail_elements <<< "${jpeg_decoder[$way]}"
        if run_nv "jpeg-$way" filesrc location="$mjpeg" ! jpegparse ! "${tail_elements[@]}" \
                ! filesink location="$frames/jpeg-$way.raw" \
            && compare "jpeg-$way" "$frames/jpeg-ref.raw" "$frames/jpeg-$way.raw" 40; then
            check "JPEG_${way^^}" PASS
            jpeg=PASS jpeg_detail+=" $way"
        else
            printf 'JPEG_%s=FAIL\n' "${way^^}"
            outcome[JPEG_${way^^}]=FAIL
            [[ -s $frames/jpeg-$way.raw ]] && explain "jpeg-$way" "$frames/jpeg-ref.raw" "$frames/jpeg-$way.raw"
        fi
        rm -f "$frames/jpeg-$way.raw"
    done
fi
if wants jpeg; then check JPEG "$jpeg${jpeg_detail:+ by$jpeg_detail}"; else skipped JPEG; fi
rm -f "$frames/jpeg-ref.raw" "$frames/enc-source.raw"

# --- 6. Speed, for the record (not counted).
if wants speed; then
    for codec in h264 h265; do
        clip=$frames/clip.$codec
        [[ -s $clip ]] || continue
        if run_nv "speed-dec-$codec" filesrc location="$clip" ! "${codec}parse" ! nvv4l2decoder ! fakesink sync=false; then
            speed "speed-dec-$codec" "$CLIP_FRAMES"
        fi
        if has_property nvv4l2decoder enable-max-performance \
            && run_nv "speed-dec-$codec-max" filesrc location="$clip" ! "${codec}parse" \
                ! nvv4l2decoder enable-max-performance=true ! fakesink sync=false; then
            speed "speed-dec-$codec-max" "$CLIP_FRAMES"
        fi
        run_sw "speed-libav-$codec" filesrc location="$clip" ! "${codec}parse" ! "avdec_$codec" ! fakesink sync=false \
            && speed "speed-libav-$codec" "$CLIP_FRAMES"
    done
    if run_nv speed-source "${clip_source[@]}" ! "${to_nvmm[@]}" ! fakesink sync=false; then
        speed speed-source "$CLIP_FRAMES"
        for codec in h264 h265; do
            skip_h264 "$codec" && continue
            run_nv "speed-enc-$codec" "${clip_source[@]}" ! "${to_nvmm[@]}" ! "nvv4l2${codec}enc" bitrate=$(( BITRATE * 1000 )) \
                ! fakesink sync=false && speed "speed-enc-$codec" "$CLIP_FRAMES"
        done
    fi
    [[ -s $mjpeg ]] && run_nv speed-jpeg-nvv4l2 filesrc location="$mjpeg" ! jpegparse ! nvv4l2decoder mjpeg=1 \
        ! fakesink sync=false && speed speed-jpeg-nvv4l2 "$TEST_FRAMES"
    [[ -s $mjpeg ]] && run_sw speed-jpegdec filesrc location="$mjpeg" ! jpegparse ! jpegdec ! fakesink sync=false \
        && speed speed-jpegdec "$TEST_FRAMES"
fi
rm -f "$frames"/clip.* "$mjpeg"

# --- 7. Webcam, for the record (not counted).
webcam=${WEBCAM:-/dev/video0}
if wants webcam && [[ $webcam != none && -c $webcam ]]; then
    cam=(v4l2src device="$webcam" num-buffers="$CLIP_FRAMES" ! 'image/jpeg,width=1920,height=1080,framerate=30/1' ! jpegparse)
    run_nv webcam-nvv4l2 "${cam[@]}" ! nvv4l2decoder mjpeg=1 ! fakesink sync=false \
        && speed webcam-nvv4l2 "$CLIP_FRAMES"
    run_sw webcam-jpegdec "${cam[@]}" ! jpegdec ! fakesink sync=false && speed webcam-jpegdec "$CLIP_FRAMES"
else
    printf 'WEBCAM=skipped (%s)\n' "$(wants webcam && echo "$webcam" || echo 'not in CODEC_STEPS')"
fi

finish

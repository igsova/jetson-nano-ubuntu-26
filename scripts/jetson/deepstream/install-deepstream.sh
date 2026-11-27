#!/usr/bin/env bash
# Install NVIDIA DeepStream 6.0.1 on a converted Nano, beside Ubuntu 26.04,
# and check it on NVIDIA's sample video.
#
# DeepStream 6.0.1 is JetPack 4.6's, the last DeepStream built for the
# Nano's GPU, and it needs JetPack 4's whole user space: Ubuntu 18.04's
# libraries and GStreamer 1.14, L4T R32.7's driver, EGL and video libraries,
# CUDA 10.2, cuDNN 8.2 and TensorRT 8.2. This kernel runs JetPack 4's
# libraries (patches/jp5), so this script gives DeepStream that user space
# whole: an Ubuntu 18.04 root in a folder, with NVIDIA's packages from
# NVIDIA's own repositories, entered by nano-deepstream. Ubuntu 26.04 and
# its GPU stack are not changed. docs/DEEPSTREAM.md has the background.
#
# Usage, from an SSH login or a terminal on the Nano, in this folder:
#   sudo bash install-deepstream.sh            # install (once) and check
#   sudo bash install-deepstream.sh --video clip.mp4
#                                              # check on your own H.264 MP4
#
# What it changes:
#   - installs debootstrap, curl and gpg from Ubuntu's archive if missing;
#   - builds the root at /opt/nano-ds601 (about 5 GB; needs 10 GiB free):
#     Ubuntu 18.04 from ports.ubuntu.com by debootstrap, checked against
#     Ubuntu's archive keyring, then NVIDIA's r32.7 repositories, their key
#     checked by fingerprint;
#   - installs the launcher as /usr/local/bin/nano-deepstream.
# NVIDIA's bootloader and kernel packages are pinned out of the root and
# checked absent, and the root never sees a disk or flash device, so
# nothing in it can reach the card's boot partitions or the module's boot
# firmware (docs/SAFETY.md).
#
# A rerun goes on from the first step that has not passed. The check runs
# deepstream-app on DeepStream's sample_1080p_h264.mp4: hardware decode,
# nvstreammux at 1280x720, the sample ResNet-10 detector in FP16 through
# TensorRT (whose engine the first run builds, a few minutes), boxes drawn
# by nvdsosd and a hardware H.264 encode to out.mp4. It passes when
# deepstream-app exits 0, every frame reaches the detector's output, most
# frames hold an object (NVIDIA's sample only) and out.mp4 is written.
#
# Record: ~/deepstream-check/<time> (summary.txt, logs, out.mp4). The last
# line is DEEPSTREAM_INSTALL=PASS or FAIL.
# Undo: sudo bash uninstall-deepstream.sh
set -uo pipefail

KERNEL=5.10.216-tegra
ROOT=${NANO_DS_ROOT:-/opt/nano-ds601}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LAUNCHER=/usr/local/bin/nano-deepstream
MIN_FREE_KIB=$((10 * 1024 * 1024))
PORTS=http://ports.ubuntu.com/ubuntu-ports
NV_REPO=https://repo.download.nvidia.com/jetson
NV_KEY_URL=$NV_REPO/jetson-ota-public.asc
NV_KEY_FINGERPRINT=3C6D1FF3100C8C3ABB0869C0E6543461A9996195
DS=/opt/nvidia/deepstream/deepstream-6.0
RUN_SECONDS=${NANO_DS_CHECK_SECONDS:-1800}
# NVIDIA's packages that write boot firmware or a kernel: never in the root.
BLOCKED=(nvidia-l4t-bootloader nvidia-l4t-kernel nvidia-l4t-kernel-dtbs nvidia-l4t-kernel-headers)
NV_PACKAGES=(nvidia-l4t-core nvidia-l4t-init nvidia-l4t-x11 nvidia-l4t-cuda nvidia-l4t-3d-core
             nvidia-l4t-multimedia nvidia-l4t-multimedia-utils nvidia-l4t-gstreamer nvidia-l4t-firmware
             cuda-libraries-10-2 libcudnn8 libnvinfer8 libnvinfer-plugin8 libnvparsers8
             libnvonnxparsers8 deepstream-6.0)
# NVIDIA's DeepStream 6.0 guide for Jetson, "Install Dependencies", and a font.
DS_DEPS=(libssl1.0.0 libgstreamer1.0-0 gstreamer1.0-tools gstreamer1.0-plugins-good
         gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav
         libgstrtspserver-1.0-0 libjansson4 libyaml-cpp-dev fonts-dejavu-core)
ELEMENTS=(nvstreammux nvinfer nvdsosd nvvideoconvert nvmultistreamtiler nvtracker
          nvv4l2decoder nvv4l2h264enc nvvidconv)
# Libraries the dynamic linker must find in the root.
KEY_LIBS=(libcuda.so.1 libnvbufsurface.so.1.0.0 libnvbufsurftransform.so.1.0.0 libnvmedia.so
          libnvdla_compiler.so libnvrm.so libnvdsbufferpool.so.1.0.0 libEGL_nvidia.so.0)
# deepstream-app and the plugins the check uses must link fully; DeepStream's
# optional parts (Kafka, AMQP, Redis, Azure, Triton, Rivermax) are listed only.
REQUIRED_FILES=" deepstream-app libnvdsgst_multistream.so libnvdsgst_infer.so libnvdsgst_osd.so libnvdsgst_multistreamtiler.so libnvdsgst_tracker.so "

die() { printf 'DEEPSTREAM_INSTALL=FAIL: %s\n' "$*" | tee -a "${summary:-/dev/null}" >&2; exit 1; }
note() { printf '%s\n' "$*" | tee -a "$summary"; }

[[ $(id -u) -eq 0 ]] || { echo 'run this with sudo' >&2; exit 1; }
owner=${SUDO_USER:-}
[[ -n $owner && $owner != root ]] || { echo 'run this with sudo from your own account' >&2; exit 1; }
IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || { echo "no account $owner" >&2; exit 1; }
video=''
if [[ ${1:-} == --video && $# -eq 2 ]]; then
    video=$(readlink -f -- "$2")
    [[ -f $video ]] || { echo "no file $2" >&2; exit 2; }
elif [[ $# -ne 0 ]]; then
    echo 'usage: sudo bash install-deepstream.sh [--video CLIP.mp4]' >&2; exit 2
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$home/deepstream-check/$stamp
install -d -o "$uid" -g "$gid" -m 0755 "$home/deepstream-check" "$record"
summary=$record/summary.txt
: > "$summary"
trap 'chown -R "$uid:$gid" "$record"' EXIT
note "RECORD=$record"
note "ROOT=$ROOT"

# --- 1. The system.
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
compatible=$(tr '\0' ' ' < /proc/device-tree/compatible 2> /dev/null)
[[ $compatible == *nvidia,jetson-nano* ]] || die "not a Jetson Nano: $compatible"
[[ -f $HERE/nano-deepstream ]] || die "no nano-deepstream next to this script"
for tool in apt-get unshare chroot setpriv findmnt df timeout; do
    command -v "$tool" > /dev/null || die "no $tool"
done
need=()
command -v debootstrap > /dev/null || need+=(debootstrap)
command -v curl > /dev/null || need+=(curl)
command -v gpg > /dev/null || need+=(gpg)
if (( ${#need[@]} )); then
    note "HOST_TOOLS=installing ${need[*]} with apt"
    apt-get install -y --no-install-recommends "${need[@]}" > "$record/apt-host-tools.log" 2>&1 \
        || die "apt could not install ${need[*]} ($record/apt-host-tools.log)"
fi
[[ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]] || die 'no /usr/share/keyrings/ubuntu-archive-keyring.gpg'
install -d -m 0755 "$ROOT"
[[ -n $(find "$ROOT" -maxdepth 0 -empty) || -f $ROOT/.nano-ds601 ]] || die "$ROOT exists and is not DeepStream's root"
findmnt -rn -o TARGET | grep -q "^$ROOT/" && die "something is mounted under $ROOT"
touch "$ROOT/.nano-ds601"
(( ${#need[@]} )) && printf '%s\n' "${need[@]}" >> "$ROOT/.nano-ds601-host-tools"
free_kib=$(df -Pk "$ROOT" | awk 'NR == 2 { print $4 }')
if [[ ! -f $ROOT/.nano-ds601-packages ]]; then
    (( free_kib >= MIN_FREE_KIB )) || die "needs 10 GiB free for $ROOT, has $((free_kib / 1024)) MiB"
fi

# --- 2. Ubuntu 18.04, in a private mount namespace.
if [[ ! -f $ROOT/.nano-ds601-base ]]; then
    note "BASE=debootstrap bionic minbase from $PORTS (a few minutes)"
    unshare --mount --propagation private debootstrap --arch=arm64 --variant=minbase --include=ca-certificates \
        --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg bionic "$ROOT" "$PORTS" \
        > "$record/debootstrap.log" 2>&1 || die "debootstrap failed ($record/debootstrap.log)"
    touch "$ROOT/.nano-ds601-base"
fi
note "BASE=PASS $(. "$ROOT/etc/os-release"; echo "$PRETTY_NAME")"

# --- 3. NVIDIA's repositories and key, the pins and the root's settings
# (written on every run, so a rerun takes this script's).
if [[ ! -f $ROOT/etc/apt/trusted.gpg.d/jetson-ota-public.asc ]]; then
    curl -fsSL "$NV_KEY_URL" -o "$record/jetson-ota-public.asc" || die "cannot download $NV_KEY_URL"
    fpr=$(gpg --show-keys --with-colons "$record/jetson-ota-public.asc" 2> /dev/null | awk -F: '/^fpr:/ { print $10; exit }')
    [[ $fpr == "$NV_KEY_FINGERPRINT" ]] || die "NVIDIA key fingerprint $fpr, expected $NV_KEY_FINGERPRINT"
    install -m 0644 "$record/jetson-ota-public.asc" "$ROOT/etc/apt/trusted.gpg.d/jetson-ota-public.asc"
fi
printf 'deb %s bionic%s main universe\n' "$PORTS" '' "$PORTS" -updates "$PORTS" -security > "$ROOT/etc/apt/sources.list"
printf 'deb %s/common r32.7 main\ndeb %s/t210 r32.7 main\n' "$NV_REPO" "$NV_REPO" > "$ROOT/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
for p in "${BLOCKED[@]}"; do printf 'Package: %s\nPin: version *\nPin-Priority: -1\n\n' "$p"; done \
    > "$ROOT/etc/apt/preferences.d/nano-ds601-no-boot"
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"; chmod 0755 "$ROOT/usr/sbin/policy-rc.d"
# NVIDIA's flag for L4T packages in a container: no boot firmware update.
install -d "$ROOT/opt/nvidia/l4t-packages"
touch "$ROOT/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"
# The linker's folders, as JetPack 4 sets them, and DeepStream's own.
install -d "$ROOT/etc/ld.so.conf.d"
printf '/usr/lib/aarch64-linux-gnu/tegra\n/usr/lib/aarch64-linux-gnu/tegra-egl\n' > "$ROOT/etc/ld.so.conf.d/nano-ds601-tegra.conf"
printf '%s/lib\n' "$DS" > "$ROOT/etc/ld.so.conf.d/nano-ds601-deepstream.conf"
note "NVIDIA_KEY=PASS $NV_KEY_FINGERPRINT"
note "PINNED_OUT=${BLOCKED[*]}"

install -m 0755 "$HERE/nano-deepstream" "$LAUNCHER" || die "cannot install $LAUNCHER"
note "LAUNCHER=$LAUNCHER"
in_root() { NANO_DS_ROOT=$ROOT "$LAUNCHER" "$@" < /dev/null; }

# --- 4. NVIDIA's packages and DeepStream.
if [[ ! -f $ROOT/.nano-ds601-packages ]]; then
    note 'PACKAGES=installing JetPack 4.6 user space and DeepStream 6.0.1 (about 2.5 GB of downloads)'
    in_root apt-get update > "$record/apt-update.log" 2>&1 \
        || { grep -E '^(E|W|Err):' "$record/apt-update.log" | tee -a "$summary"; die "apt-get update failed ($record/apt-update.log)"; }
    in_root apt-get install -y --no-install-recommends "${NV_PACKAGES[@]}" "${DS_DEPS[@]}" > "$record/apt-install.log" 2>&1 \
        || { tail -30 "$record/apt-install.log" | tee -a "$summary"; die "apt-get install failed ($record/apt-install.log)"; }
    touch "$ROOT/.nano-ds601-packages"
fi
in_root dpkg-query -W -f '${Package} ${Version}\n' > "$record/packages.txt"
for p in deepstream-6.0 nvidia-l4t-core libnvinfer8 libcudnn8 cuda-cudart-10-2 libgstreamer1.0-0; do
    note "PACKAGE $(grep -E "^$p " "$record/packages.txt" || echo "$p missing")"
done
for p in "${BLOCKED[@]}"; do
    grep -q "^$p " "$record/packages.txt" && die "$p is installed in the root, which must not happen"
done
note 'BLOCKED_PACKAGES=PASS none installed'
# docs/SAFETY.md names three JetPack 4 packages that write the boot flash when
# installed or started. nvidia-l4t-3d-core (NVIDIA's EGL, which DeepStream's
# buffer libraries need) depends on nvidia-l4t-init, so the root holds some
# of them. In the root they cannot reach the flash: it has no service
# manager, no flash or disk device node, a read-only /sys, and its programs
# cannot make device nodes (nano-deepstream). Listed here for the record.
present=''
for p in nvidia-l4t-init nvidia-l4t-tools nvidia-l4t-xusb-firmware; do
    grep -q "^$p " "$record/packages.txt" && present+="$p "
done
note "FLASH_PACKAGES_IN_ROOT=${present:-none} (inert in the root: docs/DEEPSTREAM.md)"

# --- 5. Libraries, EGL and GStreamer.
vendors=$ROOT/usr/share/glvnd/egl_vendor.d
if [[ ! -f $vendors/10_nvidia.json ]]; then
    install -d "$vendors"
    printf '{\n    "file_format_version" : "1.0.0",\n    "ICD" : {\n        "library_path" : "libEGL_nvidia.so.0"\n    }\n}\n' \
        > "$vendors/10_nvidia.json"
fi
in_root ldconfig || die 'ldconfig failed in the root'
in_root ldconfig -p > "$record/ldconfig-p.txt"
for lib in "${KEY_LIBS[@]}"; do
    awk -v l="$lib" '$1 == l { found = 1 } END { exit !found }' "$record/ldconfig-p.txt" \
        || die "the root's linker cannot find $lib"
done
note "LDCONFIG=PASS ${KEY_LIBS[*]}"
in_root sh -c "for f in $DS/bin/deepstream-app $DS/lib/*.so $DS/lib/gst-plugins/*.so; do
    ldd \$f 2>&1 | sed -n \"s|^[[:space:]]*\\([^ ]*\\) => not found|\$f \\1|p\"; done" > "$record/ldd-missing.txt"
required_missing=''; optional_missing=''
while read -r file lib; do
    if [[ $REQUIRED_FILES == *" ${file##*/} "* ]]; then required_missing+="${file##*/} needs $lib; "
    else optional_missing+="${file##*/}:$lib "; fi
done < "$record/ldd-missing.txt"
[[ -z $optional_missing ]] || note "OPTIONAL_MISSING (DeepStream parts the check does not use) $optional_missing"
[[ -z $required_missing ]] || die "DeepStream links libraries the root lacks: $required_missing"
note 'LIBRARIES=PASS'
rm -f "$ROOT/root/.cache/gstreamer-1.0/registry.aarch64.bin"
missing_elements=''
for e in "${ELEMENTS[@]}"; do
    in_root gst-inspect-1.0 "$e" > "$record/inspect-$e.txt" 2>&1 || missing_elements+="$e "
done
if [[ -n $missing_elements ]]; then
    in_root gst-inspect-1.0 -b 2>&1 | head -30 | tee -a "$summary"
    die "GStreamer has no $missing_elements"
fi
note "ELEMENTS=PASS ${ELEMENTS[*]}"

# --- 6. The check: deepstream-app on a clip.
run=/var/lib/nano-ds601/check
rm -rf "${ROOT:?}$run"; install -d "$ROOT$run/kitti"
models=$DS/samples/models/Primary_Detector_Nano
[[ -f $ROOT$models/resnet10.caffemodel ]] || die "no sample ResNet-10 detector at $models"
if [[ -n $video ]]; then
    cp -- "$video" "$ROOT$run/input.mp4" || die "cannot copy $video"
    clip=$run/input.mp4
else
    clip=$DS/samples/streams/sample_1080p_h264.mp4
fi
[[ -f $ROOT$clip ]] || die "no $clip"
note "CLIP=${video:-$clip}"
cat > "$ROOT$run/infer.txt" << EOF
[property]
gpu-id=0
net-scale-factor=0.0039215697906911373
model-file=$models/resnet10.caffemodel
proto-file=$models/resnet10.prototxt
labelfile-path=$models/labels.txt
model-engine-file=$models/resnet10.caffemodel_b1_gpu0_fp16.engine
force-implicit-batch-dim=1
batch-size=1
network-mode=2
num-detected-classes=4
interval=0
gie-unique-id=1
output-blob-names=conv2d_bbox;conv2d_cov/Sigmoid
cluster-mode=2

[class-attrs-all]
pre-cluster-threshold=0.2
nms-iou-threshold=0.5
topk=20
EOF
cat > "$ROOT$run/app.txt" << EOF
[application]
enable-perf-measurement=1
perf-measurement-interval-sec=5
gie-kitti-output-dir=$run/kitti

[source0]
enable=1
type=2
uri=file://$clip
num-sources=1
gpu-id=0
cudadec-memtype=0

[streammux]
gpu-id=0
live-source=0
batch-size=1
batched-push-timeout=40000
width=1280
height=720
enable-padding=0
nvbuf-memory-type=0

[primary-gie]
enable=1
gpu-id=0
batch-size=1
gie-unique-id=1
nvbuf-memory-type=0
config-file=$run/infer.txt

[osd]
enable=1
gpu-id=0
border-width=2
text-size=15
text-color=1;1;1;1
text-bg-color=0.3;0.3;0.3;1
font=DejaVu Sans
display-text=1
display-bbox=1
nvbuf-memory-type=0

[tiled-display]
enable=0

[sink0]
enable=1
type=3
container=1
codec=1
enc-type=0
sync=0
bitrate=4000000
output-file=$run/out.mp4
source-id=0

[tests]
file-loop=0
EOF
cp "$ROOT$run/app.txt" "$ROOT$run/infer.txt" "$record/"
note "CHECK=deepstream-app (the first run builds the TensorRT engine; limit ${RUN_SECONDS}s)"
start=$(date +%s)
# The launcher's stdin is /dev/null: under timeout deepstream-app runs in the
# background, and reading the terminal would stop it.
timeout -k 10 "$RUN_SECONDS" env NANO_DS_ROOT="$ROOT" "$LAUNCHER" deepstream-app -c "$run/app.txt" \
    < /dev/null > "$record/deepstream-app.log" 2>&1
status=$?
note "DEEPSTREAM_APP_EXIT=$status seconds=$(( $(date +%s) - start ))"
perf=$(grep -oE '^\*\*PERF:[^0-9]*[0-9.]+ \([0-9.]+\)' "$record/deepstream-app.log" | tail -1 | sed 's/^\*\*PERF: *//')
note "FRAMES_A_SECOND=${perf:-none} (last interval (average))"
frames=$(find "$ROOT$run/kitti" -type f | wc -l)
with_objects=$(find "$ROOT$run/kitti" -type f -size +0 | wc -l)
objects=$(cat "$ROOT$run/kitti"/* 2> /dev/null | wc -l)
classes=$(cat "$ROOT$run/kitti"/* 2> /dev/null | awk '{ print $1 }' | sort | uniq -c | tr -s ' \n' ' ')
note "DETECTIONS frames=$frames frames_with_objects=$with_objects objects=$objects classes:${classes:- none}"
mp4=$(stat -c %s "$ROOT$run/out.mp4" 2> /dev/null || echo 0)
cp "$ROOT$run/out.mp4" "$record/" 2> /dev/null
note "OUT_MP4=$record/out.mp4 bytes=$mp4"
[[ $status -eq 0 ]] || { tail -20 "$record/deepstream-app.log" | tee -a "$summary"; die "deepstream-app exited $status ($record/deepstream-app.log)"; }
(( frames > 0 && mp4 > 0 )) || die 'deepstream-app wrote no detections or no video'
if [[ -z $video ]]; then
    (( frames >= 1400 )) || die "only $frames of the sample's frames reached the detector's output"
    (( with_objects * 2 >= frames )) || die "objects in only $with_objects of $frames frames"
fi
note "DEEPSTREAM_INSTALL=PASS deepstream=6.0.1 frames=$frames objects=$objects frames_a_second=\"${perf:-none}\""

#!/usr/bin/env bash
# Put the reference card's Ubuntu 26.04 desktop on the GPU, as JetPack 4's is (stage 5).
#
# Usage: sudo bash add-u26-gpu-desktop.sh DEBS_DIR
#
# Run as root on the Nano from the reference card's everyday 5.10 boot, after
# build-u26-root.sh and add-u26-desktop.sh passed. DEBS_DIR holds the
# nano-l4t-gl and nano-l4t-x11 .debs from scripts/host/build-nano-l4t-debs.py,
# each checked against its pinned SHA-256. In a chroot on the UBUNTU26
# partition it installs them, with mesa-utils from Ubuntu's signed archive for
# glxinfo, and points LightDM at the X server 1.20 in /usr/lib/nano-xorg with
# NVIDIA's X driver. 26.04's own X server, its framebuffer settings and Mesa
# stay installed: removing /etc/lightdm/lightdm.conf.d/60-jetson-gpu.conf goes
# back to them. Then it checks that the X server, its modules and NVIDIA's GL
# libraries link in 26.04 and that CUDA still runs on the real GPU. It writes
# only the UBUNTU26 partition and a record under the owner's home; APP, its
# boot and the QSPI stay untouched. Rerunning it is safe.
set -euo pipefail

KERNEL=5.10.216-tegra
CARD_BYTES=63864569856
APP_PARTUUID=5ac80d7c-40fb-4796-bd56-4110e389819b
PART=/dev/mmcblk0p15
NAME=UBUNTU26
L4T=32.7.6-20241104234540+u26.1
declare -A PINS=(  # file in DEBS_DIR -> SHA-256
    # scripts/host/build-nano-l4t-debs.py at 05f574c, on the owner's PC (2026-10-15)
    [nano-l4t-gl_${L4T}_arm64.deb]=54f42b2d11248b77da7210eda03f62c56c652a24b87f096301a902e0f775ad08
    [nano-l4t-x11_${L4T}_arm64.deb]=318d554b06d995e1c29d7fb01732096e1dbc29511cee04a3126da2eb02efea86
)
PACKAGES=(mesa-utils)
XSERVER='/usr/lib/nano-xorg/Xorg -nolisten tcp -modulepath /usr/lib/nano-xorg/modules -config /etc/X11/nano-xorg.conf -configdir /etc/X11/nano-xorg.conf.d'

die() { printf 'U26_GPU_DESKTOP=FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 ]] || { printf 'Usage: sudo bash %s DEBS_DIR\n' "$0" >&2; exit 2; }
[[ $EUID == 0 && $(uname -m) == aarch64 ]] || die 'run as root on the Nano'
self=$(realpath -e -- "$0")
debs=$(realpath -e -- "$1")

# All mounts below live in a private mount namespace and vanish with it.
if [[ ${U26_GPU_NS:-} != 1 ]]; then
    # JetPack 4's desktop automounts UBUNTU26 at boot as /media/<user>/UBUNTU26.
    # Undo only that mount, here, before the private namespace copies it.
    targets=$(findmnt -n -l -o TARGET -S "$PART" || true)
    if grep -qx "/media/[a-z_][a-z0-9_-]*/$NAME" <<<"$targets"; then
        udisksctl unmount -b "$PART" || die "could not undo the desktop's automount of $PART"
    fi
    exec unshare --mount --propagation private env U26_GPU_NS=1 bash "$self" "$debs"
fi

# --- The machine: the reference card's everyday 5.10 boot, with a passed 26.04 build and desktop.
[[ $(uname -r) == "$KERNEL" ]] || die "running $(uname -r); boot the reference card's everyday 5.10 entry"
grep -q 'REVISION: 7.6,' /etc/nv_tegra_release || die 'not L4T R32.7.6 user space'
[[ $(blockdev --getsize64 /dev/mmcblk0) == "$CARD_BYTES" ]] || die 'mmcblk0 is not the reference card'
[[ $(findmnt -n -o SOURCE /) == /dev/mmcblk0p1 ]] || die 'the root is not mmcblk0p1'
[[ $(blkid -s PARTUUID -o value /dev/mmcblk0p1) == "$APP_PARTUUID" ]] || die 'mmcblk0p1 is not the reference card APP'
[[ $(lsblk -nro PARTLABEL | grep -cx "$NAME") == 1 ]] || die "not exactly one $NAME partition"
[[ $(lsblk -dno PARTLABEL "$PART") == "$NAME" ]] || die "$PART is not $NAME"
[[ $(blkid -s LABEL -o value "$PART") == "$NAME" && $(blkid -s TYPE -o value "$PART") == ext4 ]] \
    || die "$PART has no ext4 filesystem labelled $NAME"
fs_uuid=$(blkid -s UUID -o value "$PART")
! findmnt -n -S "$PART" >/dev/null || die "$PART is mounted; unmount it first"
owner=$(getent passwd 1000) || die 'no account with UID 1000'
IFS=: read -r user _ _ _ _ home _ <<<"$owner"
[[ $user =~ ^[a-z_][a-z0-9_-]*$ && $home == /home/$user && -d $home ]] || die "unexpected account $user"
newest() { find "$home/$1" -mindepth 1 -maxdepth 1 -type d -name '20*Z' 2>/dev/null | sort | tail -n 1 || true; }
build=$(newest u26-build)
[[ -n $build && -f $build/build.log && -f $build/summary.txt ]] || die 'no 26.04 build record'
[[ $(tail -n 1 "$build/build.log") == U26_ROOT=PASS* ]] || die "the newest build ($build) did not pass"
grep -qx "fs_uuid=$fs_uuid" "$build/summary.txt" || die 'the build record names another filesystem'
desktop=$(newest u26-desktop)
[[ -n $desktop && -f $desktop/desktop.log && -f $desktop/summary.txt ]] || die 'no desktop record; run add-u26-desktop.sh first'
[[ $(tail -n 1 "$desktop/desktop.log") == U26_DESKTOP=PASS* ]] || die "the newest desktop step ($desktop) did not pass"
grep -qx "fs_uuid=$fs_uuid" "$desktop/summary.txt" || die 'the desktop record names another filesystem'
for deb in "${!PINS[@]}"; do
    [[ -f $debs/$deb ]] || die "missing $debs/$deb"
    [[ $(sha256sum "$debs/$deb" | cut -d' ' -f1) == "${PINS[$deb]}" ]] || die "$deb does not match its pinned SHA-256"
done
for _ in $(seq 24); do
    timedatectl status | grep -q 'System clock synchronized: yes' && break
    sleep 5
done
timedatectl status | grep -q 'System clock synchronized: yes' || die 'the clock has not synchronized yet'

# --- The record, on APP in the owner's home; secrets never go to it.
stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$home/u26-gpu-desktop/$stamp
install -d -m 0755 -o 1000 -g 1000 "$home/u26-gpu-desktop"
install -d -m 0755 "$record"
exec 3>&1 4>&2
exec > >(tee "$record/gpu-desktop.log") 2>&1
tee_pid=$!
printf 'started %s on %s %s\n' "$stamp" "$(uname -r)" "$(uname -v)"
printf 'target %s (%s, filesystem %s), build %s, desktop %s\n' "$PART" "$NAME" "$fs_uuid" "${build##*/}" "${desktop##*/}"
for deb in "${!PINS[@]}"; do printf '%s  %s\n' "${PINS[$deb]}" "$deb"; done | sort -k2

root=/run/u26-gpu/root
mounted=()
cleanup() {
    local status=$? i
    rm -rf "$root/usr/sbin/policy-rc.d" "$root/var/tmp/u26-gpu-inputs" 2>/dev/null || true
    for ((i=${#mounted[@]}-1; i>=0; i--)); do
        umount -R "${mounted[i]}" || { umount -R -l "${mounted[i]}"; printf 'UNMOUNT_WARNING=%s\n' "${mounted[i]}"; }
    done
    sync
    chown -R 1000:1000 "$record" || true
    if (( status != 0 )); then printf 'U26_GPU_DESKTOP=FAIL exit=%s record=%s\n' "$status" "$record"; fi
    exec 1>&3 2>&4  # tee sees end of input and finishes the log
    wait "$tee_pid" 2>/dev/null || sleep 2
    exit "$status"
}
trap cleanup EXIT
install -d -m 0700 /run/u26-gpu
install -d -m 0755 "$root"
mount -t ext4 -o noatime "$PART" "$root"
mounted+=("$root")
[[ -f $root/var/log/nano-u26/build-${build##*/}.txt && -f $root/var/log/nano-u26/desktop-${desktop##*/}.txt ]] \
    || die "the 26.04 root lacks build ${build##*/} or desktop ${desktop##*/}"
(( $(df -B1 --output=avail "$root" | tail -n 1) > 2000000000 )) || die "$NAME has under 2 GB free"

mount -t proc proc "$root/proc"; mounted+=("$root/proc")
mount --bind /sys "$root/sys"; mounted+=("$root/sys")
mount -o remount,bind,ro "$root/sys"
mount --rbind /dev "$root/dev"; mounted+=("$root/dev")
mount --make-rslave "$root/dev"
mount -t tmpfs -o nosuid,nodev,mode=0755,size=64m tmpfs "$root/run"; mounted+=("$root/run")
install -d -m 0755 "$root/run/systemd/resolve"
cp -L /etc/resolv.conf "$root/run/systemd/resolve/stub-resolv.conf"

in_root() {
    chroot "$root" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C TERM=dumb DEBIAN_FRONTEND=noninteractive "$@"
}
printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"
chmod 0755 "$root/usr/sbin/policy-rc.d"

# --- The packages. The plan may install and upgrade, never remove, and must
# leave systemd, glibc, the X server 21.1 and the other NVIDIA packages as they are.
stage=$root/var/tmp/u26-gpu-inputs
install -d -m 0755 "$stage"
for deb in "${!PINS[@]}"; do cp "$debs/$deb" "$stage/"; done
inputs=("$stage"/*.deb)
inputs=("${inputs[@]#"$root"}")
in_root dpkg-query -W -f '${Package} ${Version}\n' > "$record/packages-before.txt"
in_root apt-get update
in_root apt-get -s --no-install-recommends install "${inputs[@]}" "${PACKAGES[@]}" > "$record/plan.txt"
if grep -E '^Remv ' "$record/plan.txt"; then die 'the plan removes packages'; fi
keep='(systemd|systemd-sysv|udev|libc6|libc-bin|libpam-systemd|libnss-systemd|xserver-xorg-core|nano-l4t-(core|cuda|power)|cuda-[a-z]+-10-2|libcublas10|libcu(fft|rand|solver|sparse)-10-2|libnpp-10-2)'
if grep -E "^Inst $keep " "$record/plan.txt"; then
    die 'the plan changes systemd, glibc, the X server or the other NVIDIA packages'
fi
printf 'plan: %s packages to install or upgrade\n' "$(grep -c '^Inst ' "$record/plan.txt")"
in_root apt-get --yes --no-install-recommends -o Dpkg::Options::=--force-confold \
    install "${inputs[@]}" "${PACKAGES[@]}"
rm -rf "$stage"
in_root ldconfig

# --- LightDM starts X server 1.20 with NVIDIA's driver instead of 26.04's on fbdev.
cat > "$root/etc/lightdm/lightdm.conf.d/60-jetson-gpu.conf" <<EOF
# The GPU desktop: X server 1.20 with NVIDIA's X driver (nano-l4t-x11).
# Remove this file to go back to 26.04's X server on the framebuffer.
[Seat:*]
xserver-command=$XSERVER
EOF

# --- Checks in the chroot.
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || failed+=("$1"); }
failed=()
[[ -z $(in_root dpkg --audit) ]] && check DPKG_AUDIT PASS || check DPKG_AUDIT FAIL
in_root dpkg-query -W -f '${Package} ${Version}\n' > "$record/packages-after.txt"
diff <(grep -E "^$keep " "$record/packages-before.txt") <(grep -E "^$keep " "$record/packages-after.txt") \
    && check CORE_PACKAGES_UNCHANGED PASS || check CORE_PACKAGES_UNCHANGED FAIL
[[ $(in_root dpkg-query -W -f '${Version}' nano-l4t-gl nano-l4t-x11) == "$L4T$L4T" ]] \
    && check NANO_L4T_GL_X11 PASS || check NANO_L4T_GL_X11 FAIL
[[ $(in_root systemctl --version | head -n 1) == 'systemd 259'* ]] && check SYSTEMD_259 PASS || check SYSTEMD_259 FAIL
in_root ldconfig -p > "$record/ldconfig.txt"
grep -q 'libcuda.so.1 .*=> /usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1$' "$record/ldconfig.txt" \
    && check LIBCUDA PASS || check LIBCUDA FAIL
grep -q 'libGLX_nvidia.so.0 .*=> /usr/lib/aarch64-linux-gnu/tegra/libGLX_nvidia.so.0$' "$record/ldconfig.txt" \
    && grep -q 'libEGL_nvidia.so.0 .*=> /usr/lib/aarch64-linux-gnu/tegra-egl/libEGL_nvidia.so.0$' "$record/ldconfig.txt" \
    && [[ -f $root/usr/share/glvnd/egl_vendor.d/10_nvidia.json ]] \
    && check GL_VENDOR_LIBS PASS || check GL_VENDOR_LIBS FAIL
# The X server is linked with BIND_NOW: -version resolves every symbol it imports.
set +e
in_root /usr/lib/nano-xorg/Xorg -version > "$record/xorg-version.txt" 2>&1
xorg_exit=$?
set -e
cat "$record/xorg-version.txt"
[[ $xorg_exit == 0 ]] && grep -q '^X.Org X Server 1.20.13$' "$record/xorg-version.txt" \
    && check XORG_120_RUNS PASS || check XORG_120_RUNS FAIL
# Every library the modules and GL libraries need resolves in 26.04 (X server
# symbols bind when the X server loads them).
: > "$record/ldd.txt"
for lib in /usr/lib/nano-xorg/modules/drivers/nvidia_drv.so \
    /usr/lib/nano-xorg/modules/extensions/libglxserver_nvidia.so \
    /usr/lib/nano-xorg/modules/extensions/libglx.so /usr/lib/nano-xorg/modules/libfb.so \
    /usr/lib/nano-xorg/modules/libwfb.so /usr/lib/nano-xorg/modules/input/libinput_drv.so \
    /usr/lib/aarch64-linux-gnu/tegra/libGLX_nvidia.so.0 \
    /usr/lib/aarch64-linux-gnu/tegra-egl/libEGL_nvidia.so.0 \
    /usr/lib/aarch64-linux-gnu/tegra-egl/libGLESv2_nvidia.so.2; do
    { printf '== %s\n' "$lib"; in_root ldd "$lib" 2>&1 || true; } >> "$record/ldd.txt"
done
if grep -q 'not found' "$record/ldd.txt"; then
    awk '/^== /{lib=$2} /not found/{print lib ":" $0}' "$record/ldd.txt"
    check X_MODULES_LINK FAIL
else
    check X_MODULES_LINK PASS
fi
[[ $(grep -c '^xserver-command=' "$root/etc/lightdm/lightdm.conf.d/60-jetson-gpu.conf") == 1 \
    && -f $root/etc/X11/nano-xorg.conf && -d $root/etc/X11/nano-xorg.conf.d \
    && -f $root/etc/X11/xorg.conf.d/20-jetson-framebuffer.conf && -x $root/usr/lib/xorg/Xorg ]] \
    && check LIGHTDM_GPU PASS || check LIGHTDM_GPU FAIL
[[ -x $root/usr/bin/glxinfo && -x $root/usr/bin/eglinfo ]] && check GL_TOOLS PASS || check GL_TOOLS FAIL
in_root dpkg-query -W -f '${Package} ${Version}\n' nano-l4t-gl nano-l4t-x11 mesa-utils xserver-xorg-core lightdm

# CUDA, as the owner's account inside 26.04, with the probes the build left.
as_owner() {
    chroot "$root" /usr/bin/env -i HOME="$home" PATH=/usr/bin:/bin LC_ALL=C \
        setpriv --reuid=1000 --regid=1000 --init-groups "$@"
}
set +e
as_owner /opt/nano-cuda-probe/deviceQuery > "$record/deviceQuery.log" 2>&1
printf 'DEVICEQUERY_EXIT=%s\n' "$?"
as_owner /opt/nano-cuda-probe/vector_add > "$record/vector_add.log" 2>&1
printf 'VECTOR_ADD_EXIT=%s\n' "$?"
set -e
grep -q 'Result = PASS' "$record/deviceQuery.log" && check CUDA_DEVICEQUERY PASS || check CUDA_DEVICEQUERY FAIL
grep -qx 'RESULT=PASS' "$record/vector_add.log" && check CUDA_VECTOR_ADD PASS || check CUDA_VECTOR_ADD FAIL

# --- Finish.
in_root apt-get clean
{
    printf 'stamp=%s\nbuild=%s\ndesktop=%s\nfs_uuid=%s\n' "$stamp" "${build##*/}" "${desktop##*/}" "$fs_uuid"
    printf 'packages=%s (before %s)\n' "$(wc -l < "$record/packages-after.txt")" "$(wc -l < "$record/packages-before.txt")"
    printf 'used_bytes=%s\n' "$(df -B1 --output=used "$root" | tail -n 1)"
    sha256sum "$self"
} | tee "$record/summary.txt"
install -d -m 0755 "$root/var/log/nano-u26"
cp "$record/summary.txt" "$root/var/log/nano-u26/gpu-desktop-$stamp.txt"
if (( ${#failed[@]} )); then
    die "checks failed: ${failed[*]}"
fi
printf 'U26_GPU_DESKTOP=PASS record=%s\n' "$record"

#!/usr/bin/env bash
# Add the desktop and zram swap to the reference card's Ubuntu 26.04 (stage 5, first part).
#
# Usage: sudo bash add-u26-desktop.sh
#
# Run as root on the Nano from the reference card's everyday 5.10 boot, after
# build-u26-root.sh passed. In a chroot on the UBUNTU26 partition it installs,
# from Ubuntu's signed archive:
# - Xfce with LightDM on the 5.10 framebuffer, software-rendered: the first
#   stage's package set and settings (configure-desktop.sh), without its systemd 249
#   pieces, which stock systemd 259 does not need;
# - zram swap at half of the memory, with Ubuntu's systemd-zram-generator;
# then makes graphical.target the default and checks that CUDA still runs
# from the root on the real GPU. It writes only the UBUNTU26 partition and a
# record under the owner's home; APP, its boot and the QSPI stay untouched.
# Rerunning it is safe.
set -euo pipefail

KERNEL=5.10.216-tegra
CARD_BYTES=63864569856
APP_PARTUUID=5ac80d7c-40fb-4796-bd56-4110e389819b
PART=/dev/mmcblk0p15
NAME=UBUNTU26
PACKAGES=(xfce4 lightdm lightdm-gtk-greeter xfce4-terminal xserver-xorg-core
    xserver-xorg-input-libinput xserver-xorg-video-fbdev xserver-xorg-input-evdev
    dbus-user-session fonts-ubuntu yaru-theme-gtk yaru-theme-icon
    ubuntu-wallpapers-resolute mousepad x11-utils
    polkitd xdg-user-dirs xdg-utils xfce4-notifyd
    systemd-zram-generator)
WALLPAPER=/usr/share/backgrounds/Resolute_Raccoon_Wallpaper_Dimmed_3840x2160.png

die() { printf 'U26_DESKTOP=FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 0 ]] || { printf 'Usage: sudo bash %s\n' "$0" >&2; exit 2; }
[[ $EUID == 0 && $(uname -m) == aarch64 ]] || die 'run as root on the Nano'
self=$(realpath -e -- "$0")

# All mounts below live in a private mount namespace and vanish with it.
if [[ ${U26_DESKTOP_NS:-} != 1 ]]; then
    # JetPack 4's desktop automounts UBUNTU26 at boot as /media/<user>/UBUNTU26.
    # Undo only that mount, here, before the private namespace copies it.
    targets=$(findmnt -n -l -o TARGET -S "$PART" || true)
    if grep -qx "/media/[a-z_][a-z0-9_-]*/$NAME" <<<"$targets"; then
        udisksctl unmount -b "$PART" || die "could not undo the desktop's automount of $PART"
    fi
    exec unshare --mount --propagation private env U26_DESKTOP_NS=1 bash "$self"
fi

# --- The machine: the reference card's everyday 5.10 boot, with a passed 26.04 build.
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
build=$(find "$home/u26-build" -mindepth 1 -maxdepth 1 -type d -name '20*Z' 2>/dev/null | sort | tail -n 1 || true)
[[ -n $build && -f $build/build.log && -f $build/summary.txt ]] || die 'no 26.04 build record'
[[ $(tail -n 1 "$build/build.log") == U26_ROOT=PASS* ]] || die "the newest build ($build) did not pass"
grep -qx "fs_uuid=$fs_uuid" "$build/summary.txt" || die 'the build record names another filesystem'
[[ -e /sys/class/graphics/fb0 ]] || die 'no framebuffer (fb0) under this kernel'
fb_name=$(cat /sys/class/graphics/fb0/name)
for _ in $(seq 24); do
    timedatectl status | grep -q 'System clock synchronized: yes' && break
    sleep 5
done
timedatectl status | grep -q 'System clock synchronized: yes' || die 'the clock has not synchronized yet'

# --- The record, on APP in the owner's home; secrets never go to it.
stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$home/u26-desktop/$stamp
install -d -m 0755 -o 1000 -g 1000 "$home/u26-desktop"
install -d -m 0755 "$record"
exec 3>&1 4>&2
exec > >(tee "$record/desktop.log") 2>&1
tee_pid=$!
printf 'started %s on %s %s\n' "$stamp" "$(uname -r)" "$(uname -v)"
printf 'target %s (%s, filesystem %s), build %s, fb0 %s\n' "$PART" "$NAME" "$fs_uuid" "${build##*/}" "$fb_name"

root=/run/u26-desktop/root
mounted=()
cleanup() {
    local status=$? i
    rm -f "$root/usr/sbin/policy-rc.d" 2>/dev/null || true
    for ((i=${#mounted[@]}-1; i>=0; i--)); do
        umount -R "${mounted[i]}" || { umount -R -l "${mounted[i]}"; printf 'UNMOUNT_WARNING=%s\n' "${mounted[i]}"; }
    done
    sync
    chown -R 1000:1000 "$record" || true
    if (( status != 0 )); then printf 'U26_DESKTOP=FAIL exit=%s record=%s\n' "$status" "$record"; fi
    exec 1>&3 2>&4  # tee sees end of input and finishes the log
    wait "$tee_pid" 2>/dev/null || sleep 2
    exit "$status"
}
trap cleanup EXIT
install -d -m 0700 /run/u26-desktop
install -d -m 0755 "$root"
mount -t ext4 -o noatime "$PART" "$root"
mounted+=("$root")
[[ -f $root/var/log/nano-u26/build-${build##*/}.txt && -x $root/usr/lib/systemd/systemd ]] \
    || die "the 26.04 root lacks build ${build##*/}"
(( $(df -B1 --output=avail "$root" | tail -n 1) > 4000000000 )) || die "$NAME has under 4 GB free"
modules=$root/usr/lib/modules/$KERNEL
[[ -n $(find "$modules" -name 'zram.ko*' -print -quit) ]] || grep -q '/zram.ko$' "$modules/modules.builtin" \
    || die 'this kernel has no zram'

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

# --- Ubuntu's packages. The plan may install and upgrade, never remove, and
# must leave systemd, glibc and the NVIDIA packages as they are.
in_root dpkg-query -W -f '${Package} ${Version}\n' > "$record/packages-before.txt"
in_root apt-get update
in_root apt-get -s --no-install-recommends install "${PACKAGES[@]}" > "$record/plan.txt"
if grep -E '^Remv ' "$record/plan.txt"; then die 'the plan removes packages'; fi
if grep -E '^Inst (systemd|systemd-sysv|udev|libc6|libc-bin|libpam-systemd|libnss-systemd|nano-l4t-[a-z]+|cuda-[a-z]+-10-2|libcublas10|libcu(fft|rand|solver|sparse)-10-2|libnpp-10-2) ' \
    "$record/plan.txt"; then die 'the plan changes systemd, glibc or the NVIDIA packages'; fi
printf 'plan: %s packages to install or upgrade\n' "$(grep -c '^Inst ' "$record/plan.txt")"
in_root apt-get --yes --no-install-recommends -o Dpkg::Options::=--force-confold \
    install "${PACKAGES[@]}"

# --- The desktop, with the first stage's settings.
install -d -m 0755 "$root/etc/X11/xorg.conf.d" "$root/etc/lightdm/lightdm.conf.d"
# LightDM enumerates this at start and warns when it is missing.
in_root install -d -m 0755 -o lightdm -g lightdm /var/lib/lightdm/data
cat > "$root/etc/X11/xorg.conf.d/20-jetson-framebuffer.conf" <<'EOF'
Section "Device"
    Identifier "Jetson framebuffer"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
    Option "ShadowFB" "true"
EndSection
Section "Screen"
    Identifier "Jetson screen"
    Device "Jetson framebuffer"
    DefaultDepth 24
EndSection
EOF
cat > "$root/etc/lightdm/lightdm.conf.d/50-jetson-desktop.conf" <<'EOF'
[LightDM]
logind-check-graphical=false
[Seat:*]
allow-guest=false
xserver-command=/usr/lib/xorg/Xorg -nolisten tcp
greeter-session=lightdm-gtk-greeter
user-session=xfce
greeter-hide-users=false
EOF
{
    printf '[greeter]\n'
    if [[ -f $root$WALLPAPER ]]; then printf 'background=%s\n' "$WALLPAPER"; fi
    printf 'theme-name=Yaru-dark\nicon-theme-name=Yaru\nfont-name=Ubuntu 11\n'
    printf 'indicators=~host;~spacer;~clock;~spacer;~power\nclock-format=%%a %%d %%b, %%H:%%M\n'
} > "$root/etc/lightdm/lightdm-gtk-greeter.conf"
# System defaults apply only where the account has no personal setting.
xfconf=$root/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
install -d -m 0755 "$xfconf"
cat > "$xfconf/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="theme" type="string" value="Yaru"/>
  </property>
</channel>
EOF
in_root python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET
p = Path('/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml')
tree = ET.parse(p); root = tree.getroot()
for group, key, value in [('Net', 'ThemeName', 'Yaru-dark'), ('Net', 'IconThemeName', 'Yaru'),
                          ('Gtk', 'FontName', 'Ubuntu 11')]:
    parent = root.find("property[@name='%s']" % group)
    if parent is None:
        parent = ET.SubElement(root, 'property', {'name': group, 'type': 'empty'})
    child = parent.find("property[@name='%s']" % key)
    if child is None:
        child = ET.SubElement(parent, 'property', {'name': key})
    child.set('type', 'string'); child.set('value', value)
tree.write(p, encoding='UTF-8', xml_declaration=True)
PY
# The packaged Xfce default names an absent Xubuntu backdrop.
if [[ -f $root$WALLPAPER ]]; then
    install -d -m 0755 "$root/usr/share/xfce4/backdrops"
    ln -sfn "$WALLPAPER" "$root/usr/share/xfce4/backdrops/xubuntu-wallpaper.png"
fi

# --- zram swap: half of the memory, as JetPack's nvzramconfig.
install -d -m 0755 "$root/etc/systemd"
printf '[zram0]\nzram-size = ram / 2\nswap-priority = 100\n' > "$root/etc/systemd/zram-generator.conf"

in_root systemctl enable lightdm.service
in_root systemctl set-default graphical.target

# --- Checks in the chroot.
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || failed+=("$1"); }
failed=()
[[ -z $(in_root dpkg --audit) ]] && check DPKG_AUDIT PASS || check DPKG_AUDIT FAIL
in_root dpkg-query -W -f '${Package} ${Version}\n' > "$record/packages-after.txt"
keep='^(systemd|systemd-sysv|udev|libc6|libc-bin|nano-l4t-[a-z]+|cuda-[a-z]+-10-2|libcublas10|libcu(fft|rand|solver|sparse)-10-2|libnpp-10-2) '
diff <(grep -E "$keep" "$record/packages-before.txt") <(grep -E "$keep" "$record/packages-after.txt") \
    && check CORE_PACKAGES_UNCHANGED PASS || check CORE_PACKAGES_UNCHANGED FAIL
[[ $(in_root systemctl --version | head -n 1) == 'systemd 259'* ]] && check SYSTEMD_259 PASS || check SYSTEMD_259 FAIL
in_root ldconfig -p > "$record/ldconfig.txt"
grep -q 'libcuda.so.1 .*=> /usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1$' "$record/ldconfig.txt" \
    && check LIBCUDA PASS || check LIBCUDA FAIL
[[ -x $root/usr/lib/xorg/Xorg && -f $root/usr/lib/xorg/modules/drivers/fbdev_drv.so ]] \
    && check XORG_FBDEV PASS || check XORG_FBDEV FAIL
[[ $(in_root systemctl is-enabled lightdm.service) == enabled \
    && $(readlink "$root/etc/systemd/system/display-manager.service") == */lightdm.service \
    && $(cat "$root/etc/X11/default-display-manager") == /usr/sbin/lightdm ]] \
    && check LIGHTDM_ENABLED PASS || check LIGHTDM_ENABLED FAIL
[[ $(in_root systemctl get-default) == graphical.target ]] && check GRAPHICAL_DEFAULT PASS || check GRAPHICAL_DEFAULT FAIL
[[ -x $root/usr/lib/systemd/system-generators/zram-generator ]] && check ZRAM_GENERATOR PASS || check ZRAM_GENERATOR FAIL
in_root dpkg-query -W -f '${Package} ${Version}\n' xfce4-session lightdm xserver-xorg-core systemd-zram-generator
in_root /usr/sbin/lightdm --version 2>&1 | head -n 1 || true
in_root /usr/lib/xorg/Xorg -version 2>&1 | grep -m1 'X.Org X Server' || true

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
    printf 'stamp=%s\nbuild=%s\nfs_uuid=%s\nfb0=%s\n' "$stamp" "${build##*/}" "$fs_uuid" "$fb_name"
    printf 'packages=%s (before %s)\n' "$(wc -l < "$record/packages-after.txt")" "$(wc -l < "$record/packages-before.txt")"
    printf 'used_bytes=%s\n' "$(df -B1 --output=used "$root" | tail -n 1)"
    sha256sum "$self"
} | tee "$record/summary.txt"
install -d -m 0755 "$root/var/log/nano-u26"
cp "$record/summary.txt" "$root/var/log/nano-u26/desktop-$stamp.txt"
if (( ${#failed[@]} )); then
    die "checks failed: ${failed[*]}"
fi
printf 'U26_DESKTOP=PASS record=%s\n' "$record"

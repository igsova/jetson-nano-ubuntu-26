#!/usr/bin/env bash
# Add Ubuntu's Unity desktop next to Xfce on the reference card's Ubuntu 26.04 (stage 5).
#
# Usage: sudo bash add-u26-unity.sh
#
# Run as root on the Nano from the reference card's everyday 5.10 boot, after
# build-u26-root.sh, add-u26-desktop.sh and add-u26-gpu-desktop.sh passed.
# Unity 7 draws with OpenGL (Compiz), so it needs the GPU desktop. In a chroot
# on the UBUNTU26 partition it installs, from Ubuntu's signed archive, the
# Ubuntu Unity flavour's session, shell, settings, theme, indicators, Dash
# search and Nemo (its desktop), without the flavour's application set. Xfce
# stays LightDM's default session; the login screen gets a session menu, and
# LightDM remembers the last session per account. Unity's own wallpaper and
# launcher defaults point at what this root has (the Resolute wallpaper, Nemo,
# Xfce's terminal and editor). Unity's file manager brings udisks2, so a udev
# rule hides the card's own partitions (APP and JetPack's boot partitions)
# from the desktop, which would otherwise offer to mount them. Then it checks
# that Unity links in 26.04 and that CUDA still runs on the real GPU. It
# writes only the UBUNTU26 partition and a record under the owner's home; APP,
# its boot and the QSPI stay untouched. Rerunning it is safe.
set -euo pipefail

KERNEL=5.10.216-tegra
CARD_BYTES=63864569856
APP_PARTUUID=5ac80d7c-40fb-4796-bd56-4110e389819b
PART=/dev/mmcblk0p15
NAME=UBUNTU26
PACKAGES=(unity-session ubuntu-unity-settings yaru-theme-unity unity-control-center
    unity-lens-applications unity-lens-files unity-scopes-runner hud nemo
    indicator-session indicator-datetime indicator-power indicator-sound
    indicator-keyboard indicator-application)
WALLPAPER=/usr/share/backgrounds/Resolute_Raccoon_Wallpaper_Dimmed_3840x2160.png
FAVORITES="['application://nemo.desktop', 'application://xfce4-terminal.desktop', \
'application://org.xfce.mousepad.desktop', 'application://unity-control-center.desktop', \
'unity://running-apps', 'unity://expo-icon', 'unity://devices']"
OVERRIDE=/usr/share/glib-2.0/schemas/90_nano-u26-unity.gschema.override
GREETER=/etc/lightdm/lightdm-gtk-greeter.conf
HIDE=/etc/udev/rules.d/80-nano-hide-card.rules

die() { printf 'U26_UNITY=FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 0 ]] || { printf 'Usage: sudo bash %s\n' "$0" >&2; exit 2; }
[[ $EUID == 0 && $(uname -m) == aarch64 ]] || die 'run as root on the Nano'
self=$(realpath -e -- "$0")

# All mounts below live in a private mount namespace and vanish with it.
if [[ ${U26_UNITY_NS:-} != 1 ]]; then
    # JetPack 4's desktop automounts UBUNTU26 at boot as /media/<user>/UBUNTU26.
    # Undo only that mount, here, before the private namespace copies it.
    targets=$(findmnt -n -l -o TARGET -S "$PART" || true)
    if grep -qx "/media/[a-z_][a-z0-9_-]*/$NAME" <<<"$targets"; then
        udisksctl unmount -b "$PART" || die "could not undo the desktop's automount of $PART"
    fi
    exec unshare --mount --propagation private env U26_UNITY_NS=1 bash "$self"
fi

# --- The machine: the reference card's everyday 5.10 boot, with a passed 26.04 build,
# desktop and GPU desktop.
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
passed() {  # DIR LOG RESULT: the newest record, which must have passed on this filesystem
    local newest
    newest=$(find "$home/$1" -mindepth 1 -maxdepth 1 -type d -name '20*Z' 2>/dev/null | sort | tail -n 1 || true)
    [[ -n $newest && -f $newest/$2 && -f $newest/summary.txt ]] || die "no $1 record"
    [[ $(tail -n 1 "$newest/$2") == "$3"=PASS* ]] || die "the newest step in $newest did not pass"
    grep -qx "fs_uuid=$fs_uuid" "$newest/summary.txt" || die "the record $newest names another filesystem"
    printf '%s\n' "$newest"
}
build=$(passed u26-build build.log U26_ROOT)
desktop=$(passed u26-desktop desktop.log U26_DESKTOP)
gpu=$(passed u26-gpu-desktop gpu-desktop.log U26_GPU_DESKTOP)
for _ in $(seq 24); do
    timedatectl status | grep -q 'System clock synchronized: yes' && break
    sleep 5
done
timedatectl status | grep -q 'System clock synchronized: yes' || die 'the clock has not synchronized yet'

# --- The record, on APP in the owner's home; secrets never go to it.
stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$home/u26-unity/$stamp
install -d -m 0755 -o 1000 -g 1000 "$home/u26-unity"
install -d -m 0755 "$record"
exec 3>&1 4>&2
exec > >(tee "$record/unity.log") 2>&1
tee_pid=$!
printf 'started %s on %s %s\n' "$stamp" "$(uname -r)" "$(uname -v)"
printf 'target %s (%s, filesystem %s), build %s, desktop %s, gpu %s\n' \
    "$PART" "$NAME" "$fs_uuid" "${build##*/}" "${desktop##*/}" "${gpu##*/}"

root=/run/u26-unity/root
mounted=()
cleanup() {
    local status=$? i
    rm -f "$root/usr/sbin/policy-rc.d" 2>/dev/null || true
    for ((i=${#mounted[@]}-1; i>=0; i--)); do
        umount -R "${mounted[i]}" || { umount -R -l "${mounted[i]}"; printf 'UNMOUNT_WARNING=%s\n' "${mounted[i]}"; }
    done
    sync
    chown -R 1000:1000 "$record" || true
    if (( status != 0 )); then printf 'U26_UNITY=FAIL exit=%s record=%s\n' "$status" "$record"; fi
    exec 1>&3 2>&4  # tee sees end of input and finishes the log
    wait "$tee_pid" 2>/dev/null || sleep 2
    exit "$status"
}
trap cleanup EXIT
install -d -m 0700 /run/u26-unity
install -d -m 0755 "$root"
mount -t ext4 -o noatime "$PART" "$root"
mounted+=("$root")
[[ -f $root/var/log/nano-u26/gpu-desktop-${gpu##*/}.txt ]] || die "the 26.04 root lacks GPU desktop ${gpu##*/}"
[[ -f $root$GREETER && -f $root/etc/lightdm/lightdm.conf.d/50-jetson-desktop.conf \
    && -f $root/etc/lightdm/lightdm.conf.d/60-jetson-gpu.conf ]] || die 'the 26.04 root lacks the desktop settings'
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
# leave systemd, glibc, both X servers and the NVIDIA packages as they are.
in_root dpkg-query -W -f '${Package} ${Version}\n' > "$record/packages-before.txt"
in_root apt-get update
in_root apt-get -s --no-install-recommends install "${PACKAGES[@]}" > "$record/plan.txt"
if grep -E '^Remv ' "$record/plan.txt"; then die 'the plan removes packages'; fi
keep='(systemd|systemd-sysv|udev|libc6|libc-bin|libpam-systemd|libnss-systemd|xserver-xorg-core|nano-l4t-[a-z0-9]+|cuda-[a-z]+-10-2|libcublas10|libcu(fft|rand|solver|sparse)-10-2|libnpp-10-2)'
if grep -E "^Inst $keep " "$record/plan.txt"; then
    die 'the plan changes systemd, glibc, the X server or the NVIDIA packages'
fi
printf 'plan: %s packages to install or upgrade\n' "$(grep -c '^Inst ' "$record/plan.txt")"
in_root apt-get --yes --no-install-recommends -o Dpkg::Options::=--force-confold \
    install "${PACKAGES[@]}"

# --- Unity's defaults for what this root has; an account's own settings win.
{
    printf '# Unity on the Nano (add-u26-unity.sh): the wallpaper and launcher items this root has.\n'
    if [[ -f $root$WALLPAPER ]]; then
        printf "[org.gnome.desktop.background:Unity]\npicture-uri = 'file://%s'\npicture-uri-dark = 'file://%s'\n\n" \
            "$WALLPAPER" "$WALLPAPER"
    fi
    printf '[com.canonical.Unity.Launcher]\nfavorites = %s\n' "$FAVORITES"
} > "$root$OVERRIDE"
in_root glib-compile-schemas /usr/share/glib-2.0/schemas
# The login screen's session menu, so Unity can be picked there.
if ! grep -q '^indicators=.*~session' "$root$GREETER"; then
    sed -i 's/^indicators=\(.*\)~power$/indicators=\1~session;~power/' "$root$GREETER"
fi

# Unity's file manager would show, and offer to mount, the card's own partitions.
cat > "$root$HIDE" <<'EOF'
# The desktop's disk tools (udisks2) leave the SD card's partitions alone:
# APP and JetPack's boot partitions (add-u26-unity.sh).
SUBSYSTEM=="block", KERNEL=="mmcblk0p[0-9]*", ENV{UDISKS_IGNORE}="1"
EOF

# --- Checks in the chroot.
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || failed+=("$1"); }
failed=()
[[ -z $(in_root dpkg --audit) ]] && check DPKG_AUDIT PASS || check DPKG_AUDIT FAIL
in_root dpkg-query -W -f '${Package} ${Version}\n' > "$record/packages-after.txt"
diff <(grep -E "^$keep " "$record/packages-before.txt") <(grep -E "^$keep " "$record/packages-after.txt") \
    && check CORE_PACKAGES_UNCHANGED PASS || check CORE_PACKAGES_UNCHANGED FAIL
[[ $(in_root systemctl --version | head -n 1) == 'systemd 259'* ]] && check SYSTEMD_259 PASS || check SYSTEMD_259 FAIL
in_root ldconfig -p > "$record/ldconfig.txt"
grep -q 'libcuda.so.1 .*=> /usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1$' "$record/ldconfig.txt" \
    && check LIBCUDA PASS || check LIBCUDA FAIL
[[ -f $root/usr/share/xsessions/unity.desktop && -f $root/usr/share/xsessions/xfce.desktop \
    && -x $root/usr/bin/unity && -x $root/usr/bin/compiz && -x $root/usr/bin/nemo ]] \
    && check UNITY_SESSION PASS || check UNITY_SESSION FAIL
# Every library Unity's shell and Compiz need resolves in 26.04.
: > "$record/ldd.txt"
mapfile -t libs < <(in_root sh -c 'ls /usr/bin/unity /usr/bin/compiz /usr/lib/nux/unity_support_test \
    /usr/lib/*/compiz/libunityshell.so /usr/lib/*/compiz/libopengl.so /usr/lib/*/compiz/libcomposite.so' || true)
for lib in "${libs[@]}"; do
    { printf '== %s\n' "$lib"; in_root ldd "$lib" 2>&1 || true; } >> "$record/ldd.txt"
done
if (( ${#libs[@]} < 6 )); then
    printf 'only %s of the 6 Unity and Compiz files found\n' "${#libs[@]}"
    check UNITY_LINK FAIL
elif grep -q 'not found' "$record/ldd.txt"; then
    awk '/^== /{lib=$2} /not found/{print lib ":" $0}' "$record/ldd.txt"
    check UNITY_LINK FAIL
else
    check UNITY_LINK PASS
fi
# LightDM: Xfce by default on the GPU X server, with a session menu.
lightdm=$root/etc/lightdm/lightdm.conf.d
grep -qx 'user-session=xfce' "$lightdm/50-jetson-desktop.conf" \
    && grep -qx 'greeter-session=lightdm-gtk-greeter' "$lightdm/50-jetson-desktop.conf" \
    && grep -q '^xserver-command=/usr/lib/nano-xorg/Xorg ' "$lightdm/60-jetson-gpu.conf" \
    && grep -q '^indicators=.*~session' "$root$GREETER" \
    && check LIGHTDM_SESSIONS PASS || check LIGHTDM_SESSIONS FAIL
grep -q 'ENV{UDISKS_IGNORE}="1"' "$root$HIDE" && check CARD_HIDDEN PASS || check CARD_HIDDEN FAIL
# Unity's effective defaults, read the way a Unity session reads them.
gs() { in_root env XDG_CURRENT_DESKTOP=Unity GSETTINGS_BACKEND=memory gsettings get "$@"; }
{
    printf 'background %s\n' "$(gs org.gnome.desktop.background picture-uri)"
    printf 'gtk-theme %s\n' "$(gs org.gnome.desktop.interface gtk-theme)"
    printf 'icon-theme %s\n' "$(gs org.gnome.desktop.interface icon-theme)"
    printf 'favorites %s\n' "$(gs com.canonical.Unity.Launcher favorites)"
} | tee "$record/unity-defaults.txt"
grep -qx "background 'file://$WALLPAPER'" "$record/unity-defaults.txt" \
    && grep -qx "gtk-theme 'Yaru-dark'" "$record/unity-defaults.txt" \
    && grep -q "^favorites \['application://nemo.desktop', " "$record/unity-defaults.txt" \
    && check UNITY_DEFAULTS PASS || check UNITY_DEFAULTS FAIL
in_root dpkg-query -W -f '${Package} ${Version}\n' unity unity-session compiz-core nemo \
    lightdm nano-l4t-x11 xserver-xorg-core

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
    printf 'stamp=%s\nbuild=%s\ndesktop=%s\ngpu=%s\nfs_uuid=%s\n' \
        "$stamp" "${build##*/}" "${desktop##*/}" "${gpu##*/}" "$fs_uuid"
    printf 'packages=%s (before %s)\n' "$(wc -l < "$record/packages-after.txt")" "$(wc -l < "$record/packages-before.txt")"
    printf 'used_bytes=%s\n' "$(df -B1 --output=used "$root" | tail -n 1)"
    sha256sum "$self"
} | tee "$record/summary.txt"
install -d -m 0755 "$root/var/log/nano-u26"
cp "$record/summary.txt" "$root/var/log/nano-u26/unity-$stamp.txt"
if (( ${#failed[@]} )); then
    die "checks failed: ${failed[*]}"
fi
printf 'U26_UNITY=PASS record=%s\n' "$record"

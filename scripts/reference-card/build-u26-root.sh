#!/usr/bin/env bash
# Build Ubuntu 26.04.1 into the reference card's UBUNTU26 partition, from its everyday 5.10 boot.
#
# Usage: sudo bash build-u26-root.sh [--reset] INPUTS_DIR
#
# Run as root on the Nano while the reference card runs JetPack 5's 5.10 kernel with its
# JetPack 4 user space (the everyday entry). INPUTS_DIR holds the files below,
# each checked against its pinned SHA-256. The script writes only the UBUNTU26
# partition (mmcblk0p15, checked by label, size and filesystem) and a record
# under the owner's home on APP. It never touches APP's system, the boot
# partitions, extlinux.conf or the QSPI, and it changes no running service.
#
# Steps: Ubuntu Base 26.04.1, then from Ubuntu's signed archive the stock
# systemd 259, udev, SSH, NetworkManager and a small set of tools; the 5.10
# modules from APP; the Wi-Fi firmware 5.10 cannot load compressed; the Nano's
# NVIDIA files (nano-l4t-*) and CUDA 10.2's libraries; the owner's account, SSH
# host keys and saved network profiles; then checks in a chroot, including CUDA
# on the real GPU as the owner's account. The partition must be empty (only
# lost+found); --reset empties it first.
set -euo pipefail

KERNEL=5.10.216-tegra
CARD_BYTES=63864569856
APP_PARTUUID=5ac80d7c-40fb-4796-bd56-4110e389819b
PART=/dev/mmcblk0p15
NAME=UBUNTU26
BASE=ubuntu-base-26.04.1-base-arm64.tar.gz
L4T=32.7.6-20241104234540+u26.1
declare -A PINS=(  # path in INPUTS_DIR -> SHA-256
    [$BASE]=5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd
    # scripts/host/build-nano-l4t-debs.py at 107553a, on the owner's PC (2026-10-15)
    [nano-l4t/nano-l4t-core_${L4T}_arm64.deb]=d3aeb47f26906fe7567bfd03a76d8267eeea4a08813e77b0db16dff232228a36
    [nano-l4t/nano-l4t-cuda_${L4T}_arm64.deb]=04a6b519aec39042c501b45a21f3f33f7e656d5a18cdada2880e3d144f940b36
    [nano-l4t/nano-l4t-power_${L4T}_arm64.deb]=6c02fa0612205d14591bb0e736f4ef8d36a277b7829fd7472886c68c9952a6b1
    # NVIDIA's signed common r32.7 index (2026-10-15)
    [cuda/cuda-cudart-10-2_10.2.300-1_arm64.deb]=e3cd683965f7b2e4a13b27c58754443185dcc545d0f989e52c224840cfde48d1
    [cuda/cuda-libraries-10-2_10.2.460-1_arm64.deb]=a09ecb11e6ccf1d44c4ba941de49e0b9be02f6d70ba7f2f5c8be06a9d50fc9d1
    [cuda/cuda-nvgraph-10-2_10.2.300-1_arm64.deb]=88412a2eecdc5dc2f3db7f6f2dea3d13c234114b8f36ec0356d237190504748e
    [cuda/cuda-nvrtc-10-2_10.2.300-1_arm64.deb]=7118079394a22c6cedba1152f0a78ef7bb10ac26c1984ab8c4dcf82fe9f4e20c
    [cuda/libcublas10_10.2.3.300-1_arm64.deb]=a4cde28215c01bce78fa7c3d09909afaec487142e1144646bd7ff043a5c6c1df
    [cuda/libcufft-10-2_10.1.2.300-1_arm64.deb]=661a91f35f2d148d938ca907484ebe48727b17f03a8cbb6992e60bb792738caf
    [cuda/libcurand-10-2_10.1.2.300-1_arm64.deb]=45f2bbafdde70b8b8bcdc6f0625a2ab334632b6659f153224654d03e1776057b
    [cuda/libcusolver-10-2_10.3.0.300-1_arm64.deb]=31a32e7c7e439bc34331d32b93392d08de6c9893d5083865b93703509d6fb7d6
    [cuda/libcusparse-10-2_10.3.1.300-1_arm64.deb]=bd844b7a71adc76694caf5da4818ab03f207e3b7f23340aa2fe86909f799fb92
    [cuda/libnpp-10-2_10.2.1.300-1_arm64.deb]=dc51dc218b7652680138ca236877d01ff0b65546d60a113276ded05f1fea967e
    # linux-firmware-realtek 20260319.git217ca6e4-0ubuntu1.2's rtl8188eufw.bin.zst, decompressed
    [firmware/rtlwifi/rtl8188eufw.bin]=2ff74315287529dec2e50eb57d6e0c97d2116f28ae166773ccdf93b6360000c4
    [vector_add.cu]=7bbbfb23e145280a120cd2be06820d75af5e3fcc05af2f9f0b17ca02b28da078
)
# Ubuntu's own packages, without recommends. The desktop and other board
# features come later (the reference card's stage 5).
PACKAGES=(systemd systemd-sysv systemd-resolved systemd-timesyncd udev dbus
    libpam-systemd libnss-systemd openssh-server network-manager wpasupplicant iw
    wireless-regdb iproute2 iputils-ping ca-certificates sudo nano less kmod procps
    locales tzdata python3 zstd e2fsprogs usbutils file)

die() { printf 'U26_ROOT=FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: sudo bash %s [--reset] INPUTS_DIR\n' "$0" >&2; exit 2; }

reset=0
if [[ ${1:-} == --reset ]]; then reset=1; shift; fi
[[ $# -eq 1 ]] || usage
[[ $EUID == 0 && $(uname -m) == aarch64 ]] || die 'run as root on the Nano'
inputs=$(realpath -e -- "$1")
self=$(realpath -e -- "$0")

# All mounts below live in a private mount namespace and vanish with it.
if [[ ${U26_BUILD_NS:-} != 1 ]]; then
    # JetPack 4's desktop automounts UBUNTU26 at boot as /media/<user>/UBUNTU26.
    # Undo only that mount, here, before the private namespace copies it; any
    # other mount of the partition still stops the checks below.
    targets=$(findmnt -n -l -o TARGET -S "$PART" || true)
    if grep -qx "/media/[a-z_][a-z0-9_-]*/$NAME" <<<"$targets"; then
        udisksctl unmount -b "$PART" || die "could not undo the desktop's automount of $PART"
    fi
    again=("$inputs")
    if ((reset)); then again=(--reset "$inputs"); fi
    exec unshare --mount --propagation private env U26_BUILD_NS=1 bash "$self" "${again[@]}"
fi

# --- The machine: the reference card's everyday 5.10 boot with JetPack 4's user space.
[[ $(uname -r) == "$KERNEL" ]] || die "running $(uname -r); boot the reference card's everyday 5.10 entry"
grep -q 'REVISION: 7.6,' /etc/nv_tegra_release || die 'not L4T R32.7.6 user space'
config=$(zcat /proc/config.gz)
grep -qx CONFIG_PSI=y <<<"$config" && grep -qx CONFIG_CGROUP_BPF=y <<<"$config" \
    || die 'this kernel predates build #34 (CONFIG_PSI, CONFIG_CGROUP_BPF)'
[[ $(blockdev --getsize64 /dev/mmcblk0) == "$CARD_BYTES" ]] || die 'mmcblk0 is not the reference card'
[[ $(findmnt -n -o SOURCE /) == /dev/mmcblk0p1 ]] || die 'the root is not mmcblk0p1'
[[ $(blkid -s PARTUUID -o value /dev/mmcblk0p1) == "$APP_PARTUUID" ]] || die 'mmcblk0p1 is not the reference card APP'
[[ $(lsblk -nro PARTLABEL | grep -cx "$NAME") == 1 ]] || die "not exactly one $NAME partition"
[[ $(lsblk -dno PARTLABEL "$PART") == "$NAME" ]] || die "$PART is not $NAME"
[[ $(blkid -s LABEL -o value "$PART") == "$NAME" && $(blkid -s TYPE -o value "$PART") == ext4 ]] \
    || die "$PART has no ext4 filesystem labelled $NAME"
fs_uuid=$(blkid -s UUID -o value "$PART")
(( $(blockdev --getsize64 "$PART") > 32000000000 )) || die "$PART is too small"
! findmnt -n -S "$PART" >/dev/null || die "$PART is mounted; unmount it first"
modules=/lib/modules/$KERNEL
[[ -f $modules/modules.dep && -n $(find "$modules" -name nvgpu.ko -print -quit) ]] \
    || die "no 5.10 modules at $modules"
owner=$(getent passwd 1000) || die 'no account with UID 1000'
IFS=: read -r user _ _ _ gecos home shell <<<"$owner"
[[ $user =~ ^[a-z_][a-z0-9_-]*$ && $home == /home/$user && -d $home ]] || die "unexpected account $user"
[[ $(getent group video | cut -d: -f3) == 44 ]] || die 'the video group is not GID 44 here'
nvcc=/usr/local/cuda-10.2/bin/nvcc
sample=/usr/local/cuda-10.2/samples/1_Utilities/deviceQuery/deviceQuery.cpp
[[ -x $nvcc && -f $sample ]] || die 'CUDA 10.2 compiler or samples missing on JetPack 4'

# apt rejects Ubuntu's signed indexes while the clock is behind.
for _ in $(seq 24); do
    timedatectl status | grep -q 'System clock synchronized: yes' && break
    sleep 5
done
timedatectl status | grep -q 'System clock synchronized: yes' || die 'the clock has not synchronized yet'

# --- The inputs.
for rel in "${!PINS[@]}"; do
    [[ -f $inputs/$rel ]] || die "missing $inputs/$rel"
    printf '%s  %s\n' "${PINS[$rel]}" "$inputs/$rel" | sha256sum --check --quiet - \
        || die "$rel does not match its pin"
done

# --- The record, on APP in the owner's home; secrets never go to it.
stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$home/u26-build/$stamp
install -d -m 0755 -o 1000 -g 1000 "$home/u26-build"
install -d -m 0755 "$record"
exec 3>&1 4>&2
exec > >(tee "$record/build.log") 2>&1
tee_pid=$!
printf 'started %s on %s %s, %s\n' "$stamp" "$(uname -r)" "$(uname -v)" "$(head -n 1 /etc/nv_tegra_release)"
printf 'target %s (%s, filesystem %s), inputs %s\n' "$PART" "$NAME" "$fs_uuid" "$inputs"

root=/run/u26-build/root
mounted=()
cleanup() {
    local status=$? i
    for ((i=${#mounted[@]}-1; i>=0; i--)); do
        umount -R "${mounted[i]}" || { umount -R -l "${mounted[i]}"; printf 'UNMOUNT_WARNING=%s\n' "${mounted[i]}"; }
    done
    sync
    chown -R 1000:1000 "$record" || true
    if (( status != 0 )); then printf 'U26_ROOT=FAIL exit=%s record=%s\n' "$status" "$record"; fi
    exec 1>&3 2>&4  # tee sees end of input and finishes the log
    wait "$tee_pid" 2>/dev/null || sleep 2
    exit "$status"
}
trap cleanup EXIT
install -d -m 0700 /run/u26-build
install -d -m 0755 "$root"
mount -t ext4 -o noatime "$PART" "$root"
mounted+=("$root")

leftovers=$(find "$root" -mindepth 1 -maxdepth 1 ! -name lost+found -printf '%f\n' | head -n 5)
if [[ -n $leftovers ]]; then
    ((reset)) || die "$NAME is not empty (${leftovers//$'\n'/, }...); rerun with --reset to start over"
    printf 'reset: emptying %s\n' "$NAME"
    find "$root" -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system {} +
fi
(( $(df -B1 --output=avail "$root" | tail -n 1) > 8000000000 )) || die "$NAME has under 8 GB free"

# --- Ubuntu Base, as in the first stage.
umask 022
tar --extract --gzip --file "$inputs/$BASE" --directory "$root" \
    --numeric-owner --same-owner --same-permissions --delay-directory-restore
chmod 0755 "$root"
grep -q 'VERSION_ID="26.04"' "$root/etc/os-release" || die 'the base is not 26.04'

mount -t proc proc "$root/proc"; mounted+=("$root/proc")
mount --bind /sys "$root/sys"; mounted+=("$root/sys")
mount -o remount,bind,ro "$root/sys"
mount --rbind /dev "$root/dev"; mounted+=("$root/dev")
mount --make-rslave "$root/dev"
mount -t tmpfs -o nosuid,nodev,mode=0755,size=64m tmpfs "$root/run"; mounted+=("$root/run")
# resolved's stub path, filled from the host for the build; it is the link the
# booted system keeps.
install -d -m 0755 "$root/run/systemd/resolve"
cp -L /etc/resolv.conf "$root/run/systemd/resolve/stub-resolv.conf"
rm -f "$root/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"

in_root() {
    chroot "$root" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C TERM=dumb DEBIAN_FRONTEND=noninteractive "$@"
}
printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"
chmod 0755 "$root/usr/sbin/policy-rc.d"
cat > "$root/etc/apt/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: resolute resolute-updates resolute-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
rm -f "$root/etc/apt/sources.list"

# --- Identity that package scripts would otherwise generate: SSH host keys
# (so the owner's PC keeps trusting the Nano) and the hostname.
install -d -m 0755 "$root/etc/ssh"
keys=0
for key in /etc/ssh/ssh_host_*_key; do
    install -m 0600 "$key" "$root/etc/ssh/"
    install -m 0644 "$key.pub" "$root/etc/ssh/"
    keys=$((keys + 1))
done
(( keys > 0 )) || die 'no SSH host keys on the host'
hostname=$(cat /etc/hostname)
printf '%s\n' "$hostname" > "$root/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' \
    "$hostname" > "$root/etc/hosts"

# --- Ubuntu's packages.
in_root apt-get update
in_root apt-get --yes -o Dpkg::Options::=--force-confold full-upgrade
in_root apt-get --yes --no-install-recommends -o Dpkg::Options::=--force-confold \
    install "${PACKAGES[@]}"
[[ $(in_root systemctl --version | head -n 1) == 'systemd 259'* ]] || die 'systemd is not 259'
for key in /etc/ssh/ssh_host_*_key; do
    cmp -s "$key" "$root$key" || die "$key was replaced"
done

# --- The 5.10 modules from APP, indexed by 26.04's kmod.
install -d -m 0755 "$root/usr/lib/modules"
cp -a "$modules" "$root/usr/lib/modules/"
rm -f "$root/usr/lib/modules/$KERNEL"/{build,source}
in_root depmod -a "$KERNEL"
grep -q '/nvgpu.ko:' "$root/usr/lib/modules/$KERNEL/modules.dep" || die 'depmod lost nvgpu'

# --- Firmware 5.10 needs uncompressed (it cannot read 26.04's .zst files).
install -D -m 0644 "$inputs/firmware/rtlwifi/rtl8188eufw.bin" \
    "$root/usr/lib/firmware/rtlwifi/rtl8188eufw.bin"

# --- The Nano's NVIDIA files and CUDA 10.2, through apt for their dependencies.
stage=$root/var/tmp/u26-inputs
install -d -m 0755 "$stage"
cp "$inputs"/nano-l4t/*.deb "$inputs"/cuda/*.deb "$stage/"
debs=("$stage"/*.deb)
in_root apt-get --yes --no-install-recommends -o Dpkg::Options::=--force-confold \
    install "${debs[@]#"$root"}"
rm -rf "$stage"
in_root ldconfig

# --- The owner's account: same name, IDs and password hash; Ubuntu's groups.
groups=()
for g in adm cdrom sudo dip plugdev video audio render input netdev; do
    if in_root getent group "$g" >/dev/null; then groups+=("$g"); fi
done
[[ $(in_root getent group video | cut -d: -f3) == 44 ]] || die '26.04 video group is not GID 44'
in_root groupadd --gid 1000 "$user"
in_root useradd --uid 1000 --gid 1000 --comment "$gecos" --home-dir "$home" \
    --shell /bin/bash --create-home --groups "$(IFS=,; echo "${groups[*]}")" "$user"
hash=$(getent shadow "$user" | cut -d: -f2)
[[ $hash == '$'* ]] || die "no password hash for $user"
printf '%s:%s\n' "$user" "$hash" | in_root chpasswd --encrypted
unset hash
install -d -m 0700 -o 1000 -g 1000 "$root$home/.ssh"
install -m 0600 -o 1000 -g 1000 "$home/.ssh/authorized_keys" "$root$home/.ssh/authorized_keys"

# --- Network: the saved NetworkManager profiles (Wi-Fi included), unchanged,
# and every device managed, as on JetPack 4.
profiles=0
for file in /etc/NetworkManager/system-connections/*; do
    [[ -f $file ]] || continue
    base=${file##*/}
    install -m 0600 "$file" "$root/etc/NetworkManager/system-connections/${base%.nmconnection}.nmconnection"
    profiles=$((profiles + 1))
done
install -d -m 0755 "$root/etc/NetworkManager/conf.d"
: > "$root/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"

# --- Time, locale, mounts and the first boot target.
if [[ -f /etc/timezone ]]; then tz=$(cat /etc/timezone); else
    tz=$(readlink -f /etc/localtime | sed -n 's|^/usr/share/zoneinfo/||p'); fi
[[ -f $root/usr/share/zoneinfo/$tz ]] || die "no zone $tz in 26.04"
ln -sfn "/usr/share/zoneinfo/$tz" "$root/etc/localtime"
printf '%s\n' "$tz" > "$root/etc/timezone"
# The same LANG and LC_* settings, each UTF-8 locale built with localedef.
: > "$root/etc/default/locale"
locales=()
while IFS='=' read -r key value; do
    value=${value//\"/}
    [[ $key =~ ^(LANG|LANGUAGE|LC_[A-Z]+)$ && -n $value ]] || continue
    if [[ $key != LANGUAGE ]]; then
        [[ $value =~ ^([a-z]{2,3}_[A-Z]{2})\.(UTF-8|utf8)$ ]] || { printf 'locale: skipped %s=%s\n' "$key" "$value"; continue; }
        value=${BASH_REMATCH[1]}.UTF-8
        [[ " ${locales[*]} " == *" $value "* ]] || locales+=("$value")
    fi
    printf '%s="%s"\n' "$key" "$value" >> "$root/etc/default/locale"
done < <(grep -E '^[A-Z_]+=' /etc/default/locale 2>/dev/null || true)
for value in "${locales[@]}"; do in_root localedef -i "${value%.UTF-8}" -f UTF-8 "$value"; done
grep -q '^LANG=' "$root/etc/default/locale" || printf 'LANG="C.UTF-8"\n' >> "$root/etc/default/locale"
lang=$(sed -n 's/^LANG="\(.*\)"$/\1/p' "$root/etc/default/locale")
printf 'UUID=%s / ext4 defaults,noatime,errors=remount-ro 0 1\n' "$fs_uuid" > "$root/etc/fstab"
in_root systemd-machine-id-setup
# A persistent journal, so a failed first boot can be read from APP's boot.
in_root install -d -m 2755 -o root -g systemd-journal /var/log/journal
in_root systemctl set-default multi-user.target

# --- Checks in the chroot.
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || failed+=("$1"); }
failed=()
[[ -z $(in_root dpkg --audit) ]] && check DPKG_AUDIT PASS || check DPKG_AUDIT FAIL
in_root ldconfig -p > "$record/ldconfig.txt"
grep -q 'libcuda.so.1 .*=> /usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1$' "$record/ldconfig.txt" \
    && check LIBCUDA PASS || check LIBCUDA FAIL
grep -q 'libcudart.so.10.2 .*=> /usr/local/cuda-10.2/targets/aarch64-linux/lib/libcudart.so.10.2$' \
    "$record/ldconfig.txt" && check LIBCUDART PASS || check LIBCUDART FAIL
units=(NetworkManager.service systemd-resolved.service systemd-timesyncd.service
    nvpmodel.service nano-cpu-governor.service)
in_root systemctl is-enabled "${units[@]}" ssh.socket ssh.service > "$record/units-enabled.txt" || true
cat "$record/units-enabled.txt"
in_root systemctl is-enabled --quiet "${units[@]}" \
    && { in_root systemctl is-enabled --quiet ssh.socket || in_root systemctl is-enabled --quiet ssh.service; } \
    && check UNITS_ENABLED PASS || check UNITS_ENABLED FAIL
in_root udevadm verify --resolve-names=never /usr/lib/udev/rules.d/99-nano-l4t.rules \
    && check UDEV_RULES PASS || check UDEV_RULES FAIL
install -d -m 0755 "$root/run/sshd"
in_root sshd -t && check SSHD_CONFIG PASS || check SSHD_CONFIG FAIL
set +e
in_root timeout 120 systemd-analyze verify --man=no nvpmodel.service nano-cpu-governor.service
printf 'SYSTEMD_ANALYZE_VERIFY_EXIT=%s\n' "$?"
set -e

# --- CUDA on the real GPU, as the owner's account inside 26.04. Built here
# with JetPack 4's nvcc (26.04's GCC is too new for CUDA 10.2), linked against
# the runtime the image installed.
probe=$root/opt/nano-cuda-probe
install -d -m 0755 "$probe"
flags=(-std=c++11 -O2 -arch=sm_53 --cudart shared)
"$nvcc" "${flags[@]}" -I /usr/local/cuda-10.2/samples/common/inc "$sample" -o "$probe/deviceQuery"
"$nvcc" "${flags[@]}" "$inputs/vector_add.cu" -o "$probe/vector_add"
sha256sum "$sample" "$inputs/vector_add.cu" "$probe/deviceQuery" "$probe/vector_add" > "$record/probe-sha256.txt"
as_owner() {
    chroot "$root" /usr/bin/env -i HOME="$home" PATH=/usr/bin:/bin LC_ALL=C \
        setpriv --reuid=1000 --regid=1000 --init-groups "$@"
}
in_root ldd /opt/nano-cuda-probe/vector_add | tee "$record/probe-ldd.txt"
! grep -q 'not found' "$record/probe-ldd.txt" \
    && grep -q 'libcudart.so.10.2 => /usr/local/cuda-10.2/' "$record/probe-ldd.txt" \
    && check PROBE_LINKS PASS || check PROBE_LINKS FAIL
as_owner id | tee "$record/probe-id.txt"
set +e
as_owner /opt/nano-cuda-probe/deviceQuery > "$record/deviceQuery.log" 2>&1
printf 'DEVICEQUERY_EXIT=%s\n' "$?"
as_owner /opt/nano-cuda-probe/vector_add --seconds 10 > "$record/vector_add.log" 2>&1
printf 'VECTOR_ADD_EXIT=%s\n' "$?"
set -e
tail -n 4 "$record/deviceQuery.log"
cat "$record/vector_add.log"
grep -q 'Result = PASS' "$record/deviceQuery.log" && check CUDA_DEVICEQUERY PASS || check CUDA_DEVICEQUERY FAIL
grep -qx 'RESULT=PASS' "$record/vector_add.log" && check CUDA_VECTOR_ADD PASS || check CUDA_VECTOR_ADD FAIL

# --- Finish: the record (no secrets), then leave the root ready to boot.
in_root dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' > "$record/packages.txt"
sha256sum "$root"/var/cache/apt/archives/*.deb > "$record/archives-sha256.txt" 2>/dev/null || true
in_root apt-get clean
rm -f "$root/usr/sbin/policy-rc.d"
{
    printf 'stamp=%s\nkernel=%s %s\npartition=%s\nfs_uuid=%s\n' "$stamp" "$(uname -r)" "$(uname -v)" "$PART" "$fs_uuid"
    printf 'systemd=%s\n' "$(in_root systemctl --version | head -n 1)"
    printf 'glibc=%s\n' "$(in_root ldd --version | head -n 1)"
    printf 'packages=%s\nssh_host_keys=%s\nnm_profiles=%s\naccount=%s groups=%s\n' \
        "$(wc -l < "$record/packages.txt")" "$keys" "$profiles" "$user" "${groups[*]}"
    printf 'timezone=%s\nlang=%s locales=%s\nused_bytes=%s\n' "$tz" "$lang" "${locales[*]}" "$(df -B1 --output=used "$root" | tail -n 1)"
    sha256sum "$self"
} | tee "$record/summary.txt"
install -d -m 0755 "$root/var/log/nano-u26"
cp "$record/summary.txt" "$root/var/log/nano-u26/build-$stamp.txt"
if (( ${#failed[@]} )); then
    die "checks failed: ${failed[*]}"
fi
printf 'U26_ROOT=PASS record=%s\n' "$record"

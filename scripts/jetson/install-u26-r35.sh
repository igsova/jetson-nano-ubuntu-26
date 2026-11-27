#!/usr/bin/env bash
# Move Ubuntu 26.04 onto JetPack 5's GPU stack: CUDA 11.4 in, CUDA 10.2 out.
#
# Usage, from an SSH login to the Nano (not from a terminal on its desktop):
#   sudo bash install-u26-r35.sh INPUTS_DIR...
#
# Ubuntu 26.04 under the 5.10 kernel, with the nano-l4t packages from
# L4T R32.7.6 and CUDA 10.2's libraries that build-u26-root.sh installed. The
# INPUTS_DIRs hold the .debs pinned below, each checked against its SHA-256
# here (any folder may hold any of them): the five nano-l4t packages that
# build-nano-l4t-debs.py --release r35 builds from L4T R35.6, and NVIDIA's CUDA
# 11.4 runtime libraries, cuDNN 8.6 and TensorRT 8.5 with trtexec, as
# fetch-r35-cuda.py --set install fetched them from NVIDIA's signed index.
#
# One apt transaction upgrades the nano-l4t packages to R35.6, installs those
# NVIDIA packages and purges every CUDA 10.2 package. The plan must be exactly
# that: nothing else is installed, upgraded or removed, and no file of a new
# package may belong to another package now or come in two of them. The
# display manager is stopped for the change, which ends the desktop session
# (save work first), and started again after it, on R35.6's X driver. Then the
# new udev rules are applied to the GPU's device nodes; /opt/nano-cuda-probe
# (CUDA 10.2 test programs build-u26-root.sh left) and links ldconfig left in
# CUDA 10.2's folder are removed; the login screen's X server is checked
# (R35.6's driver, GLX with direct rendering); and check-u26-r35.sh runs as
# the account that ran sudo. The record goes to ~/u26-r35/<stamp>.
# Run again after a pass, it changes nothing and checks again.
#
# The boot partitions, the kernel, its modules and the QSPI are not touched.
# Undo: apt-get install --allow-downgrades the R32.7.6 nano-l4t and CUDA 10.2
# .debs of the 26.04 build, and purge the packages this installed.
# The last line is U26_R35_INSTALL=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
NANO_L4T=35.6.5-20260701022834+u26.1
XORG=/usr/lib/nano-xorg/Xorg
declare -A PINS=(  # .deb -> SHA-256
    # scripts/host/build-nano-l4t-debs.py --release r35, on the owner's PC
    [nano-l4t-core_35.6.5-20260701022834+u26.1_arm64.deb]=9dcf5bedfd6739cfb1b4a73e24dc99af38363bd00761067be1d56afaa1898edd
    [nano-l4t-cuda_35.6.5-20260701022834+u26.1_arm64.deb]=8a3720e9a4b3e1c688dc60f27cc71de2eed2d981a0d7973a9a063e852b21efcb
    [nano-l4t-gl_35.6.5-20260701022834+u26.1_arm64.deb]=6ec88f998c9a0e1d4a4110c569c6aed89f7313657961968bd9a292c1b4421cb4
    [nano-l4t-power_35.6.5-20260701022834+u26.1_arm64.deb]=fea5baa2ae9b7add30761025307330f81a0a91e8b03ec319472471b49762f8e6
    [nano-l4t-x11_35.6.5-20260701022834+u26.1_arm64.deb]=00a8aea4b90496748f0053782f0242b9e7425cb52b4ac363fd2f4c145224f1fe
    # NVIDIA's signed common r35.6 index, through fetch-r35-cuda.py --set install
    [cuda-cudart-11-4_11.4.298-1_arm64.deb]=488274208dc7bc2c0b0c803277926510b5e586ecc2b239a695978158da191ccd
    [cuda-libraries-11-4_11.4.19-1_arm64.deb]=42e281734bb997a7b8ce9e92027be5a284d8e05a55008e1afb73b886d7bb6bc3
    [cuda-nvrtc-11-4_11.4.300-1_arm64.deb]=f0e4150e89624d85dc6aaaec09fad97e36d285212f6765b24db9e69b85c2f0b0
    [cuda-toolkit-11-4-config-common_11.4.298-1_all.deb]=39d1aee28677c015029972737fdc05bfa95c8e6738470821465bbc7dac5ef270
    [cuda-toolkit-11-config-common_11.4.298-1_all.deb]=fc68012eed2562378187a120b6df79a5895ba490ef0706714f3071087de89805
    [cuda-toolkit-config-common_11.4.298-1_all.deb]=f04b8db43032a67ffd092f855ed1e7dd3ce4647370f3b85c87ef1d593f460404
    [libcublas-11-4_11.6.6.84-1_arm64.deb]=53de2203b45dc2e47472c9a48e2dd6c5d11b78a9ee94a1d8e5707e11feffe703
    [libcudla-11-4_11.4.298-1_arm64.deb]=2134a55a748364c3239e2003b46bf9b14893c6cd5f25c7c93d8f8beb312adf5c
    [libcudnn8_8.6.0.166-1+cuda11.4_arm64.deb]=4a679b9676d4d1bfd2d7a3572eefc916706219ad006e38a8fd2377067fd635ee
    [libcufft-11-4_10.6.0.202-1_arm64.deb]=87f2161d58e3766f4d1ac695dae673ad6bad0e0e8a5f9866506dccae6c72219f
    [libcurand-11-4_10.2.5.297-1_arm64.deb]=d4e0025162c0c68d792b373f50843328234918e450258873f6325630580af692
    [libcusolver-11-4_11.2.0.297-1_arm64.deb]=f2e39c718793bfbe6dd99bac3ccf8029b7f869bb92160fce5b281e32b4535c6e
    [libcusparse-11-4_11.6.0.299-1_arm64.deb]=b1fedfac989075df9dfa3c36977df61fd3f3f1969bef10c451d03b3801dda04a
    [libnpp-11-4_11.4.0.287-1_arm64.deb]=c86078219861dc4830f1d63cb6d70844e98b71287cb9431617325f5aa6783c02
    [libnvinfer-bin_8.5.2-1+cuda11.4_arm64.deb]=b73224d8eb9675e7d616ee5c47ffa1c01501734ca326f599d42de61f2ea5d2d2
    [libnvinfer-plugin8_8.5.2-1+cuda11.4_arm64.deb]=3026cff562d367e35ad25f7d1dde555eea63283317784baa03dd23ef96616db1
    [libnvinfer8_8.5.2-1+cuda11.4_arm64.deb]=55012013528106fca0fb0fd3dbf73a54b8e441567fe7144d1523e5609f036c31
    [libnvonnxparsers8_8.5.2-1+cuda11.4_arm64.deb]=7cd2c461c0ef020853c4df618d0e57ca33bb889d019a691696dba293ac11bbc8
    [libnvparsers8_8.5.2-1+cuda11.4_arm64.deb]=5ef03cac6744145037eb6ea00b63eaf4d99a04c41800fc5d76252d55bcc09801
)
# The delivery folder: this script, the check and its test files.
HERE_FILES=(install-u26-r35.sh check-u26-r35.sh cuda11_probe.py egl_probe.py vk_probe.py trt_check.py
            tiny_cnn.onnx expected.json)
OLD_CUDA='(-10-2|^libcublas10)$'  # CUDA 10.2's package names

die() { printf 'U26_R35_INSTALL=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
(( $# )) || die 'give the folders holding the .debs (for example ~/u26-r35-debs)'
inputs=()
for dir in "$@"; do
    [[ -d $dir ]] || die "no inputs folder $dir"
    inputs+=("$(cd "$dir" && pwd)")
done
[[ $(id -u) -eq 0 ]] || die 'run this with sudo'
owner=${SUDO_USER:-}
[[ -n $owner && $owner != root ]] || die 'run this with sudo from your own account'
IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || die "no account $owner"
[[ -d $home ]] || die "no home folder for $owner"
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for file in "${HERE_FILES[@]}"; do
    (cd "$here" && grep -E "  ${file//./\\.}\$" SHA256SUMS | sha256sum --quiet -c -) > /dev/null 2>&1 \
        || die "$file does not match the SHA256SUMS next to this script"
done
(( ${#PINS[@]} )) || die 'no .debs are pinned in this copy of the script'

# Stopping the display manager closes the desktop and its terminals: refuse
# unless an SSH login or a text console started this.
from_login() {
    local pid=$$ comm
    while (( pid > 1 )); do
        comm=$(< "/proc/$pid/comm") || return 1
        [[ $comm == sshd* || $comm == login ]] && return 0
        pid=$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status") || return 1
    done
    return 1
}
from_login || die 'start this from an SSH login from your PC: it restarts the desktop and closes its terminals'
for tool in apt-get dpkg dpkg-deb dpkg-query runuser systemctl udevadm pgrep timeout tar setsid; do
    command -v "$tool" > /dev/null || die "no $tool"
done

# --- The inputs, by pin.
declare -A DEB_OF=()  # package -> its pinned .deb
debs=()
for name in $(printf '%s\n' "${!PINS[@]}" | sort); do
    found=
    for dir in "${inputs[@]}"; do
        [[ -f $dir/$name ]] && { found=$dir/$name; break; }
    done
    [[ -n $found ]] || die "no $name in ${inputs[*]}"
    [[ $(sha256sum < "$found" | cut -d ' ' -f 1) == "${PINS[$name]}" ]] || die "$found does not match its pin"
    pkg=$(dpkg-deb -f "$found" Package) || die "cannot read $found"
    [[ $name == "${pkg}_"* && -z ${DEB_OF[$pkg]:-} ]] || die "$name holds package $pkg, or $pkg is pinned twice"
    DEB_OF[$pkg]=$found
    debs+=("$found")
done
for pkg in nano-l4t-core nano-l4t-cuda nano-l4t-gl nano-l4t-x11 nano-l4t-power; do
    [[ $(dpkg-deb -f "${DEB_OF[$pkg]:-/dev/null}" Version 2> /dev/null) == "$NANO_L4T" ]] \
        || die "no $pkg $NANO_L4T among the pins"
done

stamp=$(date -u +%Y%m%dT%H%M%SZ)
parent=$home/u26-r35
record=$parent/$stamp
[[ -d $parent ]] || { mkdir -m 0755 "$parent" && chown "$uid:$gid" "$parent"; } || die "cannot create $parent"
mkdir -m 0755 "$record" || die "cannot create $record"
stage=/var/tmp/u26-r35-debs
# Losing the SSH connection or pressing Ctrl+C still ends with the desktop back.
trap '' HUP PIPE
exec 3>&1 4>&2
exec > >(trap '' INT TERM; exec tee --output-error=warn "$record/summary.txt") 2>&1
tee_pid=$!
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\nACCOUNT=%s\n' \
    "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME" "$(id "$owner")"
for pkg in $(printf '%s\n' "${!DEB_OF[@]}" | sort); do
    printf 'INPUT %s %s\n' "$pkg" "$(dpkg-deb -f "${DEB_OF[$pkg]}" Version)"
done

result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS* ]] || result=FAIL; }
alive() { local state; state=$(sed 's/.*) //' "/proc/$1/stat" 2> /dev/null | cut -c 1); [[ -n $state && $state != Z ]]; }
dm_xorg() { pgrep -n -f "^$XORG .*-seat seat0"; }  # LightDM's X server; the pattern cannot match pgrep itself
dm_stopped=0
restore_desktop() {
    local pid=
    dm_stopped=0
    systemctl start display-manager || { check DESKTOP 'FAIL the display manager did not start'; return 1; }
    for _ in $(seq 60); do
        pid=$(dm_xorg) && break
        sleep 0.5
    done
    sleep 3
    if [[ -n $pid ]] && alive "$pid" && systemctl is-active --quiet display-manager; then
        printf 'DESKTOP_XORG=%s\n' "$(tr '\0' ' ' < "/proc/$pid/cmdline")"
        check DESKTOP_STARTED PASS
        xpid=$pid
    else
        check DESKTOP_STARTED FAIL
        xpid=
    fi
}
finish() {
    trap - EXIT
    trap '' INT TERM
    (( dm_stopped )) && restore_desktop
    rm -rf "$stage"
    chown -R "$uid:$gid" "$record"
    printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
    printf 'U26_R35_INSTALL=%s record=%s\n' "$result" "$record"
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    [[ $result == PASS ]] && exit 0  # (exit with no status in a trap keeps the status before it)
    exit 1
}
trap finish EXIT
trap 'printf "INTERRUPTED\n"; result=FAIL; exit 130' INT TERM
fail() { check "$1" "FAIL $2"; exit 1; }

# --- The plan: the pinned packages in, CUDA 10.2 out, nothing else.
dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' > "$record/packages-before.txt"
mapfile -t old_cuda < <(awk -v re="$OLD_CUDA" '$1 ~ /^.i/ && $2 ~ re { print $2 }' "$record/packages-before.txt")
printf 'CUDA_10_2=%s\n' "${old_cuda[*]:-none}"
todo=()
for pkg in $(printf '%s\n' "${!DEB_OF[@]}" | sort); do
    have=$(awk -v p="$pkg" '$1 ~ /^.i/ && $2 == p { print $3 }' "$record/packages-before.txt")
    [[ $have == "$(dpkg-deb -f "${DEB_OF[$pkg]}" Version)" ]] || todo+=("$pkg")
done
printf 'TO_INSTALL=%s\n' "${todo[*]:-none}"

if (( ${#todo[@]} + ${#old_cuda[@]} )); then
    # No file of a new package may belong to another package now, or come in
    # two of them unless dpkg allows that (the same link to a directory);
    # files no package owns (such as links ldconfig made) are only listed.
    clash=0
    for pkg in "${todo[@]}"; do
        dpkg-deb --fsys-tarfile "${DEB_OF[$pkg]}" | tar -tv > "$record/list-$pkg.txt" \
            || fail FILE_OWNERS "cannot list ${DEB_OF[$pkg]}"
        # GNU tar's long listing: mode, owner, size, date and time, then ./path,
        # with " -> target" after a link and " link to path" after a hard link.
        : > "$record/dirs-$pkg.txt"; : > "$record/paths-$pkg.txt"
        awk -v dirs="$record/dirs-$pkg.txt" -v paths="$record/paths-$pkg.txt" '{
                type = substr($1, 1, 1)
                sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, ""); sub(/^\.\//, "/")
                if (type == "d") { sub(/\/$/, ""); if ($0 != "") print > dirs; next }
                if (type == "l") sub(/ -> .*$/, ""); else if (type == "h") sub(/ link to .*$/, "")
                print > paths
            }' "$record/list-$pkg.txt"
        xargs -d '\n' -r dpkg-query -S < "$record/paths-$pkg.txt" 2> /dev/null \
            | grep -vE '^(local )?diversion ' > "$record/owners-$pkg.txt"
        while IFS= read -r line; do
            owners=${line%%: /*}; path=/${line#*: /}
            owners=$(sed 's/:[a-z0-9]*//g' <<< "$owners")
            [[ ", $owners, " == *", $pkg, "* ]] && continue
            printf 'OWNED_ELSEWHERE %s by %s (in %s)\n' "$path" "$owners" "$pkg"; clash=1
        done < "$record/owners-$pkg.txt"
        sed 's|^[^/]*: /|/|' "$record/owners-$pkg.txt" > "$record/owned-$pkg.txt"
        while IFS= read -r path; do
            [[ -e $path || -L $path ]] && ! grep -qxF -- "$path" "$record/owned-$pkg.txt" \
                && printf 'UNOWNED_EXISTS %s (in %s)\n' "$path" "$pkg"
        done < "$record/paths-$pkg.txt"
        rm -f "$record/owned-$pkg.txt"
    done
    # dpkg lets several packages ship one path only as the same link to a
    # directory: nine of NVIDIA's CUDA 11.4 packages each ship
    # /usr/local/cuda-11.4/lib64 -> targets/aarch64-linux/lib.
    link_of() {  # PKG PATH: the target, when PKG ships PATH as a link
        awk -v p=".$2" 'substr($1, 1, 1) == "l" {
                sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, ""); n = index($0, " -> ")
                if (n && substr($0, 1, n - 1) == p) { print substr($0, n + 4); exit }
            }' "$record/list-$1.txt"
    }
    new_dirs=$(for pkg in "${todo[@]}"; do cat "$record/dirs-$pkg.txt"; done | sort -u)
    while IFS= read -r path; do
        targets=()
        for pkg in "${todo[@]}"; do
            grep -qxF -- "$path" "$record/paths-$pkg.txt" && targets+=("$(link_of "$pkg" "$path")")
        done
        target=${targets[0]}
        for other in "${targets[@]}"; do [[ $other == "$target" ]] || target=; done
        [[ $target == /* ]] && dir=$target || dir=${path%/*}/$target
        if [[ -n $target && $target != *..* ]] \
                && { grep -qxF -- "$dir" <<< "$new_dirs" || [[ -d $dir && ! -L $dir ]]; }; then
            printf 'SHARED_LINK %s -> %s (in %s packages)\n' "$path" "$target" "${#targets[@]}"
        else
            printf 'IN_TWO_PACKAGES %s\n' "$path"; clash=1
        fi
    done < <(for pkg in "${todo[@]}"; do cat "$record/paths-$pkg.txt"; done | sort | uniq -d)
    (( clash == 0 )) && check FILE_OWNERS PASS || fail FILE_OWNERS 'a new file belongs to another package'

    # Staged in a folder only root writes, checked again there, where apt reads them.
    rm -rf "$stage"
    install -d -m 0755 "$stage"
    need=$(( 1024 * 1024 * 1024 ))
    staged=()
    for pkg in "${todo[@]}"; do
        need=$(( need + $(dpkg-deb -f "${DEB_OF[$pkg]}" Installed-Size) * 1024 + $(stat -c %s "${DEB_OF[$pkg]}") ))
    done
    free=$(( $(df -B1 --output=avail / | tail -n 1) ))
    printf 'SPACE=%s MiB free, %s MiB needed\n' "$(( free >> 20 ))" "$(( need >> 20 ))"
    (( free > need )) || fail SPACE 'not enough free space on /'
    for pkg in "${todo[@]}"; do
        name=$(basename "${DEB_OF[$pkg]}")
        install -m 0644 "${DEB_OF[$pkg]}" "$stage/$name"
        [[ $(sha256sum < "$stage/$name" | cut -d ' ' -f 1) == "${PINS[$name]}" ]] || fail STAGE "$name changed while copied"
        staged+=("$stage/$name")
    done
    export DEBIAN_FRONTEND=noninteractive
    apt=(apt-get --no-install-recommends --purge -o Dpkg::Options::=--force-confold)
    request=("${staged[@]}" "${old_cuda[@]/%/-}")
    "${apt[@]}" -s install "${request[@]}" > "$record/plan.txt" 2>&1 \
        || { tail -n 20 "$record/plan.txt"; fail PLAN 'apt cannot plan the change'; }
    unexpected=()
    while read -r action name _; do
        case $action in
            Inst) [[ " ${todo[*]} " == *" $name "* ]] || unexpected+=("install $name") ;;
            Remv|Purg) [[ " ${old_cuda[*]} " == *" $name "* ]] || unexpected+=("remove $name") ;;
        esac
    done < <(grep -E '^(Inst|Remv|Purg) ' "$record/plan.txt")
    for pkg in "${todo[@]}"; do grep -qE "^Inst $pkg " "$record/plan.txt" || unexpected+=("not installing $pkg"); done
    for pkg in "${old_cuda[@]}"; do grep -qE "^(Remv|Purg) $pkg " "$record/plan.txt" || unexpected+=("not removing $pkg"); done
    printf 'PLAN=%s installed or upgraded, %s removed\n' "$(grep -c '^Inst ' "$record/plan.txt")" \
        "$(grep -cE '^(Remv|Purg) ' "$record/plan.txt")"
    (( ${#unexpected[@]} == 0 )) && check PLAN PASS || fail PLAN "${unexpected[*]}"

    # --- The change, with the desktop stopped.
    if systemctl is-active --quiet display-manager; then
        printf 'STOPPING_DESKTOP\n'
        dm_stopped=1
        systemctl stop display-manager || fail DESKTOP_STOP 'could not stop the display manager'
        for _ in $(seq 40); do dm_xorg > /dev/null || break; sleep 0.5; done
        dm_xorg > /dev/null && fail DESKTOP_STOP "LightDM's X server is still running"
    fi
    printf 'INSTALLING (apt-get, %s packages; this takes several minutes)\n' "$(( ${#todo[@]} + ${#old_cuda[@]} ))"
    # In its own session, so neither Ctrl+C nor a lost connection stops dpkg
    # halfway; an interrupt takes effect once apt-get is done.
    if setsid --wait "${apt[@]}" --yes install "${request[@]}" < /dev/null > "$record/apt-install.txt" 2>&1; then
        check APT_INSTALL PASS
    else
        tail -n 25 "$record/apt-install.txt"
        fail APT_INSTALL "see $record/apt-install.txt; 'sudo apt-get -f install' finishes or undoes it"
    fi
    grep -E '^(E|W): ' "$record/apt-install.txt" | head -n 10
    rm -rf "$stage"
else
    printf 'ALREADY_INSTALLED=yes\n'
fi

# --- After the change.
dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' > "$record/packages-after.txt"
dpkg --audit > "$record/dpkg-audit.txt" 2>&1
[[ ! -s $record/dpkg-audit.txt ]] && check DPKG_AUDIT PASS || check DPKG_AUDIT FAIL
diff <(awk '$1 ~ /^.i/ { print $2, $3 }' "$record/packages-before.txt") \
     <(awk '$1 ~ /^.i/ { print $2, $3 }' "$record/packages-after.txt") > "$record/packages-diff.txt"
printf 'PACKAGES_CHANGED=%s lines in packages-diff.txt\n' "$(grep -c '^[<>]' "$record/packages-diff.txt")"
ldconfig
# Every file in the tegra folders belongs to a nano-l4t package (or is a link ldconfig made).
stray=()
while IFS= read -r path; do
    if [[ -L $path && $(readlink "$path") != */* ]] && dpkg-query -S "$(dirname "$path")/$(readlink "$path")" &> /dev/null; then
        continue
    fi
    dpkg-query -S "$path" 2> /dev/null | grep -q '^nano-l4t-' || stray+=("$path")
done < <(find /usr/lib/aarch64-linux-gnu/tegra /usr/lib/aarch64-linux-gnu/tegra-egl -mindepth 1 \( -type f -o -type l \))
(( ${#stray[@]} == 0 )) && check TEGRA_FILES PASS || check TEGRA_FILES "FAIL not from nano-l4t: ${stray[*]}"
# Purging CUDA 10.2 leaves its folder when ldconfig had put links there; with
# no file left in it, it goes too.
if [[ -d /usr/local/cuda-10.2 ]] && ! dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 2> /dev/null \
        | grep -qE '^.i +[^ ]*-10-2$'; then
    left=$(find /usr/local/cuda-10.2 ! -type d ! -type l | head -n 1)
    if [[ -z $left ]]; then
        printf 'REMOVED=/usr/local/cuda-10.2 (%s links left by ldconfig)\n' "$(find /usr/local/cuda-10.2 -type l | wc -l)"
        rm -r /usr/local/cuda-10.2
    else
        printf 'KEPT=/usr/local/cuda-10.2 (holds %s)\n' "$left"
    fi
fi
if [[ -d /opt/nano-cuda-probe ]]; then
    left=$(find /opt/nano-cuda-probe -mindepth 1 ! \( -type f \( -name deviceQuery -o -name vector_add \) \) | head -n 1)
    if [[ -z $left ]]; then
        rm -f /opt/nano-cuda-probe/deviceQuery /opt/nano-cuda-probe/vector_add && rmdir /opt/nano-cuda-probe \
            && printf 'REMOVED=/opt/nano-cuda-probe (CUDA 10.2 test programs)\n'
    else
        printf 'KEPT=/opt/nano-cuda-probe (holds %s)\n' "$left"
    fi
fi

# --- The GPU's device nodes, as the new rules set them.
udevadm control --reload
udevadm trigger --action=change --subsystem-match=nvidia-gpu-v2 --subsystem-match=nvidia-gpu-v2-power
udevadm trigger --action=change --sysname-match='nvhost*' --sysname-match=nvmap --sysname-match='tegra_dc*'
udevadm settle --timeout=30 || printf 'UDEV_SETTLE=timed out\n'
ls -l /dev/nvgpu/igpu0/* /dev/nvmap /dev/nvhost-* > "$record/nodes.txt" 2>&1
sed 's/^/NODES: /' "$record/nodes.txt" | grep -E 'igpu0/|nvmap|nvhost-(ctrl|gpu|as-gpu|ctrl-gpu)$' | head -n 20

# --- The desktop, on R35.6's X driver.
xpid=
if (( dm_stopped )); then
    restore_desktop
else
    xpid=$(dm_xorg) || xpid=
fi
if [[ -n $xpid ]]; then
    maps=$(awk '$6 ~ /^\// { print $6 }' "/proc/$xpid/maps" 2> /dev/null | sort -u)
    grep -q "^${XORG%/Xorg}/modules/drivers/nvidia_drv.so\$" <<< "$maps" \
        && grep -q '/tegra/libnvidia-glcore\.so\.35\.6\.5$' <<< "$maps" \
        && check XORG_R35 PASS || check XORG_R35 'FAIL its NVIDIA driver or GL core is not R35.6'
    args=$(tr '\0' '\n' < "/proc/$xpid/cmdline")
    log=$(grep -A1 -x -- -logfile <<< "$args" | tail -n 1)
    [[ $log == /* && -f $log ]] || log=/var/log/Xorg.0.log
    grep -E 'NVIDIA dlloader X Driver|NVIDIA\(0\): NVIDIA GPU|\(EE\)' "$log" 2> /dev/null | head -n 8 | sed 's/^/XLOG: /'
    auth=$(grep -A1 -x -- -auth <<< "$args" | tail -n 1)
    if [[ -f $auth ]] && command -v glxinfo > /dev/null \
            && timeout 20 env DISPLAY=:0 XAUTHORITY="$auth" __GL_SHADER_DISK_CACHE=0 glxinfo -B \
                > "$record/glxinfo-login-screen.txt" 2>&1; then
        grep -E 'direct rendering|OpenGL version string' "$record/glxinfo-login-screen.txt" | sed 's/^/LOGIN_SCREEN_GLX: /'
        grep -q '^direct rendering: Yes' "$record/glxinfo-login-screen.txt" \
            && grep -qE '^OpenGL version string: .*NVIDIA 35\.6\.5' "$record/glxinfo-login-screen.txt" \
            && check LOGIN_SCREEN_GLX PASS || check LOGIN_SCREEN_GLX FAIL
    else
        check LOGIN_SCREEN_GLX "FAIL glxinfo could not use the login screen's X server"
    fi
elif systemctl is-active --quiet display-manager; then
    check XORG_R35 "FAIL no X server of LightDM's found"
else
    printf 'DESKTOP=not running (not checked)\n'
fi

# --- The installed stack, as the account.
printf 'CHECK=check-u26-r35.sh as %s\n' "$owner"
runuser -u "$owner" -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$home" USER="$owner" \
    LOGNAME="$owner" LANG=C.UTF-8 bash "$here/check-u26-r35.sh" > "$record/check.txt" 2>&1
check_status=$?
grep -E '=(PASS|FAIL)|^(UNRESOLVED|NODE|PACKAGE) |=skipped' "$record/check.txt" | sed 's/^/check: /'
(( check_status == 0 )) && check INSTALLED_STACK PASS || check INSTALLED_STACK FAIL
journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1
grep -iE 'nvgpu|nvmap|smmu|mmu_fault|tegradc|nvdc|host1x' "$record/kernel.log" | tail -n 20 | sed 's/^/KERNEL: /'
exit 0

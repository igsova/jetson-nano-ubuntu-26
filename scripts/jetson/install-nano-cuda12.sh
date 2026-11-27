#!/usr/bin/env bash
# Install CUDA 12 beside CUDA 11.4 on the Nano: nano-cuda12 and nano-cuda12-dev.
#
# Usage, from an SSH login to the Nano or a terminal on it:
#   sudo bash install-nano-cuda12.sh
#
# Ubuntu 26.04 under the 5.10 kernel, with JetPack 5's driver set
# (nano-l4t R35.6) and CUDA 11.4 that install-u26-r35.sh installed. This
# script's folder is the nano/ folder scripts/host/build-nano-cuda12-debs.py
# wrote: the two .debs, check-nano-cuda12.sh and its test files, and
# SHA256SUMS, all checked here.
#
# One apt transaction installs the two packages, and the plan must be exactly
# that: nothing else installed, upgraded or removed, and no file of theirs may
# exist already or belong to another package. They have no maintainer
# scripts; their files go to /usr/local/cuda-12.2/compat (NVIDIA's CUDA 12.2
# driver for JetPack 5), /usr/local/cuda-12.6 (CUDA 12.6 and cuDNN 9) and
# /usr/bin/nano-cuda12, none in the system's library path, and /usr/local/cuda
# stays CUDA 11.4's; both are checked before and after. The desktop keeps
# running. Then check-nano-cuda12.sh runs as the account that ran sudo. The
# record goes to ~/nano-cuda12-install/<stamp>. Run again after a pass, it
# installs nothing and checks again.
#
# The boot partitions, the kernel, its modules, the driver set and the QSPI
# are not touched. Undo: sudo apt-get purge nano-cuda12 nano-cuda12-dev.
# The last line is NANO_CUDA12_INSTALL=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
PACKAGES=(nano-cuda12 nano-cuda12-dev)
HERE_FILES=(install-nano-cuda12.sh check-nano-cuda12.sh cuda11_probe.py cuda_libs_probe.py vector_add.cu
            gpu_probe.cu cuda12_dev_check.cu)
# Library names that must stay out of the system's library path.
CUDA12_NAMES='lib(cudart\.so\.12|cublas(Lt)?\.so\.12|cudnn[a-z_]*\.so\.9|nvrtc\.so\.12|nvJitLink\.so\.12)'

die() { printf 'NANO_CUDA12_INSTALL=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
[[ $(id -u) -eq 0 ]] || die 'run this with sudo'
owner=${SUDO_USER:-}
[[ -n $owner && $owner != root ]] || die 'run this with sudo from your own account'
IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || die "no account $owner"
[[ -d $home ]] || die "no home folder for $owner"
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for tool in apt-get dpkg dpkg-deb dpkg-query runuser setsid ldconfig sha256sum; do
    command -v "$tool" > /dev/null || die "no $tool"
done
[[ -f $here/SHA256SUMS ]] || die "no SHA256SUMS next to this script"
sum_of() { awk -v n="$1" '$2 == n' "$here/SHA256SUMS"; }  # NAME: its line in SHA256SUMS
for file in "${HERE_FILES[@]}"; do
    (cd "$here" && sum_of "$file" | grep . | sha256sum --quiet -c -) > /dev/null 2>&1 \
        || die "$file does not match the SHA256SUMS next to this script"
done
driver=$(dpkg-query -W -f '${db:Status-Abbrev} ${Version}' nano-l4t-core 2> /dev/null)
[[ $driver == ii\ *35.6.* ]] || die "needs JetPack 5's driver set (nano-l4t-core 35.6) installed (found: ${driver:-none})"

# --- The two .debs, by the sums next to them.
declare -A DEB_OF=()
for pkg in "${PACKAGES[@]}"; do
    found=("$here/${pkg}_"*_arm64.deb)
    [[ ${#found[@]} -eq 1 && -f ${found[0]} ]] || die "need exactly one ${pkg}_*_arm64.deb next to this script"
    name=$(basename "${found[0]}")
    (cd "$here" && sum_of "$name" | grep . | sha256sum --quiet -c -) > /dev/null 2>&1 \
        || die "$name does not match the SHA256SUMS next to this script"
    [[ $(dpkg-deb -f "${found[0]}" Package) == "$pkg" ]] || die "$name does not hold $pkg"
    DEB_OF[$pkg]=${found[0]}
done
version=$(dpkg-deb -f "${DEB_OF[nano-cuda12]}" Version)
[[ $(dpkg-deb -f "${DEB_OF[nano-cuda12-dev]}" Version) == "$version" ]] || die 'the two .debs are not the same version'

stamp=$(date -u +%Y%m%dT%H%M%SZ)
parent=$home/nano-cuda12-install
record=$parent/$stamp
[[ -d $parent ]] || { mkdir -m 0755 "$parent" && chown "$uid:$gid" "$parent"; } || die "cannot create $parent"
mkdir -m 0755 "$record" || die "cannot create $record"
stage=/var/tmp/nano-cuda12-debs
trap '' HUP PIPE
exec 3>&1 4>&2
exec > >(trap '' INT TERM; exec tee --output-error=warn "$record/summary.txt") 2>&1
tee_pid=$!
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\nACCOUNT=%s\nVERSION=%s\nDRIVER_SET=%s\n' \
    "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME" "$(id "$owner")" "$version" "${driver##* }"

result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS* ]] || result=FAIL; }
finish() {
    trap - EXIT
    trap '' INT TERM
    rm -rf "$stage"
    chown -R "$uid:$gid" "$record"
    printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
    printf 'NANO_CUDA12_INSTALL=%s record=%s\n' "$result" "$record"
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    [[ $result == PASS ]] && exit 0
    exit 1
}
trap finish EXIT
trap 'printf "INTERRUPTED\n"; result=FAIL; exit 130' INT TERM
fail() { check "$1" "FAIL $2"; exit 1; }

system_state() {  # what must not change: /usr/local/cuda and CUDA 12 names in the library path
    printf 'usr_local_cuda=%s\n' "$(readlink -f /usr/local/cuda 2> /dev/null || echo none)"
    ldconfig -p | grep -E "$CUDA12_NAMES" | sed 's/^[[:space:]]*/ldconfig: /'
}
system_state > "$record/system-before.txt"
sed 's/^/BEFORE: /' "$record/system-before.txt"
grep -q '^ldconfig: ' "$record/system-before.txt" \
    && fail SYSTEM_BEFORE 'a CUDA 12 or cuDNN 9 library is already in the library path'

# --- The plan: the two packages in, nothing else.
dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' > "$record/packages-before.txt"
todo=()
for pkg in "${PACKAGES[@]}"; do
    have=$(awk -v p="$pkg" '$1 ~ /^.i/ && $2 == p { print $3 }' "$record/packages-before.txt")
    [[ $have == "$version" ]] || todo+=("$pkg")
done
printf 'TO_INSTALL=%s\n' "${todo[*]:-none}"

if (( ${#todo[@]} )); then
    # No file of a new package may exist already: neither another package's
    # nor one no package owns (an earlier manual CUDA 12 install, say).
    clash=0
    for pkg in "${todo[@]}"; do
        dpkg-deb --fsys-tarfile "${DEB_OF[$pkg]}" | tar -t | sed -n 's|^\./|/|; /[^/]$/p' > "$record/paths-$pkg.txt" \
            || fail FILE_OWNERS "cannot list ${DEB_OF[$pkg]}"
        while IFS= read -r path; do
            [[ -e $path || -L $path ]] || continue
            [[ -d $path && ! -L $path ]] && continue
            owners=$(dpkg-query -S "$path" 2> /dev/null | grep -v '^diversion ' | sed 's/: .*//' | paste -sd ' ')
            if [[ -n $owners && " ${owners//,/ } " != *" $pkg "* ]]; then
                printf 'OWNED_ELSEWHERE %s by %s (in %s)\n' "$path" "$owners" "$pkg"
            elif [[ -z $owners ]]; then
                printf 'EXISTS_UNOWNED %s (in %s)\n' "$path" "$pkg"
            else
                continue
            fi
            clash=1
        done < "$record/paths-$pkg.txt"
    done
    (( clash == 0 )) && check FILE_OWNERS PASS || fail FILE_OWNERS 'a file of the new packages is already there'

    # Staged in a folder only root writes, checked again there, where apt reads them.
    rm -rf "$stage"
    install -d -m 0755 "$stage"
    need=$(( 1024 * 1024 * 1024 ))
    for pkg in "${todo[@]}"; do
        need=$(( need + $(dpkg-deb -f "${DEB_OF[$pkg]}" Installed-Size) * 1024 + $(stat -c %s "${DEB_OF[$pkg]}") ))
    done
    free=$(( $(df -B1 --output=avail /usr/local | tail -n 1) ))
    printf 'SPACE=%s MiB free, %s MiB needed\n' "$(( free >> 20 ))" "$(( need >> 20 ))"
    (( free > need )) || fail SPACE 'not enough free space for /usr/local'
    staged=()
    for pkg in "${todo[@]}"; do
        name=$(basename "${DEB_OF[$pkg]}")
        install -m 0644 "${DEB_OF[$pkg]}" "$stage/$name"
        (cd "$stage" && sum_of "$name" | grep . | sha256sum --quiet -c -) > /dev/null 2>&1 \
            || fail STAGE "$name changed while copied"
        staged+=("$stage/$name")
    done
    export DEBIAN_FRONTEND=noninteractive
    apt=(apt-get --no-install-recommends -o Dpkg::Options::=--force-confold)
    "${apt[@]}" -s install "${staged[@]}" > "$record/plan.txt" 2>&1 \
        || { tail -n 20 "$record/plan.txt"; fail PLAN 'apt cannot plan the change'; }
    unexpected=()
    while read -r action name _; do
        case $action in
            Inst) [[ " ${todo[*]} " == *" $name "* ]] || unexpected+=("install $name") ;;
            Remv|Purg) unexpected+=("remove $name") ;;
        esac
    done < <(grep -E '^(Inst|Remv|Purg) ' "$record/plan.txt")
    for pkg in "${todo[@]}"; do grep -qE "^Inst $pkg " "$record/plan.txt" || unexpected+=("not installing $pkg"); done
    printf 'PLAN=%s installed or upgraded, %s removed\n' "$(grep -c '^Inst ' "$record/plan.txt")" \
        "$(grep -cE '^(Remv|Purg) ' "$record/plan.txt")"
    (( ${#unexpected[@]} == 0 )) && check PLAN PASS || fail PLAN "${unexpected[*]}"

    printf 'INSTALLING (apt-get, %s packages; unpacking several GB takes a few minutes)\n' "${#todo[@]}"
    # In its own session, so neither Ctrl+C nor a lost connection stops dpkg
    # halfway; an interrupt takes effect once apt-get is done.
    if setsid --wait "${apt[@]}" --yes install "${staged[@]}" < /dev/null > "$record/apt-install.txt" 2>&1; then
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
for pkg in "${PACKAGES[@]}"; do
    awk -v p="$pkg" -v v="$version" '$1 == "ii" && $2 == p && $3 == v { found = 1 } END { exit !found }' \
        "$record/packages-after.txt" && check "INSTALLED_${pkg//-/_}" PASS || check "INSTALLED_${pkg//-/_}" FAIL
done
diff <(awk '$1 ~ /^.i/ { print $2, $3 }' "$record/packages-before.txt") \
     <(awk '$1 ~ /^.i/ { print $2, $3 }' "$record/packages-after.txt") > "$record/packages-diff.txt"
changed=$(grep '^[<>]' "$record/packages-diff.txt" | awk '{ print $2 }' | sort -u | paste -sd ' ')
printf 'PACKAGES_CHANGED=%s\n' "${changed:-none}"
[[ -z $(grep '^[<>]' "$record/packages-diff.txt" | awk '{ print $2 }' | grep -vxE 'nano-cuda12(-dev)?') ]] \
    && check ONLY_THESE_PACKAGES PASS || check ONLY_THESE_PACKAGES FAIL
dpkg --audit > "$record/dpkg-audit.txt" 2>&1
[[ ! -s $record/dpkg-audit.txt ]] && check DPKG_AUDIT PASS || check DPKG_AUDIT FAIL
# Every installed file as packaged (a system that leaves documentation out of
# installs, as minimal images do, shows the doc files missing).
dpkg --verify "${PACKAGES[@]}" > "$record/dpkg-verify.txt" 2>&1
grep -vE '^missing +/usr/share/doc/' "$record/dpkg-verify.txt" > "$record/dpkg-verify-files.txt"
[[ ! -s $record/dpkg-verify-files.txt ]] && check FILES_INTACT PASS \
    || { head -n 5 "$record/dpkg-verify-files.txt"; check FILES_INTACT FAIL; }
system_state > "$record/system-after.txt"
diff "$record/system-before.txt" "$record/system-after.txt" > "$record/system-diff.txt" \
    && check SYSTEM_UNCHANGED PASS || { cat "$record/system-diff.txt"; check SYSTEM_UNCHANGED FAIL; }

# --- CUDA 12 as installed, as the account.
printf 'CHECK=check-nano-cuda12.sh as %s\n' "$owner"
runuser -u "$owner" -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$home" USER="$owner" \
    LOGNAME="$owner" LANG=C.UTF-8 bash "$here/check-nano-cuda12.sh" > "$record/check.txt" 2>&1
check_status=$?
grep -E '=(PASS|FAIL)|SGEMM_RATE=|^(NVCC|NVCC_FIX|SASS|GPU_CLOCK|ISOLATION|NOT_FOUND|BUILD_ERROR|BUILD_WARNING|LINKS|KERNEL|USR_LOCAL_CUDA|IN_LIBRARY_PATH)[ =:]|=skipped' \
    "$record/check.txt" | sed 's/^/check: /'
(( check_status == 0 )) && check INSTALLED_CUDA12 PASS || check INSTALLED_CUDA12 FAIL
exit 0

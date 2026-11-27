#!/usr/bin/env bash
# Add Ubuntu's GCC 11 to the running Ubuntu 26.04, as CUDA 11.4's host compiler.
#
# Usage: sudo bash add-u26-gcc11.sh
#
# Run on the Nano while it runs Ubuntu 26.04 under the 5.10 kernel.
# CUDA 11.4's nvcc (JetPack 5) supports GCC up to 10 or 11; 26.04's oldest is
# GCC 11 (gcc-11 and g++-11 11.5.0 in resolute universe), installed beside
# 26.04's own compiler packages, without recommends, from Ubuntu's signed
# archive. The plan may install and upgrade, never remove, and must leave
# systemd, glibc, the X server and the NVIDIA and CUDA 10.2 packages as they
# are, as add-u26-unity.sh requires. Changes nothing else; the record goes to
# ~/u26-gcc11/<stamp> in the owner's home. Undo: apt-get remove gcc-11 g++-11.
set -euo pipefail

KERNEL=5.10.216-tegra
PACKAGES=(g++-11)
keep='(systemd|systemd-sysv|udev|libc6|libc-bin|libpam-systemd|libnss-systemd|xserver-xorg-core|nano-l4t-[a-z0-9]+|cuda-[a-z]+-10-2|libcublas10|libcu(fft|rand|solver|sparse)-10-2|libnpp-10-2)'

die() { printf 'U26_GCC11=FAIL: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || die 'run with sudo'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
owner=${SUDO_USER:-jetson}
home=$(getent passwd "$owner" | cut -d: -f6)
[[ -d $home ]] || die "no home for $owner"

record=$home/u26-gcc11/$(date -u +%Y%m%dT%H%M%SZ)
install -d -o "$owner" -g "$owner" "$home/u26-gcc11" "$record"
exec > >(tee "$record/summary.txt") 2>&1
result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || result=FAIL; }

dpkg-query -W -f '${Package} ${Version}\n' | sort > "$record/packages-before.txt"
export DEBIAN_FRONTEND=noninteractive
apt-get update > "$record/apt-update.txt" 2>&1 || { tail -n 5 "$record/apt-update.txt"; die 'apt-get update failed'; }
apt-get -s --no-install-recommends install "${PACKAGES[@]}" > "$record/plan.txt"
if grep -E '^Remv ' "$record/plan.txt"; then die 'the plan removes packages'; fi
if grep -E "^Inst $keep " "$record/plan.txt"; then
    die 'the plan changes systemd, glibc, the X server or the NVIDIA packages'
fi
printf 'plan: %s packages to install or upgrade\n' "$(grep -c '^Inst ' "$record/plan.txt")"
grep '^Inst ' "$record/plan.txt" | cut -d' ' -f2 | tr '\n' ' '; echo
apt-get --yes --no-install-recommends -o Dpkg::Options::=--force-confold \
    install "${PACKAGES[@]}" > "$record/apt-install.txt" 2>&1 \
    || { tail -n 20 "$record/apt-install.txt"; die 'apt-get install failed'; }
grep -E '^(E|W):' "$record/apt-install.txt" || true
dpkg-query -W -f '${Package} ${Version}\n' | sort > "$record/packages-after.txt"
printf 'packages: %s before, %s after\n' "$(wc -l < "$record/packages-before.txt")" \
    "$(wc -l < "$record/packages-after.txt")"

# --- Checks.
dpkg --audit > "$record/dpkg-audit.txt" 2>&1
[[ ! -s $record/dpkg-audit.txt ]] && check DPKG_AUDIT PASS || check DPKG_AUDIT FAIL
diff <(grep -E "^$keep " "$record/packages-before.txt") <(grep -E "^$keep " "$record/packages-after.txt") \
    && check CORE_PACKAGES_UNCHANGED PASS || check CORE_PACKAGES_UNCHANGED FAIL
g++-11 --version > "$record/gxx-version.txt" 2>&1 || true
head -n 1 "$record/gxx-version.txt"
grep -q '^g++-11 .* 11\.' "$record/gxx-version.txt" && check GXX11 PASS || check GXX11 FAIL
work=$(mktemp -d)
printf '#include <cstdio>\n#include <vector>\nint main() { std::vector<int> v{1, 2, 3}; std::printf("SUM=%%d\\n", v[0] + v[1] + v[2]); }\n' \
    > "$work/hello.cc"
if g++-11 -std=c++11 -O2 -o "$work/hello" "$work/hello.cc" && [[ $("$work/hello") == SUM=6 ]]; then
    check GXX11_BUILDS PASS
else
    check GXX11_BUILDS FAIL
fi
rm -rf "$work"
apt-get clean
chown -R "$owner:$owner" "$record"
printf 'U26_GCC11=%s record=%s\n' "$result" "$record"
[[ $result == PASS ]]

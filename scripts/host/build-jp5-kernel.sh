#!/usr/bin/env bash
# Build the JetPack 5 (L4T R35.6) 5.10 kernel, modules and device trees for
# the Jetson Nano (patches/jp5/README.md), on an x86-64 Ubuntu PC.
#
#   bash scripts/host/build-jp5-kernel.sh [WORK_DIR]
#
# WORK_DIR defaults to artifacts/jp5 in this repository. Sources are fetched at
# pinned commits, patched with patches/jp5, and the result goes to
# WORK_DIR/out with SHA256SUMS. Needs about 14 GB free on a Linux filesystem
# and the GCC 13 compilers the patches were validated with:
#   sudo apt install gcc-13-aarch64-linux-gnu binutils-aarch64-linux-gnu gcc-13 \
#     make bc bison flex libssl-dev kmod git python3
# Runs as the ordinary user; touches nothing outside WORK_DIR.
set -euo pipefail

if [[ $# -gt 1 || $EUID == 0 ]]; then
    printf 'Usage (not as root): %s [WORK_DIR]\n' "$0" >&2
    exit 2
fi
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(realpath -m -- "${1:-$repo/artifacts/jp5}")
patches=$repo/patches/jp5
kernel_url=https://github.com/OE4T/linux-tegra-5.10
kernel_commit=4bce4d148ef3ff159ab55c127d8761aeaac5cc28 # oe4t-patches-l4t-35.6.0
dt_url=https://github.com/OE4T/linux-tegra-4.9
dt_commit=6944a5ce1dae5947ff24ada6b6592d9e3062d38c     # oe4t-patches-l4t-r32.7.6
release=5.10.216-tegra
cross=aarch64-linux-gnu-
cc=${cross}gcc-13
# Host tools (kconfig, dtc, sign-file) with GCC 13 too when installed.
hostcc=$(command -v gcc-13 || echo gcc)

missing=()
for tool in git make gcc "$cc" ${cross}ld bc bison flex perl python3 depmod modinfo cpp sha256sum; do
    command -v "$tool" >/dev/null || missing+=("$tool")
done
# Module signing builds sign-file against OpenSSL.
printf '#include <openssl/opensslv.h>\n' | gcc -E -x c - >/dev/null 2>&1 || missing+=(openssl/opensslv.h)
if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'Missing: %s\nSee the apt line at the top of this script.\n' "${missing[*]}" >&2
    exit 3
fi
src=$work/src/linux-tegra-5.10
dts=$work/src/linux-tegra-4.9
kbuild=$work/kbuild
out=$work/out
logs=$work/logs
mkdir -p "$work/src" "$logs"
export LC_ALL=C
case $(stat -f -c %T "$work") in
    msdos | vfat | exfat | fuseblk | ntfs*)
        printf 'WORK_DIR must be on a Linux filesystem (symlinks, case, modes)\n' >&2
        exit 3 ;;
esac
if [[ $(df -B1 --output=avail "$work" | tail -n 1) -lt 15000000000 && ! -d $work/kbuild ]]; then
    printf 'WORK_DIR needs about 14 GB free; pass a roomier directory\n' >&2
    exit 3
fi

fetch() { # URL COMMIT DIR [SPARSE_PATH...]
    local url=$1 commit=$2 dir=$3
    shift 3
    if [[ ! -d $dir/.git ]]; then
        git init -q "$dir"
        git -C "$dir" remote add origin "$url"
    fi
    if [[ $# -gt 0 ]]; then
        git -C "$dir" sparse-checkout set --no-cone "$@"
        git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$commit"
    else
        git -C "$dir" fetch -q --depth 1 origin "$commit"
    fi
    git -C "$dir" checkout -q --force --detach FETCH_HEAD
    git -C "$dir" reset -q --hard
    git -C "$dir" clean -q -fdx
    [[ $(git -C "$dir" rev-parse HEAD) == "$commit" ]]
}

printf '== Fetching sources\n'
fetch "$kernel_url" "$kernel_commit" "$src"
fetch "$dt_url" "$dt_commit" "$dts" \
    /nvidia/platform/t210/porg/ /nvidia/platform/t210/common/ /nvidia/soc/t210/ \
    /nvidia/platform/tegra/common/ /nvidia/soc/tegra/ /nvidia/include/dt-bindings/ \
    /include/dt-bindings/

printf '== Applying patches\n'
for patch in "$patches"/0*.patch; do
    git -C "$src" apply --whitespace=nowarn "$patch"
    printf 'applied %s\n' "${patch##*/}"
done
# An empty .scmversion keeps the release at exactly $release (no "+").
: > "$src/.scmversion"

# The banner (/proc/version, uname -v) names the account, computer and local
# time it was built under; a published kernel names neither and uses UTC.
export KBUILD_BUILD_USER=nano26 KBUILD_BUILD_HOST=build TZ=UTC
make_k() {
    make -C "$src" ARCH=arm64 CROSS_COMPILE="$cross" CC="$cc" HOSTCC="$hostcc" O="$kbuild" \
        KCFLAGS=-Wno-error "$@"
}
jobs=$(nproc)

printf '== Configuring\n'
make_k -s tegra_defconfig
"$src/scripts/kconfig/merge_config.sh" -m -O "$kbuild" "$kbuild/.config" \
    "$patches/kernel-config.fragment" > "$logs/merge-config.log"
make_k -s olddefconfig
grep -E '^(CONFIG_|# CONFIG_[A-Z0-9_]+ is not set$)' "$patches/kernel-config.fragment" | while IFS= read -r line; do
    grep -qxF -- "$line" "$kbuild/.config" || { printf 'Config not applied: %s\n' "$line" >&2; exit 4; }
done

# prepare runs alone first: a parallel prepare+Image raced in the R35 overlays.
printf '== Building (logs in %s)\n' "$logs"
make_k -j"$jobs" prepare > "$logs/prepare.log" 2>&1
[[ $(cat "$kbuild/include/config/kernel.release") == "$release" ]]
make_k -j"$jobs" Image > "$logs/image.log" 2>&1
make_k -j"$jobs" modules > "$logs/modules.log" 2>&1
make_k -j"$jobs" scripts_dtc > "$logs/dtc.log" 2>&1

printf '== Installing modules\n'
rm -rf "$out"
mkdir -p "$out/modules"
make_k -s INSTALL_MOD_PATH="$out/modules" INSTALL_MOD_STRIP=1 modules_install \
    > "$logs/modules-install.log" 2>&1
rm -f "$out/modules/lib/modules/$release/build" "$out/modules/lib/modules/$release/source"
for module in nvgpu nvmap r8168 r8188eu; do
    path=$(find "$out/modules/lib/modules/$release" -name "$module.ko")
    [[ -n $path ]]
done
grep -q '^kernel/drivers/gpu/nvgpu/nvgpu.ko: kernel/drivers/video/tegra/nvmap/nvmap.ko' \
    "$out/modules/lib/modules/$release/modules.dep"

printf '== Building device trees\n'
mkdir -p "$out/dtb" "$work/dt"
for variant in r35 r35-gpu-smmu; do
    name=tegra210-p3448-0000-p3449-0000-b00-$variant
    cpp -nostdinc -undef -D__DTS__ -DLINUX_VERSION=510 -x assembler-with-cpp \
        -I "$dts/nvidia/platform/t210/porg/kernel-dts" \
        -I "$dts/nvidia/platform/t210/common/kernel-dts" \
        -I "$dts/nvidia/soc/t210/kernel-dts" \
        -I "$dts/nvidia/soc/tegra/kernel-include" \
        -I "$dts/nvidia/platform/tegra/common/kernel-dts" \
        -I "$dts/include" -I "$dts/nvidia/include" -I "$patches" \
        "$patches/$name.dts" > "$work/dt/$name.pre.dts"
    "$kbuild/scripts/dtc/dtc" -I dts -O dtb -@ -o "$out/dtb/$name.dtb" \
        "$work/dt/$name.pre.dts" 2> "$logs/dtc-$variant.log"
done

printf '== Checking outputs\n'
cp "$kbuild/arch/arm64/boot/Image" "$out/Image"
cp "$kbuild/.config" "$out/config-$release"
cp "$kbuild/System.map" "$out/System.map-$release"
# arm64 Image header: magic "ARMd" at byte 56.
[[ $(dd if="$out/Image" bs=1 skip=56 count=4 status=none) == ARM$'\x64' ]]
# (grep -q on a pipe would end strings with SIGPIPE under pipefail.)
grep -qaF "Linux version $release " "$out/Image"
vermagic=$(modinfo -F vermagic "$(find "$out/modules" -name nvgpu.ko)")
[[ $vermagic == "$release SMP preempt mod_unload modversions aarch64" ]]
python3 -I - "$out/dtb" <<'PY'
import struct, sys
from pathlib import Path
for path in sorted(Path(sys.argv[1]).glob('*.dtb')):
    data = path.read_bytes()
    magic, size = struct.unpack('>II', data[:8])
    assert magic == 0xd00dfeed and size == len(data), path
    assert b'nvidia,p3449-0000-b00+p3448-0000-b00' in data, path
    print(f'{path.name}: {size} bytes')
PY
# U-Boot copies the bootloader's EMC node, with that boot's training results,
# into a device tree loaded from a file only if the node's phandle matches the
# bootloader's own device tree: 0x21 in R32.7.6's Nano B01 one.
for dtb in "$out"/dtb/*.dtb; do
    emc_phandle=$("$kbuild/scripts/dtc/dtc" -I dtb -O dts "$dtb" 2>/dev/null |
        awk '/^\texternal-memory-controller@7001b000 \{/ { p = 1 }
             p && /^\t\tphandle = / && !v { v = $3 } END { print v }')
    if [[ $emc_phandle != '<0x21>;' ]]; then
        printf '%s: EMC node phandle %s, not 0x21\n' "${dtb##*/}" "$emc_phandle" >&2
        exit 4
    fi
done
{
    printf 'release=%s\n' "$release"
    printf 'kernel=%s %s\n' "$kernel_url" "$kernel_commit"
    printf 'device_tree=%s %s\n' "$dt_url" "$dt_commit"
    printf 'patches:\n'
    (cd "$patches" && sha256sum 0*.patch *.dts kernel-config.fragment)
    printf 'compiler: %s\n' "$("$cc" --version | head -n 1)"
    printf 'host_compiler: %s\n' "$("$hostcc" --version | head -n 1)"
    printf 'linker: %s\n' "$(${cross}ld --version | head -n 1)"
    printf 'host: %s\n' "$(. /etc/os-release && echo "$PRETTY_NAME") $(uname -m)"
    printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$out/build-info.txt"
(cd "$out" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -d '\n' sha256sum > SHA256SUMS)
printf 'modules: %s files, %s\n' "$(find "$out/modules" -name '*.ko' | wc -l)" \
    "$(du -sh "$out/modules" | cut -f1)"
sha256sum "$out/Image" "$out"/dtb/*.dtb
printf 'JP5_KERNEL_BUILD=PASS out=%s\n' "$out"

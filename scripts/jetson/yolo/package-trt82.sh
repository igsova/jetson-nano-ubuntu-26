#!/usr/bin/env bash
# Build nano-trt82: JetPack 4's TensorRT 8.2 as the default TensorRT, with
# JetPack 5's TensorRT 8.5 kept beside it (the owner's choice, 2026-10-19).
#
# Usage, from an SSH login to the Nano, as your own account (no sudo):
#   bash package-trt82.sh INPUTS_DIR
# INPUTS_DIR is the folder scripts/host/fetch-r35-cuda.py --set tensorrt
# --release r32.7 wrote, the one probe-trt82.sh tested: TensorRT 8.2.1 with
# trtexec, cuDNN 8.2.1, cuBLAS 10.2, the CUDA 10.2 runtime and NVRTC, from
# JetPack 4's signed index. Nothing is installed here: the .deb, the list of
# its files with their SHA-256 and SHA256SUMS go to ~/nano-trt82-package
# (replaced only when a build passes), for install-trt82.sh.
#
# The package holds NVIDIA's files as they are:
#   /usr/lib/aarch64-linux-gnu/nano-trt82/lib: every library of the .debs,
#     and a stand-in libnvmedia.so (below);
#   /etc/ld.so.conf.d/00-nano-trt82.conf: that folder, read before Ubuntu's
#     own, so programs find TensorRT 8.2 and cuDNN 8.2 first. libnvinfer.so.8,
#     libcudnn.so.8 and the rest are also the names of JetPack 5's TensorRT
#     8.5 and cuDNN 8.6, which stay installed;
#   /usr/bin/trtexec: TensorRT 8.2's trtexec;
#   /usr/bin/nano-trt85: runs a program with TensorRT 8.5 and cuDNN 8.6
#     instead, through links in nano-trt82/trt85 to each installed library
#     whose name a library of the package shares, for example
#     nano-trt85 /usr/src/tensorrt/bin/trtexec.
# TensorRT 8.2 links JetPack 4's libnvmedia.so, which JetPack 5's driver set
# lacks, and binds its functions at load. The stand-in has a stub for each
# NvMedia function the dynamic linker cannot otherwise bind (ldd -r). Each
# returns an error (NVMEDIA_STATUS_NOT_SUPPORTED; a null handle for
# NvMedia*Create*), except NvMedia's DLA count, which TensorRT's builder
# needs: a handle and no engines, as a Nano has no DLA (probe-trt82.sh,
# 2026-10-19, where only those three were called). The DLA stubs are silent;
# any other says on stderr when it is first called, and NANO_TRT82_STUBS=1
# makes all of them say so. Every library must resolve: TensorRT's, cuDNN's,
# cuBLAS's and the CUDA runtime's in the package, the driver's (R35.6) and
# Ubuntu's from the system, and the package depends on the packages those
# come from. The last line is TRT82_PACKAGE=PASS or FAIL.
set -uo pipefail

KERNEL=5.10.216-tegra
NAME=nano-trt82
SUFFIX=+u26.2  # this project's revision, after NVIDIA's libnvinfer8 version
SYSLIB=/usr/lib/aarch64-linux-gnu
DIR=usr/lib/aarch64-linux-gnu/nano-trt82
CONF=etc/ld.so.conf.d/00-nano-trt82.conf
# The .debs taken from the inputs; their versions are checked below.
PACKAGES='libnvinfer[a-z0-9-]*|libnvonnxparsers[0-9]+|libnvparsers[0-9]+|libcudnn[0-9]+|libcublas10|cuda-[a-z0-9-]+-10-2'
REQUIRED=(libnvinfer-bin libnvinfer8 libnvinfer-plugin8 libnvonnxparsers8 libcudnn8 libcublas10 cuda-cudart-10-2)
# Libraries that must come from the package, never from the installed JetPack 5 stack.
TRT_LIBS='^lib(nvinfer|nvonnxparser|nvparsers|cudnn|cublas|cudart|nvrtc|myelin)'
# The installed packages whose libraries nano-trt85 may put first.
TRT85_PACKAGES='^(libnvinfer|libnvinfer-plugin|libnvparsers|libnvonnxparsers|libcudnn)[0-9]+$'
OUT=$HOME/nano-trt82-package

die() { printf 'TRT82_PACKAGE=FAIL: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
inputs=${1:-}
[[ $# -eq 1 ]] || die 'usage: bash package-trt82.sh INPUTS_DIR'
[[ -d $inputs ]] || die "no inputs folder $inputs"
inputs=$(cd "$inputs" && pwd)
[[ $(id -u) -ne 0 ]] || die 'run this as your own account, without sudo'
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for tool in python3 sha256sum dpkg-deb dpkg-query ldd find du; do command -v "$tool" > /dev/null || die "no $tool"; done
cc=$(command -v gcc-11 || command -v gcc || command -v cc) || die 'no C compiler (sudo apt install gcc)'
installed() { dpkg-query -W -f '${db:Status-Abbrev} ${Version}\n' "$1" 2> /dev/null | awk '$1 == "ii" { print $2 }'; }
[[ $(installed libnvinfer8) == 8.5.* ]] \
    || die "needs JetPack 5's TensorRT 8.5 installed (libnvinfer8: $(installed libnvinfer8 | grep . || echo none))"
[[ $(installed libcudnn8) == 8.6.* ]] \
    || die "needs JetPack 5's cuDNN 8.6 installed (libcudnn8: $(installed libcudnn8 | grep . || echo none))"

part=$OUT.part
rm -rf "$part" && mkdir -p "$part" || die "cannot create $part"
exec 3>&1 4>&2
exec > >(tee "$part/build.txt") 2>&1
tee_pid=$!
start=$(date +%s)
printf 'OUT=%s\nKERNEL=%s\nINPUTS=%s\nCOMPILER=%s\n' "$OUT" "$(uname -r)" "$inputs" "$("$cc" --version | head -n 1)"
printf 'INSTALLED=libnvinfer8 %s, libcudnn8 %s, %s %s\n' "$(installed libnvinfer8)" "$(installed libcudnn8)" \
    "$NAME" "$(installed "$NAME" | grep . || echo none)"

src=$part/src
root=$part/root
lib=$root/$DIR/lib
finish() {  # PASS or FAIL
    rm -rf "$src" "$root"
    printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
    if [[ $1 == PASS ]]; then
        printf 'Next: sudo bash %s/install-trt82.sh %s\n' "$here" "$OUT"
        printf 'TRT82_PACKAGE=PASS deb=%s/%s\n' "$OUT" "${deb##*/}"
    else
        printf 'TRT82_PACKAGE=FAIL record=%s/build.txt\n' "$part"
    fi
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    [[ $1 == PASS ]] || exit 1
    rm -rf "$OUT" && mv "$part" "$OUT" || die "cannot move $part to $OUT"
    exit 0
}
trap 'printf "INTERRUPTED\n"; finish FAIL' INT TERM
check() { printf '%s=%s\n' "$1" "$2"; }
fail() { check "$1" "FAIL $2"; finish FAIL; }

# --- The inputs, as the PC wrote them (as probe-trt82.sh checks them).
if (cd "$inputs" && sha256sum --quiet -c SHA256SUMS) > "$part/inputs-sha256.txt" 2>&1; then
    check INPUTS_SHA256 "PASS $(grep -c '\.deb$' "$inputs/SHA256SUMS") packages"
else
    sed 's/^/  /' "$part/inputs-sha256.txt" | head -n 8
    fail INPUTS_SHA256 "$inputs"
fi
cp "$inputs/SHA256SUMS" "$part/inputs-SHA256SUMS"
shopt -s nullglob
debs=() names=()
for deb in "$inputs"/*.deb; do
    if ! [[ $(basename "$deb") =~ ^($PACKAGES)_ ]]; then
        printf 'NOT_TAKEN=%s\n' "$(basename "$deb")"
        continue
    fi
    package=$(dpkg-deb -f "$deb" Package) version=$(dpkg-deb -f "$deb" Version)
    case $package in
        libnvinfer*|libnvonnxparsers*|libnvparsers*|libcudnn*) want='8.2.*' ;;
        *) want='10.2.*' ;;
    esac
    # shellcheck disable=SC2053  # $want is a pattern
    [[ $version == $want ]] || fail PACKAGES "$(basename "$deb") is $version, not $want"
    [[ $(dpkg-deb -f "$deb" Architecture) == arm64 ]] || fail PACKAGES "$(basename "$deb") is not arm64"
    [[ " ${names[*]} " != *" $package "* ]] || fail PACKAGES "two .debs of $package"
    names+=("$package") debs+=("$deb")
    [[ $package == libnvinfer8 ]] && nvinfer_version=$version
    printf 'DEB=%s %s\n' "$package" "$version"
done
for package in "${REQUIRED[@]}"; do
    [[ " ${names[*]} " == *" $package "* ]] || fail PACKAGES "no $package .deb in $inputs"
done
version=$nvinfer_version$SUFFIX
check PACKAGES "PASS ${#debs[@]} packages; $NAME $version"

mkdir -p "$src" "$lib" "$root/$DIR/bin" "$root/$DIR/trt85" "$root/usr/bin" "$root/etc/ld.so.conf.d" \
    "$root/usr/share/doc/$NAME" || fail UNPACK "cannot create $root"
for deb in "${debs[@]}"; do
    dpkg-deb -x "$deb" "$src" || fail UNPACK "dpkg-deb could not unpack $deb"
done
check UNPACK "PASS $(du -sm "$src" | cut -f1) MiB"

# --- The libraries, in one folder; links keep their targets' names.
while IFS= read -r path; do
    file=${path##*/}
    [[ ! -e $lib/$file && ! -L $lib/$file ]] || fail LIBRARIES "two libraries named $file in the .debs"
    if [[ -L $path ]]; then
        ln -s "$(basename "$(readlink "$path")")" "$lib/$file"
    else
        ln "$path" "$lib/$file" 2> /dev/null || cp -p "$path" "$lib/$file" || fail LIBRARIES "cannot copy $file"
    fi
done < <(find "$src" \( -type f -o -type l \) -name 'lib*.so*' ! -path '*/stubs/*' | sort)
ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
"$ldconfig" -n "$lib" 2>&1 | sed 's/^/LDCONFIG: /'
broken=$(find "$lib" -xtype l -printf '%f ')
[[ -z $broken ]] || fail LIBRARIES "links to nothing: $broken"
trtexec=$(find "$src" -type f -name trtexec | head -n 1)
[[ -n $trtexec ]] || fail LIBRARIES 'no trtexec in the packages (libnvinfer-bin)'
cp -p "$trtexec" "$root/$DIR/bin/trtexec" && chmod 0755 "$root/$DIR/bin/trtexec" || fail LIBRARIES 'cannot copy trtexec'
ln -s "../lib/aarch64-linux-gnu/$NAME/bin/trtexec" "$root/usr/bin/trtexec"
for doc in "$src"/usr/share/doc/*/copyright; do
    cp "$doc" "$root/usr/share/doc/$NAME/copyright.$(basename "$(dirname "$doc")")"
done
(cd "$src" && find . \( -type f -o -type l \) ! -name 'lib*.so*' ! -name trtexec ! -path './usr/share/doc/*' -printf '/%P\n' \
    | sort) > "$part/not-taken.txt"
printf 'NOT_TAKEN_FILES=%s %s\n' "$(grep -c . "$part/not-taken.txt")" "$(head -n 6 "$part/not-taken.txt" | xargs)"

elf_files() { printf '%s\n' "$root/$DIR/bin/trtexec"; find "$lib" -maxdepth 1 -type f -name 'lib*.so*' | sort; }
# "file lib path" for each library they link. One found in an installed
# nano-trt82 counts as not found: the new package must hold it itself.
ldd_all() {
    local file
    while IFS= read -r file; do
        LD_LIBRARY_PATH=$lib ldd "$file" 2>&1 | awk -v f="${file##*/}" -v old="/$DIR/" '
            $2 == "=>" { print f, $1, (index($3, old) == 1 ? "not" : $3) }'
    done < <(elf_files)
}
ldd_all > "$part/ldd.txt"
missing=$(awk '$3 == "not" { print $2 }' "$part/ldd.txt" | sort -u | xargs)
[[ -z $missing || $missing == libnvmedia.so ]] || fail LIBRARIES "not found: $missing (only libnvmedia.so may be missing)"

# --- The NvMedia stand-in, when the system has no libnvmedia.so.
unbound() {  # every symbol the dynamic linker cannot bind, as "symbol referencing-file"
    local file
    while IFS= read -r file; do
        LD_LIBRARY_PATH=$lib ldd -r "$file" 2>&1 | awk '
            $1 == "undefined" && $2 == "symbol:" { n = split($NF, p, "/"); sub(/\)$/, "", p[n]); print $3, p[n] }
            / version .* not defined in file / { print "VERSIONED:" $2 "@" $4, $NF }'
    done < <(elf_files) | sort -u
}
if [[ $missing == libnvmedia.so ]]; then
    "$cc" -shared -fPIC -x c /dev/null -Wl,-soname,libnvmedia.so -o "$lib/libnvmedia.so" > "$part/stand-in.txt" 2>&1 \
        || fail STAND_IN "cannot build an empty libnvmedia.so: $(head -n 2 "$part/stand-in.txt")"
    unbound > "$part/unbound.txt"
    other=$(awk '$1 !~ /^NvMedia/ { print $1 }' "$part/unbound.txt" | sort -u | head -n 8 | xargs)
    [[ -z $other ]] || fail STAND_IN "unbound symbols that are not NvMedia functions: $other"
    python3 -I - "$part/unbound.txt" "$part/nvmedia-stand-in.c" << 'EOF' || fail STAND_IN 'cannot write the stubs'
import sys
names = sorted({line.split()[0] for line in open(sys.argv[1]) if line.strip()})
out = ["/* nano-trt82's stand-in for JetPack 4's libnvmedia.so, written by package-trt82.sh:",
       ' * a stub for each NvMedia function TensorRT 8.2 binds at load. Each returns',
       ' * NVMEDIA_STATUS_NOT_SUPPORTED (6), or a null handle for NvMedia*Create*, except',
       " * the DLA count TensorRT's builder needs: one handle and no engines, as on a",
       ' * Nano, which has no DLA. Those three are silent; the others say on stderr when',
       ' * first called, and NANO_TRT82_STUBS=1 makes all of them say so. */',
       '#include <stdint.h>',
       '#include <stdio.h>',
       '#include <stdlib.h>',
       'static void called(int *once, const char *name, int quiet) {',
       '    const char *all = getenv("NANO_TRT82_STUBS");',
       '    if (!(*once)++ && (!quiet || (all && *all)))',
       '        fprintf(stderr, "nano-trt82 stand-in: %s called\\n", name);',
       '}',
       'static long dla[64];  /* the one DLA handle: accepted only by the count and Destroy */']
# No DLA: a handle, no engines (the count comes second, after the handle, or first).
dla = {'NvMediaDlaCreate': 'return (long)dla;',
       'NvMediaDlaDestroy': 'return a == dla ? 0 : 1;',
       'NvMediaDlaGetNumEngines': 'uint16_t *n = a == dla ? b : a; if (!n) return 1; *n = 0; return 0;'}
for i, name in enumerate(names):
    body = dla.get(name, f'return {0 if "Create" in name else 6};')
    out += [f'long s{i}(void *a, void *b) __asm__("{name}");',
            f'long s{i}(void *a, void *b) {{ static int once; (void)a; (void)b; '
            f'called(&once, "{name}", {int(name in dla)}); {body} }}']
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
EOF
    "$cc" -shared -fPIC -O2 -Wall -Wl,-soname,libnvmedia.so -o "$lib/libnvmedia.so" "$part/nvmedia-stand-in.c" \
        > "$part/stand-in.txt" 2>&1 || fail STAND_IN "cannot build the stubs: $(head -n 2 "$part/stand-in.txt")"
    chmod 0644 "$lib/libnvmedia.so"
    cp "$part/nvmedia-stand-in.c" "$root/usr/share/doc/$NAME/nvmedia-stand-in.c"
    stubs=$(awk '{ print $1 }' "$part/unbound.txt" | sort -u)
    check STAND_IN "PASS libnvmedia.so with $(grep -c . <<< "$stubs") stubs: $(head -n 8 <<< "$stubs" | xargs)"
fi
unbound > "$part/unbound-after.txt"
if [[ -s $part/unbound-after.txt ]]; then
    sed 's/^/  UNBOUND /' "$part/unbound-after.txt" | head -n 20
    fail LIBRARIES "$(grep -c . "$part/unbound-after.txt") symbols no library defines"
fi
ldd_all > "$part/ldd.txt"
bad=$(awk -v lib="$lib/" -v trt="$TRT_LIBS" '
    $3 == "not" { printf "UNRESOLVED %s (needed by %s)\n", $2, $1; next }
    $2 ~ trt && index($3, lib) != 1 { printf "OUTSIDE %s => %s (needed by %s)\n", $2, $3, $1 }' "$part/ldd.txt" | sort -u)
if [[ -n $bad ]]; then
    printf '%s\n' "$bad" | head -n 20
    fail LIBRARIES "$(grep -c . <<< "$bad") problems"
fi
check LIBRARIES "PASS $(find "$lib" -type f | wc -l) files and $(find "$lib" -type l | wc -l) links, all resolving"

# --- What the package depends on: the packages of the system libraries it links.
owner_of() {  # PATH: the package that holds it (dpkg may know it by another of its names)
    local path
    for path in "$1" "$(readlink -f "$1")" "/usr$1"; do
        dpkg-query -S "$path" 2> /dev/null | grep -v '^diversion ' | head -n 1 | sed 's/: .*//; s/, .*//; s/:[a-z0-9]*$//' | grep . \
            && return 0
    done
    return 1
}
depends=() unowned=()
while IFS= read -r path; do
    pkg=$(owner_of "$path") || { unowned+=("$path"); continue; }
    [[ " ${depends[*]} " == *" $pkg "* ]] || depends+=("$pkg")
done < <(awk -v lib="$lib/" '$3 ~ /^\// && index($3, lib) != 1 { print $3 }' "$part/ldd.txt" | sort -u)
(( ${#unowned[@]} == 0 )) || fail DEPENDS "no package holds ${unowned[*]}"
# CUDA's runtime opens the driver's libcuda.so.1 when it starts, without linking it.
cuda=$("$ldconfig" -p | awk '$1 == "libcuda.so.1" && /AArch64/ { print $NF; exit }')
[[ -n $cuda ]] || fail DEPENDS 'ldconfig knows no libcuda.so.1 (the R35.6 driver)'
pkg=$(owner_of "$cuda") || fail DEPENDS "no package holds $cuda"
[[ " ${depends[*]} " == *" $pkg "* ]] || depends+=("$pkg")
mapfile -t depends < <(printf '%s\n' "${depends[@]}" | sort)
fields=()
for pkg in "${depends[@]}"; do
    if [[ $pkg == nano-l4t-* ]]; then fields+=("$pkg (>= $(installed "$pkg"))"); else fields+=("$pkg"); fi
done
depends_line=$(IFS=,; echo "${fields[*]}" | sed 's/,/, /g')
check DEPENDS "PASS $depends_line"

# --- nano-trt85's links: each installed library whose name one of the package's shares.
trt85=$root/$DIR/trt85
owners=()
for path in "$lib"/*; do
    file=${path##*/}
    [[ -e $SYSLIB/$file ]] || continue
    pkg=$(owner_of "$SYSLIB/$file") || fail TRT85 "no package holds $SYSLIB/$file"
    [[ $pkg =~ $TRT85_PACKAGES ]] || fail TRT85 "$SYSLIB/$file is $pkg's, not TensorRT's or cuDNN's"
    ln -s "$SYSLIB/$file" "$trt85/$file"
    [[ " ${owners[*]} " == *" $pkg "* ]] || owners+=("$pkg")
done
for need in libnvinfer.so.8 libcudnn.so.8; do
    [[ -L $trt85/$need ]] || fail TRT85 "no $SYSLIB/$need for nano-trt85"
done
# TensorRT 8.5's trtexec and libraries through those links find none of 8.2's.
mixed=$(for file in /usr/src/tensorrt/bin/trtexec "$trt85"/*; do
            [[ -e $file ]] || continue
            LD_LIBRARY_PATH=$trt85 ldd "$(readlink -f "$file")" 2>&1 | awk -v f="${file##*/}" -v new="$lib/" -v old="/$DIR/lib/" '
                $2 == "=>" && (index($3, new) == 1 || index($3, old) == 1 || $3 == "not") { print f ": " $1 " => " $3 }'
        done | sort -u)
[[ -z $mixed ]] || { printf '  %s\n' "$mixed" | head -n 10; fail TRT85 'TensorRT 8.5 would load libraries of 8.2'; }
check TRT85 "PASS $(find "$trt85" -type l | wc -l) links to $(for p in "${owners[@]}"; do printf '%s %s, ' "$p" "$(installed "$p")"; done | sed 's/, $//')"

cat > "$root/$CONF" << EOF
# nano-trt82: JetPack 4's TensorRT 8.2 and cuDNN 8.2, found before JetPack 5's
# TensorRT 8.5 and cuDNN 8.6 of the same names. nano-trt85 runs a program with those.
/$DIR/lib
EOF
cat > "$root/usr/bin/nano-trt85" << EOF
#!/bin/sh
# Run a program with JetPack 5's TensorRT 8.5 and cuDNN 8.6 (NVIDIA's libnvinfer8
# and libcudnn8 packages, for CUDA 11.4) instead of the default, nano-trt82's
# TensorRT 8.2 and cuDNN 8.2. The links in $DIR/trt85
# point at each of their libraries whose name nano-trt82 also has. For example:
#   nano-trt85 /usr/src/tensorrt/bin/trtexec --onnx=model.onnx --fp16
dir=/$DIR/trt85
if [ \$# -eq 0 ]; then
    echo 'usage: nano-trt85 PROGRAM [ARGUMENT...]' >&2
    exit 2
fi
for link in "\$dir"/*; do
    if [ ! -e "\$link" ]; then
        echo "nano-trt85: \${link##*/} is missing: is TensorRT 8.5 (libnvinfer8 8.5) installed?" >&2
        exit 1
    fi
done
LD_LIBRARY_PATH=\$dir\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export LD_LIBRARY_PATH
exec "\$@"
EOF
chmod 0755 "$root/usr/bin/nano-trt85"
chmod 0644 "$root/$CONF"
cat > "$root/usr/share/doc/$NAME/copyright" << EOF
nano-trt82 holds files from NVIDIA's packages for JetPack 4.6 (L4T r32.7,
repo.download.nvidia.com/jetson/common), unchanged, under NVIDIA's licenses
(copyright.<package> here, where the package had one):
$(printf '  %s\n' "${names[@]}" | sort)
libnvmedia.so is a stand-in built by this project's
scripts/jetson/yolo/package-trt82.sh from nvmedia-stand-in.c here.
EOF

# --- The .deb.
mkdir -m 0755 "$root/DEBIAN"
size=$(du -sk --exclude=DEBIAN "$root" | cut -f1)
cat > "$root/DEBIAN/control" << EOF
Package: $NAME
Version: $version
Architecture: arm64
Maintainer: jetson-ubuntu-26 <noreply@localhost>
Installed-Size: $size
Depends: $depends_line
Section: non-free/libs
Priority: optional
Description: NVIDIA TensorRT 8.2 for Jetson Nano as the default, TensorRT 8.5 beside it
 JetPack 4's TensorRT 8.2.1, cuDNN 8.2.1, cuBLAS 10.2 and CUDA 10.2 runtime
 from NVIDIA's L4T r32.7 packages, in /$DIR/lib,
 found before the installed TensorRT 8.5 and cuDNN 8.6 of the same names.
 trtexec is TensorRT 8.2's; nano-trt85 runs a program with TensorRT 8.5 and
 cuDNN 8.6 instead. A stand-in libnvmedia.so answers TensorRT's NvMedia calls
 (no DLA). None of NVIDIA's maintainer scripts is included.
EOF
printf '/%s\n' "$CONF" > "$root/DEBIAN/conffiles"
printf '#!/bin/sh\nset -e\nif [ "$1" = configure ]; then\n\tldconfig\nfi\n' > "$root/DEBIAN/postinst"
printf '#!/bin/sh\nset -e\nif [ "$1" = remove ] || [ "$1" = purge ]; then\n\tldconfig\nfi\n' > "$root/DEBIAN/postrm"
chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"
chmod 0644 "$root/DEBIAN/control" "$root/DEBIAN/conffiles"
find "$root" -type d -exec chmod 0755 {} +
(cd "$root" && find . -path ./DEBIAN -prune -o \( -type f -o -type l \) -printf '%P\n' | sort | while IFS= read -r rel; do
    if [[ -L $rel ]]; then
        printf '%-64s  /%s -> %s\n' symlink "$rel" "$(readlink "$rel")"
    else
        printf '%s  /%s\n' "$(sha256sum < "$rel" | cut -d ' ' -f 1)" "$rel"
    fi
done) > "$part/$NAME-files.txt"
compress=-Zxz
dpkg-deb --help 2>&1 | grep -q zstd && compress=-Zzstd
deb=$part/${NAME}_${version#*:}_arm64.deb
dpkg-deb --root-owner-group "$compress" --build "$root" "$deb" > "$part/dpkg-deb.txt" 2>&1 \
    || fail DEB "dpkg-deb: $(tail -n 3 "$part/dpkg-deb.txt" | xargs)"
[[ $(dpkg-deb -f "$deb" Package Version | awk '{ print $2 }' | xargs) == "$NAME $version" ]] || fail DEB 'its fields'
(cd "$part" && sha256sum "${deb##*/}" "$NAME-files.txt") > "$part/SHA256SUMS"
check DEB "PASS ${deb##*/}, $(( $(stat -c %s "$deb") >> 20 )) MiB, $(grep -c . "$part/$NAME-files.txt") files and links"
finish PASS

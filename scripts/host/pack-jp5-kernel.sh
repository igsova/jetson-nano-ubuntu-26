#!/usr/bin/env bash
# Pack build-jp5-kernel.sh's out/ folder into the one file nano26-convert
# downloads (docs/CONVERTER.md, "The kernel as a download"), on the PC.
#
#   bash scripts/host/pack-jp5-kernel.sh OUT_DIR DEST_DIR
#
# Checks every file in OUT_DIR against its SHA256SUMS (and that nothing else
# is there), reads the release and build number from the Image, and writes
# DEST_DIR/nano26-kernel-RELEASE-bBUILD.tar.xz, with the folder's files under
# nano26-kernel/, and its SHA-256 beside it. The archive holds the same bytes
# however often it is packed: names sorted, owners and times fixed, xz on one
# thread. build-info.txt inside it names the sources (OE4T's commits and the
# patches' SHA-256), as the GPL asks of a published kernel. Prints the
# Image's banner, which names an account and a computer: build-jp5-kernel.sh
# sets them to nano26@build, and this shows what is about to be published.
# Writes nothing else and needs no root. The last line is KERNEL_BUNDLE=PASS
# or an error.
set -euo pipefail
umask 022

die() { printf 'KERNEL_BUNDLE=FAIL %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || { printf 'Usage: %s OUT_DIR DEST_DIR\n' "$0" >&2; exit 2; }
out=$(realpath -e -- "$1") || die "no folder $1"
dest=$(realpath -e -- "$2") || die "no folder $2"
[[ -d $out && -d $dest ]] || die 'OUT_DIR and DEST_DIR must be folders'
for tool in tar xz sha256sum find sort grep; do command -v "$tool" > /dev/null || die "no $tool"; done
export LC_ALL=C

# Every file listed, every listed file there and unchanged.
[[ -f $out/SHA256SUMS ]] || die "$out has no SHA256SUMS (is it build-jp5-kernel.sh's out/?)"
listed=$(sed 's/^[0-9a-f]\{64\}  //' "$out/SHA256SUMS" | sort)
present=$(cd "$out" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort)
[[ $listed == "$present" ]] || die "the files in $out and its SHA256SUMS differ"
(cd "$out" && sha256sum --quiet --strict -c SHA256SUMS) || die "a file in $out does not match SHA256SUMS"
[[ -z $(find "$out" ! -type f ! -type d -print -quit) ]] || die "$out holds something other than files and folders"

release=$(sed -n 's/^release=//p' "$out/build-info.txt" 2> /dev/null)
[[ -n $release ]] || die "$out/build-info.txt names no release"
[[ $(head -c 64 "$out/Image" | tail -c 8 | head -c 4) == ARM$'\x64' ]] || die 'Image is not an arm64 kernel'
# The banner: "Linux version RELEASE (user@host) (compiler, linker) #BUILD ...".
version=$(grep -aom1 "Linux version ${release//./\\.} [^#]*#[0-9]*" "$out/Image") \
    || die "Image is not $release"
build=${version##*#}
[[ -n $(find "$out/modules/lib/modules/$release" -name nvgpu.ko -print -quit 2> /dev/null) ]] \
    || die "no nvgpu module for $release"
[[ -n $(find "$out/dtb" -name '*.dtb' -print -quit 2> /dev/null) ]] || die 'no device trees'

name=nano26-kernel-$release-b$build.tar.xz
[[ ! -e $dest/$name ]] || die "$dest/$name already exists"
# The build's own time for every entry, so packing again gives the same file.
stamp=$(sed -n 's/^built_utc=//p' "$out/build-info.txt")
[[ -n $stamp ]] || die "$out/build-info.txt has no built_utc"
tar --create --directory="$out" --sort=name --format=gnu --owner=0 --group=0 --numeric-owner \
    --mode='u+rw,go+r,go-w' --mtime="$stamp" --transform='s,^\.,nano26-kernel,' . \
    | xz -9 --threads=1 > "$dest/$name.part"
mv "$dest/$name.part" "$dest/$name"
(cd "$dest" && sha256sum -- "$name" > "$name.sha256")
digest=$(cut -d' ' -f1 "$dest/$name.sha256")
printf 'files: %s, packed %s\n' "$(wc -l < "$out/SHA256SUMS")" "$(du -h "$dest/$name" | cut -f1)"
printf 'Image: %s, build #%s, SHA-256 %s\n' "$release" "$build" "$(sha256sum "$out/Image" | cut -d' ' -f1)"
# Published with the kernel: the account and computer name in its banner.
printf 'banner: %s\n' "$version"
printf 'KERNEL_BUNDLE=PASS file=%s sha256=%s\n' "$dest/$name" "$digest"

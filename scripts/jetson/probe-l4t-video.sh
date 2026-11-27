#!/usr/bin/env bash
# Try JetPack 5's or JetPack 4's video converter (nvvidconv) on the Nano from a
# scratch folder, or as nano-l4t-r32-video or nano-l4t-r35-video installed it,
# through VIC and through CUDA.
#
# Usage: bash probe-l4t-video.sh INPUTS_DIR
#        bash probe-l4t-video.sh --installed [r32|r35]
#
# Run as the owner's ordinary account, without sudo, on Ubuntu 26.04
# under the 5.10 kernel, with the nano-l4t packages (L4T R35.6's driver set)
# installed and Ubuntu's GStreamer tools and base plugins:
#   sudo apt install --no-install-recommends gstreamer1.0-tools gstreamer1.0-plugins-base
# INPUTS_DIR is the folder scripts/host/fetch-r35-cuda.py --set video wrote,
# with this script, frame_check.py and colour_fit.py (tests/video) and
# SHA256SUMS:
# - JetPack 5 (L4T R35.6, the default): nvidia-l4t-gstreamer, -multimedia and
#   -multimedia-utils and any platform package they needed. Their NVIDIA
#   libraries may also come from the installed driver set.
# - JetPack 4 (L4T R32.7.6, --release r32.7): the same three, nvidia-l4t-core
#   and any package they needed (CUDA 10.2's runtime among them). The two
#   releases' libraries share names, so every NVIDIA library the converter
#   loads must come from the scratch folder, never the installed R35.6 set.
# The release is read from the nvidia-l4t-gstreamer .deb. The .debs are only
# unpacked, with dpkg-deb -x, into ~/l4t-video-probe/<stamp>/root; nothing is
# installed and no system file is changed. A library there that Ubuntu also
# provides is set aside, so Ubuntu's stays in charge. GStreamer keeps its
# plugin list in a registry file in the record folder, so the system's is
# untouched. The unpacked files and test frames are removed at the end unless
# KEEP_ROOT=1.
#
# With --installed (or --installed r32) it tests nano-l4t-r32-video instead
# (built by scripts/host/build-nano-l4t-debs.py --set video): the same steps,
# with every run started through its launcher, /usr/bin/nano-r32-video, and
# every NVIDIA library the converter loads coming from the package's folder.
# With --installed r35 it tests nano-l4t-r35-video (--set video --release r35)
# the same way, through /usr/bin/nano-r35-video, which applies the VIC fix
# (VIC_PATCH=fix, with the package's vic_patch.so) to every run: the NVIDIA
# libraries come from the package's folder or the installed driver set, a
# VIC_PATCH_RUNS line counts the jobs the fix patched, and step 9 runs. It
# also needs vic_cuda.py (tests/video) next to this script, and VIC_PATCH_RUNS
# may not be given. Nothing is unpacked; the script, frame_check.py and
# colour_fit.py still need their SHA256SUMS lines next to them.
#
# KEEP_FRAMES=1 keeps each compared pair of frames (and the colour tests'
# input frames) in the record's kept-frames folder, about 500 MB a path.
# INTERPOLATION_SWEEP adds step 6: "all", or interpolation-method values
# separated by spaces (as the INTERPOLATION_METHODS line lists them).
# VIC_RECORD=1 adds step 7. It needs vic_record.c and vic_jobs.py
# (tests/video) next to this script, with their SHA256SUMS lines, and a C
# compiler (gcc-11 from add-u26-gcc11.sh). VIC_PATCH adds step 8 and needs
# the same: "each", or groups of VIC's settings separated by spaces (gamma
# matrix blend alpha chromaloc control roundtrip all fix, as vic_record.c
# describes them); with --installed r35 its runs use the probe's own build of
# vic_record.c in place of the package's. VIC_PATCH_RUNS (groups, such as
# fix) runs every converter run of steps 3 to 6 under vic_record.c with those
# groups set to JetPack 4's values in every VIC job, and needs the same
# files; the last line then ends in vic_patch=GROUPS, and a VIC_PATCH_RUNS
# line counts the jobs patched.
#
# Steps, each logged in the record folder:
#   1. libraries: everything the nvvidconv plugin links resolves, the NVIDIA
#      libraries from the scratch folder (or, for JetPack 5, the installed
#      driver set); the other NVIDIA plugins' unresolved libraries are listed
#      (not required);
#   2. inspect: GStreamer loads nvvidconv (gst-inspect-1.0);
#   then, on the VIC path (nvvidconv's default) and on the CUDA path
#   (compute-hw=GPU) in turn, after a two-frame colour conversion within
#   SMOKE_SECONDS (a hung VIC job shows there, and the path's other runs are
#   skipped; a run that finishes with a wrong picture fails the path but
#   the other runs still go):
#   3. roundtrip: 30 frames of a moving 1920x1080 I420 test pattern into NV12
#      in NVMM buffers and back to I420, which must match the pattern
#      (frame_check.py, at least 40 dB per plane);
#   4. colour: 1280x720 I420 (BT.601) to RGBA in NVMM buffers and back, against
#      GStreamer's own videoconvert (at least 30 dB per channel). If that
#      fails, colour_fit.py reports which software conversion of the first
#      input frame the output fits best (chroma moved or interpolated,
#      another matrix or range), and the check still passes if every
#      compared frame reaches 40 dB per channel against limited-range BT.601
#      with nearest chroma moved CHROMA_MOVE pixels across. VIC takes the
#      chroma of the pixel to the right on odd pixels, where videoconvert
#      takes the left one; VIC's output fits that model at 53 dB and
#      videoconvert's at 26 (2026-10-17, build #35);
#   5. scale: 1280x720 to 640x360 I420 with bilinear filtering, against
#      videoscale's bilinear (at least 20 dB per plane: filters differ at the
#      pattern's fine stripes; a wrong size, layout or plane order scores
#      under 12);
#   6. only with INTERPOLATION_SWEEP, and only if the VIC path's runs finish:
#      the VIC path's colour (10 frames) and scale tests again with
#      interpolation-method set to each value given, each run limited to
#      SMOKE_SECONDS, for the record (not counted, frames not kept). A
#      SWEEP_COLOUR and a SWEEP_SCALE line for each value give the planes'
#      PSNR and, for colour, colour_fit.py's VIC check, best fit and big
#      errors; the full output is in the record's sweep-*.txt files;
#   7. only with VIC_RECORD=1, and only if the VIC path's runs finish: the
#      jobs nvvidconv hands VIC in three two-frame conversions, before any
#      fix, recorded by vic_record.c (built here; it only reads) in the record's
#      vic-jobs/<case> folders: colour (step 4's conversion), and
#      scale-m0 and scale-m1 (step 5's, with interpolation-method 0 and 1
#      when nvvidconv lists them; otherwise one scale case without it). A
#      VIC_RECORD line a case gives the jobs recorded, and vic_jobs.py
#      compare reads two converters' folders side by side;
#   8. only with VIC_PATCH, and only if the VIC path's runs finish: the VIC
#      path's colour (10 frames) and scale tests (step 5's, 30 frames) again
#      under vic_record.c, first with no group (it only records) and then
#      with each group given, which it sets to JetPack 4's values in every
#      job before the job goes to VIC (only the jobs change, no file; a run
#      that a changed job hangs ends after SMOKE_SECONDS). A PATCH_COLOUR
#      and a PATCH_SCALE line a group give what the sweep's lines give and
#      the shim's count of the jobs it patched; each run's first jobs, as
#      VIC got them, are in the record's vic-patch/<group>-<test> folders;
#   9. only with --installed r35, and only if the VIC path's smoke run
#      finishes: one program (vic_cuda.py, run through the launcher) converts
#      30 frames on VIC with the fix and checks each on the GPU with CUDA 11.4
#      in the same process (VIC_CUDA, counted); its NVIDIA libraries are
#      checked by step 1's rule. The same with VIC_PATCH= (no fix), 10
#      frames, for the record (VIC_CUDA_UNFIXED, not counted);
#  10. for the record: the chip the kernel reports, VIC's firmware file,
#      VIC's runtime power counter before and after, the video decoder's
#      device node (NVDEC is off in the 5.10 device tree), and the kernel's
#      messages since the start when the account may read them.
# Each conversion run records the libraries it loaded (LD_DEBUG=libs) and
# checks every NVIDIA one against the rule in step 1. The last line is
# L4T_VIDEO_PROBE=PASS or FAIL with the release and each path's result; it
# passes when steps 1 and 2 pass, either path passes 3 to 5, and step 9
# passes where it runs.
# NVVIDCONV_PROPERTIES lists nvvidconv's properties and INTERPOLATION_METHODS
# its interpolation-method values, with the default.
set -uo pipefail

KERNEL=5.10.216-tegra
PACKAGES='nvidia-l4t-[a-z0-9-]+|cuda-[a-z0-9-]+-10-2'
NV_LIBS='^lib(nv|cuda|cudart|tegrav4l2|v4l2_nv|gstnv)'
LIB=/usr/lib/aarch64-linux-gnu
RUN_SECONDS=180
SMOKE_SECONDS=45
CHROMA_MOVE=1  # VIC's nearest chroma on odd pixels comes from the right (step 4)
GST_TOOLS='sudo apt install --no-install-recommends gstreamer1.0-tools gstreamer1.0-plugins-base'
VIDEO_PACKAGE=nano-l4t-r32-video  # JetPack 4's converter, installed (--installed r32)
LAUNCHER=/usr/bin/nano-r32-video

root='' frames=''
cleanup() {
    [[ -n $root && -d $root ]] || return 0
    if [[ ${KEEP_ROOT:-0} == 1 ]]; then
        printf 'ROOT_KEPT=%s\n' "$root"
    else
        rm -rf "${root:?}" "${frames:?}" && printf 'ROOT_REMOVED=%s\n' "$root"
    fi
}
die() { cleanup; trap - EXIT; printf 'L4T_VIDEO_PROBE=FAIL: %s\n' "$*" >&2; exit 1; }
# The installed driver set (nano-l4t, L4T R35.6) and CUDA 11.4's runtime: in
# their folders, or a file one of their packages owns (libnvcucompat.so).
# JetPack 4's converter may use none of them.
release=''
installed_nv() {
    [[ $release == r35 ]] || return 1
    case $1 in
        $LIB/tegra/*|$LIB/tegra-egl/*|/usr/local/cuda-11.4/*) return 0 ;;
    esac
    dpkg-query -S "$1" "$(readlink -f "$1")" 2> /dev/null \
        | grep -qE '^(nano-l4t-[a-z0-9-]+|cuda-[a-z0-9-]+-11-4)(:[a-z0-9]+)?: '
}

here=$(cd "$(dirname "$0")" && pwd)
installed=0
if [[ ${1:-} == --installed ]]; then
    installed=1 release=${2:-r32}
    (( $# <= 2 )) && [[ $release == r3[25] ]] \
        || die 'give either the video inputs folder or --installed, with r32 (the default) or r35'
    if [[ $release == r35 ]]; then
        VIDEO_PACKAGE=nano-l4t-r35-video LAUNCHER=/usr/bin/nano-r35-video  # JetPack 5's, with the VIC fix
    fi
    PACKAGE_DIR=$LIB/$VIDEO_PACKAGE
else
    (( $# == 1 )) || die 'give the video inputs folder (for example ~/r32-video-inputs), or --installed'
    [[ -d $1 ]] || die "no inputs folder $1"
    inputs=$(cd "$1" && pwd)
fi
[[ $(id -u) -ne 0 ]] || die 'run this as the ordinary account, not with sudo'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
driver=$(dpkg-query -W -f '${Version}' nano-l4t-core 2> /dev/null)
[[ $driver == 35.6.* ]] || die "needs the nano-l4t R35.6 driver set (nano-l4t-core is ${driver:-not installed})"
if (( installed )); then
    read -r state l4t < <(dpkg-query -W -f '${db:Status-Status} ${Version}\n' "$VIDEO_PACKAGE" 2> /dev/null)
    want=32.7.6-
    [[ $release == r35 ]] && want=35.6.5-
    [[ ${state:-} == installed && ${l4t:-} == "$want"* ]] \
        || die "needs $VIDEO_PACKAGE installed (it is ${state:-not installed}${l4t:+ $l4t})"
    [[ -x $LAUNCHER ]] || die "no $LAUNCHER (it comes with $VIDEO_PACKAGE)"
fi
for tool in gst-launch-1.0 gst-inspect-1.0; do
    command -v "$tool" > /dev/null || die "no $tool; install Ubuntu's GStreamer tools first: $GST_TOOLS"
done
for tool in python3 dpkg-deb timeout; do
    command -v "$tool" > /dev/null || die "no $tool"
done
own=(probe-l4t-video.sh frame_check.py colour_fit.py)
fixed=0  # nano-r35-video applies the VIC fix to every run
(( installed )) && [[ $release == r35 ]] && fixed=1 && own+=(vic_cuda.py)
(( fixed )) && [[ -n ${VIC_PATCH_RUNS:-} ]] \
    && die "VIC_PATCH_RUNS is not for --installed r35: $LAUNCHER applies the fix to every run"
cc=''
if [[ ${VIC_RECORD:-0} == 1 || -n ${VIC_PATCH:-} || -n ${VIC_PATCH_RUNS:-} ]]; then
    own+=(vic_record.c vic_jobs.py)
    cc=$(command -v gcc-11 || command -v gcc || command -v cc) \
        || die 'VIC_RECORD=1 and VIC_PATCH need a C compiler (gcc-11 from add-u26-gcc11.sh)'
fi
all_groups='gamma matrix blend alpha chromaloc control roundtrip all fix'
groups_of() {  # SETTING VALUE: VALUE's groups, one a line
    local group
    for group in $2; do
        [[ " $all_groups " == *" $group "* ]] || die "$1: no group $group (give some of: $all_groups)"
        printf '%s\n' "$group"
    done
}
patch_groups=() run_groups=()
if [[ ${VIC_PATCH:-} == each ]]; then
    read -ra patch_groups <<< "$all_groups"
elif [[ -n ${VIC_PATCH:-} ]]; then
    groups_of VIC_PATCH "$VIC_PATCH" > /dev/null  # dies here, not in the substitution below
    mapfile -t patch_groups < <(groups_of VIC_PATCH "$VIC_PATCH")
fi
if [[ -n ${VIC_PATCH_RUNS:-} ]]; then
    groups_of VIC_PATCH_RUNS "$VIC_PATCH_RUNS" > /dev/null
    mapfile -t run_groups < <(groups_of VIC_PATCH_RUNS "$VIC_PATCH_RUNS")
fi
for file in "${own[@]:1}"; do
    [[ -f $here/$file ]] || die "no $file next to this script"
done
listed="  ($(IFS='|'; echo "${own[*]//./\\.}"))\$"
(cd "$here" && grep -E "$listed" SHA256SUMS | sha256sum --quiet -c - \
    && [[ $(grep -cE "$listed" SHA256SUMS) == "${#own[@]}" ]]) > /dev/null 2>&1 \
    || die "this script or ${own[*]:1} do not match the SHA256SUMS next to it"
nodes=()
for node in /dev/nvmap /dev/nvhost-ctrl /dev/nvhost-vic; do
    [[ -r $node && -w $node ]] || nodes+=("$node")  # bash's test; 26.04's uutils test misreads groups
done
(( ${#nodes[@]} == 0 )) || die "this account cannot open ${nodes[*]} (the video group should have them)"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=$HOME/l4t-video-probe/$stamp
mkdir -p "$HOME/l4t-video-probe" && mkdir "$record" || die "cannot create $record"
root=$record/root frames=$record/frames
mkdir "$root" "$frames" || die "cannot create $root"
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
exec > >(tee "$record/summary.txt") 2>&1
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\nDRIVER_SET=nano-l4t-core %s\n' \
    "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME" "$driver"
printf 'GSTREAMER=%s\n' "$(gst-launch-1.0 --version | sed -n 's/^GStreamer //p' | head -n 1)"

result=PASS vic_path=- gpu_path=- vic_cuda=''
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS ]] || result=FAIL; }
finish() {
    cleanup; trap - EXIT
    printf 'L4T_VIDEO_PROBE=%s release=%s vic=%s gpu=%s source=%s record=%s%s%s\n' "$result" "${release:--}" \
        "$vic_path" "$gpu_path" "$( (( installed )) && echo installed || echo scratch)" "$record" \
        "$( (( ${#run_groups[@]} )) && printf ' vic_patch=%s' "$(IFS=+; echo "${run_groups[*]}")")" \
        "${vic_cuda:+ vic_cuda=$vic_cuda}"
    [[ $result == PASS ]] && exit 0
    exit 1
}

# --- What to test: the packages as the PC wrote them, unpacked into the
# scratch folder, or with --installed nano-l4t-r32-video or -r35-video as installed.
shopt -s nullglob
need=600  # MiB of test frames at most, besides the unpacked packages
[[ ${KEEP_FRAMES:-0} == 1 ]] && need=1500  # and the kept frames of both paths
space() {
    free=$(python3 -I -c 'import os, sys; s = os.statvfs(sys.argv[1]); print(s.f_bavail * s.f_frsize >> 20)' "$record")
    printf 'SPACE=%s MiB free, %s MiB needed\n' "$free" "$need"
    (( free >= need )) || die "not enough space in $HOME: $free MiB free, $need MiB needed"
}
if (( installed )); then
    printf 'PACKAGE=%s %s (installed, run through %s)\n' "$VIDEO_PACKAGE" "$l4t" "$LAUNCHER"
    printf 'RELEASE=%s (L4T %s)\n' "$release" "${l4t%+*}"
    space
    lib_root=$PACKAGE_DIR plugins=$PACKAGE_DIR/gstreamer-1.0 dirs=("$PACKAGE_DIR/lib")
    [[ -f $plugins/libgstnvvidconv.so ]] || die "no $plugins/libgstnvvidconv.so"
    libdirs=${dirs[0]}
    printf 'LIBDIR=%s\nPLUGIN_DIR=%s\n' "$libdirs" "$plugins"
    # The launcher sets the library and plugin paths (and for JetPack 5 the
    # VIC fix), as for any program run with it; the caller's VIC_PATCH is not passed on.
    linker=(env -u VIC_PATCH "$LAUNCHER")
    gst=(env -u DISPLAY -u WAYLAND_DISPLAY -u VIC_PATCH GST_REGISTRY="$record/registry.bin" GST_DEBUG_NO_COLOR=1
         "$LAUNCHER" env)
    if (( fixed )); then
        [[ -f $PACKAGE_DIR/vic_patch.so ]] || die "no $PACKAGE_DIR/vic_patch.so"
        launched=$("${linker[@]}" printenv VIC_PATCH)
        printf 'LAUNCHER_FIX VIC_PATCH=%s LD_PRELOAD=%s\n' "${launched:-(none)}" \
            "$("${linker[@]}" printenv LD_PRELOAD)"
        read -ra run_groups <<< "$launched"
    fi
else
    if (cd "$inputs" && sha256sum --quiet -c SHA256SUMS) > "$record/sha256-check.txt" 2>&1; then
        printf 'INPUTS_SHA256=PASS %s\n' "$inputs"
    else
        cat "$record/sha256-check.txt"
        printf 'INPUTS_SHA256=FAIL %s\n' "$inputs"
        result=FAIL; finish
    fi
    cp "$inputs/SHA256SUMS" "$record/SHA256SUMS-inputs"
    converter=("$inputs"/nvidia-l4t-gstreamer_*.deb)
    (( ${#converter[@]} == 1 )) || die "no nvidia-l4t-gstreamer .deb in the inputs, or more than one"
    l4t=$(dpkg-deb -f "${converter[0]}" Version)
    case $l4t in
        35.6.*) release=r35 required=() ;;
        32.7.6-*) release=r32 required=(nvidia-l4t-core) ;;
        *) die "nvidia-l4t-gstreamer is $l4t, neither JetPack 5's 35.6 nor JetPack 4's 32.7.6" ;;
    esac
    printf 'RELEASE=%s (L4T %s)\n' "$release" "$l4t"
    debs=() names=()
    for deb in "$inputs"/*.deb; do
        [[ $(basename "$deb") =~ ^($PACKAGES)_ ]] || continue
        package=$(dpkg-deb -f "$deb" Package) version=$(dpkg-deb -f "$deb" Version)
        if [[ $package == cuda-* ]]; then
            [[ $release == r32 && $version == 10.2.* ]] || die "$(basename "$deb") does not belong to $release's set"
        else
            [[ $version == "$l4t" ]] || die "$(basename "$deb") is $version, not $l4t"
        fi
        names+=("$package") debs+=("$deb")
    done
    for package in nvidia-l4t-gstreamer nvidia-l4t-multimedia nvidia-l4t-multimedia-utils "${required[@]}"; do
        [[ " ${names[*]} " == *" $package "* ]] || die "no $package .deb in the inputs"
    done
    for deb in "${debs[@]}"; do
        size=$(dpkg-deb -f "$deb" Installed-Size)
        need=$(( need + ${size:-0} / 1024 + 1 ))
    done
    space
    for deb in "${debs[@]}"; do
        printf 'UNPACK=%s\n' "$(basename "$deb")"
        dpkg-deb -x "$deb" "$root" || die "dpkg-deb could not unpack $deb"
    done
    plugins=$root$LIB/gstreamer-1.0
    [[ -f $plugins/libgstnvvidconv.so ]] || die "no ${plugins#"$root"}/libgstnvvidconv.so in the packages"
    libdirs_of() {
        find "$root" \( -type f -o -type l \) -name 'lib*.so*' ! -path "$plugins/*" -printf '%h\n' | sort -u
    }
    ldconfig=$(command -v ldconfig || echo /usr/sbin/ldconfig)
    mapfile -t dirs < <(libdirs_of)
    (( ${#dirs[@]} )) || die 'no libraries in the packages'
    "$ldconfig" -n "${dirs[@]}" 2>&1 | sed 's/^/LDCONFIG: /'
    # Ubuntu's own libraries stay Ubuntu's: set aside any name the packages also
    # carry (after ldconfig, so that no link to them is made again).
    "$ldconfig" -p | awk -v lib="$LIB/tegra" '/ => / && index($NF, lib) != 1 {print $1}' | sort -u > "$record/system-libs.txt"
    while IFS= read -r file; do
        name=$(basename "$file")
        if grep -qxF "$name" "$record/system-libs.txt"; then
            mkdir -p "$record/set-aside"
            mv "$file" "$record/set-aside/$(tr / _ <<< "${file#"$root"/}")" && printf 'SET_ASIDE=%s (Ubuntu has its own)\n' "${file#"$root"}"
        fi
    done < <(find "$root" \( -type f -o -type l \) -name 'lib*.so*' ! -path "$plugins/*" | sort)
    mapfile -t dirs < <(libdirs_of)
    (( ${#dirs[@]} )) || die 'no libraries left in the packages after setting aside Ubuntu'"'"'s'
    libdirs=$(IFS=:; echo "${dirs[*]}")
    printf 'LIBDIR=%s\n' "${dirs[@]#"$root"}"
    printf 'PLUGIN_DIR=%s\n' "${plugins#"$root"}"
    lib_root=$root linker=(env LD_LIBRARY_PATH="$libdirs")
    gst=(env -u DISPLAY -u WAYLAND_DISPLAY LD_LIBRARY_PATH="$libdirs" GST_PLUGIN_PATH="$plugins"
         GST_REGISTRY="$record/registry.bin" GST_DEBUG_NO_COLOR=1)
fi
ls -l "${dirs[@]}" "$plugins" > "$record/libraries.txt"

# --- 1. Libraries: what the dynamic linker finds for each NVIDIA plugin.
ldd_check() {  # FILE: prints problems, returns 1 if any
    local file=$1 bad=0 lib path
    "${linker[@]}" ldd "$file" > "$record/ldd.tmp" 2>&1
    printf '## %s\n' "${file#"$lib_root"}" >> "$record/ldd.txt"
    cat "$record/ldd.tmp" >> "$record/ldd.txt"
    while read -r lib _ path _; do
        if [[ $path == not ]]; then
            printf 'UNRESOLVED %s' "$lib"; bad=1
        elif [[ $lib =~ $NV_LIBS && $path == /* && $path != "$lib_root"/* ]] && ! installed_nv "$path"; then
            printf 'OUTSIDE %s=>%s' "$lib" "$path"; bad=1
        else
            continue
        fi
        printf ' (needed by %s)\n' "$(basename "$file")"
    done < <(grep '=>' "$record/ldd.tmp")
    rm -f "${record:?}/ldd.tmp"
    return "$bad"
}
ldd_check "$plugins/libgstnvvidconv.so" && check LIBRARIES PASS || check LIBRARIES FAIL
others=0
for plugin in "$plugins"/libgstnv*.so*; do
    [[ $plugin == */libgstnvvidconv.so ]] && continue
    ldd_check "$plugin" > "$record/ldd-other.tmp" || others=$(( others + 1 ))
    sed 's/^/OTHER_PLUGIN: /' "$record/ldd-other.tmp"
done
rm -f "${record:?}/ldd-other.tmp"
printf 'OTHER_PLUGINS_WITH_GAPS=%s (not required)\n' "$others"

# --- 2. GStreamer loads nvvidconv (this also builds the registry).
for element in videotestsrc videoconvert videoscale filesink; do
    "${gst[@]}" gst-inspect-1.0 "$element" > /dev/null 2>&1 \
        || die "GStreamer has no $element; install Ubuntu's base plugins first: $GST_TOOLS"
done
timeout -k 10 "$RUN_SECONDS" "${gst[@]}" gst-inspect-1.0 nvvidconv > "$record/inspect-nvvidconv.txt" 2>&1
status=$?
grep -E '^ +(Filename|Version|Source module|Binary package) |^ +(compute-hw|interpolation-method) *:' \
    "$record/inspect-nvvidconv.txt" | sed -E 's/^ +/inspect: /'
"${gst[@]}" gst-inspect-1.0 -b > "$record/inspect-blacklist.txt" 2>&1
grep -E 'libgstnv|nv[a-z0-9]+:' "$record/inspect-blacklist.txt" | sed 's/^ */BLACKLISTED: /'
"${gst[@]}" gst-inspect-1.0 > "$record/inspect-all.txt" 2>&1
printf 'NV_ELEMENTS=%s\n' "$(awk -F': +' '$1 ~ /^nv/ {printf "%s%s", sep, $2; sep = " "}' "$record/inspect-all.txt")"
inspect=FAIL
if (( status == 0 )) && grep -q 'Factory Details' "$record/inspect-nvvidconv.txt"; then
    inspect=PASS
    check INSPECT PASS
else
    head -n 5 "$record/inspect-nvvidconv.txt" | sed 's/^/inspect: /'
    check INSPECT "FAIL gst-inspect-1.0 exit $status"
fi
has_property() { grep -qE "^ +$1 *:" "$record/inspect-nvvidconv.txt"; }
# nvvidconv's properties, and the values its interpolation-method offers as
# NUMBER:NAME (gst-inspect-1.0 lists them as "(NUMBER): NAME - description").
printf 'NVVIDCONV_PROPERTIES=%s\n' "$(awk '/^Element Properties:/ {p = 1; next} /^[^ ]/ {p = 0}
    p && /^  [a-z][a-z0-9-]* *:/ {name = $1; sub(/:.*/, "", name); printf "%s%s", sep, name; sep = " "}' \
    "$record/inspect-nvvidconv.txt")"
methods=$(awk '/^[^ ]/ {p = 0}
    /^  [a-z][a-z0-9-]* *:/ {name = $1; sub(/:.*/, "", name); p = (name == "interpolation-method")}
    p && /^ +\([0-9]+\): / {n = $1; gsub(/[():]/, "", n); printf "%s%s:%s", sep, n, $2; sep = " "}' \
    "$record/inspect-nvvidconv.txt")
if has_property interpolation-method; then
    printf 'INTERPOLATION_METHODS=%s default=%s\n' "${methods:-none listed}" \
        "$(sed -nE '/^ +interpolation-method *:/,/Default:/ s/.*Default: ([0-9]+), "([^"]*)".*/\1:\2/p' \
            "$record/inspect-nvvidconv.txt" | head -n 1)"
fi
sweep=()
if [[ -n ${INTERPOLATION_SWEEP:-} && -z $methods ]]; then
    printf 'SWEEP=skipped (nvvidconv lists no interpolation-method values)\n'
elif [[ -n ${INTERPOLATION_SWEEP:-} ]]; then
    if [[ $INTERPOLATION_SWEEP == all ]]; then
        read -ra sweep <<< "$(sed -E 's/:[^ ]*//g' <<< "$methods")"
    else
        read -ra sweep <<< "$INTERPOLATION_SWEEP"
        for value in "${sweep[@]}"; do
            [[ " $methods" == *" $value:"* ]] \
                || die "INTERPOLATION_SWEEP: nvvidconv has no interpolation-method $value ($methods)"
        done
    fi
fi

# --- The chip the kernel reports.
printf 'SOC soc_id=%s family=%s revision=%s\n' "$(cat /sys/devices/soc0/soc_id 2> /dev/null || echo -)" \
    "$(cat /sys/devices/soc0/family 2> /dev/null || echo -)" "$(cat /sys/devices/soc0/revision 2> /dev/null || echo -)"
# VIC's falcon firmware, which the kernel loads (R32.7.6's in nano-l4t-core).
firmware=/lib/firmware/tegra21x/vic04_ucode.bin
if [[ -f $firmware ]]; then
    owner=$(dpkg-query -S "$(readlink -f "$firmware")" 2> /dev/null | cut -d: -f1 | head -n 1)
    printf 'VIC_FIRMWARE %s bytes=%s sha256=%s package=%s\n' "$firmware" "$(stat -c %s "$firmware")" \
        "$(sha256sum < "$firmware" | cut -c1-16)" "${owner:--}"
else
    printf 'VIC_FIRMWARE %s missing\n' "$firmware"
fi

# --- VIC's runtime power counter (milliseconds powered on).
vic_dir=$(find /sys/bus/platform/devices/ -maxdepth 1 -name '*.vic' | head -n 1)
vic_time() { cat "$vic_dir/power/runtime_active_time" 2> /dev/null || echo -; }
vic_before=$(vic_time)

# --- Conversion runs. NAME then gst-launch-1.0's arguments; RUN_LIMIT seconds.
own_libs='the scratch folder'
(( installed )) && own_libs="$VIDEO_PACKAGE's folder"
vic_env=()  # step 8's shim settings, for the converter's runs only
run_gst() {
    local name=$1 ok=0 status loaded outside began=$SECONDS; shift
    timeout -k 10 "${RUN_LIMIT:-$RUN_SECONDS}" "${gst[@]}" "${vic_env[@]}" GST_DEBUG=2 GST_DEBUG_FILE="$record/$name-gst.log" \
        LD_DEBUG=libs LD_DEBUG_OUTPUT="$record/ld-$name" gst-launch-1.0 "$@" > "$record/$name.log" 2>&1
    status=$?
    gst_exit=$status
    printf '%s: GST_LAUNCH_EXIT=%s seconds=%s\n' "$name" "$status" "$(( SECONDS - began ))"
    (( status == 0 )) || ok=1
    grep -E 'ERROR|WARNING|error|Segmentation|Bus error|Aborted|core dumped' "$record/$name.log" \
        | head -n 10 | cut -c1-240 | sed "s/^/$name: /"
    grep -E ' (ERROR|WARN) ' "$record/$name-gst.log" 2> /dev/null | head -n 6 | cut -c1-240 | sed "s/^/$name: GST: /"
    # Every library the run loaded, from the linker's own record.
    cat "$record/ld-$name".* 2> /dev/null | grep -oE 'calling init: /[^ ]+' | sed 's/^calling init: //' \
        | sort -u > "$record/$name-loaded.txt"
    rm -f "${record:?}/ld-${name:?}".*
    loaded=$(while read -r path; do
        [[ $(basename "$path") =~ $NV_LIBS ]] && basename "$path"; done < "$record/$name-loaded.txt" | tr '\n' ' ')
    outside=$(while read -r path; do
        [[ $(basename "$path") =~ $NV_LIBS && $path != "$lib_root"/* ]] && ! installed_nv "$path" && echo "$path"
    done < "$record/$name-loaded.txt" | tr '\n' ' ')
    printf '%s: NV_LOADED=%s\n' "$name" "$loaded"
    if [[ ! -s $record/$name-loaded.txt ]]; then
        printf '%s: LIB_MIX=FAIL the linker recorded nothing\n' "$name"; ok=1
    elif [[ -n $outside ]]; then
        printf '%s: LIB_MIX=FAIL %s\n' "$name" "$outside"; ok=1
    else
        printf '%s: LIB_MIX=PASS every NVIDIA library from %s\n' "$name" \
            "$own_libs$([[ $release == r35 ]] && echo ' or the driver set')"
    fi
    return "$ok"
}
# compare NAME FORMAT WIDTH HEIGHT MIN_PSNR: the run's frames against the reference's.
# A failed colour check (one with input frames) is explained by colour_fit.py,
# and passes if the compared frames fit BT.601 with VIC's chroma placement.
compare() {
    local name=$1 status picked
    python3 -I "$here/frame_check.py" "$2" "$3" "$4" "$frames/$name-ref.raw" "$frames/$name-out.raw" "$5" \
        > "$record/$name-frames.txt"
    status=$?
    sed "s/^/$name: /" "$record/$name-frames.txt"
    if (( status != 0 )) && [[ -f $frames/$name-in.raw ]]; then
        python3 -I "$here/colour_fit.py" "$3" "$4" "$frames/$name-in.raw" "$frames/$name-out.raw" \
            | sed "s/^/$name: /"
        picked=$(sed -n 's/^COMPARED frames=\([0-9,]*\) .*/\1/p' "$record/$name-frames.txt")
        if [[ -n $picked ]]; then
            python3 -I "$here/colour_fit.py" --check "$CHROMA_MOVE" 40 "$picked" "$3" "$4" \
                "$frames/$name-in.raw" "$frames/$name-out.raw" 2>&1 | sed "s/^/$name: /"
            (( PIPESTATUS[0] == 0 )) && status=0
        fi
    fi
    drop "$name"
    return "$status"
}
drop() {  # NAME: its frames go, or into kept-frames with KEEP_FRAMES=1
    if [[ ${KEEP_FRAMES:-0} == 1 ]]; then
        mkdir -p "$record/kept-frames" && mv -f "$frames/$1"-*.raw "$record/kept-frames/" 2> /dev/null
    fi
    rm -f "${frames:?}/${1:?}"-*.raw
}
reference() {  # NAME then the pipeline, ending in a filesink
    local name=$1; shift
    timeout -k 10 "$RUN_SECONDS" "${gst[@]}" gst-launch-1.0 -q "$@" > "$record/$name-ref.log" 2>&1 \
        || { printf '%s: REFERENCE=FAIL\n' "$name"; tail -n 3 "$record/$name-ref.log" | sed "s/^/$name: /"; return 1; }
}
moving=(videotestsrc num-buffers=30 pattern=smpte horizontal-speed=8)
hd=('video/x-raw,format=I420,width=1920,height=1080,framerate=30/1')
src=('video/x-raw,format=I420,width=1280,height=720,framerate=30/1,colorimetry=bt601')
bilinear=''
if has_property interpolation-method; then
    bilinear=1
else
    printf "SCALE_FILTER=nvvidconv's default (no interpolation-method property)\n"
fi
# colour NAME FRAMES LIMIT then nvvidconv's properties: I420 (BT.601) to RGBA at 1280x720.
# The pattern is also kept as I420 for colour_fit.py.
colour() {
    local name=$1 count=$2 limit=$3; shift 3
    local pattern=(videotestsrc num-buffers="$count" pattern=smpte horizontal-speed=8)
    reference "$name-in" "${pattern[@]}" ! "${src[@]}" ! filesink location="$frames/$name-in.raw" \
        && reference "$name" "${pattern[@]}" ! "${src[@]}" ! videoconvert ! video/x-raw,format=RGBA \
            ! filesink location="$frames/$name-ref.raw" \
        && RUN_LIMIT=$limit run_gst "$name" "${pattern[@]}" ! "${src[@]}" ! nvvidconv "$@" \
            ! 'video/x-raw(memory:NVMM),format=RGBA' ! nvvidconv "$@" ! video/x-raw,format=RGBA \
            ! filesink location="$frames/$name-out.raw" \
        && compare "$name" RGBA 1280 720 30 && return 0
    drop "$name"
    return 1
}
# scale NAME METHOD then nvvidconv's properties: 1280x720 to 640x360 I420 with
# interpolation-method METHOD (none if empty) on the scaling conversion, against
# videoscale's bilinear.
scale() {
    local name=$1 filter=(); shift
    [[ -n $1 ]] && filter=(interpolation-method="$1")
    shift
    reference "$name" "${moving[@]}" ! "${src[@]}" ! videoscale method=bilinear \
            ! video/x-raw,width=640,height=360 ! filesink location="$frames/$name-ref.raw" \
        && run_gst "$name" "${moving[@]}" ! "${src[@]}" ! nvvidconv "$@" "${filter[@]}" \
            ! 'video/x-raw(memory:NVMM),format=I420,width=640,height=360' ! nvvidconv "$@" \
            ! video/x-raw,format=I420 ! filesink location="$frames/$name-out.raw" \
        && compare "$name" I420 640 360 20 && return 0
    drop "$name"
    return 1
}
# convert_path PATH then nvvidconv's properties: a two-frame colour conversion
# within SMOKE_SECONDS (the kernel ends a hung engine job after 10 s, so a hang
# shows as a timeout or a wrong picture), then steps 3 to 5.
hung=''  # the paths whose smoke run did not finish
convert_path() {
    local path=$1 upper=${1^^} ok=PASS
    shift
    gst_exit=''
    if colour "$path-smoke" 2 "$SMOKE_SECONDS" "$@"; then
        printf '%s_SMOKE=PASS\n' "$upper"
    elif [[ $gst_exit == 0 ]]; then
        printf '%s_SMOKE=FAIL (the run finished, so the other %s checks still run)\n' "$upper" "$path"
        ok=FAIL
    else
        printf '%s_SMOKE=FAIL (two frames, %s s at most; the other %s checks skipped)\n' "$upper" "$SMOKE_SECONDS" "$path"
        printf '%s_PATH=FAIL\n' "$upper"
        hung+=" $path"
        return 1
    fi
    # 3. Round trip through NVMM NV12 at 1920x1080.
    if reference "$path-roundtrip" "${moving[@]}" ! "${hd[@]}" ! filesink location="$frames/$path-roundtrip-ref.raw" \
            && run_gst "$path-roundtrip" "${moving[@]}" ! "${hd[@]}" ! nvvidconv "$@" \
                ! 'video/x-raw(memory:NVMM),format=NV12' ! nvvidconv "$@" ! video/x-raw,format=I420 \
                ! filesink location="$frames/$path-roundtrip-out.raw" \
            && compare "$path-roundtrip" I420 1920 1080 40; then
        printf '%s_ROUNDTRIP=PASS\n' "$upper"
    else
        printf '%s_ROUNDTRIP=FAIL\n' "$upper"; ok=FAIL
    fi
    # 4. Colour conversion, 30 frames.
    if colour "$path-colour" 30 "$RUN_SECONDS" "$@"; then
        printf '%s_COLOUR=PASS\n' "$upper"
    else
        printf '%s_COLOUR=FAIL\n' "$upper"; ok=FAIL
    fi
    # 5. Scaling to 640x360 with bilinear filtering.
    if scale "$path-scale" "$bilinear" "$@"; then
        printf '%s_SCALE=PASS\n' "$upper"
    else
        printf '%s_SCALE=FAIL\n' "$upper"; ok=FAIL
    fi
    printf '%s_PATH=%s\n' "$upper" "$ok"
    [[ $ok == PASS ]]
}

# vic_record.c, for VIC_PATCH_RUNS and steps 7 and 8.
shim=''
build_shim() {  # STEP: builds vic_record.so once
    [[ -n $shim ]] && return 0
    if "$cc" -O2 -Wall -shared -fPIC -o "$record/vic_record.so" "$here/vic_record.c" -ldl \
            > "$record/vic_record-build.txt" 2>&1; then
        shim=$record/vic_record.so
        return 0
    fi
    printf '%s=FAIL (vic_record.c did not build)\n' "$1"
    head -n 5 "$record/vic_record-build.txt" | sed "s/^/$1: /"
    return 1
}
if (( ${#run_groups[@]} )); then
    if (( fixed )); then  # the launcher's vic_patch.so patches; it also counts with a record folder
        printf 'VIC_PATCH_RUNS=%s (%s sets it for every run; its vic_patch.so counts the jobs)\n' \
            "${run_groups[*]}" "$LAUNCHER"
        vic_env=(VIC_RECORD_DIR="$record/vic-patch-runs" VIC_RECORD_JOBS=2)
    else
        build_shim VIC_PATCH_RUNS || { result=FAIL; finish; }
        printf 'VIC_PATCH_RUNS=%s (every converter run of steps 3 to 6 has these set to JetPack 4'"'"'s values)\n' \
            "${run_groups[*]}"
        vic_env=(LD_PRELOAD="$record/vic_record.so" VIC_RECORD_DIR="$record/vic-patch-runs" VIC_RECORD_JOBS=2
                 VIC_PATCH="${run_groups[*]}")
    fi
    mkdir -p "$record/vic-patch-runs"
fi

# --- The VIC path (nvvidconv's default), then the CUDA path.
if [[ $inspect == PASS ]]; then
    vic_path=FAIL
    convert_path vic && vic_path=PASS
    if has_property compute-hw; then
        gpu_path=FAIL
        convert_path gpu compute-hw=1 && gpu_path=PASS
    else
        gpu_path=skipped
        printf 'GPU_PATH=skipped (no compute-hw property)\n'
    fi
else
    vic_path=skipped gpu_path=skipped
    printf 'CONVERSIONS=skipped (GStreamer did not load nvvidconv)\n'
fi
[[ $vic_path == PASS || $gpu_path == PASS ]] && check CONVERTER PASS || check CONVERTER FAIL

# --- 6. With INTERPOLATION_SWEEP: the VIC path's colour and scale tests with
# each value, for the record. Each run's lines go to sweep-NAME.txt; one line
# a test sums them up.
sums() {  # FILE: the planes' PSNR, and colour_fit.py's check, best fit and big errors if it ran
    sed -nE 's/^[^ ]+: PLANE ([A-Za-z]+) psnr_db=([^ ]+) .*/\1=\2/p
        s/^[^ ]+: COLOUR_FIT_CHECK=([A-Z]+) .* worst_db=([^ ]+) .*/vic_check=\1 vic_check_db=\2/p
        s/^[^ ]+: COLOUR_FIT best chroma=([a-z]+) move=([^ ]+) matrix=([^ ]+) worst_db=([^ ]+) .*/best=\1,\2,\3 best_db=\4/p
        s/^[^ ]+: BIG_ERRORS pixels=([0-9]+) of ([0-9]+) .*/big_errors=\1\/\2/p' "$1" | paste -sd ' '
}
if (( ${#sweep[@]} )); then
    if [[ $vic_path == skipped || " $hung " == *" vic "* ]]; then
        printf 'SWEEP=skipped (the VIC path did not run, or its smoke run did not finish)\n'
    else
        for value in "${sweep[@]}"; do
            label=$(tr ' ' '\n' <<< "$methods" | sed -n "s/^$value://p")
            gst_exit=''
            KEEP_FRAMES=0 colour "sweep-colour-m$value" 10 "$SMOKE_SECONDS" interpolation-method="$value" \
                > "$record/sweep-colour-m$value.txt" 2>&1 && verdict=PASS || verdict=FAIL
            printf 'SWEEP_COLOUR method=%s (%s) %s exit=%s %s\n' "$value" "$label" "$verdict" "${gst_exit:--}" \
                "$(sums "$record/sweep-colour-m$value.txt")"
            gst_exit=''
            KEEP_FRAMES=0 RUN_LIMIT=$SMOKE_SECONDS scale "sweep-scale-m$value" "$value" \
                > "$record/sweep-scale-m$value.txt" 2>&1 && verdict=PASS || verdict=FAIL
            printf 'SWEEP_SCALE method=%s (%s) %s exit=%s %s\n' "$value" "$label" "$verdict" "${gst_exit:--}" \
                "$(sums "$record/sweep-scale-m$value.txt")"
        done
    fi
fi

if (( ${#run_groups[@]} )); then
    vic_env=()
    printf 'VIC_PATCH_RUNS %s\n' "$(awk '/^vic_patch:/ {runs++; for (i = 3; i <= NF; i++) {split($i, kv, "="); n[kv[1]] += kv[2]}}
        END {printf "runs=%d jobs=%d patched=%d unchanged=%d skipped=%d failed=%d", runs, n["jobs"], n["patched"],
             n["unchanged"], n["skipped"], n["failed"]}' "$record"/vic-patch-runs/p*-log.txt 2> /dev/null)"
fi

# --- 7. With VIC_RECORD=1: the jobs nvvidconv hands VIC, two frames a case.
recorded() {  # NAME then gst-launch-1.0's arguments
    local name=$1 jobs=$record/vic-jobs/$1 status; shift
    mkdir -p "$jobs"
    timeout -k 10 "$SMOKE_SECONDS" "${gst[@]}" LD_PRELOAD="$record/vic_record.so" VIC_RECORD_DIR="$jobs" \
        VIC_PATCH= gst-launch-1.0 -q "$@" > "$jobs/gst.log" 2>&1
    status=$?
    python3 -I "$here/vic_jobs.py" show "$jobs" > "$jobs/show.txt" 2>&1
    printf 'VIC_RECORD %s exit=%s %s\n' "$name" "$status" "$(sed -n '1s/^JOBS [^:]*: //p' "$jobs/show.txt")"
    # Jobs alike but for their name, once each with their count.
    sed -n 's/^JOB [^ ]* //p' "$jobs/show.txt" | uniq -c | sed -E 's/^ *([0-9]+) /VIC_RECORD   jobs=\1 /'
}
if [[ ${VIC_RECORD:-0} == 1 ]]; then
    if [[ $vic_path == skipped || " $hung " == *" vic "* ]]; then
        printf 'VIC_RECORD=skipped (the VIC path did not run, or its smoke run did not finish)\n'
    elif build_shim VIC_RECORD; then
        printf 'VIC_RECORD_DIR=%s\n' "$record/vic-jobs"
        two=(videotestsrc num-buffers=2 pattern=smpte)
        recorded colour "${two[@]}" ! "${src[@]}" ! nvvidconv ! 'video/x-raw(memory:NVMM),format=RGBA' \
            ! nvvidconv ! video/x-raw,format=RGBA ! fakesink
        cases=()
        for value in 0 1; do
            [[ " $methods" == *" $value:"* ]] && cases+=("$value")
        done
        (( ${#cases[@]} )) || cases=('')
        for value in "${cases[@]}"; do
            recorded "scale${value:+-m$value}" "${two[@]}" ! "${src[@]}" ! nvvidconv \
                ${value:+interpolation-method="$value"} ! 'video/x-raw(memory:NVMM),format=I420,width=640,height=360' \
                ! nvvidconv ! video/x-raw,format=I420 ! fakesink
        done
    fi
fi

# --- 8. With VIC_PATCH: the VIC path's colour and scale tests with groups of
# VIC's settings set to JetPack 4's values in every job.
patch_test() {  # GROUP TEST: the colour or scale test, as the sweep runs it
    if [[ $2 == colour ]]; then
        KEEP_FRAMES=0 colour "patch-$1-colour" 10 "$SMOKE_SECONDS"
    else
        KEEP_FRAMES=0 RUN_LIMIT=$SMOKE_SECONDS scale "patch-$1-scale" "$bilinear"
    fi
}
if (( ${#patch_groups[@]} )); then
    if [[ $vic_path == skipped || " $hung " == *" vic "* ]]; then
        printf 'VIC_PATCH=skipped (the VIC path did not run, or its smoke run did not finish)\n'
    elif build_shim VIC_PATCH; then
        printf 'VIC_PATCH_DIR=%s\n' "$record/vic-patch"
        for group in none "${patch_groups[@]}"; do
            for test in colour scale; do
                folder=$record/vic-patch/$group-$test
                mkdir -p "$folder"
                vic_env=(LD_PRELOAD="$record/vic_record.so" VIC_RECORD_DIR="$folder" VIC_PATCH="${group#none}")
                gst_exit=''
                patch_test "$group" "$test" > "$folder/test.txt" 2>&1 && verdict=PASS || verdict=FAIL
                vic_env=()
                counts=$(sed -n 's/^vic_patch: groups=[^ ]* //p' "$folder"/p*-log.txt 2> /dev/null | paste -sd ';')
                printf 'PATCH_%s group=%s %s exit=%s %s vic_jobs: %s\n' "${test^^}" "$group" "$verdict" \
                    "${gst_exit:--}" "$(sums "$folder/test.txt")" "${counts:-not patched}"
            done
        done
    fi
fi

# --- 9. With --installed r35: one program converts on VIC and checks the frames with CUDA.
one_program() {  # NAME FRAMES then settings for the launched program: vic_cuda.py's VIC_CUDA line
    local name=$1 frames=$2 status outside; shift 2
    timeout -k 10 "$RUN_SECONDS" "${gst[@]}" "$@" CUDA_CACHE_DISABLE=1 \
        python3 -I "$here/vic_cuda.py" --frames "$frames" > "$record/$name.txt" 2>&1
    status=$?
    grep -vE '^(FRAME |LIB |PIPELINE=|VIC_CUDA=)' "$record/$name.txt" | head -n 20 | cut -c1-240 \
        | sed "s/^/$name: /"
    awk -v name="$name" '/^FRAME / {n++; if ($NF == "PASS") ok++; for (i = 2; i <= NF; i++) if ($i ~ /^worst=/) {
            v = substr($i, 7); if (worst == "" || v + 0 < worst + 0) worst = v} if ($0 ~ /cpu=DIFFER/) differ++}
        END {printf "%s: FRAMES checked=%d pass=%d worst_db=%s cpu_differ=%d\n", name, n, ok, worst == "" ? "-" : worst,
             differ}' "$record/$name.txt"
    outside=$(sed -n 's/^LIB //p' "$record/$name.txt" | while read -r path; do
        [[ $path != "$lib_root"/* ]] && ! installed_nv "$path" && echo "$path"; done | tr '\n' ' ')
    printf '%s: NV_LOADED=%s\n' "$name" "$(sed -n 's/^LIB //p' "$record/$name.txt" | xargs -r -n1 basename | tr '\n' ' ')"
    if [[ -n $outside ]]; then
        printf '%s: LIB_MIX=FAIL %s\n' "$name" "$outside"
        status=1
    else
        printf '%s: LIB_MIX=PASS every NVIDIA library from %s or the driver set\n' "$name" "$own_libs"
    fi
    grep '^VIC_CUDA=' "$record/$name.txt" | sed "s/^/$name: /"
    printf '%s: EXIT=%s\n' "$name" "$status"
    return "$status"
}
if (( fixed )); then
    if [[ $vic_path == skipped || " $hung " == *" vic "* ]]; then
        vic_cuda=FAIL
        check VIC_CUDA 'FAIL (skipped: the VIC path did not run, or its smoke run did not finish)'
    else
        vic_cuda=FAIL
        one_program vic-cuda 30 && vic_cuda=PASS
        check VIC_CUDA "$vic_cuda"
        one_program vic-cuda-unfixed 10 VIC_PATCH= > "$record/vic-cuda-unfixed-summary.txt" \
            && verdict=PASS || verdict=FAIL
        printf 'VIC_CUDA_UNFIXED %s %s (VIC_PATCH=, for the record, not counted)\n' "$verdict" \
            "$(sed -n 's/^vic-cuda-unfixed: FRAMES \(checked=.*\)/\1/p' "$record/vic-cuda-unfixed-summary.txt")"
    fi
fi

# --- VIC's counter, the decoder node, the kernel's messages.
vic_after=$(vic_time)
printf 'VIC_RUNTIME device=%s active_ms_before=%s after=%s status=%s\n' "${vic_dir:--}" "$vic_before" "$vic_after" \
    "$(cat "$vic_dir/power/runtime_status" 2> /dev/null || echo -)"
if [[ -e /dev/nvhost-nvdec ]]; then
    printf 'DECODER_NODE=present (/dev/nvhost-nvdec)\n'
else
    printf 'DECODER_NODE=absent (NVDEC is off in the 5.10 device tree)\n'
fi
if journalctl -k --since "@$start" --no-pager -o short-monotonic > "$record/kernel.log" 2>&1 \
        && ! grep -q 'No journal files were opened\|not seeing messages' "$record/kernel.log"; then
    printf 'KERNEL_LOG=read lines=%s\n' "$(wc -l < "$record/kernel.log")"
    grep -iE 'vic|nvhost|host1x|nvmap|smmu|falcon|flcn|mc-err|nvgpu' "$record/kernel.log" \
        | tail -n 40 | sed 's/^/KERNEL: /'
else
    printf 'KERNEL_LOG=unavailable (%s)\n' "$(head -n 1 "$record/kernel.log")"
fi
printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
finish

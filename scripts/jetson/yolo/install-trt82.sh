#!/usr/bin/env bash
# Install nano-trt82 from package-trt82.sh: JetPack 4's TensorRT 8.2 as the
# default TensorRT, with JetPack 5's TensorRT 8.5 beside it.
#
# Usage, from an SSH login to the Nano:
#   sudo bash install-trt82.sh ~/nano-trt82-package
#
# The folder's .deb is checked against its SHA256SUMS. No file of the package
# may exist already unless an earlier nano-trt82 holds it, and apt's plan must
# be this one package and nothing else; TensorRT 8.5 and cuDNN 8.6 stay
# installed. After the install, as the account that ran sudo:
#   1. the library path: libnvinfer.so.8, libnvinfer_plugin.so.8,
#      libnvonnxparser.so.8 and libcudnn.so.8 resolve to nano-trt82 first, and
#      TensorRT 8.5's and cuDNN 8.6's are still listed;
#   2. by default TensorRT's library reports 8.2.1 and cuDNN's 8.2.1, each
#      loaded from nano-trt82; through nano-trt85, 8.5.2 and 8.6.0 from
#      /usr/lib/aarch64-linux-gnu;
#   3. trtexec is TensorRT 8.2's, and nano-trt85 /usr/src/tensorrt/bin/trtexec
#      8.5's.
# The GPU runs come next, with setup-yolo.sh. The record goes to
# ~/trt82-install/<stamp>; the last line is TRT82_INSTALL=PASS or FAIL. Run
# again after a pass, it installs nothing and checks again.
# Undo: sudo apt-get purge nano-trt82 (TensorRT 8.5 is then the default again).
set -uo pipefail

KERNEL=5.10.216-tegra
PKG=nano-trt82
LIBDIR=/usr/lib/aarch64-linux-gnu
DIR=$LIBDIR/nano-trt82
TRTEXEC85=/usr/src/tensorrt/bin/trtexec
# The names TensorRT 8.2 and 8.5, and cuDNN 8.2 and 8.6, share.
SHARED=(libnvinfer.so.8 libnvinfer_plugin.so.8 libnvonnxparser.so.8 libcudnn.so.8)

die() { printf 'TRT82_INSTALL=FAIL: %s\n' "$*" >&2; exit 1; }

folder=${1:-}
[[ $# -eq 1 && -d $folder ]] || die 'usage: sudo bash install-trt82.sh PACKAGE_DIR (from package-trt82.sh)'
folder=$(cd "$folder" && pwd)
[[ $(id -u) -eq 0 ]] || die 'run this with sudo'
owner=${SUDO_USER:-}
[[ -n $owner && $owner != root ]] || die 'run this with sudo from your own account'
IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$owner") || die "no account $owner"
[[ -d $home ]] || die "no home folder for $owner"
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for tool in apt-get dpkg dpkg-deb dpkg-query runuser setsid ldconfig sha256sum python3 tar; do
    command -v "$tool" > /dev/null || die "no $tool"
done
installed() { dpkg-query -W -f '${db:Status-Abbrev} ${Version}\n' "$1" 2> /dev/null | awk '$1 == "ii" { print $2 }'; }
[[ $(installed libnvinfer8) == 8.5.* && $(installed libcudnn8) == 8.6.* ]] \
    || die "needs JetPack 5's TensorRT 8.5 and cuDNN 8.6 installed (libnvinfer8 $(installed libnvinfer8), libcudnn8 $(installed libcudnn8))"
shopt -s nullglob
found=("$folder/${PKG}_"*_arm64.deb)
[[ ${#found[@]} -eq 1 ]] || die "need exactly one ${PKG}_*_arm64.deb in $folder"
deb=${found[0]}
[[ -f $folder/SHA256SUMS ]] || die "no SHA256SUMS in $folder"
(cd "$folder" && grep -E "  ${PKG}_.*_arm64\.deb\$" SHA256SUMS | grep . | sha256sum --quiet -c -) > /dev/null 2>&1 \
    || die "${deb##*/} does not match the SHA256SUMS next to it"
[[ $(dpkg-deb -f "$deb" Package) == "$PKG" ]] || die "${deb##*/} does not hold $PKG"
version=$(dpkg-deb -f "$deb" Version)

stamp=$(date -u +%Y%m%dT%H%M%SZ)
parent=$home/trt82-install
record=$parent/$stamp
[[ -d $parent ]] || { mkdir -m 0755 "$parent" && chown "$uid:$gid" "$parent"; } || die "cannot create $parent"
mkdir -m 0755 "$record" || die "cannot create $record"
stage=/var/tmp/nano-trt82-deb
trap '' HUP PIPE
exec 3>&1 4>&2
exec > >(trap '' INT TERM; exec tee --output-error=warn "$record/summary.txt") 2>&1
tee_pid=$!
start=$(date +%s)
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nOS=%s\nACCOUNT=%s\nVERSION=%s\nTENSORRT85=%s\nCUDNN86=%s\n' \
    "$record" "$stamp" "$(uname -r)" "$PRETTY_NAME" "$(id "$owner")" "$version" "$(installed libnvinfer8)" \
    "$(installed libcudnn8)"

result=PASS
check() { printf '%s=%s\n' "$1" "$2"; [[ $2 == PASS* ]] || result=FAIL; }
finish() {
    trap - EXIT
    trap '' INT TERM
    rm -rf "$stage"
    chown -R "$uid:$gid" "$record"
    printf 'SECONDS_TOTAL=%s\n' "$(( $(date +%s) - start ))"
    if [[ $result == PASS ]]; then
        printf 'Next: bash setup-yolo.sh ~/yolo26-nano.tar (builds the engines with TensorRT 8.2)\n'
    fi
    printf 'TRT82_INSTALL=%s record=%s\n' "$result" "$record"
    exec 1>&3 2>&4  # tee sees the end of its input and finishes the record
    wait "$tee_pid" 2> /dev/null
    [[ $result == PASS ]] && exit 0
    exit 1
}
trap finish EXIT
trap 'printf "INTERRUPTED\n"; result=FAIL; exit 130' INT TERM
fail() { check "$1" "FAIL $2"; exit 1; }

# --- The plan: this package in, nothing else.
dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' > "$record/packages-before.txt"
if [[ $(installed "$PKG") == "$version" ]]; then
    printf 'ALREADY_INSTALLED=%s\n' "$version"
else
    # No file of the package may exist already: neither another package's nor
    # one no package holds; an earlier nano-trt82's are replaced.
    dpkg-deb --fsys-tarfile "$deb" | tar -t | sed -n 's|^\./|/|; /[^/]$/p' > "$record/paths.txt" \
        || fail FILE_OWNERS "cannot list ${deb##*/}"
    clash=0
    while IFS= read -r path; do
        [[ -e $path || -L $path ]] || continue
        [[ -d $path && ! -L $path ]] && continue
        owners=$(dpkg-query -S "$path" 2> /dev/null | grep -v '^diversion ' | sed 's/: .*//' | paste -sd ' ')
        if [[ -z $owners ]]; then
            printf 'EXISTS_UNOWNED %s\n' "$path"
        elif [[ " ${owners//,/ } " != *" $PKG "* ]]; then
            printf 'OWNED_ELSEWHERE %s by %s\n' "$path" "$owners"
        else
            continue
        fi
        clash=1
    done < "$record/paths.txt"
    (( clash == 0 )) && check FILE_OWNERS PASS || fail FILE_OWNERS 'a file of the package is already there'

    # Staged in a folder only root writes, checked again there, where apt reads it.
    rm -rf "$stage"
    install -d -m 0755 "$stage"
    need=$(( $(dpkg-deb -f "$deb" Installed-Size) * 1024 + $(stat -c %s "$deb") + (512 << 20) ))
    free=$(( $(df -B1 --output=avail "$LIBDIR" | tail -n 1) ))
    printf 'SPACE=%s MiB free, %s MiB needed\n' "$(( free >> 20 ))" "$(( need >> 20 ))"
    (( free > need )) || fail SPACE "not enough free space for $LIBDIR"
    staged=$stage/${deb##*/}
    install -m 0644 "$deb" "$staged"
    (cd "$folder" && grep -E "  ${PKG}_.*_arm64\.deb\$" SHA256SUMS) | sed "s|  .*|  $staged|" | sha256sum --quiet -c - \
        > /dev/null 2>&1 || fail STAGE "${deb##*/} changed while copied"
    export DEBIAN_FRONTEND=noninteractive
    apt=(apt-get --no-install-recommends -o Dpkg::Options::=--force-confold)
    "${apt[@]}" -s install "$staged" > "$record/plan.txt" 2>&1 \
        || { tail -n 20 "$record/plan.txt"; fail PLAN 'apt cannot plan the change'; }
    unexpected=()
    while read -r action pkg _; do
        case $action in
            Inst) [[ $pkg == "$PKG" ]] || unexpected+=("install $pkg") ;;
            Remv|Purg) unexpected+=("remove $pkg") ;;
        esac
    done < <(grep -E '^(Inst|Remv|Purg) ' "$record/plan.txt")
    grep -qE "^Inst $PKG " "$record/plan.txt" || unexpected+=("not installing $PKG")
    printf 'PLAN=%s installed or upgraded, %s removed\n' "$(grep -c '^Inst ' "$record/plan.txt")" \
        "$(grep -cE '^(Remv|Purg) ' "$record/plan.txt")"
    (( ${#unexpected[@]} == 0 )) && check PLAN PASS || fail PLAN "${unexpected[*]}"

    printf 'INSTALLING (apt-get; unpacking %s MiB takes a few minutes)\n' "$(( $(dpkg-deb -f "$deb" Installed-Size) >> 10 ))"
    # In its own session, so neither Ctrl+C nor a lost connection stops dpkg
    # halfway; an interrupt takes effect once apt-get is done.
    if setsid --wait "${apt[@]}" --yes install "$staged" < /dev/null > "$record/apt-install.txt" 2>&1; then
        check APT_INSTALL PASS
    else
        tail -n 25 "$record/apt-install.txt"
        fail APT_INSTALL "see $record/apt-install.txt; 'sudo apt-get -f install' finishes or undoes it"
    fi
    grep -E '^(E|W): ' "$record/apt-install.txt" | head -n 10
    rm -rf "$stage"
fi

# --- After the change.
dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' > "$record/packages-after.txt"
[[ $(installed "$PKG") == "$version" ]] && check INSTALLED PASS || check INSTALLED FAIL
diff <(awk '$1 ~ /^.i/ { print $2, $3 }' "$record/packages-before.txt") \
     <(awk '$1 ~ /^.i/ { print $2, $3 }' "$record/packages-after.txt") > "$record/packages-diff.txt"
changed=$(grep '^[<>]' "$record/packages-diff.txt" | awk '{ print $2 }' | sort -u | paste -sd ' ')
printf 'PACKAGES_CHANGED=%s\n' "${changed:-none}"
[[ -z $(grep '^[<>]' "$record/packages-diff.txt" | awk '{ print $2 }' | grep -vx "$PKG") ]] \
    && check ONLY_THIS_PACKAGE PASS || check ONLY_THIS_PACKAGE FAIL
dpkg --audit > "$record/dpkg-audit.txt" 2>&1
[[ ! -s $record/dpkg-audit.txt ]] && check DPKG_AUDIT PASS || check DPKG_AUDIT FAIL
dpkg --verify "$PKG" > "$record/dpkg-verify.txt" 2>&1
grep -vE '^missing +/usr/share/doc/' "$record/dpkg-verify.txt" > "$record/dpkg-verify-files.txt"
[[ ! -s $record/dpkg-verify-files.txt ]] && check FILES_INTACT PASS \
    || { head -n 5 "$record/dpkg-verify-files.txt"; check FILES_INTACT FAIL; }

# 1. The library path: nano-trt82's first, 8.5's and 8.6's still there.
ldconfig -p > "$record/ldconfig.txt" 2>&1
bad=()
for soname in "${SHARED[@]}"; do
    first=$(awk -v n="$soname" '$1 == n && /AArch64/ { print $NF; exit }' "$record/ldconfig.txt")
    printf 'FIRST %s => %s\n' "$soname" "${first:-none}"
    [[ $first == "$DIR/lib/$soname" ]] || bad+=("$soname first from ${first:-nowhere}")
    awk -v n="$soname" -v p="$LIBDIR/$soname" '$1 == n && $NF == p { found = 1 } END { exit !found }' "$record/ldconfig.txt" \
        || bad+=("no $LIBDIR/$soname")
done
(( ${#bad[@]} == 0 )) && check LIBRARY_PATH PASS || check LIBRARY_PATH "FAIL ${bad[*]}"

# 2 and 3, as the account: the versions each way finds, and where it found them.
as_owner() {
    runuser -u "$owner" -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$home" USER="$owner" LOGNAME="$owner" \
        LANG=C.UTF-8 "$@"
}
versions='
import ctypes
def where(name):
    for line in open("/proc/self/maps"):
        path = line.split()[-1]
        if path.rsplit("/", 1)[-1].startswith(name):
            return path
    return "?"
nv = ctypes.CDLL("libnvinfer.so.8")
dnn = ctypes.CDLL("libcudnn.so.8")
dnn.cudnnGetVersion.restype = ctypes.c_size_t
print(nv.getInferLibVersion(), where("libnvinfer.so"), dnn.cudnnGetVersion(), where("libcudnn.so"))
'
loaded() {  # NAME WANT_TRT WANT_CUDNN FOLDER then the command's prefix
    local name=$1 trt=$2 dnn=$3 dir=$4 out
    shift 4
    out=$(as_owner "$@" python3 -I -c "$versions" 2> "$record/$name-versions.txt")
    printf '%s: TENSORRT=%s from %s CUDNN=%s from %s\n' "$name" $out
    read -r got_trt trt_path got_dnn dnn_path <<< "$out"
    [[ ${got_trt:-} == "$trt" && ${got_dnn:-} == "$dnn" && ${trt_path%/*} == "$dir" && ${dnn_path%/*} == "$dir" ]]
}
loaded default 8201 8201 "$DIR/lib" && check DEFAULT PASS || check DEFAULT FAIL
loaded trt85 8502 8600 "$LIBDIR" nano-trt85 && check NANO_TRT85 PASS || check NANO_TRT85 FAIL
banner() { grep -m 1 -oE 'TensorRT v[0-9]+' <<< "$1" || echo none; }
help82=$(as_owner trtexec --help 2>&1)
help85=$(as_owner nano-trt85 "$TRTEXEC85" --help 2>&1)
printf 'TRTEXEC=%s (%s)\nTRTEXEC85=%s (nano-trt85 %s)\n' "$(banner "$help82")" "$(readlink -f /usr/bin/trtexec)" \
    "$(banner "$help85")" "$TRTEXEC85"
[[ $(banner "$help82") == 'TensorRT v8201' && $(banner "$help85") == 'TensorRT v8502' ]] \
    && check TRTEXEC PASS || check TRTEXEC FAIL
exit 0

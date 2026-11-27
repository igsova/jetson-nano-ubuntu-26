#!/usr/bin/env bash
# Destructive restore of a verified image to an explicitly identified card.
set -euo pipefail
umask 077
usage() {
    cat <<'EOF'
Usage: restore-card.sh --image FILE --sha256 HASH --device DEVICE \
  --expected-bytes BYTES --expected-diskseq SEQUENCE

Erases the selected card. Requires a whole, unmounted USB/MMC device whose
current capacity and kernel disk sequence match the supplied values, and an
authenticated image of exactly that capacity. Verifies the image hash before
writing and compares every byte read back afterward with aligned O_DIRECT
reads. Copy counters exclude the final flush and verification. No sudo or unmounting
is performed by this helper.
EOF
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
image='' hash='' device='' expected='' sequence=''
while (($#)); do
    case "$1" in
        --image|--sha256|--device|--expected-bytes|--expected-diskseq)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --image) image=$2 ;; --sha256) hash=$2 ;; --device) device=$2 ;;
                --expected-bytes) expected=$2 ;; --expected-diskseq) sequence=$2 ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$image" && -n "$device" && "$hash" =~ ^[0-9a-f]{64}$ && "$expected" =~ ^[1-9][0-9]*$ && "$sequence" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
for program in lsblk python3 dd sfdisk stat readlink mktemp tee; do
    command -v "$program" >/dev/null || die "Required command unavailable: $program"
done
image=$(readlink -f -- "$image")
device=$(readlink -f -- "$device")
[[ -f "$image" && ! -b "$image" ]] || die 'Image must be an ordinary file'
[[ -b "$device" ]] || die 'Target must be a whole card block device'
[[ $(stat --format=%s "$image") == "$expected" ]] || die 'Image capacity does not match target capacity'
inspect() { lsblk --tree --bytes --json --output PATH,SIZE,TYPE,TRAN,MODEL,SERIAL,RO,MAJ:MIN,MOUNTPOINTS "$device"; }
# The card without its partitions: once written, the kernel may re-read the
# image's table (udev does when a written disk is closed), so later checks
# compare the card itself and require that nothing on it is mounted.
card_only() { lsblk --nodeps --bytes --json --output PATH,SIZE,TYPE,TRAN,MODEL,SERIAL,RO,MAJ:MIN,MOUNTPOINTS "$device"; }
unmounted() {
    inspect | python3 -c '
import json,sys
def check(n):
    if any(n.get("mountpoints") or []) or n["type"] not in ("disk","part"):
        sys.exit("Target has a mounted filesystem or active mapped device")
    for child in n.get("children",[]): check(child)
for d in json.load(sys.stdin)["blockdevices"]: check(d)
'
}
inventory=$(inspect)
card=$(card_only)
python3 -c '
import json,sys
roots=json.load(sys.stdin)["blockdevices"]
if len(roots)!=1 or roots[0]["type"]!="disk":
    sys.exit("Target must be one whole disk, not a partition")
d=roots[0]
if int(d["size"])!=int(sys.argv[1]) or d.get("tran") not in ("usb","mmc") or d.get("ro"):
    sys.exit("Target capacity/transport/writability does not match the identified card")
def check(n):
    if any(n.get("mountpoints") or []) or n["type"] not in ("disk","part"):
        sys.exit("Target has a mounted filesystem or active mapped device")
    for child in n.get("children",[]): check(child)
check(d)
' "$expected" <<< "$inventory"
sequence_file="/sys/class/block/${device##*/}/diskseq"
[[ -r "$sequence_file" && $(cat "$sequence_file") == "$sequence" ]] || die 'Target was replaced or reinserted; identify it again'
[[ -r "$device" && -w "$device" ]] || die 'Temporary read/write access to the identified target is required'
image_identity=$(stat --format='%d:%i:%s:%y:%z' "$image")
printf 'Checking source image SHA-256 before erasing %s\n' "$device"
python3 -c '
import hashlib,sys
d=hashlib.sha256()
with open(sys.argv[1],"rb") as stream:
    for chunk in iter(lambda:stream.read(4*1024*1024),b""): d.update(chunk)
if d.hexdigest()!=sys.argv[2]: sys.exit("Image SHA-256 mismatch; target not written")
print("Image SHA-256: PASS")
' "$image" "$hash"
sfdisk --verify "$image"
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$project/artifacts/restores"
run=$(mktemp -d "$project/artifacts/restores/$(date -u +%Y%m%dT%H%M%SZ)-card-XXXXXX")
printf '%s\n' "$inventory" > "$run/target-before.json"
printf 'image=%s\nsha256=%s\nbytes=%s\ntarget=%s\ndiskseq=%s\nstarted_utc=%s\n' \
    "$image" "$hash" "$expected" "$device" "$sequence" "$(date -u +%FT%TZ)" > "$run/restore.txt"
dd --version | head -n 1 >> "$run/restore.txt"
[[ $(inspect) == "$inventory" && $(cat "$sequence_file") == "$sequence" && $(stat --format='%d:%i:%s:%y:%z' "$image") == "$image_identity" ]] || die 'Image or target changed during preflight'
printf 'Restoring verified image to the identified card: %s\nTransfer counters exclude the final flush and readback.\n' "$device"
dd if="$image" of="$device" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
printf 'write_and_flush=PASS\n' >> "$run/restore.txt"
[[ $(cat "$sequence_file") == "$sequence" && $(stat --format='%d:%i:%s:%y:%z' "$image") == "$image_identity" ]] || die 'Image or target changed during writing'
[[ $(card_only) == "$card" ]] && unmounted || die 'Target state changed during writing'
printf 'Reading back and comparing all %s bytes\n' "$expected"
python3 "$project/scripts/host/verify-card.py" --image "$image" --sha256 "$hash" \
    --device "$device" --expected-bytes "$expected" --expected-diskseq "$sequence" | \
    tee "$run/readback.log"
[[ $(cat "$sequence_file") == "$sequence" && $(card_only) == "$card" ]] && unmounted || die 'Target state changed during readback'
inspect > "$run/target-after.json"
sfdisk --verify "$device" > "$run/target-gpt-verification.txt"
printf 'completed_utc=%s\nreadback=PASS\nstatus=PASS\n' "$(date -u +%FT%TZ)" >> "$run/restore.txt"
printf 'Card write/readback verified: %s\nNano boot and CUDA tests are still required.\n' "$run"

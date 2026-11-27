#!/usr/bin/env bash
# Read an offline card into an ordinary file; never write to a block device.
set -euo pipefail
umask 077

usage() {
    cat <<'EOF'
Usage: backup-card.sh --device DEVICE --expected-bytes BYTES [--dest DIR]

The Nano must be shut down and its baseline card connected to this computer.
Identify the whole card and unmount all its partitions first. The script
requires read access to DEVICE and writes a raw image, SHA-256 and inventory
under ignored artifacts/backups/, or under DIR (an existing folder, for
example on a larger disk). It does not obtain administrator access,
unmount filesystems, or flash a card.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
device=''
expected=''
dest=''
while (($#)); do
    case "$1" in
        --device) (($# >= 2)) || die 'Missing --device value'; device=$2; shift 2 ;;
        --expected-bytes) (($# >= 2)) || die 'Missing --expected-bytes value'; expected=$2; shift 2 ;;
        --dest) (($# >= 2)) || die 'Missing --dest value'; dest=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$device" && "$expected" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
for command in lsblk python3 dd sha256sum stat df readlink mktemp; do
    command -v "$command" >/dev/null || die "Required command unavailable: $command"
done
device=$(readlink -f -- "$device")
[[ -b "$device" ]] || die 'The source must be an existing block device'

# Check the entire source tree, not just the first partition. Capture the
# kernel's disk sequence too, so replacing a card between checks is detected.
inspect() {
    lsblk --tree --bytes --json --output PATH,SIZE,TYPE,TRAN,MODEL,SERIAL,MAJ:MIN,MOUNTPOINTS "$device"
}
inventory=$(inspect)
python3 -c '
import json, sys
d = json.load(sys.stdin)["blockdevices"]
if len(d) != 1 or d[0]["type"] != "disk":
    sys.exit("Source must be one whole disk, not a partition")
disk = d[0]
if int(disk["size"]) != int(sys.argv[1]):
    sys.exit("Source capacity does not match --expected-bytes")
if disk.get("tran") not in ("usb", "mmc"):
    sys.exit("Source must be a USB/MMC card, not an internal host disk")
def check(node):
    if any(node.get("mountpoints") or []):
        sys.exit("Unmount every source partition before backing up")
    if node["type"] not in ("disk", "part"):
        sys.exit("Source has an active mapped device")
    for child in node.get("children", []):
        check(child)
check(disk)
' "$expected" <<< "$inventory"
sequence_file="/sys/class/block/${device##*/}/diskseq"
[[ -r "$sequence_file" ]] || die 'Kernel disk-sequence information unavailable'
sequence=$(cat "$sequence_file")
[[ -r "$device" ]] || die "Read access required for $device; grant read access in your own terminal"

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ -n "$dest" ]]; then
    [[ -d "$dest" && -w "$dest" ]] || die "--dest must be an existing folder you can write: $dest"
    backup_root=$(readlink -f -- "$dest")
else
    backup_root="$project/artifacts/backups"
    mkdir -p -- "$backup_root"
fi
available=$(df --block-size=1 --output=avail "$backup_root" | tail -n 1 | tr -d ' ')
((available >= expected + 1073741824)) || die 'Insufficient space for the image plus 1 GiB headroom'
run=$(mktemp -d "$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-card-XXXXXX")
printf '%s\n' "$inventory" > "$run/source-lsblk.json"
printf 'source=%s\nbytes=%s\ndiskseq=%s\nstarted_utc=%s\n' \
    "$device" "$expected" "$sequence" "$(date -u +%FT%TZ)" > "$run/backup.txt"
printf 'Reading %s bytes from %s into %s\n' "$expected" "$device" "$run"
trap 'printf "Backup incomplete; retained diagnostic files in %s\n" "$run" >&2' ERR
before=$(inspect)
[[ "$before" == "$inventory" && $(cat "$sequence_file") == "$sequence" ]] || die 'Source changed before reading'
dd if="$device" of="$run/card.img.partial" bs=4M iflag=fullblock,count_bytes \
    count="$expected" status=progress conv=fsync
[[ $(stat --format=%s "$run/card.img.partial") == "$expected" ]] || die 'Image size does not match the whole card'
[[ $(inspect) == "$inventory" && $(cat "$sequence_file") == "$sequence" ]] || die 'Source changed while reading'
mv -- "$run/card.img.partial" "$run/card.img"
(
    cd -- "$run"
    sha256sum card.img > SHA256SUMS
    sha256sum --check SHA256SUMS
)
printf 'completed_utc=%s\nstatus=PASS\n' "$(date -u +%FT%TZ)" >> "$run/backup.txt"
trap - ERR
printf 'Backup verified: %s\nRestore instructions: %s/docs/BACKUP.md\n' "$run" "$project"

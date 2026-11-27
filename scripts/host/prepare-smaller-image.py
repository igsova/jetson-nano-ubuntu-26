#!/usr/bin/env python3
"""Shrink a copy of the Nano's APP filesystem to fit a smaller card.

Only ordinary files are read/written. No loop devices, sudo, mounts or card
writes are used. The original full-card backup is never changed.
"""
import argparse
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time

CHUNK = 4 * 1024 * 1024
PROJECT = Path(__file__).resolve().parents[2]


def command(arguments, log, allowed=(0,)):
    result = subprocess.run(arguments, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True,
                            env={**os.environ, "LC_ALL": "C"})
    log.write("$ " + " ".join(map(str, arguments)) + "\n" + result.stdout)
    log.flush()
    if result.returncode not in allowed:
        raise RuntimeError("Command failed; see preparation.log: " + str(arguments[0]))
    return result.stdout


def table(path):
    return json.loads(subprocess.check_output(["sfdisk", "--json", str(path)], text=True))["partitiontable"]


def range_hash(stream, start, size):
    stream.seek(start)
    digest = hashlib.sha256()
    remaining = size
    while remaining:
        data = stream.read(min(CHUNK, remaining))
        if not data:
            raise RuntimeError("Unexpected end of file")
        digest.update(data)
        remaining -= len(data)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--target-bytes", type=int, required=True)
    args = parser.parse_args()
    for program in ("sfdisk", "sgdisk", "e2fsck", "resize2fs", "dumpe2fs"):
        if not shutil.which(program):
            parser.error("Required host tool unavailable: " + program)
    if not args.source.is_file():
        parser.error("Source must be an ordinary full-card image file")
    source = args.source.resolve()
    source_size = source.stat().st_size
    if len(args.source_sha256) != 64 or any(c not in "0123456789abcdef" for c in args.source_sha256):
        parser.error("Expected source SHA-256 must contain 64 lowercase hexadecimal characters")
    if not 0 < args.target_bytes < source_size or args.target_bytes % 512:
        parser.error("Target must be smaller than the source and a multiple of 512 bytes")
    original = table(source)
    partitions = original["partitions"]
    if original["label"] != "gpt" or original["sectorsize"] != 512 or len(partitions) != 14:
        parser.error("Expected the recorded 14-partition, 512-byte-sector Nano GPT layout")
    app = partitions[0]
    if app["name"] != "APP" or app.get("attrs"):
        parser.error("Expected APP as partition 1 without special GPT attributes")
    offset, length = app["start"] * 512, app["size"] * 512
    if any((p["start"] + p["size"]) * 512 > offset for p in partitions[1:]):
        parser.error("Expected every firmware partition to precede APP")
    with source.open("rb") as stream:
        stream.seek(512)
        header = stream.read(512)
    if header[:8] != b"EFI PART":
        parser.error("Missing GPT header")
    entry_count, entry_size = struct.unpack_from("<II", header, 80)
    tail = ((entry_count * entry_size + 511) // 512 + 1) * 512
    available = shutil.disk_usage(PROJECT / "artifacts").free
    if available < length + 1024**3:
        parser.error("Not enough room for temporary APP extraction plus 1 GiB")

    os.umask(0o077)
    parent = PROJECT / "artifacts/build"
    parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = Path(tempfile.mkdtemp(prefix=stamp + "-smaller-", dir=parent))
    (run / "source-gpt.json").write_text(json.dumps(original, indent=2) + "\n")
    filesystem = run / "app.ext4.partial"
    print("Preparing smaller image in", run, flush=True)
    print("Extracting APP while verifying the complete source hash", flush=True)
    source_digest = hashlib.sha256()
    zero = bytes(CHUNK)
    position = 0
    reported = time.monotonic()
    with source.open("rb") as src, filesystem.open("wb") as dst:
        while data := src.read(CHUNK):
            source_digest.update(data)
            lower = max(0, offset - position)
            upper = min(len(data), offset + length - position)
            if upper > lower:
                piece = data[lower:upper]
                if piece == zero[:len(piece)]:
                    dst.seek(len(piece), os.SEEK_CUR)
                else:
                    dst.write(piece)
            position += len(data)
            if time.monotonic() - reported >= 20:
                print(f"Source read: {100 * position / source_size:.1f}%", flush=True)
                reported = time.monotonic()
        dst.truncate(length)
        dst.flush()
        os.fsync(dst.fileno())
    if position != source_size or source_digest.hexdigest() != args.source_sha256:
        raise RuntimeError("Source size/hash mismatch; derived files are not accepted")
    print("Source hash: PASS; checking and shrinking the copied filesystem", flush=True)
    with (run / "preparation.log").open("w") as log:
        command(["e2fsck", "-f", "-p", str(filesystem)], log, allowed=(0, 1))
        stats = command(["dumpe2fs", "-h", str(filesystem)], log)
        fields = dict(line.split(":", 1) for line in stats.splitlines() if ":" in line)
        block_size = int(fields["Block size"].strip())
        if block_size != 4096:
            raise RuntimeError("Expected the baseline 4096-byte ext4 block size")
        blocks = (args.target_bytes - offset - tail) // block_size
        if blocks >= int(fields["Block count"].strip()) or blocks <= 0:
            raise RuntimeError("Requested target does not shrink APP")
        command(["resize2fs", str(filesystem), str(blocks)], log)
        command(["e2fsck", "-f", "-p", str(filesystem)], log, allowed=(0, 1))
        resized_stats = command(["dumpe2fs", "-h", str(filesystem)], log)
        new_fields = dict(line.split(":", 1) for line in resized_stats.splitlines() if ":" in line)
        if int(new_fields["Block count"].strip()) != blocks or filesystem.stat().st_size != blocks * block_size:
            raise RuntimeError("Resized filesystem size mismatch")
        for field in ("Filesystem UUID", "Filesystem features"):
            if fields[field].strip() != new_fields[field].strip():
                raise RuntimeError("Filesystem identity/features changed unexpectedly")
        needed = filesystem.stat().st_blocks * 512 + offset + 1024**3
        if shutil.disk_usage(run).free < needed:
            raise RuntimeError("Not enough space to assemble the sparse derived image")
        image = run / "card-smaller.img.partial"
        print("Assembling sparse image and preserving the firmware partitions", flush=True)
        with source.open("rb") as src, filesystem.open("rb", buffering=0) as fs, image.open("w+b") as dst:
            dst.truncate(source_size)
            dst.write(src.read(offset))
            cursor = 0
            while cursor < filesystem.stat().st_size:
                try:
                    start = os.lseek(fs.fileno(), cursor, os.SEEK_DATA)
                except OSError as error:
                    if error.errno == errno.ENXIO:
                        break
                    raise
                end = os.lseek(fs.fileno(), start, os.SEEK_HOLE)
                fs.seek(start)
                dst.seek(offset + start)
                remaining = end - start
                while remaining:
                    data = fs.read(min(CHUNK, remaining))
                    if not data:
                        raise RuntimeError("Unexpected end of temporary filesystem")
                    dst.write(data)
                    remaining -= len(data)
                cursor = end
            src.seek(source_size - tail)
            dst.seek(source_size - tail)
            dst.write(src.read(tail))
            dst.flush()
            os.fsync(dst.fileno())
        sectors = blocks * block_size // 512
        command(["sgdisk", "--delete=1", f"--new=1:{app['start']}:{app['start'] + sectors - 1}",
                 f"--typecode=1:{app['type']}", f"--partition-guid=1:{app['uuid']}",
                 "--change-name=1:APP", str(image)], log)
        with image.open("r+b") as stream:
            stream.truncate(args.target_bytes)
        command(["sgdisk", "--move-second-header", str(image)], log)
        command(["sfdisk", "--verify", str(image)], log)
        derived = table(image)
        if derived["id"] != original["id"] or len(derived["partitions"]) != len(partitions):
            raise RuntimeError("GPT identity/partition count changed")
        for index, (old, new) in enumerate(zip(partitions, derived["partitions"])):
            old = {k: v for k, v in old.items() if k != "node"}
            new = {k: v for k, v in new.items() if k != "node"}
            if index == 0:
                old["size"] = sectors
            if old != new:
                raise RuntimeError("Unexpected GPT partition change")
        firmware = []
        with source.open("rb") as src, image.open("rb") as dst:
            for partition in partitions[1:]:
                start, size = partition["start"] * 512, partition["size"] * 512
                expected = range_hash(src, start, size)
                if range_hash(dst, start, size) != expected:
                    raise RuntimeError("Firmware partition payload changed")
                firmware.append({"name": partition["name"], "sha256": expected})
            with filesystem.open("rb") as fs:
                app_digest = range_hash(fs, 0, blocks * block_size)
            if range_hash(dst, offset, blocks * block_size) != app_digest:
                raise RuntimeError("Assembled APP bytes differ from the resized filesystem")
            image_digest = range_hash(dst, 0, args.target_bytes)
        final = run / "card-smaller.img"
        image.rename(final)
        (run / "SHA256SUMS").write_text(image_digest + "  card-smaller.img\n")
        (run / "derived-gpt.json").write_text(json.dumps(derived, indent=2) + "\n")
        report = {"status": "PASS", "source_sha256": args.source_sha256,
                  "image_bytes": args.target_bytes, "image_sha256": image_digest,
                  "app_bytes": blocks * block_size, "app_sha256": app_digest, "firmware": firmware,
                  "filesystem_uuid": fields["Filesystem UUID"].strip(),
                  "filesystem_features": fields["Filesystem features"].strip(),
                  "card_write": "NOT PERFORMED", "nano_boot": "NOT TESTED"}
        (run / "preparation.json").write_text(json.dumps(report, indent=2) + "\n")
        filesystem.unlink()
    print("Derived image prepared and verified:", final, flush=True)
    print("SHA-256:", image_digest, flush=True)
    print("Card write and Nano boot: NOT PERFORMED", flush=True)


if __name__ == "__main__":
    main()

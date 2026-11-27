#!/usr/bin/env python3
"""Compare an unmounted card with an image using aligned Linux O_DIRECT reads.

The card is opened read-only. There is no buffered fallback, flashing, mounting,
sudo or partition-table reload. Raw records are saved under ignored artifacts/.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import mmap
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time

CHUNK = 4 * 1024 * 1024
PROJECT = Path(__file__).resolve().parents[2]


def inventory(device):
    return json.loads(subprocess.check_output([
        "lsblk", "--tree", "--bytes", "--json", "--output",
        "PATH,SIZE,TYPE,TRAN,MODEL,SERIAL,RO,MAJ:MIN,MOUNTPOINTS", str(device)
    ], text=True))


def image_identity(path):
    info = path.stat()
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def compare_direct(device, image, size, progress=None):
    """Read exactly size bytes with a page-aligned anonymous mmap buffer."""
    digest = hashlib.sha256()
    descriptor = os.open(device, os.O_RDONLY | os.O_DIRECT | os.O_CLOEXEC)
    try:
        with mmap.mmap(-1, CHUNK) as buffer, open(image, "rb") as expected:
            view = memoryview(buffer)
            try:
                offset = 0
                while offset < size:
                    wanted = min(CHUNK, size - offset)
                    part = view[:wanted]
                    try:
                        received = os.preadv(descriptor, [part], offset)
                        if received != wanted:
                            raise RuntimeError(f"Short direct read at byte {offset}: {received}/{wanted}")
                        actual = part.tobytes()
                    finally:
                        part.release()
                    reference = expected.read(wanted)
                    if actual != reference:
                        raise RuntimeError(f"Card/image mismatch in block starting at byte {offset}")
                    digest.update(actual)
                    offset += wanted
                    if progress:
                        progress(offset, size)
            finally:
                view.release()
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--device", type=Path, required=True)
    parser.add_argument("--expected-bytes", type=int, required=True)
    parser.add_argument("--expected-diskseq", type=int, required=True)
    args = parser.parse_args()
    if len(args.sha256) != 64 or any(c not in "0123456789abcdef" for c in args.sha256):
        parser.error("Expected SHA-256 must have 64 lowercase hexadecimal characters")
    image, device = args.image.resolve(), args.device.resolve()
    if not stat.S_ISREG(image.stat().st_mode) or image.stat().st_size != args.expected_bytes:
        parser.error("Image must be an ordinary file of exactly the expected capacity")
    if args.expected_bytes <= 0 or args.expected_bytes % 512:
        parser.error("Capacity must be a positive multiple of 512 bytes")
    if not stat.S_ISBLK(device.stat().st_mode):
        parser.error("Target must be a whole card block device")
    before = inventory(device)
    roots = before["blockdevices"]
    if len(roots) != 1 or roots[0]["type"] != "disk":
        parser.error("Expected one whole disk, not a partition")
    card = roots[0]
    if int(card["size"]) != args.expected_bytes or card.get("tran") not in ("usb", "mmc"):
        parser.error("Card capacity/transport does not match")

    def mounted(node):
        return any(node.get("mountpoints") or []) or node["type"] not in ("disk", "part") or \
            any(mounted(child) for child in node.get("children", []))

    def card_only(node):
        return {k: v for k, v in node.items() if k != "children"}

    if mounted(card):
        parser.error("Card has a mounted filesystem or active mapped device")
    sequence = Path("/sys/class/block") / device.name / "diskseq"

    def unchanged():
        if int(sequence.read_text()) != args.expected_diskseq:
            raise RuntimeError("Card was replaced/reinserted; identify it again")
        # The partitions may change: after a write the kernel may re-read the
        # new table (udev does when a written disk is closed).
        now = inventory(device)["blockdevices"]
        if len(now) != 1 or card_only(now[0]) != card_only(card) or mounted(now[0]) or \
                image_identity(image) != identity:
            raise RuntimeError("Card state or image changed during verification")

    identity = image_identity(image)
    unchanged()
    os.umask(0o077)
    parent = PROJECT / "artifacts/restore-readbacks"
    parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = Path(tempfile.mkdtemp(prefix=stamp + "-readback-", dir=parent))
    (run / "target-before.json").write_text(json.dumps(before, indent=2) + "\n")
    started = datetime.now(timezone.utc).isoformat()
    print("READBACK_DIR=" + str(run), flush=True)
    print("Read-only O_DIRECT comparison; aligned buffers; no buffered fallback", flush=True)
    last_report = time.monotonic()

    def progress(done, total):
        nonlocal last_report
        if time.monotonic() - last_report >= 20 or done == total:
            print(f"Readback: {done}/{total} bytes ({100 * done / total:.1f}%)", flush=True)
            last_report = time.monotonic()

    digest = compare_direct(device, image, args.expected_bytes, progress)
    if digest != args.sha256:
        raise RuntimeError("Readback/image SHA-256 differs from the pinned prepared image")
    unchanged()
    gpt = subprocess.check_output(["sfdisk", "--verify", str(device)], text=True)
    (run / "target-gpt-verification.txt").write_text(gpt)
    report = {"status": "PASS", "compared_bytes": args.expected_bytes,
              "sha256": digest, "device": str(device), "diskseq": args.expected_diskseq,
              "image": str(image), "started_utc": started,
              "completed_utc": datetime.now(timezone.utc).isoformat(),
              "method": "Read-only O_DIRECT, page-aligned mmap/preadv, complete byte comparison",
              "buffered_fallback": False, "nano_boot": "NOT TESTED"}
    (run / "readback.json").write_text(json.dumps(report, indent=2) + "\n")
    print("READBACK=PASS SHA256=" + digest, flush=True)


if __name__ == "__main__":
    main()

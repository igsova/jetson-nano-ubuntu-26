#!/usr/bin/env python3
"""Hash raw I420 frames as GStreamer writes them, or compare two hash lists.

Usage: python3 -I frame_hashes.py WIDTH HEIGHT LIST [KEEP_FILE KEEP_FRAMES [save-rows|check-rows ROWS]] < FRAMES
       python3 -I frame_hashes.py --compare REFERENCE_LIST OUTPUT_LIST

The first form reads I420 frames (no row padding) from standard input, a
pipe or a FIFO that filesink writes, so a long decode needs no disk space. It
writes one line a frame to LIST: the frame's number, the first 32 hex digits
of its SHA-256, then shorter hashes of its Y plane and of the inner rows of
its U and V planes (all but the first and last row). It keeps the first
KEEP_FRAMES frames in KEEP_FILE for frame_check.py and frame_diff.py. It
prints FRAMES=N, and PARTIAL=BYTES if the input ends inside a frame (which
it does not hash).

For a converter that moves the colour half a row, as JetPack 4's nvvidconv
did to NVDEC's frames on the Nano (each U and V row averaged with the row
below), save-rows writes ROWS (zlib-compressed, about a tenth of the frames'
size): each pair of neighbouring U and V rows averaged, rounded down, and
where that average was a half. check-rows reads it while hashing the
output, and for each way (each inner row averaged with the row above or
below) adds to each line how many U and V values were not that average
rounded either way, how many were off by more than 1, how many halves were
rounded up and down, and the largest difference.

The second form compares two lists frame by frame and prints FRAMES (both
counts), IDENTICAL, the first differing frames, Y_IDENTICAL, CHROMA_IDENTICAL
(the inner rows), CHROMA_HALF_ROW for each way checked, MATCH (identical;
luma+chroma-half-row-<way> when Y is identical in every frame and every U
and V value is within 1 of the reference's average for that way in every
frame; luma; or none) and HASHES=PASS when the lists match in count and
every frame, else HASHES=FAIL; it exits 0 or 1.
Pure Python, for probe-l4t-codec.sh on the Nano.
"""
import hashlib
import struct
import sys
import zlib

WAYS = ('below', 'above')
MASKS = {}


def masks(n):
    """Integers with each of n bytes 0x7f, 0x80 and 0x01, for byte-by-byte work on whole planes."""
    if n not in MASKS:
        MASKS[n] = tuple(int.from_bytes(bytes([b]) * n, 'big') for b in (0x7f, 0x80, 0x01))
    return MASKS[n]


def nonzero(v, n):
    """Bit 7 of each byte set where that byte of v is not zero."""
    m7f, m80, _ = masks(n)
    return (((v & m7f) + m7f) | v) & m80


def short(*parts):
    h = hashlib.sha256()
    for part in parts:
        h.update(part)
    return h.hexdigest()[:16]


def chroma_of(frame, width, height):
    ysize, csize = width * height, (width // 2) * (height // 2)
    return frame[ysize:ysize + csize], frame[ysize + csize:]


def pair_rows(frame, width, height):
    """Each pair of neighbouring U and V rows averaged rounding down, and where the sum was odd (1)."""
    cw, ch = width // 2, height // 2
    n = (ch - 1) * cw
    m7f, _, m01 = masks(n)
    low, odd = [], []
    for plane in chroma_of(frame, width, height):
        x, y = int.from_bytes(plane[:n], 'big'), int.from_bytes(plane[cw:], 'big')
        low.append(((x & y) + (((x ^ y) >> 1) & m7f)).to_bytes(n, 'big'))
        odd.append(((x ^ y) & m01).to_bytes(n, 'big'))
    return b''.join(low + odd)


def check_rows(frame, width, height, rows):
    """For each way, the output's inner U and V rows against the reference's averages: a list token."""
    cw, ch = width // 2, height // 2
    n, inner = (ch - 1) * cw, (ch - 2) * cw
    _, m80, _ = masks(inner)
    tokens = []
    for way in WAYS:
        start = cw if way == 'below' else 0  # pair r is rows r and r + 1
        off = big = up = down = worst = 0
        for p, plane in enumerate(chroma_of(frame, width, height)):
            low_b = rows[p * n + start:p * n + start + inner]
            odd_b = rows[(2 + p) * n + start:(2 + p) * n + start + inner]
            got_b = plane[cw:cw + inner]
            got, low, odd = (int.from_bytes(b, 'big') for b in (got_b, low_b, odd_b))
            not_low, not_high = nonzero(got ^ low, inner), nonzero(got ^ (low + odd), inner)
            halves = odd << 7
            up += ((m80 ^ not_high) & halves).bit_count()
            down += ((m80 ^ not_low) & halves).bit_count()
            bad = not_low & not_high
            if bad:
                off += bad.bit_count()
                flags = (bad >> 7).to_bytes(inner, 'big')
                i = flags.find(1)
                while i >= 0:
                    twice = abs(2 * got_b[i] - 2 * low_b[i] - odd_b[i])
                    worst = max(worst, twice)
                    big += twice > 2
                    i = flags.find(1, i + 1)
        tokens.append(f'{way}:{off}:{big}:{up}:{down}:{worst}')
    return tokens


def read_frames(width, height, listing, keep_file=None, keep_frames=0, mode=None, rows_file=None):
    if width % 2 or height % 2 or height < 6:
        raise SystemExit('I420 needs an even width and height')
    size = width * height * 3 // 2
    ysize, cw, ch = width * height, width // 2, height // 2
    source = sys.stdin.buffer
    count = 0
    keep = open(keep_file, 'wb') if keep_file else None
    rows = open(rows_file, 'wb' if mode == 'save-rows' else 'rb') if mode else None
    with open(listing, 'w') as out:
        while True:
            frame = bytearray()
            while len(frame) < size:
                chunk = source.read(size - len(frame))
                if not chunk:
                    break
                frame += chunk
            if len(frame) < size:
                if frame:
                    print(f'PARTIAL={len(frame)}')
                break
            frame = bytes(frame)
            u, v = chroma_of(frame, width, height)
            line = [hashlib.sha256(frame).hexdigest()[:32], short(frame[:ysize]),
                    short(u[cw:(ch - 1) * cw], v[cw:(ch - 1) * cw])]
            if mode == 'save-rows':
                packed = zlib.compress(pair_rows(frame, width, height), 1)
                rows.write(struct.pack('>I', len(packed)) + packed)
            elif mode == 'check-rows':
                head = rows.read(4)
                if len(head) == 4:
                    line += check_rows(frame, width, height, zlib.decompress(rows.read(struct.unpack('>I', head)[0])))
            out.write(f"{count} {' '.join(line)}\n")
            if keep and count < keep_frames:
                keep.write(frame)
            count += 1
    for f in (keep, rows):
        if f:
            f.close()
    print(f'FRAMES={count}')
    return 0


def load(path):
    try:
        with open(path) as f:
            return [line.split()[1:] for line in f if line.strip()]
    except OSError as e:
        raise SystemExit(f'HASHES=FAIL cannot read {path}: {e}')


def compare(reference, output):
    a, b = load(reference), load(output)
    if any(len(x) < 3 for x in a + b):
        raise SystemExit('HASHES=FAIL a list has a line without its hashes')
    same = sum(x[0] == y[0] for x, y in zip(a, b))
    differ = [i for i, (x, y) in enumerate(zip(a, b)) if x[0] != y[0]]
    whole = len(a) == len(b) and len(a) > 0
    print(f'FRAMES reference={len(a)} output={len(b)}')
    print(f'IDENTICAL={same}')
    if differ:
        print(f"DIFFERING first={','.join(map(str, differ[:10]))} count={len(differ)}")
    ok = whole and not differ
    match = 'identical' if ok else 'none'
    if not ok:
        luma = sum(x[1] == y[1] for x, y in zip(a, b))
        print(f'Y_IDENTICAL={luma}')
        print(f'CHROMA_IDENTICAL={sum(x[2] == y[2] for x, y in zip(a, b))} (all but the first and last rows)')
        if whole and luma == len(a):
            match = 'luma'
        for way in WAYS:
            found = [list(map(int, t.split(':')[1:])) for y in b for t in y[3:] if t.split(':')[0] == way]
            if not found:
                continue
            off, big, up, down = (sum(f[k] for f in found) for k in range(4))
            worst = max(f[4] for f in found)
            within = sum(f[1] == 0 for f in found)
            print(f'CHROMA_HALF_ROW {way} frames={len(found)} within_one={within} not_rounded_average={off} '
                  f'off_more_than_one={big} halves_up={up} halves_down={down} largest_difference={worst / 2:g}')
            if match == 'luma' and len(found) == len(b) and within == len(b):
                match = f'luma+chroma-half-row-{way}'
    print(f'MATCH={match}')
    print(f"HASHES={'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def main(argv):
    if len(argv) == 3 and argv[0] == '--compare':
        return compare(argv[1], argv[2])
    if len(argv) in (3, 5, 7) and not argv[0].startswith('-'):
        if len(argv) == 7 and argv[5] not in ('save-rows', 'check-rows'):
            raise SystemExit(f'unknown rows mode {argv[5]} (save-rows or check-rows)')
        keep = (argv[3], int(argv[4])) if len(argv) >= 5 else (None, 0)
        rows = (argv[5], argv[6]) if len(argv) == 7 else (None, None)
        return read_frames(int(argv[0]), int(argv[1]), argv[2], *keep, *rows)
    print(__doc__.split('\n\n')[1], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Compare raw video frames written by GStreamer's filesink, plane by plane.

Usage: python3 -I frame_check.py FORMAT WIDTH HEIGHT REFERENCE OUTPUT MIN_PSNR [SAMPLES]

FORMAT is I420 (planes Y, U and V) or RGBA (channels R, G and B; alpha is
not compared), in GStreamer's default layout with no row padding. Both files
must hold the same whole number of frames. SAMPLES frames (default 6), spread
evenly from the first to the last, are compared in full; each plane's PSNR
must be at least MIN_PSNR dB (identical planes count as infinite). The output
must also not be flat where the reference is not, so a black or single-colour
output fails even against a dim reference.

Prints one line per plane and FRAME_CHECK=PASS or FRAME_CHECK=FAIL last; exits
0 or 1. Pure Python (no NumPy), for probe-l4t-video.sh on the Nano.
"""
import math
import operator
import os
import sys


def planes(fmt, width, height):
    """(name, offset, length, step) for each compared plane of one frame, and the frame size."""
    if fmt == 'I420':
        if width % 2 or height % 2:
            raise SystemExit('FRAME_CHECK=FAIL I420 needs an even width and height')
        y, c = width * height, (width // 2) * (height // 2)
        return [('Y', 0, y, 1), ('U', y, c, 1), ('V', y + c, c, 1)], y + 2 * c
    if fmt == 'RGBA':
        size = width * height * 4
        return [('R', 0, size, 4), ('G', 1, size, 4), ('B', 2, size, 4)], size
    raise SystemExit(f'FRAME_CHECK=FAIL unknown format {fmt} (I420 or RGBA)')


def stats(a, b):
    """Sum of squared differences and the largest difference between two equal-length byte strings."""
    if a == b:
        return 0, 0
    d = list(map(operator.sub, a, b))
    return sum(map(operator.mul, d, d)), max(map(abs, d))


def spread(values):
    """Population standard deviation of a byte string, from a 1-in-16 sample."""
    sample = values[::16]
    mean = sum(sample) / len(sample)
    return math.sqrt(sum((v - mean) ** 2 for v in sample) / len(sample))


def main(argv):
    if len(argv) not in (6, 7):
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    fmt, width, height, reference, output, min_psnr = argv[:6]
    width, height, min_psnr = int(width), int(height), float(min_psnr)
    samples = int(argv[6]) if len(argv) == 7 else 6
    layout, frame = planes(fmt, width, height)
    sizes = {}
    for label, path in (('reference', reference), ('output', output)):
        size = os.path.getsize(path) if os.path.exists(path) else -1
        if size <= 0 or size % frame:
            print(f'FRAME_CHECK=FAIL the {label} holds {size} bytes, not a whole number of '
                  f'{fmt} {width}x{height} frames ({frame} bytes each)')
            return 1
        sizes[label] = size // frame
    print(f"FRAMES reference={sizes['reference']} output={sizes['output']} frame_bytes={frame}")
    if sizes['reference'] != sizes['output']:
        print('FRAME_CHECK=FAIL the output has a different number of frames')
        return 1
    count = sizes['output']
    taken = min(samples, count)
    picks = sorted({round(i * (count - 1) / max(taken - 1, 1)) for i in range(taken)})
    totals = {name: [0, 0, 0] for name, _, _, _ in layout}  # squared error, values, largest difference
    flat = []
    identical = 0
    with open(reference, 'rb') as ref, open(output, 'rb') as out:
        for index in picks:
            ref.seek(index * frame)
            out.seek(index * frame)
            a, b = ref.read(frame), out.read(frame)
            identical += a == b
            for name, offset, length, step in layout:
                pa, pb = a[offset:offset + length:step], b[offset:offset + length:step]
                sse, largest = stats(pa, pb)
                total = totals[name]
                total[0] += sse
                total[1] += len(pa)
                total[2] = max(total[2], largest)
                if spread(pa) > 8 and spread(pb) < 1:
                    flat.append(f'{name}@{index}')
    print(f"COMPARED frames={','.join(map(str, picks))} identical={identical}")
    ok = True
    for name, (sse, values, largest) in totals.items():
        psnr = math.inf if sse == 0 else 10 * math.log10(255 ** 2 * values / sse)
        good = psnr >= min_psnr
        ok &= good
        shown = 'inf' if psnr == math.inf else f'{psnr:.1f}'
        print(f"PLANE {name} psnr_db={shown} max_diff={largest} {'PASS' if good else 'FAIL'} (needs {min_psnr:g})")
    if flat:
        print(f"FLAT_OUTPUT {' '.join(flat)} (the reference varies there)")
        ok = False
    print(f"FRAME_CHECK={'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

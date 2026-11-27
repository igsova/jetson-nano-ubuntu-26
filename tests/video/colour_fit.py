#!/usr/bin/env python3
"""Explain a failed colour test: which I420-to-RGB conversion an RGBA output fits best.

Usage: python3 -I colour_fit.py WIDTH HEIGHT I420_INPUT RGBA_OUTPUT [FRAME]
       python3 -I colour_fit.py --check DX MIN_PSNR FRAMES WIDTH HEIGHT I420_INPUT RGBA_OUTPUT

Converts frame FRAME (default 0) of the I420 input to RGB in software under
several models and compares each with the same frame of the output, channel
by channel (alpha is not compared), on every eighth row:
- chroma repeated to full size (nearest, as GStreamer's videoconvert does
  for this test), with the chroma moved by up to two pixels across and one
  row up or down: a converter that places chroma differently fits a move;
- chroma interpolated linearly, sited between luma pixels (centred) or on
  the even ones (cosited), not moved;
- nearest chroma, not moved, with the BT.709 matrix or full range instead
  of limited-range BT.601.

Prints the five models with the best worst-channel PSNR (ties go to the
smallest move), then the in-place nearest BT.601 model (the colour test's
reference) if it is not among them, then where the best model still misses
(ERROR_SIZES, and for pixels a channel misses by 64 or more BIG_ERRORS with
the even and odd columns, BIG_COLUMNS and BIG_ROWS: merged ranges, the most
missed first), and COLOUR_FIT last with the best model.
A move of +1,+0 means the output at column x shows the chroma the input has
at x+1. GStreamer 1.24's own videoconvert output fits its model at about
40 dB, not exactly, because it rounds differently. It explains a failure;
frame_check.py decides it, so it exits 0 whenever the files can be read.

With --check it tests one model instead: nearest chroma moved DX pixels
across (not up or down) with limited-range BT.601, on each frame in FRAMES
(comma-separated, as frame_check.py's COMPARED line gives them). Every
channel of every frame must reach MIN_PSNR. It prints one CHECK line per
frame and COLOUR_FIT_CHECK=PASS or FAIL last, and exits 0 or 1. The probe
uses DX 1: VIC takes the chroma of the pixel to the right on odd pixels,
where GStreamer's videoconvert takes the left one, both nearest.

Pure Python, no NumPy.
"""
import collections
import math
import os
import sys

ROW_STEP = 8
SHOWN = 5
BIG = 64  # a channel this far off is a big error, mapped by column and row
SIZES = ((0, 0), (1, 3), (4, 15), (16, 63), (BIG, 255))
RANGES = 8
# (luma scale, luma offset, R from V, G from U, G from V, B from U), per 8-bit value.
MATRICES = {
    'bt601': (1.164383, 16, 1.596027, -0.391762, -0.812968, 2.017232),
    'bt709': (1.164383, 16, 1.792741, -0.213249, -0.532909, 2.112402),
    'bt601-full': (1.0, 0, 1.402, -0.344136, -0.714136, 1.772),
}


def read_frame(path, size, index):
    """One frame's bytes, or exit with a message when the file cannot hold it."""
    length = os.path.getsize(path) if os.path.exists(path) else -1
    if length <= 0 or length % size or (index + 1) * size > length:
        raise SystemExit(f'COLOUR_FIT=UNREADABLE {path} holds {length} bytes, not frame {index} '
                         f'of {size}-byte frames')
    with open(path, 'rb') as f:
        f.seek(index * size)
        return f.read(size)


def chroma_terms(i420, width, height, matrix):
    """Per chroma row: the R, G and B terms the U and V samples add, at chroma size."""
    _, _, rv, gu, gv, bu = MATRICES[matrix]
    half, size = width // 2, width * height
    rows = []
    for k in range(height // 2):
        u = i420[size + k * half:size + (k + 1) * half]
        v = i420[size + size // 4 + k * half:size + size // 4 + (k + 1) * half]
        rows.append(([rv * (b - 128) for b in v],
                     [gu * (a - 128) + gv * (b - 128) for a, b in zip(u, v)],
                     [bu * (a - 128) for a in u]))
    return rows


def across(row, siting):
    """One chroma row brought to full width: repeated, or linear centred or cosited."""
    n = len(row)
    if siting == 'nearest':
        return [t for t in row for _ in (0, 1)]
    out = []
    for k in range(n):
        before, here, after = row[max(k - 1, 0)], row[k], row[min(k + 1, n - 1)]
        if siting == 'centred':
            out += [0.75 * here + 0.25 * before, 0.75 * here + 0.25 * after]
        else:
            out += [here, 0.5 * (here + after)]
    return out


def down(rows, y, siting):
    """The chroma for luma row y (rows already at full width): repeated or linear centred."""
    k = y >> 1
    if siting == 'nearest':
        return rows[k]
    other = rows[max(k - 1, 0)] if y % 2 == 0 else rows[min(k + 1, len(rows) - 1)]
    return [0.75 * a + 0.25 * b for a, b in zip(rows[k], other)]


def fit(i420, rgba, width, height, siting, move, matrix, cache, errors=None):
    """Worst and per-channel PSNR of one model against the output.

    With a list as ERRORS, also adds (x, y, worst channel's difference) for
    each compared pixel."""
    scale, offset = MATRICES[matrix][:2]
    dx, dy = move
    key = (siting, matrix)
    if key not in cache:
        terms = chroma_terms(i420, width, height, matrix)
        cache[key] = [[across(row[c], siting) for row in terms] for c in range(3)]
    full = cache[key]
    vertical = 'nearest' if siting == 'nearest' else 'centred'
    sse, count = [0, 0, 0], 0
    for y in range(2, height - 2, ROW_STEP):
        luma = [scale * (b - offset) for b in i420[y * width + 2:(y + 1) * width - 2]]
        line = rgba[y * width * 4:(y + 1) * width * 4]
        diffs = []
        for c in range(3):
            chroma = down(full[c], y + dy, vertical)[2 + dx:width - 2 + dx]
            out = line[c::4][2:width - 2]
            diffs.append([min(255, max(0, int(a + b + 0.5))) - o for a, b, o in zip(luma, chroma, out)])
            sse[c] += sum(d * d for d in diffs[c])
        if errors is not None:
            errors += ((x, y, max(abs(r), abs(g), abs(b))) for x, (r, g, b) in enumerate(zip(*diffs), 2))
        count += width - 4
    db = [math.inf if e == 0 else 10 * math.log10(255 ** 2 * count / e) for e in sse]
    return min(db), db


def shown(db):
    return 'inf' if db == math.inf else f'{db:.1f}'


def ranges(values, gap):
    """Values (repeated once per pixel) merged into ranges of values at most GAP
    apart, as FIRST-LAST:PIXELS, the most pixels first, at most RANGES of them."""
    counts = collections.Counter(values)
    merged = []
    for v in sorted(counts):
        if merged and v - merged[-1][1] <= gap:
            merged[-1][1:] = [v, merged[-1][2] + counts[v]]
        else:
            merged.append([v, v, counts[v]])
    merged.sort(key=lambda r: -r[2])
    text = ' '.join(f"{a}{'' if a == b else f'-{b}'}:{n}" for a, b, n in merged[:RANGES])
    return text + (f' (+{len(merged) - RANGES} more ranges)' if len(merged) > RANGES else '')


def misses(i420, rgba, width, height, model, cache):
    """Where a model misses: error sizes, and big errors by column and row."""
    errors = []
    fit(i420, rgba, width, height, *model, cache, errors)
    sizes = ' '.join(f"{lo}{'' if lo == hi else f'-{hi}' if hi < 255 else '+'}:"
                     f'{sum(lo <= e <= hi for _, _, e in errors)}' for lo, hi in SIZES)
    print(f'ERROR_SIZES {sizes} (pixels by their worst channel\'s difference)')
    big = [(x, y) for x, y, e in errors if e >= BIG]
    odd = sum(x % 2 for x, _ in big)
    print(f'BIG_ERRORS pixels={len(big)} of {len(errors)} even_columns={len(big) - odd} odd_columns={odd} '
          f'(a channel {BIG} or more off; columns 2-{width - 3}, every {ROW_STEP}th row from 2)')
    if big:
        print(f'BIG_COLUMNS {ranges([x for x, _ in big], 2)}')
        print(f'BIG_ROWS {ranges([y for _, y in big], ROW_STEP)}')


def check(argv):
    """--check DX MIN_PSNR FRAMES WIDTH HEIGHT I420_INPUT RGBA_OUTPUT: one model on several frames."""
    dx, min_db, frames = int(argv[0]), float(argv[1]), [int(f) for f in argv[2].split(',')]
    width, height = int(argv[3]), int(argv[4])
    if width % 2 or height % 2 or width < 8 or height < 8:
        raise SystemExit('COLOUR_FIT_CHECK=FAIL needs an even width and height of at least 8')
    if abs(dx) > 2:
        raise SystemExit('COLOUR_FIT_CHECK=FAIL the move must be within two pixels')
    ok, lowest = True, math.inf
    for index in frames:
        i420 = read_frame(argv[5], width * height * 3 // 2, index)
        rgba = read_frame(argv[6], width * height * 4, index)
        worst, db = fit(i420, rgba, width, height, 'nearest', (dx, 0), 'bt601', {})
        ok &= worst >= min_db
        lowest = min(lowest, worst)
        print(f'CHECK frame={index} R={shown(db[0])} G={shown(db[1])} B={shown(db[2])} worst={shown(worst)}')
    print(f"COLOUR_FIT_CHECK={'PASS' if ok else 'FAIL'} chroma=nearest move={dx:+d},+0 matrix=bt601 "
          f'frames={len(frames)} worst_db={shown(lowest)} (needs {min_db:g})')
    return 0 if ok else 1


def main(argv):
    if argv[:1] == ['--check']:
        if len(argv) != 8:
            print(__doc__.split('\n\n')[1], file=sys.stderr)
            return 2
        return check(argv[1:])
    if len(argv) not in (4, 5):
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    width, height = int(argv[0]), int(argv[1])
    index = int(argv[4]) if len(argv) == 5 else 0
    if width % 2 or height % 2 or width < 8 or height < 8:
        raise SystemExit('COLOUR_FIT=UNREADABLE needs an even width and height of at least 8')
    i420 = read_frame(argv[2], width * height * 3 // 2, index)
    rgba = read_frame(argv[3], width * height * 4, index)
    models = [('nearest', (dx, dy), 'bt601') for dy in (-1, 0, 1) for dx in (-2, -1, 0, 1, 2)]
    models += [('centred', (0, 0), 'bt601'), ('cosited', (0, 0), 'bt601'),
               ('nearest', (0, 0), 'bt709'), ('nearest', (0, 0), 'bt601-full')]
    cache, results = {}, []
    for model in models:
        results.append((*fit(i420, rgba, width, height, *model, cache), model))
    # Ties go to the smallest move, then to the test reference.
    results.sort(key=lambda r: (-r[0], abs(r[2][1][0]) + abs(r[2][1][1]), r[2] != ('nearest', (0, 0), 'bt601')))
    reference = next(r for r in results if r[2] == ('nearest', (0, 0), 'bt601'))
    shown_results = results[:SHOWN] + ([reference] if reference not in results[:SHOWN] else [])

    def label(model):
        siting, (dx, dy), matrix = model
        return f'chroma={siting} move={dx:+d},{dy:+d} matrix={matrix}'
    for worst, db, model in shown_results:
        print(f"FIT {label(model)} R={shown(db[0])} G={shown(db[1])} B={shown(db[2])} worst={shown(worst)}")
    best = results[0]
    misses(i420, rgba, width, height, best[2], cache)
    print(f'COLOUR_FIT best {label(best[2])} worst_db={shown(best[0])} '
          f'(the test reference, nearest in place with bt601: {shown(reference[0])})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

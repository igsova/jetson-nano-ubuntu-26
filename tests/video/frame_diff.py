#!/usr/bin/env python3
"""Describe how two I420 recordings of the same frames differ.

Usage: python3 -I frame_diff.py WIDTH HEIGHT REFERENCE OUTPUT [PNG]

For a decoder whose frames fail frame_check.py or frame_hashes.py: both
files hold raw I420 frames (no row padding), as GStreamer's filesink writes
them, and the output should repeat the reference. It prints:

  FRAME       each plane's PSNR for a few frames, and whether Y is identical;
  OFFSET      for each of the first frames, the reference frame within three
              either side that the output's Y fits best (a dropped, repeated
              or reordered frame);
  SHIFT       the whole-pixel move of the first frame's Y, up to 8 either
              way, that fits best (a crop or a misplaced picture);
  FIT         each output plane as a least-squares mix of the reference's Y,
              U and V plus a constant, and what is left (a colour matrix or
              range conversion fits closely; a decoding error does not);
  BIAS        the mean difference of each plane in the first frame;
  ERRORS      how many of the first frame's Y values are off by 0, 1 to 2,
              3 to 8, 9 to 32 and more;
  REGION_Y/V  the first frame's RMS error over a grid of 8 columns by 6 rows
              of the picture (V at half size), to show where it is wrong;
  CHROMA_FIT  each of the first frame's U and V as a least-squares mix of the
              reference's same plane at the same place and its eight
              neighbours, plus a constant, and what is left (a converter that
              filters or moves the colour fits closely; JetPack 4's nvvidconv
              averaged each of NVDEC's colour rows with the one below);
  CHROMA_HALF_ROW  for each way of averaging the reference's U and V rows with
              the row above or below, rounding up or down: in how many of the
              FRAME lines' frames the output's inner rows (all but the first and
              last) are exactly that, and in the first frame the share of equal
              values and the largest difference;
  CHROMA_EDGES whether the output's first and last U and V rows are the
              reference's unchanged.

With PNG, it also writes the first frame's Y as a greyscale image at half
size: reference, output and four times the difference, one above the other.
Pure Python (no NumPy), for probe-l4t-codec.sh on the Nano; slow but bounded
(about a minute and a half for 1080p on the Nano).
"""
import math
import operator
import os
import struct
import sys
import zlib

COLUMNS, ROWS = 8, 6


def psnr(sse, count):
    return math.inf if sse == 0 else 10 * math.log10(255 ** 2 * count / sse)


def shown(value):
    return 'inf' if value == math.inf else f'{value:.1f}'


def sse_of(a, b):
    if a == b:
        return 0
    d = list(map(operator.sub, a, b))
    return sum(map(operator.mul, d, d))


class Clip:
    def __init__(self, path, width, height):
        self.w, self.h = width, height
        self.ysize = width * height
        self.csize = (width // 2) * (height // 2)
        self.frame = self.ysize + 2 * self.csize
        size = os.path.getsize(path)
        if size < self.frame:
            raise SystemExit(f'FRAME_DIFF=FAIL {path} holds less than one {width}x{height} I420 frame')
        self.count = size // self.frame
        self.file = open(path, 'rb')
        self.cache = {}

    def get(self, index):
        if index not in self.cache:
            self.file.seek(index * self.frame)
            data = self.file.read(self.frame)
            self.cache[index] = (data[:self.ysize], data[self.ysize:self.ysize + self.csize],
                                 data[self.ysize + self.csize:])
            if len(self.cache) > 12:
                self.cache.pop(next(iter(self.cache)))
        return self.cache[index]


def rows_of(plane, width, height, step, dx=0, dy=0, margin=0):
    """Every step-th row of a plane (moved by dx, dy), cut to width - 2 * margin, joined."""
    out = bytearray()
    for r in range(margin, height - margin, step):
        src = r - dy
        start = src * width + margin - dx
        out += plane[start:start + width - 2 * margin]
    return bytes(out)


def solve(m, v):
    """Solve m x = v by Gaussian elimination with partial pivoting."""
    n = len(v)
    a = [row[:] + [v[i]] for i, row in enumerate(m)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(a[r][c]))
        if abs(a[p][c]) < 1e-9:
            return None
        a[c], a[p] = a[p], a[c]
        for r in range(n):
            if r != c:
                f = a[r][c] / a[c][c]
                a[r] = [x - f * y for x, y in zip(a[r], a[c])]
    return [a[i][n] / a[i][i] for i in range(n)]


def fit(ref, out, w, h):
    """Least-squares fit of each output plane on (Y, U, V, 1) of the reference."""
    yr, ur, vr = ref
    yo, uo, vo = out
    cw = w // 2
    xs, targets = [], ([], [], [])
    for r in range(0, h, 8):
        for c in range(0, w, 4):
            ci = (r // 2) * cw + c // 2
            xs.append((yr[r * w + c], ur[ci], vr[ci], 1))
            targets[0].append(yo[r * w + c])
            targets[1].append(uo[ci])
            targets[2].append(vo[ci])
    m = [[sum(x[i] * x[j] for x in xs) for j in range(4)] for i in range(4)]
    lines = []
    for name, t in zip('YUV', targets):
        coef = solve(m, [sum(x[i] * y for x, y in zip(xs, t)) for i in range(4)])
        if coef is None:
            lines.append(f'FIT {name} no fit (the reference does not vary enough)')
            continue
        residual = sum((y - sum(a * b for a, b in zip(coef, x))) ** 2 for x, y in zip(xs, t))
        lines.append(f'FIT {name} = {coef[0]:.3f}*Y {coef[1]:+.3f}*U {coef[2]:+.3f}*V {coef[3]:+.1f} '
                     f'left_db={shown(psnr(residual, len(t)))}')
    return lines


def chroma_fit(ref, out, width, height):
    """Least-squares fit of an output chroma plane on the reference's 3x3 neighbourhood and 1.

    The samples are every third column of the 32 rows that differ most from
    the rows beside them (where a vertical filter shows) and of every 32nd row.
    """
    row = lambda r: ref[r * width:(r + 1) * width]
    change = sorted(range(1, height - 1), key=lambda r: -(sse_of(row(r), row(r - 1)) + sse_of(row(r), row(r + 1))))
    picked = sorted(set(change[:32]) | set(range(1, height - 1, 32)))
    columns = range(1, width - 1, 3)
    features = [[] for _ in range(10)]
    target = []
    for r in picked:
        for dr in (-1, 0, 1):
            line = row(r + dr)
            for dc in (-1, 0, 1):
                features[(dr + 1) * 3 + dc + 1].extend(line[c + dc] for c in columns)
        target.extend(out[r * width + c] for c in columns)
    features[9] = [1] * len(target)
    m = [[sum(map(operator.mul, features[i], features[j])) for j in range(10)] for i in range(10)]
    coef = solve(m, [sum(map(operator.mul, f, target)) for f in features])
    if coef is None:
        return 'no fit (the reference does not vary enough)'
    residual = 0.0
    for k, y in enumerate(target):
        residual += (y - sum(coef[i] * features[i][k] for i in range(10))) ** 2
    taps = lambda first: ' '.join(f'{c:+.3f}' for c in coef[first:first + 3])
    return (f'above={taps(0)} row={taps(3)} below={taps(6)} constant={coef[9]:+.1f} '
            f'left_db={shown(psnr(residual, len(target)))} samples={len(target)}')


def half_row(plane, width, height, below, up):
    """The plane's inner rows, each averaged with the row above (or below), rounding up or down.

    Byte by byte, (a + b + 1) // 2 or (a + b) // 2, on whole rows at once as
    in frame_hashes.py.
    """
    a = plane[width:(height - 1) * width]
    b = plane[2 * width:] if below else plane[:(height - 2) * width]
    n = len(a)
    x, y = int.from_bytes(a, 'big'), int.from_bytes(b, 'big')
    half = ((x ^ y) >> 1) & int.from_bytes(b'\x7f' * n, 'big')
    return ((x | y) - half if up else (x & y) + half).to_bytes(n, 'big')


def regions(a, b, width, height):
    """RMS error over a COLUMNS x ROWS grid of the plane."""
    cw, rh = width // COLUMNS, height // ROWS
    grid = []
    for gr in range(ROWS):
        line = []
        for gc in range(COLUMNS):
            sse = 0
            for r in range(gr * rh, (gr + 1) * rh):
                start = r * width + gc * cw
                sse += sse_of(a[start:start + cw], b[start:start + cw])
            line.append(math.sqrt(sse / (cw * rh)))
        grid.append(line)
    return grid


def png(path, width, height, pixels):
    raw = b''.join(b'\0' + pixels[r * width:(r + 1) * width] for r in range(height))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def main(argv):
    if len(argv) not in (4, 5):
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    width, height = int(argv[0]), int(argv[1])
    if width % 2 or height % 2 or width < 64 or height < 64:
        raise SystemExit('FRAME_DIFF=FAIL I420 needs an even width and height of 64 or more')
    ref, out = Clip(argv[2], width, height), Clip(argv[3], width, height)
    count = min(ref.count, out.count)
    cw, ch = width // 2, height // 2
    print(f'FRAMES reference={ref.count} output={out.count} compared={count}')

    shown_frames = sorted({0, 1, 2, 3, count // 2, count - 1} & set(range(count)))
    for i in shown_frames:
        a, b = ref.get(i), out.get(i)
        dbs = [shown(psnr(sse_of(x, y), len(x))) for x, y in zip(a, b)]
        print(f'FRAME {i} y_db={dbs[0]} u_db={dbs[1]} v_db={dbs[2]} y_identical={"yes" if a[0] == b[0] else "no"}')

    best_counts = {}
    for i in range(min(count, 10)):
        yb = rows_of(out.get(i)[0], width, height, 4)
        scores = {}
        for k in range(-3, 4):
            if 0 <= i + k < ref.count:
                scores[k] = psnr(sse_of(rows_of(ref.get(i + k)[0], width, height, 4), yb), len(yb))
        best = max(scores, key=scores.get)
        best_counts[best] = best_counts.get(best, 0) + 1
        print(f'OFFSET frame={i} best={best:+d} y_db={shown(scores[best])} at_0={shown(scores[0])}')
    print('OFFSET_BEST ' + ' '.join(f'{k:+d}:{n}' for k, n in sorted(best_counts.items())))

    a, b = ref.get(0), out.get(0)
    target = rows_of(b[0], width, height, 16, margin=8)
    shifts = {}
    for dy in range(-8, 9):
        for dx in range(-8, 9):
            moved = rows_of(a[0], width, height, 16, dx, dy, margin=8)
            shifts[(dx, dy)] = psnr(sse_of(moved, target), len(target))
    (dx, dy), value = max(shifts.items(), key=lambda item: item[1])
    print(f'SHIFT best dx={dx:+d} dy={dy:+d} y_db={shown(value)} at_0={shown(shifts[(0, 0)])} '
          '(output pixel = reference pixel moved right dx, down dy)')

    for line in fit(a, b, width, height):
        print(line)
    bias = [sum(map(operator.sub, y, x)) / len(x) for x, y in zip(a, b)]
    print(f'BIAS output_minus_reference y={bias[0]:+.2f} u={bias[1]:+.2f} v={bias[2]:+.2f}')
    d = list(map(abs, map(operator.sub, a[0], b[0])))
    buckets = [(0, 0), (1, 2), (3, 8), (9, 32), (33, 255)]
    total = len(d)
    hist = [0] * 256
    for value in d:
        hist[value] += 1
    print('ERRORS y ' + ' '.join(f'{lo}-{hi}:{100 * sum(hist[lo:hi + 1]) / total:.1f}%' for lo, hi in buckets))
    for name, x, y, w, h in (('Y', a[0], b[0], width, height), ('V', a[2], b[2], cw, ch)):
        for gr, line in enumerate(regions(x, y, w, h)):
            print(f'REGION_{name} row={gr} ' + ' '.join(f'{v:5.1f}' for v in line))

    for name, p in (('U', 1), ('V', 2)):
        print(f'CHROMA_FIT {name} {chroma_fit(a[p], b[p], cw, ch)}')
    inner = lambda plane: plane[cw:(ch - 1) * cw]
    for below in (False, True):
        for up in (1, 0):
            way = f"{'below' if below else 'above'}_{'up' if up else 'down'}"
            same_frames = sum(all(half_row(ref.get(i)[p], cw, ch, below, up) == inner(out.get(i)[p]) for p in (1, 2))
                              for i in shown_frames)
            shares, largest = [], 0
            for p in (1, 2):
                moved, got = half_row(a[p], cw, ch, below, up), inner(b[p])
                shares.append(100 * sum(map(operator.eq, moved, got)) / len(got))
                if moved != got:
                    largest = max(largest, max(map(abs, map(operator.sub, moved, got))))
            print(f'CHROMA_HALF_ROW {way} identical_frames={same_frames}/{len(shown_frames)} '
                  f'frame0 u_same={shares[0]:.2f}% v_same={shares[1]:.2f}% max_diff={largest}')
    edge = lambda r: 'yes' if all(a[p][r * cw:(r + 1) * cw] == b[p][r * cw:(r + 1) * cw] for p in (1, 2)) else 'no'
    print(f'CHROMA_EDGES first_row_unchanged={edge(0)} last_row_unchanged={edge(ch - 1)}')

    if len(argv) == 5:
        half = lambda plane: b''.join(plane[r * width:(r + 1) * width:2] for r in range(0, height, 2))
        ya, yb = half(a[0]), half(b[0])
        diff = bytes(min(255, 4 * abs(p - q)) for p, q in zip(ya, yb))
        png(argv[4], cw, 3 * ch, ya + yb + diff)
        print(f'PNG {argv[4]} reference, output and 4x difference of frame 0 Y, top to bottom')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

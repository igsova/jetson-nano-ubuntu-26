#!/usr/bin/env python3
"""Write make_model.py's input for trtexec, or check trtexec's output against expected.json.

Usage: python3 -I trt_check.py input OUT.bin
       python3 -I trt_check.py check OUTPUT.json EXPECTED.json TOLERANCE

Standard library only, for the Nano. "input" writes the 1x3x64x64 float32
input of make_model.input_values(), little-endian in C order, which trtexec
reads with --loadInputs=input:OUT.bin. "check" reads trtexec's
--exportOutput JSON and passes when every output value is within TOLERANCE
of the expected one, scaled by max(1, |expected|). Prints KEY=VALUE lines.
"""
import json
import struct
import sys


def write_input(path):
    values = [(((c * 4096 + h * 64 + w) * 37) % 255) / 255.0 - 0.5
              for c in range(3) for h in range(64) for w in range(64)]
    with open(path, 'wb') as out:
        out.write(struct.pack(f'<{len(values)}f', *values))
    print(f'TRT_INPUT={path} values={len(values)}')


def check(output_path, expected_path, tolerance):
    with open(expected_path) as f:
        expected = json.load(f)
    with open(output_path) as f:
        outputs = json.load(f)
    found = [o for o in outputs if o.get('name') == expected['name']]
    if not found:
        print(f'TRT_OUTPUT=FAIL no output named {expected["name"]} in {output_path}')
        return False
    got = [float(v) for v in found[0]['values']]
    want = expected['values']
    if len(got) != len(want):
        print(f'TRT_OUTPUT=FAIL {len(got)} values, expected {len(want)}')
        return False
    worst = max(abs(g - e) / max(1.0, abs(e)) for g, e in zip(got, want))
    ok = worst <= tolerance
    print('TRT_VALUES=' + ' '.join(f'{v:.4f}' for v in got))
    print(f'TRT_OUTPUT={"PASS" if ok else "FAIL"} worst scaled error {worst:.2e} (tolerance {tolerance:g})')
    return ok


def main():
    if len(sys.argv) == 3 and sys.argv[1] == 'input':
        write_input(sys.argv[2])
        return 0
    if len(sys.argv) == 5 and sys.argv[1] == 'check':
        return 0 if check(sys.argv[2], sys.argv[3], float(sys.argv[4])) else 1
    print(__doc__.split('\n\n')[1], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Summarize a TensorRT engine's per-layer profile from trtexec.

Usage: python3 trt-profile.py RECORD [SLOWEST]
RECORD holds profile.json (trtexec --exportProfile) and, if trtexec could
write it, layers.json (--exportLayerInfo, with --profilingVerbosity=detailed
for types, formats and kernels). Prints the time by layer type and by output data type, the format
conversions (Reformat layers), the convolution kernels by time and the
SLOWEST (20) layers. Used by profile-yolo.sh and probe-trt82.sh.
"""
import collections
import json
import re
import sys

record = sys.argv[1]
slowest = int(sys.argv[2]) if len(sys.argv) > 2 else 20
profile = json.load(open(f'{record}/profile.json'))
try:
    info = json.load(open(f'{record}/layers.json'))
except FileNotFoundError:  # a trtexec without --exportLayerInfo: times and names only
    info = {}
runs = next((p['count'] for p in profile if 'count' in p), None)
rows = [p for p in profile if 'name' in p]
layers = {l.get('Name'): l for l in info.get('Layers', []) if isinstance(l, dict)}


def data_type(layer):
    outs = layer.get('Outputs') or [{}]
    text = outs[0].get('Format/Datatype', '')
    m = re.search(r'\b(FP32|FP16|Int8|INT8|Int32|INT32|Bool|BOOL|UInt8)\b', text)
    return m.group(1).upper() if m else (text or '?')


def shape(layer):
    outs = layer.get('Outputs') or [{}]
    return 'x'.join(map(str, outs[0].get('Dimensions', []))) or '?'


total = sum(r['averageMs'] for r in rows)
matched = sum(r['name'] in layers for r in rows)
print(f'PROFILE {len(rows)} layers, {runs} profiled runs, {total:.2f} ms a run in all '
      f'(each layer timed alone, so more than the timing run); {matched} layers with details')


def table(title, groups, limit=None):
    print(title)
    for key, (n, ms) in sorted(groups.items(), key=lambda kv: -kv[1][1])[:limit]:
        print(f'  {ms:8.2f} ms {100 * ms / total:5.1f}%  {n:4d} layers  {key}')


by_type, by_dtype, kernels = (collections.defaultdict(lambda: [0, 0.0]) for _ in range(3))
for r in rows:
    layer = layers.get(r['name'], {})
    kind = layer.get('LayerType', '?')
    for groups, key in ((by_type, kind), (by_dtype, data_type(layer))):
        groups[key][0] += 1
        groups[key][1] += r['averageMs']
    if layer.get('ParameterType') == 'Convolution' or 'Convolution' in kind:
        kernel = kernels[layer.get('TacticName') or layer.get('TacticValue') or kind]
        kernel[0] += 1
        kernel[1] += r['averageMs']
table('By layer type:', by_type)
table('By output data type:', by_dtype)
n, ms = by_type.get('Reformat', [0, 0.0])
print(f'Format conversions: {n} Reformat layers, {ms:.2f} ms ({100 * ms / max(total, 1e-9):.1f}%)')
table('Convolution kernels, by time:', kernels, 10)
print(f'Slowest {slowest} layers:')
for r in sorted(rows, key=lambda r: -r['averageMs'])[:slowest]:
    layer = layers.get(r['name'], {})
    tactic = layer.get('TacticName') or ''
    print(f'  {r["averageMs"]:7.3f} ms {100 * r["averageMs"] / total:5.1f}%  {layer.get("LayerType", "?")} '
          f'{data_type(layer)} {shape(layer)}  {r["name"][:70]}{"  [" + tactic[:60] + "]" if tactic else ""}')

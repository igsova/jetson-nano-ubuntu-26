#!/usr/bin/env python3
"""Export Ultralytics' YOLO26 to ONNX for the Nano's TensorRT, with test images
and Ultralytics' own detections on them, as a bundle for setup-yolo.sh (and
probe-trt82.sh).

Runs on a PC (not the Nano), in a Python environment with Ultralytics 8.4.182
and a CPU build of PyTorch, for example (conda-forge's CPU build avoids
PyPI's CUDA wheels):
  micromamba create -p ENV -c conda-forge python=3.12 'pytorch=*=cpu*' torchvision
  ENV/bin/python -m pip install ultralytics==8.4.182 onnx onnxslim onnxruntime opencv-python-headless
  ENV/bin/python scripts/host/export-yolo26.py [OUT]

OUT is artifacts/yolo by default (out of git: the models are binaries under
Ultralytics' AGPL-3.0). It gets the weights (weights/, checked against their
SHA-256), the bundle folder and OUT/yolo26-nano.tar holding it:
  models/yolo26n-640x480.onnx      YOLO26n, NMS-free head: (1, 6300, 84), top 300 after
  models/yolo26n-640x480-raw.onnx  YOLO26n, one-to-many head: (1, 84, 6300), NMS after
  models/yolo26s-640x480.onnx      YOLO26s, NMS-free head
  test/<image>-640x480.png         bus.jpg and zidane.jpg from Ultralytics'
                                   package, letterboxed to 640x480 by Ultralytics
  test/<model>.<image>.json        Ultralytics' PyTorch detections (conf 0.25) on it
  SHA256SUMS, README.txt
Each model takes a 640x480 RGB picture (1, 3, 480, 640), the webcam's own
size, so the Nano needs no resizing; ONNX opset 13, simplified, FP32 (the
Nano builds FP16 engines from it). Opset 13 is the newest JetPack 4's
TensorRT 8.2 reads, and JetPack 5's 8.5 reads it too, so one file serves
both. The NMS-free models leave out the head's last step, Ultralytics' pick
of the 300 best box and class pairs (TopK and GatherElements), which TensorRT
8.5 could not build on the Nano ("insufficient workspace", 2026-10-18);
yolo-cam.py does it on the CPU.

Checks, each a line, then EXPORT=PASS or FAIL: the weights' SHA-256; each
model's input, output and operators (only those listed in TRT_OPS); that
yolo-cam.py's letterbox gives Ultralytics' pixels; and that ONNX Runtime with
yolo-cam.py's decoding finds Ultralytics' detections (same class, overlap
0.98 or more, score within 0.01).
"""
import hashlib
import importlib.util
import json
import pathlib
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request

ULTRALYTICS = '8.4.182'
WEIGHTS = {  # https://github.com/ultralytics/assets/releases/tag/v8.4.0
    'yolo26n.pt': '9b09cc8bf347f0fc8a5f7657480587f25db09b34bf33b0652110fb03a8ad4fef',
    'yolo26s.pt': '646f8bc3fe0a656803d95c294f7852321748cb29d13466a1af8862e2db384a1b',
}
WEIGHTS_URL = 'https://github.com/ultralytics/assets/releases/download/v8.4.0/'
SIZE = (480, 640)  # height, width: the webcam's 640x480
MODELS = (  # file stem, weights, NMS-free head
    ('yolo26n-640x480', 'yolo26n.pt', True),
    ('yolo26n-640x480-raw', 'yolo26n.pt', False),
    ('yolo26s-640x480', 'yolo26s.pt', True),
)
IMAGES = ('bus.jpg', 'zidane.jpg')
OPSET = 13  # TensorRT 8.2's newest, read by 8.5 too
CONF = 0.25
# Operators the models use, each taken by TensorRT 8.5's ONNX parser and by 8.2's (onnx-tensorrt
# release/8.2-GA, docs/operators.md); no TopK, GatherElements or Mod: the top-300 step is left out.
TRT_OPS = {'Add', 'Concat', 'Conv', 'Div', 'MatMul', 'MaxPool', 'Mul', 'Reshape', 'Resize', 'Sigmoid', 'Slice',
           'Softmax', 'Split', 'Sub', 'Transpose'}

here = pathlib.Path(__file__).resolve().parent
repo = here.parent.parent
failures = []


def check(name, ok, detail=''):
    print(f'{name}={"PASS" if ok else "FAIL"}{" " + detail if detail else ""}', flush=True)
    if not ok:
        failures.append(name)
    return ok


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def load_cam():
    spec = importlib.util.spec_from_file_location('yolo_cam', repo / 'scripts/jetson/yolo/yolo-cam.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else repo / 'artifacts/yolo').resolve()
    import cv2
    import numpy as np
    import onnx
    import onnxruntime
    import torch
    import ultralytics
    from ultralytics import YOLO
    from ultralytics.data.augment import LetterBox

    check('ULTRALYTICS', ultralytics.__version__ == ULTRALYTICS, f'{ultralytics.__version__} (wanted {ULTRALYTICS})')
    cam = load_cam()
    weights = out / 'weights'
    bundle = out / 'yolo26-nano'
    if bundle.exists():
        shutil.rmtree(bundle)
    for d in (weights, bundle / 'models', bundle / 'test'):
        d.mkdir(parents=True, exist_ok=True)

    for name, want in WEIGHTS.items():
        path = weights / name
        if not path.exists():
            print(f'downloading {WEIGHTS_URL}{name}', flush=True)
            with urllib.request.urlopen(WEIGHTS_URL + name, timeout=120) as r, open(path, 'wb') as f:
                shutil.copyfileobj(r, f)
        if not check(f'WEIGHTS_{name}', sha256(path) == want, sha256(path)):
            return 1

    # Test pictures, letterboxed by Ultralytics and by yolo-cam.py.
    assets = pathlib.Path(ultralytics.__file__).parent / 'assets'
    tests = {}
    for image in IMAGES:
        img = cv2.imread(str(assets / image))
        theirs = LetterBox(new_shape=SIZE, auto=False)(image=img)
        ours = cam.Letterbox((img.shape[1], img.shape[0]), (SIZE[1], SIZE[0])).apply(img)
        stem = image.rsplit('.', 1)[0]
        check(f'LETTERBOX_{stem}', ours.shape == theirs.shape and np.array_equal(ours, theirs),
              f'{img.shape[1]}x{img.shape[0]} to {ours.shape[1]}x{ours.shape[0]}')
        png = bundle / 'test' / f'{stem}-640x480.png'
        cv2.imwrite(str(png), theirs)
        tests[stem] = cv2.imread(str(png))  # exactly what the Nano reads

    with tempfile.TemporaryDirectory() as tmp:
        for stem, pt, e2e in MODELS:
            work = pathlib.Path(tmp) / stem
            work.mkdir()
            shutil.copy(weights / pt, work / pt)
            model = YOLO(str(work / pt))
            head = model.model.model[-1]
            if e2e:  # without the top-300 step: its input, (1, anchors, 4 + classes), is the output
                head.postprocess = lambda preds: preds
            exported = model.export(format='onnx', imgsz=SIZE, opset=OPSET, simplify=True, batch=1, dynamic=False,
                                    nms=False if e2e else None, verbose=False)
            if e2e:
                del head.postprocess  # Ultralytics' own detections below come from the whole head
            onnx_path = bundle / 'models' / f'{stem}.onnx'
            shutil.move(exported, onnx_path)
            graph = onnx.load(str(onnx_path))
            onnx.checker.check_model(graph)
            dims = lambda v: [d.dim_value for d in v.type.tensor_type.shape.dim]
            ins, outs = [dims(i) for i in graph.graph.input], [dims(o) for o in graph.graph.output]
            anchors = sum((SIZE[0] // s) * (SIZE[1] // s) for s in (8, 16, 32))
            want_out = [1, anchors, 84] if e2e else [1, 84, anchors]
            check(f'SHAPES_{stem}', ins == [[1, 3, *SIZE]] and outs == [want_out], f'in {ins}, out {outs}')
            ops = {n.op_type for n in graph.graph.node}
            check(f'OPS_{stem}', ops <= TRT_OPS and graph.opset_import[0].version == OPSET,
                  f'opset {graph.opset_import[0].version}, {len(graph.graph.node)} nodes'
                  + (f', not expected: {sorted(ops - TRT_OPS)}' if ops - TRT_OPS else ''))
            session = onnxruntime.InferenceSession(str(onnx_path), providers=['CPUExecutionProvider'])
            for image, img in tests.items():
                result = model.predict(img, imgsz=SIZE, conf=CONF, nms=False if e2e else None, verbose=False)[0]
                b = result.boxes
                expected = [[*map(float, xyxy), float(c), float(k)]
                            for xyxy, c, k in zip(b.xyxy.tolist(), b.conf.tolist(), b.cls.tolist())]
                text = json.dumps({
                    'model': f'{stem}.onnx', 'image': f'{image}-640x480.png', 'conf': CONF,
                    'ultralytics': ultralytics.__version__, 'torch': torch.__version__,
                    'head': 'NMS-free (one-to-one), top 300' if e2e else 'one-to-many with NMS (IoU 0.7)',
                    'columns': ['x1', 'y1', 'x2', 'y2', 'score', 'class'],
                    'detections': [[round(v, 4) for v in d] for d in expected]}, indent=1)
                text = re.sub(r'\[\s+([-0-9.,\s]+?)\s+\]', lambda m: '[' + ' '.join(m.group(1).split()) + ']', text)
                (bundle / 'test' / f'{stem}.{image}.json').write_text(text + '\n')
                raw = session.run(None, {session.get_inputs()[0].name: cam.to_blob(img)})[0]
                got = cam.decode(raw, CONF)
                ok, lines = cam.compare(got.tolist(), expected, strong=CONF, weak=CONF, min_iou=0.98, score_tol=0.01)
                check(f'ORT_{stem}_{image}', ok and len(got) == len(expected),
                      f'{len(got)} found, Ultralytics {len(expected)}: '
                      + ', '.join(f'{cam.NAMES[int(d[5])]} {d[4]:.2f}' for d in expected))
                if not ok:
                    print('\n'.join(lines))

    readme = f'''YOLO26 for the Jetson Nano's TensorRT 8.5 or 8.2 (jetson-ubuntu-26, scripts/host/export-yolo26.py)

Models: Ultralytics YOLO26n and YOLO26s (COCO, 80 classes), weights from
{WEIGHTS_URL} (AGPL-3.0, https://ultralytics.com/license), exported to ONNX
by Ultralytics {ultralytics.__version__} with PyTorch {torch.__version__} on a CPU: input
(1, 3, 480, 640) RGB 0-1, opset {OPSET}, simplified, FP32.
  *-640x480.onnx      NMS-free head, output (1, 6300, 84): x1, y1, x2, y2, 80 class scores;
                      the 300 best box and class pairs after (the head's last step)
  *-640x480-raw.onnx  one-to-many head, output (1, 84, 6300): cx, cy, w, h, 80 class scores; NMS after
Test pictures: bus.jpg and zidane.jpg from the ultralytics package's assets,
letterboxed to 640x480; the JSON files hold Ultralytics' own detections on them.
'''
    (bundle / 'README.txt').write_text(readme)
    files = sorted(p for p in bundle.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
    (bundle / 'SHA256SUMS').write_text(''.join(f'{sha256(p)}  {p.relative_to(bundle)}\n' for p in files))
    tar = out / 'yolo26-nano.tar'

    def plain(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ''
        return info
    with tarfile.open(tar, 'w') as t:
        for p in [bundle, *sorted(bundle.rglob('*'))]:
            t.add(p, arcname=str(p.relative_to(out)), recursive=False, filter=plain)
    print(f'BUNDLE {tar} {tar.stat().st_size} bytes sha256 {sha256(tar)}')
    for p in sorted((bundle / 'models').iterdir()):
        print(f'  {p.name} {p.stat().st_size} bytes sha256 {sha256(p)}')
    print(f'EXPORT={"FAIL " + " ".join(failures) if failures else "PASS"}')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())

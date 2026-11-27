#!/usr/bin/env python3
"""Live YOLO object detection on the USB webcam with TensorRT on the Jetson Nano.

Ubuntu 26.04 runs TensorRT on the Nano's GPU: JetPack 4's 8.2 by
default once nano-trt82 is installed, else JetPack 5's 8.5. setup-yolo.sh
builds the engines and libnano_trt.so, the small C library this program calls
through ctypes (TensorRT's own Python module does not fit Ubuntu 26.04's
Python), for the default TensorRT.

Usage, from an SSH login to the Nano, as your own account (no sudo):
  python3 yolo-cam.py [--seconds N] [--engine FILE] [--device /dev/videoN]
                      [--conf 0.25] [--watch person] [--port 8080] [--show]
  python3 yolo-cam.py --check IMAGE EXPECTED.json [--engine FILE]
  python3 yolo-cam.py --video IN.mp4 --out OUT.mp4 [--seconds N] [--size WxH]
--lib picks the runner library for an engine of another TensorRT, run through
a launcher that puts that TensorRT's libraries first: TensorRT 8.5's, which
setup-yolo.sh keeps in ~/yolo/trt85, through nano-trt85, or JetPack 4's 8.2
from probe-trt82.sh through its own.

Live: a capture thread reads the camera (YUYV, at the engine's input size
unless --size says otherwise) and prepares each frame for the model; the main
loop runs the newest frame through the engine, draws what it found with the
frame rate, and serves the picture as an MJPEG stream at http://BIND:PORT/
(127.0.0.1 by default, so view it through ssh -L 8080:127.0.0.1:8080).
--show also opens a window on the Nano's own desktop.

Watched classes (person by default) make events: a class seen with at least
--event-conf in EVENT_FRAMES processed frames in a row starts one, with a
snapshot; EVENT_GAP seconds without it ends it. Every STATS_SECONDS a line gives
the processed and camera frame rates, each stage's time, this program's CPU
use, the GPU's load, clock and temperature, and the memory left. Ctrl+C or
--seconds stops it. The record goes to ~/yolo/runs/<stamp>: stats.csv,
events.csv, the event snapshots, last.jpg and summary.json. The last line is
YOLO_CAM=PASS (it ran without a camera or engine error and averaged MIN_FPS
or more) or YOLO_CAM=FAIL.

Video: runs a video file through the engine instead of the camera, every
frame in order, and writes it with the detections and each frame's engine time
drawn on to --out (MP4, the input's frame rate). Each frame's time is the
engine and decoding, as in the live loop, where the capture thread prepares
the next frame meanwhile. For demos without a camera;
--seconds stops it early and --size scales the frames to fit inside it first,
keeping their shape. The last line
is YOLO_VIDEO=PASS with the mean times, or YOLO_VIDEO=FAIL.

Check: runs the engine on a test image (export-yolo26.py made it and the
expected detections with Ultralytics) and compares; the last line is
YOLO_CHECK=PASS or FAIL, with the engine's mean time over CHECK_RUNS runs.
"""
import argparse
import csv
import ctypes
import datetime
import http.server
import json
import os
import pathlib
import signal
import sys
import threading
import time

try:
    import cv2
    import numpy as np
except ImportError as error:
    sys.exit(f'YOLO_CAM=FAIL: no {error.name} for Python 3; install it with: sudo apt install python3-opencv')

WORK = pathlib.Path.home() / 'yolo'
LIB = WORK / 'lib' / 'libnano_trt.so'
ENGINE = WORK / 'engines' / 'yolo26n-640x480-fp16.engine'
RUNS = WORK / 'runs'
SYS = pathlib.Path('/sys')
PROC = pathlib.Path('/proc')
STATS_SECONDS = 5
MIN_FPS = 10
MIN_SECONDS = 10       # a live run shorter than this is not judged
EVENT_FRAMES = 3
EVENT_GAP = 3.0
CHECK_RUNS = 50
IOU = 0.7              # NMS overlap for the one-to-many head, as Ultralytics uses
JPEG_QUALITY = 80

NAMES = (
    'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck', 'boat', 'traffic light',
    'fire hydrant', 'stop sign', 'parking meter', 'bench', 'bird', 'cat', 'dog', 'horse', 'sheep', 'cow',
    'elephant', 'bear', 'zebra', 'giraffe', 'backpack', 'umbrella', 'handbag', 'tie', 'suitcase', 'frisbee',
    'skis', 'snowboard', 'sports ball', 'kite', 'baseball bat', 'baseball glove', 'skateboard', 'surfboard',
    'tennis racket', 'bottle', 'wine glass', 'cup', 'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple',
    'sandwich', 'orange', 'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair', 'couch',
    'potted plant', 'bed', 'dining table', 'toilet', 'tv', 'laptop', 'mouse', 'remote', 'keyboard', 'cell phone',
    'microwave', 'oven', 'toaster', 'sink', 'refrigerator', 'book', 'clock', 'vase', 'scissors', 'teddy bear',
    'hair drier', 'toothbrush')  # COCO, the classes Ultralytics' YOLO26 detects
PALETTE = ((56, 56, 255), (151, 157, 255), (31, 112, 255), (29, 178, 255), (49, 210, 207), (10, 249, 72),
           (23, 204, 146), (134, 219, 61), (52, 147, 26), (187, 212, 0), (168, 153, 44), (255, 194, 0),
           (147, 69, 52), (255, 115, 100), (236, 24, 0), (255, 56, 132), (133, 0, 82), (255, 56, 203),
           (200, 149, 255), (199, 55, 255))  # BGR


def say(*parts):
    print(*parts, flush=True)


# --- The model's input and output.

class Letterbox:
    """Fits a frame into the model's input as Ultralytics' LetterBox does (scale to
    fit, round each side, pad evenly with grey 114) and maps boxes back."""

    def __init__(self, frame_wh, model_wh):
        (w, h), (mw, mh) = frame_wh, model_wh
        r = min(mh / h, mw / w)
        self.size = (round(w * r), round(h * r))
        dw, dh = (mw - self.size[0]) / 2, (mh - self.size[1]) / 2
        self.top, self.bottom = round(dh - 0.1), round(dh + 0.1)
        self.left, self.right = round(dw - 0.1), round(dw + 0.1)
        self.gain = (self.size[0] / w, self.size[1] / h)
        self.frame = (w, h)

    def apply(self, img):
        if (img.shape[1], img.shape[0]) != self.size:
            img = cv2.resize(img, self.size, interpolation=cv2.INTER_LINEAR)
        if self.top or self.bottom or self.left or self.right:
            img = cv2.copyMakeBorder(img, self.top, self.bottom, self.left, self.right, cv2.BORDER_CONSTANT,
                                     value=(114, 114, 114))
        return img

    def unmap(self, dets):
        """Detections in model pixels to frame pixels, clipped to the frame."""
        d = dets.copy()
        d[:, [0, 2]] = ((d[:, [0, 2]] - self.left) / self.gain[0]).clip(0, self.frame[0])
        d[:, [1, 3]] = ((d[:, [1, 3]] - self.top) / self.gain[1]).clip(0, self.frame[1])
        return d


def to_blob(img):
    """BGR uint8 (H, W, 3) to the model's float32 (1, 3, H, W): RGB, 0 to 1."""
    return cv2.dnn.blobFromImage(img, 1 / 255.0, swapRB=True)


def nms(boxes, scores, iou):
    """Indices kept by greedy non-maximum suppression, best first."""
    area = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    order = scores.argsort(kind='stable')[::-1]
    keep = []
    while order.size:
        i, rest = order[0], order[1:]
        keep.append(i)
        w = (np.minimum(boxes[i, 2], boxes[rest, 2]) - np.maximum(boxes[i, 0], boxes[rest, 0])).clip(0)
        h = (np.minimum(boxes[i, 3], boxes[rest, 3]) - np.maximum(boxes[i, 1], boxes[rest, 1])).clip(0)
        inter = w * h
        order = rest[inter / (area[i] + area[rest] - inter + 1e-9) <= iou]
    return np.array(keep, dtype=int)


def decode(out, conf, iou=IOU, top=300):
    """The model's output to detections (N, 6): x1, y1, x2, y2, score, class in
    model pixels, best first.

    YOLO26's NMS-free head, as export-yolo26.py exports it, gives (1, anchors,
    4 + classes) of corners and class scores, without its last step (TensorRT
    8.5 could not build it on the Nano), which is done here: Ultralytics' pick
    of the `top` best box and class pairs among the `top` anchors with the best
    class scores. Exported whole it gives (1, 300, 6) already in the final form. Its one-to-many head gives (1, 4 + classes,
    anchors) of centre, size and class scores, which need non-maximum
    suppression per class."""
    out = out.reshape(out.shape[-2:]).astype(np.float32, copy=False)
    if out.shape[1] == 6:
        dets = out[out[:, 4] >= conf]
        return dets[dets[:, 4].argsort(kind='stable')[::-1]]
    if out.shape[0] > out.shape[1]:  # anchors first: the NMS-free head
        scores = out[:, 4:]
        anchor, cls = np.divmod(np.flatnonzero(scores >= conf), scores.shape[1])  # under conf: dropped anyway
        rows = np.unique(anchor)
        if len(rows) > top:
            rows = rows[np.argpartition(scores[rows].max(1), -top)[-top:]]
            keep = np.isin(anchor, rows)
            anchor, cls = anchor[keep], cls[keep]
        score = scores[anchor, cls]
        order = score.argsort(kind='stable')[::-1][:top]
        anchor, cls, score = anchor[order], cls[order], score[order]
        return np.concatenate([out[anchor, :4], score[:, None], cls[:, None]], 1).astype(np.float32)
    scores = out[4:]
    best = scores.max(0)
    keep = np.flatnonzero(best >= conf)
    cls, score = scores[:, keep].argmax(0), best[keep]
    xy, wh = out[:2, keep].T, out[2:4, keep].T
    boxes = np.concatenate([xy - wh / 2, xy + wh / 2], 1)
    kept = nms(boxes + cls[:, None] * 7680.0, score, iou)[:top]  # classes apart, as Ultralytics does
    return np.concatenate([boxes[kept], score[kept, None], cls[kept, None]], 1).astype(np.float32)


DTYPES = {0: np.float32, 1: np.float16, 2: np.int8, 3: np.int32, 4: np.bool_, 5: np.uint8}


class Engine:
    """A TensorRT engine through libnano_trt.so: one input, its outputs."""

    def __init__(self, path, lib=None):
        L = self.lib = ctypes.CDLL(str(lib or LIB))
        L.ntrt_version.restype = ctypes.c_int
        L.ntrt_open.restype = ctypes.c_void_p
        L.ntrt_open.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int)
        L.ntrt_count.argtypes = (ctypes.c_void_p,)
        L.ntrt_binding.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                                   ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
                                   ctypes.POINTER(ctypes.c_int), ctypes.c_int)
        L.ntrt_run.argtypes = (ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_float),
                               ctypes.c_char_p, ctypes.c_int)
        L.ntrt_memory.argtypes = (ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t))
        L.ntrt_close.argtypes = (ctypes.c_void_p,)
        v = L.ntrt_version()
        self.version = f'{v // 1000}.{v // 100 % 10}.{v % 100}'
        self.err = ctypes.create_string_buffer(1024)
        self.handle = L.ntrt_open(os.fsencode(path), self.err, len(self.err))
        if not self.handle:
            raise RuntimeError(self.err.value.decode(errors='replace'))
        self.names, self.arrays, inputs = [], [], []
        for i in range(L.ntrt_count(self.handle)):
            name, is_input, kind, dims = ctypes.create_string_buffer(256), ctypes.c_int(), ctypes.c_int(), (ctypes.c_int * 8)()
            n = L.ntrt_binding(self.handle, i, name, len(name), ctypes.byref(is_input), ctypes.byref(kind), dims, 8)
            self.names.append(name.value.decode())
            self.arrays.append(np.zeros(tuple(dims[:n]), DTYPES[kind.value]))
            if is_input.value:
                inputs.append(i)
        if len(inputs) != 1 or self.arrays[inputs[0]].ndim != 4 or self.arrays[inputs[0]].shape[:2] != (1, 3):
            self.close()
            raise RuntimeError('the engine needs one input of shape (1, 3, H, W)')
        self.input = inputs[0]
        self.outputs = [i for i in range(len(self.arrays)) if i != self.input]
        self.size = (self.arrays[self.input].shape[3], self.arrays[self.input].shape[2])  # W, H
        self.pointers = (ctypes.c_void_p * len(self.arrays))(*[a.ctypes.data for a in self.arrays])
        self.gpu_ms = ctypes.c_float()

    def __call__(self, blob):
        """The outputs for one input (reused by the next call) and the GPU time in ms."""
        held = self.arrays[self.input]
        if blob.dtype == held.dtype and blob.shape == held.shape and blob.flags.c_contiguous:
            self.pointers[self.input] = blob.ctypes.data  # no copy; blob lives through the call
        else:
            np.copyto(held, blob, casting='same_kind')
            self.pointers[self.input] = held.ctypes.data
        if self.lib.ntrt_run(self.handle, self.pointers, ctypes.byref(self.gpu_ms), self.err, len(self.err)):
            raise RuntimeError(self.err.value.decode(errors='replace'))
        return [self.arrays[i] for i in self.outputs], self.gpu_ms.value

    def memory(self):
        free, total = ctypes.c_size_t(), ctypes.c_size_t()
        return (free.value, total.value) if self.lib.ntrt_memory(ctypes.byref(free), ctypes.byref(total)) == 0 else None

    def describe(self):
        return ', '.join(f'{"in" if i == self.input else "out"} {n} {tuple(a.shape)} {a.dtype}'
                         for i, (n, a) in enumerate(zip(self.names, self.arrays)))

    def close(self):
        if self.handle:
            self.lib.ntrt_close(self.handle)
            self.handle = None


def draw(img, dets, banner):
    for x1, y1, x2, y2, score, cls in dets:
        c = int(cls)
        color = PALETTE[c % len(PALETTE)]
        p1, p2 = (int(x1), int(y1)), (int(x2), int(y2))
        cv2.rectangle(img, p1, p2, color, 2)
        label = f'{NAMES[c] if c < len(NAMES) else c} {score:.2f}'
        (tw, th), base = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
        y = p1[1] - 4 if p1[1] - th - base - 4 >= 0 else p1[1] + th + 4
        cv2.rectangle(img, (p1[0], y - th - 3), (p1[0] + tw + 4, y + base - 1), color, -1)
        cv2.putText(img, label, (p1[0] + 2, y - 1), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1, cv2.LINE_AA)
    (tw, th), base = cv2.getTextSize(banner, cv2.FONT_HERSHEY_SIMPLEX, 0.55, 1)
    cv2.rectangle(img, (0, 0), (tw + 10, th + base + 8), (0, 0, 0), -1)
    cv2.putText(img, banner, (5, th + 4), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1, cv2.LINE_AA)
    return img


# --- Check: one test image against Ultralytics' detections.

def iou_one(a, b):
    w = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    h = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = w * h
    return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter + 1e-9)


def compare(got, want, strong=0.5, weak=0.3, min_iou=0.85, score_tol=0.08):
    """Whether got matches want, and a line per finding. Every wanted detection
    of at least strong needs one of the same class with min_iou overlap and a
    score within score_tol; every detection got of at least strong needs a
    wanted one of the same class of at least weak that it overlaps by 0.5."""
    lines, ok, used = [], True, set()
    for w in (w for w in want if w[4] >= strong):
        best, best_iou = None, 0.0
        for j, g in enumerate(got):
            if j not in used and int(g[5]) == int(w[5]) and iou_one(g, w) > best_iou:
                best, best_iou = j, iou_one(g, w)
        name = NAMES[int(w[5])]
        if best is not None and best_iou >= min_iou and abs(got[best][4] - w[4]) <= score_tol:
            used.add(best)
            lines.append(f'  match {name} {w[4]:.3f} -> {got[best][4]:.3f}, overlap {best_iou:.3f}')
        else:
            ok = False
            found = f'best {got[best][4]:.3f} with overlap {best_iou:.3f}' if best is not None else 'none'
            lines.append(f'  MISSING {name} {w[4]:.3f} at {[round(float(v), 1) for v in w[:4]]} ({found})')
    for g in (g for g in got if g[4] >= strong):
        if not any(int(w[5]) == int(g[5]) and w[4] >= weak and iou_one(g, w) >= 0.5 for w in want):
            ok = False
            lines.append(f'  EXTRA {NAMES[int(g[5])]} {g[4]:.3f} at {[round(float(v), 1) for v in g[:4]]}')
    return ok, lines


def check(args):
    def fail(why):
        say(f'YOLO_CHECK=FAIL: {why}')
        return 1
    image, expected = args.check
    img = cv2.imread(image, cv2.IMREAD_COLOR)
    if img is None:
        return fail(f'cannot read {image}')
    try:
        want = json.loads(pathlib.Path(expected).read_text())['detections']
    except (OSError, ValueError, KeyError) as error:
        return fail(f'cannot read {expected}: {error}')
    try:
        engine = Engine(args.engine, args.lib)
    except (OSError, RuntimeError) as error:
        return fail(f'{args.engine}: {error}')
    try:
        say(f'TensorRT {engine.version}; {args.engine}: {engine.describe()}')
        box = Letterbox((img.shape[1], img.shape[0]), engine.size)
        blob = to_blob(box.apply(img))
        outs, _ = engine(blob)  # the first run sets things up
        walls, gpus = [], []
        for _ in range(CHECK_RUNS):
            t = time.perf_counter()
            outs, gpu = engine(blob)
            walls.append((time.perf_counter() - t) * 1000)
            gpus.append(gpu)
        got = box.unmap(decode(outs[0], args.conf))
    except RuntimeError as error:
        return fail(str(error))
    finally:
        engine.close()
    say(f'{len(got)} detections at {args.conf}+; Ultralytics had {len(want)}')
    ok, lines = compare(got.tolist(), want)
    for line in lines:
        say(line)
    timing = f'mean {sum(walls) / len(walls):.2f} ms a run, GPU {sum(gpus) / len(gpus):.2f} ms ({CHECK_RUNS} runs)'
    say(f'YOLO_CHECK={"PASS" if ok else "FAIL"} {timing}')
    return 0 if ok else 1


# --- Live.

def find_camera():
    """The first USB camera's capture node (index 0), else /dev/video0."""
    found = []
    for node in (SYS / 'class/video4linux').glob('video*'):
        try:
            if (node / 'index').read_text().strip() == '0' and '/usb' in os.path.realpath(node / 'device'):
                found.append(int(node.name[5:]))
        except (OSError, ValueError):
            continue
    return f'/dev/video{min(found)}' if found else '/dev/video0'


class Camera(threading.Thread):
    """Reads frames into a one-frame slot (the newest wins) and prepares each for the model."""

    def __init__(self, device, size, prepare):
        super().__init__(daemon=True)
        self.cap = cv2.VideoCapture(device, cv2.CAP_V4L2)
        if not self.cap.isOpened():
            raise RuntimeError(f'cannot open {device} (in use by another program?)')
        self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'YUYV'))
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, size[0])
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, size[1])
        self.cap.set(cv2.CAP_PROP_FPS, 30)
        self.size = (int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT)))
        fourcc = int(self.cap.get(cv2.CAP_PROP_FOURCC))
        self.mode = f'{fourcc.to_bytes(4, "little").decode(errors="replace")} {self.size[0]}x{self.size[1]} ' \
                    f'at {self.cap.get(cv2.CAP_PROP_FPS):g} fps'
        self.prepare = prepare
        self.cond = threading.Condition()
        self.slot = None   # (seq, time read, frame, (blob, letterbox), prepare ms)
        self.seq = 0
        self.error = None
        self.stopping = False

    def run(self):
        misses = 0
        try:
            while not self.stopping:
                ok, frame = self.cap.read()
                now = time.monotonic()
                if not ok:
                    misses += 1
                    if misses >= 30:
                        raise RuntimeError('the camera stopped giving frames')
                    time.sleep(0.05)
                    continue
                misses = 0
                prepared = self.prepare(frame)
                with self.cond:
                    self.seq += 1
                    self.slot = (self.seq, now, frame, prepared, (time.monotonic() - now) * 1000)
                    self.cond.notify_all()
        except Exception as error:  # reported by the main loop
            self.error = f'{type(error).__name__}: {error}'
        finally:
            with self.cond:
                self.stopping = True
                self.cond.notify_all()

    def newest(self, after, timeout):
        with self.cond:
            self.cond.wait_for(lambda: self.stopping or (self.slot and self.slot[0] > after), timeout)
            return self.slot if self.slot and self.slot[0] > after else None

    def stop(self):
        with self.cond:
            self.stopping = True
        self.join(timeout=5)
        self.cap.release()


class Picture:
    """The newest drawn frame and the stats line, for the web page."""

    def __init__(self):
        self.cond = threading.Condition()
        self.frame, self.seq, self.stats, self.stopping = None, 0, {}, False

    def publish(self, frame, stats):
        with self.cond:
            self.frame, self.stats = frame, stats
            self.seq += 1
            self.cond.notify_all()

    def wait(self, seq, timeout=1.0):
        with self.cond:
            self.cond.wait_for(lambda: self.stopping or self.seq != seq, timeout)
            return self.seq, self.frame

    def stop(self):
        with self.cond:
            self.stopping = True
            self.cond.notify_all()


PAGE = '''<!doctype html><html><head><meta charset="utf-8"><title>Nano camera</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{margin:0;background:#111;color:#ddd;font:14px sans-serif;text-align:center}
img{max-width:100%;height:auto;margin-top:8px}p{margin:6px}</style></head>
<body><img src="/stream" alt="camera"><p id="s"></p><script>
setInterval(async()=>{try{const r=await fetch('/stats');const j=await r.json();
document.getElementById('s').textContent=j.line||''}catch(e){}},1000)</script></body></html>'''


def make_handler(picture):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, kind, body):
            self.send_response(200)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            try:
                if self.path == '/':
                    self.send('text/html; charset=utf-8', PAGE.encode())
                elif self.path == '/stats':
                    self.send('application/json', json.dumps(picture.stats).encode())
                elif self.path == '/snapshot.jpg':
                    _, frame = picture.wait(-1, 0)
                    if frame is None:
                        self.send_error(503, 'no picture yet')
                    else:
                        self.send('image/jpeg', cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 90])[1].tobytes())
                elif self.path == '/stream':
                    self.stream()
                else:
                    self.send_error(404)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def stream(self):
            self.send_response(200)
            self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            seq = 0
            while not picture.stopping:
                new, frame = picture.wait(seq)
                if new == seq or frame is None:
                    continue
                seq = new
                jpg = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY])[1].tobytes()
                self.wfile.write(b'--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n' % len(jpg)
                                 + jpg + b'\r\n')
    return Handler


class Board:
    """GPU load, clock and temperatures, memory left and this program's CPU use."""

    def __init__(self):
        self.load = SYS / 'devices/gpu.0/load'
        self.clock = SYS / 'class/devfreq/57000000.gpu/cur_freq'
        self.zones = {}
        for zone in (SYS / 'class/thermal').glob('thermal_zone*'):
            try:
                kind = (zone / 'type').read_text().strip()
            except OSError:
                continue
            if kind in ('CPU-therm', 'GPU-therm'):
                self.zones[kind[:3].lower()] = zone / 'temp'
        self.cpu = (time.monotonic(), sum(os.times()[:2]))

    @staticmethod
    def number(path):
        try:
            return int(path.read_text().split()[0])
        except (OSError, ValueError, IndexError):
            return None

    def read(self):
        now, used = time.monotonic(), sum(os.times()[:2])
        out = {'cpu_pct': round(100 * (used - self.cpu[1]) / max(now - self.cpu[0], 1e-6))}
        self.cpu = (now, used)
        load, clock = self.number(self.load), self.number(self.clock)
        out['gpu_load_pct'] = None if load is None else round(load / 10)
        out['gpu_mhz'] = None if clock is None else round(clock / 1e6)
        for name, path in self.zones.items():
            t = self.number(path)
            out[f'{name}_c'] = None if t is None else round(t / 1000, 1)
        try:
            meminfo = dict(line.split(':', 1) for line in (PROC / 'meminfo').read_text().splitlines())
            out['mem_free_mb'] = int(meminfo['MemAvailable'].split()[0]) // 1024
        except (OSError, KeyError, ValueError):
            out['mem_free_mb'] = None
        return out


class Events:
    """Watched classes coming into view and leaving it, with snapshots."""

    FIELDS = ('event', 'class', 'start_utc', 'seconds', 'most_at_once', 'best_score', 'snapshot')

    def __init__(self, watch, min_conf, record):
        self.watch, self.min_conf, self.record = watch, min_conf, record
        self.streak = dict.fromkeys(watch, 0)
        self.open = {}   # class -> event row (dict) with its last-seen time
        self.count = 0
        self.file = open(record / 'events.csv', 'w', newline='')
        self.csv = csv.DictWriter(self.file, self.FIELDS)
        self.csv.writeheader()

    def update(self, now, dets, picture):
        for c in self.watch:
            seen = [d for d in dets if int(d[5]) == c and d[4] >= self.min_conf]
            event = self.open.get(c)
            if seen:
                self.streak[c] += 1
                if event:
                    event['last'] = now
                    event['most_at_once'] = max(event['most_at_once'], len(seen))
                    event['best_score'] = max(event['best_score'], max(float(d[4]) for d in seen))
                elif self.streak[c] >= EVENT_FRAMES:
                    self.count += 1
                    snap = f'event-{self.count:03d}-{NAMES[c].replace(" ", "-")}.jpg'
                    cv2.imwrite(str(self.record / snap), picture, [cv2.IMWRITE_JPEG_QUALITY, 90])
                    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
                    self.open[c] = {'event': self.count, 'class': NAMES[c], 'start_utc': stamp, 'start': now,
                                    'last': now, 'most_at_once': len(seen),
                                    'best_score': max(float(d[4]) for d in seen), 'snapshot': snap}
                    say(f'EVENT {self.count} {NAMES[c]} in view ({len(seen)}), snapshot {snap}')
            else:
                self.streak[c] = 0
                if event and now - event['last'] >= EVENT_GAP:
                    self.end(c, now)

    def end(self, c, now):
        event = self.open.pop(c)
        event['seconds'] = round(event['last'] - event['start'], 1)
        event['best_score'] = round(event['best_score'], 3)
        say(f'EVENT {event["event"]} {event["class"]} gone after {event["seconds"]} s '
            f'(most at once {event["most_at_once"]}, best score {event["best_score"]})')
        self.csv.writerow({k: event[k] for k in self.FIELDS})
        self.file.flush()

    def close(self, now):
        for c in list(self.open):
            self.end(c, now)
        self.file.close()


def percentile(values, q):
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q / 100 * (len(s) - 1))))]


def mean(values):
    return sum(values) / len(values) if values else None


def shown(value, unit):
    return '-' if value is None else f'{value}{unit}'


def live(args):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    record = RUNS / stamp
    record.mkdir(parents=True, exist_ok=True)
    say(f'RECORD={record}')

    def fail(why):
        say(f'YOLO_CAM=FAIL: {why}')
        return 1
    try:
        engine = Engine(args.engine, args.lib)
    except (OSError, RuntimeError) as error:
        return fail(f'{args.engine}: {error}')
    say(f'TensorRT {engine.version}; {args.engine}: {engine.describe()}')
    size = tuple(args.size) if args.size else engine.size
    device = args.device or find_camera()
    boxes = {}

    def prepare(frame):
        frame_wh = (frame.shape[1], frame.shape[0])
        box = boxes.get(frame_wh) or boxes.setdefault(frame_wh, Letterbox(frame_wh, engine.size))
        return to_blob(box.apply(frame)), box
    if args.show:
        try:
            cv2.namedWindow('yolo-cam', cv2.WINDOW_AUTOSIZE)
        except cv2.error:
            engine.close()
            return fail("--show found no desktop to draw on; start it from a terminal on the Nano's desktop")
    try:
        camera = Camera(device, size, prepare)
    except RuntimeError as error:
        engine.close()
        return fail(str(error))
    say(f'CAMERA {device}: {camera.mode}')
    watch = []
    for name in filter(None, (n.strip() for n in args.watch.split(','))):
        if name not in NAMES:
            camera.cap.release()
            engine.close()
            return fail(f'unknown class {name!r} for --watch')
        watch.append(NAMES.index(name))
    picture = Picture()
    server = None
    if args.port:
        try:
            server = http.server.ThreadingHTTPServer((args.bind, args.port), make_handler(picture))
        except OSError as error:
            camera.cap.release()
            engine.close()
            return fail(f'cannot serve on {args.bind}:{args.port}: {error}')
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.5}, daemon=True).start()
        say(f'STREAM http://{args.bind}:{args.port}/')
    events = Events(watch, args.event_conf, record)
    board = Board()
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    meta = {'engine': str(args.engine), 'tensorrt': engine.version, 'bindings': engine.describe(),
            'camera': device, 'mode': camera.mode, 'conf': args.conf, 'watch': args.watch,
            'event_conf': args.event_conf, 'started_utc': stamp}
    (record / 'run.json').write_text(json.dumps(meta, indent=1) + '\n')
    stats_file = open(record / 'stats.csv', 'w', newline='')
    fields = ('seconds', 'fps', 'camera_fps', 'prepare_ms', 'infer_ms', 'gpu_ms', 'post_ms', 'latency_ms',
              'detections', 'cpu_pct', 'gpu_load_pct', 'gpu_mhz', 'cpu_c', 'gpu_c', 'mem_free_mb')
    stats_csv = csv.DictWriter(stats_file, fields, extrasaction='ignore')
    stats_csv.writeheader()

    camera.start()
    start = time.monotonic()
    deadline = start + args.seconds if args.seconds else None
    last_seq, error = 0, None
    first_frame_at, last_frame_at = None, start
    banner = pathlib.Path(args.engine).name.removesuffix('.engine')
    window = {k: [] for k in ('prepare', 'infer', 'gpu', 'post', 'latency', 'dets')}
    totals = {k: [] for k in window}
    frames, window_frames, window_start, cam_seq_at_window = 0, 0, start, 0
    banner_fps, last_drawn = 0.0, None
    try:
        while not stop.is_set() and (deadline is None or time.monotonic() < deadline):
            slot = camera.newest(last_seq, timeout=2.0)
            if slot is None:
                if camera.error or camera.stopping:
                    error = camera.error or 'the camera stopped'
                    break
                if time.monotonic() - last_frame_at > 10:
                    error = 'no frame from the camera for 10 s'
                    break
                continue
            seq, t_read, frame, (blob, box), prep_ms = slot
            last_seq, last_frame_at = seq, t_read
            t0 = time.monotonic()
            outs, gpu_ms = engine(blob)
            t1 = time.monotonic()
            dets = box.unmap(decode(outs[0], args.conf))
            t2 = time.monotonic()
            if first_frame_at is None:
                first_frame_at = t2
                window_start, cam_seq_at_window = t2, seq
            else:
                frames += 1
                window_frames += 1
                for k, v in (('prepare', prep_ms), ('infer', (t1 - t0) * 1000), ('gpu', gpu_ms),
                             ('post', (t2 - t1) * 1000), ('latency', (t2 - t_read) * 1000), ('dets', len(dets))):
                    window[k].append(v)
            drawn = draw(frame, dets, f'{banner}  {banner_fps:.1f} FPS  GPU {gpu_ms:.0f} ms  {len(dets)} found')
            last_drawn = drawn
            events.update(t2, dets, drawn)
            if t2 - window_start >= STATS_SECONDS and window_frames:
                span = t2 - window_start
                row = {'seconds': round(t2 - first_frame_at), 'fps': round(window_frames / span, 1),
                       'camera_fps': round((seq - cam_seq_at_window) / span, 1)}
                for k in ('prepare', 'infer', 'gpu', 'post', 'latency'):
                    row[f'{k}_ms'] = round(mean(window[k]), 1)
                row['detections'] = round(mean(window['dets']), 1)
                row.update(board.read())
                stats_csv.writerow(row)
                stats_file.flush()
                banner_fps = row['fps']
                line = (f'{row["seconds"]:>4} s  {row["fps"]:4.1f} fps (camera {row["camera_fps"]:4.1f})  '
                        f'prepare {row["prepare_ms"]} ms, infer {row["infer_ms"]} ms (GPU {row["gpu_ms"]}), '
                        f'post {row["post_ms"]} ms, latency {row["latency_ms"]} ms; {row["detections"]} found; '
                        f'CPU {row["cpu_pct"]}% of a core; GPU {shown(row["gpu_load_pct"], "%")} at '
                        f'{shown(row["gpu_mhz"], " MHz")}, {shown(row.get("gpu_c"), " C")}; '
                        f'CPU {shown(row.get("cpu_c"), " C")}; {shown(row["mem_free_mb"], " MB")} free')
                say(line)
                for k in window:
                    totals[k] += window[k]
                    window[k] = []
                window_frames, window_start, cam_seq_at_window = 0, t2, seq
                picture.stats = {'line': line, **row}
            picture.publish(drawn, picture.stats)
            if args.show:
                cv2.imshow('yolo-cam', drawn)
                if cv2.waitKey(1) & 0xFF in (ord('q'), 27):
                    break
    except RuntimeError as failure:
        error = str(failure)
    finally:
        end = time.monotonic()
        picture.stop()
        if server:
            server.shutdown()
            server.server_close()
        camera.stop()
        engine.close()
        events.close(end)
        stats_file.close()
        if args.show:
            cv2.destroyAllWindows()
    if last_drawn is not None:
        cv2.imwrite(str(record / 'last.jpg'), last_drawn, [cv2.IMWRITE_JPEG_QUALITY, 90])
    for k in window:
        totals[k] += window[k]
    ran = (end - first_frame_at) if first_frame_at else 0.0
    fps = frames / ran if ran > 0 else 0.0
    summary = {**meta, 'seconds': round(ran, 1), 'frames': frames, 'fps': round(fps, 2), 'events': events.count,
               'error': error}
    for k in ('prepare', 'infer', 'gpu', 'post', 'latency'):
        summary[f'{k}_ms_mean'] = None if not totals[k] else round(mean(totals[k]), 2)
        summary[f'{k}_ms_p95'] = None if not totals[k] else round(percentile(totals[k], 95), 2)
    summary['detections_mean'] = None if not totals['dets'] else round(mean(totals['dets']), 2)
    (record / 'summary.json').write_text(json.dumps(summary, indent=1) + '\n')
    say(f'SUMMARY {frames} frames in {ran:.1f} s: {fps:.1f} fps; infer {summary["infer_ms_mean"]} ms mean '
        f'(GPU {summary["gpu_ms_mean"]}, p95 {summary["infer_ms_p95"]}); prepare {summary["prepare_ms_mean"]} ms; '
        f'latency {summary["latency_ms_mean"]} ms mean, p95 {summary["latency_ms_p95"]}; events {events.count}')
    result = (f'fps={fps:.1f} gpu_ms={summary["gpu_ms_mean"]} latency_ms={summary["latency_ms_mean"]} '
              f'frames={frames} events={events.count}')
    if error:
        say(f'YOLO_CAM=FAIL: {error} {result}')
        return 1
    if ran < MIN_SECONDS:
        say(f'YOLO_CAM=FAIL: ran {ran:.1f} s, under {MIN_SECONDS} s {result}')
        return 1
    if fps < MIN_FPS:
        say(f'YOLO_CAM=FAIL: {fps:.1f} fps is under {MIN_FPS} {result}')
        return 1
    say(f'YOLO_CAM=PASS {result}')
    return 0


# --- Video: a file instead of the camera, every frame, written out drawn.

def open_video(path):
    """A capture of the video file at path and its frame rate; RuntimeError if unreadable."""
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise RuntimeError(f'cannot read {path}')
    return cap, cap.get(cv2.CAP_PROP_FPS) or 30.0


def video(args):
    def fail(why):
        say(f'YOLO_VIDEO=FAIL: {why}')
        return 1
    if not args.out:
        return fail('--video needs --out FILE.mp4')
    try:
        cap, fps = open_video(args.video)
    except RuntimeError as error:
        return fail(str(error))
    try:
        engine = Engine(args.engine, args.lib)
    except (OSError, RuntimeError) as error:
        cap.release()
        return fail(f'{args.engine}: {error}')
    say(f'TensorRT {engine.version}; {args.engine}: {engine.describe()}')
    name = pathlib.Path(args.engine).stem
    writer, box, walls, gpus, frames = None, None, [], [], 0
    try:
        while not args.seconds or frames < args.seconds * fps:
            ok, frame = cap.read()
            if not ok:
                break
            if args.size:  # fit inside --size, keeping the video's shape
                scale = min(args.size[0] / frame.shape[1], args.size[1] / frame.shape[0])
                fit = (max(2, round(frame.shape[1] * scale / 2) * 2), max(2, round(frame.shape[0] * scale / 2) * 2))
                frame = cv2.resize(frame, fit, interpolation=cv2.INTER_AREA)
            frame_wh = (frame.shape[1], frame.shape[0])
            if writer is None:
                writer = cv2.VideoWriter(args.out, cv2.VideoWriter_fourcc(*'mp4v'), fps, frame_wh)
                if not writer.isOpened():
                    return fail(f'cannot write {args.out}')
                box = Letterbox(frame_wh, engine.size)
                engine(to_blob(box.apply(frame)))  # the first run sets things up
            blob = to_blob(box.apply(frame))  # live, the capture thread does this beside the GPU
            t = time.perf_counter()
            outs, gpu = engine(blob)
            dets = box.unmap(decode(outs[0], args.conf))
            walls.append((time.perf_counter() - t) * 1000)
            gpus.append(gpu)
            banner = f'{name.split("-")[0]}, TensorRT {engine.version}: {walls[-1]:.0f} ms ({1000 / walls[-1]:.1f} fps)'
            writer.write(draw(frame, dets, banner))
            frames += 1
    except RuntimeError as error:
        return fail(str(error))
    finally:
        cap.release()
        if writer is not None:
            writer.release()
        engine.close()
    if not frames:
        return fail(f'no frames in {args.video}')
    say(f'YOLO_VIDEO=PASS frames={frames} out={args.out} mean {mean(walls):.2f} ms a frame '
        f'(engine and decoding), GPU {mean(gpus):.2f} ms')
    return 0


def size_arg(text):
    try:
        w, h = (int(v) for v in text.lower().split('x'))
    except ValueError:
        raise argparse.ArgumentTypeError('give the size as WIDTHxHEIGHT, such as 640x480')
    return w, h


def main(argv=None):
    p = argparse.ArgumentParser(description='Live YOLO detection on the USB webcam with TensorRT.')
    p.add_argument('--engine', default=str(ENGINE), help='TensorRT engine (default %(default)s)')
    p.add_argument('--lib', default=str(LIB), help="runner library, built for the engine's TensorRT (default %(default)s)")
    p.add_argument('--check', nargs=2, metavar=('IMAGE', 'EXPECTED'), help='compare the engine on a test image')
    p.add_argument('--seconds', type=float, default=0, help='stop after this many seconds (default: Ctrl+C)')
    p.add_argument('--device', help='camera node (default: the first USB camera)')
    p.add_argument('--size', type=size_arg, help="camera size, WIDTHxHEIGHT (default: the engine's input)")
    p.add_argument('--conf', type=float, default=0.25, help='lowest score drawn (default %(default)s)')
    p.add_argument('--watch', default='person', help='classes that make events, comma-separated, or "" (default %(default)s)')
    p.add_argument('--event-conf', type=float, default=0.5, help='lowest score for an event (default %(default)s)')
    p.add_argument('--bind', default='127.0.0.1', help='address of the web stream (default %(default)s)')
    p.add_argument('--port', type=int, default=8080, help='port of the web stream, 0 for none (default %(default)s)')
    p.add_argument('--show', action='store_true', help="also show the picture in a window on the Nano's desktop")
    p.add_argument('--video', help='read this video file instead of the camera')
    p.add_argument('--out', help='with --video: write the drawn video to this MP4')
    args = p.parse_args(argv)
    if args.check:
        return check(args)
    return video(args) if args.video else live(args)


if __name__ == '__main__':
    sys.exit(main())

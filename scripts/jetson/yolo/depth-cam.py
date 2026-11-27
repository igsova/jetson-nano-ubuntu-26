#!/usr/bin/env python3
"""Live metric depth from the USB webcam with TensorRT on the Jetson Nano.

Depth Anything V2 Metric Small, the indoor model (fine-tuned on Hypersim),
gives each pixel's distance from the camera in metres, up to 20 m, from one
picture. setup-depth.sh builds its engines for the default TensorRT (JetPack
4's 8.2 once nano-trt82 is installed); this program runs them through
libnano_trt.so, the runner setup-yolo.sh builds, and yolo-cam.py's engine,
camera and web stream, which it loads from its own folder.

Usage, from an SSH login to the Nano, as your own account (no sudo):
  python3 depth-cam.py [--seconds N] [--engine FILE] [--device /dev/videoN]
                       [--far 10] [--port 8080] [--show]
  python3 depth-cam.py --check IMAGE REFERENCE.npy [--engine FILE] [--save FILE.jpg]
  python3 depth-cam.py --video IN.mp4 --out OUT.mp4 [--seconds N] [--far 10]
An engine of TensorRT 8.5 (probe-depth-trt.sh builds one) runs through
nano-trt85 with 8.5's runner: nano-trt85 python3 depth-cam.py --engine FILE
--lib ~/yolo/trt85/lib/libnano_trt.so ...

Live: the camera (640x480 unless --size says otherwise) is read by a capture
thread that prepares each frame for the model (resized, cubic, to the engine's
input as Depth Anything V2 does); the main loop runs the newest frame through
the engine and serves the camera picture beside its depth map (near red, far
blue, --far metres and beyond dark blue) as an MJPEG stream at
http://BIND:PORT/ (127.0.0.1 by default, so view it through
ssh -L 8080:127.0.0.1:8080). The box in the middle is the centre distance:
the median depth in the middle tenth of the picture, also in the banner, to
hold against a tape measure. --show also opens a window on the Nano's own
desktop. Every STATS_SECONDS a line gives the frame rates, each stage's time,
the centre distance, this program's CPU use, the GPU's load, clock and
temperature, and the memory left. Ctrl+C or --seconds stops it. The record
goes to ~/depth/runs/<stamp>: stats.csv, run.json, last.jpg, last-depth.npy
(metres) and summary.json. The last line is DEPTH_CAM=PASS (it ran without a
camera or engine error and averaged MIN_FPS or more) or DEPTH_CAM=FAIL.

Video: runs a video file through the engine instead of the camera, every
frame in order (its middle cut to --size's shape and scaled to it, 640x480
by default), and writes each frame
beside its depth map to --out (MP4, the input's frame rate). For demos
without a camera; --seconds stops it early. The last line is DEPTH_VIDEO=PASS
with the mean times, or DEPTH_VIDEO=FAIL.

Check: runs the engine on a test picture (export-depth.py made it and
PyTorch's depth for it) and compares: every value a number (not NaN or
infinite), AbsRel (the mean of |engine - PyTorch| / PyTorch) at most
ABS_REL_MAX, and at least WITHIN_MIN of the pixels within WITHIN of PyTorch's
depth. The last line is
DEPTH_CHECK=PASS or FAIL, with the engine's mean time over CHECK_RUNS runs.
"""
import argparse
import csv
import datetime
import http.server
import importlib.util
import json
import pathlib
import signal
import sys
import threading
import time


def load_yolo_cam():
    """yolo-cam.py from this program's folder, as a module."""
    path = pathlib.Path(__file__).resolve().with_name('yolo-cam.py')
    if not path.is_file():
        sys.exit(f'DEPTH_CAM=FAIL: no {path} (setup-depth.sh copies it here)')
    spec = importlib.util.spec_from_file_location('yolo_cam', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cam = load_yolo_cam()
cv2, np = cam.cv2, cam.np

WORK = pathlib.Path.home() / 'depth'
LIB = cam.LIB          # ~/yolo/lib/libnano_trt.so, built by setup-yolo.sh
ENGINE = WORK / 'engines' / 'da2s-indoor-336x252-fp16.engine'
RUNS = WORK / 'runs'
CAMERA_SIZE = (640, 480)
STATS_SECONDS = 5
MIN_FPS = 2.0          # depth often enough for slow indoor driving and mapping
MIN_SECONDS = 10       # a live run shorter than this is not judged
CHECK_RUNS = 20
ABS_REL_MAX = 0.02     # the model's own error indoors is several times this
WITHIN = 0.05
WITHIN_MIN = 0.98
CENTRE = 0.1           # the centre box's share of each side
JPEG_QUALITY = 80


def say(*parts):
    print(*parts, flush=True)


# --- The model's input and output.

def prepare(frame, size):
    """BGR uint8 frame to the model's float32 (1, 3, H, W) for size (W, H):
    resized as Depth Anything V2 resizes (cubic), RGB, 0 to 1. The model
    normalizes it itself."""
    if (frame.shape[1], frame.shape[0]) != tuple(size):
        frame = cv2.resize(frame, tuple(size), interpolation=cv2.INTER_CUBIC)
    return cam.to_blob(frame)


def compare(got, want):
    """How depth got (metres) matches want: the share of its values that are not
    numbers (NaN or infinite), and over the rest AbsRel, the share within WITHIN
    of want and the largest difference in metres."""
    g, w = np.asarray(got, np.float64), np.asarray(want, np.float64)
    if g.shape != w.shape:
        raise ValueError(f'depth of shape {g.shape}, wanted {w.shape}')
    ok = np.isfinite(g)
    err = np.abs(g[ok] - w[ok])
    if not err.size:
        return {'nonfinite': 1.0, 'abs_rel': None, 'within': 0.0, 'max_err_m': None}
    return {'nonfinite': float(1 - ok.mean()), 'abs_rel': float(np.mean(err / np.maximum(w[ok], 1e-3))),
            'within': float(np.mean(err <= WITHIN * w[ok]) * ok.mean()), 'max_err_m': float(err.max())}


def centre(depth):
    """The median depth in the middle CENTRE of each side, and that box as fractions."""
    h, w = depth.shape
    bw, bh = max(1, round(w * CENTRE)), max(1, round(h * CENTRE))
    x0, y0 = (w - bw) // 2, (h - bh) // 2
    return float(np.median(depth[y0:y0 + bh, x0:x0 + bw])), (x0 / w, y0 / h, (x0 + bw) / w, (y0 + bh) / h)


def colour(depth, far, size):
    """Metres to a BGR picture of size (W, H): near red, far blue, beyond far dark blue."""
    scaled = np.clip(depth * (255.0 / far), 0, 255).astype(np.uint8)
    img = cv2.applyColorMap(255 - scaled, cv2.COLORMAP_TURBO)
    return cv2.resize(img, size, interpolation=cv2.INTER_LINEAR)


def text(img, label, origin, scale=0.55):
    (tw, th), base = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, scale, 1)
    x, y = origin
    cv2.rectangle(img, (x, y - th - 4), (x + tw + 8, y + base + 2), (0, 0, 0), -1)
    cv2.putText(img, label, (x + 4, y), cv2.FONT_HERSHEY_SIMPLEX, scale, (255, 255, 255), 1, cv2.LINE_AA)


def compose(frame, depth, far, banner):
    """The camera picture beside its depth map, with the centre box and distance,
    a colour scale and the banner. Returns the picture and the centre distance."""
    h, w = frame.shape[:2]
    metres, (bx0, by0, bx1, by1) = centre(depth)
    right = colour(depth, far, (w, h))
    out = np.hstack([frame, right])
    for x in (0, w):
        cv2.rectangle(out, (x + round(bx0 * w), round(by0 * h)), (x + round(bx1 * w), round(by1 * h)),
                      (255, 255, 255), 2)
    text(out, f'{metres:.2f} m', (w + round(bx1 * w) + 6, round((by0 + by1) / 2 * h) + 6), 0.7)
    bar = cv2.applyColorMap(255 - np.linspace(0, 255, 200).astype(np.uint8)[None].repeat(10, 0), cv2.COLORMAP_TURBO)
    out[h - 30:h - 20, 2 * w - 215:2 * w - 15] = bar
    text(out, '0', (2 * w - 235, h - 18), 0.45)
    text(out, f'{far:g} m', (2 * w - 60, h - 36), 0.45)
    text(out, banner, (0, 18))
    return out, metres


# --- Check: one test picture against PyTorch's depth.

def check(args):
    def fail(why):
        say(f'DEPTH_CHECK=FAIL: {why}')
        return 1
    image, reference = args.check
    img = cv2.imread(image, cv2.IMREAD_COLOR)
    if img is None:
        return fail(f'cannot read {image}')
    try:
        want = np.load(reference)
    except (OSError, ValueError) as error:
        return fail(f'cannot read {reference}: {error}')
    try:
        engine = cam.Engine(args.engine, args.lib)
    except (OSError, RuntimeError) as error:
        return fail(f'{args.engine}: {error}')
    try:
        say(f'TensorRT {engine.version}; {args.engine}: {engine.describe()}')
        blob = prepare(img, engine.size)
        engine(blob)  # the first run sets things up
        walls, gpus = [], []
        for _ in range(CHECK_RUNS):
            t = time.perf_counter()
            outs, gpu = engine(blob)
            walls.append((time.perf_counter() - t) * 1000)
            gpus.append(gpu)
        got = outs[0].reshape(outs[0].shape[-2:]).astype(np.float32)
        found = compare(got, want)
    except (RuntimeError, ValueError) as error:
        return fail(str(error))
    finally:
        engine.close()
    say(f'depth {np.nanmin(got):.2f} to {np.nanmax(got):.2f} m (median {np.nanmedian(got):.2f}); '
        f'PyTorch {want.min():.2f} to {want.max():.2f} m (median {np.median(want):.2f})')
    if args.save:
        picture, _ = compose(img, np.nan_to_num(got), args.far, f'{pathlib.Path(args.engine).stem} on {pathlib.Path(image).name}')
        cv2.imwrite(args.save, picture, [cv2.IMWRITE_JPEG_QUALITY, 90])
    ok = not found['nonfinite'] and found['abs_rel'] <= ABS_REL_MAX and found['within'] >= WITHIN_MIN
    timing = f'mean {sum(walls) / len(walls):.2f} ms a run, GPU {sum(gpus) / len(gpus):.2f} ms ({CHECK_RUNS} runs)'
    shown = lambda v, f: '-' if v is None else format(v, f)
    say(f'DEPTH_CHECK={"PASS" if ok else "FAIL"} abs_rel={shown(found["abs_rel"], ".4f")} '
        f'within{WITHIN * 100:g}%={found["within"] * 100:.2f}% max_err={shown(found["max_err_m"], ".3f")}m '
        f'not_a_number={found["nonfinite"] * 100:.2f}%; {timing}')
    return 0 if ok else 1


# --- Video: a file instead of the camera, every frame, written out drawn.

def video(args):
    def fail(why):
        say(f'DEPTH_VIDEO=FAIL: {why}')
        return 1
    if not args.out:
        return fail('--video needs --out FILE.mp4')
    try:
        cap, fps = cam.open_video(args.video)
    except RuntimeError as error:
        return fail(str(error))
    try:
        engine = cam.Engine(args.engine, args.lib)
    except (OSError, RuntimeError) as error:
        cap.release()
        return fail(f'{args.engine}: {error}')
    say(f'TensorRT {engine.version}; {args.engine}: {engine.describe()}')
    size = tuple(args.size)
    writer = cv2.VideoWriter(args.out, cv2.VideoWriter_fourcc(*'mp4v'), fps, (2 * size[0], size[1]))
    walls, gpus, frames = [], [], 0
    try:
        if not writer.isOpened():
            return fail(f'cannot write {args.out}')
        while not args.seconds or frames < args.seconds * fps:
            ok, frame = cap.read()
            if not ok:
                break
            h, w = frame.shape[:2]  # the middle of a wide video, at --size's shape
            cw, ch = min(w, round(h * size[0] / size[1])), min(h, round(w * size[1] / size[0]))
            frame = frame[(h - ch) // 2:(h - ch) // 2 + ch, (w - cw) // 2:(w - cw) // 2 + cw]
            frame = cv2.resize(frame, size, interpolation=cv2.INTER_AREA)
            blob = prepare(frame, engine.size)
            if not frames:
                engine(blob)  # the first run sets things up
            t = time.perf_counter()
            outs, gpu = engine(blob)
            depth = np.nan_to_num(outs[0].reshape(outs[0].shape[-2:]).astype(np.float32))
            picture, _ = compose(frame, depth, args.far, '')
            walls.append((time.perf_counter() - t) * 1000)  # engine and drawing, as in the live loop
            gpus.append(gpu)
            text(picture, f'Depth Anything V2 Small, TensorRT {engine.version}: '
                          f'{walls[-1]:.0f} ms ({1000 / walls[-1]:.1f} fps)', (0, 18))
            writer.write(picture)
            frames += 1
    except RuntimeError as error:
        return fail(str(error))
    finally:
        cap.release()
        writer.release()
        engine.close()
    if not frames:
        return fail(f'no frames in {args.video}')
    say(f'DEPTH_VIDEO=PASS frames={frames} out={args.out} mean {sum(walls) / frames:.2f} ms a frame, '
        f'GPU {sum(gpus) / frames:.2f} ms')
    return 0


# --- Live.

def live(args):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    record = RUNS / stamp
    record.mkdir(parents=True, exist_ok=True)
    say(f'RECORD={record}')

    def fail(why):
        say(f'DEPTH_CAM=FAIL: {why}')
        return 1
    try:
        engine = cam.Engine(args.engine, args.lib)
    except (OSError, RuntimeError) as error:
        return fail(f'{args.engine}: {error}')
    say(f'TensorRT {engine.version}; {args.engine}: {engine.describe()}')
    device = args.device or cam.find_camera()
    if args.show:
        try:
            cv2.namedWindow('depth-cam', cv2.WINDOW_AUTOSIZE)
        except cv2.error:
            engine.close()
            return fail("--show found no desktop to draw on; start it from a terminal on the Nano's desktop")
    try:
        camera = cam.Camera(device, args.size, lambda frame: prepare(frame, engine.size))
    except RuntimeError as error:
        engine.close()
        return fail(str(error))
    say(f'CAMERA {device}: {camera.mode}')
    picture = cam.Picture()
    server = None
    if args.port:
        try:
            server = http.server.ThreadingHTTPServer((args.bind, args.port), cam.make_handler(picture))
        except OSError as error:
            camera.cap.release()
            engine.close()
            return fail(f'cannot serve on {args.bind}:{args.port}: {error}')
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.5}, daemon=True).start()
        say(f'STREAM http://{args.bind}:{args.port}/')
    board = cam.Board()
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    meta = {'engine': str(args.engine), 'tensorrt': engine.version, 'bindings': engine.describe(),
            'camera': device, 'mode': camera.mode, 'far_m': args.far, 'started_utc': stamp}
    (record / 'run.json').write_text(json.dumps(meta, indent=1) + '\n')
    stats_file = open(record / 'stats.csv', 'w', newline='')
    fields = ('seconds', 'fps', 'camera_fps', 'prepare_ms', 'infer_ms', 'gpu_ms', 'post_ms', 'latency_ms',
              'centre_m', 'cpu_pct', 'gpu_load_pct', 'gpu_mhz', 'cpu_c', 'gpu_c', 'mem_free_mb')
    stats_csv = csv.DictWriter(stats_file, fields, extrasaction='ignore')
    stats_csv.writeheader()

    camera.start()
    start = time.monotonic()
    deadline = start + args.seconds if args.seconds else None
    last_seq, error = 0, None
    first_frame_at, last_frame_at = None, start
    banner = pathlib.Path(args.engine).name.removesuffix('.engine')
    window = {k: [] for k in ('prepare', 'infer', 'gpu', 'post', 'latency', 'centre')}
    totals = {k: [] for k in window}
    frames, window_frames, window_start, cam_seq_at_window = 0, 0, start, 0
    banner_fps, last_drawn, last_depth = 0.0, None, None
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
            seq, t_read, frame, blob, prep_ms = slot
            last_seq, last_frame_at = seq, t_read
            t0 = time.monotonic()
            outs, gpu_ms = engine(blob)
            t1 = time.monotonic()
            depth = outs[0].reshape(outs[0].shape[-2:])
            if not np.isfinite(depth).all():
                error = 'the engine gave depth that is not a number'
                break
            drawn, metres = compose(frame, depth, args.far,
                                    f'{banner}  {banner_fps:.1f} FPS  GPU {gpu_ms:.0f} ms')
            t2 = time.monotonic()
            last_drawn, last_depth = drawn, depth.copy()
            if first_frame_at is None:
                first_frame_at = t2
                window_start, cam_seq_at_window = t2, seq
            else:
                frames += 1
                window_frames += 1
                for k, v in (('prepare', prep_ms), ('infer', (t1 - t0) * 1000), ('gpu', gpu_ms),
                             ('post', (t2 - t1) * 1000), ('latency', (t2 - t_read) * 1000), ('centre', metres)):
                    window[k].append(v)
            if t2 - window_start >= STATS_SECONDS and window_frames:
                span = t2 - window_start
                row = {'seconds': round(t2 - first_frame_at), 'fps': round(window_frames / span, 1),
                       'camera_fps': round((seq - cam_seq_at_window) / span, 1)}
                for k in ('prepare', 'infer', 'gpu', 'post', 'latency'):
                    row[f'{k}_ms'] = round(cam.mean(window[k]), 1)
                row['centre_m'] = round(float(np.median(window['centre'])), 2)
                row.update(board.read())
                stats_csv.writerow(row)
                stats_file.flush()
                banner_fps = row['fps']
                line = (f'{row["seconds"]:>4} s  {row["fps"]:4.1f} fps (camera {row["camera_fps"]:4.1f})  '
                        f'prepare {row["prepare_ms"]} ms, infer {row["infer_ms"]} ms (GPU {row["gpu_ms"]}), '
                        f'post {row["post_ms"]} ms, latency {row["latency_ms"]} ms; centre {row["centre_m"]} m; '
                        f'CPU {row["cpu_pct"]}% of a core; GPU {cam.shown(row["gpu_load_pct"], "%")} at '
                        f'{cam.shown(row["gpu_mhz"], " MHz")}, {cam.shown(row.get("gpu_c"), " C")}; '
                        f'CPU {cam.shown(row.get("cpu_c"), " C")}; {cam.shown(row["mem_free_mb"], " MB")} free')
                say(line)
                for k in window:
                    totals[k] += window[k]
                    window[k] = []
                window_frames, window_start, cam_seq_at_window = 0, t2, seq
                picture.stats = {'line': line, **row}
            picture.publish(drawn, picture.stats)
            if args.show:
                cv2.imshow('depth-cam', drawn)
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
        stats_file.close()
        if args.show:
            cv2.destroyAllWindows()
    if last_drawn is not None:
        cv2.imwrite(str(record / 'last.jpg'), last_drawn, [cv2.IMWRITE_JPEG_QUALITY, 90])
        np.save(record / 'last-depth.npy', last_depth)
    for k in window:
        totals[k] += window[k]
    ran = (end - first_frame_at) if first_frame_at else 0.0
    fps = frames / ran if ran > 0 else 0.0
    summary = {**meta, 'seconds': round(ran, 1), 'frames': frames, 'fps': round(fps, 2), 'error': error}
    for k in ('prepare', 'infer', 'gpu', 'post', 'latency'):
        summary[f'{k}_ms_mean'] = None if not totals[k] else round(cam.mean(totals[k]), 2)
        summary[f'{k}_ms_p95'] = None if not totals[k] else round(cam.percentile(totals[k], 95), 2)
    summary['centre_m_median'] = None if not totals['centre'] else round(float(np.median(totals['centre'])), 2)
    (record / 'summary.json').write_text(json.dumps(summary, indent=1) + '\n')
    say(f'SUMMARY {frames} frames in {ran:.1f} s: {fps:.1f} fps; infer {summary["infer_ms_mean"]} ms mean '
        f'(GPU {summary["gpu_ms_mean"]}, p95 {summary["infer_ms_p95"]}); prepare {summary["prepare_ms_mean"]} ms; '
        f'post {summary["post_ms_mean"]} ms; latency {summary["latency_ms_mean"]} ms mean, '
        f'p95 {summary["latency_ms_p95"]}')
    result = (f'fps={fps:.1f} gpu_ms={summary["gpu_ms_mean"]} latency_ms={summary["latency_ms_mean"]} '
              f'frames={frames}')
    if error:
        say(f'DEPTH_CAM=FAIL: {error} {result}')
        return 1
    if ran < MIN_SECONDS:
        say(f'DEPTH_CAM=FAIL: ran {ran:.1f} s, under {MIN_SECONDS} s {result}')
        return 1
    if fps < MIN_FPS:
        say(f'DEPTH_CAM=FAIL: {fps:.1f} fps is under {MIN_FPS:g} {result}')
        return 1
    say(f'DEPTH_CAM=PASS {result}')
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description='Live metric depth from the USB webcam with TensorRT.')
    p.add_argument('--engine', default=str(ENGINE), help='TensorRT engine (default %(default)s)')
    p.add_argument('--lib', default=str(LIB), help="runner library, built for the engine's TensorRT (default %(default)s)")
    p.add_argument('--check', nargs=2, metavar=('IMAGE', 'REFERENCE'), help="compare the engine with PyTorch's depth")
    p.add_argument('--save', help='with --check: write the picture and its depth map to this JPEG')
    p.add_argument('--seconds', type=float, default=0, help='stop after this many seconds (default: Ctrl+C)')
    p.add_argument('--device', help='camera node (default: the first USB camera)')
    p.add_argument('--size', type=cam.size_arg, default=CAMERA_SIZE, help='camera size, WIDTHxHEIGHT (default 640x480)')
    p.add_argument('--far', type=float, default=10.0, help='depth drawn as the farthest colour, in metres (default %(default)s)')
    p.add_argument('--bind', default='127.0.0.1', help='address of the web stream (default %(default)s)')
    p.add_argument('--port', type=int, default=8080, help='port of the web stream, 0 for none (default %(default)s)')
    p.add_argument('--show', action='store_true', help="also show the picture in a window on the Nano's desktop")
    p.add_argument('--video', help='read this video file instead of the camera')
    p.add_argument('--out', help='with --video: write the picture and its depth map to this MP4')
    args = p.parse_args(argv)
    if args.far <= 0:
        p.error('--far must be above 0')
    if args.check:
        return check(args)
    return video(args) if args.video else live(args)


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Check a USB webcam (UVC) on Ubuntu 26.04 under the 5.10 kernel.

Usage, from an SSH login to the Nano, as the owner's account (no sudo):
    python3 check-usb-webcam.py [--seconds N] [--device /dev/videoN] [--no-audio]

Steps, each printed and kept in ~/webcam-check/<stamp>:
 1. the camera on USB: its ids and names, link speed, and the drivers bound
    to its video and audio interfaces (uvcvideo, snd-usb-audio), with the
    kernel's lines about it since boot;
 2. its V4L2 nodes and their capabilities; the capture node is opened as the
    account (through the video group);
 3. every format, frame size and frame rate the camera offers, and its
    controls with their current values (read only);
 4. capture through V4L2's memory-mapped streaming. First SETTLE (5) s in
    the fastest mode up to 640x480, so the camera's automatic exposure and
    white balance adapt (in the first run on the Nano, the first mode's
    picture came out blue without it). Then up to three modes per format
    (its largest size, 1280x720 and 640x480, each at its highest rate):
    after a 1 s warm-up, SECONDS (default 4) of frames, with the rate
    from the driver's timestamps, the frames it skipped or marked bad, and
    whether the picture changes from frame to frame. MJPEG frames must be
    whole JPEGs of the size asked for. The last frame of each format's
    largest mode is saved to look at: MJPEG as the camera sent it (with the
    standard Huffman tables added when the camera leaves them out, as many
    do), YUYV and UYVY as a half-size PNG;
 5. the kernel's USB and uvcvideo lines during the captures;
 6. when GStreamer's v4l2src is installed (gstreamer1.0-plugins-good), 30
    frames through it in the format GStreamer picks;
 7. the camera's microphone, when it has one: 5 s recorded through ALSA
    (arecord, or ALSA's library when arecord is missing), its level, and the
    WAV file to listen to.
Nothing is installed or changed on disk outside the record; like any
capture program, it sets the camera's format and frame rate while it runs.

A mode passes when frames arrive steadily, fewer than 5 % carry the driver's
error flag or (MJPEG) are broken, and the frames are not all the same. A
mode below 80 % of its frame rate fails, unless the camera's dynamic frame
rate control is on: then the camera lengthens its exposure in dim light, and
the mode is reported as slow-in-dim-light instead. The last line is
USB_WEBCAM_CHECK=PASS or USB_WEBCAM_CHECK=FAIL, with the modes' results and
the microphone's (mic=pass, none, skipped, busy, no-access or fail; the
microphone does not decide the result).
"""
import argparse
import array
import ctypes
import errno
import fcntl
import itertools
import math
import mmap
import os
import re
import select
import shutil
import struct
import subprocess
import sys
import time
import wave
import zlib

KERNEL = '5.10.216-tegra'
SYS, DEV, PROC = '/sys', '/dev', '/proc'
ioctl = fcntl.ioctl
map_buffer = mmap.mmap

# V4L2 (linux/videodev2.h; the same layout on any 64-bit Linux).
def _ioc(direction, nr, size):
    return (direction << 30) | (size << 16) | (ord('V') << 8) | nr
R, W, RW = 2, 1, 3
QUERYCAP = _ioc(R, 0, 104)
ENUM_FMT = _ioc(RW, 2, 64)
S_FMT = _ioc(RW, 5, 208)
REQBUFS = _ioc(RW, 8, 20)
QUERYBUF = _ioc(RW, 9, 88)
QBUF = _ioc(RW, 15, 88)
DQBUF = _ioc(RW, 17, 88)
STREAMON = _ioc(W, 18, 4)
STREAMOFF = _ioc(W, 19, 4)
G_PARM = _ioc(RW, 21, 204)
S_PARM = _ioc(RW, 22, 204)
G_CTRL = _ioc(RW, 27, 8)
QUERYCTRL = _ioc(RW, 36, 68)
QUERYMENU = _ioc(RW, 37, 44)
ENUM_FRAMESIZES = _ioc(RW, 74, 44)
ENUM_FRAMEINTERVALS = _ioc(RW, 75, 52)
CAPTURE, MEMORY_MMAP = 1, 1
CAP_VIDEO_CAPTURE, CAP_META_CAPTURE = 0x1, 0x00800000
CAP_STREAMING, CAP_DEVICE_CAPS = 0x04000000, 0x80000000
FMT_FLAG_COMPRESSED = 0x1
BUF_FLAG_ERROR = 0x40
CTRL_NEXT, CTRL_DISABLED = 0x80000000, 0x1
CTRL_MENU, CTRL_CLASS = 3, 6
CID_EXPOSURE_AUTO_PRIORITY = 0x009a0903  # "Exposure, Dynamic Framerate"

WARMUP = 1.0
SETTLE = 5.0
GOOD_RATE = 0.8
BAD_SHARE = 0.05
BUFFERS = 4
MIC_SECONDS = 5

# The standard Huffman tables (JPEG Annex K.3, as libjpeg writes them), for
# MJPEG frames that leave them out.
STANDARD_DHT = bytes.fromhex(
    '0000010501010101010100000000000000000102030405060708090a0b10000201030302'
    '0403050504040000017d01020300041105122131410613516107227114328191a1082342'
    'b1c11552d1f02433627282090a161718191a25262728292a3435363738393a4344454647'
    '48494a535455565758595a636465666768696a737475767778797a838485868788898a92'
    '939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2'
    'd3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9fa0100030101010101'
    '010101010000000000000102030405060708090a0b110002010204040304070504040001'
    '0277000102031104052131061241510761711322328108144291a1b1c109233352f01562'
    '72d10a162434e125f11718191a262728292a35363738393a434445464748494a53545556'
    '5758595a636465666768696a737475767778797a82838485868788898a92939495969798'
    '999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8'
    'd9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa')

record = None
_summary = None


def say(line=''):
    print(line, flush=True)
    if _summary:
        _summary.write(line + '\n')
        _summary.flush()


def keep(name, text):
    with open(os.path.join(record, name), 'w') as f:
        f.write(text)


def fail(message):
    say(f'USB_WEBCAM_CHECK=FAIL: {message}' + (f' record={record}' if record else ''))
    sys.exit(1)


def cstr(raw):
    return bytes(raw).split(b'\0', 1)[0].decode('utf-8', 'replace')


def fourcc(code):
    return code.to_bytes(4, 'little').decode('ascii', 'replace').rstrip()


def xioctl(fd, request, buf):
    while True:
        try:
            ioctl(fd, request, buf, True)
            return buf
        except InterruptedError:
            continue


def read(path, default=''):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


# 1. The camera on USB.
def usb_cameras():
    """USB devices with a video interface: (sysfs path, name, interfaces)."""
    found = []
    base = f'{SYS}/bus/usb/devices'
    for name in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        dev = os.path.realpath(os.path.join(base, name))
        if ':' in name or not os.path.exists(f'{dev}/idVendor'):
            continue
        interfaces = []
        for intf in sorted(glob_dirs(dev, name + ':')):
            cls = read(f'{intf}/bInterfaceClass')
            driver = os.path.basename(os.path.realpath(f'{intf}/driver')) if os.path.exists(f'{intf}/driver') else 'none'
            interfaces.append((os.path.basename(intf), cls, read(f'{intf}/bInterfaceSubClass'), driver))
        if any(cls == '0e' for _, cls, _, _ in interfaces):
            found.append((dev, name, interfaces))
    return found


def glob_dirs(path, prefix):
    try:
        return [os.path.join(path, n) for n in os.listdir(path) if n.startswith(prefix)]
    except OSError:
        return []


def all_usb():
    base = f'{SYS}/bus/usb/devices'
    out = []
    for name in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        dev = os.path.join(base, name)
        if ':' not in name and os.path.exists(f'{dev}/idVendor'):
            out.append(f'{read(dev + "/idVendor")}:{read(dev + "/idProduct")} {read(dev + "/product", "?")}')
    return out


# 2. V4L2 nodes.
def video_nodes(usb_path):
    nodes = []
    base = f'{SYS}/class/video4linux'
    for name in sorted(os.listdir(base), key=lambda n: int(re.sub(r'\D', '', n) or 0)) if os.path.isdir(base) else []:
        target = os.path.realpath(f'{base}/{name}/device')
        if target == usb_path or target.startswith(usb_path + '/'):
            nodes.append(name)
    return nodes


def querycap(fd):
    b = xioctl(fd, QUERYCAP, bytearray(104))
    caps, device_caps = struct.unpack_from('<II', b, 84)
    return {'driver': cstr(b[0:16]), 'card': cstr(b[16:48]), 'bus': cstr(b[48:80]),
            'caps': device_caps if caps & CAP_DEVICE_CAPS else caps}


# 3. Formats, sizes, rates and controls.
def enum(fd, request, size, fill):
    """Each answer of an indexed V4L2 enumeration, until EINVAL."""
    for i in itertools.count():
        b = bytearray(size)
        fill(b, i)
        try:
            xioctl(fd, request, b)
        except OSError as e:
            if e.errno == errno.EINVAL:
                return
            raise
        yield b


def formats(fd):
    out = []
    for b in enum(fd, ENUM_FMT, 64, lambda b, i: struct.pack_into('<II', b, 0, i, CAPTURE)):
        flags, = struct.unpack_from('<I', b, 8)
        pix, = struct.unpack_from('<I', b, 44)
        out.append({'pix': pix, 'name': fourcc(pix), 'desc': cstr(b[12:44]),
                    'compressed': bool(flags & FMT_FLAG_COMPRESSED), 'sizes': sizes(fd, pix)})
    return out


def sizes(fd, pix):
    """{(width, height): [(numerator, denominator), ...]}, the shortest interval first."""
    out = {}
    for b in enum(fd, ENUM_FRAMESIZES, 44, lambda b, i: struct.pack_into('<II', b, 0, i, pix)):
        kind, = struct.unpack_from('<I', b, 8)
        if kind == 1:
            dims = [struct.unpack_from('<II', b, 12)]
        else:  # continuous or stepwise: the two ends
            min_w, max_w, _, min_h, max_h, _ = struct.unpack_from('<6I', b, 12)
            dims = [(min_w, min_h), (max_w, max_h)]
        for w, h in dims:
            out[(w, h)] = intervals(fd, pix, w, h)
        if kind != 1:
            break
    return out


def intervals(fd, pix, w, h):
    out = []
    for b in enum(fd, ENUM_FRAMEINTERVALS, 52, lambda b, i: struct.pack_into('<IIII', b, 0, i, pix, w, h)):
        kind, = struct.unpack_from('<I', b, 16)
        if kind == 1:
            out.append(struct.unpack_from('<II', b, 20))
        else:  # continuous or stepwise: the shortest and longest
            out += [struct.unpack_from('<II', b, 20), struct.unpack_from('<II', b, 28)]
            break
    return sorted({iv for iv in out if iv[0] and iv[1]}, key=lambda iv: iv[0] / iv[1])


def rate(iv):
    return iv[1] / iv[0]


def fps_text(rates):
    return ','.join(f'{r:g}' for r in rates)


def controls(fd):
    out, cid = [], CTRL_NEXT
    while True:
        b = bytearray(68)
        struct.pack_into('<I', b, 0, cid)
        try:
            xioctl(fd, QUERYCTRL, b)
        except OSError as e:
            if e.errno == errno.EINVAL:
                return out
            raise
        found, kind = struct.unpack_from('<II', b, 0)
        low, high, step, default, flags = struct.unpack_from('<iiiiI', b, 40)
        cid = found | CTRL_NEXT
        if kind == CTRL_CLASS or flags & CTRL_DISABLED:
            continue
        value = None
        c = bytearray(struct.pack('<Ii', found, 0))
        try:
            value = struct.unpack_from('<i', xioctl(fd, G_CTRL, c), 4)[0]
        except OSError:
            pass
        label = ''
        if kind == CTRL_MENU and value is not None:
            m = bytearray(44)
            struct.pack_into('<II', m, 0, found, value)
            try:
                label = cstr(xioctl(fd, QUERYMENU, m)[8:40])
            except OSError:
                pass
        out.append({'id': found, 'name': cstr(b[8:40]), 'min': low, 'max': high, 'default': default,
                    'value': value, 'label': label})


# 4. Capture.
def set_mode(fd, pix, w, h, iv):
    b = bytearray(208)
    struct.pack_into('<IIIII', b, 0, CAPTURE, 0, w, h, pix)
    xioctl(fd, S_FMT, b)
    got_w, got_h, got_pix, _, bpl, size = struct.unpack_from('<6I', b, 8)
    p = bytearray(204)
    struct.pack_into('<IIIII', p, 0, CAPTURE, 0, 0, iv[0], iv[1])
    try:
        xioctl(fd, S_PARM, p)
    except OSError:
        xioctl(fd, G_PARM, p)
    _, _, num, den = struct.unpack_from('<IIII', p, 4)
    return {'w': got_w, 'h': got_h, 'pix': got_pix, 'bpl': bpl, 'size': size,
            'rate': den / num if num and den else 0.0}


def buffer_struct(index=0):
    b = bytearray(88)
    struct.pack_into('<II', b, 0, index, CAPTURE)
    struct.pack_into('<I', b, 60, MEMORY_MMAP)
    return b


def stream(fd, seconds, interval, on_frame):
    """Capture for WARMUP + seconds; on_frame(data, sequence, timestamp, flags, counted).

    A wait for a frame longer than 5 s (the first) or three frame intervals
    (at least 2 s) counts as a stall; the second stall ends the capture.
    """
    req = bytearray(struct.pack('<5I', BUFFERS, CAPTURE, MEMORY_MMAP, 0, 0))
    xioctl(fd, REQBUFS, req)
    count, = struct.unpack_from('<I', req, 0)
    if count < 2:
        raise OSError(errno.ENOMEM, f'the driver gave {count} buffers')
    maps = []
    stalls = 0
    try:
        for i in range(count):
            b = xioctl(fd, QUERYBUF, buffer_struct(i))
            offset, = struct.unpack_from('<I', b, 64)
            length, = struct.unpack_from('<I', b, 72)
            maps.append(map_buffer(fd, length, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=offset))
            xioctl(fd, QBUF, buffer_struct(i))
        xioctl(fd, STREAMON, bytearray(struct.pack('<i', CAPTURE)))
        start = time.monotonic()
        wait = 5.0
        while time.monotonic() - start < WARMUP + seconds:
            ready, _, _ = select.select([fd], [], [], wait)
            if not ready:
                stalls += 1
                if stalls >= 2:
                    break
                continue
            b = buffer_struct()
            try:
                xioctl(fd, DQBUF, b)
            except OSError as e:
                if e.errno == errno.EAGAIN:
                    continue
                raise
            index, _, used, flags = struct.unpack_from('<4I', b, 0)
            sec, usec = struct.unpack_from('<qq', b, 24)
            sequence, = struct.unpack_from('<I', b, 56)
            on_frame(maps[index][:used], sequence, sec + usec / 1e6, flags, time.monotonic() - start >= WARMUP)
            wait = max(2.0, 3 * interval)
            xioctl(fd, QBUF, buffer_struct(index))
    finally:
        try:
            xioctl(fd, STREAMOFF, bytearray(struct.pack('<i', CAPTURE)))
        except OSError:
            pass
        for m in maps:
            m.close()
        try:
            xioctl(fd, REQBUFS, bytearray(struct.pack('<5I', 0, CAPTURE, MEMORY_MMAP, 0, 0)))
        except OSError:
            pass
    return stalls


def jpeg_info(data):
    """(width, height, has Huffman tables) of a whole JPEG, or None."""
    if data[:2] != b'\xff\xd8' or data.rfind(b'\xff\xd9') < 0:
        return None
    i, dims, dht = 2, None, False
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            return None
        marker = data[i + 1]
        if marker == 0xFF:
            i += 1
            continue
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        length = int.from_bytes(data[i + 2:i + 4], 'big')
        if marker == 0xC4:
            dht = True
        elif 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC) and i + 9 <= len(data):
            dims = (int.from_bytes(data[i + 7:i + 9], 'big'), int.from_bytes(data[i + 5:i + 7], 'big'))
        elif marker == 0xDA:
            return (dims[0], dims[1], dht) if dims else None
        i += 2 + length
    return None


def with_huffman(data):
    """A camera's MJPEG frame as a JPEG file any viewer opens."""
    info = jpeg_info(data)
    if not info or info[2]:
        return data
    return data[:2] + b'\xff\xc4' + (len(STANDARD_DHT) + 2).to_bytes(2, 'big') + STANDARD_DHT + data[2:]


def yuv422_png(data, w, h, bpl, order):
    """A half-size RGB PNG from a YUYV or UYVY frame (BT.601, limited range)."""
    y0, u0, v0 = (0, 1, 3) if order == 'YUYV' else (1, 0, 2)
    clip = bytes(min(255, max(0, i - 512)) for i in range(1536))
    yt = [298 * (y - 16) + 128 + (512 << 8) for y in range(256)]
    rv = [409 * (v - 128) for v in range(256)]
    gu = [100 * (u - 128) for u in range(256)]
    gv = [208 * (v - 128) for v in range(256)]
    bu = [516 * (u - 128) for u in range(256)]
    rows = []
    for row in range(0, h - 1, 2):
        line = data[row * bpl:row * bpl + w * 2]
        ys, us, vs = line[y0::4], line[u0::4], line[v0::4]
        out = bytearray(len(ys) * 3)
        for j, (y, u, v) in enumerate(zip(ys, us, vs)):
            base = yt[y]
            out[3 * j] = clip[(base + rv[v]) >> 8]
            out[3 * j + 1] = clip[(base - gu[u] - gv[v]) >> 8]
            out[3 * j + 2] = clip[(base + bu[u]) >> 8]
        rows.append(bytes(out))
    return png(len(ys), len(rows), rows)


def png(width, height, rows):
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
    raw = b''.join(b'\0' + r for r in rows)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def luma(data, w, h, bpl, order):
    """Mean and standard deviation of a sample of a YUYV or UYVY frame's luma."""
    first = 0 if order == 'YUYV' else 1
    sample = []
    for row in range(0, h, max(1, h // 48)):
        sample += data[row * bpl + first:row * bpl + w * 2:2][::max(1, w // 64)]
    mean = sum(sample) / len(sample)
    return mean, math.sqrt(sum((s - mean) ** 2 for s in sample) / len(sample))


def capture_mode(fd, fmt, size, iv, seconds, dynamic, keep_preview):
    w, h = size
    nominal = rate(iv)
    label = f'{fmt["name"]} {w}x{h}@{nominal:g}'
    try:
        got = set_mode(fd, fmt['pix'], w, h, iv)
    except OSError as e:
        say(f'CAPTURE {label}: the driver refused the mode ({e.strerror})')
        return label, 'fail'
    if (got['w'], got['h'], got['pix']) != (w, h, fmt['pix']):
        say(f'CAPTURE {label}: the driver set {fourcc(got["pix"])} {got["w"]}x{got["h"]} instead')
        return label, 'fail'
    frames = []  # (sequence, timestamp, flags, used, crc, good)
    last = {}

    def on_frame(data, sequence, stamp, flags, counted):
        if not counted:
            return
        good = len(data) > 0
        if fmt['name'] == 'MJPG':
            info = jpeg_info(data)
            good = bool(info) and info[:2] == (w, h)
        elif not fmt['compressed'] and got['size']:
            good = len(data) >= got['size']
        frames.append((sequence, stamp, flags, len(data), zlib.crc32(data), good))
        last['data'] = data

    try:
        stalls = stream(fd, seconds, 1 / (got['rate'] or nominal), on_frame)
    except OSError as e:
        say(f'CAPTURE {label}: streaming failed ({e.strerror or e})')
        return label, 'fail'
    n = len(frames)
    if n < 2:
        say(f'CAPTURE {label}: {n} frames in {seconds:g} s' + (', the stream stalled' if stalls else ''))
        return label, 'fail'
    span = frames[-1][1] - frames[0][1]
    measured = (n - 1) / span if span > 0 else 0.0
    skipped = sum(max(0, b[0] - a[0] - 1) for a, b in zip(frames, frames[1:]))
    errors = sum(1 for f in frames if f[2] & BUF_FLAG_ERROR)
    broken = sum(1 for f in frames if not f[5])
    distinct = len({f[4] for f in frames})
    average = sum(f[3] for f in frames) / n
    notes = []
    if fmt['name'] in ('YUYV', 'UYVY') and 'data' in last:
        mean, sd = luma(last['data'], w, h, got['bpl'] or w * 2, fmt['name'])
        notes.append(f'luma mean {mean:.0f} sd {sd:.0f}' + (' (flat: is the lens covered?)' if sd < 2 else ''))
    status = 'ok'
    if errors > BAD_SHARE * n or broken > BAD_SHARE * n or distinct == 1 or stalls:
        status = 'fail'
    elif measured < GOOD_RATE * nominal:
        status = 'slow-in-dim-light' if dynamic else 'fail'
    say(f'CAPTURE {label}: {n} frames, {measured:.1f} fps (set {got["rate"]:g}), skipped {skipped}, '
        f'error-flagged {errors}, broken {broken}, distinct {distinct}, {average / 1024:.0f} KiB a frame'
        + (f', stalled {stalls}x' if stalls else '') + ''.join(f', {x}' for x in notes) + f' -> {status}')
    if keep_preview and 'data' in last:
        data = last['data']
        name = None
        if fmt['name'] == 'MJPG' and jpeg_info(data):
            name = f'preview-MJPG-{w}x{h}.jpg'
            body = with_huffman(data)
        elif fmt['name'] in ('YUYV', 'UYVY'):
            name = f'preview-{fmt["name"]}-{w}x{h}-half.png'
            body = yuv422_png(data, w, h, got['bpl'] or w * 2, fmt['name'])
        if name:
            with open(os.path.join(record, name), 'wb') as f:
                f.write(body)
            say(f'PREVIEW {record}/{name}')
    return label, status


def settle(fd, fmts):
    """SETTLE seconds of frames in a fast mode, so the camera's automatic exposure
    and white balance adapt to the scene before the first measured mode."""
    fast = [(rate(ivs[0]), w * h, fmt, (w, h), ivs[0])
            for fmt in fmts for (w, h), ivs in fmt['sizes'].items() if ivs and w * h <= 640 * 480]
    if not fast:
        return
    _, _, fmt, (w, h), iv = max(fast, key=lambda m: m[:2])
    try:
        set_mode(fd, fmt['pix'], w, h, iv)
        stream(fd, SETTLE - WARMUP, 1 / rate(iv), lambda *frame: None)
    except OSError as e:
        say(f'SETTLE: {fmt["name"]} {w}x{h} failed ({e.strerror or e}); the first mode may show an unsettled picture')
        return
    say(f'SETTLE: {SETTLE:g} s in {fmt["name"]} {w}x{h}@{rate(iv):g} for the automatic exposure and white balance')


def pick_modes(fmt):
    """The largest size, 1280x720 and 640x480, each at its highest rate."""
    ranked = sorted((s for s, ivs in fmt['sizes'].items() if ivs), key=lambda s: s[0] * s[1], reverse=True)
    chosen = ranked[:1] + [s for s in ((1280, 720), (640, 480)) if s in ranked[1:]]
    return [(s, fmt['sizes'][s][0]) for s in chosen]


# 7. The microphone.
def sound_card(usb_path):
    base = f'{SYS}/class/sound'
    for name in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        if not re.fullmatch(r'card\d+', name):
            continue
        target = os.path.realpath(f'{base}/{name}/device')
        if target.startswith(usb_path + '/'):
            index = name[4:]
            return index, read(f'{PROC}/asound/card{index}/id', index)
    return None


def record_alsa(device, path):
    """5 s of 16 kHz mono through ALSA's library; returns None or the error."""
    try:
        lib = ctypes.CDLL('libasound.so.2')
    except OSError:
        return 'no ALSA library'
    lib.snd_strerror.restype = ctypes.c_char_p
    lib.snd_pcm_readi.restype = ctypes.c_long
    lib.snd_pcm_readi.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
    lib.snd_pcm_recover.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    pcm = ctypes.c_void_p()
    rc = lib.snd_pcm_open(ctypes.byref(pcm), device.encode(), 1, 0)  # capture, blocking
    if rc < 0:
        return f'{-rc}:{lib.snd_strerror(rc).decode()}'
    try:
        rc = lib.snd_pcm_set_params(pcm, 2, 3, 1, 16000, 1, 500000)  # S16_LE, interleaved, mono
        if rc < 0:
            return f'{-rc}:{lib.snd_strerror(rc).decode()}'
        chunk = ctypes.create_string_buffer(1600 * 2)
        pcm_data = bytearray()
        while len(pcm_data) < MIC_SECONDS * 16000 * 2:
            n = lib.snd_pcm_readi(pcm, chunk, 1600)
            if n < 0:
                if lib.snd_pcm_recover(pcm, int(n), 1) < 0:
                    return f'{-n}:{lib.snd_strerror(int(n)).decode()}'
                continue
            pcm_data += chunk.raw[:n * 2]
    finally:
        lib.snd_pcm_close(pcm)
    with wave.open(path, 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(16000)
        f.writeframes(bytes(pcm_data))
    return None


def mic_check(usb_path):
    card = sound_card(usb_path)
    if not card:
        say('MIC: none (the camera has no USB audio interface with a sound card)')
        return 'none'
    index, card_id = card
    device = f'plughw:CARD={card_id},DEV=0'
    path = os.path.join(record, 'mic.wav')
    say(f'MIC: card {index} ({card_id}); RECORDING {MIC_SECONDS} s: speak or clap near the camera now')
    if shutil.which('arecord'):
        run = subprocess.run(['timeout', str(MIC_SECONDS + 10), 'arecord', '-q', '-D', device, '-f', 'S16_LE',
                              '-r', '16000', '-c', '1', '-d', str(MIC_SECONDS), path],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, check=False)
        problem = None if run.returncode == 0 else (run.stdout.strip().splitlines() or [f'exit {run.returncode}'])[-1]
        tool = 'arecord'
    else:
        problem, tool = record_alsa(device, path), "ALSA's library"
    if problem:
        kind = 'busy' if 'busy' in problem.lower() else 'no-access' if 'permission' in problem.lower() else 'fail'
        say(f'MIC: {tool} could not record from {device}: {problem}')
        if kind == 'no-access':
            say(f'MIC: the account is in groups {subprocess.run(["id", "-nG"], stdout=subprocess.PIPE, universal_newlines=True, check=False).stdout.strip()}; the audio group gives access')
        return kind
    with wave.open(path, 'rb') as f:
        samples = array.array('h', f.readframes(f.getnframes()))
    if sys.byteorder != 'little':
        samples.byteswap()
    if not samples:
        say('MIC: the recording is empty')
        return 'fail'
    peak = max(abs(s) for s in samples)
    rms = math.sqrt(sum(s * s for s in samples) / len(samples))
    def db(x):
        return 20 * math.log10(x / 32768) if x else float('-inf')
    say(f'MIC: {len(samples) / 16000:.1f} s with {tool}, level {db(rms):.1f} dBFS RMS, peak {db(peak):.1f} dBFS'
        + (' (silent: every sample is 0)' if peak == 0 else ''))
    say(f'MIC_RECORDING {path}')
    return 'pass' if peak else 'fail'


def kernel_lines(pattern, since=None):
    """This boot's kernel lines matching pattern, from journalctl (the adm group)
    or dmesg, from a CLOCK_MONOTONIC time on; None when the account may read neither."""
    lines = None
    for command in (['journalctl', '-k', '-b', '--no-pager', '-o', 'short-monotonic'], ['dmesg']):
        run = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True,
                             check=False)
        found = [line for line in run.stdout.splitlines() if re.match(r'\[\s*\d+\.\d+\]', line)]
        if run.returncode == 0 and found:
            lines = found
            break
    if lines is None:
        return None
    if since is not None:
        lines = [line for line in lines if float(re.match(r'\[\s*(\d+\.\d+)\]', line).group(1)) >= since]
    # Serial numbers stay out of the record.
    return [line for line in lines if re.search(pattern, line, re.I) and 'SerialNumber' not in line]


def main():
    global record, _summary
    parser = argparse.ArgumentParser(description='Check a USB webcam on the Nano.')
    parser.add_argument('--seconds', type=float, default=4.0, help='seconds of frames a mode (default 4)')
    parser.add_argument('--device', help='the capture node (default: the first USB camera\'s)')
    parser.add_argument('--no-audio', action='store_true', help='leave out the microphone')
    args = parser.parse_args()
    if os.geteuid() == 0:
        fail('run this as your own account, without sudo')
    uname = os.uname()
    if uname.machine != 'aarch64' or uname.release != KERNEL:
        fail(f"run this on the Nano's {KERNEL} kernel")

    stamp = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    record = os.path.join(os.path.expanduser('~'), 'webcam-check', stamp)
    os.makedirs(record)
    _summary = open(os.path.join(record, 'summary.txt'), 'w')
    start = time.monotonic() - 1
    say(f'RECORD={record}')
    say(f'KERNEL={uname.release}')
    os_name = re.search(r'^PRETTY_NAME="?([^"\n]*)', read('/etc/os-release'), re.M)
    say(f'OS={os_name.group(1) if os_name else "unknown"}')

    # 1. USB.
    cameras = usb_cameras()
    if not cameras:
        for line in all_usb():
            say(f'  usb: {line}')
        fail('no USB device with a video interface (USB class 0e); is the camera plugged in?')
    if len(cameras) > 1:
        say(f'USB_CAMERAS={len(cameras)}; checking the first ({cameras[0][1]}) unless --device names another')
    if args.device:
        node = os.path.basename(args.device)
        cameras = [c for c in cameras if node in video_nodes(c[0])] or fail(f'{args.device} is not a USB camera\'s node')
    usb_path, usb_name, interfaces = cameras[0]
    names = ' '.join(n for n in (read(f'{usb_path}/manufacturer'), read(f'{usb_path}/product')) if n)
    say(f'USB_CAMERA={read(usb_path + "/idVendor")}:{read(usb_path + "/idProduct")} '
        + (f'"{names}" ' if names else '(no name strings) ')
        + f'port={usb_name} speed={read(usb_path + "/speed")}Mb/s usb={read(usb_path + "/version")} '
        f'power={read(usb_path + "/bMaxPower")}')
    kinds = {('0e', '01'): 'video control', ('0e', '02'): 'video streaming',
             ('01', '01'): 'audio control', ('01', '02'): 'audio streaming'}
    for intf, cls, sub, driver in interfaces:
        say(f'  interface {intf}: {kinds.get((cls, sub), f"class {cls}/{sub}")}, driver {driver}')
    if not any(cls == '0e' and driver == 'uvcvideo' for _, cls, _, driver in interfaces):
        fail('uvcvideo is not bound to the camera\'s video interfaces')
    module = re.search(r'^uvcvideo ', read(PROC + '/modules'), re.M)
    say(f'UVCVIDEO={"module" if module else "built in"} {read(SYS + "/module/uvcvideo/version", "")}'.rstrip())
    mine = kernel_lines(rf'usb {re.escape(usb_name)}:|uvcvideo|UVC')
    if mine is None:
        say('KERNEL_LOG=unreadable by the account (journalctl needs the adm group)')
    else:
        keep('kernel-boot.txt', '\n'.join(mine) + '\n')
        for line in mine[-8:]:
            say(f'  boot kernel: {line[:160]}')

    # 2. Nodes.
    nodes = video_nodes(usb_path)
    capture_node = None
    for name in nodes:
        path = f'{DEV}/{name}'
        try:
            fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        except OSError as e:
            say(f'NODE {path}: cannot open ({e.strerror})')
            if e.errno == errno.EACCES:
                groups = subprocess.run(['id', '-nG'], stdout=subprocess.PIPE, universal_newlines=True, check=False).stdout.strip()
                fail(f'no access to {path}; the account is in groups {groups}, and the video group gives access')
            continue
        try:
            cap = querycap(fd)
        finally:
            os.close(fd)
        roles = [r for bit, r in ((CAP_VIDEO_CAPTURE, 'video capture'), (CAP_META_CAPTURE, 'metadata'),
                                  (CAP_STREAMING, 'streaming')) if cap['caps'] & bit]
        say(f'NODE {path}: driver {cap["driver"]}, "{cap["card"]}", {cap["bus"]}, {", ".join(roles) or hex(cap["caps"])}')
        if (args.device in (None, path, name)) and capture_node is None and cap['caps'] & CAP_VIDEO_CAPTURE:
            capture_node = path
    if not capture_node:
        fail('the camera has no video capture node')
    say(f'CAPTURE_NODE={capture_node}')

    fd = os.open(capture_node, os.O_RDWR | os.O_NONBLOCK)
    try:
        # 3. Formats and controls.
        fmts = formats(fd)
        if not fmts:
            fail(f'{capture_node} lists no formats')
        listing = []
        for fmt in fmts:
            say(f'FORMAT {fmt["name"]} "{fmt["desc"]}"' + (' (compressed)' if fmt['compressed'] else ''))
            for (w, h), ivs in sorted(fmt['sizes'].items(), key=lambda s: s[0][0] * s[0][1], reverse=True):
                rates = sorted({round(rate(iv), 3) for iv in ivs}, reverse=True)
                listing.append(f'{fmt["name"]} {w}x{h} fps {fps_text(rates)}')
                say(f'  {w}x{h}: {fps_text(rates)} fps')
        keep('formats.txt', '\n'.join(listing) + '\n')
        ctrls = controls(fd)
        keep('controls.txt', ''.join(f'{c["name"]}: {c["value"]}{" (" + c["label"] + ")" if c["label"] else ""} '
                                     f'range {c["min"]}..{c["max"]} default {c["default"]}\n' for c in ctrls))
        say('CONTROLS ' + '; '.join(f'{c["name"]}={c["value"]}' + (f' ({c["label"]})' if c['label'] else '') for c in ctrls))
        dynamic = any(c['id'] == CID_EXPOSURE_AUTO_PRIORITY and c['value'] for c in ctrls)
        say(f'DYNAMIC_FRAME_RATE={"on" if dynamic else "off or absent"}')

        # 4. Capture.
        say(f'CAPTURE: up to three modes a format, {WARMUP:g} s warm-up and {args.seconds:g} s each; '
            "keep the camera pointed at something lit, and don't cover it")
        settle(fd, fmts)
        results = []
        for fmt in fmts:
            for i, (size, iv) in enumerate(pick_modes(fmt)):
                results.append(capture_mode(fd, fmt, size, iv, args.seconds, dynamic, i == 0))
    finally:
        os.close(fd)
    if not results:
        fail('no format lists a frame size with a frame rate to capture')

    # 5. Kernel lines during the run.
    during = kernel_lines(rf'usb {re.escape(usb_name)}\b|uvc|xusb', start)
    if during is not None:
        keep('kernel-run.txt', '\n'.join(during) + '\n')
        say(f'KERNEL_LINES_DURING={len(during)}')
        for line in during[-8:]:
            say(f'  run kernel: {line[:160]}')

    # 6. GStreamer.
    gst = 'not-installed'
    if shutil.which('gst-launch-1.0') and shutil.which('gst-inspect-1.0') and subprocess.run(
            ['gst-inspect-1.0', 'v4l2src'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode == 0:
        run = subprocess.run(['timeout', '60', 'gst-launch-1.0', '-q', 'v4l2src', f'device={capture_node}',
                              'num-buffers=30', '!', 'fakesink'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             universal_newlines=True, check=False)
        keep('gstreamer.txt', run.stdout)
        gst = 'pass' if run.returncode == 0 else 'fail'
        say(f'GST_V4L2SRC={gst} (30 frames, exit {run.returncode})')
    else:
        say('GST_V4L2SRC=not-installed (gstreamer1.0-plugins-good has v4l2src)')

    # 7. Microphone.
    mic = 'skipped' if args.no_audio else mic_check(usb_path)

    failed = [label for label, status in results if status == 'fail']
    slow = [label for label, status in results if status == 'slow-in-dim-light']
    if slow:
        say(f'SLOW: {", ".join(slow)} ran below {GOOD_RATE:.0%} of the rate set with the dynamic frame rate on; '
            'more light (or that control off) gives the full rate')
    ok = not failed and gst != 'fail'
    summary = (f'modes={len(results) - len(failed) - len(slow)}ok' + (f',{len(slow)}slow' if slow else '')
               + (f',{len(failed)}fail' if failed else '') + f' gst={gst} mic={mic} record={record}')
    if failed:
        say(f'FAILED: {", ".join(failed)}')
    say(f'USB_WEBCAM_CHECK={"PASS" if ok else "FAIL"} {summary}')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())

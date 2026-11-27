#!/usr/bin/env python3
"""Headless EGL and OpenGL ES 2 probe through ctypes, for NVIDIA's Tegra GL libraries.

Usage: python3 -I egl_probe.py [--egl LIBEGL] [--cuda LIBCUDA] [--lib-root DIR]

Loads libglvnd's libEGL (default libEGL.so.1), which picks NVIDIA's vendor
library from __EGL_VENDOR_LIBRARY_FILENAMES or the system's egl_vendor.d, and
checks, step by step, what an offscreen GL program needs: a display (the EGL
device platform first, then the surfaceless and default platforms), an ES 2
context, a 64x64 texture framebuffer, a clear read back exactly, a shader
pair compiled by the driver drawing a gradient checked pixel by pixel, a
triangle covering half the frame, and fill rate in a 1024x1024 framebuffer.
With --cuda it then loads that libcuda into the same process and allocates,
sets and reads back GPU memory, to show GL and CUDA from one driver stack
can share a process. Needs no headers or compiler, only Python's ctypes.

Prints KEY=VALUE lines; the last is PROBE=PASS or PROBE=FAIL (exit 0 or 1).
LIB= lines list the NVIDIA libraries the process mapped; with --lib-root,
LIB_MIX=FAIL means one of them came from outside that folder. Unset DISPLAY
and WAYLAND_DISPLAY first, so no window system is involved. Writes nothing.
"""
import argparse
import ctypes
import os
import sys
import time

c_int, c_uint, c_void_p, c_char_p = ctypes.c_int, ctypes.c_uint, ctypes.c_void_p, ctypes.c_char_p
c_float, c_size_t, POINTER = ctypes.c_float, ctypes.c_size_t, ctypes.POINTER

# EGL 1.4/1.5 and extension tokens.
EGL_SUCCESS, EGL_NONE = 0x3000, 0x3038
EGL_ALPHA_SIZE, EGL_BLUE_SIZE, EGL_GREEN_SIZE, EGL_RED_SIZE = 0x3021, 0x3022, 0x3023, 0x3024
EGL_SURFACE_TYPE, EGL_RENDERABLE_TYPE, EGL_PBUFFER_BIT, EGL_OPENGL_ES2_BIT = 0x3033, 0x3040, 0x1, 0x4
EGL_VENDOR, EGL_VERSION, EGL_EXTENSIONS, EGL_CLIENT_APIS = 0x3053, 0x3054, 0x3055, 0x308D
EGL_HEIGHT, EGL_WIDTH = 0x3056, 0x3057
EGL_OPENGL_ES_API, EGL_CONTEXT_CLIENT_VERSION = 0x30A0, 0x3098
EGL_PLATFORM_DEVICE_EXT, EGL_PLATFORM_SURFACELESS_MESA = 0x313F, 0x31DD
EGL_DRM_DEVICE_FILE_EXT = 0x3233

# OpenGL ES 2 tokens.
GL_NO_ERROR, GL_TRIANGLES, GL_UNSIGNED_BYTE, GL_FLOAT = 0, 0x0004, 0x1401, 0x1406
GL_VENDOR, GL_RENDERER, GL_VERSION, GL_SHADING_LANGUAGE_VERSION = 0x1F00, 0x1F01, 0x1F02, 0x8B8C
GL_TEXTURE_2D, GL_RGBA, GL_NEAREST = 0x0DE1, 0x1908, 0x2600
GL_TEXTURE_MAG_FILTER, GL_TEXTURE_MIN_FILTER = 0x2800, 0x2801
GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_COMPLETE = 0x8D40, 0x8CE0, 0x8CD5
GL_COLOR_BUFFER_BIT, GL_BLEND, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA = 0x4000, 0x0BE2, 0x0302, 0x0303
GL_FRAGMENT_SHADER, GL_VERTEX_SHADER = 0x8B30, 0x8B31
GL_COMPILE_STATUS, GL_LINK_STATUS, GL_INFO_LOG_LENGTH = 0x8B81, 0x8B82, 0x8B84

VERTEX = b"""\
attribute vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
"""
# Red and green follow the pixel's position, so each pixel proves the shader ran there.
FRAGMENT = b"""\
precision highp float;
uniform vec4 color;
void main() {
    gl_FragColor = vec4(gl_FragCoord.x / 64.0, gl_FragCoord.y / 64.0, color.b, color.a);
}
"""
SIZE, FILL_SIZE, FILL_DRAWS = 64, 1024, 200
# Client-side vertex arrays, kept for the life of the process so no two draws can be
# handed arrays at the same address.
FRAME = (c_float * 12)(-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1)  # the whole frame
HALF = (c_float * 6)(-1, -1, 1, -1, -1, 1)  # the lower-left half, below the diagonal

EGL_API = {  # name: (result type, argument types)
    'eglGetError': (c_int, []),
    'eglGetProcAddress': (c_void_p, [c_char_p]),
    'eglQueryString': (c_char_p, [c_void_p, c_int]),
    'eglGetDisplay': (c_void_p, [c_void_p]),
    'eglInitialize': (c_uint, [c_void_p, POINTER(c_int), POINTER(c_int)]),
    'eglTerminate': (c_uint, [c_void_p]),
    'eglBindAPI': (c_uint, [c_uint]),
    'eglChooseConfig': (c_uint, [c_void_p, POINTER(c_int), POINTER(c_void_p), c_int, POINTER(c_int)]),
    'eglCreatePbufferSurface': (c_void_p, [c_void_p, c_void_p, POINTER(c_int)]),
    'eglCreateContext': (c_void_p, [c_void_p, c_void_p, c_void_p, POINTER(c_int)]),
    'eglMakeCurrent': (c_uint, [c_void_p, c_void_p, c_void_p, c_void_p]),
    'eglDestroyContext': (c_uint, [c_void_p, c_void_p]),
    'eglDestroySurface': (c_uint, [c_void_p, c_void_p]),
    'eglReleaseThread': (c_uint, []),
}
EGL_EXT = {  # through eglGetProcAddress
    'eglQueryDevicesEXT': (c_uint, [c_int, POINTER(c_void_p), POINTER(c_int)]),
    'eglQueryDeviceStringEXT': (c_char_p, [c_void_p, c_int]),
    'eglGetPlatformDisplayEXT': (c_void_p, [c_uint, c_void_p, POINTER(c_int)]),
}
GL_API = {  # through eglGetProcAddress; glvnd dispatches to the current context's vendor
    'glGetError': (c_uint, []),
    'glGetString': (c_char_p, [c_uint]),
    'glGenTextures': (None, [c_int, POINTER(c_uint)]),
    'glBindTexture': (None, [c_uint, c_uint]),
    'glTexParameteri': (None, [c_uint, c_uint, c_int]),
    'glTexImage2D': (None, [c_uint, c_int, c_int, c_int, c_int, c_int, c_uint, c_uint, c_void_p]),
    'glGenFramebuffers': (None, [c_int, POINTER(c_uint)]),
    'glBindFramebuffer': (None, [c_uint, c_uint]),
    'glFramebufferTexture2D': (None, [c_uint, c_uint, c_uint, c_uint, c_int]),
    'glCheckFramebufferStatus': (c_uint, [c_uint]),
    'glViewport': (None, [c_int, c_int, c_int, c_int]),
    'glClearColor': (None, [c_float, c_float, c_float, c_float]),
    'glClear': (None, [c_uint]),
    'glReadPixels': (None, [c_int, c_int, c_int, c_int, c_uint, c_uint, c_void_p]),
    'glCreateShader': (c_uint, [c_uint]),
    'glShaderSource': (None, [c_uint, c_int, POINTER(c_char_p), POINTER(c_int)]),
    'glCompileShader': (None, [c_uint]),
    'glGetShaderiv': (None, [c_uint, c_uint, POINTER(c_int)]),
    'glGetShaderInfoLog': (None, [c_uint, c_int, POINTER(c_int), c_char_p]),
    'glCreateProgram': (c_uint, []),
    'glAttachShader': (None, [c_uint, c_uint]),
    'glBindAttribLocation': (None, [c_uint, c_uint, c_char_p]),
    'glLinkProgram': (None, [c_uint]),
    'glGetProgramiv': (None, [c_uint, c_uint, POINTER(c_int)]),
    'glGetProgramInfoLog': (None, [c_uint, c_int, POINTER(c_int), c_char_p]),
    'glUseProgram': (None, [c_uint]),
    'glGetUniformLocation': (c_int, [c_uint, c_char_p]),
    'glUniform4f': (None, [c_int, c_float, c_float, c_float, c_float]),
    'glEnableVertexAttribArray': (None, [c_uint]),
    'glVertexAttribPointer': (None, [c_uint, c_int, c_uint, ctypes.c_ubyte, c_int, c_void_p]),
    'glDrawArrays': (None, [c_uint, c_int, c_int]),
    'glFinish': (None, []),
    'glEnable': (None, [c_uint]),
    'glBlendFunc': (None, [c_uint, c_uint]),
}
CUDA_API = {  # every call returns CUresult (int)
    'cuInit': [c_uint],
    'cuDriverGetVersion': [POINTER(c_int)],
    'cuDeviceGet': [POINTER(c_int), c_int],
    'cuDeviceGetName': [c_char_p, c_int, c_int],
    'cuCtxCreate_v2': [POINTER(c_void_p), c_uint, c_int],
    'cuCtxDestroy_v2': [c_void_p],
    'cuMemAlloc_v2': [POINTER(ctypes.c_uint64), c_size_t],
    'cuMemsetD8_v2': [ctypes.c_uint64, ctypes.c_ubyte, c_size_t],
    'cuMemcpyDtoH_v2': [c_void_p, ctypes.c_uint64, c_size_t],
    'cuMemFree_v2': [ctypes.c_uint64],
}


class Failed(Exception):
    pass


def say(key, value):
    print(f'{key}={value}', flush=True)


def text(value):
    return value.decode(errors='replace') if value else ''


class Egl:
    def __init__(self, path):
        self.lib = ctypes.CDLL(path)
        for name, (result, args) in EGL_API.items():
            fn = getattr(self.lib, name)
            fn.restype, fn.argtypes = result, args
        self.ext = {}
        for name, (result, args) in EGL_EXT.items():
            address = self.lib.eglGetProcAddress(name.encode())
            self.ext[name] = ctypes.CFUNCTYPE(result, *args)(address) if address else None

    def check(self, step, ok, name):
        if not ok:
            say(step, f'FAIL {name} 0x{self.lib.eglGetError():04x}')
            raise Failed(step)

    def gl(self):
        functions = {}
        for name, (result, args) in GL_API.items():
            address = self.lib.eglGetProcAddress(name.encode())
            if not address:
                say('GL_FUNCTIONS', f'FAIL {name}')
                raise Failed('GL_FUNCTIONS')
            functions[name] = ctypes.CFUNCTYPE(result, *args)(address)
        return type('GL', (), functions)


def attribs(*pairs):
    values = [v for pair in pairs for v in pair] + [EGL_NONE]
    return (c_int * len(values))(*values)


def open_display(egl):
    """The first platform whose display initialises: device, surfaceless, default."""
    say('EGL_CLIENT_EXTENSIONS', text(egl.lib.eglQueryString(None, EGL_EXTENSIONS)))
    candidates = []
    query, get = egl.ext['eglQueryDevicesEXT'], egl.ext['eglGetPlatformDisplayEXT']
    if query and get:
        devices, count = (c_void_p * 8)(), c_int()
        if query(8, devices, ctypes.byref(count)):
            say('EGL_DEVICES', count.value)
            for index in range(count.value):
                strings = egl.ext['eglQueryDeviceStringEXT']
                exts = text(strings(devices[index], EGL_EXTENSIONS)) if strings else ''
                drm = text(strings(devices[index], EGL_DRM_DEVICE_FILE_EXT)) \
                    if strings and 'EGL_EXT_device_drm' in exts else ''
                say(f'EGL_DEVICE_{index}', f'extensions="{exts}" drm="{drm}"')
                candidates.append((f'device{index}', lambda d=devices[index]:
                                   get(EGL_PLATFORM_DEVICE_EXT, d, None)))
        else:
            say('EGL_DEVICES', f'none (0x{egl.lib.eglGetError():04x})')
    if get:
        candidates.append(('surfaceless', lambda: get(EGL_PLATFORM_SURFACELESS_MESA, None, None)))
    candidates.append(('default', lambda: egl.lib.eglGetDisplay(None)))
    for name, opener in candidates:
        display = opener()
        major, minor = c_int(), c_int()
        if display and egl.lib.eglInitialize(display, ctypes.byref(major), ctypes.byref(minor)):
            say('EGL_PLATFORM', name)
            say('EGL_INIT', f'PASS {major.value}.{minor.value}')
            return display
        say(f'EGL_PLATFORM_{name.upper()}', f'no display (0x{egl.lib.eglGetError():04x})')
    say('EGL_INIT', 'FAIL no platform initialised')
    raise Failed('EGL_INIT')


def make_context(egl, display):
    for key, token in (('EGL_VENDOR', EGL_VENDOR), ('EGL_VERSION', EGL_VERSION),
                       ('EGL_CLIENT_APIS', EGL_CLIENT_APIS), ('EGL_EXTENSIONS', EGL_EXTENSIONS)):
        say(key, text(egl.lib.eglQueryString(display, token)))
    egl.check('EGL_BIND_API', egl.lib.eglBindAPI(EGL_OPENGL_ES_API), 'eglBindAPI')
    surface = None
    for kind, surface_type in (('pbuffer', EGL_PBUFFER_BIT), ('surfaceless', 0)):
        # A surface type of 0 matches every config; EGL's default would ask for windows.
        wanted = [(EGL_SURFACE_TYPE, surface_type), (EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT),
                  (EGL_RED_SIZE, 8), (EGL_GREEN_SIZE, 8), (EGL_BLUE_SIZE, 8), (EGL_ALPHA_SIZE, 8)]
        config, count = c_void_p(), c_int()
        if egl.lib.eglChooseConfig(display, attribs(*wanted), ctypes.byref(config), 1,
                                   ctypes.byref(count)) and count.value:
            if surface_type:
                surface = egl.lib.eglCreatePbufferSurface(
                    display, config, attribs((EGL_WIDTH, SIZE), (EGL_HEIGHT, SIZE)))
                if not surface:
                    say('EGL_PBUFFER', f'none (0x{egl.lib.eglGetError():04x})')
                    continue
            say('EGL_SURFACE', kind)
            break
        say(f'EGL_CONFIG_{kind.upper()}', 'none')
    else:
        say('EGL_CONFIG', 'FAIL no ES 2 config')
        raise Failed('EGL_CONFIG')
    context = egl.lib.eglCreateContext(display, config, None,
                                       attribs((EGL_CONTEXT_CLIENT_VERSION, 2)))
    egl.check('EGL_CONTEXT', context, 'eglCreateContext')
    egl.check('EGL_CONTEXT', egl.lib.eglMakeCurrent(display, surface, surface, context),
              'eglMakeCurrent')
    say('EGL_CONTEXT', 'PASS')
    return surface, context


def gl_check(gl, step):
    error = gl.glGetError()
    if error != GL_NO_ERROR:
        say(step, f'FAIL GL error 0x{error:04x}')
        raise Failed(step)


def framebuffer(gl, size):
    texture, fbo = c_uint(), c_uint()
    gl.glGenTextures(1, ctypes.byref(texture))
    gl.glBindTexture(GL_TEXTURE_2D, texture)
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, size, size, 0, GL_RGBA, GL_UNSIGNED_BYTE, None)
    gl.glGenFramebuffers(1, ctypes.byref(fbo))
    gl.glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
    status = gl.glCheckFramebufferStatus(GL_FRAMEBUFFER)
    if status != GL_FRAMEBUFFER_COMPLETE:
        say('GL_FRAMEBUFFER', f'FAIL status 0x{status:04x}')
        raise Failed('GL_FRAMEBUFFER')
    gl.glViewport(0, 0, size, size)
    gl_check(gl, 'GL_FRAMEBUFFER')


def read(gl, size):
    pixels = (ctypes.c_ubyte * (size * size * 4))()
    gl.glReadPixels(0, 0, size, size, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
    gl_check(gl, 'GL_READ')
    return bytes(pixels)


def compile_program(gl):
    def shader(kind, source, step):
        handle = gl.glCreateShader(kind)
        sources, length = (c_char_p * 1)(source), (c_int * 1)(len(source))
        gl.glShaderSource(handle, 1, sources, length)
        gl.glCompileShader(handle)
        status = c_int()
        gl.glGetShaderiv(handle, GL_COMPILE_STATUS, ctypes.byref(status))
        if not status.value:
            log = ctypes.create_string_buffer(4096)
            gl.glGetShaderInfoLog(handle, 4096, None, log)
            say(step, 'FAIL ' + text(log.value).replace('\n', ' | '))
            raise Failed(step)
        say(step, 'PASS')
        return handle

    program = gl.glCreateProgram()
    gl.glAttachShader(program, shader(GL_VERTEX_SHADER, VERTEX, 'GL_VERTEX_SHADER'))
    gl.glAttachShader(program, shader(GL_FRAGMENT_SHADER, FRAGMENT, 'GL_FRAGMENT_SHADER'))
    gl.glBindAttribLocation(program, 0, b'position')
    gl.glLinkProgram(program)
    status = c_int()
    gl.glGetProgramiv(program, GL_LINK_STATUS, ctypes.byref(status))
    if not status.value:
        log = ctypes.create_string_buffer(4096)
        gl.glGetProgramInfoLog(program, 4096, None, log)
        say('GL_LINK', 'FAIL ' + text(log.value).replace('\n', ' | '))
        raise Failed('GL_LINK')
    say('GL_LINK', 'PASS')
    gl.glUseProgram(program)
    return gl.glGetUniformLocation(program, b'color')


def draw(gl, vertices, times=1):
    gl.glEnableVertexAttribArray(0)
    gl.glVertexAttribPointer(0, 2, GL_FLOAT, 0, 0, vertices)
    for _ in range(times):
        gl.glDrawArrays(GL_TRIANGLES, 0, len(vertices) // 2)
    gl.glFinish()
    gl_check(gl, 'GL_DRAW')


def expected(x, y):
    # gl_FragCoord is the pixel's centre; 8-bit conversion may round either way.
    return round(255 * (x + 0.5) / SIZE), round(255 * (y + 0.5) / SIZE)


def gl_test(gl):  # the checks in the module docstring, in order
    for key, token in (('GL_VENDOR', GL_VENDOR), ('GL_RENDERER', GL_RENDERER),
                       ('GL_VERSION', GL_VERSION), ('GLSL_VERSION', GL_SHADING_LANGUAGE_VERSION)):
        say(key, text(gl.glGetString(token)))
    framebuffer(gl, SIZE)

    gl.glClearColor(0.25, 0.5, 0.75, 1.0)
    gl.glClear(GL_COLOR_BUFFER_BIT)
    pixels = read(gl, SIZE)
    want = (64, 128, 191, 255)
    bad = sum(1 for i in range(0, len(pixels), 4)
              if any(abs(pixels[i + k] - want[k]) > 1 for k in range(4)))
    # 0.5 becomes 127 or 128 by the driver's rounding; later checks use what it wrote.
    cleared = tuple(pixels[:4])
    say('GL_CLEAR', f'PASS rgba={cleared}' if not bad else f'FAIL {bad} pixels differ, first {cleared}')
    if bad:
        raise Failed('GL_CLEAR')

    color = compile_program(gl)
    gl.glUniform4f(color, 0.0, 0.0, 0.5, 1.0)
    draw(gl, FRAME)
    pixels = read(gl, SIZE)
    bad = 0
    for y in range(SIZE):
        for x in range(SIZE):
            i = (y * SIZE + x) * 4
            r, g = expected(x, y)
            if abs(pixels[i] - r) > 1 or abs(pixels[i + 1] - g) > 1 \
                    or abs(pixels[i + 2] - 128) > 1 or pixels[i + 3] != 255:
                bad += 1
    say('GL_SHADER_DRAW', 'PASS pixels=4096' if not bad else f'FAIL {bad} of 4096 pixels differ')
    if bad:
        raise Failed('GL_SHADER_DRAW')

    gl.glClear(GL_COLOR_BUFFER_BIT)
    draw(gl, HALF)
    pixels = read(gl, SIZE)
    inside = outside = bad_in = bad_out = 0
    first = ''
    for y in range(SIZE):
        for x in range(SIZE):
            if x + y == SIZE - 1:
                continue  # on the diagonal either rule is right
            i = (y * SIZE + x) * 4
            pixel = tuple(pixels[i:i + 4])
            if x + y < SIZE - 1:
                inside += 1
                wrong = abs(pixel[2] - 128) > 1 or pixel[3] != 255
                bad_in += wrong
            else:
                outside += 1
                wrong = pixel != cleared
                bad_out += wrong
            if wrong and not first:
                first = f' first=({x},{y}) rgba={pixel}'
    if bad_in or bad_out:
        say('GL_TRIANGLE', f'FAIL inside {bad_in} of {inside} and outside {bad_out} of '
            f'{outside} pixels differ{first}')
        raise Failed('GL_TRIANGLE')
    say('GL_TRIANGLE', f'PASS inside={inside} outside={outside}')

    # Blended, so each draw reads and writes every pixel and none can be skipped.
    framebuffer(gl, FILL_SIZE)
    gl.glEnable(GL_BLEND)
    gl.glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    gl.glUniform4f(color, 0.0, 0.0, 0.5, 0.5)
    draw(gl, FRAME)
    start = time.perf_counter()
    draw(gl, FRAME, FILL_DRAWS)
    seconds = time.perf_counter() - start
    say('GL_FILL', f'PASS draws={FILL_DRAWS} size={FILL_SIZE} seconds={seconds:.4f} '
        f'mpixels_per_second={FILL_DRAWS * FILL_SIZE * FILL_SIZE / seconds / 1e6:.0f}')


def cuda_test(path):
    lib = ctypes.CDLL(path)
    for name, args in CUDA_API.items():
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = c_int, args

    def call(step, name, *args):
        rc = getattr(lib, name)(*args)
        if rc:
            say(step, f'FAIL {name} {rc}')
            raise Failed(step)

    call('CUDA_INIT', 'cuInit', 0)
    version, device, context, memory = c_int(), c_int(), c_void_p(), ctypes.c_uint64()
    call('CUDA_INIT', 'cuDriverGetVersion', ctypes.byref(version))
    call('CUDA_INIT', 'cuDeviceGet', ctypes.byref(device), 0)
    name = ctypes.create_string_buffer(256)
    call('CUDA_INIT', 'cuDeviceGetName', name, 256, device)
    say('CUDA_INIT', f'PASS driver={version.value} device="{text(name.value)}"')
    call('CUDA_MEMORY', 'cuCtxCreate_v2', ctypes.byref(context), 0, device)
    size = 1 << 20
    call('CUDA_MEMORY', 'cuMemAlloc_v2', ctypes.byref(memory), size)
    call('CUDA_MEMORY', 'cuMemsetD8_v2', memory, 0x5A, size)
    host = (ctypes.c_ubyte * size)()
    call('CUDA_MEMORY', 'cuMemcpyDtoH_v2', host, memory, size)
    call('CUDA_MEMORY', 'cuMemFree_v2', memory)
    call('CUDA_MEMORY', 'cuCtxDestroy_v2', context)
    bad = sum(1 for b in bytes(host) if b != 0x5A)
    say('CUDA_MEMORY', 'PASS bytes=1048576' if not bad else f'FAIL {bad} bytes differ')
    if bad:
        raise Failed('CUDA_MEMORY')


def mapped_libraries(root):
    seen = []
    with open('/proc/self/maps') as maps:
        for line in maps:
            fields = line.split(None, 5)
            path = fields[5].strip() if len(fields) == 6 else ''
            base = os.path.basename(path)
            if path.startswith('/') and path not in seen and (
                    base.startswith(('libnv', 'libcuda', 'libEGL', 'libGL'))
                    or '_nvidia' in base):
                seen.append(path)
    outside = []
    for path in seen:
        say('LIB', path)
        base = os.path.basename(path)
        nvidia = base.startswith(('libnv', 'libcuda')) or '_nvidia' in base
        if root and nvidia and not os.path.realpath(path).startswith(os.path.realpath(root) + os.sep):
            outside.append(path)
    if root:
        say('LIB_MIX', 'PASS' if not outside else 'FAIL ' + ' '.join(outside))
    return not outside


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--egl', default='libEGL.so.1', help="libglvnd's libEGL path or soname")
    parser.add_argument('--cuda', help='libcuda path or soname, for CUDA in the same process')
    parser.add_argument('--lib-root', help='folder every NVIDIA library must come from')
    args = parser.parse_args()
    for name in ('__EGL_VENDOR_LIBRARY_FILENAMES', 'DISPLAY', 'WAYLAND_DISPLAY'):
        say(f'ENV_{name.strip("_")}', os.environ.get(name, ''))
    ok = False
    try:
        egl = Egl(args.egl)
        say('EGL_LOAD', 'PASS')
        display = open_display(egl)
        surface, context = make_context(egl, display)
        gl_test(egl.gl())
        egl.lib.eglMakeCurrent(display, None, None, None)
        egl.lib.eglDestroyContext(display, context)
        if surface:
            egl.lib.eglDestroySurface(display, surface)
        if args.cuda:
            say('PROBE_CUDA', args.cuda)
            cuda_test(args.cuda)
        ok = True
    except OSError as error:  # a library or symbol that does not load
        say('LOAD_ERROR', str(error).replace('\n', ' '))
    except (Failed, AttributeError) as error:
        if isinstance(error, AttributeError):
            say('SYMBOL_ERROR', str(error))
    ok = mapped_libraries(args.lib_root) and ok
    say('PROBE', 'PASS' if ok else 'FAIL')
    sys.stdout.flush()
    os._exit(0 if ok else 1)  # skip library destructors, which may not expect ctypes' order


if __name__ == '__main__':
    main()

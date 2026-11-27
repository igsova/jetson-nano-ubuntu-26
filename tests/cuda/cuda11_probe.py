#!/usr/bin/env python3
"""CUDA driver and runtime probe through ctypes, for drivers without a matching nvcc.

Usage: python3 -I cuda11_probe.py --driver LIBCUDA [--runtime LIBCUDART]
           [--expect-driver VERSION] [--lib-root DIR]

Loads the given libcuda (a path, or a soname the system resolves) and checks,
step by step, what a CUDA program needs from its driver: cuInit, the driver
version, the device's name and compute capability, a context, a module
JIT-compiled from the PTX below (vector_add for sm_53), launches at the sizes
vector_add.cu uses, and an exact check of every output. With --runtime it
then does the same through the CUDA runtime library: versions, the device,
cudaMalloc and cudaMemcpy, and the PTX kernel launched in the runtime's
primary context. Needs no CUDA headers or compiler, only Python's ctypes.

Prints KEY=VALUE lines; the last is PROBE=PASS or PROBE=FAIL (exit 0 or 1).
LIB= lines list the NVIDIA and CUDA libraries the process mapped; with
--lib-root, LIB_MIX=FAIL means one of them came from outside that folder.
Writes nothing; set CUDA_CACHE_DISABLE=1 so the driver keeps no JIT cache.
"""
import argparse
import array
import ctypes
import os
import sys
import time

# Written to match clang 18's NVPTX output for vector_add.cu's kernel
# (sm_53, PTX ISA 4.2, which CUDA 10.2's and 11.4's drivers both accept).
PTX = b"""\
.version 4.2
.target sm_53
.address_size 64

.visible .entry vector_add(
\t.param .u64 vector_add_param_0,
\t.param .u64 vector_add_param_1,
\t.param .u64 vector_add_param_2,
\t.param .u32 vector_add_param_3
)
{
\t.reg .pred %p<2>;
\t.reg .b32 %r<6>;
\t.reg .f32 %f<4>;
\t.reg .b64 %rd<11>;

\tld.param.u32 %r1, [vector_add_param_3];
\tmov.u32 %r2, %ctaid.x;
\tmov.u32 %r3, %ntid.x;
\tmov.u32 %r4, %tid.x;
\tmad.lo.s32 %r5, %r2, %r3, %r4;
\tsetp.ge.u32 %p1, %r5, %r1;
\t@%p1 bra DONE;
\tld.param.u64 %rd4, [vector_add_param_0];
\tld.param.u64 %rd5, [vector_add_param_2];
\tcvta.to.global.u64 %rd6, %rd5;
\tld.param.u64 %rd7, [vector_add_param_1];
\tcvta.to.global.u64 %rd8, %rd7;
\tcvta.to.global.u64 %rd9, %rd4;
\tmul.wide.u32 %rd10, %r5, 4;
\tadd.s64 %rd1, %rd6, %rd10;
\tadd.s64 %rd2, %rd8, %rd10;
\tadd.s64 %rd3, %rd9, %rd10;
\tld.global.f32 %f1, [%rd3];
\tld.global.f32 %f2, [%rd2];
\tadd.f32 %f3, %f1, %f2;
\tst.global.f32 [%rd1], %f3;
DONE:
\tret;
}
"""
SIZES = (1, 255, 256, 257, 50000, 1048579)  # as vector_add.cu
BLOCK = 256
REPEATS = 64

c_int, c_uint, c_size_t, c_void_p = ctypes.c_int, ctypes.c_uint, ctypes.c_size_t, ctypes.c_void_p
c_u64, c_char_p, POINTER = ctypes.c_uint64, ctypes.c_char_p, ctypes.POINTER
P = c_void_p  # opaque handles and host pointers

DRIVER_API = {  # name: argument types; every call returns CUresult (int)
    'cuInit': [c_uint],
    'cuGetErrorName': [c_int, POINTER(c_char_p)],
    'cuDriverGetVersion': [POINTER(c_int)],
    'cuDeviceGetCount': [POINTER(c_int)],
    'cuDeviceGet': [POINTER(c_int), c_int],
    'cuDeviceGetName': [ctypes.c_char_p, c_int, c_int],
    'cuDeviceGetAttribute': [POINTER(c_int), c_int, c_int],
    'cuDeviceTotalMem_v2': [POINTER(c_size_t), c_int],
    'cuCtxCreate_v2': [POINTER(P), c_uint, c_int],
    'cuCtxDestroy_v2': [P],
    'cuCtxGetCurrent': [POINTER(P)],
    'cuCtxSynchronize': [],
    'cuModuleLoadDataEx': [POINTER(P), c_char_p, c_uint, POINTER(c_int), POINTER(P)],
    'cuModuleGetFunction': [POINTER(P), P, c_char_p],
    'cuModuleUnload': [P],
    'cuMemAlloc_v2': [POINTER(c_u64), c_size_t],
    'cuMemFree_v2': [c_u64],
    'cuMemcpyHtoD_v2': [c_u64, P, c_size_t],
    'cuMemcpyDtoH_v2': [P, c_u64, c_size_t],
    'cuLaunchKernel': [P, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, P,
                       POINTER(P), POINTER(P)],
}
RUNTIME_API = {  # every call returns cudaError_t (int)
    'cudaGetErrorName': None,  # returns const char *
    'cudaRuntimeGetVersion': [POINTER(c_int)],
    'cudaDriverGetVersion': [POINTER(c_int)],
    'cudaGetDeviceCount': [POINTER(c_int)],
    'cudaGetDeviceProperties': [P, c_int],
    'cudaDeviceGetAttribute': [POINTER(c_int), c_int, c_int],
    'cudaSetDevice': [c_int],
    'cudaFree': [P],
    'cudaMalloc': [POINTER(P), c_size_t],
    'cudaMemcpy': [P, P, c_size_t, c_int],
    'cudaDeviceSynchronize': [],
}
ATTRS = {'COMPUTE_MAJOR': 75, 'COMPUTE_MINOR': 76, 'SM_COUNT': 16,
         'CLOCK_KHZ': 13, 'INTEGRATED': 18}
JIT_INFO_LOG, JIT_INFO_SIZE, JIT_ERROR_LOG, JIT_ERROR_SIZE = 3, 4, 5, 6
MEMCPY_H2D, MEMCPY_D2H = 1, 2


class Failed(Exception):
    pass


def say(key, value):
    print(f'{key}={value}', flush=True)


class Driver:
    def __init__(self, path):
        self.lib = ctypes.CDLL(path)
        for name, args in DRIVER_API.items():
            fn = getattr(self.lib, name)
            fn.restype, fn.argtypes = c_int, args

    def name(self, rc):
        text = c_char_p()
        if self.lib.cuGetErrorName(rc, ctypes.byref(text)) == 0 and text.value:
            return text.value.decode()
        return 'unknown'

    def __call__(self, step, name, *args):
        rc = getattr(self.lib, name)(*args)
        if rc:
            say(step, f'FAIL {name} {rc} {self.name(rc)}')
            raise Failed(step)
        return rc


class Runtime:
    def __init__(self, path):
        self.lib = ctypes.CDLL(path)
        for name, args in RUNTIME_API.items():
            fn = getattr(self.lib, name)
            if name == 'cudaGetDeviceProperties' and hasattr(self.lib, name + '_v2'):
                # CUDA 12's header calls the _v2 symbol: a larger cudaDeviceProp
                # that starts with the same name field.
                fn = self.lib[name + '_v2']
                setattr(self.lib, name, fn)
            if args is None:
                fn.restype, fn.argtypes = c_char_p, [c_int]
            else:
                fn.restype, fn.argtypes = c_int, args

    def __call__(self, step, name, *args):
        rc = getattr(self.lib, name)(*args)
        if rc:
            text = self.lib.cudaGetErrorName(rc) or b'unknown'
            say(step, f'FAIL {name} {rc} {text.decode()}')
            raise Failed(step)
        return rc


def inputs(n):
    a = array.array('f', (float(i % 1024) for i in range(n)))
    b = array.array('f', (float((i * 7) % 1000) for i in range(n)))
    want = array.array('f', (x + y for x, y in zip(a, b)))  # exact: small integers
    return a, b, want


def address(buf):
    return c_void_p(buf.buffer_info()[0])


def load_module(cu, prefix):
    module = P()
    log = ctypes.create_string_buffer(8192)
    info = ctypes.create_string_buffer(8192)
    opts = (c_int * 4)(JIT_ERROR_LOG, JIT_ERROR_SIZE, JIT_INFO_LOG, JIT_INFO_SIZE)
    vals = (P * 4)(ctypes.cast(log, P), P(len(log)), ctypes.cast(info, P), P(len(info)))
    rc = cu.lib.cuModuleLoadDataEx(ctypes.byref(module), PTX, 4, opts, vals)
    for line in info.value.decode(errors='replace').splitlines():
        say(prefix + '_JIT_INFO', line)
    if rc:
        for line in log.value.decode(errors='replace').splitlines():
            say(prefix + '_JIT_ERROR', line)
        say(prefix + '_MODULE', f'FAIL cuModuleLoadDataEx {rc} {cu.name(rc)}')
        raise Failed(prefix + '_MODULE')
    function = P()
    cu(prefix + '_FUNCTION', 'cuModuleGetFunction', ctypes.byref(function), module, b'vector_add')
    say(prefix + '_MODULE', 'PASS')
    return module, function


def launch(cu, step, function, ptrs, n, repeats=1):
    values = [c_u64(p) for p in ptrs] + [c_uint(n)]
    params = (P * 4)(*[ctypes.cast(ctypes.byref(v), P) for v in values])
    grid = (n + BLOCK - 1) // BLOCK
    for _ in range(repeats):
        cu(step, 'cuLaunchKernel', function, grid, 1, 1, BLOCK, 1, 1, 0, None, params, None)


def driver_test(cu, expect):
    cu('CUDA_INIT', 'cuInit', 0)
    say('CUDA_INIT', 'PASS')
    version = c_int()
    cu('DRIVER_VERSION', 'cuDriverGetVersion', ctypes.byref(version))
    say('DRIVER_VERSION', version.value)
    if expect and version.value != expect:
        say('DRIVER_VERSION_CHECK', f'FAIL expected {expect}')
        raise Failed('DRIVER_VERSION')
    count, dev = c_int(), c_int()
    cu('DEVICE_COUNT', 'cuDeviceGetCount', ctypes.byref(count))
    say('DEVICE_COUNT', count.value)
    cu('DEVICE', 'cuDeviceGet', ctypes.byref(dev), 0)
    name = ctypes.create_string_buffer(256)
    cu('DEVICE_NAME', 'cuDeviceGetName', name, len(name), dev)
    say('DEVICE_NAME', name.value.decode(errors='replace'))
    for key, attr in ATTRS.items():
        value = c_int()
        cu('DEVICE_' + key, 'cuDeviceGetAttribute', ctypes.byref(value), attr, dev)
        say('DEVICE_' + key, value.value)
    total = c_size_t()
    cu('DEVICE_MEMORY', 'cuDeviceTotalMem_v2', ctypes.byref(total), dev)
    say('DEVICE_MEMORY_BYTES', total.value)

    ctx = P()
    cu('CONTEXT', 'cuCtxCreate_v2', ctypes.byref(ctx), 0, dev)
    say('CONTEXT', 'PASS')
    module, function = load_module(cu, 'DRIVER')
    for n in SIZES:
        a, b, want = inputs(n)
        out = array.array('f', bytes(4 * n))
        ptrs = []
        for _ in range(3):
            p = c_u64()
            cu(f'DRIVER_ALLOC_{n}', 'cuMemAlloc_v2', ctypes.byref(p), 4 * n)
            ptrs.append(p.value)
        cu(f'DRIVER_COPY_IN_{n}', 'cuMemcpyHtoD_v2', ptrs[0], address(a), 4 * n)
        cu(f'DRIVER_COPY_IN_{n}', 'cuMemcpyHtoD_v2', ptrs[1], address(b), 4 * n)
        repeats = REPEATS if n == SIZES[-1] else 1
        started = time.monotonic()
        launch(cu, f'DRIVER_LAUNCH_{n}', function, ptrs, n, repeats)
        cu(f'DRIVER_SYNC_{n}', 'cuCtxSynchronize')
        elapsed = time.monotonic() - started
        cu(f'DRIVER_COPY_OUT_{n}', 'cuMemcpyDtoH_v2', address(out), ptrs[2], 4 * n)
        bad = sum(1 for x, y in zip(out, want) if x != y)
        for p in ptrs:
            cu(f'DRIVER_FREE_{n}', 'cuMemFree_v2', p)
        say(f'DRIVER_VECTOR_ADD_{n}', f"{'PASS' if not bad else 'FAIL'} "
            f'launches={repeats} mismatches={bad} seconds={elapsed:.4f}')
        if bad:
            raise Failed('DRIVER_VECTOR_ADD')
    cu('DRIVER_UNLOAD', 'cuModuleUnload', module)
    cu('CONTEXT_DESTROY', 'cuCtxDestroy_v2', ctx)
    say('DRIVER_TEST', 'PASS')


def runtime_test(cu, rt):
    version = c_int()
    rt('RUNTIME_VERSION', 'cudaRuntimeGetVersion', ctypes.byref(version))
    say('RUNTIME_VERSION', version.value)
    rt('RUNTIME_DRIVER_VERSION', 'cudaDriverGetVersion', ctypes.byref(version))
    say('RUNTIME_DRIVER_VERSION', version.value)
    count = c_int()
    rt('RUNTIME_DEVICE_COUNT', 'cudaGetDeviceCount', ctypes.byref(count))
    say('RUNTIME_DEVICE_COUNT', count.value)
    props = ctypes.create_string_buffer(8192)  # cudaDeviceProp starts with char name[256]
    rt('RUNTIME_PROPERTIES', 'cudaGetDeviceProperties', ctypes.cast(props, P), 0)
    say('RUNTIME_DEVICE_NAME', props.raw[:256].split(b'\0', 1)[0].decode(errors='replace'))
    for key in ('COMPUTE_MAJOR', 'COMPUTE_MINOR'):
        value = c_int()
        rt('RUNTIME_' + key, 'cudaDeviceGetAttribute', ctypes.byref(value), ATTRS[key], 0)
        say('RUNTIME_' + key, value.value)
    rt('RUNTIME_SET_DEVICE', 'cudaSetDevice', 0)
    rt('RUNTIME_CONTEXT', 'cudaFree', None)  # creates the primary context
    ctx = P()
    cu('RUNTIME_CONTEXT', 'cuCtxGetCurrent', ctypes.byref(ctx))
    if not ctx.value:
        say('RUNTIME_CONTEXT', 'FAIL no current context after cudaFree(0)')
        raise Failed('RUNTIME_CONTEXT')
    say('RUNTIME_CONTEXT', 'PASS')
    module, function = load_module(cu, 'RUNTIME')
    n = SIZES[-1]
    a, b, want = inputs(n)
    out = array.array('f', bytes(4 * n))
    ptrs = []
    for _ in range(3):
        p = P()
        rt('RUNTIME_MALLOC', 'cudaMalloc', ctypes.byref(p), 4 * n)
        ptrs.append(p.value)
    rt('RUNTIME_COPY_IN', 'cudaMemcpy', P(ptrs[0]), address(a), 4 * n, MEMCPY_H2D)
    rt('RUNTIME_COPY_IN', 'cudaMemcpy', P(ptrs[1]), address(b), 4 * n, MEMCPY_H2D)
    launch(cu, 'RUNTIME_LAUNCH', function, ptrs, n, REPEATS)
    rt('RUNTIME_SYNC', 'cudaDeviceSynchronize')
    rt('RUNTIME_COPY_OUT', 'cudaMemcpy', address(out), P(ptrs[2]), 4 * n, MEMCPY_D2H)
    bad = sum(1 for x, y in zip(out, want) if x != y)
    for p in ptrs:
        rt('RUNTIME_FREE', 'cudaFree', P(p))
    cu('RUNTIME_UNLOAD', 'cuModuleUnload', module)
    say('RUNTIME_VECTOR_ADD', f"{'PASS' if not bad else 'FAIL'} launches={REPEATS} mismatches={bad}")
    if bad:
        raise Failed('RUNTIME_VECTOR_ADD')
    say('RUNTIME_TEST', 'PASS')


def mapped_libraries(root):
    seen = []
    with open('/proc/self/maps') as maps:
        for line in maps:
            path = line.split(None, 5)[5].strip() if len(line.split(None, 5)) == 6 else ''
            base = os.path.basename(path)
            if path.startswith('/') and (base.startswith(('libnv', 'libcuda', 'libcudart'))) \
                    and path not in seen:
                seen.append(path)
    outside = []
    for path in seen:
        say('LIB', path)
        if root and not os.path.realpath(path).startswith(os.path.realpath(root) + os.sep):
            outside.append(path)
    if root:
        say('LIB_MIX', 'PASS' if not outside else 'FAIL ' + ' '.join(outside))
    return not outside


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--driver', required=True, help='libcuda path or soname')
    parser.add_argument('--runtime', help='libcudart path or soname')
    parser.add_argument('--expect-driver', type=int, help='e.g. 11040 or 10020')
    parser.add_argument('--lib-root', help='folder every NVIDIA library must come from')
    args = parser.parse_args()
    say('PROBE_DRIVER', args.driver)
    say('CUDA_CACHE_DISABLE', os.environ.get('CUDA_CACHE_DISABLE', ''))
    ok = False
    try:
        cu = Driver(args.driver)
        say('DRIVER_LOAD', 'PASS')
        driver_test(cu, args.expect_driver)
        if args.runtime:
            say('PROBE_RUNTIME', args.runtime)
            runtime_test(cu, Runtime(args.runtime))
        ok = True
    except OSError as error:  # a library or symbol that does not load
        say('LOAD_ERROR', str(error).replace('\n', ' '))
    except (Failed, AttributeError) as error:
        if isinstance(error, AttributeError):
            say('SYMBOL_ERROR', str(error))
    ok = mapped_libraries(args.lib_root) and ok
    say('PROBE', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())

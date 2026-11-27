#!/usr/bin/env python3
"""cuBLAS and cuDNN through ctypes, checked exactly, for CUDA versions without a matching compiler.

Usage: python3 -I cuda_libs_probe.py --runtime LIBCUDART [--cublas LIBCUBLAS]
           [--cudnn LIBCUDNN] [--lib-root DIR]

Loads the given CUDA runtime (a path, or a soname the system resolves) and,
through it, runs what the Nano's GPU (sm_53) must execute from each library's
own machine code:
- cuBLAS: SGEMM at four shapes, up to 1024 x 1024 x 1024, with alpha 1 and
  beta 2 over a C of ones; then ten more 1024-cube SGEMMs, timed;
- cuDNN: 2-D convolutions (cross-correlation, NCHW, float) at two shapes with
  the implicit GEMM and precomputed implicit GEMM algorithms.
Inputs are small integers, so every product is exact in float32 whatever the
order of summation; outputs are compared with Python's own sums, in full for
the small shapes and at evenly spread positions for the large ones.

Prints KEY=VALUE lines; the last is LIBS_PROBE=PASS or LIBS_PROBE=FAIL (exit 0
or 1). LIB= lines list the NVIDIA and CUDA libraries the process mapped; with
--lib-root, LIB_MIX=FAIL means one of them came from outside that folder.
Writes nothing; run with CUDA_CACHE_DISABLE=1 so the driver keeps no JIT cache.
"""
import argparse
import array
import ctypes
import importlib.util
import os
from pathlib import Path
import sys
import time

_spec = importlib.util.spec_from_file_location('cuda11_probe', Path(__file__).resolve().parent / 'cuda11_probe.py')
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)
say, Failed, Runtime, address = base.say, base.Failed, base.Runtime, base.address
c_int, c_size_t, c_float, P, POINTER = ctypes.c_int, ctypes.c_size_t, ctypes.c_float, ctypes.c_void_p, ctypes.POINTER
MEMCPY_H2D, MEMCPY_D2H = base.MEMCPY_H2D, base.MEMCPY_D2H

GEMMS = ((1, 1, 1), (17, 33, 9), (128, 96, 64), (1024, 1024, 1024))  # m, n, k
TIMED = 10
SAMPLES = 512
CUBLAS_API = {  # every call returns cublasStatus_t (int)
    'cublasCreate_v2': [POINTER(P)],
    'cublasDestroy_v2': [P],
    'cublasGetVersion_v2': [P, POINTER(c_int)],
    'cublasSgemm_v2': [P, c_int, c_int, c_int, c_int, c_int, POINTER(c_float), P, c_int,
                       P, c_int, POINTER(c_float), P, c_int],
}
CUBLAS_OP_N = 0
# n, c, h, w, k, r, s, pad, stride
CONVS = ((1, 3, 17, 17, 4, 3, 3, 1, 1), (2, 16, 32, 32, 16, 3, 3, 1, 2))
CONV_ALGOS = {'IMPLICIT_GEMM': 0, 'IMPLICIT_PRECOMP_GEMM': 1}
CUDNN_API = {  # every call returns cudnnStatus_t (int)
    'cudnnCreate': [POINTER(P)],
    'cudnnDestroy': [P],
    'cudnnCreateTensorDescriptor': [POINTER(P)],
    'cudnnSetTensor4dDescriptor': [P, c_int, c_int, c_int, c_int, c_int, c_int],
    'cudnnDestroyTensorDescriptor': [P],
    'cudnnCreateFilterDescriptor': [POINTER(P)],
    'cudnnSetFilter4dDescriptor': [P, c_int, c_int, c_int, c_int, c_int, c_int],
    'cudnnDestroyFilterDescriptor': [P],
    'cudnnCreateConvolutionDescriptor': [POINTER(P)],
    'cudnnSetConvolution2dDescriptor': [P, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int],
    'cudnnDestroyConvolutionDescriptor': [P],
    'cudnnGetConvolution2dForwardOutputDim': [P, P, P, POINTER(c_int), POINTER(c_int),
                                              POINTER(c_int), POINTER(c_int)],
    'cudnnGetConvolutionForwardWorkspaceSize': [P, P, P, P, P, c_int, POINTER(c_size_t)],
    'cudnnConvolutionForward': [P, P, P, P, P, P, P, c_int, P, c_size_t, P, P, P],
}
CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, CUDNN_CROSS_CORRELATION = 0, 0, 1


class Library:
    """A CUDA library whose calls return a status; a non-zero status fails the step."""

    def __init__(self, path, api, error_name):
        self.lib = ctypes.CDLL(path)
        for name, args in api.items():
            fn = getattr(self.lib, name)
            fn.restype, fn.argtypes = c_int, args
        self.error_name = getattr(self.lib, error_name, None)
        if self.error_name:
            self.error_name.restype, self.error_name.argtypes = ctypes.c_char_p, [c_int]

    def __call__(self, step, name, *args):
        rc = getattr(self.lib, name)(*args)
        if rc:
            text = (self.error_name(rc) if self.error_name else None) or b'unknown'
            say(step, f'FAIL {name} {rc} {text.decode(errors="replace")}')
            raise Failed(step)
        return rc


def device(rt, step, data):
    """A device copy of the float array DATA."""
    ptr = P()
    rt(step, 'cudaMalloc', ctypes.byref(ptr), 4 * len(data))
    rt(step, 'cudaMemcpy', ptr, address(data), 4 * len(data), MEMCPY_H2D)
    return ptr


def fetch(rt, step, ptr, count):
    out = array.array('f', bytes(4 * count))
    rt(step, 'cudaMemcpy', address(out), ptr, 4 * count, MEMCPY_D2H)
    return out


def positions(total):
    """Every index for small outputs; SAMPLES evenly spread ones, the last included, for large."""
    if total <= 4 * SAMPLES:
        return range(total)
    return sorted({i * (total - 1) // (SAMPLES - 1) for i in range(SAMPLES)})


def gemm_test(rt, blas):
    handle = P()
    blas('CUBLAS_CREATE', 'cublasCreate_v2', ctypes.byref(handle))
    version = c_int()
    blas('CUBLAS_VERSION', 'cublasGetVersion_v2', handle, ctypes.byref(version))
    say('CUBLAS_VERSION', version.value)
    alpha, beta = c_float(1.0), c_float(2.0)
    for m, n, k in GEMMS:
        step = f'SGEMM_{m}x{n}x{k}'
        # Column-major: A is m x k, B is k x n, C is m x n.
        a = array.array('f', (float((i * 3 + j * 5) % 7 - 3) for j in range(k) for i in range(m)))
        b = array.array('f', (float((i * 2 + j * 7) % 5 - 2) for j in range(n) for i in range(k)))
        ones = array.array('f', [1.0]) * (m * n)
        ptrs = [device(rt, step, x) for x in (a, b, ones)]
        blas(step, 'cublasSgemm_v2', handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, ctypes.byref(alpha),
             ptrs[0], m, ptrs[1], k, ctypes.byref(beta), ptrs[2], m)
        rt(step, 'cudaDeviceSynchronize')
        out = fetch(rt, step, ptrs[2], m * n)
        checked = bad = 0
        for index in positions(m * n):
            i, j = index % m, index // m
            want = sum(a[i + p * m] * b[p + j * k] for p in range(k)) + 2.0
            checked += 1
            bad += out[index] != want
        if (m, n, k) == GEMMS[-1]:
            started = time.monotonic()
            for _ in range(TIMED):
                blas(step, 'cublasSgemm_v2', handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, ctypes.byref(alpha),
                     ptrs[0], m, ptrs[1], k, ctypes.byref(beta), ptrs[2], m)
            rt(step, 'cudaDeviceSynchronize')
            seconds = time.monotonic() - started
            say('SGEMM_RATE', f'{2.0 * m * n * k * TIMED / seconds / 1e9:.1f} GFLOPS '
                f'({TIMED} x {m}x{n}x{k} in {seconds:.3f} s)')
        for ptr in ptrs:
            rt(step, 'cudaFree', ptr)
        say(step, f"{'PASS' if not bad else 'FAIL'} checked={checked} mismatches={bad}")
        if bad:
            raise Failed(step)
    blas('CUBLAS_DESTROY', 'cublasDestroy_v2', handle)
    say('CUBLAS_TEST', 'PASS')


def conv_test(rt, dnn):
    get_version = dnn.lib.cudnnGetVersion
    get_version.restype, get_version.argtypes = c_size_t, []
    say('CUDNN_VERSION', get_version())
    handle = P()
    dnn('CUDNN_CREATE', 'cudnnCreate', ctypes.byref(handle))
    alpha, beta = c_float(1.0), c_float(0.0)
    for n, c, h, w, k, r, s, pad, stride in CONVS:
        shape = f'{n}x{c}x{h}x{w}_k{k}_{r}x{s}_p{pad}_s{stride}'
        x = array.array('f', (float((ni * 7 + ci * 3 + hi * 5 + wi) % 9 - 4)
                              for ni in range(n) for ci in range(c) for hi in range(h) for wi in range(w)))
        f = array.array('f', (float((ki * 5 + ci * 2 + ri * 3 + si) % 5 - 2)
                              for ki in range(k) for ci in range(c) for ri in range(r) for si in range(s)))
        xd, yd, fd, cd = P(), P(), P(), P()
        step = 'CONV_' + shape
        dnn(step, 'cudnnCreateTensorDescriptor', ctypes.byref(xd))
        dnn(step, 'cudnnSetTensor4dDescriptor', xd, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, n, c, h, w)
        dnn(step, 'cudnnCreateFilterDescriptor', ctypes.byref(fd))
        dnn(step, 'cudnnSetFilter4dDescriptor', fd, CUDNN_DATA_FLOAT, CUDNN_TENSOR_NCHW, k, c, r, s)
        dnn(step, 'cudnnCreateConvolutionDescriptor', ctypes.byref(cd))
        dnn(step, 'cudnnSetConvolution2dDescriptor', cd, pad, pad, stride, stride, 1, 1,
            CUDNN_CROSS_CORRELATION, CUDNN_DATA_FLOAT)
        dims = [c_int() for _ in range(4)]
        dnn(step, 'cudnnGetConvolution2dForwardOutputDim', cd, xd, fd, *[ctypes.byref(d) for d in dims])
        on, oc, oh, ow = (d.value for d in dims)
        ho, wo = (h + 2 * pad - r) // stride + 1, (w + 2 * pad - s) // stride + 1
        if (on, oc, oh, ow) != (n, k, ho, wo):
            say(step, f'FAIL output {on}x{oc}x{oh}x{ow}, expected {n}x{k}x{ho}x{wo}')
            raise Failed(step)
        dnn(step, 'cudnnCreateTensorDescriptor', ctypes.byref(yd))
        dnn(step, 'cudnnSetTensor4dDescriptor', yd, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, n, k, ho, wo)
        total = n * k * ho * wo
        want = {}
        for index in positions(total):
            wi, rest = index % wo, index // wo
            hi, rest = rest % ho, rest // ho
            ki, ni = rest % k, rest // k
            acc = 0.0
            for ci in range(c):
                for ri in range(r):
                    y = hi * stride - pad + ri
                    if not 0 <= y < h:
                        continue
                    for si in range(s):
                        z = wi * stride - pad + si
                        if 0 <= z < w:
                            acc += x[((ni * c + ci) * h + y) * w + z] * f[((ki * c + ci) * r + ri) * s + si]
            want[index] = acc
        px, pf = device(rt, step, x), device(rt, step, f)
        py = device(rt, step, array.array('f', [0.0]) * total)
        for algo_name, algo in CONV_ALGOS.items():
            step = f'CONV_{shape}_{algo_name}'
            size = c_size_t()
            dnn(step, 'cudnnGetConvolutionForwardWorkspaceSize', handle, xd, fd, cd, yd, algo, ctypes.byref(size))
            work = P()
            if size.value:
                rt(step, 'cudaMalloc', ctypes.byref(work), size.value)
            dnn(step, 'cudnnConvolutionForward', handle, ctypes.byref(alpha), xd, px, fd, pf, cd, algo,
                work, size.value, ctypes.byref(beta), yd, py)
            rt(step, 'cudaDeviceSynchronize')
            out = fetch(rt, step, py, total)
            if size.value:
                rt(step, 'cudaFree', work)
            bad = sum(1 for index, value in want.items() if out[index] != value)
            say(step, f"{'PASS' if not bad else 'FAIL'} workspace={size.value} checked={len(want)} mismatches={bad}")
            if bad:
                raise Failed(step)
        for ptr in (px, pf, py):
            rt(step, 'cudaFree', ptr)
        dnn(step, 'cudnnDestroyTensorDescriptor', xd)
        dnn(step, 'cudnnDestroyTensorDescriptor', yd)
        dnn(step, 'cudnnDestroyFilterDescriptor', fd)
        dnn(step, 'cudnnDestroyConvolutionDescriptor', cd)
    dnn('CUDNN_DESTROY', 'cudnnDestroy', handle)
    say('CUDNN_TEST', 'PASS')


def mapped_libraries(root):
    seen = []
    with open('/proc/self/maps') as maps:
        for line in maps:
            fields = line.split(None, 5)
            path = fields[5].strip() if len(fields) == 6 else ''
            if path.startswith('/') and os.path.basename(path).startswith(('libnv', 'libcu')) \
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
    parser.add_argument('--runtime', required=True, help='libcudart path or soname')
    parser.add_argument('--cublas', help='libcublas path or soname')
    parser.add_argument('--cudnn', help='libcudnn path or soname')
    parser.add_argument('--lib-root', help='folder every NVIDIA and CUDA library must come from')
    args = parser.parse_args()
    say('CUDA_CACHE_DISABLE', os.environ.get('CUDA_CACHE_DISABLE', ''))
    ok = False
    try:
        rt = Runtime(args.runtime)
        version = c_int()
        rt('RUNTIME_VERSION', 'cudaRuntimeGetVersion', ctypes.byref(version))
        say('RUNTIME_VERSION', version.value)
        rt('RUNTIME_DRIVER_VERSION', 'cudaDriverGetVersion', ctypes.byref(version))
        say('RUNTIME_DRIVER_VERSION', version.value)
        rt('RUNTIME_SET_DEVICE', 'cudaSetDevice', 0)
        rt('RUNTIME_CONTEXT', 'cudaFree', None)
        if args.cublas:
            say('PROBE_CUBLAS', args.cublas)
            gemm_test(rt, Library(args.cublas, CUBLAS_API, 'cublasGetStatusName'))
        if args.cudnn:
            say('PROBE_CUDNN', args.cudnn)
            conv_test(rt, Library(args.cudnn, CUDNN_API, 'cudnnGetErrorString'))
        ok = True
    except OSError as error:  # a library or symbol that does not load
        say('LOAD_ERROR', str(error).replace('\n', ' '))
    except (Failed, AttributeError) as error:
        if isinstance(error, AttributeError):
            say('SYMBOL_ERROR', str(error))
    ok = mapped_libraries(args.lib_root) and ok
    say('LIBS_PROBE', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Write tiny_cnn.onnx and expected.json, the TensorRT test model and its answer.

Usage: python3 make_model.py OUT_DIR   (needs numpy and onnx; onnxruntime optional)

A small convolutional network with fixed pseudo-random weights (numpy seed
53): Conv 3->16 (3x3, pad 1), Relu, MaxPool 2x2, Conv 16->32 (3x3, pad 1),
Relu, GlobalAveragePool, Flatten, Gemm 32->10, on a 1x3x64x64 input "input"
to a 1x10 output "output". ONNX opset 13 and IR version 8, which TensorRT
8.5's parser reads. The input is defined by input_values() below, which
trt_check.py repeats with the standard library only, so the Nano needs no
numpy; expected.json holds the output computed here in float64 with numpy,
and checked against onnxruntime when it is installed. Committed copies were
made with numpy 2.2.6, onnx 1.18.0 and onnxruntime 1.22.1.
"""
import json
from pathlib import Path
import sys

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

SHAPE = (1, 3, 64, 64)


def input_values():
    """The input, element by element in C order, as trt_check.py writes it."""
    c, h, w = np.meshgrid(np.arange(3), np.arange(64), np.arange(64), indexing='ij')
    return ((((c * 4096 + h * 64 + w) * 37) % 255) / 255.0 - 0.5).astype(np.float32).reshape(SHAPE)


def weights():
    rng = np.random.RandomState(53)
    return {
        'w1': (rng.standard_normal((16, 3, 3, 3)) * 0.3).astype(np.float32),
        'b1': (rng.standard_normal(16) * 0.1).astype(np.float32),
        'w2': (rng.standard_normal((32, 16, 3, 3)) * 0.1).astype(np.float32),
        'b2': (rng.standard_normal(32) * 0.1).astype(np.float32),
        'w3': (rng.standard_normal((10, 32)) * 0.5).astype(np.float32),
        'b3': (rng.standard_normal(10) * 0.1).astype(np.float32),
    }


def conv(x, w, b):  # stride 1, pad 1, float64
    n, c, h, wd = x.shape
    padded = np.pad(x, ((0, 0), (0, 0), (1, 1), (1, 1)))
    out = np.zeros((n, w.shape[0], h, wd))
    for i in range(3):
        for j in range(3):
            out += np.einsum('nchw,oc->nohw', padded[:, :, i:i + h, j:j + wd], w[:, :, i, j])
    return out + b[None, :, None, None]


def reference(x, p):
    p = {k: v.astype(np.float64) for k, v in p.items()}
    y = np.maximum(conv(x.astype(np.float64), p['w1'], p['b1']), 0)
    y = y.reshape(1, 16, 32, 2, 32, 2).max(axis=(3, 5))
    y = np.maximum(conv(y, p['w2'], p['b2']), 0)
    y = y.mean(axis=(2, 3))
    return y @ p['w3'].T + p['b3']


def model(p):
    nodes = [
        helper.make_node('Conv', ['input', 'w1', 'b1'], ['c1'], pads=[1, 1, 1, 1], kernel_shape=[3, 3]),
        helper.make_node('Relu', ['c1'], ['r1']),
        helper.make_node('MaxPool', ['r1'], ['p1'], kernel_shape=[2, 2], strides=[2, 2]),
        helper.make_node('Conv', ['p1', 'w2', 'b2'], ['c2'], pads=[1, 1, 1, 1], kernel_shape=[3, 3]),
        helper.make_node('Relu', ['c2'], ['r2']),
        helper.make_node('GlobalAveragePool', ['r2'], ['g']),
        helper.make_node('Flatten', ['g'], ['f'], axis=1),
        helper.make_node('Gemm', ['f', 'w3', 'b3'], ['output'], transB=1),
    ]
    graph = helper.make_graph(
        nodes, 'tiny_cnn',
        [helper.make_tensor_value_info('input', TensorProto.FLOAT, list(SHAPE))],
        [helper.make_tensor_value_info('output', TensorProto.FLOAT, [1, 10])],
        [numpy_helper.from_array(v, k) for k, v in p.items()])
    m = helper.make_model(graph, producer_name='jetson-ubuntu-26 make_model.py',
                          opset_imports=[helper.make_opsetid('', 13)])
    m.ir_version = 8
    onnx.checker.check_model(m)
    return m


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    p = weights()
    m = model(p)
    (out / 'tiny_cnn.onnx').write_bytes(m.SerializeToString())
    x = input_values()
    expected = reference(x, p)[0]
    try:
        import onnxruntime
        session = onnxruntime.InferenceSession(str(out / 'tiny_cnn.onnx'), providers=['CPUExecutionProvider'])
        got = session.run(None, {'input': x})[0][0]
        print('onnxruntime max abs diff', float(np.abs(got - expected).max()))
        assert np.allclose(got, expected, rtol=1e-5, atol=1e-5)
    except ImportError:
        print('onnxruntime not installed; reference not cross-checked')
    (out / 'expected.json').write_text(json.dumps(
        {'name': 'output', 'shape': [1, 10], 'values': [round(float(v), 9) for v in expected]}, indent=1) + '\n')
    print('expected', [round(float(v), 4) for v in expected])


if __name__ == '__main__':
    main()

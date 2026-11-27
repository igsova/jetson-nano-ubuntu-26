# TensorRT validation

`tiny_cnn.onnx` is a small convolutional network (two 3x3 convolutions with
ReLU, max and average pooling, and a 32-to-10 fully connected layer) with
fixed pseudo-random weights, ONNX opset 13 and IR version 8, which TensorRT
8.5's parser reads. `expected.json` holds its output for one fixed input,
computed in float64 with numpy and cross-checked with onnxruntime (largest
difference 1.2e-6). `make_model.py` writes both (numpy 2.2.6, onnx 1.18.0,
onnxruntime 1.22.1; rerunning it gives byte-identical files).

`trt_check.py` needs only Python's standard library, so it runs on the Nano:
`input OUT.bin` writes the same input (byte-identical to
`make_model.input_values()`) for trtexec's `--loadInputs`, and `check` reads
trtexec's `--exportOutput` JSON and compares it with `expected.json`.

`scripts/jetson/probes/probe-r35-trt.sh` uses them on the Nano: JetPack 5's trtexec
builds FP32 and FP16 engines for the model on the GPU and runs them, the
saved engine is reloaded, and the outputs must match within 1e-3 (FP32) and
5e-2 (FP16), as on the Nano on 2026-10-15. A pass with stand-in
libraries on a host is a test of the scripts, not of the Nano's GPU.

`cudla_stub.c` and `cudla_stub.map` are a stand-in for cuDLA's
`libcudla.so.1`, which JetPack 5's `libnvinfer.so.8.5.2` links (eight
functions at the version node `libcudla.so.1`) although the Nano has no DLA.
The runner uses NVIDIA's `libcudla-11-4` when the inputs hold it and its own
libraries resolve, and otherwise builds this stand-in with the Nano's gcc: it
reports no DLA devices and fails every other call.

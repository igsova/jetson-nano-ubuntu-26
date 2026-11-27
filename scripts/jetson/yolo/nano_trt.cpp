// C functions over TensorRT's runtime for yolo-cam.py, which loads this
// library with ctypes: TensorRT's Python bindings are not built for Ubuntu
// 26.04's Python. They load a serialized engine (trtexec --saveEngine),
// describe its bindings and run it on host buffers.
//
// Built by setup-yolo.sh on the Nano for the default TensorRT, against its
// public headers (github.com/NVIDIA/TensorRT, Apache-2.0): JetPack 4's 8.2.1
// with CUDA 10.2's libcudart.so.10.2 once nano-trt82 is installed, else
// JetPack 5's 8.5.2 with CUDA 11.4's libcudart.so.11.0. Both name their
// library libnvinfer.so.8, so it refuses to open an engine with the other's.
#include <NvInferRuntime.h>
#include <cuda_runtime_api.h>
#include <dlfcn.h>

#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {

class Logger : public nvinfer1::ILogger {
  public:
    void log(Severity severity, const char *msg) noexcept override {
        if (severity <= Severity::kWARNING) std::fprintf(stderr, "tensorrt: %s\n", msg);
    }
};
Logger logger;

struct Binding {
    std::string name;
    bool input;
    nvinfer1::DataType type;
    nvinfer1::Dims dims;
    size_t bytes;
};

struct Handle {
    nvinfer1::IRuntime *runtime = nullptr;
    nvinfer1::ICudaEngine *engine = nullptr;
    nvinfer1::IExecutionContext *context = nullptr;
    cudaStream_t stream = nullptr;
    cudaEvent_t start = nullptr, stop = nullptr;
    std::vector<Binding> bindings;
    std::vector<void *> device;
};

void say(char *err, int len, const std::string &msg) {
    if (err && len > 0) std::snprintf(err, len, "%s", msg.c_str());
}

bool ok(cudaError_t status, const char *what, char *err, int len) {
    if (status == cudaSuccess) return true;
    say(err, len, std::string(what) + ": " + cudaGetErrorString(status));
    return false;
}

size_t element_size(nvinfer1::DataType type) {
    switch (type) {
    case nvinfer1::DataType::kFLOAT:
    case nvinfer1::DataType::kINT32: return 4;
    case nvinfer1::DataType::kHALF: return 2;
    case nvinfer1::DataType::kINT8:
    case nvinfer1::DataType::kBOOL: return 1;
#if NV_TENSORRT_MAJOR > 8 || (NV_TENSORRT_MAJOR == 8 && NV_TENSORRT_MINOR >= 5)
    case nvinfer1::DataType::kUINT8: return 1;  // since TensorRT 8.5; JetPack 4's 8.2 lacks it
#endif
    }
    return 0;
}

void destroy(Handle *h) {
    for (void *p : h->device)
        if (p) cudaFree(p);
    if (h->start) cudaEventDestroy(h->start);
    if (h->stop) cudaEventDestroy(h->stop);
    if (h->stream) cudaStreamDestroy(h->stream);
    delete h->context;
    delete h->engine;
    delete h->runtime;
    delete h;
}

}  // namespace

extern "C" {

int ntrt_version() { return getInferLibVersion(); }

// The engine at path, ready to run, or NULL with the reason in err.
void *ntrt_open(const char *path, char *err, int errlen) {
    const int built = NV_TENSORRT_MAJOR * 1000 + NV_TENSORRT_MINOR * 100 + NV_TENSORRT_PATCH;
    if (getInferLibVersion() != built) {
        auto name = [](int v) {
            return std::to_string(v / 1000) + "." + std::to_string(v / 100 % 10) + "." + std::to_string(v % 100);
        };
        say(err, errlen, "this runner is for TensorRT " + name(built) + " but TensorRT " + name(getInferLibVersion()) +
                             " was loaded: 8.5's runner and engines run through nano-trt85, 8.2's without it");
        return nullptr;
    }
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        say(err, errlen, std::string("cannot read ") + path);
        return nullptr;
    }
    std::vector<char> blob((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    // TensorRT's plugins, as trtexec registers them, when the library is there.
    if (void *plugins = dlopen("libnvinfer_plugin.so.8", RTLD_NOW | RTLD_GLOBAL)) {
        using Init = bool (*)(void *, const char *);
        if (auto init = reinterpret_cast<Init>(dlsym(plugins, "initLibNvInferPlugins"))) init(&logger, "");
    }
    auto *h = new Handle;
    h->runtime = nvinfer1::createInferRuntime(logger);
    if (!h->runtime) {
        say(err, errlen, "createInferRuntime failed");
        destroy(h);
        return nullptr;
    }
    h->engine = h->runtime->deserializeCudaEngine(blob.data(), blob.size());
    if (!h->engine) {
        say(err, errlen, "the engine does not load (built by another TensorRT version or for another GPU?)");
        destroy(h);
        return nullptr;
    }
    h->context = h->engine->createExecutionContext();
    if (!h->context) {
        say(err, errlen, "createExecutionContext failed");
        destroy(h);
        return nullptr;
    }
    for (int i = 0; i < h->engine->getNbBindings(); ++i) {
        Binding b{h->engine->getBindingName(i), h->engine->bindingIsInput(i), h->engine->getBindingDataType(i),
                  h->engine->getBindingDimensions(i), element_size(h->engine->getBindingDataType(i))};
        for (int d = 0; d < b.dims.nbDims; ++d) {
            if (b.dims.d[d] < 0) {
                say(err, errlen, "binding " + b.name + " has a dynamic shape; build the engine with fixed shapes");
                destroy(h);
                return nullptr;
            }
            b.bytes *= static_cast<size_t>(b.dims.d[d]);
        }
        void *p = nullptr;
        if (!ok(cudaMalloc(&p, b.bytes), "cudaMalloc", err, errlen)) {
            destroy(h);
            return nullptr;
        }
        h->bindings.push_back(b);
        h->device.push_back(p);
    }
    if (!ok(cudaStreamCreate(&h->stream), "cudaStreamCreate", err, errlen) ||
        !ok(cudaEventCreate(&h->start), "cudaEventCreate", err, errlen) ||
        !ok(cudaEventCreate(&h->stop), "cudaEventCreate", err, errlen)) {
        destroy(h);
        return nullptr;
    }
    return h;
}

int ntrt_count(void *handle) { return static_cast<int>(static_cast<Handle *>(handle)->bindings.size()); }

// Binding i: its name, whether it is an input, its TensorRT data type (0 float,
// 1 half, 2 int8, 3 int32, 4 bool, 5 uint8) and its dimensions; returns the
// number of dimensions, or -1 for no such binding.
int ntrt_binding(void *handle, int i, char *name, int namelen, int *input, int *type, int *dims, int maxdims) {
    auto *h = static_cast<Handle *>(handle);
    if (i < 0 || i >= static_cast<int>(h->bindings.size())) return -1;
    const Binding &b = h->bindings[i];
    say(name, namelen, b.name);
    *input = b.input;
    *type = static_cast<int>(b.type);
    for (int d = 0; d < b.dims.nbDims && d < maxdims; ++d) dims[d] = b.dims.d[d];
    return b.dims.nbDims;
}

// One inference: host[i] is binding i's buffer, read for an input and written
// for an output, each the binding's full size. gpu_ms gets the time between
// the copies in and out, as CUDA events measure it. Returns 0, or -1 with the
// reason in err.
int ntrt_run(void *handle, void *const *host, float *gpu_ms, char *err, int errlen) {
    auto *h = static_cast<Handle *>(handle);
    for (size_t i = 0; i < h->bindings.size(); ++i)
        if (h->bindings[i].input &&
            !ok(cudaMemcpyAsync(h->device[i], host[i], h->bindings[i].bytes, cudaMemcpyHostToDevice, h->stream),
                "cudaMemcpyAsync in", err, errlen))
            return -1;
    if (!ok(cudaEventRecord(h->start, h->stream), "cudaEventRecord", err, errlen)) return -1;
    if (!h->context->enqueueV2(h->device.data(), h->stream, nullptr)) {
        say(err, errlen, "enqueueV2 failed");
        return -1;
    }
    if (!ok(cudaEventRecord(h->stop, h->stream), "cudaEventRecord", err, errlen)) return -1;
    for (size_t i = 0; i < h->bindings.size(); ++i)
        if (!h->bindings[i].input &&
            !ok(cudaMemcpyAsync(host[i], h->device[i], h->bindings[i].bytes, cudaMemcpyDeviceToHost, h->stream),
                "cudaMemcpyAsync out", err, errlen))
            return -1;
    if (!ok(cudaStreamSynchronize(h->stream), "cudaStreamSynchronize", err, errlen)) return -1;
    float ms = 0;
    if (!ok(cudaEventElapsedTime(&ms, h->start, h->stop), "cudaEventElapsedTime", err, errlen)) return -1;
    *gpu_ms = ms;
    return 0;
}

// Free and total GPU memory in bytes (one pool on the Nano, shared with the CPU).
int ntrt_memory(size_t *free, size_t *total) { return cudaMemGetInfo(free, total) == cudaSuccess ? 0 : -1; }

void ntrt_close(void *handle) {
    if (handle) destroy(static_cast<Handle *>(handle));
}

}  // extern "C"

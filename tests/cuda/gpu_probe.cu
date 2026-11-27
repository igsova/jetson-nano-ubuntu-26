// GPU allocation and launch probe for the JetPack 5 kernel trial.
//
// For each buffer size it prints where cudaMalloc placed the three buffers,
// runs the vector_add kernel once and then 64 times, and checks every output.
// Sizes grow from 64 KiB to 16 MiB per buffer, past the 4 MiB buffers of the
// vector_add case that failed in trial 9. A GPU fault leaves the CUDA context
// unusable, so the probe stops at the first failure. Output is line buffered
// so each result is visible before a later step can crash the kernel.
#include <cuda_runtime.h>

#include <cstdio>
#include <vector>

static bool ok(cudaError_t status, const char *operation, size_t bytes) {
    if (status == cudaSuccess) return true;
    std::printf("FAIL bytes=%zu %s: %s\n", bytes, operation, cudaGetErrorString(status));
    return false;
}

__global__ void vector_add(const float *a, const float *b, float *c, int count) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < count) c[i] = a[i] + b[i];
}

static bool run_size(int count) {
    const size_t bytes = static_cast<size_t>(count) * sizeof(float);
    std::vector<float> a(count), b(count), c(count);
    for (int i = 0; i < count; ++i) {
        a[i] = static_cast<float>(i % 251 - 125);
        b[i] = static_cast<float>(i % 127 - 63);
    }
    float *da = nullptr, *db = nullptr, *dc = nullptr;
    if (!ok(cudaMalloc(&da, bytes), "allocate A", bytes) ||
        !ok(cudaMalloc(&db, bytes), "allocate B", bytes) ||
        !ok(cudaMalloc(&dc, bytes), "allocate C", bytes))
        return false;
    std::printf("bytes=%zu a=%p b=%p c=%p\n", bytes, static_cast<void *>(da),
                static_cast<void *>(db), static_cast<void *>(dc));
    if (!ok(cudaMemcpy(da, a.data(), bytes, cudaMemcpyHostToDevice), "copy A", bytes) ||
        !ok(cudaMemcpy(db, b.data(), bytes, cudaMemcpyHostToDevice), "copy B", bytes))
        return false;
    for (int launches : {1, 64}) {
        if (!ok(cudaMemset(dc, 0x7f, bytes), "initialize output", bytes)) return false;
        for (int r = 0; r < launches; ++r) {
            vector_add<<<(count + 255) / 256, 256>>>(da, db, dc, count);
            if (!ok(cudaGetLastError(), "launch", bytes)) return false;
        }
        if (!ok(cudaDeviceSynchronize(), "synchronize", bytes) ||
            !ok(cudaMemcpy(c.data(), dc, bytes, cudaMemcpyDeviceToHost), "copy C", bytes))
            return false;
        for (int i = 0; i < count; ++i) {
            if (c[i] != a[i] + b[i]) {
                std::printf("FAIL bytes=%zu launches=%d index=%d expected=%g actual=%g\n",
                            bytes, launches, i, a[i] + b[i], c[i]);
                return false;
            }
        }
        std::printf("PASS bytes=%zu launches=%d\n", bytes, launches);
    }
    return ok(cudaFree(da), "free A", bytes) && ok(cudaFree(db), "free B", bytes) &&
           ok(cudaFree(dc), "free C", bytes);
}

int main() {
    std::setvbuf(stdout, nullptr, _IOLBF, 0);
    size_t free_bytes = 0, total_bytes = 0;
    if (!ok(cudaMemGetInfo(&free_bytes, &total_bytes), "read memory size", 0)) return 1;
    std::printf("gpu memory free=%zu total=%zu\n", free_bytes, total_bytes);
    for (int count : {1 << 14, 1 << 18, 1 << 19, 1 << 20, 1 << 21, 1 << 22}) {
        if (!run_size(count)) {
            std::puts("PROBE=FAIL");
            return 1;
        }
    }
    std::puts("PROBE=PASS");
    return 0;
}

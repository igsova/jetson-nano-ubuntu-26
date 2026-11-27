#include <cuda_runtime.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static void check(cudaError_t status, const char *operation) {
    if (status != cudaSuccess) {
        std::fprintf(stderr, "FAIL: %s: %s\n", operation, cudaGetErrorString(status));
        std::exit(EXIT_FAILURE);
    }
}

__global__ void vector_add(const float *a, const float *b, float *c, int count) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < count) c[i] = a[i] + b[i];
}

static void run_case(int count, int seconds) {
    const size_t bytes = static_cast<size_t>(count) * sizeof(float);
    std::vector<float> a(count), b(count), c(count);
    for (int i = 0; i < count; ++i) {
        a[i] = static_cast<float>(i % 251 - 125);
        b[i] = static_cast<float>(i % 127 - 63);
    }
    float *da = nullptr, *db = nullptr, *dc = nullptr;
    check(cudaMalloc(&da, bytes), "allocate A");
    check(cudaMalloc(&db, bytes), "allocate B");
    check(cudaMalloc(&dc, bytes), "allocate C");
    check(cudaMemcpy(da, a.data(), bytes, cudaMemcpyHostToDevice), "copy A to GPU");
    check(cudaMemcpy(db, b.data(), bytes, cudaMemcpyHostToDevice), "copy B to GPU");

    const auto start = std::chrono::steady_clock::now();
    unsigned long batches = 0, launches = 0;
    double elapsed = 0;
    do {
        // Poison output each batch so an unexecuted kernel cannot pass.
        check(cudaMemset(dc, 0x7f, bytes), "initialize output");
        const int repetitions = seconds ? 256 : 1;
        for (int r = 0; r < repetitions; ++r) {
            vector_add<<<(count + 255) / 256, 256>>>(da, db, dc, count);
            check(cudaGetLastError(), "launch vector_add");
            ++launches;
        }
        check(cudaDeviceSynchronize(), "synchronize GPU");
        check(cudaMemcpy(c.data(), dc, bytes, cudaMemcpyDeviceToHost), "copy C from GPU");
        for (int i = 0; i < count; ++i) {
            // These bounded integer-valued floats and their sums are exact.
            if (c[i] != a[i] + b[i]) {
                std::fprintf(stderr, "FAIL: count=%d index=%d expected=%g actual=%g\n",
                             count, i, a[i] + b[i], c[i]);
                std::exit(EXIT_FAILURE);
            }
        }
        ++batches;
        elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    } while (elapsed < seconds);

    check(cudaFree(da), "free A");
    check(cudaFree(db), "free B");
    check(cudaFree(dc), "free C");
    std::printf("PASS count=%d verified_batches=%lu kernel_launches=%lu seconds=%.3f\n",
                count, batches, launches, elapsed);
}

int main(int argc, char **argv) {
    int seconds = 0;
    if (argc != 1) {
        if (argc != 3 || std::strcmp(argv[1], "--seconds") != 0) return 2;
        char *end = nullptr;
        const long parsed = std::strtol(argv[2], &end, 10);
        if (!*argv[2] || *end || parsed < 0 || parsed > 300) return 2;
        seconds = static_cast<int>(parsed);
    }
    int devices = 0, driver = 0, runtime = 0;
    check(cudaGetDeviceCount(&devices), "enumerate devices");
    if (devices < 1) {
        std::fprintf(stderr, "FAIL: no CUDA GPU\n");
        return 1;
    }
    check(cudaSetDevice(0), "select device");
    cudaDeviceProp properties{};
    check(cudaGetDeviceProperties(&properties, 0), "read device properties");
    check(cudaDriverGetVersion(&driver), "read driver version");
    check(cudaRuntimeGetVersion(&runtime), "read runtime version");
    std::printf("device=%s compute=%d.%d devices=%d driver=%d runtime=%d\n",
                properties.name, properties.major, properties.minor, devices, driver, runtime);
    const int cases[] = {1, 255, 256, 257, 50000, 1048579};
    for (int count : cases) run_case(count, count == 1048579 ? seconds : 0);
    check(cudaDeviceReset(), "reset CUDA context");
    std::puts("RESULT=PASS");
    return 0;
}

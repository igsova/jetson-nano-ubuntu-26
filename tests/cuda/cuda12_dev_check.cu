// Build check for CUDA 12's headers and link names on the Nano: a kernel of
// its own, then cuBLAS and cuDNN through their headers and -l names.
//   nvcc -ccbin g++-11 -O2 -arch=sm_53 -o cuda12_dev_check cuda12_dev_check.cu -lcublas -lcudnn
// Inputs are small integers, so every result is exact in float32.
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cudnn.h>

#include <cstdio>
#include <cstdlib>
#include <vector>

static void check(cudaError_t status, const char *operation) {
    if (status != cudaSuccess) {
        std::printf("FAIL: %s: %s\n", operation, cudaGetErrorString(status));
        std::exit(EXIT_FAILURE);
    }
}

static void check_blas(cublasStatus_t status, const char *operation) {
    if (status != CUBLAS_STATUS_SUCCESS) {
        std::printf("FAIL: %s: cuBLAS status %d\n", operation, static_cast<int>(status));
        std::exit(EXIT_FAILURE);
    }
}

static void check_dnn(cudnnStatus_t status, const char *operation) {
    if (status != CUDNN_STATUS_SUCCESS) {
        std::printf("FAIL: %s: %s\n", operation, cudnnGetErrorString(status));
        std::exit(EXIT_FAILURE);
    }
}

__global__ void scale_add(float *x, int count, float factor, float offset) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < count) x[i] = x[i] * factor + offset;
}

int main() {
    int driver = 0, runtime = 0;
    check(cudaDriverGetVersion(&driver), "read driver version");
    check(cudaRuntimeGetVersion(&runtime), "read runtime version");
    std::printf("driver=%d runtime=%d\n", driver, runtime);

    // Own kernel: x * 3 + 1 over 1000 values.
    const int count = 1000;
    std::vector<float> x(count);
    for (int i = 0; i < count; ++i) x[i] = static_cast<float>(i % 97 - 48);
    float *dx = nullptr;
    check(cudaMalloc(&dx, count * sizeof(float)), "allocate x");
    check(cudaMemcpy(dx, x.data(), count * sizeof(float), cudaMemcpyHostToDevice), "copy x");
    scale_add<<<(count + 255) / 256, 256>>>(dx, count, 3.0f, 1.0f);
    check(cudaGetLastError(), "launch scale_add");
    std::vector<float> y(count);
    check(cudaMemcpy(y.data(), dx, count * sizeof(float), cudaMemcpyDeviceToHost), "copy y");
    int kernel_bad = 0;
    for (int i = 0; i < count; ++i) kernel_bad += y[i] != x[i] * 3.0f + 1.0f;
    std::printf("KERNEL=%s mismatches=%d\n", kernel_bad ? "FAIL" : "PASS", kernel_bad);
    check(cudaFree(dx), "free x");

    // cuBLAS: C = A * B for 5x7 by 7x3, column-major.
    const int m = 5, n = 3, k = 7;
    std::vector<float> a(m * k), b(k * n), c(m * n, -1.0f);
    for (int i = 0; i < m * k; ++i) a[i] = static_cast<float>(i % 5 - 2);
    for (int i = 0; i < k * n; ++i) b[i] = static_cast<float>(i % 7 - 3);
    float *da = nullptr, *db = nullptr, *dc = nullptr;
    check(cudaMalloc(&da, a.size() * sizeof(float)), "allocate A");
    check(cudaMalloc(&db, b.size() * sizeof(float)), "allocate B");
    check(cudaMalloc(&dc, c.size() * sizeof(float)), "allocate C");
    check(cudaMemcpy(da, a.data(), a.size() * sizeof(float), cudaMemcpyHostToDevice), "copy A");
    check(cudaMemcpy(db, b.data(), b.size() * sizeof(float), cudaMemcpyHostToDevice), "copy B");
    cublasHandle_t blas = nullptr;
    check_blas(cublasCreate(&blas), "cublasCreate");
    int blas_version = 0;
    check_blas(cublasGetVersion(blas, &blas_version), "cublasGetVersion");
    const float one = 1.0f, zero = 0.0f;
    check_blas(cublasSgemm(blas, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, &one, da, m, db, k, &zero, dc, m),
               "cublasSgemm");
    check(cudaMemcpy(c.data(), dc, c.size() * sizeof(float), cudaMemcpyDeviceToHost), "copy C");
    int bad = 0;
    for (int col = 0; col < n; ++col) {
        for (int row = 0; row < m; ++row) {
            float sum = 0.0f;
            for (int i = 0; i < k; ++i) sum += a[i * m + row] * b[col * k + i];
            bad += c[col * m + row] != sum;
        }
    }
    std::printf("CUBLAS=%s version=%d header=%d mismatches=%d\n", bad ? "FAIL" : "PASS", blas_version,
                CUBLAS_VERSION, bad);
    check_blas(cublasDestroy(blas), "cublasDestroy");
    check(cudaFree(da), "free A");
    check(cudaFree(db), "free B");
    check(cudaFree(dc), "free C");

    // cuDNN: a handle, and the library's version against its header's.
    cudnnHandle_t dnn = nullptr;
    check_dnn(cudnnCreate(&dnn), "cudnnCreate");
    const size_t dnn_version = cudnnGetVersion();
    std::printf("CUDNN=%s version=%zu header=%d\n", dnn_version / 100 == CUDNN_VERSION / 100 ? "PASS" : "FAIL",
                dnn_version, CUDNN_VERSION);
    check_dnn(cudnnDestroy(dnn), "cudnnDestroy");
    const bool pass = kernel_bad == 0 && bad == 0 && dnn_version / 100 == CUDNN_VERSION / 100;
    std::puts(pass ? "RESULT=PASS" : "RESULT=FAIL");
    return pass ? 0 : 1;
}

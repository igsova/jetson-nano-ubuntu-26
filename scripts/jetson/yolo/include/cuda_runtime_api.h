/*
 * The part of CUDA's runtime API that nano_trt.cpp and TensorRT 8.5's runtime
 * headers use, declared here because the system carries CUDA 11.4's runtime
 * library (libcudart.so.11.0) without its headers. The names, values and
 * signatures are CUDA 11.4's; nano_trt.cpp links the real library.
 */
#ifndef NANO_CUDA_RUNTIME_API_H
#define NANO_CUDA_RUNTIME_API_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CUstream_st *cudaStream_t;
typedef struct CUevent_st *cudaEvent_t;
typedef int cudaError_t; /* an enum in CUDA; 0 is cudaSuccess */
#define cudaSuccess 0

enum cudaMemcpyKind {
    cudaMemcpyHostToHost = 0,
    cudaMemcpyHostToDevice = 1,
    cudaMemcpyDeviceToHost = 2,
    cudaMemcpyDeviceToDevice = 3,
    cudaMemcpyDefault = 4
};

cudaError_t cudaMalloc(void **devPtr, size_t size);
cudaError_t cudaFree(void *devPtr);
cudaError_t cudaMemcpyAsync(void *dst, const void *src, size_t count, enum cudaMemcpyKind kind,
                            cudaStream_t stream);
cudaError_t cudaMemGetInfo(size_t *free, size_t *total);
cudaError_t cudaStreamCreate(cudaStream_t *stream);
cudaError_t cudaStreamSynchronize(cudaStream_t stream);
cudaError_t cudaStreamDestroy(cudaStream_t stream);
cudaError_t cudaEventCreate(cudaEvent_t *event);
cudaError_t cudaEventRecord(cudaEvent_t event, cudaStream_t stream);
cudaError_t cudaEventElapsedTime(float *ms, cudaEvent_t start, cudaEvent_t end);
cudaError_t cudaEventDestroy(cudaEvent_t event);
const char *cudaGetErrorString(cudaError_t error);

#ifdef __cplusplus
}
#endif

#endif

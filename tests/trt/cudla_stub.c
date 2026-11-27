/* A stand-in for cuDLA's libcudla.so.1, for the Jetson Nano, which has no DLA.
 *
 * JetPack 5's TensorRT (libnvinfer.so.8.5.2 in libnvinfer8 8.5.2-1+cuda11.4)
 * links libcudla.so.1 and imports these eight functions at the version node
 * "libcudla.so.1" (its dynamic section and version needs, read on the owner's
 * PC, 2026-10-15), so it does not load without a library of that name.
 * probe-r35-trt.sh builds this one only when NVIDIA's libcudla.so.1 is missing
 * from the inputs, or cannot resolve its own libraries, or CUDLA=stub is set:
 *   gcc -shared -fPIC -O2 -Wl,-soname,libcudla.so.1
 *       -Wl,--version-script=cudla_stub.map -o libcudla.so.1 cudla_stub.c
 * cudlaDeviceGetCount reports no DLA devices, as on hardware without one;
 * every other function fails, since TensorRT has no device to use them on.
 * The arguments of those are not read, so they are left undeclared.
 * Validation: pending (the Nano run of probe-r35-trt.sh).
 */
#include <stdint.h>

typedef int cudlaStatus;
#define CUDLA_SUCCESS 0
#define CUDLA_STUB_ERROR 0x7fffffff /* any non-zero status is an error to the caller */

cudlaStatus cudlaDeviceGetCount(uint64_t *const count)
{
    if (!count)
        return CUDLA_STUB_ERROR;
    *count = 0;
    return CUDLA_SUCCESS;
}

#define UNSUPPORTED(name) \
    cudlaStatus name() { return CUDLA_STUB_ERROR; }
UNSUPPORTED(cudlaCreateDevice)
UNSUPPORTED(cudlaDestroyDevice)
UNSUPPORTED(cudlaModuleLoadFromMemory)
UNSUPPORTED(cudlaModuleGetAttributes)
UNSUPPORTED(cudlaModuleUnload)
UNSUPPORTED(cudlaMemRegister)
UNSUPPORTED(cudlaSubmitTask)

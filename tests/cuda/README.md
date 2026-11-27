# CUDA validation

`vector_add.cu` is the project's numerical GPU probe. It uses explicit GPU allocations, host/device transfers, kernel launch, synchronization, and exact comparison of every output element. Sizes 1, 255, 256, 257, 50,000, and 1,048,579 cover small inputs and partial thread blocks. CUDA failures and incorrect results exit nonzero.

On a converted Nano, `scripts/jetson/check-u26-r35.sh` and
`scripts/jetson/check-nano-cuda12.sh` build and run it with CUDA 11.4 and
CUDA 12.6 (`-arch=sm_53`), next to the probes below. The converter runs both
at the end of every conversion.

To run an already-built probe:

```bash
./vector_add
./vector_add --seconds 10
```

The timed case launches 256 kernels per batch, then verifies every output. It is a correctness workload, not a performance benchmark or a comprehensive thermal/power qualification.

Acceptance must cover GPU allocation, transfer, kernel execution, synchronization, and output verification. Return a nonzero status on CUDA errors or incorrect numerical results. Record compiler, build flags, runtime/driver versions, input sizes and hardware identity.

It was run first on JetPack 4.6.6 with CUDA 10.2, as the baseline, then at
every stage of the port. A passing host-only or emulated run is not a GPU
validation result.

## The other tools

The first four came from the kernel trials, where each ran on both the 4.9 control boot and the 5.10 trial boot ([patches/jp5/NOTES.md](../../patches/jp5/NOTES.md)).

- `gpu_probe.cu` allocates three buffers of each size from 64 KiB to 16 MiB, prints their GPU addresses, runs vector_add once and then 64 times, and checks every output. It stops at the first failure (`PROBE=FAIL`, exit 1) because a GPU fault leaves the CUDA context unusable. Build it like vector_add.
- `../cpu/cpu_spin.c` (trial 15) spins a register-only integer loop on a given number of threads for a given time and prints each thread's rate in millions of iterations per second. The loop never touches memory, so its rate follows the CPU clock alone. Build with `cc -O2 -pthread -o cpu_spin cpu_spin.c`; run `./cpu_spin THREADS SECONDS`.
- `ioctl_census.c` counts the GPU driver requests a program makes (the 2026-10-12 census behind patch 0001).
- `ioctl_trace.c` logs each nvgpu, nvhost or nvmap request with its argument bytes before and after the call, plus the buffer the driver fills for GET_CHARACTERISTICS and GET_VA_REGIONS. Address-space and nvmap handle requests are logged up to 256 times each, others 8 times, then only counted. It passes every call through unchanged. Build with `cc -O2 -shared -fPIC -o ioctl_trace.so ioctl_trace.c -ldl -lpthread` and run a program under `LD_PRELOAD=./ioctl_trace.so`; set `IOCTL_TRACE=FILE` to log to a file instead of stderr.
- `cuda11_probe.py` (2026-10-15) checks a CUDA driver and runtime through Python's ctypes, for a driver whose compiler is not on the Nano: cuInit, versions, the device, a context, vector_add as PTX for sm_53 JIT-compiled by the driver at vector_add.cu's sizes, and the runtime's allocation and copies with the same kernel. It prints `KEY=VALUE` lines and `PROBE=PASS` or `FAIL`, and lists the NVIDIA libraries it mapped. `scripts/jetson/probes/probe-cuda11.sh` runs it on JetPack 5's CUDA 11.4 driver from a scratch folder, with the system's CUDA 10.2 as the control. Run it with `CUDA_CACHE_DISABLE=1` so the driver keeps no JIT cache.

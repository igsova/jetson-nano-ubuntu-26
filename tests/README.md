# Tests

Two kinds of thing live here, and they prove different things.

**Tests that run on a PC** check the converter's logic. They cannot show
that a Nano boots or that its GPU computes: only a run on the Nano does.
GitHub runs the quick one on every push, with a syntax check of every
script and a check that the 27 kernel patches still apply to the pinned
kernel source ([checks.yml](../.github/workflows/checks.yml)).

**Probes that run on the Nano** are the small programs the checks use
there. Each computes something on the real GPU or video engine and compares
the result with a known answer, so "it installed" is never taken for "it
works".

## On a PC: the converter

```bash
sudo apt install fdisk gpg gpgv dpkg xz-utils
python3 tests/convert/test_nano26_convert.py
```

About 5 seconds, 57 checks, no network and no Nano (its stand-in card is a
sparse file, so the temporary folder needs 11 GB free). It builds a stand-in
Nano (device tree, JetPack release files, a card image with 14 partitions)
and stand-ins for NVIDIA's package servers, signed with keys made for the
test, and runs the real converter against them:

- every check it must pass and every refusal: the wrong board, the wrong
  JetPack, a target that is mounted or is the boot card, a kernel file that
  does not match its hash, a download with the wrong SHA-256;
- the dry run's plan, and that it prints no password hash and no network
  name;
- NVIDIA's signed indexes verified and each package checked, into the copy
  the second stage builds from;
- the kernel download packed, fetched, checked and unpacked;
- that the desktop settings the second stage writes are the ones the
  reference card's scripts write.

```bash
sudo python3 tests/convert/test_convert_image.py
```

The long one. It needs loop devices, the network, about 8 GB, and on a PC
that is not arm64, `qemu-user-static` registered with `binfmt_misc`. The
converter writes a real image from Ubuntu's real archive; the test checks
its partition table and contents, grows it as the first boot does, then
runs the first boot and the second stage in an arm64 chroot of the image
under emulation. NVIDIA's builders and checks are replaced by stubs there,
so it shows the flow (the real `apt` transaction, the settings, resuming
after a failed step, the report, the clean-up) and none of NVIDIA's code.

## On the Nano: the probes

| Folder | What it holds | Used by |
| --- | --- | --- |
| [cuda/](cuda) | `vector_add.cu` and `gpu_probe.cu` compute on the GPU and verify every element; `cuda11_probe.py` and `cuda_libs_probe.py` do the same through a driver with no compiler, and check cuBLAS and cuDNN; `cuda12_dev_check.cu` checks CUDA 12's compiler. `ioctl_census.c` and `ioctl_trace.c` count and log the requests a program makes of NVIDIA's drivers | `check-u26-r35.sh`, `check-nano-cuda12.sh`, the CUDA probes |
| [gl/](gl), [vk/](vk) | Headless OpenGL ES and Vulkan compute, every pixel and value read back | `check-u26-r35.sh` |
| [trt/](trt) | A small network with a known output, built and run by TensorRT in FP32 and FP16 | `check-u26-r35.sh` |
| [video/](video) | Frame comparisons for the video converter, and the source of the two small libraries the video packages carry (`vic_record.c`, `v4l2_plugin_dir.c`) | `probe-l4t-video.sh`, `build-nano-l4t-debs.py` |
| [cursor/](cursor) | A shim that logs what the X driver sends as the mouse pointer's image | `probe-hw-cursor-image.sh` |
| [cpu/](cpu) | `cpu_spin.c`, a loop whose rate follows the CPU clock alone | The kernel trials |

Each folder's README says what its probe checks and what a pass means. A
pass of any of them on a PC, against Mesa or stand-in libraries, tests the
probe and not the Nano.

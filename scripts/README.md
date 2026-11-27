# Scripts

Where things are, and which of them you need.

| Folder | Runs on | What it is for |
| --- | --- | --- |
| [jetson/convert/](jetson/convert) | The Nano | **The converter.** If you only want Ubuntu 26.04 on your Nano, this is the one folder you run anything from |
| [jetson/](jetson) | The Nano | What the converter's second stage runs, and checks and helpers for a converted system |
| [jetson/yolo/](jetson/yolo) | The Nano | The two webcam demos, and TensorRT 8.2 |
| [host/](host) | A Linux PC | Building the kernel, repackaging NVIDIA's drivers, exporting the demo models, backing up cards |
| [jetson/probes/](jetson/probes) | The Nano | One-off experiments from the port, kept because they show how each piece was proven |
| [reference-card/](reference-card) | Both | How the project's own card was built by hand, before the converter existed |

Every script starts with a comment that says what it does and what it
changes. Most end by printing one result line, `...=PASS` or `...=FAIL`,
and keep a record of the run in a dated folder in your home.

## Words the scripts use

The scripts were written while the port was under way and keep its working
names.

- **The reference card**: the project's own microSD card, the one the port
  was finished on by hand before the converter existed. Scripts that only
  fit that card are in `reference-card/`.
- **The owner**: whoever the Nano belongs to. "The owner's account" is the
  account that ran `sudo`.
- **Trial N**: the Nth numbered boot of a 5.10 kernel build during the port
  ([patches/jp5](../patches/jp5/README.md)). **Build #N** is the kernel's
  build counter.
- **R32, R35, R36**: NVIDIA's L4T releases under JetPack 4, 5 and 6.
- **u26**: Ubuntu 26.04.

## The converter: `jetson/convert/`

| File | What it does |
| --- | --- |
| `nano26-convert` | Runs on JetPack 4.6.6. Checks the board, downloads everything and builds the new card as an image file (or writes a second card). `--dry-run` shows the plan and writes nothing |
| `nano26-first-boot` | The new card's first boot: grows the system to the whole card, installs Ubuntu's packages, creates your accounts |
| `nano26-stage2`, `nano26-stage2.service` | The second boot: builds, installs and checks the GPU stack, then starts the desktop |

[docs/CONVERTER.md](../docs/CONVERTER.md) describes each step, and
[docs/SAFETY.md](../docs/SAFETY.md) what it writes and refuses.

The converter does not carry its own copies of the build steps. Its second
stage runs these scripts as they are, which is why they sit where they do:

| Script | Its part in a conversion |
| --- | --- |
| `host/build-nano-l4t-debs.py` | Repackages NVIDIA's driver files into the `nano-l4t-*` packages, without NVIDIA's install scripts |
| `host/fetch-r35-cuda.py`, `host/fetch-cuda12-probe.py` | Verify NVIDIA's signed package indexes |
| `host/build-nano-cuda12-debs.py` | Packages CUDA 12.6 and cuDNN 9.3 beside CUDA 11.4 |
| `jetson/install-nano-cuda12.sh`, `jetson/check-nano-cuda12.sh` | Install and check CUDA 12 |
| `jetson/check-u26-r35.sh` | Checks CUDA 11.4, OpenGL ES, Vulkan compute and TensorRT |
| `jetson/yolo/package-trt82.sh`, `jetson/yolo/install-trt82.sh` | Make JetPack 4's TensorRT 8.2 the default, with 8.5 beside it |
| `jetson/enable-u26-fan.sh`, `jetson/enable-hdmi-wake.sh` | The fan's thermal zone, and waking the HDMI screen after it blanks |
| `jetson/probe-l4t-video.sh` | Checks both video converters through VIC and CUDA |

It also reads, without running them: the package lists in
`reference-card/add-u26-*.sh` and `jetson/add-u26-gcc11.sh`, and the pinned
package hashes in `jetson/install-u26-r35.sh`.
[tests/convert](../tests/convert) checks all of these paths on a PC.

## On a converted Nano: `jetson/`

| Script | What it does |
| --- | --- |
| `check-u26-board.sh` | Read-only check of USB, network, serial ports, clocks, power mode and fan |
| `check-u26-power.sh` | Switches between the 5 W and MAXN power modes and back, and shows the fan starting under load |
| `check-usb-webcam.py` | Checks a USB webcam: formats, frame rates, a capture and its microphone |
| `arm-u26-kernel.sh`, `nano-u26-kernel-once` | Try a new kernel build for **one boot**. The previous boot menu is put back before anything else runs, so a kernel that fails leaves the Nano on the old one; `--keep` makes the new one the default |
| `add-u26-gcc11.sh` | GCC 11 for CUDA 11.4's `nvcc`, which supports nothing newer; Ubuntu 26.04 ships nothing older. The converter installs it already |
| `install-u26-r35.sh` | How the reference card moved from JetPack 4's GPU stack to JetPack 5's. The converter installs JetPack 5's from the start and only reads this file's pins |

## The demos: `jetson/yolo/`

The README's two demos, and what they needed. The models are exported on a
PC with PyTorch (`host/export-yolo26.py`, `host/export-depth.py`) and
copied to the Nano as a bundle.

| Script | What it does |
| --- | --- |
| `setup-yolo.sh`, `yolo-cam.py` | Build YOLO26's TensorRT engines and check their detections; live detection from a USB webcam, or from a video file with `--video` |
| `setup-depth.sh`, `depth-cam.py` | The same for Depth Anything V2 Metric Small |
| `nano_trt.cpp` | The small C library both demos call TensorRT through: TensorRT has no Python bindings for Ubuntu 26.04's Python |
| `package-trt82.sh`, `install-trt82.sh`, `trt-default.sh` | JetPack 4's TensorRT 8.2 on JetPack 5's driver. It runs these models 1.5 to 1.6 times faster than 8.5 on this GPU |
| `probe-trt82.sh`, `probe-depth-trt.sh`, `profile-yolo.sh`, `trt-profile.py` | The measurements behind that: per-layer profiles, and which layers of the depth model each TensorRT builds |

## On a PC: `host/`

| Script | What it does |
| --- | --- |
| `build-jp5-kernel.sh` | Builds the 5.10 kernel, modules and device trees from pinned sources and [patches/jp5](../patches/jp5/README.md) |
| `pack-jp5-kernel.sh` | Packs that build into the one file the converter downloads |
| `backup-card.sh`, `restore-card.sh`, `verify-card.py`, `prepare-smaller-image.py` | Card backups, verified byte for byte ([docs/BACKUP.md](../docs/BACKUP.md)) |
| `survey-r35-gpu-archs.py`, `survey-r36-nano.py` | Read, without running anything, which of NVIDIA's JetPack 5 and 6 libraries still carry code for the Nano's GPU. This is how CUDA 12.6 and cuDNN 9.3 were found to be worth trying |
| `export-yolo26.py`, `export-depth.py` | Export the demo models to ONNX with reference results |

The `host/` scripts in the converter's table above run on a PC too, which
is how the reference card's packages were first built.

## The experiments: `jetson/probes/`

Before anything was installed, each part of NVIDIA's newer stack was tried
from a scratch folder, leaving the system as it was.

| Script | The question it answered |
| --- | --- |
| `probe-cuda11.sh`, `probe-cuda12.sh` | Do JetPack 5's CUDA 11.4 and NVIDIA's CUDA 12 compute correctly on this GPU and kernel? |
| `probe-r35-gl.sh`, `probe-r35-vk.sh`, `probe-r35-x.sh`, `probe-r35-trt.sh` | The same for OpenGL ES, Vulkan, the X driver and TensorRT 8.5 |
| `probe-l4t-codec.sh` | Do the hardware video decoder, encoder and JPEG engine work, and are their pictures right? |
| `vic-compare.sh`, `vic-r32-display.sh`, `vic-u1804.sh` | Why did the video converter's jobs never finish? Three rounds of narrowing that ended in kernel patch 0029 |
| `probe-hdmi-wake.sh` | Why does the screen stay dark after it blanks? It led to `enable-hdmi-wake.sh` |
| `probe-hw-cursor.sh`, `probe-hw-cursor-image.sh` | Why is there no mouse pointer with JetPack 5's X driver? |

## The reference card: `reference-card/`

The project's own card was not made by the converter. It started as a
JetPack 4 card, gained a second partition with Ubuntu 26.04, and was cut
down to 26.04 alone once that worked. These scripts are that path, and they
only fit that card: they check its partition ids before they do anything.
They stay because the converter takes its package lists and desktop
settings from them, and a test compares the two.

| Script | Its step |
| --- | --- |
| `add-u26-partition.py` | Add a partition for Ubuntu 26.04 in the card's free space |
| `build-u26-root.sh` | Build Ubuntu 26.04 into it, from the running 5.10 system |
| `arm-u26-oneshot.sh`, `nano-u26-oneshot-init` | Boot it once, with the old system as the fallback |
| `add-u26-desktop.sh`, `add-u26-gpu-desktop.sh`, `add-u26-unity.sh` | The desktops, on the GPU |
| `set-u26-default.sh` | Make Ubuntu 26.04 the default boot |
| `build-u26-image.py` | Build the image that holds Ubuntu 26.04 alone |

## What is no longer here

Three groups of scripts were removed before the repository was published,
because nothing in the finished system uses them: Ubuntu 26.04 on NVIDIA's
4.9 kernel with systemd 249 (the project's first stage), the harness that
ran each kernel trial from a JetPack 4 card, and the JetPack 4 set-up
helpers. [patches/jp5/NOTES.md](../patches/jp5/NOTES.md) still describes the
kernel trials.

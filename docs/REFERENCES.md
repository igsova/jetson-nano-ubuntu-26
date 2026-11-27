# References

What this project was built from and read against. A reference describes
someone else's release or work; what happened on this Nano is in the
[kernel port's notes](../patches/jp5/NOTES.md) and the other pages in
[docs/](.).

## Source and packages this project uses

- [OE4T linux-tegra-5.10](https://github.com/OE4T/linux-tegra-5.10): NVIDIA's
  JetPack 5 kernel source as one tree. The kernel is built from commit
  `4bce4d148ef3ff159ab55c127d8761aeaac5cc28` (L4T R35.6) plus
  [patches/jp5](../patches/jp5/README.md).
- [OE4T linux-tegra-4.9](https://github.com/OE4T/linux-tegra-4.9): NVIDIA's
  JetPack 4 kernel source, the reference for how the Nano's drivers behave
  and the source of the Nano's device tree (commit
  `6944a5ce1dae5947ff24ada6b6592d9e3062d38c`).
- [NVIDIA's Jetson package repository](https://repo.download.nvidia.com/jetson/):
  the signed apt indexes the converter reads (t210 r32.7, t194 r35.6 and
  common r32.7, r35.6 and r36.4).
- [NVIDIA's CUDA repository for Jetson](https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/arm64/):
  `cuda-compat-12-2`, CUDA 12.2's driver for JetPack 5.
- [Ubuntu Base 26.04.1 for arm64](https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/)
  and [Ubuntu's ports archive](https://ports.ubuntu.com/ubuntu-ports/).
- [NVIDIA's software licence for Jetson](https://docs.nvidia.com/jetson/jetpack/eula/index.html),
  which the converter shows before it downloads NVIDIA's packages.

## NVIDIA's releases for the Nano

- [JetPack archive](https://developer.nvidia.com/embedded/jetpack-archive):
  which JetPack supports which board.
- [Jetson Linux R32.7.6](https://developer.nvidia.com/embedded/linux-tegra-r3276):
  the last release for the Nano: kernel 4.9, Ubuntu 18.04.
- [JetPack 4.6.6](https://developer.nvidia.com/jetpack-sdk-466): the last
  software stack for the Nano, with CUDA 10.2.
- [Nano developer kit setup](https://developer.nvidia.com/embedded/learn/get-started-jetson-nano-devkit)
  and the [Nano 4GB SD card image](https://developer.nvidia.com/jetson-nano-sd-card-image)
  (JetPack 4.6.1).
- [R32.7.6: updating a Jetson](https://docs.nvidia.com/jetson/archives/l4t-archived/l4t-3276/Tegra%20Linux%20Driver%20Package%20Development%20Guide/updating_jetson_and_host.html)
  and its [Quick Start](https://docs.nvidia.com/jetson/archives/l4t-archived/l4t-3276/Tegra%20Linux%20Driver%20Package%20Development%20Guide/quick_start.html):
  NVIDIA's update mechanism, recovery over micro-USB, the A02 and B01
  carrier boards.

## Ubuntu and systemd

- [Ubuntu 26.04 release notes](https://documentation.ubuntu.com/release-notes/26.04/changes-since-previous-interim/):
  what changed in user space, systemd 259 among it.
- [systemd 259's README](https://github.com/systemd/systemd/blob/v259/README):
  the minimum kernel, Linux 5.4, which is why JetPack 4's 4.9 could not
  stay.

## Video converter (VIC)

- [libdrm's VIC 4.0 definitions](https://gitlab.freedesktop.org/mesa/drm/-/blob/main/tests/tegra/vic40.h):
  the public description of VIC's settings block, used to decode what
  JetPack 4's and JetPack 5's converters send.

## Earlier community work on newer Ubuntu for the Nano

Read at the start (2026-10-11). These keep JetPack 4's 4.9 kernel.

- [Qengineering: Ubuntu 20.04 on the Jetson Nano](https://www.qengineering.eu/install-ubuntu-20.04-on-jetson-nano.html)
  and its [image](https://github.com/Qengineering/Jetson-Nano-Ubuntu-20-image).
- [xronos-inc: headless Ubuntu 22.04](https://github.com/xronos-inc/jetson-nano-ubuntu-22.04).
- [An Ubuntu 22.04 CUDA container on JetPack 4](https://gist.github.com/gpshead/0c3a9e0a7b3e180d108b6f4aef59bc19).

## Demos

- [Ultralytics YOLO](https://docs.ultralytics.com/) (YOLO26n) and
  [Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2):
  the models the two demos run. Each has its own licence; the models are
  not in this repository.

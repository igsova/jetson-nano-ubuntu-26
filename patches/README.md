# Patches

Everything this project changes in software it did not write.

- [jp5/](jp5/README.md): the kernel port. JetPack 5's Linux 5.10 kernel
  (L4T R35.6) on the Jetson Nano: 27 patches, the Nano's device tree for
  5.10 and a config fragment, each with the problem it fixes and the boot
  that showed it fixed. Applied by
  [build-jp5-kernel.sh](../scripts/host/build-jp5-kernel.sh).

NVIDIA's and Ubuntu's packages are not patched here. Where the project
adapts one, the script that repackages it says what it changes and why:
[build-nano-l4t-debs.py](../scripts/host/build-nano-l4t-debs.py) for
NVIDIA's driver set and
[package-trt82.sh](../scripts/jetson/yolo/package-trt82.sh) for
TensorRT 8.2.

Everything under this folder is GPL-2.0-only ([LICENSE](LICENSE)), like the
kernel it changes. The rest of the repository is MIT.

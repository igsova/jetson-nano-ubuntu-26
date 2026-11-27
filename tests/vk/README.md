# Vulkan validation

`vk_probe.py` checks headless Vulkan through the system's Vulkan loader, with
no window system and no compiler or Vulkan tools: an instance, the physical
devices with their features and extensions, a logical device with a compute
queue, a 4 MiB host-visible storage buffer, and the compute shader in
`fill.comp` (embedded as SPIR-V) run on the GPU with every value read back
and checked, then repeated 50 times for a memory-write rate. It uses only
the NVIDIA device unless `--any-vendor` is given. The last line is
`PROBE=PASS` or `PROBE=FAIL`.

`scripts/jetson/probes/probe-r35-vk.sh` runs it on the Nano against JetPack 4's
Vulkan driver and against JetPack 5's (L4T R35.6) from a scratch folder,
writing a driver manifest for each, as on the Nano on 2026-10-15.
A pass on Mesa's lavapipe or any other host is a test of the probe, not of
the Nano's GPU.

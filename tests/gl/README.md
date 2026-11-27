# GL validation

`egl_probe.py` checks headless EGL and OpenGL ES 2 on NVIDIA's Tegra GL
libraries through libglvnd, with no window system and no compiler: a
display on the EGL device platform, a context, a cleared framebuffer read
back exactly, a driver-compiled shader drawing a gradient checked on every
pixel, a triangle over half the frame, and blended fill rate. With `--cuda`
it also allocates and checks GPU memory through the given libcuda in the
same process. The last line is `PROBE=PASS` or `PROBE=FAIL`.

`scripts/jetson/probes/probe-r35-gl.sh` runs it on the Nano against JetPack 4's
libraries and against JetPack 5's (L4T R35.6) from a scratch folder, as on the Nano on 2026-10-15. A pass on Mesa or any other host is a
test of the probe, not of the Nano's GPU.

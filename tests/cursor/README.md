# Hardware mouse pointer

`cursor_shim.c` is an `LD_PRELOAD` library for the X server. It logs each
cursor image NVIDIA's X driver gives tegradc
(`TEGRA_DC_EXT_SET_CURSOR_IMAGE`): the image's size, blend and colour flags,
which bytes of its pixels are set, a picture of its top-left corner, and the
ioctl's result. It also logs X's other cursor calls: the clip setting, and
each position call that changes the pointer's visibility or fails. Depending
on a mode file, it can also change an image before passing it on: write the
CPU caches back, mark it as premultiplied RGBA, or move each pixel's alpha to
the low byte. X's own structure is never changed; the shim changes a copy.

`scripts/jetson/probes/probe-hw-cursor-image.sh` builds it on the Nano and starts
LightDM's X with it, either for four phases at the login screen or, with
`session`, for the login screen and Unity, each without and then with the
shim, as on the Nano on 2026-10-16. Its host test, a stand-in X
that sets a memfd image, checks the logging and the changes, not the Nano's
display.

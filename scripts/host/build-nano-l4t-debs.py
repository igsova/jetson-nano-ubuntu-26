#!/usr/bin/env python3
"""Repackage the Nano's NVIDIA driver files from JetPack 4 or JetPack 5 for Ubuntu 26.04.

Usage: python3 scripts/host/build-nano-l4t-debs.py [--release r32|r35]
           [--set driver|video] [--also DIR ...] [--cc COMPILER] DEBS_DIR OUT_DIR

With --release r32 (the default), DEBS_DIR holds NVIDIA's L4T R32.7.6 .debs
for the Nano (t210) and the two X server .debs from Ubuntu 20.04 below, each
checked against its SHA-256. OUT_DIR receives nano-l4t-core, nano-l4t-cuda,
nano-l4t-power, nano-l4t-gl and nano-l4t-x11 .debs, a list of every file they
hold with its SHA-256, and SHA256SUMS. Only the files listed here are taken, so
the image carries no more of JetPack 4 than the board features this project
keeps need. None of NVIDIA's maintainer scripts or services
is kept: nvidia-l4t-xusb-firmware's postinst writes the boot flash, as do
nvidia-l4t-tools' payload updater and nvidia-l4t-init's bootloader-config
service, none of which is taken.

With --release r35 the same five packages, version 35.6.5-20260701022834+u26.1,
carry JetPack 5's L4T R35.6 libraries instead (nvidia-l4t-core, -3d-core and
-cuda 35.6.5 from NVIDIA's signed t194 r35.6 index): its CUDA 11.4 driver,
OpenGL, EGL, Vulkan and X driver, which ran on the Nano from a scratch folder
(2026-10-15). R35.6 has no Nano firmware and no
nvpmodel settings for it, so the GPU, video and USB firmware and nvpmodel,
tegrastats and jetson_clocks stay R32.7.6's, from the same .debs as above; the
X server stays Ubuntu 20.04's 1.20, which R35.6's X driver ran on. Every
NVIDIA library an R35.6 file links is checked to be in the packages.

NVIDIA's R32 X driver supports X servers up to 1.20 (video driver ABI 24).
26.04's X server 1.21.1 dropped a field from ScrnInfoRec ahead of the driver's
entry points, so nano-l4t-x11 carries Ubuntu 20.04's X server 1.20 and its
libinput driver in /usr/lib/nano-xorg, apart from 26.04's own X server, with
NVIDIA's X driver and GLX module beside them.

The CUDA runtime libraries are NVIDIA's own .debs (cuda-*-10-2 with R32.7.6,
cuda-*-11-4 with R35.6), installed as they are.

With --set video OUT_DIR receives a video converter package instead. With
--release r32 it is nano-l4t-r32-video: JetPack 4's video converter
(nvvidconv), which converts VIC's pictures correctly on the Nano where
R35.6's does not unaided (2026-10-17), and since
+u26.2 its codec elements, nvv4l2decoder (NVDEC), nvv4l2h264enc and
nvv4l2h265enc (NVENC) and nvjpegdec (NVJPG), which passed every check of
scripts/jetson/probes/probe-l4t-codec.sh (2026-10-23). The plugins and every library
of JetPack 4's video set, as scripts/jetson/probe-l4t-video.sh and
probe-l4t-codec.sh ran them, go into
/usr/lib/aarch64-linux-gnu/nano-l4t-r32-video, out of the library path, since
they share names with the installed R35.6 set. The libraries are flattened
into its lib folder, the GStreamer plugins go into its gstreamer-1.0 folder
and libv4l2's plugins (the codec plugin, libv4l2_nvvideocodec.so, among
them) into its libv4l2-plugins folder; the libraries Ubuntu has its own of
(CODEC_SKIP) stay Ubuntu's, as in the probes, except NVIDIA's libv4l2
and libv4lconvert, which load those plugins. A library that links an NVIDIA
library the set lacks is left out, with whatever links it (VIDEO_DROPPED
lines), unless a plugin needs it, and so is a libv4l2 plugin that links one
(V4L2_PLUGIN_DROPPED), unless it is the codec plugin. /usr/bin/nano-r32-video
runs a program with them first in the library path, with the plugins in
GStreamer's, and preloads v4l2_plugin_dir.so, built here from
tests/video/v4l2_plugin_dir.c by the arm64 cross compiler (as below), which
points NVIDIA's libv4l2 at the package's plugin folder instead of
/usr/lib/aarch64-linux-gnu/libv4l/plugins/nv. DEBS_DIR is then the folder
scripts/host/fetch-r35-cuda.py --set video --release r32.7 wrote; the X
server .debs are not needed.

With --set video --release r35 it is nano-l4t-r35-video: JetPack 5's
converter and, since +u26.3, its codec elements, in
/usr/lib/aarch64-linux-gnu/nano-l4t-r35-video in the same way, with the
libraries of R35.6's video set that the installed driver set (nano-l4t-core,
-cuda and -gl R35.6, and CUDA 11.4's runtime) does not already provide, and
with vic_patch.so, built here from tests/video/vic_record.c, and
v4l2_plugin_dir.so, both by the arm64 cross compiler (--cc, or else
aarch64-linux-gnu-gcc or the newest aarch64-linux-gnu-gcc-N on the path).
/usr/bin/nano-r35-video runs a program with them, preloads vic_patch.so
with VIC_PATCH=fix, which turns off the gamma conversion and the round trip
through RGB that JetPack 5's converter asks of the Nano's VIC and sets its
vertical chroma siting to JetPack 4's (with those it passed every VIC check
on the Nano and fitted BT.601 on every row, 2026-10-17), and preloads
v4l2_plugin_dir.so as nano-r32-video does. JetPack 5's decoders gave frames
identical to libav's, and its H.265 encoder and nvjpegdec passed; its H.264
encoder crashes on the Nano in NVIDIA's library under every setting tried, so
H.264 encoding stays nano-r32-video's (2026-10-23). Every NVIDIA library is
then R35.6's, so the same program may also use CUDA 11.4. The package
depends on the driver set's packages whose libraries its own link. DEBS_DIR
is the folder scripts/host/fetch-r35-cuda.py --set video wrote; R35.6's
nvidia-l4t-core, -3d-core and -cuda .debs (the driver set's sources, which
give the names it provides) must be in DEBS_DIR or an --also folder.

Runs as an ordinary user;
needs dpkg-deb. --also names more folders to look in for the .debs. Writes
nothing outside OUT_DIR, and puts the .debs there only once every check has
passed.
"""
import argparse
import fnmatch
import hashlib
import io
import json
import os
import posixpath
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
fetch = __import__('fetch-r35-cuda')  # its ELF reader

# nvpmodel reads each parameter's *_KNEXT path on kernels newer than 4.9. In
# the Nano config of nvidia-l4t-tools 32.7.6 the GPU's FREQ_TABLE_KNEXT names
# Xavier's GPU, so the service failed under 5.10 (kernel trial 28's journal).
# That one line takes its own FREQ_TABLE path, as the GPU's other _KNEXT lines
# already do (trial 29; patches/jp5/NOTES.md, "Userspace configuration").
NVPMODEL_SHA256 = 'd53dee45efb39852bf41e582d0f9a08098ea4430c8b5e7926e07ecf0007bc7b0'
NVPMODEL_EDIT = (
    b'FREQ_TABLE_KNEXT /sys/devices/17000000.gv11b/devfreq/devfreq0/available_frequencies\n',
    b'FREQ_TABLE_KNEXT /sys/devices/gpu.0/devfreq/57000000.gpu/available_frequencies\n')


def nvpmodel_edit(original):
    """Return the Nano nvpmodel config with its GPU FREQ_TABLE_KNEXT line corrected."""
    assert hashlib.sha256(original).hexdigest() == NVPMODEL_SHA256
    old, new = NVPMODEL_EDIT
    lines = original.splitlines(keepends=True)
    assert lines.count(old) == 1 and lines.count(new) == 0
    return b''.join(new if line == old else line for line in lines)


L4T = '32.7.6-20241104234540'
VERSION = L4T + '+u26.1'
# nano-l4t-r32-video's own: .2 adds JetPack 4's codec elements.
R32_VIDEO_VERSION = L4T + '+u26.2'
EPOCH = 1730763940  # 2024-11-04 23:45:40 UTC, the build stamp in L4T's version
TEGRA = 'usr/lib/aarch64-linux-gnu/tegra/'
TEGRA_EGL = 'usr/lib/aarch64-linux-gnu/tegra-egl/'
NANO_XORG = 'usr/lib/nano-xorg/'
NVIDIA_DEBS = {  # SHA-256 of the .debs in NVIDIA's signed t210 r32.7 index (2026-10-15)
    'nvidia-l4t-core': '61ada8308bd38fe6fe1793b658c83c3ef3dcc057a0d9e080dc0336e61be683c2',
    'nvidia-l4t-cuda': '0042650294496d632f5d7695a23632411ec3c1d3b2fdd664181338031bb45f86',
    'nvidia-l4t-3d-core': '44df4b465417916ac1bdb1c801892c7af948114cadf5a3a1eafb780984600a94',
    'nvidia-l4t-firmware': '0404d7ddea8eda64c492f2c4e329c1f92a346d927eaa6926ec47233e70069eff',
    'nvidia-l4t-xusb-firmware': '298d1a481babdd84e5ae74a64576f3263e3cc08852f3fb39a479655a5b95ef86',
    'nvidia-l4t-tools': '09652eeccdfe1829f78ac33401199ccd536507bbcca64eeb9bdbb958df2b5371',
}
# Version and SHA-256 in Ubuntu 20.04's signed focal-updates and focal indexes
# (ports.ubuntu.com, 2026-10-15): the X server NVIDIA's R32 X driver was built for.
UBUNTU_DEBS = {
    'xserver-xorg-core': ('2:1.20.13-1ubuntu1~20.04.20',
                          '55ed33216a88dfbbf334268059fa04c0112a01859ecc5e8dc33433c551140bb8'),
    'xserver-xorg-input-libinput': ('0.29.0-1',
                                    'afe338ad93e287aec5c91f543391c85693fb7cb1bb986529f4dc895697ba467f'),
}

# Read only by the X server in /usr/lib/nano-xorg, as LightDM starts it.
NANO_XORG_CONF = b"""\
# Jetson Nano display through NVIDIA's L4T R32.7.6 X driver (nano-l4t-x11).
# Read only by the X server 1.20 in /usr/lib/nano-xorg.
Section "Module"
    Disable "dri"
EndSection

Section "Device"
    Identifier "Tegra0"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration" "true"
EndSection
"""

# NVIDIA's 99-tegra-devices.rules (nvidia-l4t-init) as this image needs it: the
# same devices and groups, with the commas newer udev expects, and without its
# camera helper, which ships in no R32.7.6 package. Later lines win.
UDEV_RULES = b"""\
# Jetson Nano device access, after NVIDIA L4T R32.7.6's 99-tegra-devices.rules.
ACTION=="remove", GOTO="nano_l4t_end"
KERNEL=="l3cache|nvmap|nvram|nvhdcp*|nvhost*|tegra_camera_ctrl|tegra_cec|tegra_dc*|tegra_mipi_cal|tegra-vi*|ion", GROUP="video", MODE="0660"
KERNEL=="torch|ov*|focuser*|camera*|imx*|sh5*|tps*|mipi-cal|ar*|camchar*|capture-*", GROUP="video", MODE="0660"
KERNEL=="knvrm|knvmap|nvhost-sched-gpu", GROUP="root", MODE="0660"
KERNEL=="nvhost-ctxsw-gpu|nvhost-dbg-gpu|nvhost-prof-gpu", GROUP="debug", MODE="0660"
KERNEL=="tegra-crypto", GROUP="crypto", MODE="0660"
KERNEL=="trusty-ipc-dev*", GROUP="trusty", MODE="0660"
LABEL="nano_l4t_end"
# NVIDIA's 99-tegra-mmc-ra.rules: SD card read-ahead.
ACTION=="add|change", KERNEL=="mmcblk[0-9]", SUBSYSTEMS=="mmc", ATTR{bdi/read_ahead_kb}="2048"
"""

# Instead of NVIDIA's nv.sh and its nv.service, which nvpmodel.service required.
# Of nv.sh's Nano steps this keeps the schedutil CPU governor (5.10's default is
# performance) and its 2 ms rate limit. Left out: the Mesa EGL blanking, display
# manager group changes, Weston links and a world-writable /sys/power/state.
GOVERNOR_UNIT = b"""\
[Unit]
Description=Jetson Nano CPU governor (schedutil, as NVIDIA's nv.sh sets it)
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do echo schedutil > "$g"; done; for r in /sys/devices/system/cpu/cpufreq/schedutil/rate_limit_us /sys/devices/system/cpu/cpufreq/policy*/schedutil/rate_limit_us; do if [ -w "$r" ]; then echo 2000 > "$r"; fi; done'

[Install]
WantedBy=multi-user.target
"""

# NVIDIA's nvpmodel.service runs `nvpmodel -f /etc/nvpmodel.conf` after nv.service
# and before the display manager; the same without nv.service.
NVPMODEL_UNIT = b"""\
[Unit]
Description=Jetson Nano power mode (nvpmodel)
After=systemd-modules-load.service nano-cpu-governor.service
Before=display-manager.service graphical.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nvpmodel -f /etc/nvpmodel.conf

[Install]
WantedBy=multi-user.target
"""


def nano_xorg(rel):
    """An X server file's path in Ubuntu 20.04's package and in nano-l4t-x11."""
    return 'usr/lib/xorg/' + rel, NANO_XORG + rel


def enable(*units):
    # debhelper's pattern: was-enabled is true on a first install.
    text = ''
    for unit in units:
        text += (f"\tdeb-systemd-helper unmask '{unit}' >/dev/null || true\n"
                 f"\tif deb-systemd-helper --quiet was-enabled '{unit}'; then\n"
                 f"\t\tdeb-systemd-helper enable '{unit}' >/dev/null || true\n"
                 f"\telse\n\t\tdeb-systemd-helper update-state '{unit}' >/dev/null || true\n\tfi\n")
    return text


# 'take': (source package, path pattern in it, path in ours: None for the same,
# a prefix ending in / to put in front, or a full path; edit or None)
PACKAGES = {
    'nano-l4t-core': {
        'description': 'NVIDIA L4T R32.7.6 core GPU libraries and firmware for Jetson Nano',
        'depends': 'libc6, libgcc-s1, libstdc++6, libexpat1, libegl1',
        'take': [
            ('nvidia-l4t-core', TEGRA + '*', None, None),
            ('nvidia-l4t-core', 'etc/nv_tegra_release', None, None),
            ('nvidia-l4t-firmware', 'lib/firmware/gm20b/*', 'usr/', None),
            ('nvidia-l4t-firmware', 'lib/firmware/tegra21x/*', 'usr/', None),
            ('nvidia-l4t-xusb-firmware', 'lib/firmware/tegra21x_xusb_firmware', 'usr/', None),
        ],
        # Ubuntu's own libdrm stays in charge; NVIDIA's goes with the desktop backlog.
        'skip': [TEGRA + 'libdrm.so.2'],
        'own': {
            # NVIDIA's copy names /usr/lib/tegra; R32 images carry this path as an edit.
            'etc/ld.so.conf.d/nano-l4t-tegra.conf': b'/usr/lib/aarch64-linux-gnu/tegra\n',
            # The rules name these; R32 creates them only while flashing.
            'usr/lib/sysusers.d/nano-l4t.conf': b'g debug -\ng crypto -\ng trusty -\n',
            'usr/lib/modules-load.d/nano-l4t.conf': b'nvgpu\n',
            'usr/lib/udev/rules.d/99-nano-l4t.rules': UDEV_RULES,
        },
        # 5.10's upstream XUSB driver asks for this name (the initrd carries the same file).
        'links': {'usr/lib/firmware/nvidia/tegra210/xusb.bin': '../../tegra21x_xusb_firmware'},
        'postinst': ('\tldconfig\n\tif command -v systemd-sysusers >/dev/null; then '
                     'systemd-sysusers nano-l4t.conf; fi\n'),
    },
    'nano-l4t-cuda': {
        'description': 'NVIDIA L4T R32.7.6 CUDA driver library for Jetson Nano (CUDA 10.2)',
        'depends': f'libc6, nano-l4t-core (= {VERSION})',
        'take': [
            ('nvidia-l4t-cuda', '*', None, None),
            # libcuda needs the fat binary loader and loads the PTX JIT compiler.
            ('nvidia-l4t-3d-core', TEGRA + 'libnvidia-fatbinaryloader.so.440.18', None, None),
            ('nvidia-l4t-3d-core', TEGRA + 'libnvidia-ptxjitcompiler.so.440.18', None, None),
        ],
        'postinst': '\tldconfig\n',
    },
    'nano-l4t-power': {
        'description': 'NVIDIA L4T R32.7.6 nvpmodel, jetson_clocks and tegrastats for Jetson Nano',
        'depends': f'libc6, nano-l4t-core (= {VERSION}), init-system-helpers',
        'take': [
            ('nvidia-l4t-tools', 'usr/sbin/nvpmodel', None, None),
            ('nvidia-l4t-tools', 'usr/bin/jetson_clocks', None, None),
            ('nvidia-l4t-tools', 'usr/bin/tegrastats', None, None),
            ('nvidia-l4t-tools', 'etc/nvpmodel/nvpmodel_t210_jetson-nano.conf', None,
             nvpmodel_edit),
        ],
        'own': {
            'usr/lib/systemd/system/nano-cpu-governor.service': GOVERNOR_UNIT,
            'usr/lib/systemd/system/nvpmodel.service': NVPMODEL_UNIT,
        },
        'links': {'etc/nvpmodel.conf': 'nvpmodel/nvpmodel_t210_jetson-nano.conf'},
        'dirs': ['var/lib/nvpmodel'],
        'postinst': enable('nano-cpu-governor.service', 'nvpmodel.service'),
        'units': ['nano-cpu-governor.service', 'nvpmodel.service'],
    },
    'nano-l4t-gl': {
        'description': 'NVIDIA L4T R32.7.6 OpenGL, OpenGL ES, EGL and GLX libraries for Jetson Nano',
        'depends': f'libc6, nano-l4t-core (= {VERSION}), libglvnd0, libx11-6, libxext6',
        'take': [
            ('nvidia-l4t-3d-core', TEGRA + 'libGLX_nvidia.so.0', None, None),
            ('nvidia-l4t-3d-core', TEGRA + 'libnvidia-glcore.so.32.7.6', None, None),
            ('nvidia-l4t-3d-core', TEGRA + 'libnvidia-eglcore.so.32.7.6', None, None),
            ('nvidia-l4t-3d-core', TEGRA + 'libnvidia-glsi.so.32.7.6', None, None),
            ('nvidia-l4t-3d-core', TEGRA + 'libnvidia-glvkspirv.so.32.7.6', None, None),
            ('nvidia-l4t-3d-core', TEGRA + 'libnvidia-rmapi-tegra.so.32.7.6', None, None),
            ('nvidia-l4t-3d-core', TEGRA + 'libnvwinsys.so', None, None),
            ('nvidia-l4t-3d-core', TEGRA_EGL + 'libEGL_nvidia.so.0', None, None),
            ('nvidia-l4t-3d-core', TEGRA_EGL + 'libGLESv2_nvidia.so.2', None, None),
            ('nvidia-l4t-3d-core', TEGRA_EGL + 'libGLESv1_CM_nvidia.so.1', None, None),
            ('nvidia-l4t-3d-core', TEGRA_EGL + 'nvidia.json', None, None),
            # A link to nvidia.json: glvnd's EGL tries it before Mesa's 50_mesa.json.
            ('nvidia-l4t-3d-core', 'usr/share/glvnd/egl_vendor.d/10_nvidia.json', None, None),
        ],
        # NVIDIA's postinst puts tegra-egl in the library path; so does this file.
        'own': {'etc/ld.so.conf.d/nano-l4t-tegra-egl.conf': b'/usr/lib/aarch64-linux-gnu/tegra-egl\n'},
        'postinst': '\tldconfig\n',
    },
    'nano-l4t-x11': {
        'description': 'X server 1.20 with NVIDIA L4T R32.7.6 X driver for Jetson Nano',
        'depends': (f'libc6, nano-l4t-core (= {VERSION}), nano-l4t-gl (= {VERSION}), '
                    'xserver-common, x11-xkb-utils, xkb-data, libaudit1, libbsd0, libdbus-1-3, '
                    'libdrm2, libgcrypt20, libgl1, libinput10, libpciaccess0, libpixman-1-0, '
                    'libselinux1, libsystemd0, libudev1, libunwind8, libxau6, libxdmcp6, '
                    'libxfont2, libxshmfence1'),
        'take': [
            ('xserver-xorg-core', *nano_xorg('Xorg'), None),
            ('xserver-xorg-core', *nano_xorg('modules/extensions/libglx.so'), None),
            ('xserver-xorg-core', *nano_xorg('modules/libfb.so'), None),
            ('xserver-xorg-core', *nano_xorg('modules/libwfb.so'), None),
            ('xserver-xorg-core', 'usr/share/doc/xserver-xorg-core/copyright',
             'usr/share/doc/nano-l4t-x11/copyright.xserver-xorg-core', None),
            ('xserver-xorg-input-libinput', *nano_xorg('modules/input/libinput_drv.so'), None),
            ('xserver-xorg-input-libinput', 'usr/share/doc/xserver-xorg-input-libinput/copyright',
             'usr/share/doc/nano-l4t-x11/copyright.xserver-xorg-input-libinput', None),
            ('nvidia-l4t-3d-core', *nano_xorg('modules/drivers/nvidia_drv.so'), None),
            ('nvidia-l4t-3d-core', *nano_xorg('modules/extensions/libglxserver_nvidia.so'), None),
        ],
        'own': {'etc/X11/nano-xorg.conf': NANO_XORG_CONF},
        # Given as -configdir, so that 26.04's /etc/X11/xorg.conf.d stays its own.
        'dirs': ['etc/X11/nano-xorg.conf.d'],
        'postinst': '\ttrue\n',
        'note': (' With Xorg and its libinput driver from Ubuntu 20.04 (xserver-xorg-core\n'
                 f' {UBUNTU_DEBS["xserver-xorg-core"][0]}, xserver-xorg-input-libinput\n'
                 f' {UBUNTU_DEBS["xserver-xorg-input-libinput"][0]}), the X server that driver supports.\n'),
    },
}


# --- L4T R35.6 (JetPack 5), with R32.7.6's Nano firmware and power tools.
R35_L4T = '35.6.5-20260701022834'
R35_VERSION = R35_L4T + '+u26.1'
# nano-l4t-r35-video's own: .2 sets VIC's vertical chroma siting too (VIC_PATCH=fix);
# .3 adds the codec elements.
R35_VIDEO_VERSION = R35_L4T + '+u26.3'
R35_EPOCH = 1782872914  # 2026-07-01 02:28:34 UTC, the build stamp in L4T's version
R35_NVIDIA_DEBS = {  # SHA-256 of the .debs in NVIDIA's signed t194 r35.6 index (2026-10-15)
    'nvidia-l4t-core': 'da40db27fa65d0b2820e84294219ceecb5bd6da04d9d5336fde665cbfe488c36',
    'nvidia-l4t-3d-core': '6363a6e3df0b6efed9450d262c358198311905b7b1c2293b2f62ff3982a956bd',
    'nvidia-l4t-cuda': '4a4ec338db49224f1dc8c4256a11118d2de3a73c0d5242846bc34ac94fab72d4',
}
# R35.6's firmware package holds only Xavier and Orin firmware, and its tools
# only their power settings; these come from R32.7.6 (NVIDIA_DEBS above).
R35_FROM_R32 = ['nvidia-l4t-firmware', 'nvidia-l4t-xusb-firmware', 'nvidia-l4t-tools']
R35 = '35.6.5'

# NVIDIA's R35.6 99-tegra-devices.rules (nvidia-l4t-init) as this image needs
# it: R32.7.6's devices as above, plus the 5.10 GPU driver's /dev/nvgpu/igpu0
# nodes (classes nvidia-gpu-v2 and nvidia-gpu-v2-power), host1x and DMA heap
# devices, in the same groups and modes. Left out: the camera helper and the
# discrete-GPU and Xavier device nodes it creates. Later lines win.
R35_UDEV_RULES = b"""\
# Jetson Nano device access, after NVIDIA L4T R35.6's 99-tegra-devices.rules.
ACTION=="remove", GOTO="nano_l4t_end"
KERNEL=="l3cache|nvmap|nvram|nvhdcp*|nvhost*|tegra_camera_ctrl|tegra_cec|tegra_dc*|tegra_mipi_cal|tegra-vi*|ion", GROUP="video", MODE="0660"
KERNEL=="torch|ov*|focuser*|camera*|imx*|sh5*|tps*|mipi-cal|ar*|camchar*|capture-*|cdi_tsc", GROUP="video", MODE="0660"
SUBSYSTEM=="host1x", GROUP="video", MODE="0660"
SUBSYSTEM=="dma_heap", KERNEL=="system|system_heap", GROUP="video", MODE="0660"
SUBSYSTEM=="nvidia-gpu-v2-power", KERNEL=="power", GROUP="video", MODE="0660"
SUBSYSTEM=="nvidia-gpu-v2", KERNEL=="as|channel|ctrl|tsg", GROUP="video", MODE="0660"
SUBSYSTEM=="nvidia-gpu-v2", KERNEL=="nvsched", GROUP="video", MODE="0640"
SUBSYSTEM=="nvidia-gpu-v2", KERNEL=="ctxsw|dbg|prof|prof-ctx|prof-dev", GROUP="debug", MODE="0660"
SUBSYSTEM=="nvidia-gpu-v2", KERNEL=="sched", GROUP="root", MODE="0660"
KERNEL=="nvhost-ctxsw-gpu|nvhost-dbg-gpu|nvhost-prof-gpu|nvhost-prof-ctx-gpu|nvhost-prof-dev-gpu|tegra-soc-hwpm", GROUP="debug", MODE="0660"
KERNEL=="knvrm|knvmap|nvhost-sched-gpu", GROUP="root", MODE="0660"
KERNEL=="tegra-crypto", GROUP="crypto", MODE="0660"
KERNEL=="trusty-ipc-dev*", GROUP="trusty", MODE="0660"
LABEL="nano_l4t_end"
# NVIDIA's 99-tegra-mmc-ra.rules: SD card read-ahead.
ACTION=="add|change", KERNEL=="mmcblk[0-9]", SUBSYSTEMS=="mmc", ATTR{bdi/read_ahead_kb}="2048"
"""


def vulkan_icd(data):
    """NVIDIA's Vulkan driver manifest, unchanged, once it is seen to name libGLX_nvidia.so.0."""
    manifest = json.loads(data)
    assert manifest['ICD']['library_path'] == 'libGLX_nvidia.so.0', manifest
    return data


R35_PACKAGES = {
    'nano-l4t-core': {
        'description': 'NVIDIA L4T R35.6 core GPU libraries, with R32.7.6 firmware, for Jetson Nano',
        'depends': 'libc6, libgcc-s1, libstdc++6, libexpat1, libegl1',
        'take': [
            ('nvidia-l4t-core', TEGRA + '*', None, None),
            ('nvidia-l4t-core', 'etc/nv_tegra_release', None, None),
            ('nvidia-l4t-firmware', 'lib/firmware/gm20b/*', 'usr/', None),
            ('nvidia-l4t-firmware', 'lib/firmware/tegra21x/*', 'usr/', None),
            ('nvidia-l4t-xusb-firmware', 'lib/firmware/tegra21x_xusb_firmware', 'usr/', None),
        ],
        # Ubuntu's libdrm stays in charge, as with R32.7.6; tegra/ld.so.conf
        # is the target of NVIDIA's postinst alternative, which this replaces.
        'skip': [TEGRA + 'libdrm.so.2', TEGRA + 'ld.so.conf'],
        'own': {
            'etc/ld.so.conf.d/nano-l4t-tegra.conf': b'/usr/lib/aarch64-linux-gnu/tegra\n',
            'usr/lib/sysusers.d/nano-l4t.conf': b'g debug -\ng crypto -\ng trusty -\n',
            'usr/lib/modules-load.d/nano-l4t.conf': b'nvgpu\n',
            'usr/lib/udev/rules.d/99-nano-l4t.rules': R35_UDEV_RULES,
        },
        'links': {'usr/lib/firmware/nvidia/tegra210/xusb.bin': '../../tegra21x_xusb_firmware'},
        'postinst': PACKAGES['nano-l4t-core']['postinst'],
    },
    'nano-l4t-cuda': {
        'description': 'NVIDIA L4T R35.6 CUDA driver library for Jetson Nano (CUDA 11.4)',
        'depends': f'libc6, nano-l4t-core (= {R35_VERSION})',
        'take': [
            ('nvidia-l4t-cuda', '*', None, None),
            # libcuda loads the PTX JIT compiler by this name; NVIDIA's NVVM compiler
            # library goes with it, for CUDA's run-time compiling (not seen loaded yet).
            ('nvidia-l4t-3d-core', TEGRA + f'libnvidia-ptxjitcompiler.so.{R35}', None, None),
            ('nvidia-l4t-3d-core', TEGRA + 'libnvidia-ptxjitcompiler.so.1', None, None),
            ('nvidia-l4t-3d-core', TEGRA + f'libnvidia-nvvm.so.{R35}', None, None),
            ('nvidia-l4t-3d-core', TEGRA + 'libnvidia-nvvm.so.4', None, None),
        ],
        'postinst': '\tldconfig\n',
    },
    'nano-l4t-power': {
        **PACKAGES['nano-l4t-power'],
        'depends': f'libc6, nano-l4t-core (= {R35_VERSION}), init-system-helpers',
    },
    'nano-l4t-gl': {
        'description': 'NVIDIA L4T R35.6 OpenGL, OpenGL ES, EGL, GLX and Vulkan libraries for Jetson Nano',
        'depends': f'libc6, nano-l4t-core (= {R35_VERSION}), libglvnd0, libx11-6, libxext6',
        'take': [
            ('nvidia-l4t-3d-core', TEGRA + 'libGLX_nvidia.so.0', None, None),
            *[('nvidia-l4t-3d-core', TEGRA + f'libnvidia-{lib}.so.{R35}', None, None)
              for lib in ('glcore', 'eglcore', 'glsi', 'glvkspirv', 'rmapi-tegra', 'rtcore')],
            ('nvidia-l4t-3d-core', TEGRA + 'nvidia_icd.json', None, vulkan_icd),
            ('nvidia-l4t-3d-core', TEGRA_EGL + 'libEGL_nvidia.so.0', None, None),
            ('nvidia-l4t-3d-core', TEGRA_EGL + 'libGLESv2_nvidia.so.2', None, None),
            ('nvidia-l4t-3d-core', TEGRA_EGL + 'libGLESv1_CM_nvidia.so.1', None, None),
            ('nvidia-l4t-3d-core', TEGRA_EGL + 'nvidia.json', None, None),
            ('nvidia-l4t-3d-core', 'usr/share/glvnd/egl_vendor.d/10_nvidia.json', None, None),
        ],
        'own': {'etc/ld.so.conf.d/nano-l4t-tegra-egl.conf': b'/usr/lib/aarch64-linux-gnu/tegra-egl\n'},
        # The Vulkan loader's system folder; NVIDIA links the manifest from /etc/vulkan.
        'links': {'usr/share/vulkan/icd.d/nvidia_icd.json':
                  '../../../lib/aarch64-linux-gnu/tegra/nvidia_icd.json'},
        'postinst': '\tldconfig\n',
    },
    'nano-l4t-x11': {
        **PACKAGES['nano-l4t-x11'],
        'description': 'X server 1.20 with NVIDIA L4T R35.6 X driver for Jetson Nano',
        'depends': PACKAGES['nano-l4t-x11']['depends'].replace(VERSION, R35_VERSION),
    },
}

RELEASES = {
    'r32': {'version': VERSION, 'epoch': EPOCH, 'packages': PACKAGES, 'check_links': False,
            'nvidia': [(name, L4T, digest) for name, digest in NVIDIA_DEBS.items()]},
    'r35': {'version': R35_VERSION, 'epoch': R35_EPOCH, 'packages': R35_PACKAGES, 'check_links': True,
            'nvidia': [(name, R35_L4T, digest) for name, digest in R35_NVIDIA_DEBS.items()]
                      + [(name, L4T, NVIDIA_DEBS[name]) for name in R35_FROM_R32]},
}
# An NVIDIA library: what an R35.6 file may link only from these packages.
NVIDIA_LIB = re.compile(r'lib(nv|cuda|cudla|cudnn|cublas|GLX_nvidia|EGL_nvidia|GLES(v1_CM|v2)_nvidia)')


# --- JetPack 4's or JetPack 5's video converter (--set video), in a folder of its own.
LIB = 'usr/lib/aarch64-linux-gnu/'
VIDEO_PLUGINS = ['libgstnvvidconv.so']
# The codec elements too: nvv4l2decoder, nvv4l2h264enc and nvv4l2h265enc
# (NVDEC, NVENC) and nvjpegdec (NVJPG). JetPack 4's (nano-l4t-r32-video
# +u26.2) passed every check of scripts/jetson/probes/probe-l4t-codec.sh on the Nano
# (run 6, 2026-10-23); JetPack 5's (nano-l4t-r35-video
# +u26.3) every one but H.264 encoding, whose element crashes; installed, it
# passed them with H.264 encoding skipped (2026-10-24).
CODEC_PLUGINS = VIDEO_PLUGINS + ['libgstnvvideo4linux2.so', 'libgstnvjpeg.so']
# The codec elements reach the engines through NVIDIA's libv4l2, which loads
# the plugins in this folder of the video set.
V4L2_PLUGINS = LIB + 'libv4l/plugins/nv/'
V4L2_CODEC_PLUGIN = 'libv4l2_nvvideocodec.so'
VIDEO_NVIDIA_DEBS = {  # sha256sum of the PC's copies beside NVIDIA_DEBS's (2026-10-15)
    'nvidia-l4t-gstreamer': '9608bace9efa0a3cb29c19500a917ff3f0f0fce5451dee3fc9f6bc01d47b41d2',
    'nvidia-l4t-multimedia': 'e85b22ac1988e7e8926258efd7a54b16fa4fcdbb15810b73dc817570524f0d7b',
    'nvidia-l4t-multimedia-utils': 'e15b36238e2ff67fa615fdbb599203439a481d2ddf95409076d7815303b9c1ce',
    'nvidia-l4t-camera': 'cba6d67cbfc95765459489290e948b6d86fde65d045b8b58eca9ef01906faf3b',
}
# The packages fetch-r35-cuda.py --set video --release r32.7 took (2026-10-16).
VIDEO_SOURCES = ['nvidia-l4t-gstreamer', 'nvidia-l4t-multimedia', 'nvidia-l4t-multimedia-utils',
                 'nvidia-l4t-core', 'nvidia-l4t-cuda', 'nvidia-l4t-3d-core', 'nvidia-l4t-camera']
# The names the probe set aside for Ubuntu's own (2026-10-16): Ubuntu's stay in charge.
VIDEO_SKIP = {'libcuda.so', 'libdrm.so.2', 'libgbm.so.1', 'libv4l2.so.0', 'libv4lconvert.so.0'}
# A set with its codecs keeps NVIDIA's libv4l2 and libv4lconvert, as
# probe-l4t-codec.sh ran them: Ubuntu's libv4l2 does not look in NVIDIA's plugin folder.
CODEC_SKIP = VIDEO_SKIP - {'libv4l2.so.0', 'libv4lconvert.so.0'}
LIBRARY = re.compile(r'lib.+\.so(\.[0-9][0-9.]*)?$')

LAUNCHER = b"""\
#!/bin/sh
# Run a program with JetPack 4's video converter and codecs (NVIDIA L4T
# R32.7.6) from nano-l4t-r32-video: nvvidconv (VIC), nvv4l2decoder (NVDEC),
# nvv4l2h264enc and nvv4l2h265enc (NVENC) and nvjpegdec (NVJPG). Its NVIDIA
# libraries come first in the library path, ahead of the installed driver
# set's (L4T R35.6), GStreamer finds its plugins and keeps a registry of its
# own, and v4l2_plugin_dir.so (built from this project's
# tests/video/v4l2_plugin_dir.c, whose source is in
# /usr/share/doc/nano-l4t-r32-video) points NVIDIA's libv4l2 at the codec
# plugin in the package's folder. For example:
#   nano-r32-video gst-launch-1.0 filesrc location=clip.h264 ! h264parse ! nvv4l2decoder \\
#       ! nvvidconv ! video/x-raw,format=I420 ! fakesink
# nvvidconv after nvv4l2decoder averages each colour row with the row below
# and turns BT.709 pictures into BT.601 (2026-10-23).
# Everything the program loads by those names is JetPack 4's, CUDA's driver
# library included, so it cannot also use JetPack 5's CUDA or TensorRT.
dir=/usr/lib/aarch64-linux-gnu/nano-l4t-r32-video
if [ $# -eq 0 ]; then
    echo 'usage: nano-r32-video PROGRAM [ARGUMENT...]' >&2
    exit 2
fi
LD_LIBRARY_PATH=$dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
GST_PLUGIN_PATH=$dir/gstreamer-1.0${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}
GST_REGISTRY=${GST_REGISTRY:-${XDG_CACHE_HOME:-$HOME/.cache}/gstreamer-1.0/registry.nano-r32-video.bin}
LD_PRELOAD=$dir/v4l2_plugin_dir.so${LD_PRELOAD:+:$LD_PRELOAD}
V4L2_PLUGIN_DIR=$dir/libv4l2-plugins
export LD_LIBRARY_PATH GST_PLUGIN_PATH GST_REGISTRY LD_PRELOAD V4L2_PLUGIN_DIR
exec "$@"
"""


# JetPack 5's video set (--release r35), L4T R35.6, as scripts/host/fetch-r35-cuda.py
# --set video took it: the three packages, and nvsci and camera for libraries they link.
R35_VIDEO_DEBS = {  # sha256sum of the PC's copies (owner, 2026-10-17), which the Nano's probe checked
    'nvidia-l4t-gstreamer': 'be08cb606da6b319b9dc1207cd05aa600f41c028af1c0a27abe940942390efd1',
    'nvidia-l4t-multimedia': '9d3e4466fb9b73ca1ea9738cea4497e553d3fa9b9ae85e058fd7e9105dab4f6e',
    'nvidia-l4t-multimedia-utils': '1b0a81fce90cd6576caa707cbfecbeed5239dccb7e7df887c2d5355a82bcabf4',
    'nvidia-l4t-nvsci': 'e3995470226231de918e68d95f00b1d01781b7cfe6c2744846d0190ab5cdf856',
    'nvidia-l4t-camera': '58468885ea881881c94a91b6a7a77624086cfc85b9a4ba79579d08393c73c327',
}
# Installed on the Nano with CUDA 11.4's runtime libraries (install-u26-r35.sh).
R35_VIDEO_INSTALLED = {'libcudart.so.11.0': 'cuda-cudart-11-4'}
# The VIC fix: an LD_PRELOAD library that sets the settings JetPack 5's converter
# gives VIC to JetPack 4's values in each job (2026-10-17).
TESTS_VIDEO = Path(__file__).resolve().parents[2] / 'tests/video'
SHIM_SOURCE = TESTS_VIDEO / 'vic_record.c'
SHIM = 'vic_patch.so'
# The codecs: an LD_PRELOAD library that points NVIDIA's libv4l2 at the
# package's plugin folder (V4L2_PLUGIN_DIR) instead of its fixed one.
V4L2_SHIM_SOURCE = TESTS_VIDEO / 'v4l2_plugin_dir.c'
V4L2_SHIM = 'v4l2_plugin_dir.so'
SHIM_GLIBC = (2, 43)  # Ubuntu 26.04's
SHIM_LIBS = {'libc.so.6', 'libdl.so.2', 'ld-linux-aarch64.so.1'}  # the last for the stack protector's guard

R35_LAUNCHER = b"""\
#!/bin/sh
# Run a program with JetPack 5's video converter and codecs (NVIDIA L4T R35.6)
# from nano-l4t-r35-video: nvvidconv (VIC), nvv4l2decoder (NVDEC),
# nvv4l2h265enc (NVENC) and nvjpegdec (NVJPG), with VIC's settings corrected
# for the Nano. JetPack 5's converter asks VIC for a gamma conversion and,
# when it scales, a round trip through RGB, which spoil the Nano's colour and
# filtering, and sites chroma so that odd rows take the next row pair's
# (2026-10-17). vic_patch.so, built from tests/video/vic_record.c (its source
# is in /usr/share/doc/nano-l4t-r35-video), sets these to JetPack 4's values
# in each job before VIC gets it: VIC_PATCH=fix, the default here;
# VIC_PATCH= (empty) runs the converter unchanged. The package's
# libraries come first in the library path, GStreamer finds its plugins and
# keeps a registry of its own, and v4l2_plugin_dir.so (built from
# tests/video/v4l2_plugin_dir.c, also in the doc folder) points NVIDIA's
# libv4l2 at the codec plugin in the package's folder. Every NVIDIA library
# is R35.6's, as the installed driver set's are, so the program may also use
# CUDA 11.4. For example:
#   nano-r35-video gst-launch-1.0 filesrc location=clip.h264 ! h264parse ! nvv4l2decoder \\
#       ! nvvidconv ! video/x-raw,format=I420 ! fakesink
# Its decoded frames were identical to libav's (2026-10-23). Its nvv4l2h264enc crashes on the Nano: encode H.264 with
# nano-r32-video. For JPEG, nvjpegdec works; nvv4l2decoder mjpeg=1 does not.
dir=/usr/lib/aarch64-linux-gnu/nano-l4t-r35-video
if [ $# -eq 0 ]; then
    echo 'usage: nano-r35-video PROGRAM [ARGUMENT...]' >&2
    exit 2
fi
LD_LIBRARY_PATH=$dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
GST_PLUGIN_PATH=$dir/gstreamer-1.0${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}
GST_REGISTRY=${GST_REGISTRY:-${XDG_CACHE_HOME:-$HOME/.cache}/gstreamer-1.0/registry.nano-r35-video.bin}
LD_PRELOAD=$dir/vic_patch.so:$dir/v4l2_plugin_dir.so${LD_PRELOAD:+:$LD_PRELOAD}
VIC_PATCH=${VIC_PATCH-fix}
V4L2_PLUGIN_DIR=$dir/libv4l2-plugins
export LD_LIBRARY_PATH GST_PLUGIN_PATH GST_REGISTRY LD_PRELOAD VIC_PATCH V4L2_PLUGIN_DIR
exec "$@"
"""
VIDEO_DEPENDS = ('libc6, libgcc-s1, libstdc++6, libexpat1, libegl1, libdrm2, libgbm1, '
                 'libv4l-0t64 | libv4l-0, libglib2.0-0t64 | libglib2.0-0, libgstreamer1.0-0, '
                 'libgstreamer-plugins-base1.0-0')
VIDEOS = {
    'r32': {
        'package': 'nano-l4t-r32-video', 'launcher': 'nano-r32-video', 'script': LAUNCHER,
        'sources': VIDEO_SOURCES, 'plugins': CODEC_PLUGINS, 'skip': CODEC_SKIP, 'v4l2_plugins': True,
        'shims': [(V4L2_SHIM, V4L2_SHIM_SOURCE)], 'driver_set': False,
        'description': 'NVIDIA L4T R32.7.6 video converter and codecs for Jetson Nano, in their own folder',
        'depends': VIDEO_DEPENDS + ', nano-l4t-core',
        'note': (' path; nano-r32-video runs a program with them, the GStreamer plugins\n'
                 ' (nvvidconv, nvv4l2decoder, nvv4l2h264enc, nvv4l2h265enc, nvjpegdec) and\n'
                 ' v4l2_plugin_dir.so, which points NVIDIA\'s libv4l2 at the codec plugin\n'
                 ' in the package\'s folder (built from this project\'s\n'
                 ' tests/video/v4l2_plugin_dir.c, whose source it carries).\n'),
        'release': {'version': R32_VIDEO_VERSION, 'epoch': EPOCH, 'check_links': True, 'ubuntu': False,
                    'nvidia': [(name, L4T, NVIDIA_DEBS.get(name) or VIDEO_NVIDIA_DEBS[name])
                               for name in VIDEO_SOURCES]},
    },
    'r35': {
        'package': 'nano-l4t-r35-video', 'launcher': 'nano-r35-video', 'script': R35_LAUNCHER,
        'sources': list(R35_VIDEO_DEBS), 'plugins': CODEC_PLUGINS, 'skip': CODEC_SKIP, 'v4l2_plugins': True,
        'shims': [(SHIM, SHIM_SOURCE), (V4L2_SHIM, V4L2_SHIM_SOURCE)], 'driver_set': True,
        'description': 'NVIDIA L4T R35.6 video converter and codecs for Jetson Nano, with a VIC fix',
        'depends': VIDEO_DEPENDS + f', nano-l4t-core (= {R35_VERSION})',
        'note': (' path; nano-r35-video runs a program with them, the GStreamer plugins\n'
                 ' (nvvidconv, nvv4l2decoder, nvv4l2h265enc, nvjpegdec; its nvv4l2h264enc\n'
                 ' crashes on the Nano), vic_patch.so, which sets the VIC settings\n'
                 ' JetPack 5\'s converter gives the Nano to JetPack 4\'s values, and\n'
                 ' v4l2_plugin_dir.so, which points NVIDIA\'s libv4l2 at the codec plugin\n'
                 ' in the package\'s folder (built from this project\'s\n'
                 ' tests/video/vic_record.c and v4l2_plugin_dir.c, whose sources it carries).\n'),
        'driver_version': R35_VERSION,
        'release': {'version': R35_VIDEO_VERSION, 'epoch': R35_EPOCH, 'check_links': True, 'ubuntu': False,
                    'nvidia': [(name, R35_L4T, digest)
                               for name, digest in {**R35_VIDEO_DEBS, **R35_NVIDIA_DEBS}.items()]},
    },
}


class Data:
    """File contents in the shape fetch.elf_info reads."""
    def __init__(self, data):
        self.data = data

    def read_bytes(self):
        return self.data


def driver_names(debs):
    """The library names JetPack 5's installed driver set provides (nano-l4t
    R35.6's files, links and SONAMEs, and CUDA 11.4's runtime), each with its
    package and contents (None for a link or a file not in these .debs)."""
    names = {name: (package, None) for name, package in R35_VIDEO_INSTALLED.items()}
    for package, spec in R35_PACKAGES.items():
        for deb, pattern, dest, _ in spec['take']:
            if deb not in R35_NVIDIA_DEBS:
                continue
            for rel in sorted(debs[deb]):
                if not fnmatch.fnmatchcase(rel, pattern) or rel in spec.get('skip', []):
                    continue
                data = debs[deb][rel][1]
                names[posixpath.basename(target(rel, dest))] = (package, data)
                info = fetch.elf_info(Data(data)) if data else None
                if info and info['soname']:
                    names.setdefault(info['soname'], (package, data))
        for rel in spec.get('links', {}):
            names.setdefault(posixpath.basename(rel), (package, None))
    return names


def cross_compiler(given):
    """The arm64 C compiler: GIVEN, or aarch64-linux-gnu-gcc, or the newest
    aarch64-linux-gnu-gcc-N on the path."""
    if given:
        found = shutil.which(given)
        assert found, f'--cc {given}: no such program'
    else:
        names = set()
        for folder in os.environ.get('PATH', '').split(os.pathsep):
            if folder and os.path.isdir(folder):
                names |= {n for n in os.listdir(folder) if re.fullmatch(r'aarch64-linux-gnu-gcc(-[0-9]+)?', n)}
        # The plain name first, then the newest version.
        ranked = sorted(names, key=lambda n: (0, 0) if n == 'aarch64-linux-gnu-gcc'
                        else (1, -int(n.rsplit('-', 1)[1])))
        assert ranked, ('no arm64 C compiler (aarch64-linux-gnu-gcc or aarch64-linux-gnu-gcc-N) '
                        'on the path; name one with --cc')
        found = shutil.which(ranked[0])
    machine = subprocess.check_output([found, '-dumpmachine'], universal_newlines=True).strip()
    assert machine.startswith('aarch64'), f'{found} builds for {machine}, not arm64'
    return found


def build_shim(cc, name, source):
    """NAME (vic_patch.so or v4l2_plugin_dir.so) from SOURCE in tests/video,
    checked to be an arm64 library that needs only C library functions
    Ubuntu 26.04 has."""
    with tempfile.TemporaryDirectory() as work:
        out = Path(work) / name
        # Built in the source's folder by its bare name, so no build path is kept in the file.
        subprocess.check_call([cc, '-O2', '-Wall', '-Wextra', '-shared', '-fPIC', '-o', str(out),
                               source.name, '-ldl'], cwd=source.parent)
        data = out.read_bytes()
    info = fetch.elf_info(Data(data))
    assert info and data[18:20] == b'\xb7\x00', f'{name}: not an arm64 ELF file'
    assert set(info['needed']) <= SHIM_LIBS, f"{name} links {info['needed']}"
    glibc = fetch.glibc_max(info['versions'])
    assert glibc != '-' and tuple(map(int, glibc[6:].split('.'))) <= SHIM_GLIBC, f'{name} needs {glibc}'
    version = subprocess.check_output([cc, '-dumpfullversion', '-dumpversion'], universal_newlines=True).split()[0]
    print(f'SHIM {name} from tests/video/{source.name} by {Path(cc).name} {version} '
          f'sha256={hashlib.sha256(data).hexdigest()} needs={glibc}')
    return data


def resolved(debs, sources, deb, rel):
    """The (deb, path) of the file REL in DEB names, following its links within the video set."""
    for _ in range(8):
        member = debs[deb][rel][0]
        if not member.issym():
            return deb, rel
        rel = posixpath.normpath(posixpath.join(posixpath.dirname(rel), member.linkname))
        deb = next((d for d in [deb, *sources] if rel in debs[d]), None)
        assert deb, f'{rel}: a link to a file the video set lacks'
    raise AssertionError(f'{rel}: too many links')


def video_spec(debs, video, installed=None, shims=None):
    """A video package: the GStreamer plugins, every library of the video set
    (flattened into lib/; a link keeps its target's name, and each library's
    SONAME gets a link as ldconfig -n gives it in the probe), libv4l2's
    plugins (libv4l2-plugins/), the launcher and SHIMS, each name's built
    file (JetPack 5's VIC fix, the libv4l2 plugin folder). INSTALLED maps the names
    the installed driver set provides to its package and contents: such a
    library stays the driver set's when the video set's file is the same, and
    the package depends on each driver package whose libraries it links."""
    installed = installed or {}
    plugins, skip = video['plugins'], video['skip']
    folder = LIB + video['package'] + '/'
    # libv4l2's plugins: every one the set has, by its own name,
    # in libv4l2-plugins/ only (one the set also has under tegra/ stays out of lib/).
    v4l2 = {}  # name: (deb, path of the file, NVIDIA libraries it links)
    if video['v4l2_plugins']:
        for deb in video['sources']:
            for rel in sorted(debs[deb]):
                name = posixpath.basename(rel)
                if rel.startswith(V4L2_PLUGINS) and name.endswith('.so') and name not in v4l2:
                    source = resolved(debs, video['sources'], deb, rel)
                    info = fetch.elf_info(Data(debs[source[0]][source[1]][1]))
                    v4l2[name] = (*source, [lib for lib in info['needed'] if NVIDIA_LIB.match(lib)])
        assert V4L2_CODEC_PLUGIN in v4l2, f'no {V4L2_PLUGINS}{V4L2_CODEC_PLUGIN} in the video set'
    found = {}  # name: [(deb, path, member, data)]
    for deb in video['sources']:
        for rel, (member, data) in sorted(debs[deb].items()):
            name = posixpath.basename(rel)
            if (rel.startswith(LIB) and LIBRARY.match(name) and name not in skip and name not in v4l2
                    and not rel.startswith((LIB + 'gstreamer-1.0/', LIB + 'libv4l/'))):
                found.setdefault(name, []).append((deb, rel, member, data))
    take, links, sonames = [], {}, {}
    for name, entries in sorted(found.items()):
        files = [e for e in entries if not e[2].issym()]
        if files:
            assert len({e[3] for e in files}) == 1, f'{name}: different files of this name'
            if name in installed:
                package = installed[name][0]
                if installed[name][1] == files[0][3]:
                    print(f"VIDEO_INSTALLED {name} (the same file as {package}'s)")
                    continue
                print(f"VIDEO_SHADOWS {name} (not the same file as {package}'s; the probe loaded this one)")
            take.append((files[0][0], files[0][1], folder + 'lib/' + name, None))
            info = fetch.elf_info(Data(files[0][3]))
            if info and info['soname'] and info['soname'] != name:
                sonames.setdefault(info['soname'], name)
            continue
        # A link to the same name elsewhere (tegra/) is that file's alias here.
        targets = {posixpath.basename(e[2].linkname) for e in entries} - {name}
        assert len(targets) <= 1, f'{name}: links to different names {sorted(targets)}'
        if targets:
            links[folder + 'lib/' + name] = targets.pop()
        else:
            print(f'SKIPPED_LINK {name} -> {name} (no file of that name in the video set)')
    names = {posixpath.basename(t[2]) for t in take} | {posixpath.basename(r) for r in links}
    for soname, name in sorted(sonames.items()):
        if soname not in names and soname not in skip:
            links[folder + 'lib/' + soname] = name
            names.add(soname)
    # A library that links an NVIDIA library the set lacks goes, and so does
    # whatever links it, unless the plugin needs it. 2026-10-17: R32's
    # libnvvulkan-producer.so links nvidia-l4t-wayland's libnvidia-egl-wayland.so.1,
    # which none of the seven packages has, so it could not load in the probe,
    # and the converter passed there all the same.
    data = {posixpath.basename(t[2]): debs[t[0]][t[1]][1] for t in take}
    needs = {}
    for name, blob in data.items():
        info = fetch.elf_info(Data(blob))
        needs[name] = [lib for lib in (info['needed'] if info else []) if NVIDIA_LIB.match(lib)]
    plugin_needs = set()
    for plugin in plugins:
        info = fetch.elf_info(Data(debs['nvidia-l4t-gstreamer'][LIB + 'gstreamer-1.0/' + plugin][1]))
        plugin_needs |= {lib for lib in info['needed'] if NVIDIA_LIB.match(lib)}
    target = {posixpath.basename(r): link for r, link in links.items()}

    def file_of(lib):  # the file a library name resolves to through the links
        for _ in range(8):
            lib = target.get(lib, lib)
        return lib

    while True:
        gone = {name: lib for name, libs in needs.items() if name in data
                for lib in libs if file_of(lib) not in data and lib not in skip and lib not in installed}
        if not gone:
            break
        for name, lib in sorted(gone.items()):
            print(f'VIDEO_DROPPED {name} (links {lib}, which the video set lacks)')
            del data[name]
    kept = {t for t in take if posixpath.basename(t[2]) in data}
    take = [t for t in take if t in kept]
    for rel, link in sorted(links.items()):
        if link not in names or file_of(link) not in data:
            print(f'SKIPPED_LINK {posixpath.basename(rel)} -> {link} (not in the video set)')
            del links[rel]
    # A libv4l2 plugin whose libraries the set (or the installed driver set)
    # lacks goes too (NVIDIA's libv4l2 skips a plugin it cannot load); the
    # codec plugin may not.
    for name, (_, _, libs) in sorted(v4l2.items()):
        lacking = [lib for lib in libs if file_of(lib) not in data and lib not in skip and lib not in installed]
        if lacking:
            assert name != V4L2_CODEC_PLUGIN, f'{name} links {lacking[0]}, which the video set lacks'
            print(f'V4L2_PLUGIN_DROPPED {name} (links {lacking[0]}, which the video set lacks)')
            del v4l2[name]
            continue
        plugin_needs |= set(libs)
    reach, todo = set(), list(plugin_needs)
    while todo:
        lib = todo.pop()
        if lib in installed and file_of(lib) not in data:
            continue
        lib = file_of(lib)
        if lib in reach or lib in skip:
            continue
        reach.add(lib)
        assert lib in data, f'the plugin needs {lib}, which the video set lacks'
        todo += needs[lib]
    libraries = len(take)
    for plugin in plugins:
        take.append(('nvidia-l4t-gstreamer', LIB + 'gstreamer-1.0/' + plugin,
                     folder + 'gstreamer-1.0/' + plugin, None))
    for name, (deb, rel, _) in sorted(v4l2.items()):
        take.append((deb, rel, folder + 'libv4l2-plugins/' + name, None))
    print(f'VIDEO_LIBRARIES files={libraries} links={len(links)} plugins={" ".join(plugins)}'
          + (f' libv4l2_plugins={" ".join(sorted(v4l2))}' if v4l2 else ''))
    # For the record: the other libraries its files link, which the system must have.
    system = set()
    for deb, rel, _, _ in take:
        info = fetch.elf_info(Data(debs[deb][rel][1]))
        system |= set(info['needed'] if info else [])
    provided = set(data) | {posixpath.basename(r) for r in links} | set(installed)
    print(f"VIDEO_SYSTEM_LIBS {' '.join(sorted(lib for lib in system - provided if not NVIDIA_LIB.match(lib)))}")
    # The driver set's packages whose libraries the package's files link.
    linked = plugin_needs | {lib for name in data for lib in needs[name]}
    used = sorted({installed[lib][0] for lib in linked if lib in installed and file_of(lib) not in data}
                  - {'nano-l4t-core'})
    version = video.get('driver_version', video['release']['version'])  # the driver set's
    depends = video['depends'] + ''.join(f', {p} (= {version})' if p.startswith('nano-l4t-') else f', {p}'
                                         for p in used)
    if installed:
        print(f"VIDEO_DRIVER_SET {' '.join(used) or 'nano-l4t-core only'} (besides nano-l4t-core)")
    own = {f'usr/bin/{video["launcher"]}': (video['script'], 0o755)}
    for shim_name, shim_source in video['shims']:
        if shims and shim_name in shims:
            own[folder + shim_name] = (shims[shim_name], 0o644)
            own[f'usr/share/doc/{video["package"]}/{shim_source.name}'] = (shim_source.read_bytes(), 0o644)
    return {
        'description': video['description'],
        'depends': depends,
        'take': take,
        'own': own,
        'links': links,
        'postinst': '\ttrue\n',
        'note': f' Its libraries stay in /{folder.rstrip("/")}, out of the library\n' + video['note'],
    }


def check_debs(release, folders):
    """Read each pinned .deb's files, after checking its hash and fields."""
    debs = {}
    pinned = release['nvidia'] + ([(name, version, digest) for name, (version, digest) in UBUNTU_DEBS.items()]
                                  if release.get('ubuntu', True) else [])
    assert len({name for name, _, _ in pinned}) == len(pinned)
    for name, version, digest in pinned:
        filename = f'{name}_{version.split(":", 1)[-1]}_arm64.deb'
        found = [folder / filename for folder in folders if (folder / filename).is_file()]
        assert found, f'{filename} is in none of {", ".join(map(str, folders))}'
        path = found[0]
        data = path.read_bytes()
        assert hashlib.sha256(data).hexdigest() == digest, f'{path.name}: SHA-256'
        fields = subprocess.check_output(['dpkg-deb', '-f', str(path), 'Package', 'Version',
                                          'Architecture'], universal_newlines=True)
        assert fields.split() == ['Package:', name, 'Version:', version, 'Architecture:', 'arm64'], fields
        tar = subprocess.check_output(['dpkg-deb', '--fsys-tarfile', str(path)])
        members = {}
        with tarfile.open(fileobj=io.BytesIO(tar)) as archive:
            for member in archive.getmembers():
                rel = os.path.normpath(member.name)
                if rel == '.':
                    continue
                if member.isfile():
                    members[rel] = (member, archive.extractfile(member).read())
                elif member.issym():
                    members[rel] = (member, None)
                else:
                    assert member.isdir(), (name, member.name)
        debs[name] = members
        print(f'SOURCE {path.name} sha256={digest}')
    return debs


def target(rel, dest):
    if dest is None:
        return rel
    return dest + rel if dest.endswith('/') else dest


def stage(spec, debs, root):
    files = {}
    for deb, pattern, dest, edit in spec['take']:
        matched = [rel for rel in sorted(debs[deb]) if fnmatch.fnmatchcase(rel, pattern)
                   and rel not in spec.get('skip', [])]
        assert matched, (deb, pattern)
        for rel in matched:
            member, data = debs[deb][rel]
            out = target(rel, dest)
            assert out not in files, out
            if member.issym():
                assert edit is None
                files[out] = ('link', member.linkname)
            else:
                files[out] = ('file', edit(data) if edit else data, member.mode & 0o755 | 0o644)
    for rel, data in spec.get('own', {}).items():
        assert rel not in files, rel
        files[rel] = ('file', *(data if isinstance(data, tuple) else (data, 0o644)))
    for rel, link in spec.get('links', {}).items():
        assert rel not in files, rel
        files[rel] = ('link', link)
    for rel, entry in sorted(files.items()):
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if entry[0] == 'link':
            os.symlink(entry[1], path)
        else:
            path.write_bytes(entry[1])
            os.chmod(path, entry[2])
    for rel in spec.get('dirs', []):
        (root / rel).mkdir(parents=True, exist_ok=True)
    for path in [root, *root.rglob('*')]:
        if path.is_dir() and not path.is_symlink():
            os.chmod(path, 0o755)
    return files


def origin(spec, release):
    """The control file's lines naming the L4T releases the package's files come from."""
    versions = {version for name, version, _ in release['nvidia']
                if any(deb == name for deb, _, _, _ in spec['take'])}
    if len(versions) == 1:
        return (f' Files repackaged from NVIDIA L4T {versions.pop()} for Ubuntu 26.04 on the\n'
                f' JetPack 5 kernel. None of NVIDIA\'s maintainer scripts is included.\n')
    newer, older = sorted(versions, reverse=True)
    return (f' Files repackaged from NVIDIA L4T {newer} and\n {older} for Ubuntu 26.04 on the'
            f' JetPack 5 kernel. None of\n NVIDIA\'s maintainer scripts is included.\n')


def control(name, spec, files, root, release):
    debian = root / 'DEBIAN'
    debian.mkdir(mode=0o755)
    size = sum(len(e[1]) for e in files.values() if e[0] == 'file') // 1024 + 1
    (debian / 'control').write_text(
        f'Package: {name}\nVersion: {release["version"]}\nArchitecture: arm64\n'
        f'Maintainer: jetson-ubuntu-26 <noreply@localhost>\nInstalled-Size: {size}\n'
        f'Depends: {spec["depends"]}\nSection: non-free/libs\nPriority: optional\n'
        f'Description: {spec["description"]}\n'
        + origin(spec, release) + spec.get('note', ''))
    conffiles = sorted('/' + rel for rel, e in files.items()
                       if e[0] == 'file' and rel.startswith('etc/'))
    if conffiles:
        (debian / 'conffiles').write_text(''.join(c + '\n' for c in conffiles))
    (debian / 'postinst').write_text(
        '#!/bin/sh\nset -e\nif [ "$1" = configure ]; then\n' + spec['postinst'] + 'fi\n')
    purge = ''.join(f"\tdeb-systemd-helper purge '{u}' >/dev/null || true\n"
                    for u in spec.get('units', []))
    (debian / 'postrm').write_text(
        '#!/bin/sh\nset -e\nif [ "$1" = remove ] || [ "$1" = purge ]; then\n\tldconfig\nfi\n'
        + (f'if [ "$1" = purge ] && [ -x /usr/bin/deb-systemd-helper ]; then\n{purge}fi\n'
           if purge else ''))
    for script in ['postinst', 'postrm']:
        os.chmod(debian / script, 0o755)
    for item in ['control', 'conffiles']:
        if (debian / item).exists():
            os.chmod(debian / item, 0o644)


def build(name, spec, debs, out, work, release):
    root = work / name
    root.mkdir()
    files = stage(spec, debs, root)
    control(name, spec, files, root, release)
    epoch = release['epoch']
    for path in [root, *root.rglob('*')]:
        os.utime(path, (epoch, epoch), follow_symlinks=False)
    deb = out / f'{name}_{release["version"]}_arm64.deb'
    subprocess.check_call(['dpkg-deb', '--root-owner-group', '-Zxz', '--build', str(root), str(deb)],
                          stdout=subprocess.DEVNULL,
                          env={**os.environ, 'SOURCE_DATE_EPOCH': str(epoch)})
    listing = []
    for rel, entry in sorted(files.items()):
        if entry[0] == 'link':
            listing.append(f'{"symlink":64}  {name}  /{rel} -> {entry[1]}')
        else:
            listing.append(f'{hashlib.sha256(entry[1]).hexdigest()}  {name}  /{rel}')
    return deb, listing


def check_links(work, names, installed=()):
    """Every NVIDIA library an ELF file in the staged packages links is one of
    them, or one of the INSTALLED driver set's."""
    provided, needed = set(), {}
    for name in names:
        for path in sorted((work / name).rglob('*')):
            if path.is_symlink():
                provided.add(path.name)
                continue
            info = fetch.elf_info(path) if path.is_file() else None
            if info is None:
                continue
            provided.add(path.name)
            if info['soname']:
                provided.add(info['soname'])
            for lib in info['needed']:
                if NVIDIA_LIB.match(lib):
                    needed.setdefault(lib, set()).add(f'{name}:{path.name}')
    missing = {lib: users for lib, users in needed.items() if lib not in provided and lib not in installed}
    for lib, users in sorted(missing.items()):
        print(f"UNRESOLVED {lib} (linked by {', '.join(sorted(users))})")
    assert not missing, 'an NVIDIA library linked by a packaged file is not in the packages'
    print(f'NVIDIA_LINKS=PASS {len(needed)} NVIDIA libraries linked, all packaged'
          + (f' or the installed driver set\'s ({len(set(needed) & set(installed))})' if installed else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--release', choices=sorted(RELEASES), default='r32')
    parser.add_argument('--set', choices=['driver', 'video'], default='driver',
                        help="video: the release's video converter in its own folder")
    parser.add_argument('--also', type=Path, action='append', default=[],
                        help='another folder to look in for the .debs')
    parser.add_argument('--cc', help='the arm64 C compiler for --set video '
                        '(default: aarch64-linux-gnu-gcc, or the newest aarch64-linux-gnu-gcc-N)')
    parser.add_argument('debs_dir', type=Path)
    parser.add_argument('out_dir', type=Path)
    args = parser.parse_args()
    release = RELEASES[args.release]
    if args.cc and args.set != 'video':
        parser.error('--cc is for --set video only')
    if args.set == 'video':
        video = VIDEOS[args.release]
        release = video['release']
        cc = cross_compiler(args.cc)  # before the .debs are read
    debs = check_debs(release, [d.resolve(strict=True) for d in [args.debs_dir, *args.also]])
    if args.set == 'video':
        installed = driver_names(debs) if video['driver_set'] else {}
        shims = {name: build_shim(cc, name, source) for name, source in video['shims']}
        spec = video_spec(debs, video, installed, shims)
        release = {**release, 'packages': {video['package']: spec}, 'installed': installed}
    out = args.out_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    built, listing = [], []
    with tempfile.TemporaryDirectory() as work:
        # The .debs reach OUT_DIR only once every check has passed.
        staged = Path(work) / 'debs'
        staged.mkdir()
        for name, spec in release['packages'].items():
            deb, files = build(name, spec, debs, staged, Path(work), release)
            built.append(deb)
            listing += files
        if release['check_links']:
            check_links(Path(work), release['packages'], release.get('installed', ()))
        built = [Path(shutil.copy2(deb, out / deb.name)) for deb in built]
    (out / 'nano-l4t-files.txt').write_text('\n'.join(listing) + '\n')
    sums = [f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}'
            for p in built + [out / 'nano-l4t-files.txt']]
    (out / 'SHA256SUMS').write_text('\n'.join(sums) + '\n')
    print('\n'.join(sums))
    print(f'files: {len(listing)}')
    print(f'NANO_L4T_DEBS=PASS release={args.release} set={args.set} out={out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

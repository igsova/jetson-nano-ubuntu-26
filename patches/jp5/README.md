# The kernel port: JetPack 5's Linux 5.10 on the Jetson Nano

NVIDIA released JetPack 5 (L4T R35) only for Xavier and Orin. Its kernel
source still holds the drivers for the Nano's chip, the Tegra X1
(Tegra210): the GPU driver knows the Nano's GM20B GPU and the display driver
keeps its Tegra210 code. NVIDIA never built or ran them for the Nano on
Linux 5.10, though. R35 has no device tree for the board, and with one, the
first boots ended in a kernel panic and then in a clock framework that
froze every driver.

This folder is what it took: 27 patches, one device tree and a short config
fragment.

| | |
| --- | --- |
| Base | NVIDIA L4T R35.6.0, Linux 5.10.216, from [OE4T's mirror](https://github.com/OE4T/linux-tegra-5.10) at `4bce4d14` |
| Patches applied | 27, touching 35 files: 1,523 lines added, 77 removed |
| Diagnostic patches set aside | 2, in [diagnostic/](diagnostic) |
| Device tree | NVIDIA's own Nano B01 tree from L4T R32.7.6, compiled for 5.10, with the changes [below](#the-device-tree) |
| Found and tested with | 39 numbered boot trials on a real Nano, 13 to 15 October 2026, and a few later builds |
| Result | The CPU, GPU and memory run at the same clocks as under NVIDIA's 4.9 kernel, CUDA computes correct results, and trial 38's boot logged no kernel warning |

Each patch file opens with its own description: the problem, the fix, the
trial that found it and the trial that showed it fixed.
[NOTES.md](NOTES.md) holds the notes kept during the port, with every
measurement.

## Why a kernel NVIDIA wrote needs patches to run NVIDIA's board

The problems fall into three kinds.

**1. Old libraries, new kernel.** NVIDIA's user-space libraries are closed,
and they talk to the kernel through numbered requests (ioctls) with fixed
binary layouts. The port began with JetPack 4's libraries and CUDA 10.2 on
the new kernel, and wherever R35 had changed a request's size, changed its
meaning or dropped it, an old library failed, often without a message. Seven
patches accept the old layout beside the new one (0001, 0003, 0004, 0017,
0023, 0024, 0026). The finished system still runs JetPack 4's power tools
and one of its two video sets, which make their requests the old way, so
these stay needed. Two of the seven (0001 and 0017) serve JetPack 4's CUDA
10.2 driver and X driver, which the finished system has since replaced
with JetPack 5's.

**2. Board support that was only finished for Linux 4.9.** R35 keeps the
Tegra210 code but stubs parts of it out on newer kernels, with comments such
as "FIXME Drop this check once dvfs feature is added" and "EMC part is not
enabled yet". Other parts lean on a start-up order or a power-domain model
that changed after 4.9. Memory stayed at 204 MHz instead of 1,600, the GPU's and the
video engines' clocks refused to start, the display's power domains never
switched off, and the video converter's firmware never ran. Fourteen
patches make these work the way R32's 4.9 kernel did (0002, 0008 to 0013,
0016, 0018, 0020, 0022, 0027 to 0029).

**3. Bugs nobody had hit.** Code that never runs on Xavier or Orin had
never been run on 5.10 at all: a two-byte stack overflow that panics the
boot (0005), a clock that waits for itself and freezes every other driver
(0007), a display probe that dereferences NULL (0014), an IOMMU driver that
leaves most of what it maps unflushed (0019), and USB 3 lanes that are
never powered because of a name (0021).

The last patch, 0025, is a diagnostic that stays in because 0026 was written
on top of it.

## How each one was found

A kernel that hangs on an embedded board tells you very little, so the
method was the same every time: change one thing, build, boot it **once**,
collect the kernel log and the test results, and compare them with a boot of
NVIDIA's 4.9 kernel on the same card. The one-boot entry put the previous
boot menu back before anything else ran, so a kernel that failed left the
Nano on the old one at the next power-up. Nothing was ever flashed to the
board (see [docs/SAFETY.md](../../docs/SAFETY.md)).

Where a piece of logic could be tested away from the board, it was: the
memory table parser of 0009 ran in user space against the Nano's device
tree and was compared field by field with an independent script; 0019 was
checked in a model of the CPU cache, the IOMMU's page-table cache and its
TLB wrapped around the driver's real code; 0026 passed 41 of 41 checks in
user-mode Linux built from the same tree. The Nano had the last word each
time: a patch counts as working only from the trial named in its table row.

## The patches

"Trial N" is the Nth numbered boot of a 5.10 build on the Nano. R32 is
JetPack 4's kernel and driver release (Linux 4.9), R35 is JetPack 5's
(Linux 5.10).

### GPU and CUDA

| Patch | What went wrong on the Nano | What the patch does | Shown fixed |
| --- | --- | --- | --- |
| [0001](0001-nvgpu-accept-cuda-10.2-address-space-requests.patch) | Three of the 35 requests CUDA 10.2 makes of the GPU driver changed size in R35, which refuses the old sizes | Serves R32's layouts for `ALLOC_AS`, `ALLOC_SPACE` and `FREE_SPACE` beside R35's | Trial 11 |
| [0002](0002-nvgpu-gm20b-small-pages-without-iommu.patch) | The GPU has no IOMMU in this device tree, and the driver's big pages need contiguous addresses | Turns big pages off on the GM20B when there is no IOMMU, as R35 already does for Xavier | Trial 11 |
| [0003](0003-nvmap-tegra210-and-fd-handles.patch) | NVIDIA's memory-sharing driver, nvmap, refuses to load on anything older than Tegra186 | Accepts Tegra210, and returns handles as file descriptors, which JetPack 4's libraries expect | Trial 11 |
| [0007](0007-nvgpu-gm20b-gpcclk-without-runtime-pm.patch) | The GPU's first power-on froze the boot: a clock prepare waited for the GPU's own resume while holding the clock framework's global lock, so the SD card's driver blocked too | Registers that clock without a device, which is how it behaved on 4.9 | Trial 8 |
| [0008](0008-clk-tegra-gbus-prepare-sets-gpu-dvfs.patch) | R35 stubs out the GPU bus clock's prepare on newer kernels, so the power-on would fail right after the freeze was fixed | Sets the GPU rail's voltage for the clock rate, as R32's copy of the file does | Trial 8 |

Trial 11 is where CUDA first passed every test under 5.10, at all three GPU
clocks. Its last obstacle was in the device tree, not the kernel: the GPU
crashed only at its top clock, because its voltage regulator never moved
(see [the device tree](#the-device-tree)).

### Memory and CPU speed

| Patch | What went wrong on the Nano | What the patch does | Shown fixed |
| --- | --- | --- | --- |
| [0009](0009-memory-tegra210-emc-tables-from-r32-dt.patch) | Memory stayed at its 204 MHz boot speed, and a large CUDA test ran about nine times slower. The memory driver wants its timing tables from a bootloader the Nano does not have | Reads the tables from the device tree, where the Nano's bootloader writes its training results at every boot. Malformed tables are refused | Trials 13 and 14 |
| [0010](0010-bwmgr-follow-emc-clock-range.patch) | The bandwidth manager read the memory clock's range before the memory driver had loaded, and capped every later request at 204 MHz | Re-reads the range before each request and widens it | Trial 13 |
| [0011](0011-soc-tegra210-dvfs-emc-rates-from-r32-tables.patch) | Every switch to 1,600 MHz was refused as "too high": R35 left a placeholder in the voltage table for the memory clock | Fills the table from the board's memory tables, as R32 did: 204 MHz from 800 mV, 1,600 MHz from 900 mV | Trial 14 |
| [0012](0012-cpufreq-tegra124-emc-floor-from-r32-table.patch) | The mainline CPU frequency driver has no link from CPU speed to memory speed, which R32's driver had | Adds R32's memory floor: each CPU speed asks for the memory speed R32's table gives it | Trial 15 |
| [0013](0013-cpufreq-tegra124-r32-cpu-minimum.patch) | The CPU idled down to 204 MHz and took memory down with it while it waited on the GPU, so CUDA ran slower than under 4.9 | Sets R32's 1.2 GHz CPU minimum | Trial 17 |
| [0016](0016-isomgr-follow-emc-clock-range.patch) | The display's bandwidth pool was sized for 204 MHz memory, and the HDMI head's reservation was refused | Updates the range (as 0010) before sizing the pool | Trial 21 |
| [0020](0020-nvpmodel-tegra210-emc-cap-through-bwmgr.patch) | The power-mode driver failed to load on Tegra210 and left a call trace in every boot | Uses the bandwidth manager, as R32 did and as R35 does for Xavier | Trials 27 and 29 |
| [0022](0022-clk-tegra-cbus-dvfs-as-r32.patch) | The video engines' clocks (VIC, encoder, decoder, JPEG) refused to start: the same stub as 0008, on their bus | Voltage on prepare and rate rounding from the voltage table, as R32's copy of the file | Trial 33 |

In trial 14 memory ran at 1,600 MHz and the CUDA baseline verified 53
batches in 10 s, the same as under 4.9 (6 at 204 MHz). From trial 17 the
CUDA tests matched 4.9 at every GPU clock.

### Display

| Patch | What went wrong on the Nano | What the patch does | Shown fixed |
| --- | --- | --- | --- |
| [0014](0014-tegradc-tegra210-probe-on-5.10.patch) | JetPack 4's display driver could not start on 5.10: it gave up on a retryable error, used a pointer before setting it, released a clock twice, and its error path crashed | Fixes the five probe problems and makes the error path safe | Trial 21 |
| [0017](0017-tegradc-ext-r32-buffer-ids.patch) | JetPack 4's X driver passes buffer id 0 for "no buffer", which R35 looks up as file descriptor 0, failing every page flip | Takes 0 as "none" again, and says why when a buffer cannot be used | Trials 22 and 23 |
| [0018](0018-tegra-fb-take-over-firmware-framebuffer.patch) | X opens `/dev/fb0`, which was the boot console's simple framebuffer, and chose 800x600 | NVIDIA's framebuffer takes over from the boot console's and becomes `fb0`, as under 4.9 | Trial 23 |
| [0019](0019-iommu-tegra-smmu-flush-entries-on-map.patch) | Tens of thousands of display memory faults: the IOMMU driver flushed only part of what it mapped, so the hardware read stale entries | Flushes every entry as it is written, as mainline's driver does | Trial 24 |
| [0027](0027-tegradc-t21x-power-state-and-released-resets.patch) | A read timeout after a screen blank, and the HDMI power domain could never switch off (11 errors in one boot) | Asks the kernel whether the head is really powered, and holds the display's resets only while it uses them | Trial 37 |
| [0028](0028-soc-tegra-pmc-tegra210-sor-parent-domain.patch) | Once it could switch off, the HDMI encoder's domain would switch off under a running display | Makes it the parent of the display domains, the order 4.9 kept by hand | Trial 37 |

From trial 24 the boot logo, console, desktop and cursor look as they do
under 4.9, with no display fault in the whole boot.

### USB and PCIe

| Patch | What went wrong on the Nano | What the patch does | Shown fixed |
| --- | --- | --- | --- |
| [0005](0005-phy-tegra210-ss-prod-name-overflow.patch) | A kernel panic early in the boot: powering on the PCIe Ethernet lane wrote `prod_c_ss-22` into an 11-byte buffer | A larger buffer, `snprintf`, and no lookup for lanes without a USB 3 port | Trial 3 |
| [0021](0021-phy-tegra210-usb3-lanes-power-on.patch) | The USB 3 half of the onboard hub never appeared, with no error: the lane setup looks for the name `usb3-ss`, and R35 calls the lane `xusb` | Tests for the name the lanes carry | Trial 30 |

### The video converter, and what JetPack 4's libraries ask for

| Patch | What went wrong on the Nano | What the patch does | Shown fixed |
| --- | --- | --- | --- |
| [0004](0004-fuse-expose-tegra-chip-id-for-r32-userspace.patch) | NVIDIA's tools (`nvpmodel`, `tegrastats`) read the chip id from a path R35's fuse driver does not have | Exposes the same read-only value there | In every build from the first |
| [0023](0023-nvmap-r32-rw-handle-requests.patch) | The video converter stopped on a memory read/write request whose 32-byte form R35 dropped | Serves R32's form again | Trials 34 and 36 |
| [0024](0024-nvhost-r32-fence-names.patch) | It stopped one request later, naming a fence | Accepts the request after R32's check | Trial 35 |
| [0025](0025-diag-sync-file-unknown-requests.patch) | Requests on fences were refused without a word | Diagnostic: logs any request the kernel does not know | Trial 35 |
| [0026](0026-sync-file-r32-android-sync-requests.patch) | The converter reads and waits on its fences through Android's older sync requests, which 5.10 does not have | Serves the three older requests with R32's layouts | Trial 36 |
| [0029](0029-nvhost-vic-tegra210-fce-ucode-setup.patch) | On a boot that had never run 4.9 first, the video engine's firmware halted every job. Tegra210's firmware needs the kernel to tell it where part of its code is, and R35 dropped that step | Restores the two set-up writes at each power-on, as R32 and mainline do | Build #35, 2026-10-17 |

Patch 0029 has the longest story. Trials 36 to 39 converted video without
it, most likely because each trial ran right after a control boot of the
4.9 kernel, which left the engine set up. On the first system that only
ever booted 5.10, every job timed out after 10 s and nothing said why. The
search went through the converter's requests, its libraries and a full
Ubuntu 18.04 user space in a chroot before the firmware's own mailbox gave
the answer; the scripts are still in
[scripts/jetson/probes](../../scripts/jetson/probes).

### Diagnostics, not applied

[diagnostic/0006](diagnostic/0006-diag-trace-gpu-power-on.patch) traced the
GPU's power-on and led to 0007.
[diagnostic/0015](diagnostic/0015-diag-tegradc-hold-tegra210-probe.patch)
held the display probe back until a crash in it could be recorded, and
led to 0014 and 0016. The build applies only the patches in this folder, not
those in `diagnostic/`.

## The device tree

[tegra210-p3448-0000-p3449-0000-b00-r35.dts](tegra210-p3448-0000-p3449-0000-b00-r35.dts)
is not a new board description. It includes NVIDIA's own R32.7.6 tree for
the Nano B01 and compiles it for 5.10, then changes what the newer drivers
need. The changes that mattered most:

- **The GPU's voltage regulator.** The GPU passed CUDA at its two lower
  clocks and crashed at 921.6 MHz. Its rail is set by a PWM signal, and
  under 5.10 the PWM controller ran from the wrong clock, so the regulator
  sat near 710 mV whatever was asked. Giving it JetPack 4's clock source
  fixed it (trial 11).
- **Memory training.** The Nano's bootloader trains the 1,600 MHz memory
  timings at every power-on and copies them into the device tree it is
  given, but only if the memory controller's node keeps the phandle it
  expects. The build fails if that phandle changes.
- **The display behind the IOMMU.** X's screen buffers are scattered in
  memory, so the display has to sit behind an IOMMU to scan them. It now
  uses the mainline one, with the boot logo's buffer mapped through.
- **Per-CPU timers.** With the CPUs' deepest idle state on, the boot
  stopped at 22 s: each CPU needs a wake-up timer that R32's tree did not
  list for 5.10 (trial 27).
- **Smaller things:** names and bindings the newer USB, SD card, serial and
  USB device-mode drivers look for; the display's power domains and the
  resets of its HDMI encoder; CPU cache sizes, which 5.10 reads only from
  the device tree; the PMIC's interrupt type, the last kernel warning in
  the boot (trial 38); VIC, the video encoder, decoder and JPEG engine
  switched on behind the IOMMU.
- **Still off:** the eFuse-burning node (on purpose), and the DisplayPort
  head, the CSI camera path and the audio nodes, which nobody has brought
  up on 5.10 yet.

The second file, `...-gpu-smmu.dts`, is a variant that also puts the GPU
behind the IOMMU. It was a fallback that was never needed.

## The config fragment

[kernel-config.fragment](kernel-config.fragment) goes on top of R35's
`tegra_defconfig`:

| Option | Why |
| --- | --- |
| `CONFIG_TEGRA210_EMC=y` | The memory clock driver that 0009 feeds |
| `CONFIG_ARM_TEGRA124_CPUFREQ=y` | CPU frequency scaling up to 1,479 MHz |
| `CONFIG_PWM_FAN=m`, `CONFIG_SENSORS_PWM_FAN` off | NVIDIA's fan driver, which understands the Nano's fan node; the generic one rejected it |
| `CONFIG_TEGRA_FUSE_BURN` off | No interface for burning eFuses, which is permanent |
| `CONFIG_CGROUP_BPF=y`, `CONFIG_PSI=y` | What Ubuntu 26.04's systemd 259 recommends |
| `CONFIG_PSTORE_RAM=y` | Keeps the last kernel log across a reset |
| `CONFIG_SECURITY_DMESG_RESTRICT` off | Users can read the kernel log, as under JetPack 4 |
| `CONFIG_FTRACE_SYSCALLS=y` | System-call tracing, used to see which requests the video converter makes |
| `CONFIG_LOCALVERSION="-tegra"` | The release string, `5.10.216-tegra` |

## One fix outside the kernel

NVIDIA's power-mode tool reads a different set of paths on kernels newer
than 4.9, and in its Nano settings file one of those lines names a GPU path
that exists only on Xavier. The Nano's driver packages built by
[build-nano-l4t-debs.py](../../scripts/host/build-nano-l4t-debs.py) correct
that one line; with it the 5 W and MAXN modes set the same limits as under
4.9 (trial 29).

## Build it

On an x86-64 Ubuntu PC, as an ordinary user:

```bash
sudo apt install gcc-13-aarch64-linux-gnu binutils-aarch64-linux-gnu gcc-13 \
  make bc bison flex libssl-dev kmod git python3
bash scripts/host/build-jp5-kernel.sh                  # into artifacts/jp5, about 14 GB
bash scripts/host/pack-jp5-kernel.sh artifacts/jp5/out DEST_DIR
```

[build-jp5-kernel.sh](../../scripts/host/build-jp5-kernel.sh) fetches the
two source trees at pinned commits (the kernel above, and NVIDIA's R32.7.6
device tree sources from [OE4T's 4.9 mirror](https://github.com/OE4T/linux-tegra-4.9)
at `6944a5ce`), applies the 27 patches, builds the Image, modules and device
trees, and writes a `build-info.txt` with every input's hash. It took about
11 minutes on 20 cores and 30 on 4. The kernel's version banner is set to a
fixed name and UTC, so it does not record who built it.
[pack-jp5-kernel.sh](../../scripts/host/pack-jp5-kernel.sh) packs the result
into the one file the converter downloads, the same bytes however often it
is packed.

## What is not here

- These patches are against NVIDIA's downstream kernel, not mainline Linux,
  and have not been sent anywhere. 0019 brings R35's IOMMU driver in line
  with what mainline already does.
- The DisplayPort output, CSI cameras and audio are still switched off in
  the device tree, and the 40-pin header is untested. The main
  [README](../../README.md) keeps the current list.
- They were tested on one board: a Jetson Nano 4GB developer kit with the
  B01 carrier.

Everything in this folder is GPL-2.0-only, like the kernel it changes
([LICENSE](../LICENSE)).

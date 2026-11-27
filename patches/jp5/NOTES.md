# Lab notes: the kernel port, trial by trial

These are the notes kept while the port was made, in the order things
happened; [README.md](README.md) is the overview. They are kept as written
(apart from the cards' names, made plain on 2026-11-26), so they use the
project's working names:

- **The first, second and reference cards**: the three microSD cards used.
  The first held JetPack 4.6.6, the second failed in trial 3, and the
  reference card is the one the port was finished on.
- **Trial N**: the Nth numbered boot of a 5.10 build on the Nano, each next
  to a control boot of NVIDIA's 4.9 kernel on the same card. **Build #N** is
  the kernel's own build counter.
- **R32, R35**: NVIDIA's L4T releases, R32.7.6 (JetPack 4, Linux 4.9) and
  R35.6 (JetPack 5, Linux 5.10).
- **The prepare, check and collect scripts**: the harness that installed a
  trial kernel on a JetPack 4 card, booted it once and gathered its logs.
  It was removed from the repository once the Nano ran Ubuntu 26.04 on 5.10
  alone; [arm-u26-kernel.sh](../../scripts/jetson/arm-u26-kernel.sh) does
  the one-boot trial there.

## JetPack 5 (L4T R35.6) kernel for the Jetson Nano

Owner request, 2026-10-12: try JetPack 5 (or 6) on the second card. NVIDIA builds
JetPack 5 only for Xavier and Orin, so this runs JetPack 5's 5.10 kernel and
GPU driver on the Nano's existing boot firmware, with the second card's unchanged
JetPack 4.6.6 (L4T R32.7.6, Ubuntu 18.04) userspace and CUDA 10.2. Nothing
here touches QSPI, the bootloader or any partition other than APP.

**Status: in trial 11 (the reference card, 2026-10-13, recorded live on the PC) CUDA
10.2 passed every test in this repository under 5.10 on the Nano: the GPU
probe (64 KiB to 16 MiB) and vector_add at 76.8, 537.6 and 921.6 MHz, then
deviceQuery and the full vector_add baseline (`CUDA_BASELINE_EXIT=0`), with no
GPU error. The fix was the GPU regulator's PWM clock (device tree, below).
Memory then stayed at 204 MHz (vector_add's large case ran about 9 times
slower than under 4.9). Patches 0009–0011 add memory clock scaling from the
bootloader's trained EMC tables: in trial 14 (the reference card, 2026-10-13) the memory
clock switched to 1600 MHz under 5.10, and the CUDA baseline verified 53
batches in 10 s (53 in the same trial's 4.9 control boot, 6 at 204 MHz), with vdd-core at 850–900 mV.
Patch 0012 and `tegra124-cpufreq` add CPU frequency scaling with R32's
memory floor from the CPU clock: in trial 15 the CPU ran up to 1479 MHz on the
DFLL under 5.10, as fast as under 4.9. Trial 16 showed 5.10's remaining
CPU difference: its CPU minimum is 204 MHz where 4.9's is 1.2 GHz, so memory
drops to 204 MHz while the CPU waits on the GPU, and vector_add at the lower
GPU clocks ran slower than under 4.9; with a 1.2 GHz minimum it matched.
Patch 0013 sets that minimum: in trial 17 memory stayed at 1600 MHz and
vector_add matched 4.9 at every GPU clock. JetPack 4's display driver
(patch 0014 and the device tree) stopped trial 18's 5.10 boot before init.
Trial 19 held the driver's probe until late in the boot (diagnostic patch
0015), and trials 19 and 20 found the probe's next failures. In trial 21
(the reference card, 2026-10-14; 0016 and more fixes in 0014) the late probe finished and
the driver drove HDMI at 1920x1080 under 5.10, with the same mode, clocks and
supplies as 4.9; its framebuffer showed on screen. In trial 22 the probe ran
at boot as under 4.9, and JetPack 4's desktop started under 5.10 but showed
nothing: X read its modes from simplefb's fb0, and the head, without an IOMMU
here, refused X's scattered buffers. In trial 23 (the head behind upstream
tegra-smmu, tegradc's framebuffer as fb0 with patch 0018) JetPack 4's desktop
showed on HDMI under 5.10 at 1920x1080, but the display faulted on the boot
logo, the console and the cursor, because R35's tegra-smmu does not flush the
page entries it maps. Patch 0019 flushes each one: in trial 24 the 5.10 boot
had no display fault, the logo, console, desktop and cursor looked as under
4.9, and CUDA passed again. Board support is not complete: the restart at the
end of the trial instead of a power-off, the SOR power domain's shared resets
and the one-shot trial entry are open. For trial 25 diagnostic patches 0006
and 0015 moved to [diagnostic/](diagnostic/) and are no longer applied, and
the trial service no longer turns its own power-off into a restart: trial 25
passed every step under 5.10 and powered off.
Trial 26, a first step towards an everyday 5.10 boot, drops the trial entry's
`clk_ignore_unused pd_ignore_unused cpuidle.off=1` and adds patch 0020 for
`nvpmodel`. Its 5.10 boot stopped at 22 s, twice at the same line: with C7 in
use, each CPU needs the Tegra timer, which R32's device tree node left
unregistered under 5.10. Trial 27 lists that node's interrupts as upstream
does: 5.10 then used C7 on the Tegra timers, passed every step without the
three arguments, and powered off. nvpmodel's kernel side works, but its
service still fails under 5.10. In trial 28 NVIDIA's own fan driver gave
5.10 the same fan device as 4.9, and the service's own messages showed the
cause: one GPU path in its config that only kernels newer than 4.9 read
(corrected on the card from trial 29, below). With that line corrected,
trial 29's service succeeded under 5.10, and 5W and MAXN set the same limits
as under 4.9. The reference card now starts 5.10 by default with
JetPack 4's desktop. Trial 30 fixed three of that boot's gaps: the
high-speed UARTs and the cache sizes haveged needs (device tree), and USB 3
on the onboard hub (patch 0021). Under 5.10 the hub's USB 3 half,
`ttyTHS1` and `ttyTHS2` came up as under 4.9. Trial 31's device tree
turned on USB device mode, and JetPack 4's device-mode service then bound
its gadget under 5.10. In trial 32 VIC probed behind the SMMU under 5.10, but
its clock never turned on: R35 stubs out the video buses' clock prepare as it
did the GPU's. With trial 33's patch 0022 VIC ran at 4.9's clocks and the
camera daemon started; NVIDIA's video converter then stopped on an nvmap
request R35 dropped. Trial 34 restored it (0023), and the converter stopped
one request later, naming a fence. Trial 35 accepted the name (0024), and
its trace showed the converter then waiting on and reading its fence
through Android's older sync requests, which 5.10 lacks. With trial 36's
0026 serving them, the converter ran under 5.10: 120 VIC conversions with
no failed request. Trial 37 (0027, 0028 and the SOR partition's resets in
the device tree) fixed the display's two power-down errors under 5.10, the
PMC's `failed to acquire resets` on the SOR domain and a host1x read timeout
after the head powers down: on the Nano the SOR and head 0 partitions
powered off with a blank and on with the unblank, and HDMI came back.
Trial 38 gave the PMIC's interrupt its trigger type in the device tree, and
5.10 then booted with no kernel warning. On the reference card's 26.04-only boot VIC's
firmware halted every job: R35 dropped the FCE setup Tegra210's VIC firmware
needs, and the trials had passed on what their 4.9 control boot left in VIC
(inferred). Sent by hand, the setup let the converter pass (2026-10-17); 0029
restores it in the kernel, and with build #35 VIC finished the converter's
jobs on the Nano with no help (2026-10-17).**

## Sources

| Input | Upstream | Revision |
| --- | --- | --- |
| Kernel, nvgpu, nvmap, host1x | [OE4T linux-tegra-5.10](https://github.com/OE4T/linux-tegra-5.10), branch `oe4t-patches-l4t-35.6.0` (NVIDIA L4T R35.6.0, Linux 5.10.216, nvidia/nvgpu/nvlink overlays merged under `nvidia/`) | `4bce4d148ef3ff159ab55c127d8761aeaac5cc28` |
| Nano board device tree | [OE4T linux-tegra-4.9](https://github.com/OE4T/linux-tegra-4.9), branch `oe4t-patches-l4t-r32.7.6` (NVIDIA R32.7.6 `nvidia/platform/t210/porg`) | `6944a5ce1dae5947ff24ada6b6592d9e3062d38c` |
| Kernel config | R35 `tegra_defconfig` plus [kernel-config.fragment](kernel-config.fragment) | release `5.10.216-tegra` |

[scripts/host/build-jp5-kernel.sh](../../scripts/host/build-jp5-kernel.sh)
fetches both at these commits, applies everything below except the two
patches in `diagnostic/` (it applies only `patches/jp5/0*.patch`) and builds
with Ubuntu's `aarch64-linux-gnu-gcc-13` and `KCFLAGS=-Wno-error` (R35 warns
under GCC 13).

## Kernel patches

**0001-nvgpu-accept-cuda-10.2-address-space-requests.patch**
(`nvidia/nvgpu/drivers/gpu/nvgpu/os/linux/ioctl_ctrl.c`, `ioctl_as.c`).
The census on the first card (`tests/cuda/ioctl_census.c`)
found 3 of CUDA 10.2's 35 driver requests changed size in R35, and R35 matches
request numbers exactly:
- `NVGPU_GPU_IOCTL_ALLOC_AS` (R32: 16 bytes, `0xc0104708`). Handled by
  `gk20a_ctrl_alloc_as_r32()`, which fills the R35-only VA range the way R32's
  driver chose it: start at `big_page_size << 10`, end at the channel
  `user_size`, split at the small-page limit when big pages are on.
- `NVGPU_AS_IOCTL_ALLOC_SPACE` (R32: 24 bytes, `0xc0184106`) and `FREE_SPACE`
  (16 bytes, `0xc0104103`): translated field by field into the R35 structs
  (32-bit page counts, older field order) and back.

**0002-nvgpu-gm20b-small-pages-without-iommu.patch**
(`platform_gk20a_tegra.c`). The trial device tree disables the downstream
SMMU (5.10 has no driver for it), so the GPU uses direct DMA. Big pages need
contiguous IOVA, so the gm20b platform now turns them off when the GPU has no
IOMMU domain, as R35's gv11b platform does.

**0003-nvmap-tegra210-and-fd-handles.patch**
(`nvidia/drivers/video/tegra/nvmap/`). R35's loadable nvmap refuses to load
unless the SoC is Tegra186 or newer; it now accepts `nvidia,tegra210`. It also
builds with `NVMAP_CONFIG_HANDLE_AS_FD=y`: R32's nvmap, which CUDA 10.2's
libraries were built against, returns handles as file descriptors, while R35
defaults to plain IDs.

**0004-fuse-expose-tegra-chip-id-for-r32-userspace.patch**
(`drivers/soc/tegra/fuse/fuse-tegra.c`). R32's userspace tools (nvpmodel,
jetson_clocks, tegrastats, possibly the CUDA driver) read
`/sys/module/tegra_fuse/parameters/tegra_chip_id`. R35 provides it only in
its legacy downstream fuse driver, which conflicts with the upstream one, so
the upstream driver now exposes the same read-only value (33 on the Nano).

**0005-phy-tegra210-ss-prod-name-overflow.patch**
(`drivers/phy/tegra/xusb-tegra210.c`). Found by trial 2 on the Nano: the
PCIe (and SATA) PHY power-on formats `"prod_c_ss%d"` with the lane's USB3 port
into an 11-byte stack buffer. For a lane mapped to no USB3 port, such as the
Nano's PCIe Ethernet lane, the port is -EINVAL, `"prod_c_ss-22"` needs 13
bytes, and the stack protector panics ("Kernel stack is corrupted in:
tegra210_pcie_phy_power_on"). Only USB3-mapped lanes now look up prod settings,
with a 16-byte buffer and `snprintf`. R35 only ships for Tegra186 and newer,
where this Tegra210 code never runs.

**0006-diag-trace-gpu-power-on.patch** (diagnostic, for trials 7 and 8;
`nvgpu_init.c`, `module.c`, `platform_gk20a_tegra.c`, `hal/clk/clk_gm20b.c`
and `nvidia/drivers/soc/tegra/tegra-dvfs.c` at the same R35.6 revision).
Trial 6's 5.10 boot stopped completing SD card I/O right when nvgpu first
powered the GPU past the fuse check, and the stall also stopped the trial's log
snapshots. This prints, at info level (which `ignore_loglevel` sends to HDMI),
who started the power-on, each power-on init step before it runs, rail-gate
and un-rail-gate, the end of power-on, and the first 200 DVFS rail voltage
requests plus each GPU rail power-up and power-down. For trial 8 it also prints
the result of each gm20b clock step: hardware setup, clock prepare and PLL. It
changes no behaviour and is dropped once the GPU powers on. Validation: the
changed objects compile without warnings here, and 0001–0008 apply in order
to the pinned revision. Trial 7 ran it: the last step logged was
`init_clk_support`, started by nvpmodel. Trials 7 to
24 applied it. For trial 25 it moved to `diagnostic/` and is no longer
applied; the other patches apply without it.

**0007-nvgpu-gm20b-gpcclk-without-runtime-pm.patch**
(`os/linux/platform_gk20a_tegra.c`). Found from trial 7's trace. The GPU's
first power-on runs inside its runtime resume, and its clock step
(`gm20b_init_clk_support`) prepares the GPU clock, whose parents are `gbus` and
nvgpu's own `gpcclk`. nvgpu registers `gpcclk` with the GPU device, and since
Linux 4.15 the clock framework runtime-resumes a clock's device before
preparing it. The GPU is still resuming, so that call waits for itself, while
holding the clock framework's global prepare lock, and every other driver that
touches a clock then blocks too, the SD card host among them. `gpcclk` is now
registered without a device. R32.7.6 registers it with the device, but its 4.9
clock framework has no runtime PM, so this matches how R32 behaves.
Validation: compiles without warnings, and `clk_register` now receives NULL
(disassembly). On the Nano in trial 8, the clock step returned 0 and the
power-on completed.

**0008-clk-tegra-gbus-prepare-sets-gpu-dvfs.patch**
(`nvidia/drivers/clk/tegra/clk-cbus-shared.c`). R35 returns `-ENOTSUPP` from
the `gbus` prepare on kernels from 4.15 ("FIXME Drop this check once dvfs
feature is added to K59"), so once 0007 removes the hang the same clock prepare
would fail and the power-on would stop with an error. It now does what
R32.7.6's copy of this file does: set the GPU rail's voltage for the current
`gbus` rate with `tegra_dvfs_set_rate`, which R35's built-in Tegra210 DVFS
(`CONFIG_TEGRA_DVFS=y`) provides. R35's other shared-bus stubs (the `cbus`
prepare and DVFS rate rounding) are left as they are, since this trial only
needs the GPU's bus (0022 restores them for VIC). Validation: compiles without warnings and the object now calls
`tegra_dvfs_set_rate`; not yet run on the Nano.

**0009-memory-tegra210-emc-tables-from-r32-dt.patch**
(`drivers/memory/tegra/tegra210-emc-core.c`, upstream Linux 5.10's Tegra210
EMC driver as carried in R35.6). For trial 12: under 5.10 the memory clock
stayed at its 204 MHz boot rate because the R35 config leaves this driver out,
and the driver only takes its timing tables from reserved memory written by a
bootloader, which the Nano's R32 bootloader does not do. R32 keeps the tables as
`nvidia,tegra21-emc-table` nodes under the EMC node (one set per RAM code,
nominal and derated, 204 and 1600 MHz on the Nano), and its 4.9 driver reads
them with `tegra210-dt-parse.c`. When there is no `nominal` reserved region,
the probe now reads those nodes: the set whose `nvidia,ram-code` matches the
strapping (`tegra_read_ram_code()`), every property R32's parser reads, into
`struct tegra210_emc_timing`, whose layout is R32's `struct emc_table` and whose
register lists are in R32's order (compared name by name). Unlike R32 it
refuses a table with a missing property or a register count larger than its
array. As R32 does for LPDDR4, it copies the trained trimmers and clock-tree
values from each nominal timing to its derated one. It logs the node, RAM code,
and each rate's training state. The upstream checks then apply unchanged: rates
in order, a known sequence (revision 7, `r21021`), a timing for the boot rate,
and no switch above 204 MHz unless the table says `trained`. The training
results come from the bootloader at each boot; see the device tree section for
how they reach the 5.10 device tree. Validation: compiles without warnings
(`W=1`); the parser ran in a userspace harness with stub OF functions on the
trial DTB's EMC node, and an independent script (offsets from R32's struct,
property names from R32's parser) matched every parsed field and array for
both RAM codes, with and without the LPDDR4 copy, including a DTB edited to
look trained. A missing property, an oversized count, a short array and a
nominal/derated count mismatch each fail the probe. On the Nano in trial 12
the reserved-memory lookup returned -EINVAL instead of -ENODEV, and the probe
gave up: 5.10's lookup returns -EINVAL only when the node has
`memory-region-names` with "nominal" and its `memory-region` reaches a node
that is not a registered table, and the trial DTB has neither property, so
they come from the bootloader's EMC node with U-Boot's copy (which leaves
out `/reserved-memory`): trial 13 found `memory-region = <0x131 0x132>` with
names "nominal derated" in the 5.10 tree, phandles that reach two camera nodes
there. From trial 13 the probe logs any lookup error other than -ENODEV as a
warning and reads the table nodes; compiles without warnings (`W=1`), and
0001–0010 applied in order reproduce the edited file. Trial 13 on the Nano:
`EMC tables from /external-memory-controller@7001b000/emc-table@0 (RAM code
0): 2 nominal, 2 derated`, 1600 MHz trained.

**0010-bwmgr-follow-emc-clock-range.patch**
(`nvidia/drivers/platform/tegra/mc/emc_bwmgr.c`). R35's bandwidth manager
drives the EMC clock on Tegra210 from its clients' requests (nvgpu, SD card,
USB, PCIe), as R32's does. `bwmgr_init()` reads the clock's range once, at
device initcall time, but `drivers/platform` links before `drivers/memory`,
so the EMC driver has not attached its table yet and the range is 204 MHz
alone; every later update would then cap the EMC clock there. The manager now
re-reads the range under its lock before handling a request (and before its
debugfs and cooling-device updates), widens it once the clock offers more, and
lifts client caps that were left at the old maximum. Validation: compiles
without warnings. Trial 13 on the Nano: `bwmgr: emc rate range now
204000000-1600000000 Hz` 3.8 s after the EMC driver probed, and its requests
then rounded to 1600 MHz.

**0011-soc-tegra210-dvfs-emc-rates-from-r32-tables.patch**
(`nvidia/drivers/soc/tegra/tegra210-dvfs.c`). The core-rail voltage table
gives each clock its highest rate per core voltage. R35's entry for `emc` is a
placeholder (1 kHz up to 975 mV, 1200 MHz from 1000 mV), which R32 replaced at
boot from its EMC tables with `tegra210_predict_emc_rate()`; R35 skips that
step on 5.x ("EMC part is not enabled yet"). In trial 13 every switch to 1600
MHz then failed with `tegra-dvfs: rate 1600000000 too high for dvfs on emc`.
The placeholder is also the likely reason vdd-core sits at 1000 mV under 5.10
(900 mV under 4.9): it asks 1000 mV for any EMC rate, 204 MHz included. On 5.x the step now reads the board's EMC table nodes (the RAM
code's set, nominal tables only) and gives each core voltage the highest rate
whose `nvidia,emc-min-mv` it meets, in table order, as R32's prediction does
with the same tables; it does not need the EMC driver to have probed. On the
Nano's tables: 204 MHz from 800 mV and 1600 MHz from 900 mV (887 mV minimum),
matching 4.9's 1600 MHz at 900 mV. It logs each step. Validation: compiles
without warnings and the Image links; the function, compiled in userspace with
stub device tree functions on the trial DTB's EMC node, gave that ladder for
RAM codes 0 and 2, left the table unchanged for an unknown RAM code, and
balanced its node references. Trial 14 on the Nano: it logged that ladder,
no switch was refused, EMC ran at 1600 MHz with vdd-core at 900 mV (850 mV at
204 MHz), and the CUDA baseline verified 53 batches in 10 s (4.9: 53).

**0012-cpufreq-tegra124-emc-floor-from-r32-table.patch**
(`drivers/cpufreq/tegra124-cpufreq.c`). From trial 15 the config builds
upstream's `tegra124-cpufreq`, which handles Tegra210 too: it moves the CPU
from PLL_X onto the DFLL and starts cpufreq-dt on the DFLL's voltage table
(R35's `clk-tegra124-dfll-fcpu`, with Tegra210's tables and the device tree's
1479 MHz cap). R35's own `tegra210-cpufreq.c` is R32's 4.9 driver, built
only with `ARCH_TEGRA_21x_SOC` and still on APIs that 5.x removed. R32's
driver also set a memory clock floor from the CPU clock, which keeps EMC at
1600 MHz under 4.9 (the bandwidth manager's `cpu_cluster_0` client) and which
upstream's lacks. The patch adds it: a cpufreq transition notifier asks the
bandwidth manager, as `cpu_cluster_0`, for the EMC rate that the device
tree's `emc-cpu-limit-table` (R32's `/cpufreq/emc-scaling-data`, pairs of CPU
and EMC kHz) gives the new CPU rate, with R32's lookup: raised before the CPU
speeds up, lowered after it slows down. The bandwidth manager starts with the
other device initcalls, so the client registers at `late_initcall_sync` and
applies the floor for the last CPU rate seen; it logs `EMC floor follows the
CPU clock`. On the Nano's table, CPU rates from 1036.8 MHz ask 1600 MHz and
918 MHz asks 665.6 MHz (rounded up to 1600 MHz, the next EMC rate), as on 4.9.
Validation: compiles without warnings (`W=1`); the lookup, compiled in
userspace on the trial DTB's table, gave R32's floors for 15 CPU rates and
did nothing before the client registered. Trial 15 on the Nano: the CPU moved
onto the DFLL, cpufreq-dt offered 204–1479 MHz, the floor registered (`EMC
floor follows the CPU clock (6 steps)`) and held EMC at 1600 MHz with the CPU
at 1479 MHz (with the CPU pinned at 204 MHz it asked 68 MHz and EMC fell to
204 MHz), and `cpu_spin` matched 4.9 at the same clocks (245.8 against 245.7
M/s on one core).

**0013-cpufreq-tegra124-r32-cpu-minimum.patch**
(`drivers/cpufreq/tegra124-cpufreq.c`). 4.9 keeps the Nano's CPU at 1.2 GHz
or more: its policy minimum reads 1200000 kHz, and in trial 16 writing a
lower `scaling_min_freq` read back 1200000 (a lower maximum still wins). With
0012's floor this also holds EMC at 1600 MHz. Where 4.9 sets it is not traced
(no userspace configuration and no listed PM QoS request). Under 5.10 the
minimum was 204 MHz, EMC fell to 204 MHz while the CPU waited on the GPU, and
vector_add at the 76.8 and 537.6 MHz GPU pins ran slower than under 4.9;
with the minimum written to 1224 MHz it matched 4.9 (trial 16). The patch adds
a cpufreq frequency QoS minimum of 1200000 kHz to the CPU policy at
`late_initcall_sync` on boards with R32's `nvidia,tegra210-cpufreq` node, and
logs `CPU minimum 1200000 kHz, as R32`. cpufreq's limit check still lowers the
minimum to a lower maximum, so pinning the CPU low works as on 4.9.
Validation: compiles without warnings (`W=1`), and 0001–0013 applied in order
reproduce the edited tree. Trial 17 on the Nano: 5.10 logged `CPU minimum
1200000 kHz, as R32`, a written 204000 read back 1200000 as on 4.9, pins below
the minimum still took effect (204 and 816 MHz), every EMC sample during
vector_add read 1600 MHz, and vector_add verified 4, 14 and 17 batches at the
three GPU pins (4.9: 4, 15 and 16). vdd-core stopped switching while the CPU
idled (8 changes in the boot, against 196 in trial 15).

**0014-tegradc-tegra210-probe-on-5.10.patch**
(`nvidia/drivers/video/tegra/dc/dc.c`). R35's 5.10 tree still builds
JetPack 4's display driver, tegradc, with its Tegra210 code
(`CONFIG_TEGRA_DC`, `TEGRA_HDMI2_0`, `TEGRA_ISOMGR`, all on in R35's
defconfig), including 5.4-and-later branches that attach the head's power
domains by name. Trials 1 to 17 left it unused because the device tree
disabled the display nodes. Read against 5.10 (clock ids and parents match
4.9's; see the device tree below for the power domains), four things in the
probe would break on this board, and the patch fixes them, plus a fifth found
on the Nano:
- The bandwidth manager and the isochronous bandwidth manager start at
  `device_initcall` and `device_initcall_sync` on 5.10, after tegradc
  registers (4.9 started them at `subsys_initcall_sync` and `fs_initcall`).
  Registering before then returns -EAGAIN, which the probe turned into a
  lasting -ENOENT. On Tegra210 the probe now defers until the isochronous
  manager is up (which follows the bandwidth manager) and until HDMI's DDC
  I2C adapter exists, before it touches anything.
- Any probe error then dereferenced NULL: the error path counts the failed
  head in `dc_common`, which only exists on Tegra186 and later. The success
  path already limits that to NvDisplay; the error path now does too.
- On Tegra210 `tegra_disp_clk_get()` uses `devm_clk_get()` but
  `tegra_disp_clk_put()` used `clk_put()`, so an error path or removal put the
  clock twice (the second time from devres, after it was freed). It now uses
  `devm_clk_put()`.
- The "disa" power-domain attach was undone only on removal, so a probe that
  failed after it could never attach again (same virtual device name); the
  error path now detaches it.
- That attach passes `dc->ndev->dev`, but the probe set `dc->ndev` only
  further down, so it dereferenced NULL (trial 19). The probe now sets
  `dc->ndev` before the attach.
- After an isomgr failure the error path kept the dc's IRQ (registered with
  the freed dc) and passed the error handle to `tegra_isomgr_unregister()`;
  and no error path tore down the output, whose IRQ and debugfs files point
  into the dc's devres memory (trial 20: reading `tegra_hdmi/hdmi_status`
  after the failure oopsed). The error path now frees the IRQ, skips an error
  handle and, on Tegra210, destroys the output before the memory is freed.
Not changed: the dc ext interface that JetPack 4's Xorg driver uses is the
same as R32.7.6's in every ioctl and structure size (compared with
R32.7.6's header); its buffer ids are 0017's. Validation: compiles without warnings (the
file's `W=1` diagnostics are all in unchanged code), 0001–0014 applied in
order reproduce the edited tree, 0014 applies without 0015, and the full
Image links. Trial 18 on the Nano: with the head on, 5.10 stopped before init
and logged nothing (the probe runs before the root mount, which waits for it).
Trial 19 ran it late (0015) and it oopsed at the attach above (`NULL + 0x228`
in `dev_pm_domain_attach_by_name()` from `t21x_disp_attach_pd()`), after
parsing the device tree and mapping its registers. Trial 20 (with that fixed)
passed the power domains, set up the HDMI output and failed at isomgr (0016);
reading the output's leftover debugfs file then oopsed. Trial 21, with both
fixed, finished the probe in 304 ms and drove HDMI at 1920x1080 (the owner saw
the white fill); two problems remain from its log: the SOR power domain's
resets, which tegradc holds, so the PMC fails to acquire them at each switch
(-EBUSY; the bootloader leaves the domain on, so nothing breaks yet), and one
read of `DC_CMD_INT_STATUS` while the head was blanked (a host1x read
timeout). Trial 22 lets it probe at boot.

**0015-diag-tegradc-hold-tegra210-probe.patch** (diagnostic, from trial 19;
`nvidia/drivers/video/tegra/dc/dc.c`). Adds a `dc.t21x_hold` parameter. While
it is set, the Tegra210 probe defers, so the trial's 5.10 entry
(`dc.t21x_hold=1`) boots without the display driver. The check script later
clears it in `/sys/module/dc/parameters/` and asks for the probe through
`/sys/bus/platform/drivers_probe`. By then the primary entry is back and a
panic restarts into 4.9, whose pstore keeps 5.10's log. A `probe step:` line
marks each stage of the probe: start, power domains, output, ext, IRQ,
framebuffer, hotplug, head enable and the end. Validation: compiles without
warnings, 0001–0015 applied in order reproduce the edited tree, the full Image
links, and `dc.t21x_hold` is in its parameter table. Trial 19 on the Nano: the
5.10 entry booted with the probe held (`hold=Y driver=none deferred=1` at the
display probe step), and clearing it ran the probe from the check script,
whose oops then restarted the Nano into 4.9 with 5.10's log in pstore. Trial
21's late probe drove HDMI, so from trial 22 the 5.10 entry no longer sets the
hold and the probe runs at boot; the `probe step:` lines stay until it has
worked there. To be dropped then. Trials 22 to 24 probed at boot, so for trial
25 it moved to `diagnostic/` and is no longer applied; the other patches
apply without it.

**0016-isomgr-follow-emc-clock-range.patch**
(`nvidia/drivers/platform/tegra/mc/isomgr-pre_t19x.c`, `emc_bwmgr.c` and its
header). The isochronous bandwidth manager sizes its pool once, at
`device_initcall_sync`, from bwmgr's maximum EMC rate. On 5.10 bwmgr still
holds the boot rate as its maximum then and widens it only on its next update
(0010), so in trial 20 isomgr read 204 MHz (`max_iso_bw=1468800KB` at 21.4 s;
the range widened at 23.7 s) and refused the HDMI head's 2,400,960 KB, where
4.9 had 11,520,000 KB at 1600 MHz. bwmgr now exports
`tegra_bwmgr_update_emc_range()` (0010's widening, under its lock); isomgr
calls it before sizing the pool, and before each register and reserve grows
the pool and the available bandwidth by the difference when the range has
grown. Lock order is isomgr then bwmgr, as isomgr's existing calls into bwmgr
already take them. Validation: compiles without warnings, 0001–0016 applied in
order reproduce the edited tree, and the full Image links. Trial 21 on the
Nano: isomgr's init widened bwmgr's range first (`emc rate range now
204000000-1600000000 Hz` at 21.43 s), then read `iso emc max clk=1600000KHz`
and `max_iso_bw=11520000KB`, as 4.9 does, and the HDMI head reserved its
2,400,960 KB.

**0017-tegradc-ext-r32-buffer-ids.patch**
(`nvidia/drivers/video/tegra/dc/ext/util.c` and `dev.c`). JetPack 4's Xorg
driver shows its screens through tegradc's ext interface, whose buffer ids are
dma-buf file descriptors. R32.7.6's interface (its `dc/ext` sources at the
device tree's revision above) makes them unsigned with 0 for "no buffer": its
`tegra_dc_ext_pin_window()` returns early on 0, and its flip code treats a
zero id as no buffer. R35's makes them signed with a negative id for none, so
it would look up file descriptor 0 for every unused plane (U and V of an RGB
surface, for one) and fail the flip. The ext driver now takes 0 as none too, at the
five places that test an id and in the pin itself, as R32 did; a negative id
still means none. A buffer it cannot pin now says why, rate-limited (not a
dma-buf, cannot attach, cannot map, or not contiguous with its entry count
and size), where every failure used to return only -ENOMEM. Not changed:
without an IOMMU on the display (this device tree has none), the pin accepts
only physically contiguous buffers, as R32's did without one; on 4.9 the
display sat behind the SMMU. Validation: compiles without warnings, 0001–0017
applied in order reproduce the edited tree, and the full Image links with the
new messages. Trial 22 on the Nano: X's flips reached the pin with no "not a
dma-buf", attach or map failures, and every buffer was refused only as not
contiguous (2 MiB in 8 to 11 pieces), which trial 23's device tree addresses.

**0018-tegra-fb-take-over-firmware-framebuffer.patch**
(`nvidia/drivers/video/tegra/fb.c`). JetPack 4's Xorg driver opens
`/dev/fb0` by name, and its `libnvdc.so` pairs `/dev/fb%d` with
`/dev/tegra_dc_%d` (strings of both on the Nano). This device tree keeps the
boot console on simplefb, which registers first, so tegra_fb was fb1 and X
read simplefb's single 0 Hz mode and chose 800x600 (trial 22). tegra_fb now
gives its framebuffer an aperture over the whole address space before it
registers; 5.10's framebuffer core then unregisters every firmware
framebuffer that overlaps it (simplefb, `fb0: switching to tegra_fb from
simple`), and tegra_fb takes the first free number, fb0, and the console, as
under 4.9. On newer display hardware R35's driver already refuses a
framebuffer whose number differs from its head's (`ndev->id != info->node`).
The aperture is freed with the framebuffer (`framebuffer_release`).
Validation: compiles without warnings, 0001–0018 applied in order reproduce
the edited tree, and the full Image links. Trial 23 on the Nano: `fb0:
switching to tegra_fb from simple` at 24.45 s, the console moved to tegra_fb,
fb0 was `tegra_fb` with the monitor's modes, and X sized the screen at 1920 x
1080 (800 x 600 in trial 22).

**0019-iommu-tegra-smmu-flush-entries-on-map.patch**
(`drivers/iommu/tegra-smmu.c`). R35's tegra-smmu writes a page entry in
`__tegra_smmu_map()` and leaves cleaning it from the CPU cache and flushing
the SMMU's page-table cache and TLB to `iotlb_sync_map`, which misses
entries: `__iommu_map()` starts a new gather for each physically contiguous
chunk, so after `iommu_map_sg()` only the last chunk is flushed, and the sync
takes `gather->end - gather->start` as the size while `end` is the last byte,
so it drops the last page and a one-page map flushes nothing. The SMMU then
reads zeros until the CPU's cache writes the entries back, and keeps them in
its page-table cache. In trial 23 the display faulted on the bootloader's
buffer, tegra_fb's buffer and the cursor (`SMMU translation error [--S]`)
while debugfs showed their entries mapped. The map now writes each entry
through `tegra_smmu_set_pte()`, which cleans it and flushes its page-table
cache line and TLB group at once, as mainline's driver does, and
`iotlb_sync_map` is dropped; `iotlb_sync`, used on unmap, counts the last
page, so that entry is flushed and an emptied page table is released.
Validation: compiles without warnings (`W=1`), 0001–0019 applied in order
reproduce the edited tree, and the full Image links. In a userspace model
(the driver's real map, unmap and sync code and the iommu core's map and
unmap paths, with a model of the CPU cache, page-table cache and TLB), R35's
code left 2,048 of the bootloader buffer's 2,048 entries and 4,032 of
tegra_fb's 4,050 out of memory and the display faulted on them, and an
unmapped buffer kept its page table; with 0019 none were left out, nothing
faulted, and the page table was released. Trial 24 on the Nano: no
memory-controller fault in the whole 5.10 boot (tens of thousands in trial
23), the boot logo whole and a normal cursor on the desktop (owner), the same
mapping counts as trial 23, and `cpu_spin` back to 246.0 M/s.

**0020-nvpmodel-tegra210-emc-cap-through-bwmgr.patch**
(`nvidia/drivers/nvpmodel/nvpmodel_emc_cap.c`). JetPack 4's `nvpmodel`
caps the memory clock for each power mode by writing
`/sys/kernel/nvpmodel_emc_cap/emc_iso_cap`. The card's `/etc/nvpmodel.conf`
writes 0 in MAXN and 1600000000 in 5W (read from the reference card's image). R32's
driver registers a bandwidth-manager client on every chip. R35's does that
only on Tegra194 and otherwise asks the interconnect framework for an EMC
path, which Tegra210 does not provide here. Under 5.10 the driver's init
therefore failed with -517, so the sysfs file never appeared and the
`nvpmodel` service failed (trial 17). Its error path also called `icc_put()`
on the error pointer, which is the `icc_put` call trace logged in every 5.10
boot since trial 4. Tegra210 now takes the Tegra194 path. The bandwidth
manager is built in (`CONFIG_TEGRA_BWMGR=y`) and works on Tegra210 from patch
0010. Its `bwmgr_init` runs at the same initcall level as this driver and
comes first in the link order (`System.map`). An `ISO_CAP` of 0 means no cap
(the EMC's top rate), so MAXN leaves memory at 1600 MHz.
Validation: compiles without warnings (`W=1`), 0001–0020 applied in order
reproduce the edited tree, and the full Image links. Trial 27 on the Nano:
`nvpmodel: initialized successfully` at 20.4 s with no `icc_put` call trace,
`emc_iso_cap` existed (it read 0, also its initial value), and bwmgr listed its
`nvpmodel` client at 1,600 MHz. The service itself still ended `failed`.

**0021-phy-tegra210-usb3-lanes-power-on.patch**
(`drivers/phy/tegra/xusb-tegra210.c`, after 0005). Under 5.10 the onboard
hub's USB 3 half (`0bda:0411`), which 4.9 finds at 3.9 s, never appeared,
and the kernel log had no error. R35's USB 3 port `enable` is empty, and the
pad setup (SS port map, equalization, clamps, VCORE) runs in
`tegra210_usb3_phy_power_on()`. The PCIe and SATA pads' PHY power-on and
power-off call it only when the lane's function is `usb3-ss`. R35 names that
function `xusb` for Tegra210, in its lane function table and in
`tegra210_usb3_port_map()`, as R32's device trees do. So the setup never ran.
Upstream 5.10.216 uses `usb3-ss` throughout. The five checks now test for
`xusb`, the name the lanes carry. The register value for the lane's mux is
the same either way (index 1). Validation: 0005 and 0021 apply to the
pristine file, and the patched file compiles without warnings. Trial 30 on
the Nano: `usb 2-1: new SuperSpeed Gen 1 USB device` at 25.2 s, the hub's
`0bda:0411` USB 3 half, as under 4.9.

**0022-clk-tegra-cbus-dvfs-as-r32.patch**
(`nvidia/drivers/clk/tegra/clk-cbus-shared.c`, after 0008). In trial 32 VIC
never powered on under 5.10: `Cannot turn on clock vic03`, after four
"already disabled" and "already unprepared" warnings at its probe for
`vic03.cbus` and `vic.floor.cbus`. Both are users of `c2bus`, and R35's
`cbus` prepare returns `-ENOTSUPP` on kernels from 4.15, the stub 0008
removed from `gbus`. The clock core prepares the bus before its user, so
every prepare of a VIC, NVENC, NVDEC, NVJPG, TSEC-B, SE, VI or ISP clock
failed, and nvhost reports any clock failure as `-EINVAL`. The same file
skips DVFS when it rounds a bus rate, so a bus could be asked for up to its
registered maximum (1.2 GHz for `c2bus`), past the top rate of its DVFS
table, which the DVFS rate-change check refuses once the bus runs. As in R32.7.6's copy of the file, the prepare now
sets the core rail for the bus's current rate (`tegra_dvfs_set_rate`), the
unprepare drops it, the rounding goes to the DVFS table
(`tegra_dvfs_round_rate`) and `bus_user_is_slower()` reads DVFS maximum
rates. The GPU's `gbus` shares the rounding: a request now rounds up to a GPU
DVFS rate and stops at the top one, as in R32; nvgpu already builds its
frequency list from that table (`tegra_dvfs_get_freqs`). The system bus's
rounding table, also stubbed, is left as it is. Validation: 0008 and 0022
apply in order to the pristine file and reproduce the edited one, the object
compiles without warnings (`W=1`), and the three DVFS functions are built in
(build #27's System.map). Trial 33 on the Nano: VIC's clocks matched 4.9's
(`c2bus`, `vic03.cbus` and `vic03` at 192 MHz), the camera daemon stayed
active, and the four VIC clock warnings and the three `clk_cbus_round_rate`
warnings from nvpmodel were gone, with CUDA unchanged.

**0023-nvmap-r32-rw-handle-requests.patch**
(`nvidia/include/uapi/linux/nvmap.h`, `nvmap_dev.c`, `nvmap_ioctl.c`). In
trial 33 NVIDIA's video converter and camera daemon got ENOTTY from
`NVMAP_IOC_WRITE` (`Unknown NVMAP_IOC = 0x40204e06`). R32's nvmap takes three
layouts for `WRITE` and `READ`: 32 bytes with a 64-bit user address and
32-bit offset, sizes and count (0x40204e06 and 0x40204e07, which JetPack 4's
libraries use), `_64` with 64-bit fields (56 bytes) and 32-bit compat (28
bytes). R35 keeps only the last two, with `_64`'s layout under the plain
names (0x40384e06). The patch adds R32's 32-byte layout as
`struct nvmap_rw_handle_r32` (kernel-only) with the requests
`NVMAP_IOC_WRITE_R32` and `NVMAP_IOC_READ_R32`, read and answered as R32
does (the copied byte count goes back into the 32-bit `count`); a
build-time check keeps the struct at 32 bytes. Of R32's other nvmap
requests R35 also lacks `ALLOC_KIND`, `MMAP`, `PIN_MULT`, `UNPIN_MULT`,
`SHARE` and `RESERVE`; none appeared in trial 33's log, so they stay out.
Validation: the request numbers come from compiling both headers; the
patch applies to R35's files and the two objects compile without warnings.
Trial 34 on the Nano: no `Unknown NVMAP_IOC` line under 5.10, and the camera
daemon no longer logged an `NVMAP_IOC_WRITE` failure; the converter went on
to the next request (0024).
In trial 36 the working converter made 305 `WRITE` and 180 `READ` calls in
R32's layout, all answered.

**0024-nvhost-r32-fence-names.patch**
(`nvidia/drivers/video/tegra/host/host1x/host1x.c`). In trial 34 the only
kernel line during the converter's failed run was
`nvhost_ioctl_ctrl_sync_fence_set_name: operation not supported`. 5.10 has
no Android sync framework (`CONFIG_SYNC`), so R35 makes nvhost's fences
`sync_file` fences (`nvhost_sync_compat.c`), and its handler for
`NVHOST_IOCTL_CTRL_SYNC_FENCE_SET_NAME` works only with `CONFIG_SYNC`; R32's
Android fences each had a name. Without `CONFIG_SYNC` the request now
checks that the fd holds a fence made only of host1x syncpoints
(`nvhost_fence_get()`, the check R32's `nvhost_sync_fdget()` made) and
returns 0. The name is not kept: a `sync_file` fence has no name a driver
can set, and R32 used it only to label the fence in sync debug output. All
36 of R32's nvhost request numbers are unchanged in R35 (both headers
compiled). Validation: the patch applies to R35's file, `host1x.o` compiles
without warnings and references `nvhost_fence_get`. Trial 35 on the Nano:
no `sync_fence_set_name` failure, and the converter's set-name request
succeeded.

**0025-diag-sync-file-unknown-requests.patch** (diagnostic, from trial 35;
`drivers/dma-buf/sync_file.c`). JetPack 4's userspace was built for
Android's older sync requests on fence fds (`SYNC_IOC_WAIT` 0x40043e00,
`MERGE` 0xc0283e01, `FENCE_INFO` 0xc0283e02); 5.10's `sync_file` has only
`MERGE` 0xc0303e03 and `FILE_INFO` 0xc0383e04 and refuses others with
ENOTTY, silently. The patch logs each refused request, rate limited, as
`sync_file: unknown ioctl 0x… from <task>`. Validation: applies to the
file, which compiles without warnings. Trial 35 on the Nano: it logged
`0xc0283e02` (`FENCE_INFO`) from the converter's source thread and
`0x40043e00` (`WAIT`) from its main thread, the two calls the trace showed
failing. 0026's second hunk has 0025's lines as context, so moving 0025 to
`diagnostic/` needs 0026 regenerated.

**0026-sync-file-r32-android-sync-requests.patch** (from trial 36;
`drivers/dma-buf/sync_file.c`, `include/linux/sync_file.h`, nvhost's
`nvhost_sync_v2.c` and `.h`, `host1x/host1x.c`; after 0024 and 0025). R32's
4.9 kernel served Android's older sync interface on fence fds
(`drivers/staging/android/sync.c`): `SYNC_IOC_WAIT` (0x40043e00),
`SYNC_IOC_MERGE` (0xc0283e01) and `SYNC_IOC_FENCE_INFO` (0xc0283e02). In
fence info R32's nvhost described each point as timeline driver
`nvhost_sync` with `{syncpoint id, threshold}` as driver data. 5.10's
`sync_file` has only the newer `MERGE` and `FILE_INFO`, so in trial 35 the
converter's fence info and wait calls got ENOTTY. The patch serves the
three older requests with R32's layouts and behaviour (milliseconds for the
wait, a negative value without limit; up to 4,096 bytes of fence info,
ENOMEM when a point does not fit), next to the newer ones. A fence driver
can register a function (`sync_file_set_r32_pt_fn()`) that adds its driver
data and R32 driver name to each point; nvhost registers one at probe that
writes R32's `{id, thresh}` and `nvhost_sync` for its syncpoint fences.
Validation: the three patches apply in order and reproduce the edited
files, which compile without warnings (`sync_file.c` also with `W=1`);
build-time checks pin R32's structs at 40, 80 and 40 bytes. In user-mode
Linux 5.10 built from the same tree, a test using software fences passed
41 of 41 checks of the three requests, with and without a stand-in driver
function, and of the newer `FILE_INFO`. nvhost's function runs only on the
Nano. Trial 36 on the Nano: `nvvidconv exit=0` under 5.10; each of its 120
conversions read its fence through `FENCE_INFO` and waited on it through
`WAIT` without error, and no `sync_file: unknown ioctl` line appeared.

**0027-tegradc-t21x-power-state-and-released-resets.patch** (from trial 37;
`nvidia/drivers/video/tegra/dc/dc_priv.h`, `sor.h`, `sor.c`, `dpaux.c`).
Two 5.10-only problems in JetPack 4's display driver, seen in every 5.10
boot since trial 21:
- `tegra_dc_is_powered()` on 5.4 and later returns `pm_runtime_enabled()`
  of the device attached to the head's power domain, which is true from
  attach on. The interrupt handler, the only reader of `DC_CMD_INT_STATUS`
  (head 0: 0x542000dc), returns early only when that is false; so when its
  thread runs after the blank has powered the head's partition off, it
  reads an unpowered head, and host1x logs `Host read timeout at address
  542000dc` (trial 36: 0.56 s after `blank - powerdown`). 4.9 asked the PMC
  whether the partition was powered. The patch asks genpd whether the
  attached domain is on (`GENPD_STATE_ON`), for the head and for the SOR's
  debugfs dump.
- tegradc gets the SOR1 and DPAUX1 resets as exclusive controls, which
  `of_reset_control_get()` acquires for good. 5.10's PMC must acquire every
  reset its `sor` domain lists before powering the domain off, so each
  power-off after tegradc's SOR init failed with -EBUSY (`tegra-pmc: failed
  to acquire resets: -16`, 11 times in trial 36's boot) and the partition
  never powered off. The patch gets both resets released and acquires each
  only around its deassert or reset pulse, as upstream's tegra-drm SOR
  driver also gets its reset released; if the PMC holds it (the partition
  is off), tegradc warns `reset held by its power domain` and skips the
  pulse, since powering the partition on deasserts it.

**0028-soc-tegra-pmc-tegra210-sor-parent-domain.patch** (from trial 37;
`drivers/soc/tegra/pmc.c`). Under 5.10 tegradc takes the `sor` domain only
around short uses (the EDID read, HDMI audio, DPAUX), never for the
running head, so a SOR domain that can power off (0027) would power off
under it. R32's 4.9 powergate driver (`powergate-t21x.c`) powers the SOR
partition on before DISA, DISB or VENC and off after the last of them. The
patch makes the `sor` domain the genpd parent of `dis`, `disb` and `venc`
on Tegra210, as R35 already does for NVJPG and NVDEC, and logs a failure to
link them (genpd refuses a powered child under an unpowered parent). The
power-up and power-down themselves are 5.10's (`tegra_powergate_power_up()`
and `_down()`; the power-up runs Tegra210's MBIST clock-gating workaround,
which for SOR sets the same second-level override bits as 4.9's).

Validation for 0027 and 0028: they apply after 0026 (no earlier patch
touches their files) and reproduce the edited files; the tegradc directory
(49 objects) and `drivers/soc/tegra` compile without warnings with the
build's flags. Trial 37 on the Nano: under 5.10 no `failed to acquire
resets` (trial 36: 11) and no `Host read timeout` (trial 36: 1) in the
whole boot, and no `held by its power domain` or `failed to add` line. The
genpd summary showed `sor` and `dis` off-0 with head 0's device suspended
2 s after a framebuffer blank, and both on with the device active after
the unblank; HDMI came back at 1920x1080. The boot's own blank and unblank
took 80 ms (trial 36: 580 ms with the timeout).

**0029-nvhost-vic-tegra210-fce-ucode-setup.patch** (from 2026-10-17;
`nvidia/drivers/video/tegra/host/flcn/flcn.c` and `flcn.h`). Tegra210's
VIC firmware (`tegra21x/vic04_ucode.bin`) carries its FCE microcode in the
image and needs the kernel to say where after each boot. R32.7.6's falcon
driver reads the image's FCE header (`flcn_setup_ucode_fce`) and
`nvhost_vic_finalize_poweron` writes `SET_FCE_UCODE_SIZE` and
`SET_FCE_UCODE_OFFSET` through THI's method registers; upstream's tegra-drm
VIC driver does the same ("Old VIC firmware needs kernel help with setting
up FCE microcode"). R35 dropped both and turned the header fields into
`reserved[4]`, so under 5.10 VIC's firmware halts each job (error 9 in its
mailbox, `SWGEN0`, which no interrupt reports here) and nvhost times it
out. The patch restores R32's header fields and FCE parsing, skipping
images that mark the FCE absent as upstream does and leaving an image with
a bad FCE header loadable without it, and writes the two methods after
`SET_APPLICATION_ID`. Validation: it applies to R35's files (no earlier
patch touches them); `flcn.o` compiles without warnings with the build's
flags and writes methods `0x1c7` and `0x1cb`; its parser, run on this host
with the Nano firmware's header values, gives the size and offset that let
the converter pass when `vic-u1804.sh --fce` sent them by hand on the Nano
(2026-10-17). On the Nano, build #35 (one boot,
2026-10-17): `vic-u1804.sh --power-cycle` without `--fce` passed (1 s, no
timeout), and JetPack 4's converter in 26.04 finished its VIC jobs at once
with no kernel message, and its pictures are right: an exact BT.601
conversion (53 dB and up) with VIC's own chroma placement, a bit-exact NV12
round trip and scaling within limits.

The config fragment adds `CONFIG_TEGRA210_EMC=y` (built in: it calls
`tegra_read_ram_code()`, which modules cannot) and, from trial 15,
`CONFIG_ARM_TEGRA124_CPUFREQ=y` (trials 5 to 14 turned it off so the CPU
stayed on PLL_X). R35's default governor is `performance`, but the card's
`nv.sh` switches Tegra210 to `schedutil` at boot under both kernels. It also turns off `CONFIG_TEGRA_FUSE_BURN`, and the device
tree disables the `efuse-burn` node: a trial kernel offers no way to burn
eFuses, which is permanent. From trial 28 it builds NVIDIA's Tegra `pwm_fan` (a module), the driver 4.9
uses for R32's fan node, instead of upstream's hwmon `pwm-fan`, which rejected
that node (`Wrong Data`, -22) and left 5.10 without a fan device. From
trial 30 it leaves `CONFIG_SECURITY_DMESG_RESTRICT` off, as JetPack 4's 4.9
kernel does, so users can read `dmesg` without the trial entry's
`sysctl.kernel.dmesg_restrict=0`. From trial 35 it adds
`CONFIG_FTRACE_SYSCALLS=y`, so the trial check can trace the video
converter's ioctl requests; merged and resolved, that is the only change.
From trial 39 (build #34) it adds `CONFIG_CGROUP_BPF=y` and `CONFIG_PSI=y`,
which systemd 259 recommends for Ubuntu 26.04;
merged and resolved from `tegra_defconfig`, they are the only options
turned on (two dependent ones appear, left off:
`CONFIG_PSI_DEFAULT_DISABLED` and `CONFIG_BPF_STREAM_PARSER`), and
`kernel/bpf`, `kernel/cgroup` and `kernel/sched` compile without warnings
with them.

## Userspace configuration

**nvpmodel config, GPU `FREQ_TABLE_KNEXT`** (from trial 29; JetPack 4.6.6's
`nvidia-l4t-tools` 32.7.6, `/etc/nvpmodel/nvpmodel_t210_jetson-nano.conf`,
SHA-256 `d53dee45…`, which `/etc/nvpmodel.conf` links to). `nvpmodel` reads
each parameter's `*_KNEXT` path instead of its plain one on any kernel newer
than 4.9 (from `/proc/version`). In this file the GPU's `FREQ_TABLE_KNEXT`
is `/sys/devices/17000000.gv11b/devfreq/devfreq0/available_frequencies`,
Xavier's GPU, so under 5.10 the service stopped with `failed to read PARAM
GPU: ARG FREQ_TABLE` (trial 28's journal). The
prepare step changes that one line to the plain `FREQ_TABLE` path,
`/sys/devices/gpu.0/devfreq/57000000.gpu/available_frequencies`. The GPU's
other `_KNEXT` lines already use `gpu.0`, which R35's nvgpu links under
`/sys/devices` when its device has another name (`os/linux/sysfs.c`). The
devfreq device keeps the GPU's name in R35's devfreq core. 4.9 never reads
the line. The file is a dpkg conffile, so an upgrade of the package would ask
before replacing it. The prepare step saves the original under
`/var/lib/jp5-trial/original/`, and `collect --uninstall` puts it back.
NVIDIA's file is not copied into this repository.
Validation: on the host, prepare on a fake card with the card's own file
(SHA-256 matched) changed exactly that line and kept the file's mode. Collect
`--uninstall` restored it byte for byte, also from the everyday state. Trial
29 on the Nano: the `nvpmodel` service succeeded under 5.10 with no config
path missing, and switching to 5W and back to MAXN set the same CPU, GPU and
memory limits as under 4.9.

## Device tree

[tegra210-p3448-0000-p3449-0000-b00-r35.dts](tegra210-p3448-0000-p3449-0000-b00-r35.dts)
includes NVIDIA's R32.7.6 Nano B01 description, compiled with
`LINUX_VERSION=510` so NVIDIA's own `>= 4.14` branches select upstream-style
power domains and memory controller nodes. On top of it:
- The rev-400 plugin-manager fragments the 4.9 kernel would apply (power
  monitor rail names, SD0 minimum voltage, PCIe Ethernet GPIO, SDMMC3 and
  thermal OC1 properties, LEDs). 5.10 has no plugin manager; the odm-data
  watchdog fragments are not applied.
- No downstream SMMU, VPR or IRAM carveouts; nvmap registers its own carveouts
  device. Upstream `ramoops` keeps the last 5.10 console log across a warm
  reset; from trial 11's build it uses R32's zone layout (64 KiB records,
  512 KiB console), so the 4.9 boot that follows reads 5.10's console.
- USB host and SD card nodes moved to the bindings R35's upstream-derived
  drivers expect (xHCI resets, `tmclk`, pad calibration, SDMMC1 tap/trim from
  upstream `tegra210.dtsi`).
- Display, camera, audio, video engines and downstream test/debug nodes are
  disabled. Until trial 17 that included the HDMI head, so 5.10 had no
  display driver (trial 18 below turns the HDMI head on).
- Trial 2 (2026-10-13), after trial 1 stopped silently with the boot logo on
  screen: the bootloader's HDMI framebuffer (`tegra_fbmem=0x800000@0x92ca9000`,
  1920x1080 per the 4.9 log; 32 bpp, stride 7680 and `a8b8g8r8` assumed) is
  reserved and described as a `simple-framebuffer` under `/chosen`, so 5.10's
  built-in simplefb and fbcon show the kernel console on HDMI. CPU DVFS (the
  DFLL at `clock@70110000`) is disabled; the CPU stays on the bootloader's
  clock. The trial entry adds `clk_ignore_unused pd_ignore_unused
  cpuidle.off=1 initcall_debug ignore_loglevel` (prepare script), which keeps
  the display's clocks and power domain on and logs every initcall (from trial
  26 without the first three, which the 4.9 entry never had, so 5.10 turns
  off unused clocks and power domains and may use CPU idle states). Trial 18
  removed the simplefb nodes so tegradc's own framebuffer would take fbcon, as
  under 4.9; its 5.10 boot then stopped before init with only the logo on
  HDMI. Trial 19 restores them, so the console shows on HDMI through the boot
  and tegradc, probed late, gets the next framebuffer.
- Trial 5 (2026-10-13), after trial 4's log:
  host1x loses R32's camera `assigned-clocks` (entry 5, `CLK_OUT_3_MUX`, does
  not exist in 5.10's clock driver and failed host1x's probe); PCIe gets
  upstream's `default`/`idle` pinctrl states that take the PEX pads out of
  deep power-down; the pad controller gets its interrupt (SPI 49) and the
  xHCI node its xusbc/xusba PM domains, both of which R35's `xhci-tegra`
  needs; and the DFLL is enabled again with upstream p3450's `nvidia,pwm-*`
  values, because R35's `tegra210-dvfs`, which nvgpu waits for before it
  manages vdd-gpu, needs the DFLL's voltage tables. Until trial 15 the config
  fragment left out `tegra124-cpufreq`, so the CPU stayed on PLL_X at the
  bootloader's 1017.6 MHz rather than switching to the DFLL. The trial entry
  adds `log_buf_len=4M`: trial 4's initcall log overflowed the default buffer.
- Trial 6 (2026-10-13), after trial 5's log: R35's nvgpu reads the GCPLEX
  config fuse (offset 0x1c8, the register R32's nvgpu reads with
  `tegra_fuse_readl`) through an nvmem cell named `gcplex-config-fuse`, and
  R35's fuse driver maps that cell only to the T194 GPU. The efuse node gets a
  read-only `gcplex-config-fuse@1c8` cell and the gpu node points
  `nvmem-cells` at it; `calibration` still comes from the T210 lookup table.
- Trial 11 (2026-10-13), after trial 10: vdd-gpu is a `pwm-regulator` on
  channel 1 of `pwm@7000a000`, and under 5.10 the GPU's voltage sensor did not
  follow its duty. R32's `pwm-tegra.c` switched the controller's clock to its
  `parent` clock (PLL_P) and set 48 MHz; R35's driver takes only the first
  clock and asks for 48 MHz, which keeps the bootloader's source (5.10's
  Tegra210 clock table sets none for the PWM). The node now gets
  `assigned-clocks`, `assigned-clock-parents` and `assigned-clock-rates`:
  `TEGRA210_CLK_PWM` (17) on `TEGRA210_CLK_PLL_P` (243) at 48 MHz, the same
  ids in R32's and R35's bindings. The clock core applies them before the
  driver probes. Trial 11 on the Nano: `clk_parent=pll_p` at 48 MHz, the GPU's
  voltage sensor followed vdd-gpu (818 and about 1,013 mV) and the top GPU
  clock passed.
- Trial 12 (2026-10-13), for memory clock scaling (patch 0009): the EMC node
  gets `nvidia,memory-controller`, the upstream memory controller node 5.10's
  EMC driver needs. The bootloader trains the 1600 MHz table at each boot and
  stores the results in its own device tree's EMC node, and NVIDIA's L4T
  U-Boot (`fdt_copy_node_paths` in `tegra210-common.h`, R32.6.1's v2020.04
  source read here) copies `/external-memory-controller@7001b000` into a
  device tree loaded from extlinux `FDT`, but only when the node's phandle
  matches. R32.7.6's Nano B01 device tree, compiled here as NVIDIA's 4.9 build
  does, gives that node phandle 0x21, and so does this one; the build now fails
  if it changes. Trial 12 on the Nano showed the copy: under 5.10 the RAM
  code 0 tables at 1600 MHz read `trained = <1>` (this DTB has 0), with
  trained values that differ from this DTB's.
- Trial 18 (2026-10-14), display: `dc@54200000` (head 0), `sor1` and
  `dpaux1` are on; head 1 (`dc@54240000`, the DP port through `sor`) stays
  off. On 5.4 and later tegradc attaches power domains by name on the dc
  device, "disa" for head 0 and "sor" and "dpaux" for the output, and R32's
  node has none (4.9 used its own partition calls), so those lookups returned
  NULL, which the first power-up would dereference. The node now lists 5.10
  pmc's `dis`, `sor` and `sor` powergates under those names (the DPAUX shares
  the SOR partition: the driver's older code finds both as
  `nvidia,tegra210-sor-pd`). HDMI's
  DDC runs on the dpaux1 pads, so tegradc reads `dpaux1` too.
  `fb0_carveout` stays empty (the bootloader does not fill it under either
  kernel, and the 5.10 path ignores `tegra_fbmem=`), so `tegra_fb` allocates
  its buffer on first use; `nvidia,fbmem-size` caps that at 16 MiB (one 32
  bpp buffer up to 2560x1440) instead of the 40 MiB default, out of the 64 MiB
  CMA area nvgpu also uses. A decompiled diff against trial 17's DTB shows
  only these properties, the three status changes and the removed simplefb
  nodes (phandle numbers shift by two; the EMC node keeps 0x21). Trial 19's
  differs from trial 18's only in the restored simplefb nodes, and trials 20
  to 22 use trial 19's unchanged.
- Trial 23 (2026-10-14), display memory: R32's head node has `iommus` for the
  downstream SMMU node, which this tree disables, so under 5.10 the head used
  direct DMA and could not scan X's page-backed buffers (trial 22). The head
  now names upstream tegra-smmu in the memory controller, which 5.10 registers
  already (`iommu: Default domain type: Translated`), with R35's swgroups DC
  (1) and DC1 (34): the ASID registers at 0x240 and 0xa88 that R32's DC and
  DC12 (2 and 10 in its binding) set. `iommu-direct-regions`, which R35's
  tegra-smmu reads at attach and maps at the same address before it enables
  translation, points at the reserved bootloader framebuffer, which the head
  scans for simplefb from its attach (first probe attempt, about 2.4 s) until
  tegra_fb takes over. That reserved node gets a fixed phandle, 0x1000, so
  the generated phandles do not shift (U-Boot matches the EMC node's): a
  decompiled diff against trial 22's DTB shows only the head's two
  properties, that phandle and its `bootfb` symbol. Trial 23 on the Nano:
  the head joined IOMMU group 0 at its bound probe (24.06 s), the dc and dc1
  swgroups were enabled on ASID 0 with the direct region's 2,048 entries
  among its mappings, and X's buffers scanned through the SMMU; the faults on
  the entries the driver had not flushed are patch 0019's.
- Trial 27 (2026-10-14), per-CPU timers: R35's `timer-tegra.c` gives each
  Tegra210 CPU its own timer (TMR10 to TMR13, rating 460 above the arch
  timer, which does not survive a power cycle of the core) and maps their
  interrupts from entries 10 to 13 of `timer@60005000`. R32's node lists only
  those four (SPI 176 to 179), so every 5.10 boot logged `tegra-timer: failed
  to map irq for cpu0` and kept only the arch timers. That mattered once
  trial 26 let 5.10 use C7. Its 5.10 boot stopped twice at the same line at
  22 s, most likely a timed wait that no CPU woke from. The node now lists
  upstream tegra210.dtsi's 14 interrupts (TMR0 to TMR13). A decompiled diff
  against trial 26's DTB shows only that property.
- Trial 30 (2026-10-14), from the everyday boot's gaps:
  - UARTs B to D add `nvidia,tegra30-hsuart`, which R35's `serial-tegra`
    matches. R32's `nvidia,tegra114-hsuart` matched only 4.9's, so 5.10 had
    no `/dev/ttyTHS*`. The tegra30 chip data has 4.9's tegra114 values in
    every field both versions have.
  - The CPU and `l2-cache` nodes get Cortex-A57 cache sizes: 48 KiB 3-way
    I-cache and 32 KiB 2-way D-cache (L1), and a 2 MiB 16-way unified L2,
    all with 64-byte lines. 4.9 reads these from the CPU's CCSIDR; 5.10 only
    from the device tree. Without them sysfs had no cache `size`, and
    haveged failed (error 5, its walk buffer allocation).
  - LDO0 (`avdd-sys-1v2`) is always on. 4.9 keeps it on, and upstream's
    Nano device tree marks it always-on; 5.10 turned it off at 38 s.
  - A decompiled diff against trial 29's DTB shows only these properties,
    with the same phandles.
- Trial 31 (2026-10-14), USB device mode on the micro-USB port:
  - `xudc@700d0000` is on, with the names R35's `tegra-xudc` looks up:
    `reg-names` (base, fpci, ipfs), `clock-names` for R32's five clocks in
    R32's order (dev, ss, ss_src, hs_src, fs_src), `phy-names` `usb2-0`,
    the XUSB device (`xusbb`) and SuperSpeed (`xusba`) power domains, and
    R32's `hvdd_usb` and `avddio_usb` rails as `hvdd-usb-supply` and
    `avddio-usb-supply`. The node name keeps the UDC name
    `700d0000.xudc` that JetPack 4's `nv-l4t-usb-device-mode` looks for.
  - The pad controller's `usb2-0` port is `peripheral` with
    `usb-role-switch`, which R35's padctl requires for the port to carry a
    role ("usb-role-switch not found for otg mode"), and a
    `gpio-usb-b-connector` child that reads VBUS on GPIO CC4, active low.
    Both follow upstream's Nano device tree. Under 4.9 the port never took
    the host role either: R32's VBUS extcon, which also gives 4.9's xHCI
    its USB-Host cable, has only the states USB and none.
  - R32's VBUS extcon (`/extcon/extcon@1`, the same pin, for 4.9's xudc) is
    off: 5.10 builds its driver too, and it would hold the pin.
  - The connector's GPIO reference comes earlier in the tree than any
    before it, so dtc numbers the GPIO controller's phandle earlier and 48
    of the 307 phandles move (EMC is still 0x21). Mapped by node, a
    decompiled diff against trial 30's DTB shows only these properties, with
    the same dtc warnings.
  - On the Nano, 5.10 bound `tegra-xudc` and the connector's `usb-conn-gpio`,
    and JetPack 4's service attached its `l4t` gadget to `700d0000.xudc`
    (role `none`, as nothing was plugged into the port).
- Trial 32 (2026-10-14), VIC for JetPack 4's camera daemon and video
  converter:
  - `/host1x/vic` is on. R35's nvhost still drives the Tegra210 VIC
    (`t21_vic_info`, firmware `tegra21x/vic04_ucode.bin`) with R32's clock
    names; R35 registers `vic03.cbus` and `vic.floor.cbus` at R32's IDs, and
    nvhost takes the two EMC clocks through the bandwidth manager instead.
  - VIC and host1x sit behind upstream tegra-smmu (swgroups 22 and 6 in R35's
    binding), as behind 4.9's SMMU: nvhost refuses a buffer in more than one
    piece for a device without an IOMMU, and pins data buffers to VIC and
    command buffers to host1x.
  - A decompiled diff against trial 31's DTB shows only these three
    properties, with the same phandles.
  - On the Nano, 5.10 bound VIC to `falcon` with host1x and VIC in IOMMU
    groups and created `/dev/nvhost-vic`, with no SMMU fault. VIC's clock
    then failed to turn on (patch 0022, trial 33, which keeps this device
    tree).
- Trial 37 (2026-10-15), the SOR partition's resets: 5.10's PMC acquires a
  domain's resets before powering it off and asserts them across the power
  cycle. R32's `sor` powergate node, which 4.9 never read (its partition
  table is in `powergate-t21x.c`), lists SOR0, DISP1, DSIB, SOR1 and
  MIPI_CAL. DISP1 is head 0's own reset, also in `dis`, which keeps it
  acquired while off; with SOR powering off after the head (patch 0028) the
  SOR's power-off would always find it busy. The node now lists 4.9's seven
  (upstream's tegra210.dtsi has the same): SOR0, DSIA, DSIB, SOR1,
  MIPI_CAL, DPAUX and DPAUX1, tegradc's two among them released between
  uses (patch 0027). A decompiled diff against trial 32's DTB (unchanged
  through build #31) shows only that property; both variants compile with
  the same dtc warnings.
  - On the Nano, the `sor` domain powered off and on with the head under
    5.10, with no reset error (see the validation for 0027 and 0028).
- Trial 38 (2026-10-15), the PMIC's interrupt: R32's `max77620@3c` node
  gives SPI 86 type none (`<0 86 0>`), which 5.10's GIC driver warns about
  once at boot (`gic_irq_domain_translate`, in each recorded 5.10 boot since
  trial 4).
  It is the only interrupt with type none in the DTB (a scan of every
  `interrupts` and `interrupts-extended` on a three-cell controller; the
  PCIe `interrupt-map` uses level high). The node now says
  `IRQ_TYPE_LEVEL_HIGH`, the type it already ran with: Linux sets every GIC
  SPI to level at start, an SPI can be only level high or rising edge, and
  the PMC inverts the PMIC's active-low line (`nvidia,invert-interrupt`).
  Upstream's p3450 tree routes it through the PMC's wake event 51 instead.
  A decompiled diff against build #32's DTB shows only that cell (0 to 4).
  - On the Nano (build #33), 5.10 logged no warning in the whole boot, and
    `/proc/interrupts` showed `LIC 86 Level max77620-top` (4.9: `Edge`,
    its display for a line with no type).
- 2026-10-22, the video encoder, decoder and JPEG engine, for hardware
  video encoding and decoding:
  - `/host1x/nvenc`, `/host1x/nvdec` and `/host1x/nvjpg` are on. R35's
    nvhost still drives Tegra210's three (`t21_msenc_info`,
    `t21_nvdec_info`, `t21_nvjpg_info`, through the falcon and NVDEC
    drivers) with R32's clock names, whose `cbus` users patch 0022 lets
    prepare. Their firmware is R32.7.6's in `tegra21x`, from the nano-l4t
    packages; NVDEC loads `nvhost_nvdec020_ns.fw` when its secure
    bootloader pair is absent.
  - Like VIC, they sit behind upstream tegra-smmu: swgroups NVENC (7),
    NVDEC (24) and NVJPG (26) in R35's binding, which R35's Tegra210 memory
    controller table lists. R32's nodes named the 4.9 SMMU's groups.
  - A decompiled diff against build #35's DTB shows only the three nodes'
    `status` and `iommus`, in both variants, with the same dtc warnings
    (container build, dtc 1.7.0).
  - On the Nano (build #36, the reference card, 2026-10-22): `/dev/nvhost-msenc`,
    `-nvdec` and `-nvjpg` appear, each engine joins its own IOMMU group and
    logs `initialized`. The reference card boots it by default since.

The `-gpu-smmu` variant also puts only the GPU behind upstream tegra-smmu
(swgroup 17 in R35's binding), for a second trial with big pages if direct DMA
fails. Each compiles with 176 dtc style warnings (duplicate unit addresses
inherited from the R32 sources) and no errors.

The DTB bytes change with every build: R32's `tegra210-common.dtsi` stores
the cpp build time (`nvidia,dtbbuildtime`) and the absolute source path
(`nvidia,dtsfilename`) in the root node. Compare DTBs by decompiling them
(`dtc -I dtb -O dts -s`) and ignoring those two properties. On 2026-10-13 a
recompile on the owner's PC differed from the trial 3 DTB only in the build
time, and its chosen, reserved-memory, DFLL, PCIe, XUSB pad, host1x and
symbol nodes matched this container's build exactly.

## Validation so far (host only)

- 2026-10-12, this repository's container, GCC 13.3: Image, 1,101 modules
  (`nvgpu.ko` depends on `nvmap.ko`, vermagic
  `5.10.216-tegra SMP preempt mod_unload modversions aarch64`) and both DTBs
  build; the stripped modules are 89 MiB. The patched objects were rebuilt
  from the patched sources, and the nvmap objects compile without
  `NVMAP_CONFIG_HANDLE_AS_FD`'s ID fallback. The DTBs keep the board
  compatible, 118 enabled nodes and the GPU `iommus` values above (fdtget).
- `build-jp5-kernel.sh` ran from an empty directory as an unprivileged user
  (about 30 minutes on 4 cores, 9.4 GB of work files) and ended with
  `JP5_KERNEL_BUILD=PASS`; its kernel has no fuse-burn code and carries the
  `tegra_fuse.tegra_chip_id` parameter (System.map).
- 2026-10-13, the owner's PC (Ubuntu 26.04.1, GCC 13.4.0, binutils 2.46,
  20 cores): the same script, as the ordinary user, ended with
  `JP5_KERNEL_BUILD=PASS` in 641 s with the same module count, vermagic and
  checks. This is the build the second-card trial uses.
- The trial scripts were exercised against a fake card root holding the real
  saved primary extlinux bytes (SHA-256 `1a1e47ed…3052`): prepare, the pre-init
  as PID 1 for both boots, collect and uninstall (which returned the tree
  byte for byte).

Trial 1 on the Nano (2026-10-13, the repaired second card, `--skip-control`): the
5.10 boot showed only the bootloader logo for 55 minutes and never mounted the
root (no trial logs, extlinux still on the trial entry, and the next PC mount
of APP needed no journal recovery).

Trial 2 panicked in the PCIe PHY (patch 0005). Trial 3 got through every
driver, mounted the second card's root and ran the trial init, which failed with ENOEXEC
because the second card's `/bin/bash` and `/bin/kmod` read back wrong from the card itself
(PC check: 580 packaged files with bad content, then USB read timeouts).
Trial 4 on the reference card reached multi-user, ran the checks and powered off with the
card healthy; host1x, xHCI, PCIe links and the GPU did not come up (causes
above; trial 5 carries the changes). Trial 5 brought all of them up except the
GPU, whose power-on failed reading the GCPLEX fuse (trial 6 carries the cell).
Trial 6 passed the fuse read, then the first GPU power-on stalled SD card I/O
at about 42 s, so the boot never reached the checks. Trial 7's trace put the
stop in the GPU's clock step, which on 5.10 deadlocks on its own runtime resume
(patch 0007, with the gbus prepare stub behind it fixed by 0008). In trial 8
the GPU powered on and CUDA work started, then a GPU memory fault crashed the
kernel during vector_add. Trial 9, recorded on the PC, passed deviceQuery and
the small vector_add sizes; the large one faulted the GPU's MMU without
crashing the kernel. Trial 10 showed that fault only at the top GPU clock,
with the GPU's rail near 710 mV under 5.10 whatever was requested. With the
PWM clock change above, trial 11 passed every CUDA test under 5.10, with
memory still at 204 MHz. In trial 12 (patches 0009 and 0010) the trained
memory tables reached 5.10, but the EMC driver's probe failed on its
reserved-memory lookup. In trial 13 it probed and offered 1600 MHz, which
R35's EMC voltage table refused. With trial 14's patch 0011 the memory
clock reached 1600 MHz and CUDA's baseline matched 4.9's. In trial 15 (patch
0012) the CPU scaled up to 1479 MHz and matched 4.9's speed; vector_add with
the GPU pinned at its lower clocks stayed slower than under 4.9. Trial 16
(same kernel) traced that to 5.10's 204 MHz CPU minimum letting the memory
clock fall; with trial 17's patch 0013, which sets 4.9's 1.2 GHz minimum,
memory stayed at 1600 MHz and vector_add matched 4.9 at every GPU clock.
Trial 18 (patch 0014 and the device tree's HDMI head) turned on JetPack 4's
display driver, and its 5.10 boot stopped before init. Trial 19 ran the
driver's probe late in a running system (diagnostic patch 0015): 5.10 booted,
and the probe oopsed on a device pointer it had not yet set. Trial 20 set it
first (0014); the probe then failed to reserve display bandwidth because
isomgr had sized its pool at 204 MHz, and a file its error path left behind
oopsed when read. Trial 21 sized the pool from the full memory range (0016)
and cleaned up after a failed probe (0014); its late probe drove HDMI. Trial
22 probed at boot and started JetPack 4's desktop, with R32's buffer ids
(0017); X ran but chose 800x600 from simplefb's fb0, and the head refused
every buffer as not contiguous. Trial 23 put the head behind the SMMU and
made tegradc's framebuffer fb0 (0018): JetPack 4's desktop showed at
1920x1080, and the display faulted on buffers it read right after they were
mapped, which R35's tegra-smmu had not flushed. Trial 24 flushed each entry
as it was mapped (0019), and the display ran with no fault. Trial 25 dropped
diagnostic patches 0006 and 0015, and 5.10 still passed every step.

Not shown and only testable on the Nano: memory
scaling over a long run (trials 14 to 17 covered one
boot each). JetPack 6 is not attempted until JetPack 5's
gaps are closed.

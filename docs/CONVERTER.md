# How the converter works

The converter turns a Jetson Nano's JetPack 4.6.6 card into Ubuntu 26.04
with the GPU stack, in three parts:

| Part | Runs | Does |
| --- | --- | --- |
| `nano26-convert` (stage 1) | On JetPack 4.6.6, as root | Checks the board, downloads everything, and writes the new system as an image file (or onto a second card) |
| `nano26-first-boot` | As the new card's first process, once | Grows the system to the whole card and installs Ubuntu's packages, with no network |
| `nano26-stage2` | As a service on the next boot, once | Repackages and installs NVIDIA's libraries, runs the checks, and restarts into the desktop |

All three are in [scripts/jetson/convert](../scripts/jetson/convert). The
[README](../README.md#put-it-on-your-own-nano) has the steps to run it, and
[SAFETY.md](SAFETY.md) what it writes, what it downloads and what it
refuses.

**Status.** It ran once end to end on this project's Nano (2026-10-22):
from a JetPack 4.6.6 card to Ubuntu 26.04's desktop, with every stage 2
check passing. The image took 23 minutes to build and came to 6.7 GiB, the
first boot took about 10 minutes and stage 2 about 70. The kernel it
downloads is not published yet, so for now it needs `--kernel DIR` with a
kernel built by [build-jp5-kernel.sh](../scripts/host/build-jp5-kernel.sh).
It has not been re-run on the Nano since the repository was reorganised
for publication; the PC tests pass.

**Reading this page.** It was written as the plan the converter was built
from. *The reference card* is the project's own card, on which the system
was first put together by hand, step by step, with the scripts now in
[scripts/reference-card](../scripts/reference-card). The converter repeats
those steps and reuses those scripts' package lists and settings, which is
why they are still here. *The owner* is the person whose Nano this is.
Dates are 2026.

## Goal

Someone with an original Jetson Nano 4GB developer kit and NVIDIA's own
JetPack 4.6 card runs one command and ends up with what the reference card runs today:

- Ubuntu 26.04 with its own systemd, on JetPack 5's 5.10 kernel with this
  repository's patches;
- the GPU stack: JetPack 5's driver set, CUDA 11.4 with cuDNN 8.6, CUDA 12.6
  with cuDNN 9.3 beside it, TensorRT 8.2 as the default with 8.5 beside it,
  OpenGL, OpenGL ES and Vulkan compute;
- the VIC fix, the GPU desktop (X server 1.20, Unity and Xfce), the fan
  zone, zram swap and the HDMI wake helper.

The converter downloads everything from its publishers: Ubuntu's archive,
NVIDIA's repositories and this repository's kernel release. Nobody receives
NVIDIA files from us.

## What the user does

With one card, the main route (since 2026-10-21; the README's steps):

1. Write NVIDIA's JetPack 4.6.1 SD card image (NVIDIA's latest for the Nano)
   to a card of 32 GB or more, set it up, and update it to JetPack 4.6.6
   with NVIDIA's apt update. This is NVIDIA's own process; it also updates
   the board's boot firmware, which this project never writes.
2. Copy the repository and the kernel folder to the Nano, and run
   `sudo ./nano26-convert --target-image ~/nano26.img --kernel DIR`, first
   with `--dry-run`. It builds the new card as an image file on the running
   card and cuts it to its contents (about 6 GB, estimate), with its SHA-256
   beside it. `--kernel` stays needed until the kernel release is
   published; then the converter downloads the kernel and `--kernel` is
   left out.
3. Copy the image to a computer (`scp`), shut the Nano down, and write the
   image over the same card with balenaEtcher or `dd`.
4. Power on. The first boot grows APP to the end of the card, whatever its
   size, and sets the system up; the next builds the GPU stack, shows its
   progress on the HDMI screen, runs its checks, and restarts into the
   desktop.

Writing the image replaces JetPack 4.6.6 on the card; the way back is
NVIDIA's image (step 1), or a backup of the card. The image holds the
account's password hash, the SSH keys and the Wi-Fi passwords, so it is
for that user only: it is readable by the account that ran the converter
and nobody else, and the converter says not to share it.

With a second card (32 GB or larger, estimated) in a USB card reader on the
Nano: `sudo ./nano26-convert --list`, then
`sudo ./nano26-convert --target /dev/sdX --kernel DIR` with that card, and
type its name to confirm; when it says so, shut down, swap the cards and
power on. The JetPack 4 card is then only read, never changed, so it stays
a working fallback: putting it back is the recovery.

## Compared with JetPack 4.6.6

| Layer | JetPack 4.6.6 | The new card |
| --- | --- | --- |
| Board firmware (QSPI) | JetPack 4.6.6's | Kept: never written |
| The card's 13 boot partitions | Boot loader and its settings | Kept: copied byte for byte |
| Kernel | Linux 4.9.337 | Replaced: JetPack 5's 5.10.216 with this repository's patches |
| Operating system | Ubuntu 18.04 | Replaced: Ubuntu 26.04 with its own systemd |
| GPU driver | L4T R32.7.6 | Replaced: JetPack 5's set (R35.6) built for the Nano, with R32.7.6's firmware and power modes |
| CUDA | 10.2 | Replaced: 11.4, with 12.6 beside it |
| cuDNN | 8.2 | Replaced: 8.6, with 9.3 beside it |
| TensorRT | 8.2 | Kept as the default (JetPack 4's packages), 8.5 beside it |
| Graphics | JetPack 4's OpenGL, OpenGL ES, Vulkan | Replaced: JetPack 5's, on Ubuntu 20.04's X server 1.20 |
| Video converter (VIC) | JetPack 4's | Both: JetPack 4's, and JetPack 5's with this repository's VIC fix |
| Desktop | Ubuntu 18.04's | Replaced: Unity and Xfce on Ubuntu 26.04, LightDM |
| Board extras | JetPack 4's fan and zram set-up | Replaced: the fan's thermal zone for 5.10, the HDMI wake helper, zram swap |
| The user's set-up | Accounts, passwords, SSH keys, hostname, Wi-Fi, time zone, locale | Copied |

## Requirements the converter checks

It refuses to start unless all of these hold:

- the board is a Nano 4GB SD developer kit: device tree compatible
  `nvidia,p3449-0000-b00+p3448-0000-b00`, the B01 carrier, which is the only
  one tested. The A02 carrier, the 2GB Nano and the eMMC module are
  refused until someone tests them;
- the running system is L4T R32.7.6 (JetPack 4.6.6), including NVIDIA's
  bootloader package, so the board's boot firmware matches what was tested;
- it runs as root, booted from the SD card (`mmcblk0`), with internet
  access to the hosts it needs;
- the target is a whole USB disk that is not mounted, not the boot card and
  at least the minimum size. The user types its device name to confirm,
  after seeing its size and model. Serial numbers are not shown or logged;
- the user has accepted NVIDIA's licence terms for the packages it
  downloads (shown, with links, before anything is fetched).

## How it works

### Stage 1: on JetPack 4.6.6, writing the new card

All downloads happen here, while the user still has a working system, so a
network problem stops the converter before the new card is needed.

1. **Lay out the new card.** Copy the GPT entries and contents of the 13
   small boot partitions (p2 to p14) from the running card unchanged, then
   create APP (p1) from the same start to the end of the new card, with an
   ext4 the boot loader reads (no `64bit` or `metadata_csum`, as
   `build-u26-image.py` does). An image (`--target-image`) is a sparse file
   in the running card's free space: it takes all of it, keeping 1 GiB for
   JetPack and up to 16 GiB, and needs 10 GB (an estimate: the image holds
   about 6 GB). A sparse file never takes more than its size, so that is
   also the most it uses while it shrinks in step 7.
2. **Ubuntu 26.04 base.** Download Ubuntu Base 26.04.1, check it against
   the SHA-256 pinned in the converter (the one in Ubuntu's signed
   `SHA256SUMS`; [SAFETY.md](SAFETY.md) has how to check that yourself),
   and extract it into APP with JetPack 4's own `tar`.
3. **Ubuntu's packages, downloaded only.** In a chroot, 26.04's apt
   downloads, in one request, the reference card's boot set (`build-u26-root.sh`:
   systemd 259, udev, NetworkManager, OpenSSH, sudo and the rest) and
   everything stage 2 needs from Ubuntu: the reference card's Xfce and LightDM set
   (`add-u26-desktop.sh`), Unity (`add-u26-unity.sh`), `mesa-utils`,
   GCC 11 (`add-u26-gcc11.sh`), GStreamer's tools for the video check, and
   the libraries the `nano-l4t` packages depend on (read from
   `build-nano-l4t-debs.py`). Ubuntu's Realtek and Intel Wi-Fi firmware
   packages come separately. Nothing is installed on JetPack 4's 4.9
   kernel: apt and dpkg do run there (2026-10-11), but
   systemd 259 needs Linux 5.4 or newer and its package scripts run its
   tools; the project's first stage used systemd 249 for that reason
   (2026-10-12). The first boot installs these on 5.10, as the reference card's root was
   built on 5.10, with the same request, so apt picks the same packages it
   downloaded.
4. **NVIDIA's packages, downloaded only.** They go into a copy of NVIDIA's
   repositories on the new card (`/var/lib/nano26/mirror`, laid out as the
   servers are), so stage 2's builders read them as they read NVIDIA's
   servers on the PC, checks included. First the signed indexes: Jetson
   t210 r32.7, t194 r35.6 and common r32.7, r35.6 and r36.4, each `Release`
   checked with `gpgv` against NVIDIA's Jetson key (JetPack 4's own copy,
   fingerprint pinned), and the CUDA repository's for Jetson, checked against
   its key (fingerprint pinned), with `fetch-r35-cuda.py`'s and
   `fetch-cuda12-probe.py`'s own checks. Then each package, against its
   index entry and, where the repository pins it, that SHA-256:
   - the sources `build-nano-l4t-debs.py` pins: R32.7.6's core, CUDA,
     3D, firmware, USB 3 firmware, tools and video set, and R35.6's core, 3D,
     CUDA and video set;
   - the 19 packages `install-u26-r35.sh` pins: CUDA 11.4's runtime
     libraries, cuDNN 8.6 and TensorRT 8.5;
   - TensorRT 8.2's nine (`package-trt82.sh`'s inputs: TensorRT 8.2.1,
     cuDNN 8.2.1, cuBLAS 10.2, CUDA 10.2's runtime and NVRTC), the newest in
     the r32.7 index with what they depend on there, as
     `fetch-r35-cuda.py --set tensorrt --release r32.7` took them for the reference card;
   - what `build-nano-cuda12-debs.py` takes, chosen by its own code from the
     r36.4 and CUDA indexes: NVIDIA's `cuda-compat-12-2`, CUDA 12.6 and
     cuDNN 9.3;
   - Ubuntu 20.04's X server 1.20 and its libinput driver, pinned in
     `build-nano-l4t-debs.py`.
   What each stage 2 step takes is listed, with SHA-256, in `mirror/sets`.
   The repository's own files that stage 2 runs (the builders, installers,
   checks and their test files) are copied to `/usr/lib/nano26/repo` with
   their `SHA256SUMS`, so the converter runs only from a whole copy of the
   repository, and zram swap is set up for the first boot with systemd.
5. **Kernel.** For now `--kernel DIR` takes a kernel built with
   `build-jp5-kernel.sh` (its `out/` folder, every file checked against its
   `SHA256SUMS`). Once the release is published (see "The kernel as a
   download" below), the converter without `--kernel` downloads it before
   step 1, checks it against the SHA-256 pinned in the converter
   (`KERNEL_BUNDLE_SHA256`), unpacks it in `/var/tmp` (about 130 MB,
   estimate; removed at the end) and checks the folder as it checks
   `--kernel`'s. The USB 3 controller's firmware for
   the initrd comes from the running card. `extlinux.conf` gets a single
   entry that boots `nano26-first-boot` as `init=`; the everyday entry, the
   same without `init=`, waits in `/var/lib/nano26` for the first boot.
6. **Identity**, listed in the plan first. The SSH host keys (so SSH
   clients don't warn), the hostname and the NetworkManager profiles (so
   Wi-Fi works on the first boot) go in place, each skippable
   (`--no-copy-ssh-host-keys`, `--no-copy-hostname`, `--no-copy-network`).
   The SSH server gets `IPQoS none`: OpenSSH 10.1 and newer mark
   interactive traffic with DSCP EF, which some networks drop: with the
   Nano (2026-10-22), EF packets were lost between the router and the PC,
   and SSH hung before its password prompt. JetPack 4's OpenSSH never
   sends EF. The accounts with their password hashes, groups and SSH
   `authorized_keys`, the time zone and the locale are staged in
   `/var/lib/nano26` (root only), because Ubuntu's groups exist only once
   its packages are installed.
7. **First boot armed.** Copy `nano26-first-boot` and its lists, unmount,
   flush, and tell the user to swap the cards. An image is cut first:
   `e2fsck`, then `resize2fs` shrinks APP's ext4 to its minimum plus 256 MiB
   for the first boot, the file is cut after it, and the GPT is written
   again for the shorter file (its backup copy at the new end, read back).
   So the image fits any card of 32 GB, whatever its exact size (two of
   this project's 32 GB cards differed by 646 MB). Its SHA-256 goes into `FILE.sha256`; both
   files are for the account that ran sudo only. A failed run deletes the
   unfinished image, so the next one starts over.

### First boot: installing Ubuntu's packages on 5.10

`nano26-first-boot` runs as PID 1 on the new card's first boot. It mounts
`/proc`, `/sys`, `/dev` and `/run`, sets the clock no earlier than the card
was written and touches `/usr/lib/clock-epoch` (the Nano has no clock
battery: systemd starts later boots no earlier than that file, instead of
its own build date), then grows APP to the end of the card:
it refuses a card smaller than 30 GB or one where a partition follows APP,
installs `fdisk` from the cache, moves APP's end with `sfdisk -N 1` (which
also moves the backup GPT to the card's end), tells the kernel with
`partx --update` and grows the mounted ext4 with `resize2fs`. On a card
written directly APP already fills it, and only `resize2fs` runs, finding
nothing to do. Then it installs the cached Ubuntu packages
(the boot set and stage 2's, desktops included, in the request stage 1
downloaded them with) with apt and no network, uncompresses the Wi-Fi
firmware (5.10 cannot read `.zst` files), creates the accounts, sets the
time zone, locale, machine ID and a persistent journal, enables stage 2's
service, keeps `multi-user.target` as the default so the desktop waits
for the GPU stack, switches `extlinux.conf` to the everyday entry, deletes
the staged password hashes and keys, and restarts into Ubuntu 26.04's own
systemd. It shows its progress on the HDMI screen and in
`/var/log/nano26/first-boot.log`. If a step fails it stops there with the
log; powering on again retries, and every step can run again.

### Stage 2: the GPU stack, on the first systemd boot

`nano26-stage2` runs as a service (`nano26-stage2.service`) on the first
boot of Ubuntu 26.04's own systemd, natively on the 5.10 kernel, which is
how every install on the reference card ran. It needs no network: everything is on the
card. The builders and checks run as the user's account (the one that ran
the converter, staged as `owner`), the installs as root. Each step's tool
writes its record, as on the reference card, in the account's home; progress goes to
the HDMI screen, the journal and `/var/log/nano26/stage2.log`, and each
tool's result line to `/var/log/nano26/report.txt`. Stage 1 already set up
zram swap at half the memory, so the builds have it. First it checks the
repository files against their `SHA256SUMS` and gives the mirror to the
account (the CUDA 12 builder hard-links its sources, which the kernel
allows only for files the account owns).

1. **`l4t-build`**, with the repository's own builder and the mirror's
   `l4t` set (checked against its SHA-256 first, then linked into one
   folder by file name): `build-nano-l4t-debs.py --release r35` (the
   `nano-l4t` driver set: R35.6's GPU, CUDA, GL, Vulkan and X driver with
   R32.7.6's firmware and power tools, and the X server 1.20),
   `--set video --release r32 --cc gcc-11` (`nano-l4t-r32-video` with
   JetPack 4's codec elements and `v4l2_plugin_dir.so` compiled here) and
   `--set video --release r35 --cc gcc-11` (`nano-l4t-r35-video` with
   JetPack 5's codec elements, and `vic_patch.so` and `v4l2_plugin_dir.so`
   compiled here).
2. **`l4t-install`**: those seven packages and the 19 NVIDIA packages
   (CUDA 11.4's runtime libraries, cuDNN 8.6, TensorRT 8.5 with
   `trtexec`) in one apt transaction whose plan may install nothing else
   and remove nothing; then udev applies the new device rules to the
   GPU's nodes and the display's (`/dev/tegra_dc*`: NVIDIA's Vulkan driver
   opens `tegra_dc_ctrl` and crashed when it was still root's only, on the
   Nano, 2026-10-22).
3. **`r35-check`**: `check-u26-r35.sh` checks CUDA, EGL and OpenGL ES,
   Vulkan compute and TensorRT as the account.
4. **`cuda12-build`** and **`cuda12-install`**: `build-nano-cuda12-debs.py
   --mirror`, then its `install-nano-cuda12.sh`, which runs
   `check-nano-cuda12.sh`.
5. **`trt82-build`** and **`trt82-install`**: `package-trt82.sh` from
   TensorRT 8.2's nine packages, then `install-trt82.sh`, which makes it
   the default with TensorRT 8.5 beside it.
6. **`board`**: `enable-u26-fan.sh` (the fan's thermal zone) and
   `enable-hdmi-wake.sh` (the wake helper).
7. **`desktop`**: The reference card's settings as `add-u26-desktop.sh`,
   `add-u26-gpu-desktop.sh` and `add-u26-unity.sh` write them (LightDM on
   the GPU's X server 1.20, Xfce's and the greeter's theme, Unity's
   defaults and session menu, the card's partitions hidden from the desktop;
   a host test compares the texts), and LightDM enabled.
8. **`video`**: `probe-l4t-video.sh --installed r35`, then `r32`, through
   VIC and CUDA.
9. **Finish**: the installed versions go to the report; the mirror, the
   build folders and the TensorRT 8.2 package folder are deleted,
   `graphical.target` becomes the default, the service disables itself and
   the Nano restarts into the desktop's login screen.

A set's packages leave the mirror as soon as the step that installs them
passes, which keeps the card's free space up for the CUDA 12 build (its
builder wants 12 GB free). Each step that passes is marked and not run
again. If one fails, the service stops there and leaves the text login (and
SSH) with the log and the report; it runs again at the next boot, or with
`sudo systemctl start nano26-stage2`, from that step.

## What it reuses

| Reference card script | In the converter |
| --- | --- |
| `build-u26-root.sh` | Its package list (stage 1, first boot); its checks are the reference card's |
| `add-u26-desktop.sh`, `add-u26-unity.sh`, `add-u26-gcc11.sh` | Their package lists (stage 1, first boot) and settings (stage 2); they chroot into the reference card's partition |
| `add-u26-gpu-desktop.sh` | Its LightDM setting (stage 2); its packages are R32.7.6's |
| `build-nano-l4t-debs.py` | As it is (stage 2), and its pins (stage 1) |
| `fetch-r35-cuda.py`, `fetch-cuda12-probe.py` | Their index checks (stage 1, and stage 2 through the mirror); made to run on JetPack 4's Python 3.6 and GnuPG 2.2.4 |
| `build-nano-cuda12-debs.py` | As it is with `--mirror` (stage 2); its package choice (stage 1) |
| `install-u26-r35.sh` | Its 19 NVIDIA pins (stage 1); the install itself is stage 2's own, as the reference card's moved from R32.7.6 and CUDA 10.2 and pinned the owner's builds |
| `check-u26-r35.sh`, `install-nano-cuda12.sh`, `check-nano-cuda12.sh`, `package-trt82.sh`, `install-trt82.sh`, `enable-u26-fan.sh`, `enable-hdmi-wake.sh`, `probe-l4t-video.sh` | As they are (stage 2) |
| `install-u26-r35.sh`'s transition, `set-u26-default.sh`, `arm-u26-*.sh`, `build-u26-image.py` | Not needed: the new card boots 26.04 from the start |

NVIDIA's package hashes stay pinned where the repository pins them,
because they are the same for everyone. The builds made on the Nano are
not compared with the reference card's by hash (the compressor and its settings
differ); their file lists are what the checks look at.

## What it leaves out

- The YOLO26 and depth demos: their models are exported on a PC with
  PyTorch. They stay as separate, optional steps.
- ROS 2 and anything the user installs later.
- The files in the users' home folders: only the accounts, their SSH
  `authorized_keys` and the settings above are copied.
- JetPack 4's extras: VisionWorks (which JetPack 5 dropped), VPI 1, NVIDIA's
  OpenCV 4.1.1 build (without CUDA), the samples and the container runtime.
  They are built for CUDA 10.2 and Ubuntu 18.04, the reference card has none of them,
  and nothing in this repository uses them. Ubuntu 26.04's own OpenCV can
  be installed with apt (not yet tried on the Nano).
- Changing the JetPack 4 card in place. That is the main alternative (see
  open questions).

## Licences and what we publish

- Our scripts and kernel patches: this repository.
- The kernel release: a GPL build, published with the exact source (the
  OE4T commit and our patches) and its `build-info.txt`.

### The kernel as a download

`scripts/host/pack-jp5-kernel.sh OUT_DIR DEST_DIR`, on the PC that built
the kernel, checks `build-jp5-kernel.sh`'s `out/` (every file against
`SHA256SUMS` and nothing else there, the Image's release and build number,
nvgpu and the device trees) and packs it as
`nano26-kernel-RELEASE-bBUILD.tar.xz`, the folder's files under
`nano26-kernel/`, with its SHA-256 beside it. Names are sorted and owners
and times fixed (the build's `built_utc`), so packing the same folder again
gives the same file. It prints the Image's banner, which names the account
and computer the kernel was built under, because that is published with
it; `build-jp5-kernel.sh` sets them to `nano26@build`.

The converter's `KERNEL_BUNDLE_URL` names a release of this repository.
`KERNEL_BUNDLE_SHA256` is `None` until that release is published; then it
is the packed file's SHA-256, and from that version on the converter
downloads the kernel when `--kernel` is not given.

- NVIDIA's packages are downloaded by each user from NVIDIA and repackaged
  on their own Nano, under NVIDIA's terms, which the converter shows first.
- Ubuntu's packages come from Ubuntu's archive to each user's own Nano. We
  redistribute no Ubuntu image, so Canonical's terms for modified images
  don't apply to the converter (our reading); a ready image would need its
  own name or Canonical's approval (decided 2026-10-20).

## Safety rules

[SAFETY.md](SAFETY.md) has these in full, with how to check them.

- The board's boot firmware (QSPI) is never written, and neither are the
  running card's partitions: with `--target-image` the running card gets
  the image file, its SHA-256 file and temporary files, as ordinary files.
- The target is chosen by the user from current device information and
  confirmed by name; the converter never guesses a device and refuses
  anything mounted or the boot card.
- Every download is checked by a signature or a pinned SHA-256 before use.
- Logs leave out serial numbers, addresses, network names and keys.

## Testing

On the PC: shell and Python syntax; a dry run that prints the full plan; the
requirement checks against stand-in device trees and release files
(`test_nano26_convert.py`); stage 1 writing an image file instead of a card
(`--target-image`, which is also the start of the ready image) from
Ubuntu's real archive, then the first boot in an arm64 chroot under
emulation (`test_convert_image.py`, as root). That shows the logic, not
that a Nano boots the card: the emulated chroot runs on the PC's kernel,
not as PID 1 on 5.10.

NVIDIA's servers refuse this project's build machine (HTTP 403), so the
host tests use stand-ins (`tests/convert/nvidia_stand_in.py`): copies of
the Jetson and CUDA repositories and Ubuntu 20.04's pool with small `.deb`s
of the same names and versions, indexes signed by keys made for the test,
and a test plan (`--nvidia-test-plan`, accepted only with `--root`) that
points the converter at them and swaps in their keys' fingerprints and
SHA-256 pins. `test_nano26_convert.py` runs the NVIDIA step against them
and checks the mirror it saves: each set, and that
`build-nano-cuda12-debs.py --mirror` verifies its indexes, makes its choice
and takes its sources from it (hard links included), and that the other
builders' file names are there. It also compares the desktop settings
stage 2 writes with the reference card's scripts, and packs its stand-in kernel with
`pack-jp5-kernel.sh` (the same file each time; a changed file or an existing
bundle refused), serves it in place of the release and has the converter
download, check and unpack it (a different SHA-256 refused). The image test
writes its image from that download, without `--kernel`.
`test_convert_image.py` then runs
stage 2 in the image's chroot with stubs in place of the builders,
installers and checks: the real apt transaction, settings, marks, retry
after a failure, report and clean-up, but none of NVIDIA's code. The stubs
write their small `.deb`s with Python: `dpkg-deb --build` runs 26.04's tar,
which needs `openat2` (Linux 5.6 and newer, so the Nano's 5.10 has it), and
the PC's qemu-aarch64 does not provide it. `--stage2-again` reruns only
stage 2 on an image a `--keep` run left.

The image test also checks the cut image (its table, the backup GPT as the
file's last sector, room in APP, the SHA-256 file and that only its owner
can read it), then makes it as long as a 32 GB card and grows it as the first
boot does, with the PC's `sfdisk -N 1` and `resize2fs`, before the first
boot runs. The first boot itself grows the card only as PID 1: it grows the
mounted ext4, which needs `CAP_SYS_RESOURCE`, and this project's build
container lacks it.

On the Nano (2026-10-22): the newcomer's route on a 32 GB card restored to its
2026-10-11 JetPack 4.6.6 (the state right after NVIDIA's update) after a
full backup: the image built on it, copied to the PC and written over it,
then the new card's two boots. Every stage 2 step passed after two fixes:
SSH's DSCP EF marking turned off, and the display node's rules applied
before the Vulkan check.

## Open questions

- **The kernel release.** The converter downloads the kernel from a release
  of this repository, with its SHA-256 pinned in the converter. Until that
  release is published it needs `--kernel DIR`.
- **A02 carrier boards, the 2GB Nano and the eMMC module.** The device tree
  is the B01 carrier's, and the converter refuses the others until someone
  tests them.
- **A ready-made image.** Planned as a later step, built by the same code,
  and not made yet. Publishing one would redistribute Ubuntu's and NVIDIA's
  files, which their terms would have to allow; the converter avoids that
  by having each Nano download them itself.

The converter first wrote a second card in a USB reader; since 2026-10-21
its main route builds an image on the running card instead, so a newcomer
needs only one card.

# Safety: what this does to your Nano, and what it cannot do

This project puts a kernel NVIDIA never released for the Nano under an
operating system NVIDIA never tested on it. It is fair to ask what could go
wrong. This page answers that with what the code does and what was
measured, and says plainly where the testing stops.

In short:

- **It changes the microSD card and nothing else.** The boot firmware in
  the module's flash chip is never written, and neither are the chip's
  eFuses. A card that will not boot is fixed by writing NVIDIA's image to it
  again.
- **It runs the hardware at NVIDIA's numbers.** The same CPU, GPU and
  memory clocks and the same voltage tables as JetPack 4. Nothing is
  overclocked.
- **Every download is checked** against a signature or a pinned SHA-256
  before it is used, and comes from its publisher: Ubuntu, NVIDIA, and this
  repository for the kernel.
- **It has run on one board.** A Jetson Nano 4GB developer kit with the B01
  carrier. The converter refuses any other board. Treat it as an
  experiment and use a card you can afford to rewrite.

## What gets written, and what never does

| | Written? | Notes |
| --- | --- | --- |
| Boot firmware (the QSPI flash chip on the module) | Never | No script in this repository opens it. See below for NVIDIA's own update |
| eFuses | Never | The kernel is built without the fuse-burning interface (`CONFIG_TEGRA_FUSE_BURN` off) and its device tree node is disabled. Burning a fuse is permanent, so the kernel cannot do it |
| The card's 13 small boot partitions | Copied byte for byte | NVIDIA's boot loader and its settings, as JetPack left them, read back after copying |
| The card's main partition (APP) | Replaced | This is the conversion: Ubuntu 26.04, the 5.10 kernel and its boot menu entry |
| Your running JetPack card, while the converter runs | The image file, a record of the run, and temporary files it removes | Nothing is installed on JetPack or changed in it |
| Your computer | Nothing | You write the image to the card yourself, with balenaEtcher or `dd` |

The Nano starts from firmware in the module's flash chip, which then loads
whatever kernel a text file on the card names (`extlinux.conf`). A new
kernel therefore needs no flashing: it is a file on the card and a line in
that menu. That is the whole reason this project can leave the firmware
alone.

**NVIDIA's own update does write the firmware.** Step 1 of the instructions
brings JetPack 4.6.1 up to 4.6.6 with NVIDIA's `apt` update, and NVIDIA's
bootloader package updates the flash chip as part of it. That is NVIDIA's
supported process, it happens before this project is involved, and a Nano
that has been kept up to date has already done it. The converter then
checks that the bootloader package is at 32.7.6, so it only runs on the
firmware that was tested.

**NVIDIA's packages that touch the firmware are left out.** Three of
NVIDIA's JetPack 4 packages write the boot flash when installed or started:
`nvidia-l4t-xusb-firmware`'s install script, `nvidia-l4t-tools`' payload
updater and `nvidia-l4t-init`'s bootloader-config service. The new system
does not install NVIDIA's packages as they are. It rebuilds its driver
packages from a list of files
([build-nano-l4t-debs.py](../scripts/host/build-nano-l4t-debs.py)), and none
of NVIDIA's install scripts or services is carried over.

## Can it damage the board?

The kernel decides clock speeds and rail voltages, so this is the right
question to ask of a kernel port.

- **Clocks.** The CPU runs up to 1,479 MHz, the GPU up to 921.6 MHz and
  memory at 1,600 MHz: JetPack 4's limits, read back on the Nano under both
  kernels. The 5 W and MAXN power modes set the same limits as under
  NVIDIA's kernel.
- **Voltages.** They come from NVIDIA's own tables in NVIDIA's kernel
  source and from the Nano's device trees (NVIDIA's, and mainline Linux's
  for the CPU's regulator). Where the newer kernel had the code that
  applies them stubbed out for this chip, the patches restore what
  NVIDIA's 4.9 kernel does
  ([0008, 0011 and 0022](../patches/jp5/README.md)); none adds a number of
  its own. Measured under 5.10, the core rail sits at 900 mV with memory at
  1,600 MHz, as under 4.9.
- **Memory timings.** The Nano's boot loader trains the 1,600 MHz timings
  at every power-on. The kernel takes them from there, refuses a table with
  a missing or oversized entry, and will not leave the 204 MHz boot speed
  for a table that is not marked as trained.
- **The one voltage bug found** went the harmless way. Early in the port the
  GPU's regulator did not follow requests and stayed near 710 mV, too low
  for the top GPU clock, so CUDA crashed there until the regulator's clock
  source was fixed.
- **Heat.** Under 5.10 the fan first did not start: the driver's thermal
  zone is left disabled by the newer kernel. In a load test without it the
  CPU reached 69 °C after 7 minutes. The converter installs a rule that
  enables the zone, and the fan then starts at its 51 °C step
  ([enable-u26-fan.sh](../scripts/jetson/enable-u26-fan.sh)).
- **Not tested:** the chip's own over-temperature throttling and shutdown
  under 5.10. No test came near those temperatures. If your Nano has no fan
  and runs hot under JetPack, watch it (`tegrastats` works) before you
  trust it unattended.

## Where every download comes from

| What | From | Checked how |
| --- | --- | --- |
| Ubuntu Base 26.04.1 | `cdimage.ubuntu.com` | SHA-256 pinned in the converter: the value in Ubuntu's signed `SHA256SUMS` |
| Ubuntu 26.04 packages and Wi-Fi firmware | `ports.ubuntu.com` | By Ubuntu's own `apt`, with the archive keys inside that base system |
| NVIDIA's JetPack 4, 5 and 6 packages, and CUDA | `repo.download.nvidia.com`, `developer.download.nvidia.com` | Each repository's signed index is verified with `gpgv` against a key whose fingerprint is pinned; each package is then checked against its index entry, and against a SHA-256 pinned in this repository where there is one |
| Ubuntu 20.04's X server 1.20 | `ports.ubuntu.com` | SHA-256 pinned in this repository |
| The 5.10 kernel | A release of this repository | SHA-256 pinned in the converter once the release is published. Until then, and whenever you prefer, build it yourself and pass `--kernel` |

The converter only downloads, from the hosts above. It sends nothing about
you or your board, and there is no telemetry.
No file of NVIDIA's is stored in or served from this repository: each Nano
fetches NVIDIA's packages from NVIDIA, after you accept NVIDIA's licence.

To check the Ubuntu Base pin yourself, on any Ubuntu machine:

```bash
base=https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release
curl -fLO $base/SHA256SUMS -O $base/SHA256SUMS.gpg
gpgv --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg SHA256SUMS.gpg SHA256SUMS
grep ubuntu-base-26.04.1-base-arm64.tar.gz SHA256SUMS
grep BASE_SHA256 scripts/jetson/convert/nano26-convert
```

**What you are trusting from this project** is its scripts, which are all
here to read, and its kernel build. The kernel is the one binary the
project publishes. Its source is two public commits plus the patches in
[patches/jp5](../patches/jp5/README.md), a `build-info.txt` inside the
download lists the hash of every input, and
[one script](../scripts/host/build-jp5-kernel.sh) rebuilds it on an
ordinary Ubuntu PC without root.

## What it does with your accounts and keys

So that the new system comes up with your login, your Wi-Fi and the same
SSH identity, the converter copies from the JetPack card: the accounts with
their password hashes and groups, each account's SSH `authorized_keys`, the
SSH host keys, the hostname, the NetworkManager profiles (Wi-Fi passwords
included), the time zone and the locale. Home folders are not copied.

- The image therefore holds secrets. It is created readable only by the
  account that ran the converter, and the converter tells you not to share
  it.
- The staged password hashes and keys are deleted at the end of the first
  boot.
- `--no-copy-ssh-host-keys`, `--no-copy-hostname` and `--no-copy-network`
  leave those out.
- The converter's own record leaves out serial numbers, addresses, network
  names and keys. It counts the network profiles and never prints them.

## What it refuses to do

`sudo ./nano26-convert --target-image FILE --dry-run` runs every check and
prints the whole plan without writing anything. The converter stops unless
all of these hold:

- the board is a Nano 4GB developer kit on the B01 carrier. The A02 carrier,
  the 2GB Nano and eMMC modules are refused until someone tests them;
- the system is JetPack 4.6.6 (L4T R32.7.6) with NVIDIA's bootloader
  package at the same version, booted from the SD card;
- NVIDIA's apt key on the card has the pinned fingerprint;
- you have accepted NVIDIA's licence terms, which it shows first.

When the target is a second card instead of an image file, it must be a
whole USB or removable disk, not the boot card, with nothing mounted. You
choose it from a list that shows size and model, type its name to confirm,
and it is checked again just before the first write. The converter never
picks a disk on its own.

## Going back

- **One card (the main route).** Writing the image replaces JetPack on that
  card. To go back, write NVIDIA's JetPack image to the card again, or a
  backup of your own card ([docs/BACKUP.md](BACKUP.md)). Make that backup
  first if the card holds anything you care about.
- **Two cards.** The JetPack card is only read. Put it back in the slot and
  the Nano boots JetPack as before.

Either way the firmware has not changed, so a JetPack 4.6.6 card boots as
it always did. This was exercised more than it was meant to be: during the
kernel work the same Nano went back and forth between NVIDIA's 4.9 kernel
and the 5.10 kernel on dozens of boots, and before the converter's test its
card was restored to plain JetPack 4.6.6 from a backup.

## What has been tested, and what has not

Tested on the real Nano:

- The kernel: 39 numbered boot trials, compared with boots of NVIDIA's
  kernel on the same card, and the project's own card has booted it by
  default since. The record of every trial is in
  [patches/jp5/NOTES.md](../patches/jp5/NOTES.md).
- The whole converter, once, from a JetPack 4.6.6 card to the Ubuntu 26.04
  desktop with every step passing (2026-10-22). Two problems showed up in
  that run and were fixed.
- What the converter's own checks cover at the end of every conversion:
  CUDA 11.4 and 12.6 computing correct results, cuDNN, TensorRT, OpenGL ES,
  Vulkan compute and both video converters.
  `/var/log/nano26/report.txt` on the new system lists each result. One
  line in it reads `gpu=FAIL`: JetPack 5's video converter has a second
  path, through the GPU, that writes flat frames on the Nano. That is
  known, nothing uses that path, and it does not fail the step.

Tested only on a PC:

- The converter's logic against stand-ins for NVIDIA's servers
  ([tests/convert](../tests/convert)): the checks and refusals, the image
  layout, the first boot in an emulated arm64 chroot.

Not tested:

- Any other board, carrier or module. Any card other than the three used
  here.
- A conversion by anyone other than the author. Until others have run it,
  assume you may be the first to find a problem.
- The converter since the repository was reorganised for publication: the
  PC tests pass, but it has not been re-run on the Nano.
- The DisplayPort output, CSI cameras and the board's own audio, which are
  switched off in the 5.10 device tree and so do not work; Ethernet with a
  cable; the 40-pin header.
- Over-temperature throttling and shutdown, as above.
- Long unattended running.

## Security of the converted system

Ubuntu's part of the system is a supported release: `apt upgrade` brings
Ubuntu's security updates until 2031, and only Ubuntu's archive is
configured as an apt source. That is the gain over JetPack 4's Ubuntu
18.04.

The rest does not get updates:

- The kernel is NVIDIA's 5.10.216 with this project's patches. It is not in
  any apt repository, and it changes only if you install a new build.
- NVIDIA's libraries come from its JetPack 4, 5 and 6 releases. They are
  installed from local packages and stay as they are; NVIDIA no longer
  updates them for this board.
- The desktop's X server is Ubuntu 20.04's 1.20.13, the newest that
  NVIDIA's X driver for this chip loads in
  ([why](ARCHITECTURE.md#the-desktop)). Ubuntu 20.04's standard security
  updates ended in 2025. It is used only for the desktop's login screen
  and session.

Two settings are looser than Ubuntu's defaults, both matching JetPack 4:
any user can read the kernel log, and members of the `video` group can open
the GPU's device nodes. The SSH server is enabled, with your accounts and
keys as they were, and one added line (`IPQoS none`) that turns off a
packet marking some home routers drop.

## No warranty

NVIDIA does not support this combination, and neither Ubuntu nor NVIDIA
had any part in it. The code is under the [MIT licence](../LICENSE), which
means it comes with no warranty. If something goes wrong, an
[issue](https://github.com/igsova/jetson-nano-ubuntu-26/issues) with the
files in `/var/log/nano26` is welcome. Read them through before posting:
they name your account and hostname.

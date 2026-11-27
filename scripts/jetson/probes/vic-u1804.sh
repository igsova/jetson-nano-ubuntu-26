#!/usr/bin/env bash
# Is it the user space or this boot? Run JetPack 4's video converter (nvvidconv,
# L4T R32.7.6) from Ubuntu 18.04's own user space, as trial 39 had it, in a
# chroot on the 26.04 card's boot.
#
# Usage: sudo bash vic-u1804.sh [--after-hang] [--power-cycle] [--replay=STEPS] [--falcon] [--fce] ROOT_DIR
#
# Under 18.04 (trial 39: the same kernel, device tree and VIC firmware) the
# converter completed its VIC jobs. On the 26.04 card the same converter makes
# trial 39's requests and VIC finishes none of its jobs: the kernel hands VIC
# the whole job and VIC never signals (2026-10-16). If
# 18.04's user space passes here, the difference is in the user space (Ubuntu's
# libraries, GStreamer, files in /etc); if it hangs, it is in this boot's state.
#
# ROOT_DIR is a copy of the 18.04 root's bin, sbin, lib, usr and etc, taken on
# the PC from a backup of the card. Run with sudo from the
# owner's ordinary account (SUDO_USER) on Ubuntu 26.04 under the 5.10
# kernel, as the first VIC use after a restart: a hung job may leave VIC hung
# for the rest of the boot, so the script refuses when the kernel has already
# timed out a VIC job this boot, unless --after-hang (a hang then says nothing
# about the user space). In order:
#   1. it checks the copy (Ubuntu 18.04, JetPack 4's R32.7.6, GStreamer's tools
#      and nvvidconv) and prints its C library, GStreamer, the hashes of
#      NVIDIA's converter libraries, and its VIC firmware's hash next to the one
#      this system's kernel loads;
#   2. each command runs in a private mount namespace, which ends with it: this
#      system's /dev, /proc and /sys, an empty /run and a scratch folder as
#      /tmp are mounted in the copy, then chroot into it with a clean
#      environment;
#   3. gst-inspect-1.0 nvvidconv (this also builds GStreamer's registry);
#   4. with --replay=STEPS only: the camera daemon step starts first, as at
#      18.04's boot (before --power-cycle);
#   5. with --power-cycle only: VIC is powered on once and let go before the
#      case, with no job (its runtime power control set to "on", then back to
#      what it was, and its suspend awaited). Under 18.04 the camera daemon
#      powered VIC at boot, so the converter's job was not VIC's first power-on
#      of the boot; on the 26.04 card it is;
#   6. with --replay=STEPS only: the rest of the steps trial 39's check script
#      took before its VIC step (scripts/jetson/jp5-trial-check.sh), in its
#      order. STEPS is a comma list of these, or all:
#        argus  the copy's camera daemon (/usr/sbin/nvargus-daemon) in the
#               chroot, running until after the case (trial 39 started it at
#               boot), with the device nodes it holds open;
#        emc    the bandwidth manager's debug floor at the memory clock's top
#               rate for EMC_HOLD seconds, then back to what it was (trial 39
#               held it through its CUDA baseline);
#        blank  the framebuffer blanked (4) for 2 s and unblanked (0), skipped
#               while the display manager runs (under X the screen then stays
#               unpainted until the login screen restarts; 2026-10-17);
#        modes  nvpmodel -m 1 (5W), then -m 0 (MAXN), 2 s after each, then
#               back to the starting mode if that was not MAXN.
#      Not replayed: trial 39's CUDA baseline (CUDA 10.2 is gone from this
#      system; the GPU ran under the desktop in earlier hangs), its 60 s of
#      JetPack 4's desktop, and its boot options. Each step prints the memory
#      clock, its floor, VIC's clocks and power and the power mode, and the
#      kernel's lines meanwhile go to replay-kernel.txt;
#   7. the case, named u1804 with -cycled and -replay-STEPS added for the
#      options: trial 36's pipeline (two 1280x720 I420 frames into NV12 NVMM
#      buffers and back, to fakesink) as root, with the copy's own libraries.
#      The same state is printed just before it, and the memory and VIC clocks
#      are sampled every 0.5 s while it runs.
# With --falcon, VIC's own processor (its falcon) and its host interface (THI)
# are read: 25 registers, 32 bits at a time through /dev/mem, by a small C
# reader built from the source below with this system's compiler (or the
# copy's). Nothing is written to VIC. The reads happen while --power-cycle
# holds VIC on (its firmware booted, no job), and 6 s and 16 s into the case
# (the middle of the first two jobs' 10 s timeouts when they hang), each only
# if VIC's runtime status reads "active" just before. A read while VIC is off
# would fault and crash the kernel (the u26 entry's panic=10 restarts it), so
# the record is synced to the card before each read.
# With --fce (which implies --falcon), just before the case VIC is held on and
# its firmware is told where its FCE microcode is, as JetPack 4's kernel does
# at every VIC power-on and JetPack 5's does not (flcn.c,
# nvhost_vic_finalize_poweron; R35 dropped the code and the header fields).
# The reader writes the two methods, SET_FCE_UCODE_SIZE and _OFFSET, through
# THI's method registers, as that function does: the size from the firmware
# file's FCE header, the offset from the firmware image's address in VIC's
# address space, which follows from the falcon's DMA base register (the kernel
# loaded the firmware from it; checked to be a page address) and the file's
# offsets. That is the only write to VIC. VIC is read before and after, and
# stays on through the case, since a power-off would lose the setting. The case
# is named with -fce added.
# For the case: gst-launch's exit, time and messages; the kernel's job timeouts
# (cdma_handle_timeout) and its other lines; VIC's power-on time; the
# converter's ioctl requests per type (syscall trace events, trial 36's method)
# with the display driver's counted ('C' and 'D' tegra_dc, 'F' the
# framebuffer); NVIDIA's and the display libraries it loaded, and every library
# it asked for and did not get (LD_DEBUG=libs,files). It passes when
# gst-launch exits 0 and the kernel timed out no job.
#
# What it changes: the copy gets empty dev, proc, sys, run and tmp folders
# where it has none (mount points); the kernel's trace settings (events, pid
# filter, tracing_on as it was), VIC's runtime power control (--power-cycle),
# the replayed steps' memory clock floor, framebuffer blank and power mode
# (each back as it was) and camera daemon (stopped), VIC's FCE setting (--fce;
# gone at VIC's next power-on), and a temporary folder
# under /var/tmp, all undone before it exits (also on Ctrl-C or an error).
# Nothing stays mounted.
# The record is ~/l4t-video-probe/<stamp>-u1804, owned by the account.
set -uo pipefail

KERNEL=5.10.216-tegra
CASE_SECONDS=60
# Paths inside the copy.
GST_PLUGINS=/usr/lib/aarch64-linux-gnu/gstreamer-1.0
TEGRA=/usr/lib/aarch64-linux-gnu/tegra
NV_FILES="$GST_PLUGINS/libgstnvvidconv.so $TEGRA/libnvbuf_utils.so.1.0.0 $TEGRA/libnvbufsurface.so.1.0.0
$TEGRA/libnvbufsurftransform.so.1.0.0 $TEGRA/libnvddk_vic.so $TEGRA/libnvrm.so $TEGRA/libnvrm_graphics.so
$TEGRA/libnvos.so $TEGRA/libdrm.so.2"
VIC_FIRMWARE=lib/firmware/tegra21x/vic04_ucode.bin
# Where this system's lib folder is ('' for /).
FIRMWARE_ROOT=''
# Kernel lines worth reading in a case, and the lines nvhost prints for every
# job timeout (its syncpoint and channel dump), which are counted instead.
FILTER='vic|host1x|nvhost|falcon|flcn|firmware|nvmap|smmu|iommu|memory-controller|mc-err|emem|tegradc|tegra_dc|tegra_fb'
# (also the dump's job, gather and FIFO lines, and its bare words)
DUMP='cdma_handle_timeout|stuck waiting|previous client|SYNCPT_|FIRST_GET|TIMEOUT +[0-9]|NUM_SLOTS|NUM_HANDLES|channel [0-9]+ - |vic \([0-9]+\): *$|JOB, syncpt|GATHER at|FIFOSTAT|kernel: +([0-9a-f]{8} +)*[0-9a-f]{8} *$'
# The libraries shown from the linker's record: NVIDIA's, display and EGL.
LIBS_SHOWN='/tegra/|/tegra-egl/|drm|gbm|EGL|GLdispatch|nvvidconv'
# Trial 39's steps before its VIC step, in its order, and their files.
REPLAY_STEPS='argus emc blank modes'
EMC_HOLD=20
DEBUGFS=/sys/kernel/debug
GRAPHICS=/sys/class/graphics
ARGUS=/usr/sbin/nvargus-daemon
MEM=/dev/mem

user='' group='' home='' tmp='' out='' tracefs='' tracing_was='' vic_dir='' control_was=''
argus_pid='' floor_restore='' blank_restore='' mode_restore='' sampler_pid='' watcher_pid=''
cleanup() {
    # Ctrl-C reaches the whole terminal group: finish the cleanup regardless.
    trap '' INT TERM HUP PIPE
    [[ -n $sampler_pid ]] && { kill "$sampler_pid"; wait "$sampler_pid"; } 2> /dev/null
    [[ -n $watcher_pid ]] && { kill "$watcher_pid"; wait "$watcher_pid"; } 2> /dev/null
    [[ -n $argus_pid ]] && stop_argus
    [[ -n $floor_restore ]] && echo "$floor_restore" > "$floor"
    [[ -n $blank_restore ]] && echo 0 > "$fb/blank"
    [[ -n $mode_restore ]] && timeout 60 nvpmodel -m "$mode_restore" < /dev/null > /dev/null 2>&1
    if [[ -n $control_was ]]; then
        echo "$control_was" > "$vic_dir/power/control"
    fi
    if [[ -n $tracefs && -n $tracing_was ]]; then
        trace_off
        echo "$tracing_was" > "$tracefs/tracing_on"
    fi
    [[ -n $tmp && -d $tmp ]] && rm -rf -- "${tmp:?}"
    [[ -n $out && -d $out ]] && chown -R "$user:$group" "$out"
}
alive() { [[ -r /proc/$1/stat && $(awk '{ print $3 }' "/proc/$1/stat" 2> /dev/null) != Z ]]; }
stop_argus() {
    kill -TERM "$argus_pid" 2> /dev/null
    for _ in {1..50}; do alive "$argus_pid" || break; sleep 0.1; done
    alive "$argus_pid" && kill -KILL "$argus_pid" 2> /dev/null
    for _ in {1..50}; do alive "$argus_pid" || break; sleep 0.1; done
    if alive "$argus_pid"; then
        printf 'WARNING: the camera daemon (pid %s) did not stop\n' "$argus_pid"
    else
        wait "$argus_pid" 2> /dev/null
    fi
    argus_pid=''
}
die() { printf 'VIC_U1804=FAIL: %s\n' "$*" >&2; exit 1; }

after_hang=0 power_cycle=0 replay='' falcon=0 fce=0
while [[ ${1:-} == --* ]]; do
    case $1 in
        --after-hang) after_hang=1 ;;
        --power-cycle) power_cycle=1 ;;
        --falcon) falcon=1 ;;
        --fce) fce=1 falcon=1 ;;
        --replay=*) replay=${1#--replay=}; [[ -n $replay ]] || die '--replay needs steps' ;;
        *) die "unknown option $1" ;;
    esac
    shift
done
(( $# == 1 )) || die 'usage: sudo bash vic-u1804.sh [--after-hang] [--power-cycle] [--replay=STEPS] [--falcon] [--fce] ROOT_DIR'
[[ $replay == all ]] && replay=${REPLAY_STEPS// /,}
IFS=, read -ra asked <<< "$replay"
for step in "${asked[@]}"; do
    [[ " $REPLAY_STEPS " == *" $step "* ]] || die "unknown replay step '$step' (steps: ${REPLAY_STEPS// /, }, or all)"
done
# The steps asked for, in trial 39's order.
want() { [[ ,$replay, == *,$1,* ]]; }
steps=''
for step in $REPLAY_STEPS; do
    want "$step" && steps+=${steps:+,}$step
done
[[ -n $replay && -z $steps ]] && die '--replay needs at least one step'
(( $(id -u) == 0 )) || die 'run this with sudo'
user=${SUDO_USER:-}
[[ -n $user && $user != root ]] || die 'run this with sudo from the ordinary account'
home=$(getent passwd "$user" | cut -d: -f6)
[[ -n $home && -d $home ]] || die "no home folder for $user"
group=$(id -gn "$user")
[[ -d $1 ]] || die "no folder $1"
root=$(cd "$1" && pwd -P)
[[ $(stat -c %d:%i "$root") != "$(stat -c %d:%i /)" ]] || die 'ROOT_DIR is this system'"'"'s own root'
. /etc/os-release
[[ ${VERSION_ID:-} == 26.04 ]] || die "needs Ubuntu 26.04 (this is ${PRETTY_NAME:-unknown})"
[[ $(uname -r) == "$KERNEL" ]] || die "needs the $KERNEL kernel (this is $(uname -r))"
for tool in journalctl unshare chroot mount timeout sha256sum; do
    command -v "$tool" > /dev/null || die "no $tool"
done

# --- 1. The copy.
grep -qx 'DISTRIB_RELEASE=18.04' "$root/etc/lsb-release" 2> /dev/null \
    || die "$root/etc/lsb-release does not say Ubuntu 18.04"
release=$(head -n 1 "$root/etc/nv_tegra_release" 2> /dev/null)
[[ $release == '# R32 (release), REVISION: 7.6,'* ]] || die "$root/etc/nv_tegra_release is not JetPack 4's R32.7.6"
for file in /usr/bin/env /usr/bin/gst-launch-1.0 /usr/bin/gst-inspect-1.0 "$GST_PLUGINS/libgstnvvidconv.so"; do
    [[ -e $root$file || -L $root$file ]] || die "the copy has no $file"
done
for dir in dev proc sys run tmp; do
    [[ -L $root/$dir ]] && die "$root/$dir is a link; the copy should not have it"
    [[ -e $root/$dir && ! -d $root/$dir ]] && die "$root/$dir is not a folder"
done

# VIC's state this boot: a job the kernel already timed out may leave it hung.
vic_dir=$(find /sys/bus/platform/devices/ -maxdepth 1 -name '*.vic' | head -n 1)
vic_time() { cat "$vic_dir/power/runtime_active_time" 2> /dev/null || echo 0; }
earlier=$(journalctl -k -b --no-pager 2> /dev/null | grep -c 'cdma_handle_timeout.*vic')
if (( earlier > 0 && ! after_hang )); then
    die "the kernel already timed out $earlier VIC job(s) this boot; restart the Nano and run this first (or add --after-hang)"
fi
if (( power_cycle )) && [[ -z $vic_dir || ! -w $vic_dir/power/control ]]; then
    die 'no runtime power control for VIC here'
fi
if (( falcon )) && [[ -z $vic_dir || ! -r $vic_dir/power/runtime_status || ! -r $MEM ]]; then
    die "no VIC runtime status or $MEM here"
fi
if (( fce )) && [[ ! -w $vic_dir/power/control || ! -w $MEM ]]; then
    die "no runtime power control for VIC or no writable $MEM here"
fi
# What the replayed steps need, and the settings they put back.
floor=$DEBUGFS/tegra_bwmgr/debug_client_floor
fb=$(find "$GRAPHICS"/ -maxdepth 1 -name 'fb[0-9]*' 2> /dev/null | sort | head -n 1)
mode_now() { timeout 30 nvpmodel -q < /dev/null 2> /dev/null | grep -E '^[0-9]+$' | tail -n 1; }
if want argus; then
    [[ -x $root$ARGUS ]] || die "the copy has no $ARGUS"
fi
if want emc; then
    [[ -w $floor && -r $DEBUGFS/emc/available_rates ]] || die "no memory clock floor ($floor) here"
    emc_top=$(tr ' ' '\n' < "$DEBUGFS/emc/available_rates" | grep -E '^[0-9]+$' | sort -n | tail -n 1)
    floor_was=$(cat "$floor")
    [[ -n $emc_top && $floor_was =~ ^[0-9]+$ ]] || die "cannot read the memory clock's rates or floor"
fi
if want blank; then
    [[ -n $fb && -w $fb/blank ]] || die 'no framebuffer to blank here'
fi
if want modes; then
    command -v nvpmodel > /dev/null || die 'no nvpmodel'
    mode_was=$(mode_now)
    [[ -n $mode_was ]] || die 'nvpmodel -q gave no mode'
fi

trap cleanup EXIT
trap 'exit 130' INT TERM HUP
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=$home/l4t-video-probe/$stamp-u1804
runuser -u "$user" -- mkdir -p "$home/l4t-video-probe" && mkdir "$out" || die "cannot create $out"
exec > >(trap '' INT TERM HUP; exec tee "$out/summary.txt") 2>&1
printf 'RECORD=%s\nSTART=%s\nKERNEL=%s\nROOT=%s\n' "$out" "$stamp" "$(uname -r)" "$root"
printf 'ROOT_RELEASE=%s\n' "$(cut -d, -f1-2 <<< "$release")"
printf 'ROOT_LIBC=%s\n' "$(readlink "$root/lib/aarch64-linux-gnu/libc.so.6" 2> /dev/null || echo -)"
printf 'ROOT_GSTREAMER=%s\n' "$(readlink "$root/usr/lib/aarch64-linux-gnu/libgstreamer-1.0.so.0" 2> /dev/null || echo -)"
for file in $NV_FILES; do
    if [[ -f $root$file ]]; then
        printf 'ROOT_FILE=%s bytes=%s sha256=%s\n' "$file" "$(stat -L -c %s "$root$file")" \
            "$(sha256sum < "$root$file" | cut -c1-16)"
    else
        printf 'ROOT_FILE=%s missing\n' "$file"
    fi
done
# The kernel looks in /lib/firmware, which is /usr/lib/firmware on 26.04.
short_sha() { [[ -f $1 ]] && sha256sum < "$1" | cut -c1-16; }
fw_copy=$(short_sha "$root/$VIC_FIRMWARE")
fw_this=$(short_sha "$FIRMWARE_ROOT/$VIC_FIRMWARE")
printf 'VIC_FIRMWARE copy=%s this=%s same=%s\n' "${fw_copy:--}" "${fw_this:--}" \
    "$([[ -n $fw_copy && $fw_copy == "$fw_this" ]] && echo yes || echo no)"
printf 'POWER_CYCLE=%s\n' "$( (( power_cycle )) && echo yes || echo no)"
printf 'REPLAY=%s\n' "${steps:-none}"
printf 'FALCON=%s\n' "$( (( falcon )) && echo yes || echo no)"
printf 'FCE=%s\n' "$( (( fce )) && echo yes || echo no)"
# The setting comes from the file the kernel loaded (or the copy's, when the
# copy's compiler built the reader), so the two must match.
if (( fce )) && [[ -z $fw_this || $fw_copy != "$fw_this" ]]; then
    die "--fce needs this system's VIC firmware, the same as the copy's"
fi
want emc && printf 'REPLAY_EMC top=%s floor=%s hold=%ss\n' "$emc_top" "$floor_was" "$EMC_HOLD"
want blank && printf 'REPLAY_FB=%s\n' "$fb"
want modes && printf 'REPLAY_MODE start=%s\n' "$mode_was"
printf 'BOOT_VIC_TIMEOUTS=%s%s\n' "$earlier" "$( (( earlier )) && echo ' (--after-hang: a hang below says nothing about the user space)')"
printf 'VIC_DEVICE=%s status=%s on_ms=%s\n' "${vic_dir:--}" \
    "$(cat "$vic_dir/power/runtime_status" 2> /dev/null || echo -)" "$(vic_time)"

# --- 2. The chroot, in a private mount namespace.
tmp=$(mktemp -d /var/tmp/vic-u1804.XXXXXX) || die 'cannot create a temporary folder'
chmod 700 "$tmp"
mkdir -m 1777 "$tmp/root-tmp" && mkdir -m 1777 "$tmp/root-tmp/ld" || die "cannot create folders in $tmp"
for dir in dev proc sys run tmp; do
    # Owned like the copy, so its owner can remove the copy later.
    [[ -d $root/$dir ]] || { mkdir "$root/$dir" && chown --reference="$root" "$root/$dir" \
        && printf 'MOUNT_POINT_ADDED=%s\n' "$root/$dir"; } || die "cannot create $root/$dir"
done
# Arguments: the copy, the scratch folder, the trace folder ('' for none), then
# the command. With a trace folder, the shell adds itself to the traced pids
# after the mounts and becomes the command's process (chroot and env exec it);
# event-fork adds its threads and children.
inner='root=$1 scratch=$2 trace=$3
shift 3
mount --rbind /dev "$root/dev" && mount --rbind /proc "$root/proc" && mount --rbind /sys "$root/sys" \
    && mount -t tmpfs -o mode=755 run "$root/run" && mount --bind "$scratch" "$root/tmp" \
    || { echo "vic-u1804: the mounts in the copy failed" >&2; exit 98; }
if [[ -n $trace ]]; then echo $$ > "$trace/set_event_pid"; echo 1 > "$trace/tracing_on"; fi
exec chroot "$root" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C \
    GST_REGISTRY=/tmp/registry.bin GST_DEBUG_NO_COLOR=1 "$@"'
in_root() {  # TRACE_DIR COMMAND...
    local trace=$1
    shift
    timeout -k 10 "$CASE_SECONDS" unshare --mount --propagation private \
        bash -c "$inner" vic-u1804 "$root" "$tmp/root-tmp" "$trace" "$@"
}

# --- The falcon reader (--falcon), built with this system's compiler, else
# with the copy's in the chroot (and then run there).
falcon_reader() {
    cat << 'EOF'
/* Read VIC's THI and falcon registers through MEM (normally /dev/mem), 32 bits
   at a time, only if STATUS (VIC's runtime_status) reads "active" just before.
   Prints NAME=0xVALUE lines, then one decoded line. Read-only unless FIRMWARE
   is given: then it also tells VIC's firmware where its FCE microcode is, as
   JetPack 4's kernel does at every VIC power-on (flcn.c,
   nvhost_vic_finalize_poweron) and JetPack 5's does not, and prints fce:
   lines. Usage: vic-regs MEM STATUS [FIRMWARE] */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define VIC_BASE 0x54340000UL
#define VIC_SPAN 0x2000UL
/* THI's method registers (FLCN_UCLASS_METHOD_OFFSET and _DATA), and the two
   VIC methods (NVA0B6_VIDEO_COMPOSITOR_SET_FCE_UCODE_SIZE and _OFFSET). */
#define THI_METHOD0 0x0040
#define THI_METHOD1 0x0044
#define SET_FCE_UCODE_SIZE 0x071c
#define SET_FCE_UCODE_OFFSET 0x072c
#define NONE 0xa5a5a5a5u

static const struct { const char *name; unsigned int off; } regs[] = {
	{ "thi_int_status", 0x0078 }, { "irqstat", 0x1008 }, { "irqmode", 0x100c },
	{ "irqmask", 0x1018 }, { "irqdest", 0x101c }, { "mailbox0", 0x1040 },
	{ "mailbox1", 0x1044 }, { "itfen", 0x1048 }, { "idlestate", 0x104c },
	{ "curctx", 0x1050 }, { "nxtctx", 0x1054 }, { "os", 0x1080 },
	{ "debuginfo", 0x1094 }, { "cgctl", 0x10a0 }, { "exci", 0x10d0 },
	{ "hwcfg2", 0x10f4 }, { "cpuctl", 0x1100 }, { "bootvec", 0x1104 },
	{ "hwcfg", 0x1108 }, { "dmactl", 0x110c }, { "dmatrfbase", 0x1110 },
	{ "dmatrfmoffs", 0x1114 }, { "dmatrfcmd", 0x1118 }, { "dmatrffboffs", 0x111c },
	{ "misc_cg", 0x16d0 },
};
#define NREGS (sizeof regs / sizeof regs[0])

static uint32_t value(const uint32_t *v, const char *name)
{
	for (size_t i = 0; i < NREGS; i++)
		if (!strcmp(regs[i].name, name))
			return v[i];
	return 0;
}

/* The image's header (ucode_bin_header_v1_flcn in JetPack 4's flcn.h): magic,
   version, size, the OS's header and data offsets and size, the FCE's header
   and data offsets and size. The FCE header: its microcode's offset, buffer
   size and size. Little-endian, as this CPU. */
static int fce_setup(volatile uint32_t *vic, const char *path, uint32_t dmatrfbase)
{
	uint32_t h[9], fce[3];
	long size = -1;
	FILE *fw = fopen(path, "rb");

	if (fw && !fseek(fw, 0, SEEK_END))
		size = ftell(fw);
	if (size < (long)sizeof h || fseek(fw, 0, SEEK_SET) || fread(h, sizeof h, 1, fw) != 1) {
		printf("fce: cannot read %s; nothing written\n", path);
		return 4;
	}
	if ((h[0] != 0x10de && h[0] != 0x10fe) || h[1] != 1 || h[2] > size) {
		printf("fce: %s is not a version 1 falcon image (magic 0x%x version %u size %u); nothing written\n",
		       path, h[0], h[1], h[2]);
		return 4;
	}
	if (h[6] == NONE || h[7] == 0 || h[7] == NONE || (uint64_t)h[6] + sizeof fce > (uint64_t)size
	    || fseek(fw, h[6], SEEK_SET) || fread(fce, sizeof fce, 1, fw) != 1) {
		printf("fce: %s has no FCE microcode (header 0x%x data 0x%x); nothing written\n", path, h[6], h[7]);
		return 4;
	}
	fclose(fw);
	if (fce[2] == 0 || (uint64_t)h[7] + fce[2] > (uint64_t)size) {
		printf("fce: FCE size 0x%x at 0x%x does not fit the image; nothing written\n", fce[2], h[7]);
		return 4;
	}
	/* The kernel had the falcon load its OS from the image's DMA address plus
	   the OS data offset, in 256-byte units (nvhost_flcn_load_image), so the
	   image's address follows from dmatrfbase while no job has run. */
	uint64_t base = (uint64_t)dmatrfbase << 8, image = base - (h[4] & ~0xffu);
	if (base < (h[4] & ~0xffu) || image == 0 || (image & 0xfff)) {
		printf("fce: dmatrfbase 0x%08x less the OS data offset 0x%x is no page address; nothing written\n",
		       dmatrfbase, h[4]);
		return 5;
	}
	uint32_t offset = (uint32_t)((image + h[7]) >> 8);
	printf("fce: image=0x%llx os_data=0x%x fce_header=0x%x fce_data=0x%x fce_size=0x%x\n",
	       (unsigned long long)image, h[4], h[6], h[7], fce[2]);
	vic[THI_METHOD0 / 4] = SET_FCE_UCODE_SIZE >> 2;
	vic[THI_METHOD1 / 4] = fce[2];
	vic[THI_METHOD0 / 4] = SET_FCE_UCODE_OFFSET >> 2;
	vic[THI_METHOD1 / 4] = offset;
	printf("fce: written SET_FCE_UCODE_SIZE=0x%x SET_FCE_UCODE_OFFSET=0x%x\n", fce[2], offset);
	return 0;
}

int main(int argc, char **argv)
{
	static const char *irqs[] = { "GPTMR", "WDTMR", "MTHD", "CTXSW", "HALT", "EXTERR", "SWGEN0", "SWGEN1" };
	char status[32] = "";
	uint32_t v[NREGS];
	int write = argc == 4;
	FILE *f;
	int fd;

	if (argc != 3 && argc != 4) {
		fprintf(stderr, "usage: vic-regs MEM STATUS [FIRMWARE]\n");
		return 2;
	}
	fd = open(argv[1], (write ? O_RDWR : O_RDONLY) | O_SYNC);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	volatile uint32_t *vic = mmap(NULL, VIC_SPAN, PROT_READ | (write ? PROT_WRITE : 0), MAP_SHARED, fd, VIC_BASE);
	if (vic == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	/* VIC unpowered or unclocked would make a read fault: check just before. */
	f = fopen(argv[2], "r");
	if (!f || !fgets(status, sizeof status, f) || strcmp(status, "active\n")) {
		printf("skipped: VIC status %s\n", status[0] ? strtok(status, "\n") : "unreadable");
		return 3;
	}
	fclose(f);
	for (size_t i = 0; i < NREGS; i++)
		v[i] = vic[regs[i].off / 4];
	for (size_t i = 0; i < NREGS; i++)
		printf("%s=0x%08x\n", regs[i].name, v[i]);
	uint32_t cpuctl = value(v, "cpuctl"), irq = value(v, "irqstat");
	printf("decoded: cpu=%s idle=%s dma=%s irq=[", cpuctl & 0x20 ? "stopped" : cpuctl & 0x10 ? "halted" : "running",
	       value(v, "idlestate") & 1 ? "busy" : "idle", value(v, "dmatrfcmd") & 2 ? "idle" : "busy");
	for (int b = 0; b < 8; b++)
		if (irq & (1u << b))
			printf(" %s", irqs[b]);
	printf(" ] exci=0x%08x mailbox0=0x%08x mailbox1=0x%08x os=0x%08x\n", value(v, "exci"),
	       value(v, "mailbox0"), value(v, "mailbox1"), value(v, "os"));
	return write ? fce_setup(vic, argv[3], value(v, "dmatrfbase")) : 0;
}
EOF
}
falcon_run=() falcon_fw=''
if (( falcon )); then
    falcon_reader > "$tmp/root-tmp/vic-regs.c"
    for cc in cc gcc gcc-15 gcc-14 gcc-13 gcc-12 gcc-11; do
        if command -v "$cc" > /dev/null && "$cc" -O2 -o "$tmp/vic-regs" "$tmp/root-tmp/vic-regs.c" 2> "$out/falcon-build.txt"; then
            falcon_run=("$tmp/vic-regs" "$MEM" "$vic_dir/power/runtime_status")
            falcon_fw=$FIRMWARE_ROOT/$VIC_FIRMWARE
            printf 'FALCON_READER=built with %s\n' "$cc"
            break
        fi
    done
    if (( ${#falcon_run[@]} == 0 )) && in_root '' gcc -O2 -o /tmp/vic-regs /tmp/vic-regs.c >> "$out/falcon-build.txt" 2>&1; then
        falcon_run=(in_root '' /tmp/vic-regs "$MEM" "$vic_dir/power/runtime_status")
        falcon_fw=/$VIC_FIRMWARE
        printf 'FALCON_READER=built with the copy'"'"'s gcc\n'
    fi
    (( ${#falcon_run[@]} )) || { head -n 5 "$out/falcon-build.txt"; die 'no compiler built the falcon reader'; }
fi
falcon_reads=0
falcon_read() {  # LABEL
    local file
    file=$out/falcon-$(( ++falcon_reads )).txt
    echo "label: $1" > "$file"
    sync
    "${falcon_run[@]}" >> "$file" 2>&1
    printf 'FALCON %s: %s\n' "$1" "$(grep -E '^(decoded|skipped|usage)|rror|denied|ermitted' "$file" | head -n 1)"
}
fce_setup() {  # the reader with the firmware file: it reads VIC, then writes the two FCE methods
    local file rc
    file=$out/falcon-$(( ++falcon_reads )).txt
    echo 'label: FCE setup' > "$file"
    sync
    "${falcon_run[@]}" "$falcon_fw" >> "$file" 2>&1
    rc=$?
    grep -E '^(fce|skipped|usage)|rror|denied|ermitted' "$file" | sed 's/^/FCE /'
    (( rc == 0 )) || die "the FCE setup wrote nothing (reader exit $rc)"
}

# --- 3. GStreamer as root (this also builds the registry).
in_root '' gst-inspect-1.0 nvvidconv > "$out/inspect.txt" 2>&1
status=$?
if (( status == 0 )) && grep -q 'Factory Details' "$out/inspect.txt"; then
    grep -E '^ +(Filename|Version) ' "$out/inspect.txt" | sed -E 's/^ +/inspect: /'
    printf 'INSPECT=PASS\n'
else
    head -n 5 "$out/inspect.txt" | sed 's/^/inspect: /'
    die "GStreamer in the copy did not load nvvidconv (exit $status)"
fi
if grep -qs " $root/" /proc/self/mountinfo; then
    die "something of $root is still mounted here"
fi

# --- Trace events for the converter's ioctl requests (trial 36's method).
for dir in /sys/kernel/tracing /sys/kernel/debug/tracing; do
    if [[ -d $dir/events/syscalls/sys_enter_ioctl ]]; then
        tracefs=$dir
        break
    fi
done
trace_off() {
    echo 0 > "$tracefs/tracing_on"
    echo 0 > "$tracefs/events/syscalls/sys_enter_ioctl/enable"
    echo 0 > "$tracefs/events/syscalls/sys_exit_ioctl/enable"
    echo > "$tracefs/set_event_pid"
    echo 0 > "$tracefs/options/event-fork"
}
if [[ -n $tracefs ]]; then
    tracing_was=$(cat "$tracefs/tracing_on")
    printf 'IOCTL_TRACE=%s\n' "$tracefs"
else
    printf 'IOCTL_TRACE=none (no syscall trace events)\n'
fi
# The trace summary of jp5-trial-check.sh (trial 36), as in vic-compare.sh:
# each request number's calls and errors, the first failed calls and the last
# calls.
ioctl_summary() {
    awk '
    function hex(h,   i, v) {
        v = 0
        for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
        return v
    }
    /entries-in-buffer/ { print "ioctl trace: entries-in-buffer/entries-written " $3; next }
    /^#/ { next }
    match($0, /-[0-9]+ +\[[0-9]+\]/) {
        tid = substr($0, RSTART + 1, RLENGTH - 1); sub(/ .*/, "", tid)
        comm = substr($0, 1, RSTART - 1); sub(/^ +/, "", comm)
        ts = $0; sub(/: sys_ioctl.*/, "", ts); sub(/.* /, "", ts)
        if (index($0, "sys_ioctl(")) {
            x = $0; sub(/.*sys_ioctl\(fd: /, "", x)
            fd[tid] = x; sub(/,.*/, "", fd[tid])
            cmd[tid] = x; sub(/.*cmd: (0x)?/, "", cmd[tid]); sub(/,.*/, "", cmd[tid])
            # A request number passed as a signed int arrives sign-extended.
            if (length(cmd[tid]) == 16 && substr(cmd[tid], 1, 8) == "ffffffff") cmd[tid] = substr(cmd[tid], 9)
            next
        }
        if (!index($0, "sys_ioctl -> 0x") || !(tid in cmd)) next
        r = $0; sub(/.*sys_ioctl -> 0x/, "", r)
        neg = length(r) == 16 && substr(r, 1, 8) == "ffffffff"
        ret = neg ? -(4294967296 - hex(substr(r, 9, 8))) : hex(r)
        c = cmd[tid]
        if (!(c in calls)) order[++ncmds] = c
        calls[c]++; total++
        line = ts " " comm " fd=" fd[tid] " cmd=" c " ret=" ret
        if (neg) {
            nfail++
            if (!((c, ret) in seen)) errs[c] = errs[c] " " ret
            if (++seen[c, ret] <= 3 && ++shown <= 30) print "ioctl failed: " line
        }
        last[total % 12] = line
        delete cmd[tid]
    }
    END {
        printf "ioctl trace: %d calls, %d failed\n", total, nfail
        for (i = 1; i <= ncmds; i++)
            print "ioctl cmd=" order[i] " calls=" calls[order[i]] (errs[order[i]] == "" ? "" : " errors:" errs[order[i]])
        for (i = (total > 12 ? total - 11 : 1); i <= total; i++) print "ioctl last: " last[i % 12]
    }' "$1"
}
# The display driver's requests in a summary: tegra_dc's 'C' (control node)
# and 'D' (a head), and the framebuffer's 'F', by the request's type byte.
display_requests() {
    awk '/^ioctl cmd=/ {
        c = $2; sub(/^cmd=/, "", c); n = $3; sub(/^calls=/, "", n)
        t = length(c) >= 4 ? substr(c, length(c) - 3, 2) : ""
        if (t == "43" || t == "44" || t == "46") total += n
    } END { print total + 0 }' "$1"
}

# --- 4 to 6. The steps before the case.
vic_status() { cat "$vic_dir/power/runtime_status" 2> /dev/null || echo -; }
wait_status() {  # STATUS SECONDS: until VIC's runtime status is STATUS, at most SECONDS
    local end=$(( SECONDS + $2 ))
    until [[ $(vic_status) == "$1" ]] || (( SECONDS >= end )); do sleep 0.2; done
}
clk() { cat "$DEBUGFS/clk/$1/clk_rate" 2> /dev/null || echo -; }
state() {  # LABEL: the memory clock and its floor, VIC's clocks and power, the power mode
    local mode
    mode=$(mode_now)
    printf '%s: emc=%s bwmgr=%s floor=%s iso_cap=%s vic03=%s c2bus=%s vic=%s on_ms=%s mode=%s cpus=%s\n' "$1" \
        "$(clk emc)" "$(cat "$DEBUGFS/tegra_bwmgr/emc_rate" 2> /dev/null || echo -)" \
        "$(cat "$floor" 2> /dev/null || echo -)" "$(cat /sys/kernel/nvpmodel_emc_cap/emc_iso_cap 2> /dev/null || echo -)" \
        "$(clk vic03)" "$(clk c2bus)" "$(vic_status)" "$(vic_time)" "${mode:--}" \
        "$(cat /sys/devices/system/cpu/online 2> /dev/null || echo -)"
}
# The copy's camera daemon in the chroot, in the background until after the
# case (the shell becomes the daemon, as in in_root).
replay_argus() {
    local before devices
    before=$(vic_time)
    unshare --mount --propagation private bash -c "$inner" vic-u1804 "$root" "$tmp/root-tmp" '' "$ARGUS" \
        > "$out/argus.log" 2>&1 &
    argus_pid=$!
    sleep 5
    if alive "$argus_pid"; then
        # Seen from here, the device nodes it opened are under the copy's dev.
        devices=$(find "/proc/$argus_pid/fd" -mindepth 1 -maxdepth 1 -exec readlink {} + 2> /dev/null |
            awk -v d="$root/dev/" 'index($0, d) == 1 { print "/dev/" substr($0, length(d) + 1) }' | sort | uniq -c |
            awk '{ printf "%s%s", sep, $2 ($1 > 1 ? " x" $1 : ""); sep = ", " }')
        printf 'REPLAY argus: running pid=%s holds: %s\n' "$argus_pid" "${devices:-no device}"
    else
        wait "$argus_pid"
        printf 'REPLAY argus: exited (%s) within 5 s\n' "$?"
        argus_pid=''
    fi
    printf 'REPLAY argus: vic=%s on_ms=+%s\n' "$(vic_status)" "$(( $(vic_time) - before ))"
    head -n 6 "$out/argus.log" | cut -c1-200 | sed 's/^/REPLAY argus: LOG: /'
}
replay_emc() {
    state 'REPLAY emc before'
    echo "$emc_top" > "$floor" || die 'cannot set the memory clock floor'
    floor_restore=$floor_was
    sleep 2
    state "REPLAY emc floor $emc_top"
    sleep "$EMC_HOLD"
    state "REPLAY emc after ${EMC_HOLD} s"
    echo "$floor_was" > "$floor" || die "cannot set the memory clock floor back to $floor_was"
    floor_restore=''
    sleep 2
    state "REPLAY emc floor back to $floor_was"
}
replay_blank() {
    local blank=ok unblank=ok
    if systemctl is-active --quiet display-manager 2> /dev/null; then
        printf 'REPLAY blank: skipped, the display manager is running\n'
        return
    fi
    state 'REPLAY blank before'
    sync
    echo 4 > "$fb/blank" || blank=failed
    blank_restore=1
    sleep 2
    echo 0 > "$fb/blank" || unblank=failed
    [[ $unblank == ok ]] && blank_restore=''
    sleep 2
    printf 'REPLAY blank: %s blank=%s unblank=%s mode=%s\n' "${fb##*/}" "$blank" "$unblank" \
        "$(head -n 1 "$fb/mode" 2> /dev/null || echo -)"
    state 'REPLAY blank after'
}
replay_modes() {
    local m
    state 'REPLAY modes before'
    mode_restore=$mode_was
    for m in 1 0; do
        timeout 60 nvpmodel -m "$m" < /dev/null >> "$out/nvpmodel.txt" 2>&1
        printf 'REPLAY modes: nvpmodel -m %s exit=%s\n' "$m" "$?"
        sleep 2
        state "REPLAY modes after -m $m"
    done
    if [[ $mode_was != 0 ]]; then
        timeout 60 nvpmodel -m "$mode_was" < /dev/null >> "$out/nvpmodel.txt" 2>&1
        printf 'REPLAY modes: back to mode %s exit=%s\n' "$mode_was" "$?"
    fi
    [[ $(mode_now) == "$mode_was" ]] && mode_restore=''
}
name=u1804
(( power_cycle )) && name+=-cycled
[[ -n $steps ]] && name+=-replay-${steps//,/-}
(( fce )) && name+=-fce
replay_since=$(date +%s)
want argus && replay_argus
if (( power_cycle )); then
    sleep 2
    cycle_since=$(date +%s)
    cycle_before=$(vic_time)
    control_was=$(cat "$vic_dir/power/control")
    echo on > "$vic_dir/power/control" || die "cannot set VIC's power control"
    wait_status active 10
    printf 'POWER_CYCLE on: control=%s status=%s\n' "$(cat "$vic_dir/power/control")" "$(vic_status)"
    sleep 1
    (( falcon )) && falcon_read 'held on, no job'
    echo "$control_was" > "$vic_dir/power/control" || die "cannot set VIC's power control back to $control_was"
    control_was=''
    wait_status suspended 30
    printf 'POWER_CYCLE back: control=%s status=%s on_ms=%s\n' "$(cat "$vic_dir/power/control")" "$(vic_status)" \
        "$(( $(vic_time) - cycle_before ))"
    sleep 1
    journalctl -k --since "@$cycle_since" --no-pager -o short-monotonic > "$out/power-cycle-kernel.txt" 2>&1
    grep -iE "$FILTER" "$out/power-cycle-kernel.txt" | head -n 8 | cut -c1-200 | sed 's/^/power-cycle: KERNEL: /'
fi
want emc && replay_emc
want blank && replay_blank
want modes && replay_modes
if [[ -n $steps ]]; then
    sleep 1
    journalctl -k --since "@$replay_since" --no-pager -o short-monotonic > "$out/replay-kernel.txt" 2>&1
    printf 'REPLAY kernel lines: %s, VIC job timeouts: %s\n' "$(grep -vc '^-- ' "$out/replay-kernel.txt")" \
        "$(grep -c 'cdma_handle_timeout' "$out/replay-kernel.txt")"
    grep -iE "$FILTER" "$out/replay-kernel.txt" | grep -vE "$DUMP" | head -n 12 | cut -c1-200 |
        sed 's/^/REPLAY KERNEL: /'
fi

# --fce: VIC held on, its firmware told where its FCE microcode is, and kept on
# through the case.
if (( fce )); then
    sleep 2
    control_was=$(cat "$vic_dir/power/control")
    echo on > "$vic_dir/power/control" || die "cannot set VIC's power control"
    wait_status active 10
    printf 'FCE hold: control=%s status=%s\n' "$(cat "$vic_dir/power/control")" "$(vic_status)"
    sleep 1
    falcon_read 'held on, before the FCE setup'
    fce_setup
    sleep 1
    falcon_read 'after the FCE setup'
fi

# --- 7. The case, with the memory and VIC clocks sampled.
sample_clocks() { while :; do echo "$(clk emc) $(clk vic03)"; sleep 0.5; done; }
counts() { awk -v k="$1" '{ print $k }' "$2" | sort -n | uniq -c | awk '{ printf "%s:%s ", $2, $1 }'; }
pipeline=(videotestsrc num-buffers=2 ! 'video/x-raw,width=1280,height=720,format=I420' ! nvvidconv
          ! 'video/x-raw(memory:NVMM),format=NV12' ! nvvidconv ! 'video/x-raw,format=I420' ! fakesink)
sleep 2  # the earlier kernel lines stay before the case's start
state 'STATE before case'
since=$(date +%s)
vic_before=$(vic_time)
sample_clocks > "$out/$name-clocks.txt" &
sampler_pid=$!
if (( falcon )); then
    { sleep 6; falcon_read 'case 6 s'; sleep 10; falcon_read 'case 16 s'; } > "$out/falcon-case.txt" 2>&1 &
    watcher_pid=$!
fi
if [[ -n $tracefs ]]; then
    trace_off
    echo > "$tracefs/trace"
    echo 1 > "$tracefs/options/event-fork"
    echo 1 > "$tracefs/events/syscalls/sys_enter_ioctl/enable"
    echo 1 > "$tracefs/events/syscalls/sys_exit_ioctl/enable"
fi
began=$SECONDS
in_root "$tracefs" LD_DEBUG=libs,files LD_DEBUG_OUTPUT=/tmp/ld/ld \
    gst-launch-1.0 -q "${pipeline[@]}" > "$out/$name.log" 2>&1
status=$?
seconds=$(( SECONDS - began ))
{ kill "$sampler_pid"; wait "$sampler_pid"; } 2> /dev/null
sampler_pid=''
if [[ -n $watcher_pid ]]; then
    { kill "$watcher_pid"; wait "$watcher_pid"; } 2> /dev/null
    watcher_pid=''
fi
display=-
if [[ -n $tracefs ]]; then
    trace_off
    cp "$tracefs/trace" "$out/$name-ioctl-trace.txt"
    echo > "$tracefs/trace"
    ioctl_summary "$out/$name-ioctl-trace.txt" > "$out/$name-ioctl.txt"
    display=$(display_requests "$out/$name-ioctl.txt")
fi
sleep 2
journalctl -k --since "@$since" --no-pager -o short-monotonic > "$out/$name-kernel.txt" 2>&1
timeouts=$(grep -c 'cdma_handle_timeout' "$out/$name-kernel.txt")
if (( status == 0 && timeouts == 0 )); then
    result=PASS
elif (( timeouts > 0 )); then
    result=HANG
else
    result=FAIL
fi
printf 'CASE %s result=%s exit=%s seconds=%s timeouts=%s vic_on_ms=%s display_requests=%s\n' "$name" "$result" \
    "$status" "$seconds" "$timeouts" "$(( $(vic_time) - vic_before ))" "$display"
printf '%s: CLOCKS samples=%s emc=[ %s] vic03=[ %s]\n' "$name" "$(grep -c . "$out/$name-clocks.txt")" \
    "$(counts 1 "$out/$name-clocks.txt")" "$(counts 2 "$out/$name-clocks.txt")"
if (( falcon )); then
    sed "s/^/$name: /" "$out/falcon-case.txt"
    grep -q . "$out/falcon-case.txt" || printf '%s: FALCON no read (the case ended first)\n' "$name"
fi
if (( fce )); then
    echo "$control_was" > "$vic_dir/power/control" || die "cannot set VIC's power control back to $control_was"
    printf 'FCE hold end: control=%s\n' "$control_was"
    control_was=''
fi
state 'STATE after case'
if [[ -n $argus_pid ]]; then
    printf 'REPLAY argus at the end: %s\n' "$(alive "$argus_pid" && echo running || echo exited)"
    stop_argus
    tail -n 4 "$out/argus.log" | cut -c1-200 | sed 's/^/REPLAY argus: LOG END: /'
fi
head -n 8 "$out/$name.log" | cut -c1-200 | sed "s/^/$name: OUTPUT: /"
# The libraries the converter loaded, and every library a process asked for
# (linked or dlopened) that the linker never mapped. Paths are the copy's.
awk '
    /file=.*;  (dynamically loaded|needed) by / {
        n = $0; sub(/.*file=/, "", n); sub(/ .*/, "", n)
        b = $0; sub(/.* by /, "", b); sub(/ \[.*/, "", b)
        asked[FILENAME, n] = b
    }
    /file=.*;  generating link map/ { n = $0; sub(/.*file=/, "", n); sub(/ .*/, "", n); mapped[FILENAME, n] = 1 }
    END { for (k in asked) if (!(k in mapped)) { split(k, p, SUBSEP); print p[2] " (by " asked[k] ")" } }
' "$tmp/root-tmp/ld"/ld.* 2> /dev/null | sort -u > "$out/$name-not-loaded.txt"
cat "$tmp/root-tmp/ld"/ld.* 2> /dev/null > "$out/$name-ld.txt"
grep -oE 'calling init: /[^ ]+' "$out/$name-ld.txt" | sed 's/^calling init: //' | sort -u > "$out/$name-loaded.txt"
printf '%s: LOADED_COUNT: %s\n' "$name" "$(wc -l < "$out/$name-loaded.txt")"
grep -E "$LIBS_SHOWN" "$out/$name-loaded.txt" | head -n 40 | sed "s/^/$name: LOADED: /"
head -n 12 "$out/$name-not-loaded.txt" | sed "s/^/$name: NOT_LOADED: /"
if [[ -n $tracefs ]]; then
    grep -E '^ioctl (trace: [0-9]|failed|cmd=)' "$out/$name-ioctl.txt" | head -n 60 | sed "s/^/$name: /"
fi
grep -iE "$FILTER" "$out/$name-kernel.txt" | grep -vE "$DUMP" | head -n 8 | cut -c1-200 | sed "s/^/$name: KERNEL: /"
if grep -qs " $root/" /proc/self/mountinfo; then
    printf 'WARNING: something of %s is still mounted here\n' "$root"
fi
printf 'MATRIX %s=%s\n' "$name" "$result"
printf 'VIC_U1804=DONE %s=%s record=%s\n' "$name" "$result" "$out"

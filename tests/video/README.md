# Video validation

`frame_check.py` compares raw I420 or RGBA frames written by GStreamer's
`filesink` against a reference, plane by plane: the frame counts must match,
and up to six frames spread over the file must reach a given PSNR on every
plane (alpha excluded). An output that is flat where the reference varies
fails too. Pure Python, no NumPy. The last line is `FRAME_CHECK=PASS` or
`FRAME_CHECK=FAIL`.

`scripts/jetson/probe-l4t-video.sh` uses it on the Nano to check JetPack 5's
(L4T R35.6) or JetPack 4's (L4T R32.7.6) video converter, `nvvidconv`,
through the VIC and through CUDA (`compute-hw=GPU`): a round trip into NVMM buffers (40 dB), BT.601 colour
conversion against GStreamer's `videoconvert` (30 dB) and bilinear scaling
against `videoscale` (20 dB). With `KEEP_FRAMES=1` it keeps the compared
frames in its record folder. It lists `nvvidconv`'s properties and its
`interpolation-method` values. With `INTERPOLATION_SWEEP=all` (or a list
of values) it repeats the VIC path's colour and scale tests with each
value, for the record, and prints one `SWEEP_COLOUR` and one `SWEEP_SCALE`
line for each. With `--installed` it tests the installed `nano-l4t-r32-video`
package (JetPack 4's converter in its own folder) instead of a scratch
folder, starting every run through `nano-r32-video`. With `--installed r35`
it tests `nano-l4t-r35-video` (JetPack 5's converter with the VIC fix below)
the same way through `nano-r35-video`, and adds step 9, `vic_cuda.py`.

`colour_fit.py` explains a failed colour check. It converts the test's
first I420 input frame to RGB in software under 19 models and prints the
five that fit the output best: chroma repeated to full size (as
`videoconvert` does for this test; GStreamer 1.24 ignores its
`chroma-resampler` and `chroma-mode` settings here) and moved by up to two
pixels across and a row up or down, linear chroma sited centred or
cosited, and BT.709 or full range instead of limited BT.601. The probe
runs it whenever a colour check fails. `videoconvert`'s own output fits
its model at about 40 dB, not exactly, because it rounds differently; a
one-frame lag or swapped U and V fits no model. It then shows where the
best model still misses: how many pixels are off by how much (worst
channel), and for those off by 64 or more, how many sit on even and odd
columns and which column and row ranges hold the most. A dead band of
columns or a bad edge shows up as one short column range; errors on every
bar edge show up as several.

`colour_fit.py --check DX MIN_PSNR FRAMES ...` tests one model, nearest
chroma moved DX pixels across with BT.601, on each compared frame. The
probe passes a colour check that fails against `videoconvert` if it passes
`--check 1 40`: on the Nano (build #35) VIC takes each odd pixel's chroma
from the sample to its right, where `videoconvert` takes the left one, and
VIC's output fits that model at 53 dB and `videoconvert`'s at 26.

`vic_record.c` is an `LD_PRELOAD` shim that records the jobs a converter
hands VIC, and `vic_jobs.py` reads them. With `VIC_RECORD=1` the probe
builds the shim and runs three two-frame conversions under it (colour, and
scaling with `interpolation-method` 0 and 1) into its record's `vic-jobs`
folder. For each job submitted to the VIC channel, before passing it on,
the shim saves the request, its command buffers and every buffer the job
points at up to 256 KiB each (VIC's settings and filter blocks; pictures
are listed by size), read through a `/dev/nvmap` client of its own; it
changes nothing. `vic_jobs.py show` decodes each job's host1x commands
into VIC's methods, and `vic_jobs.py compare` sets two converters' jobs
side by side: methods whose values differ, methods only one sets, and the
differing words of each settings block both point at with the same
method. It names the methods the kernel or libdrm's VIC 4.0 test header
(`tests/tegra/vic40.h`) names, not the settings fields.

With `VIC_PATCH` (groups such as `gamma`, or `each`; listed in
`vic_record.c`) the shim also sets some of the settings block's fields to
JetPack 4's values in every VIC job, before the job goes to VIC, writing
through `NVMAP_IOC_WRITE` and reading the words back. The fields are those
of VIC 4.0's `ConfigStruct` in libdrm's `tests/tegra/vic40.h`, where
JetPack 5's converter differs from JetPack 4's (2026-10-17 recording). The
probe's step 8 reruns the VIC path's colour and scale tests with no group
and then with each group, one `PATCH_COLOUR` and one `PATCH_SCALE` line a
group. Only the converter's own jobs change; no file does. On the Nano
(2026-10-17) turning gamma off fixed JetPack 5's colour and turning off the
round trip through RGB fixed its scaling, and `chromaloc` gave odd rows
their own row pair's chroma (seen only by `vic_cuda.py`, which compares
every row); the `fix` group does all three, and
`VIC_PATCH_RUNS=fix` runs every check of steps 3 to 6 with it. With
`VIC_PATCH` and no `VIC_RECORD_DIR` the shim only patches and writes
nothing; `nano-l4t-r35-video` carries it built for arm64 as `vic_patch.so`,
and its launcher preloads it with `VIC_PATCH=fix`. A program can read its
job counts through `vic_patch_counts()`.

`vic_cuda.py` is one program that uses JetPack 5's converter and CUDA 11.4
together, run as `nano-r35-video python3 -I vic_cuda.py`. It makes a CUDA
context and JIT-compiles a kernel first, then runs a GStreamer pipeline
(through ctypes, no GStreamer Python bindings) that keeps each 1280x720
I420 test frame and also converts it on VIC to RGBA in NVMM buffers and
back. Each pair goes to the GPU, where the kernel from `row_sse.c` sums each
channel's squared error of VIC's RGBA against BT.601 with VIC's chroma
placement (the `--check 1` model, in integer arithmetic), row by row. The
CPU repeats 16 rows of each frame and must get the same sums, every
channel must reach 40 dB, the fix must have patched jobs with none
failing, and only one `libcuda` may be mapped. `row_sse.c` builds as PTX
for sm_53 with clang 18, as `vic_cuda.py` carries it, and for the host;
the host build runs the kernel's rows in a stand-in `libcuda` for tests.
Frames reach CUDA through a copy in host memory, not as NVMM buffers.
`--context` picks the CUDA context: the primary context (the default, as
CUDA's runtime uses), one of its own current while the pipeline starts
(which the converter destroyed on the Nano), one of its own current only
around the CUDA calls, or one made after the first frames; `CONTEXT_STATE`
lines show whether it survived the pipeline's start and stop. It compares
every row, where `colour_fit.py --check` samples every eighth: each `FRAME`
line gives the rows below the threshold, and `ROW_DETAIL` and `LOW_ROWS`
say where they miss. `--chroma-down 1` has odd rows take the next row
pair's chroma, as JetPack 5's converter does on the Nano without the
`chromaloc` group.

`scripts/jetson/probes/vic-compare.sh` (with sudo) runs that probe and then two
frames through VIC as the ordinary account and as root, in trial 36's
pipeline and the probe's, and with `--stop-desktop` again with the display
manager stopped. It records each run's kernel job timeouts, VIC clocks and
ioctl requests; it does not check the pictures.

`scripts/jetson/probes/vic-r32-display.sh` (with sudo, right after a restart)
runs JetPack 4's converter through VIC with NVIDIA's own `libdrm.so.2` and
`libgbm.so.1`, which the probe sets aside, and then as the probe runs it.
It records the same as `vic-compare.sh`, plus the display requests and the
libraries the converter loaded or could not find.

`scripts/jetson/probes/vic-u1804.sh ROOT_DIR` (with sudo, right after a restart)
runs the same converter from Ubuntu 18.04's own user space, a copy of the
18.04 root taken from a backup of the card, in a chroot on the 26.04 boot, and
records the same as `vic-r32-display.sh`. With `--power-cycle` it first
powers VIC on once with no job and lets it suspend. With `--replay=STEPS`
(`argus`, `emc`, `blank`, `modes`, or `all`) it first repeats what trial
39's check script did before its VIC step. Those are the camera daemon, the
memory clock floor, a framebuffer blank and nvpmodel's 5W and MAXN, and
each goes back as it was afterwards. Every run records the memory and VIC
clocks before, during and after the case. With `--falcon` it reads VIC's
falcon and host-interface registers (read-only, through `/dev/mem`, only
while VIC is on) during the power cycle's hold and during the case. With
`--fce` it also holds VIC on before the case and writes the two methods
that tell VIC's firmware where its FCE microcode is, as JetPack 4's kernel
does at every VIC power-on and JetPack 5's does not; VIC stays on through
the case.

The thresholds come from software conversions on a host (GStreamer 1.24,
the moving SMPTE pattern the probe uses):

| Difference from the reference | Worst plane |
| --- | --- |
| BT.709 matrix instead of BT.601 | 21.7 dB |
| Full range instead of limited | 24.9 dB |
| One frame late (colour test) | 15.0 dB |
| Nearest-neighbour instead of bilinear scaling | 25.2 dB |
| One frame late (scale test) | 21.5 dB |
| U and V planes swapped | 8.4 dB |
| Rows read with the wrong stride | 7.9 dB |
| All black | 2.8 dB |
| Odd pixels' chroma from the right (VIC on the Nano, colour test) | 25.9 dB |

A pass on a host is a test of the probe, not of the Nano's VIC or GPU.

## Hardware codecs

`scripts/jetson/probes/probe-l4t-codec.sh INPUTS_DIR` tries the Nano's video
decoder (NVDEC), encoder (NVENC) and JPEG engine (NVJPG) on Ubuntu 26.04
with JetPack 4's GStreamer elements (L4T R32.7.6), unpacked into a scratch
folder from the debs `fetch-r35-cuda.py --set video --release r32.7` wrote,
as `probe-l4t-video.sh` does. It needs build #36's device tree, which turns
the three engines on. H.264 and H.265 decoding must match libav's frame for
frame (or, through JetPack 4's `nvvidconv`, match in Y with the colour
within 1 of libav's moved half a row in every frame), encoding must decode
back to the pattern
at 30 dB, and JPEG decoding
must reach 40 dB against `jpegdec`. It also times each decoder and encoder
against the software ones, decodes a webcam's MJPEG when one is plugged in,
and records which engine powered up for each run. The script's header lists
every step.

`frame_hashes.py` hashes raw I420 frames as they stream from `filesink`
through a FIFO, so a 300-frame 1080p decode needs no disk space, and
compares two hash lists frame by frame (`--compare`). It also hashes Y
alone, so a comparison can say whether the luma is identical, and it can
save the reference's U and V rows averaged in pairs (`save-rows`) and check
an output against them as it streams (`check-rows`): a converter that
moves the colour half a row, as JetPack 4's `nvvidconv` does, passes when
every value is within 1 of that average, and the comparison counts the
halves it rounded each way and any other value off (`MATCH`). It keeps the
first frames for `frame_check.py` and `frame_diff.py` when the hashes
differ.

`frame_diff.py` describes how a decoder's frames differ from the
reference, for a failed decode: each plane's PSNR for a few frames, the
reference frame each output frame fits best (a dropped or reordered
frame), the whole-pixel move of the picture that fits best (a crop), each
output plane fitted as a mix of the reference's Y, U and V plus a constant
(a colour matrix or range conversion fits closely, a decoding error does
not), the mean difference, how many values are off by how much, and the
error over a grid of the picture. For the colour it fits each output U and
V value to the reference's 3x3 neighbourhood (a converter's filter shows as
its taps) and counts exact matches with the colour moved half a row each
way. It can also write the first frame's Y as
a PNG: reference, output and four times the difference.

`v4l2_plugin_dir.c` is an `LD_PRELOAD` shim for the codec elements. JetPack
4's codec elements reach the engines through a libv4l2 plugin,
`libv4l2_nvvideocodec.so`, which libv4l2 looks for with `glob()` in a fixed
folder under `/usr/lib`. With `V4L2_PLUGIN_DIR` set, the shim looks in that
folder instead, silently: `nano-l4t-r32-video` carries the shim and its
launcher, `nano-r32-video`, points it at the package's `libv4l2-plugins`
folder. Otherwise, with `V4L2_PLUGIN_ROOT` set, it looks under that root
(the probe's scratch folder) and prints a `V4L2_PLUGIN_DIR` line. Every
other `glob()` is passed on unchanged.

Given JetPack 5's video set (`~/r35-video-inputs-2`, from
`fetch-r35-cuda.py --set video`), the probe tries JetPack 5's elements
(L4T R35.6) the same way, which NVIDIA never released for the Nano. Their
other NVIDIA libraries may come from the installed R35.6 driver set, and
every run also preloads `vic_record.c` with the VIC fix (`VIC_PATCH=fix`),
which counts the jobs it patched and lists any nvhost or nvmap request the
kernel refused (`NVHOST_FAILED`).

`crash_trace.c` is an `LD_PRELOAD` shim the codec probe preloads in its
scratch runs: when a program dies of a signal, it prints the faulting
address, the program counter and link register as a library and offset,
the registers and a backtrace (`CRASH` lines), then lets the signal act.
JetPack 5's H.264 encoder died of SIGSEGV on the Nano; `CODEC_STEPS=encode`
and `H264_ENC_VARIANTS` repeat just that step with other encoder settings.
It crashed the same way under every setting tried (2026-10-23), so with
JetPack 5's elements the probe skips H.264 encoding (`ENCODE_H264=skipped`)
unless `R35_H264=1`.

`strace_diff.py` reads the system-call logs the codec probe writes with
`CODEC_STRACE=1` (each NVIDIA run under `strace -f -y`, file, ioctl and mmap
calls). `summary` counts a run's failed calls by error and, when a thread
died of a signal, prints the last calls that thread made. `diff` lists the
calls that failed in one run and never in another, and the files only the
first opened: after step 4 the probe sets the H.264 encoder's run against
the H.265 one's, to show what the crashing encoder asks of the system (a
file, a device request) that the working one does not. Pure Python.

`probe-l4t-codec.sh --installed` runs the same steps on the installed
`nano-l4t-r32-video` (+u26.2 or later, built by
`build-nano-l4t-debs.py --set video`), starting every NVIDIA run through
`nano-r32-video`: every NVIDIA library must come from the package's folder,
and nothing is unpacked or compiled. `--installed r35` does the same with
`nano-l4t-r35-video` (+u26.3 or later, which carries JetPack 5's codec
elements) through `nano-r35-video`, whose other NVIDIA libraries may come
from the installed R35.6 driver set.

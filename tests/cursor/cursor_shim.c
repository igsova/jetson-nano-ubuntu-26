/*
 * LD_PRELOAD shim for the X server that logs, and optionally changes, the
 * cursor images NVIDIA's X driver hands tegradc (TEGRA_DC_EXT_SET_CURSOR_IMAGE,
 * R35's include/uapi/video/tegra_dc_ext.h). Used by
 * scripts/jetson/probes/probe-hw-cursor-image.sh to find out why JetPack 5's hardware
 * mouse pointer is invisible on the Nano's 5.10 kernel.
 *
 * It also logs the other cursor calls: ownership (GET/PUT_CURSOR), clipping
 * and each change of the pointer's visibility (SET_CURSOR).
 *
 * Environment:
 *   CURSOR_SHIM_DIR   folder for log.txt and the first images of each mode
 *   CURSOR_SHIM_MODE  file holding the mode, read at every cursor image:
 *     log    pass the image on unchanged (also any mode starting with "log",
 *            such as log-unity, which starts a new set of saved images)
 *     sync   write the CPU caches back for the image first (DMA_BUF_IOCTL_SYNC)
 *     flags  mark a 32-bit image as premultiplied RGBA (tegradc's t21x code
 *            takes the blend mode from these flags), and sync
 *     rgba   also move each pixel's alpha from the top byte to the low byte
 *            (the header: "RGBA cursor: ... alpha in the low eight bits"),
 *            and sync
 *
 * Build: gcc -O2 -Wall -shared -fPIC -o cursor_shim.so cursor_shim.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <linux/ioctl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* R35's struct tegra_dc_ext_cursor_image, 28 bytes. */
struct cursor_image {
	struct {
		uint8_t r, g, b;
	} foreground, background;
	int32_t buff_id;
	uint32_t flags;
	int16_t x, y;
	uint32_t alpha;
	uint32_t colorfmt;
};
_Static_assert(sizeof(struct cursor_image) == 28, "tegra_dc_ext_cursor_image layout");

#define GET_CURSOR_NR 0x04
#define PUT_CURSOR_NR 0x05
#define SET_CURSOR_IMAGE_NR 0x06
#define SET_CURSOR_NR 0x07
#define CURSOR_CLIP_NR 0x0c
#define CURSOR_FLAGS_VISIBLE 1u
#define MAX_EVENTS 200
#define FLAGS_SIZE(f) ((f) & 0x7)
#define FLAGS_FORMAT(f) (((f) >> 16) & 0x7)
#define FLAGS_COLORFMT(f) (((f) >> 8) & 0xf)
#define FORMAT_RGBA_PREMULT_ALPHA 3u
#define SAVED_PER_MODE 2

typedef int (*ioctl_fn)(int, unsigned long, ...);
static ioctl_fn real_ioctl;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned long count;
static char last_mode[16];
static int saved;
/* Buffers already given the low-byte alpha, by inode and checksum, so a buffer
 * X hands over again unchanged is not converted twice. */
static struct {
	ino_t ino;
	uint32_t sum;
} converted[16];
static unsigned int next_converted;
/* SET_CURSOR (position and visibility) calls, and the logged events. */
static unsigned long moves;
static int last_visible = -1;
static unsigned int events;

/* R35's struct tegra_dc_ext_cursor. */
struct cursor_pos {
	int16_t x, y;
	uint32_t flags;
};

static void say(const char *fmt, ...)
{
	const char *dir = getenv("CURSOR_SHIM_DIR");
	char path[512];
	struct timespec ts;
	va_list ap;
	FILE *f;

	if (!dir)
		return;
	snprintf(path, sizeof(path), "%s/log.txt", dir);
	f = fopen(path, "a");
	if (!f)
		return;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	fprintf(f, "[%ld.%03ld] ", (long)ts.tv_sec, ts.tv_nsec / 1000000);
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

static void read_mode(char *mode, size_t len)
{
	const char *path = getenv("CURSOR_SHIM_MODE");
	FILE *f;

	snprintf(mode, len, "log");
	if (!path || !(f = fopen(path, "r")))
		return;
	if (fgets(mode, len, f))
		mode[strcspn(mode, " \n")] = '\0';
	fclose(f);
}

static const char *format_name(unsigned int format)
{
	switch (format) {
	case 0: return "2BIT_LEGACY";
	case 1: return "RGBA_NON_PREMULT_ALPHA";
	case 3: return "RGBA_PREMULT_ALPHA";
	case 4: return "RGBA_XOR";
	default: return "invalid";
	}
}

static const char *colorfmt_name(unsigned int colorfmt)
{
	static const char *names[] = { "LEGACY", "R8G8B8A8", "A1R5G5B5", "A8R8G8B8" };

	return colorfmt < 4 ? names[colorfmt] : "invalid";
}

static int sync_buf(int fd, uint64_t flags)
{
	struct dma_buf_sync sync = { .flags = flags };

	return real_ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
}

/* Which bytes of the 32-bit pixels are set, and a picture of the top-left
 * 48x48 pixels: '#' only the top byte set, 'o' only the low byte, '@' both,
 * '.' only the middle bytes, ' ' none. */
static void describe32(const uint32_t *px, unsigned int side)
{
	unsigned long lane[4] = { 0 }, opaque_hi = 0, opaque_lo = 0, nonzero = 0;
	unsigned int n = side * side, i, x, y;
	char row[64];

	for (i = 0; i < n; i++) {
		uint32_t v = px[i];

		if (v)
			nonzero++;
		for (x = 0; x < 4; x++)
			if ((v >> (8 * x)) & 0xff)
				lane[x]++;
		if ((v >> 24) == 0xff)
			opaque_hi++;
		if ((v & 0xff) == 0xff)
			opaque_lo++;
	}
	say("  pixels %u, non-zero %lu; bytes set by lane (low to top): %lu %lu %lu %lu; "
	    "top byte 0xff: %lu, low byte 0xff: %lu", n, nonzero, lane[0], lane[1], lane[2],
	    lane[3], opaque_hi, opaque_lo);
	for (y = 0; y < 48 && y < side; y++) {
		for (x = 0; x < 48 && x < side; x++) {
			uint32_t v = px[y * side + x];
			int hi = (v >> 24) != 0, lo = (v & 0xff) != 0;

			row[x] = hi && lo ? '@' : hi ? '#' : lo ? 'o' : v ? '.' : ' ';
		}
		row[x] = '\0';
		say("  |%s|", row);
	}
	say("  first set pixels:");
	for (i = 0, x = 0; i < n && x < 8; i++)
		if (px[i]) {
			say("    (%u,%u) 0x%08x", i % side, i / side, px[i]);
			x++;
		}
}

static uint32_t checksum(const uint32_t *px, size_t n)
{
	uint32_t sum = 2166136261u;
	size_t i;

	for (i = 0; i < n; i++)
		sum = (sum ^ px[i]) * 16777619u;
	return sum;
}

static void to_low_alpha(int buf, uint32_t *px, size_t n)
{
	struct stat st;
	uint32_t sum = checksum(px, n);
	unsigned int i;
	size_t j;

	if (fstat(buf, &st))
		st.st_ino = 0;
	for (i = 0; i < 16; i++)
		if (converted[i].ino == st.st_ino && converted[i].sum == sum && st.st_ino) {
			say("  alpha already in the low byte (same buffer, unchanged)");
			return;
		}
	for (j = 0; j < n; j++)
		px[j] = (px[j] << 8) | (px[j] >> 24);
	converted[next_converted].ino = st.st_ino;
	converted[next_converted].sum = checksum(px, n);
	next_converted = (next_converted + 1) % 16;
	say("  alpha moved to the low byte");
}

/* Log the image; in a mode other than log, change img and the buffer. */
static void handle(int fd, struct cursor_image *img, const char *mode)
{
	char path[512];
	const char *dir = getenv("CURSOR_SHIM_DIR");
	unsigned int side = 16u << FLAGS_SIZE(img->flags);
	unsigned int format = FLAGS_FORMAT(img->flags), colorfmt = FLAGS_COLORFMT(img->flags);
	int rgba32 = format != 0 || colorfmt == 1 || colorfmt == 3;
	size_t want = rgba32 ? (size_t)side * side * 4 : (size_t)side * side / 4;
	off_t size;
	int changing = strncmp(mode, "log", 3) != 0;
	void *map;

	if (strcmp(mode, last_mode)) {
		snprintf(last_mode, sizeof(last_mode), "%s", mode);
		saved = 0;
	}
	count++;
	say("#%lu mode=%s fd=%d buff_id=%d flags=0x%08x size=%ux%u format=%u(%s) "
	    "colorfmt_flags=%u(%s) colorfmt=%u alpha=%u fg=%02x%02x%02x bg=%02x%02x%02x "
	    "x=%d y=%d", count, mode, fd, img->buff_id, img->flags, side, side, format,
	    format_name(format), colorfmt, colorfmt_name(colorfmt), img->colorfmt, img->alpha,
	    img->foreground.r, img->foreground.g, img->foreground.b, img->background.r,
	    img->background.g, img->background.b, img->x, img->y);
	if (img->buff_id <= 0)
		return;
	size = lseek(img->buff_id, 0, SEEK_END);
	lseek(img->buff_id, 0, SEEK_SET);
	if (size < (off_t)want) {
		say("  buffer size %lld, %zu expected; left alone", (long long)size, want);
		return;
	}
	map = mmap(NULL, want, PROT_READ | (changing ? PROT_WRITE : 0), MAP_SHARED,
		   img->buff_id, 0);
	if (map == MAP_FAILED) {
		say("  mmap of the buffer failed: %s", strerror(errno));
		return;
	}
	/* No cache maintenance in log mode: what the display reads stays as X
	 * left it. The CPU's own view is coherent either way. */
	if (changing && sync_buf(img->buff_id, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW))
		say("  DMA_BUF_SYNC_START failed: %s", strerror(errno));
	say("  buffer %lld bytes, %s", (long long)size,
	    rgba32 ? "32-bit pixels" : "two 1-bit planes");
	if (rgba32 && saved < SAVED_PER_MODE)
		describe32(map, side);
	if (dir && saved < SAVED_PER_MODE) {
		int out;

		snprintf(path, sizeof(path), "%s/image-%03lu-%s-%ux%u.bin", dir, count, mode,
			 side, side);
		out = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (out >= 0) {
			if (write(out, map, want) != (ssize_t)want)
				say("  short write to %s", path);
			close(out);
		}
		saved++;
	}
	if (rgba32 && (!strcmp(mode, "flags") || !strcmp(mode, "rgba"))) {
		img->flags = (img->flags & ~(0x7u << 16)) | (FORMAT_RGBA_PREMULT_ALPHA << 16);
		say("  flags now 0x%08x", img->flags);
	}
	if (rgba32 && !strcmp(mode, "rgba"))
		to_low_alpha(img->buff_id, map, want / 4);
	if (changing) {
		if (sync_buf(img->buff_id, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW))
			say("  DMA_BUF_SYNC_END failed: %s", strerror(errno));
		else
			say("  caches written back");
	}
	munmap(map, want);
}

/* The other cursor calls: ownership, clipping, and changes of visibility
 * (positions are only counted). Logged as EVENT lines, up to MAX_EVENTS. */
static int other_cursor_call(int fd, unsigned long request, void *arg)
{
	unsigned int nr = _IOC_NR(request);
	struct cursor_pos pos = { 0 };
	int ret, err, visible = -1, clip = 0;

	if (nr == SET_CURSOR_NR && arg)
		pos = *(struct cursor_pos *)arg;
	if (nr == CURSOR_CLIP_NR && arg)
		clip = *(int *)arg;
	ret = real_ioctl(fd, request, arg);
	err = errno;
	pthread_mutex_lock(&lock);
	if (nr == SET_CURSOR_NR) {
		moves++;
		visible = !!(pos.flags & CURSOR_FLAGS_VISIBLE);
		if ((visible != last_visible || ret) && events < MAX_EVENTS) {
			events++;
			say("EVENT SET_CURSOR visible=%d at %d,%d after %lu calls returned %d%s%s",
			    visible, pos.x, pos.y, moves, ret, ret ? " " : "", ret ? strerror(err) : "");
		}
		last_visible = visible;
	} else if (events < MAX_EVENTS) {
		events++;
		if (nr == CURSOR_CLIP_NR)
			say("EVENT CURSOR_CLIP %d returned %d%s%s", clip, ret, ret ? " " : "",
			    ret ? strerror(err) : "");
		else
			say("EVENT %s_CURSOR returned %d%s%s", nr == GET_CURSOR_NR ? "GET" : "PUT", ret,
			    ret ? " " : "", ret ? strerror(err) : "");
	}
	pthread_mutex_unlock(&lock);
	errno = err;
	return ret;
}

int ioctl(int fd, unsigned long request, ...)
{
	va_list ap;
	void *arg;
	int ret, err;

	va_start(ap, request);
	arg = va_arg(ap, void *);
	va_end(ap);
	if (!real_ioctl)
		real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
	if (_IOC_TYPE(request) != 'D')
		return real_ioctl(fd, request, arg);
	switch (_IOC_NR(request)) {
	case GET_CURSOR_NR:
	case PUT_CURSOR_NR:
		if (_IOC_DIR(request) == _IOC_NONE)
			return other_cursor_call(fd, request, arg);
		return real_ioctl(fd, request, arg);
	case SET_CURSOR_NR:
		if (_IOC_DIR(request) == _IOC_WRITE && _IOC_SIZE(request) == sizeof(struct cursor_pos))
			return other_cursor_call(fd, request, arg);
		return real_ioctl(fd, request, arg);
	case CURSOR_CLIP_NR:
		if (_IOC_DIR(request) == _IOC_WRITE && _IOC_SIZE(request) == sizeof(int))
			return other_cursor_call(fd, request, arg);
		return real_ioctl(fd, request, arg);
	case SET_CURSOR_IMAGE_NR:
		break;
	default:
		return real_ioctl(fd, request, arg);
	}
	if (_IOC_DIR(request) != _IOC_WRITE || !arg)
		return real_ioctl(fd, request, arg);
	if (_IOC_SIZE(request) != sizeof(struct cursor_image)) {
		say("cursor image ioctl 0x%lx of %u bytes, not %zu; passed on unread", request,
		    (unsigned int)_IOC_SIZE(request), sizeof(struct cursor_image));
		return real_ioctl(fd, request, arg);
	}

	pthread_mutex_lock(&lock);
	{
		/* Changes go to a copy, so X's own structure stays as it made it. */
		struct cursor_image copy = *(struct cursor_image *)arg;
		char mode[16];

		read_mode(mode, sizeof(mode));
		handle(fd, &copy, mode);
		ret = real_ioctl(fd, request, &copy);
		err = errno;
		say("  SET_CURSOR_IMAGE returned %d%s%s", ret, ret ? " " : "",
		    ret ? strerror(err) : "");
	}
	pthread_mutex_unlock(&lock);
	errno = err;
	return ret;
}

__attribute__((constructor)) static void loaded(void)
{
	char exe[256] = "";
	ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);

	if (n > 0)
		exe[n] = '\0';
	say("cursor_shim loaded in pid %d (%s)", (int)getpid(), exe);
}

/*
 * LD_PRELOAD shim that records the jobs a video converter hands VIC, so that
 * JetPack 4's and JetPack 5's nvvidconv can be compared for the same
 * conversion (scripts/jetson/probe-l4t-video.sh, VIC_RECORD=1;
 * tests/video/vic_jobs.py reads the records). Unless VIC_PATCH is set, it
 * only reads: every request is passed on unchanged.
 *
 * For each NVHOST_IOCTL_CHANNEL_SUBMIT to a VIC channel, before passing it
 * on, it writes the request's fields, its command buffers (as submitted, so
 * relocated words still hold the library's placeholders) and, up to
 * VIC_RECORD_MAX bytes each, every buffer the job relocates or that was
 * mapped to a channel with NVHOST_IOCTL_CHANNEL_MAP_BUFFER: VIC's settings
 * block, filter coefficients and the like. Buffers are read with
 * NVMAP_IOC_READ through a /dev/nvmap client of its own (nvmap handles are
 * dma-buf descriptors on the Nano's 5.10 kernel, patch 0003). Requests use
 * R35's include/uapi/linux/nvhost_ioctl.h and nvmap.h, which the 5.10 kernel
 * also takes from R32's libraries.
 *
 * VIC_PATCH names groups of VIC's settings that JetPack 5's converter sets and
 * JetPack 4's does not (2026-10-17 recording); in every job submitted to a VIC
 * channel, before it is passed on and recorded, the shim sets them to JetPack
 * 4's values, writing through NVMAP_IOC_WRITE. Fields are those of VIC 4.0's
 * settings block, ConfigStruct in libdrm's tests/tegra/vic40.h (output and
 * slot 0); a job whose SET_CONTROL_PARAMS does not give that block's size
 * (1552 bytes) is left as it is. Groups, separated by commas or spaces:
 *   gamma      OutputConfig.RegammaMode and slot 0's DegammaMode to 0
 *   matrix     the output and slot 0 colour matrices to 0 (off)
 *   roundtrip  both matrices to 0, only when both are on and undo each other
 *              (JetPack 5's bilinear scaling goes YUV to RGB and back)
 *   blend      slot 0's blending block to 0
 *   alpha      OutputConfig.AlphaFillMode to 0
 *   chromaloc  OutChromaLocVert and slot 0's SlotChromaLocVert to 1
 *   control    bit 4 of SET_CONTROL_PARAMS set
 *   all        every group above
 *   fix        gamma, roundtrip and chromaloc: on the Nano (2026-10-17)
 *              these bring JetPack 5's colour, scaling and vertical chroma
 *              placement to JetPack 4's results (without chromaloc, odd rows
 *              took the next row pair's chroma), while matrix and blend each
 *              ruin some pictures
 * Each job's changes go to p<pid>-log.txt (the first VIC_RECORD_JOBS jobs),
 * and a "vic_patch:" line at exit counts the jobs. With VIC_PATCH and no
 * VIC_RECORD_DIR it only patches, writes nothing and leaves every request but
 * SUBMIT and MAP_BUFFER alone (MAP_BUFFER only to a VIC channel):
 * nano-l4t-r35-video's launcher, nano-r35-video, runs programs that way with
 * VIC_PATCH=fix. A program can read the counts as it runs through
 * vic_patch_counts() (tests/video/vic_cuda.py does).
 *
 * Environment:
 *   VIC_RECORD_DIR   folder for the records (nothing is written without it,
 *                    and without it or VIC_PATCH the shim does nothing)
 *   VIC_RECORD_JOBS  jobs recorded at most per process (default 6)
 *   VIC_RECORD_MAX   bytes read at most per buffer (default 262144); larger
 *                    buffers (pictures) are listed with their size only
 *   VIC_PATCH        groups of settings to set to JetPack 4's values (above)
 *
 * Files in VIC_RECORD_DIR, per process (p<pid>):
 *   p<pid>-log.txt        loading, and anything that could not be read
 *   p<pid>-maps.txt       each buffer mapped to a channel, with its address
 *   p<pid>-requests.txt   at exit: every nvhost and nvmap request made, by
 *                         device and number, with its count
 *   p<pid>-jNN/submit.txt the request, its command buffers, relocations,
 *                         syncpoint increments and buffers
 *   p<pid>-jNN/cmdbuf-I.bin  command buffer I's words
 *   p<pid>-jNN/buf-INODE.bin the buffer's contents, named by its inode
 *
 * Build: gcc -O2 -Wall -shared -fPIC -o vic_record.so vic_record.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/ioctl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* R35's include/uapi/linux/nvhost_ioctl.h */
struct nvhost_submit_args {
	uint32_t submit_version;
	uint32_t num_syncpt_incrs;
	uint32_t num_cmdbufs;
	uint32_t num_relocs;
	uint32_t num_waitchks;
	uint32_t timeout;
	uint32_t flags;
	uint32_t fence;
	uint64_t syncpt_incrs;
	uint64_t cmdbuf_exts;
	uint32_t checksum_methods;
	uint32_t checksum_falcon_methods;
	uint64_t pad[1];
	uint64_t reloc_types;
	uint64_t cmdbufs;
	uint64_t relocs;
	uint64_t reloc_shifts;
	uint64_t waitchks;
	uint64_t waitbases;
	uint64_t class_ids;
	uint64_t fences;
};
_Static_assert(sizeof(struct nvhost_submit_args) == 128, "nvhost_submit_args layout");

struct nvhost_cmdbuf {
	uint32_t mem;
	uint32_t offset;
	uint32_t words;
} __attribute__((packed));

struct nvhost_reloc {
	uint32_t cmdbuf_mem;
	uint32_t cmdbuf_offset;
	uint32_t target;
	uint32_t target_offset;
};

struct nvhost_reloc_type {
	uint32_t reloc_type;
	uint32_t padding;
};

struct nvhost_syncpt_incr {
	uint32_t syncpt_id;
	uint32_t syncpt_incrs;
};

struct nvhost_channel_buffer {
	uint32_t dmabuf_fd;
	uint32_t reserved0;
	uint64_t reserved1[2];
	uint64_t address;
};
_Static_assert(sizeof(struct nvhost_channel_buffer) == 32, "nvhost_channel_buffer layout");

struct nvhost_channel_map_buffer_args {
	uint32_t num_buffers;
	uint32_t reserved;
	uint64_t table_address;
};

/* R35's include/uapi/linux/nvmap.h (the 56-byte layout, 0x40384e07) */
struct nvmap_rw_handle {
	uint64_t addr;
	uint32_t handle;
	uint64_t offset;
	uint64_t elem_size;
	uint64_t hmem_stride;
	uint64_t user_stride;
	uint64_t count;
};
_Static_assert(sizeof(struct nvmap_rw_handle) == 56, "nvmap_rw_handle layout");
#define NVMAP_IOC_WRITE _IOW('N', 6, struct nvmap_rw_handle)
#define NVMAP_IOC_READ _IOW('N', 7, struct nvmap_rw_handle)

/* VIC 4.0 (libdrm's tests/tegra/vic40.h) */
#define METHOD_OFFSET 0x10  /* FLCN_UCLASS_METHOD_OFFSET: the method's offset / 4 */
#define METHOD_DATA 0x11    /* FLCN_UCLASS_METHOD_DATA: its value */
#define SET_CONTROL_PARAMS 0x704
#define SET_CONFIG_STRUCT_OFFSET 0x708
#define CONFIG_UNITS 97     /* sizeof(ConfigStruct) / 16, in SET_CONTROL_PARAMS bits 16-31 */
#define CONFIG_BYTES 0x140  /* the settings block up to the end of slot 0 */
#define MAX_METHODS 4096

#define SUBMIT_NR 26
#define MAP_BUFFER_NR 28
#define MAX_CMDBUFS 64
#define MAX_RELOCS 1024
#define MAX_INCRS 64
#define MAX_MAPS 512
#define MAX_REQUESTS 256

typedef int (*ioctl_fn)(int, unsigned long, ...);
static ioctl_fn real_ioctl;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int nvmap = -1;
static unsigned int jobs;

enum { PATCH_GAMMA = 1, PATCH_MATRIX = 2, PATCH_BLEND = 4, PATCH_ALPHA = 8, PATCH_CHROMALOC = 16,
       PATCH_CONTROL = 32, PATCH_ROUNDTRIP = 64 };
static const struct {
	const char *name;
	unsigned int bits;
} groups[] = {
	{ "gamma", PATCH_GAMMA }, { "matrix", PATCH_MATRIX }, { "blend", PATCH_BLEND },
	{ "alpha", PATCH_ALPHA }, { "chromaloc", PATCH_CHROMALOC }, { "control", PATCH_CONTROL },
	{ "roundtrip", PATCH_ROUNDTRIP }, { "all", 127 }, { "fix", PATCH_GAMMA | PATCH_ROUNDTRIP | PATCH_CHROMALOC },
};
static unsigned int patch;  /* VIC_PATCH's groups */
/* VIC jobs seen; changed and checked; already as asked; not patched (no
 * settings block found, or not VIC 4.0's); a read or write that failed. */
static unsigned int seen, patched, unchanged, skipped, failed;

/* Buffers mapped to a channel: descriptor, inode, size, device address. */
static struct {
	int fd;
	ino_t ino;
	uint64_t size, iova;
} maps[MAX_MAPS];
static unsigned int nmaps;

/* Requests made, by device and number. */
static struct {
	char dev[96];
	unsigned int cmd;
	unsigned long calls, failed;
} requests[MAX_REQUESTS];
static unsigned int nrequests;

static const char *dir(void)
{
	return getenv("VIC_RECORD_DIR");
}

static unsigned long setting(const char *name, unsigned long fallback)
{
	const char *value = getenv(name);
	char *end;
	unsigned long n;

	if (!value || !*value)
		return fallback;
	n = strtoul(value, &end, 0);
	return *end ? fallback : n;
}

static FILE *open_file(const char *mode, const char *fmt, ...)
{
	char path[512];
	va_list ap;
	int n;

	if (!dir())
		return NULL;
	n = snprintf(path, sizeof(path), "%s/", dir());
	va_start(ap, fmt);
	vsnprintf(path + n, sizeof(path) - n, fmt, ap);
	va_end(ap);
	return fopen(path, mode);
}

static void say(const char *fmt, ...)
{
	FILE *f = open_file("a", "p%d-log.txt", (int)getpid());
	va_list ap;

	if (!f)
		return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

static void device_of(int fd, char *dev, size_t len)
{
	char link[64];
	ssize_t n;

	snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
	n = readlink(link, dev, len - 1);
	if (n < 0)
		n = snprintf(dev, len, "fd-unknown");
	dev[n] = '\0';
}

static void count_request(int fd, unsigned int cmd, int failed)
{
	char dev[96];
	unsigned int i;

	device_of(fd, dev, sizeof(dev));
	for (i = 0; i < nrequests; i++)
		if (requests[i].cmd == cmd && !strcmp(requests[i].dev, dev))
			break;
	if (i == nrequests) {
		if (nrequests == MAX_REQUESTS)
			return;
		nrequests++;
		snprintf(requests[i].dev, sizeof(requests[i].dev), "%s", dev);
		requests[i].cmd = cmd;
	}
	requests[i].calls++;
	requests[i].failed += failed;
}

static ino_t inode_of(int fd)
{
	struct stat st;

	return fstat(fd, &st) ? 0 : st.st_ino;
}

static long long size_of(int fd)
{
	off_t end = lseek(fd, 0, SEEK_END);

	if (end < 0)
		return -1;
	lseek(fd, 0, SEEK_SET);
	return end;
}

/* Reads (or writes) LEN bytes of handle FD at OFFSET into (from) BUF; 0 on success. */
static int rw_handle(unsigned int request, int fd, uint64_t offset, void *buf, uint64_t len)
{
	struct nvmap_rw_handle op = {
		.addr = (uintptr_t)buf,
		.handle = (uint32_t)fd,
		.offset = offset,
		.elem_size = len,
		.hmem_stride = len,
		.user_stride = len,
		.count = 1,
	};

	if (nvmap < 0)
		nvmap = open("/dev/nvmap", O_RDWR | O_CLOEXEC);
	if (nvmap < 0)
		return -errno;
	if (real_ioctl(nvmap, request, &op))
		return -errno;
	return 0;
}

static int read_handle(int fd, uint64_t offset, void *buf, uint64_t len)
{
	return rw_handle(NVMAP_IOC_READ, fd, offset, buf, len);
}

/* Writes LEN bytes of BUF to handle FD at OFFSET and reads them back; 0 if they match. */
static int write_handle(int fd, uint64_t offset, const void *buf, uint64_t len)
{
	unsigned char back[CONFIG_BYTES];
	int err;

	if (len > sizeof(back))
		return -EINVAL;
	err = rw_handle(NVMAP_IOC_WRITE, fd, offset, (void *)buf, len);
	if (!err)
		err = read_handle(fd, offset, back, len);
	if (!err && memcmp(back, buf, len))
		err = -EIO;
	return err;
}

static int write_bin(const char *job, const char *name, const void *data, size_t len)
{
	FILE *f = open_file("w", "%s/%s", job, name);
	size_t done;

	if (!f)
		return -1;
	done = fwrite(data, 1, len, f);
	return fclose(f) || done != len ? -1 : 0;
}

/* Copies COUNT entries of SIZE bytes from the caller's array at ADDR. */
static void *copy_array(uint64_t addr, uint32_t count, size_t size, uint32_t max)
{
	void *copy;

	if (!addr || !count || count > max)
		return NULL;
	copy = malloc((size_t)count * size);
	if (copy)
		memcpy(copy, (const void *)(uintptr_t)addr, (size_t)count * size);
	return copy;
}

struct buffer {
	int fd;
	ino_t ino;
	uint64_t iova;
	const char *source;
};

static int add_buffer(struct buffer *list, int n, int max, int fd, ino_t ino, uint64_t iova,
		      const char *source)
{
	int i;

	for (i = 0; i < n; i++)
		if (list[i].ino == ino && list[i].fd == fd)
			return n;
	if (n == max)
		return n;
	list[n] = (struct buffer){ fd, ino, iova, source };
	return n + 1;
}

static void dump_buffer(FILE *out, const char *job, const struct buffer *b, unsigned long max)
{
	long long size = size_of(b->fd);
	char name[64];
	void *data;
	int err;

	fprintf(out, "BUFFER fd=%d ino=%lu size=%lld iova=", b->fd, (unsigned long)b->ino, size);
	if (b->iova)
		fprintf(out, "0x%llx", (unsigned long long)b->iova);
	else
		fputc('-', out);
	fprintf(out, " source=%s ", b->source);
	if (size <= 0) {
		fprintf(out, "dumped=no (size unknown)\n");
		return;
	}
	if ((unsigned long long)size > max) {
		fprintf(out, "dumped=no (over %lu bytes)\n", max);
		return;
	}
	data = malloc(size);
	if (!data) {
		fprintf(out, "dumped=no (no memory)\n");
		return;
	}
	err = read_handle(b->fd, 0, data, size);
	if (err) {
		fprintf(out, "dumped=no (read: %s)\n", strerror(-err));
	} else {
		snprintf(name, sizeof(name), "buf-%lu.bin", (unsigned long)b->ino);
		fprintf(out, "dumped=%s\n", write_bin(job, name, data, size) ? "no (write failed)" : name);
	}
	free(data);
}

/* A VIC method found in a command buffer: its value, and where the value sits. */
struct method {
	uint32_t method, value, mem, at;
	int imm;
};

struct decoder {
	struct method *out;
	int n, max, have;
	uint32_t method, mem;
};

static void take(struct decoder *d, uint32_t reg, uint32_t value, uint32_t at, int imm)
{
	if (reg == METHOD_OFFSET) {
		d->method = value << 2;
		d->have = 1;
	} else if (reg == METHOD_DATA && d->have && d->n < d->max) {
		d->out[d->n++] = (struct method){ d->method, value, d->mem, at, imm };
	}
}

/* The register writes of N host1x command words at BASE, as vic_jobs.py decodes them. */
static void decode(struct decoder *d, const uint32_t *w, uint32_t n, uint32_t base)
{
	uint32_t i = 0, k, bit;

	d->have = 0;
	while (i < n) {
		uint32_t op = w[i] >> 28, offset = (w[i] >> 16) & 0xfff, count, mask;

		switch (op) {
		case 0:  /* SETCLASS, with the registers its mask names */
		case 3:  /* MASK */
			mask = op == 0 ? w[i] & 0x3f : w[i] & 0xffff;
			i++;
			for (bit = 0; bit < 16; bit++)
				if (mask >> bit & 1) {
					if (i < n)
						take(d, offset + bit, w[i], base + 4 * i, 0);
					i++;
				}
			break;
		case 1:  /* INCR */
		case 2:  /* NONINCR */
			count = w[i] & 0xffff;
			for (k = 0; k < count && i + 1 + k < n; k++)
				take(d, offset + (op == 1 ? k : 0), w[i + 1 + k], base + 4 * (i + 1 + k), 0);
			i += 1 + count;
			break;
		case 4:  /* IMM */
			take(d, offset, w[i] & 0xffff, base + 4 * i, 1);
			i++;
			break;
		case 6:  /* GATHER: its words are elsewhere */
			i += 2;
			break;
		default:
			i++;
		}
	}
}

static void parse_patch(void)
{
	const char *value = getenv("VIC_PATCH");
	char *copy, *name, *save = NULL;
	unsigned int i;

	if (!value || !*value || !(copy = strdup(value)))
		return;
	for (name = strtok_r(copy, ", ", &save); name; name = strtok_r(NULL, ", ", &save)) {
		for (i = 0; i < sizeof(groups) / sizeof(groups[0]); i++)
			if (!strcmp(name, groups[i].name))
				break;
		if (i < sizeof(groups) / sizeof(groups[0]))
			patch |= groups[i].bits;
		else
			say("VIC_PATCH: no group %s (ignored)", name);
	}
	free(copy);
}

/* Sets the bits of MASK in word OFFSET of the settings block to VALUE's. */
static void set_bits(uint32_t *config, unsigned int offset, uint32_t mask, uint32_t value)
{
	config[offset / 4] = (config[offset / 4] & ~mask) | (value & mask);
}

static void zero_words(uint32_t *config, unsigned int from, unsigned int to)
{
	for (; from < to; from += 4)
		config[from / 4] = 0;
}

/* WIDTH bits from bit LO of the words at W. */
static uint32_t field(const uint32_t *w, unsigned int lo, unsigned int width)
{
	uint64_t pair = w[lo / 32] | (lo % 32 + width > 32 ? (uint64_t)w[lo / 32 + 1] << 32 : 0);

	return (uint32_t)(pair >> (lo % 32)) & ((1u << width) - 1);
}

/* A MatrixStruct's 3x3 part (matrix_coeffRK, 20-bit signed, scaled by 2^(shift + 8)). */
static int matrix_of(const uint32_t *m, double a[3][3])
{
	unsigned int shift = field(m, 60, 4), r, k;

	for (r = 0; r < 3; r++)
		for (k = 0; k < 3; k++) {
			int32_t v = (int32_t)field(m, 64 * k + 20 * r, 20);

			a[r][k] = (v & 0x80000 ? v - 0x100000 : v) / (double)(1u << (shift + 8));
		}
	return (int)field(m, 127, 1);  /* matrix_enable */
}

/* Whether the output matrix undoes slot 0's: both on, and their product within 1% of identity. */
static int matrices_cancel(const uint32_t *c)
{
	double out[3][3], in[3][3], sum;
	unsigned int r, k, j;

	if (!matrix_of(&c[0x30 / 4], out) || !matrix_of(&c[0xf0 / 4], in))
		return 0;
	for (r = 0; r < 3; r++)
		for (k = 0; k < 3; k++) {
			for (sum = 0, j = 0; j < 3; j++)
				sum += out[r][j] * in[j][k];
			sum -= r == k;
			if (sum > 0.01 || sum < -0.01)
				return 0;
		}
	return 1;
}

/* VIC_PATCH's groups, in the first CONFIG_BYTES of a ConfigStruct. */
static void patch_config(uint32_t *c)
{
	if (patch & PATCH_GAMMA) {
		set_bits(c, 0x14, 0x0000c000, 0);  /* outputConfig.RegammaMode, bits 46-47 */
		set_bits(c, 0xa4, 0x01800000, 0);  /* slot 0 slotConfig.DegammaMode, bits 183-184 */
	}
	if ((patch & PATCH_MATRIX) || ((patch & PATCH_ROUNDTRIP) && matrices_cancel(c))) {
		zero_words(c, 0x30, 0x50);  /* outColorMatrixStruct */
		zero_words(c, 0xf0, 0x110); /* slot 0 colorMatrixStruct */
	}
	if (patch & PATCH_BLEND)
		zero_words(c, 0x130, 0x140); /* slot 0 blendingSlotStruct */
	if (patch & PATCH_ALPHA)
		set_bits(c, 0x10, 0x7, 0);   /* outputConfig.AlphaFillMode, bits 0-2 */
	if (patch & PATCH_CHROMALOC) {
		set_bits(c, 0x20, 0x600, 0x200); /* outputSurfaceConfig.OutChromaLocVert, bits 9-10 */
		set_bits(c, 0xd0, 0x600, 0x200); /* slot 0 slotSurfaceConfig.SlotChromaLocVert */
	}
}

/* With VIC_PATCH: sets the job's settings to JetPack 4's values before it goes to VIC. */
static void patch_submit(int fd, const struct nvhost_submit_args *args)
{
	struct nvhost_cmdbuf *cmdbufs = NULL;
	struct nvhost_reloc *relocs = NULL;
	static struct method found[MAX_METHODS];  /* under the lock */
	struct decoder d = { found, 0, MAX_METHODS, 0, 0, 0 };
	const struct method *control = NULL, *config = NULL;
	uint32_t before[CONFIG_BYTES / 4], after[CONFIG_BYTES / 4], word;
	int show, target = -1, err = 0, changed = 0;
	uint64_t offset = 0;
	char dev[256], line[1024];
	unsigned int i, n = 0;

	device_of(fd, dev, sizeof(dev));
	if (!patch || !strstr(dev, "vic"))
		return;
	seen++;
	show = seen <= setting("VIC_RECORD_JOBS", 6);
	cmdbufs = copy_array(args->cmdbufs, args->num_cmdbufs, sizeof(*cmdbufs), MAX_CMDBUFS);
	relocs = copy_array(args->relocs, args->num_relocs, sizeof(*relocs), MAX_RELOCS);
	for (i = 0; cmdbufs && i < args->num_cmdbufs; i++) {
		size_t len = (size_t)cmdbufs[i].words * 4;
		uint32_t *words = len ? malloc(len) : NULL;

		if (words && !read_handle(cmdbufs[i].mem, cmdbufs[i].offset, words, len)) {
			d.mem = cmdbufs[i].mem;
			decode(&d, words, cmdbufs[i].words, cmdbufs[i].offset);
		}
		free(words);
	}
	for (i = 0; i < (unsigned int)d.n; i++) {
		if (found[i].method == SET_CONTROL_PARAMS)
			control = &found[i];
		else if (found[i].method == SET_CONFIG_STRUCT_OFFSET)
			config = &found[i];
	}
	/* The settings block: the buffer the kernel relocates the method's value
	 * to, or the mapped buffer its address (value << 8) falls in. */
	for (i = 0; config && relocs && i < args->num_relocs && target < 0; i++)
		if (relocs[i].cmdbuf_mem == config->mem && relocs[i].cmdbuf_offset == config->at) {
			target = (int)relocs[i].target;
			offset = relocs[i].target_offset;
		}
	for (i = 0; config && !config->imm && i < nmaps && target < 0; i++)
		if (inode_of(maps[i].fd) == maps[i].ino && (uint64_t)config->value << 8 >= maps[i].iova
		    && ((uint64_t)config->value << 8) - maps[i].iova < maps[i].size) {
			target = maps[i].fd;
			offset = ((uint64_t)config->value << 8) - maps[i].iova;
		}
	if (!control || control->imm)
		n = snprintf(line, sizeof(line), "no SET_CONTROL_PARAMS in a command buffer");
	else if (control->value >> 16 != CONFIG_UNITS)
		n = snprintf(line, sizeof(line), "SET_CONTROL_PARAMS 0x%x does not give VIC 4.0's 1552-byte block",
			     control->value);
	else if (target < 0)
		n = snprintf(line, sizeof(line), "no settings block found");
	else if (size_of(target) < (long long)(offset + CONFIG_BYTES))
		n = snprintf(line, sizeof(line), "settings block past the buffer's end");
	if (n) {
		skipped++;
		if (show)
			say("PATCH job %u: not patched (%s)", seen, line);
		goto out;
	}
	n = snprintf(line, sizeof(line), "PATCH job %u: block ino %lu +0x%llx", seen,
		     (unsigned long)inode_of(target), (unsigned long long)offset);
	if ((patch & PATCH_CONTROL) && !(control->value & 0x10)) {
		word = control->value | 0x10;
		err = read_handle(control->mem, control->at, &before[0], 4);
		if (!err && before[0] != control->value)
			err = -ESTALE;
		if (!err)
			err = write_handle(control->mem, control->at, &word, 4);
		if (err)
			goto done;
		changed++;
		n += snprintf(line + n, sizeof(line) - n, " control 0x%08x->0x%08x", control->value, word);
	}
	err = read_handle(target, offset, before, CONFIG_BYTES);
	if (err)
		goto done;
	memcpy(after, before, sizeof(after));
	patch_config(after);
	for (i = 0; i < CONFIG_BYTES / 4; i++)
		if (after[i] != before[i]) {
			changed++;
			if (n < sizeof(line) - 40)
				n += snprintf(line + n, sizeof(line) - n, " +0x%x 0x%08x->0x%08x", i * 4, before[i],
					      after[i]);
		}
	if (memcmp(after, before, sizeof(after)))
		err = write_handle(target, offset, after, CONFIG_BYTES);
done:
	if (err) {
		failed++;
		if (show)
			say("%s: failed (%s)", line, strerror(-err));
	} else if (changed) {
		patched++;
		if (show)
			say("%s", line);
	} else {
		unchanged++;
		if (show)
			say("%s: already as asked", line);
	}
out:
	free(cmdbufs);
	free(relocs);
}

static void record_submit(int fd, const struct nvhost_submit_args *args)
{
	struct nvhost_cmdbuf *cmdbufs = NULL;
	struct nvhost_reloc *relocs = NULL;
	uint32_t *shifts = NULL, *class_ids = NULL;
	struct nvhost_reloc_type *types = NULL;
	struct nvhost_syncpt_incr *incrs = NULL;
	static struct buffer buffers[MAX_RELOCS + MAX_MAPS];  /* under the lock */
	unsigned long max = setting("VIC_RECORD_MAX", 262144);
	char dev[256], job[64], name[32];
	int nbuffers = 0;
	unsigned int i;
	FILE *out;

	device_of(fd, dev, sizeof(dev));
	if (!strstr(dev, "vic") || jobs >= setting("VIC_RECORD_JOBS", 6))
		return;
	jobs++;
	snprintf(job, sizeof(job), "p%d-j%02u", (int)getpid(), jobs);
	{
		char path[512];

		snprintf(path, sizeof(path), "%s/%s", dir(), job);
		if (mkdir(path, 0755) && errno != EEXIST) {
			say("job %u: cannot create %s: %s", jobs, path, strerror(errno));
			return;
		}
	}
	out = open_file("w", "%s/submit.txt", job);
	if (!out)
		return;
	fprintf(out, "SUBMIT channel=%s submit_version=%u num_syncpt_incrs=%u num_cmdbufs=%u num_relocs=%u "
		"num_waitchks=%u timeout=%u flags=0x%x reloc_types=%s cmdbuf_exts=%s class_ids=%s fences=%s\n",
		dev, args->submit_version, args->num_syncpt_incrs, args->num_cmdbufs, args->num_relocs,
		args->num_waitchks, args->timeout, args->flags, args->reloc_types ? "yes" : "no",
		args->cmdbuf_exts ? "yes" : "no", args->class_ids ? "yes" : "no", args->fences ? "yes" : "no");

	cmdbufs = copy_array(args->cmdbufs, args->num_cmdbufs, sizeof(*cmdbufs), MAX_CMDBUFS);
	relocs = copy_array(args->relocs, args->num_relocs, sizeof(*relocs), MAX_RELOCS);
	shifts = copy_array(args->reloc_shifts, args->num_relocs, sizeof(*shifts), MAX_RELOCS);
	types = copy_array(args->reloc_types, args->num_relocs, sizeof(*types), MAX_RELOCS);
	class_ids = copy_array(args->class_ids, args->num_cmdbufs, sizeof(*class_ids), MAX_CMDBUFS);
	incrs = copy_array(args->syncpt_incrs, args->num_syncpt_incrs, sizeof(*incrs), MAX_INCRS);
	if (args->num_cmdbufs && !cmdbufs)
		fprintf(out, "NOTE command buffers not read (%u)\n", args->num_cmdbufs);
	if (args->num_relocs && !relocs)
		fprintf(out, "NOTE relocations not read (%u)\n", args->num_relocs);

	for (i = 0; cmdbufs && i < args->num_cmdbufs; i++) {
		struct nvhost_cmdbuf *c = &cmdbufs[i];
		size_t len = (size_t)c->words * 4;
		void *words = len ? malloc(len) : NULL;
		int err = words ? read_handle(c->mem, c->offset, words, len) : -ENOMEM;

		fprintf(out, "CMDBUF %u mem=%u offset=0x%x words=%u class=", i, c->mem, c->offset, c->words);
		if (class_ids)
			fprintf(out, "0x%x", class_ids[i]);
		else
			fputc('-', out);
		fprintf(out, " ino=%lu size=%lld ", (unsigned long)inode_of(c->mem), size_of(c->mem));
		snprintf(name, sizeof(name), "cmdbuf-%u.bin", i);
		if (err)
			fprintf(out, "read=no (%s)\n", strerror(-err));
		else
			fprintf(out, "read=%s\n", write_bin(job, name, words, len) ? "no (write failed)" : name);
		free(words);
	}
	for (i = 0; relocs && i < args->num_relocs; i++) {
		struct nvhost_reloc *r = &relocs[i];

		fprintf(out, "RELOC %u cmdbuf_mem=%u cmdbuf_offset=0x%x target=%u target_offset=0x%x shift=", i,
			r->cmdbuf_mem, r->cmdbuf_offset, r->target, r->target_offset);
		if (shifts)
			fprintf(out, "%u", shifts[i]);
		else
			fputc('-', out);
		fputs(" type=", out);
		if (types)
			fprintf(out, "%u", types[i].reloc_type);
		else
			fputc('-', out);
		fprintf(out, " target_ino=%lu\n", (unsigned long)inode_of(r->target));
		nbuffers = add_buffer(buffers, nbuffers, MAX_RELOCS + MAX_MAPS, r->target, inode_of(r->target), 0,
				      "reloc");
	}
	for (i = 0; incrs && i < args->num_syncpt_incrs; i++)
		fprintf(out, "SYNCPT_INCR %u id=%u incrs=%u\n", i, incrs[i].syncpt_id, incrs[i].syncpt_incrs);
	/* Mapped buffers whose descriptor still names the same buffer. */
	for (i = 0; i < nmaps; i++) {
		int j;

		if (inode_of(maps[i].fd) != maps[i].ino)
			continue;
		for (j = 0; j < nbuffers; j++)
			if (buffers[j].ino == maps[i].ino) {
				buffers[j].iova = maps[i].iova;
				break;
			}
		if (j == nbuffers)
			nbuffers = add_buffer(buffers, nbuffers, MAX_RELOCS + MAX_MAPS, maps[i].fd, maps[i].ino,
					      maps[i].iova, "map");
	}
	for (i = 0; i < (unsigned int)nbuffers; i++)
		dump_buffer(out, job, &buffers[i], max);
	fclose(out);
	free(cmdbufs);
	free(relocs);
	free(shifts);
	free(types);
	free(class_ids);
	free(incrs);
}

static void record_map(const struct nvhost_channel_map_buffer_args *args)
{
	const struct nvhost_channel_buffer *table = (const void *)(uintptr_t)args->table_address;
	FILE *f = open_file("a", "p%d-maps.txt", (int)getpid());
	unsigned int i, j;

	for (i = 0; table && i < args->num_buffers; i++) {
		int fd = (int)table[i].dmabuf_fd;
		ino_t ino = inode_of(fd);
		long long size = size_of(fd);

		if (f)
			fprintf(f, "MAP fd=%d ino=%lu size=%lld iova=0x%llx\n", fd, (unsigned long)ino, size,
				(unsigned long long)table[i].address);
		for (j = 0; j < nmaps; j++)
			if (maps[j].ino == ino)
				break;
		if (j == nmaps) {
			if (nmaps == MAX_MAPS)
				continue;
			nmaps++;
		}
		maps[j].fd = fd;
		maps[j].ino = ino;
		maps[j].size = size > 0 ? size : 0;
		maps[j].iova = table[i].address;
	}
	if (f)
		fclose(f);
}

int ioctl(int fd, unsigned long request, ...)
{
	unsigned int cmd = (unsigned int)request;  /* some callers sign-extend it */
	int ret, err, record, submit, map;
	va_list ap;
	void *arg;

	va_start(ap, request);
	arg = va_arg(ap, void *);
	va_end(ap);
	if (!real_ioctl)
		real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
	record = dir() != NULL;
	if ((!record && !patch) || (_IOC_TYPE(cmd) != 'H' && _IOC_TYPE(cmd) != 'N'))
		return real_ioctl(fd, request, arg);
	submit = _IOC_TYPE(cmd) == 'H' && _IOC_NR(cmd) == SUBMIT_NR && arg
		 && _IOC_SIZE(cmd) == sizeof(struct nvhost_submit_args);
	map = _IOC_TYPE(cmd) == 'H' && _IOC_NR(cmd) == MAP_BUFFER_NR && arg
	      && _IOC_SIZE(cmd) == sizeof(struct nvhost_channel_map_buffer_args);
	if (!record && !submit && !map)
		return real_ioctl(fd, request, arg);  /* patching only: nothing else matters */
	if (!record && map) {  /* only VIC's maps matter; nvgpu's requests share the 'H' type */
		char dev[96];

		device_of(fd, dev, sizeof(dev));
		if (!strstr(dev, "vic"))
			return real_ioctl(fd, request, arg);
	}

	pthread_mutex_lock(&lock);
	if (submit) {
		patch_submit(fd, arg);
		if (record)
			record_submit(fd, arg);
	}
	pthread_mutex_unlock(&lock);
	ret = real_ioctl(fd, request, arg);
	err = errno;
	pthread_mutex_lock(&lock);
	if (!ret && map)
		record_map(arg);
	if (record)
		count_request(fd, cmd, ret != 0);
	pthread_mutex_unlock(&lock);
	errno = err;
	return ret;
}

/*
 * For a program run with the shim: the groups VIC_PATCH set, and in COUNTS
 * the jobs seen, patched, unchanged, skipped and failed so far.
 */
__attribute__((visibility("default"))) unsigned int vic_patch_counts(unsigned int counts[5])
{
	pthread_mutex_lock(&lock);
	counts[0] = seen;
	counts[1] = patched;
	counts[2] = unchanged;
	counts[3] = skipped;
	counts[4] = failed;
	pthread_mutex_unlock(&lock);
	return patch;
}

__attribute__((constructor)) static void loaded(void)
{
	char exe[256] = "";
	ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);

	if (n > 0)
		exe[n] = '\0';
	say("vic_record loaded in pid %d (%s)", (int)getpid(), exe);
	parse_patch();
}

__attribute__((destructor)) static void unloaded(void)
{
	FILE *f;
	unsigned int i;

	pthread_mutex_lock(&lock);
	f = open_file("w", "p%d-requests.txt", (int)getpid());
	for (i = 0; f && i < nrequests; i++)
		fprintf(f, "REQUEST dev=%s cmd=0x%08x type=%c nr=%u size=%u calls=%lu failed=%lu\n", requests[i].dev,
			requests[i].cmd, _IOC_TYPE(requests[i].cmd), _IOC_NR(requests[i].cmd),
			_IOC_SIZE(requests[i].cmd), requests[i].calls, requests[i].failed);
	if (f)
		fclose(f);
	say("vic_record: %u job(s) recorded", jobs);
	if (patch)
		say("vic_patch: groups=0x%x jobs=%u patched=%u unchanged=%u skipped=%u failed=%u", patch, seen, patched,
		    unchanged, skipped, failed);
	pthread_mutex_unlock(&lock);
}

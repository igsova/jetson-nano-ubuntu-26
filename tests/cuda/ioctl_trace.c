/* LD_PRELOAD trace of the GPU driver requests a process makes. Each ioctl on
 * an nvgpu, nvhost or nvmap device gets one line with the device, request,
 * result and the argument bytes before and after the call, appended to
 * $IOCTL_TRACE (default stderr) as it happens. Address-space requests and
 * nvmap handle requests are traced up to 256 times each, every other request
 * 8 times, then only counted (the totals are written at exit). For the GPU
 * characteristics and VA region requests it also shows the start of the
 * buffer the driver filled in. Read-only: every call is passed through
 * unchanged. Used to compare what CUDA 10.2 asks of the JetPack 4 and
 * JetPack 5 GPU drivers.
 *   cc -O2 -shared -fPIC -o ioctl_trace.so ioctl_trace.c -ldl -lpthread */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DUMP_MAX 96 /* argument bytes shown */

struct entry { char path[160]; unsigned long request; unsigned long count; };
static struct entry table[256];
static int used;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int (*real_ioctl)(int, unsigned long, void *);
static FILE *out;

static void hex(char *dst, const unsigned char *src, size_t n)
{
	static const char digits[] = "0123456789abcdef";
	for (size_t i = 0; i < n; i++) {
		*dst++ = digits[src[i] >> 4];
		*dst++ = digits[src[i] & 15];
	}
	*dst = '\0';
}

static int traced_device(const char *path)
{
	return strstr(path, "nvhost") || strstr(path, "nvmap") || strstr(path, "nvgpu");
}

/* Bytes of the driver-filled buffer to show, and where its address is. */
static size_t pointed(unsigned long request, const unsigned char *arg, const void **buf)
{
	unsigned type = (request >> 8) & 0xff, nr = request & 0xff;
	unsigned long long addr;
	unsigned size;
	if (type == 'G' && nr == 5) {		/* GET_CHARACTERISTICS */
		memcpy(&addr, arg + 8, sizeof addr);
		memcpy(&size, arg, sizeof size);
	} else if (type == 'A' && nr == 8) {	/* GET_VA_REGIONS */
		memcpy(&addr, arg, sizeof addr);
		memcpy(&size, arg + 8, sizeof size);
	} else {
		return 0;
	}
	*buf = (const void *)(unsigned long)addr;
	return addr ? (size < DUMP_MAX ? size : DUMP_MAX) : 0;
}

/* Address-space ('A') requests and nvmap ('N') create, alloc and free. */
static unsigned long limit(unsigned long request)
{
	unsigned type = (request >> 8) & 0xff, nr = request & 0xff;
	if (type == 'A' || (type == 'N' && nr <= 4))
		return 256;
	return 8;
}

int ioctl(int fd, unsigned long request, ...)
{
	va_list ap;
	va_start(ap, request);
	void *arg = va_arg(ap, void *);
	va_end(ap);
	if (!real_ioctl)
		real_ioctl = (int (*)(int, unsigned long, void *))dlsym(RTLD_NEXT, "ioctl");
	char link[32], path[160];
	snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
	ssize_t n = readlink(link, path, sizeof path - 1);
	path[n > 0 ? n : 0] = '\0';
	if (!traced_device(path))
		return real_ioctl(fd, request, arg);

	size_t size = (request >> 16) & 0x3fff;
	int readable = arg && ((request >> 30) & 3);
	size_t shown = readable ? (size < DUMP_MAX ? size : DUMP_MAX) : 0;
	unsigned char before[DUMP_MAX];
	if (shown)
		memcpy(before, arg, shown);
	int ret = real_ioctl(fd, request, arg);
	int saved = errno;

	pthread_mutex_lock(&lock);
	int i;
	for (i = 0; i < used; i++)
		if (table[i].request == request && !strcmp(table[i].path, path))
			break;
	if (i == used && used < (int)(sizeof table / sizeof *table)) {
		strcpy(table[used].path, path);
		table[used].request = request;
		used++;
	}
	unsigned long count = i < used ? ++table[i].count : 0;
	if (count && count <= limit(request)) {
		char in[2 * DUMP_MAX + 1], res[2 * DUMP_MAX + 1], mem[2 * DUMP_MAX + 1];
		const void *buf = NULL;
		size_t filled = ret == 0 && shown >= 16 ? pointed(request, arg, &buf) : 0;
		hex(in, before, shown);
		hex(res, arg, shown);
		hex(mem, buf, filled);
		if (!out) {
			const char *name = getenv("IOCTL_TRACE");
			out = name ? fopen(name, "a") : NULL;
			if (!out)
				out = stderr;
			setvbuf(out, NULL, _IOLBF, 0);
		}
		fprintf(out, "IOCTL %s req=0x%08lx n=%lu arg=%p ret=%d errno=%d in=%s out=%s%s%s\n",
			path, request, count, arg, ret, ret < 0 ? saved : 0, in, res,
			filled ? " mem=" : "", mem);
	}
	pthread_mutex_unlock(&lock);
	errno = saved;
	return ret;
}

__attribute__((destructor)) static void report(void)
{
	pthread_mutex_lock(&lock);
	FILE *dst = out ? out : stderr;
	for (int i = 0; i < used; i++)
		fprintf(dst, "IOCTL_COUNT %s req=0x%08lx count=%lu\n",
			table[i].path, table[i].request, table[i].count);
	pthread_mutex_unlock(&lock);
}

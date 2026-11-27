/* LD_PRELOAD census of the ioctls a process issues, grouped by device and
 * request, written at exit to $IOCTL_CENSUS (default stderr). Read-only:
 * every call is passed through unchanged. Used to list the nvgpu, nvhost and
 * nvmap requests CUDA 10.2 needs before trying a newer GPU driver.
 *   cc -O2 -shared -fPIC -o ioctl_census.so ioctl_census.c -ldl -lpthread */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct entry { char path[64]; unsigned long request; int err; unsigned long count; };
static struct entry table[1024];
static int used, overflow;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int (*real_ioctl)(int, unsigned long, void *);

int ioctl(int fd, unsigned long request, ...)
{
	va_list ap;
	va_start(ap, request);
	void *arg = va_arg(ap, void *);
	va_end(ap);
	if (!real_ioctl)
		real_ioctl = (int (*)(int, unsigned long, void *))dlsym(RTLD_NEXT, "ioctl");
	int ret = real_ioctl(fd, request, arg);
	int saved = errno, err = ret < 0 ? saved : 0;
	char link[32], path[64];
	snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
	ssize_t n = readlink(link, path, sizeof path - 1);
	path[n > 0 ? n : 0] = '\0';
	pthread_mutex_lock(&lock);
	int i;
	for (i = 0; i < used; i++)
		if (table[i].request == request && table[i].err == err && !strcmp(table[i].path, path))
			break;
	if (i == used && used < (int)(sizeof table / sizeof *table)) {
		strcpy(table[used].path, path);
		table[used].request = request;
		table[used].err = err;
		used++;
	}
	if (i < used)
		table[i].count++;
	else
		overflow++;
	pthread_mutex_unlock(&lock);
	errno = saved;
	return ret;
}

__attribute__((destructor)) static void report(void)
{
	const char *name = getenv("IOCTL_CENSUS");
	FILE *out = name ? fopen(name, "a") : NULL;
	if (!out)
		out = stderr;
	pthread_mutex_lock(&lock);
	for (int i = 0; i < used; i++) {
		unsigned long r = table[i].request;
		unsigned type = (r >> 8) & 0xff;
		fprintf(out, "IOCTL path=%s req=0x%08lx dir=%lu type=0x%02x(%c) nr=%lu size=%lu errno=%d count=%lu\n",
			table[i].path[0] ? table[i].path : "?", r, (r >> 30) & 3, type,
			type >= 0x20 && type < 0x7f ? (int)type : '.', r & 0xff,
			(r >> 16) & 0x3fff, table[i].err, table[i].count);
	}
	fprintf(out, "IOCTL_CENSUS_ENTRIES=%d overflow=%d\n", used, overflow);
	pthread_mutex_unlock(&lock);
	if (out != stderr)
		fclose(out);
}

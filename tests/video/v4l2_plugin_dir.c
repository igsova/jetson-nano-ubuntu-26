/*
 * LD_PRELOAD shim that lets libv4l2 find its plugins (NVIDIA's V4L2 codec
 * plugin, libv4l2_nvvideocodec.so) somewhere other than under /usr/lib: in
 * probe-l4t-codec.sh's scratch folder of unpacked packages, or in
 * nano-l4t-r32-video's own folder, where nano-r32-video preloads it.
 *
 * NVIDIA's libv4l2 looks for plugins with glob() on a pattern in a fixed
 * folder, /usr/lib/aarch64-linux-gnu/libv4l/plugins/nv. Only patterns that
 * start with "/" and contain "/libv4l/" are changed:
 * - with V4L2_PLUGIN_DIR set, the pattern's folder is replaced by that one,
 *   keeping what follows the pattern's last "/", silently;
 * - otherwise, with V4L2_PLUGIN_ROOT set, a pattern that does not already
 *   start with that root is looked up under the root, and a line on
 *   standard error says so.
 * Every other call goes to the C library's glob() unchanged. It changes no
 * file.
 *
 * Build: gcc -shared -fPIC -O2 -o v4l2_plugin_dir.so v4l2_plugin_dir.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <glob.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*glob_fn)(const char *, int, int (*)(const char *, int), glob_t *);
typedef int (*glob64_fn)(const char *, int, int (*)(const char *, int), glob64_t *);

/* Writes the redirected pattern into buf and returns it, or returns pattern. */
static const char *redirect(const char *pattern, char *buf, size_t size)
{
	const char *dir = getenv("V4L2_PLUGIN_DIR");
	const char *root = getenv("V4L2_PLUGIN_ROOT");
	size_t n;

	if (!pattern || pattern[0] != '/' || !strstr(pattern, "/libv4l/"))
		return pattern;
	if (dir && *dir) {
		if ((size_t)snprintf(buf, size, "%s%s", dir, strrchr(pattern, '/')) >= size)
			return pattern;
		return buf;
	}
	if (!root || !*root)
		return pattern;
	n = strlen(root);
	if (strncmp(pattern, root, n) == 0 && (pattern[n] == '/' || pattern[n] == '\0'))
		return pattern;
	if ((size_t)snprintf(buf, size, "%s%s", root, pattern) >= size)
		return pattern;
	fprintf(stderr, "V4L2_PLUGIN_DIR %s -> %s\n", pattern, buf);
	return buf;
}

int glob(const char *pattern, int flags, int (*errfunc)(const char *, int), glob_t *pglob)
{
	static glob_fn real;
	char buf[4096];

	if (!real)
		real = (glob_fn)dlsym(RTLD_NEXT, "glob");
	return real(redirect(pattern, buf, sizeof(buf)), flags, errfunc, pglob);
}

int glob64(const char *pattern, int flags, int (*errfunc)(const char *, int), glob64_t *pglob)
{
	static glob64_fn real;
	char buf[4096];

	if (!real)
		real = (glob64_fn)dlsym(RTLD_NEXT, "glob64");
	return real(redirect(pattern, buf, sizeof(buf)), flags, errfunc, pglob);
}

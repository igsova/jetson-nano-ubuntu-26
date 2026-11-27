/*
 * CPU clock check for the JetPack 5 trial: spin a register-only integer loop
 * on THREADS threads for SECONDS and print each thread's rate in millions of
 * iterations per second. The loop never touches memory, so its rate follows
 * the CPU clock alone: at the same clock both kernels should match.
 *
 * Build: cc -O2 -pthread -o cpu_spin cpu_spin.c
 * Usage: cpu_spin THREADS SECONDS
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define CHUNK 1000000u
#define MAX_THREADS 64

struct spin {
	pthread_t thread;
	double seconds, elapsed;
	unsigned long chunks;
	uint64_t x;
};

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void *spin(void *arg)
{
	struct spin *s = arg;
	uint64_t x = s->x;
	double start = now();

	do {
		for (unsigned int i = 0; i < CHUNK; i++) {
			x ^= x << 13;
			x ^= x >> 7;
			x ^= x << 17;
		}
		s->chunks++;
		s->elapsed = now() - start;
	} while (s->elapsed < s->seconds);
	s->x = x;
	return NULL;
}

int main(int argc, char **argv)
{
	struct spin spins[MAX_THREADS] = {0};
	double low = 0, high = 0, total = 0;
	uint64_t check = 0;
	int threads, i;
	double seconds;

	if (argc != 3 || (threads = atoi(argv[1])) < 1 || threads > MAX_THREADS ||
	    (seconds = atof(argv[2])) <= 0) {
		fprintf(stderr, "usage: %s THREADS SECONDS\n", argv[0]);
		return 2;
	}
	for (i = 0; i < threads; i++) {
		spins[i].seconds = seconds;
		spins[i].x = 88172645463325252ull + i;
		if (pthread_create(&spins[i].thread, NULL, spin, &spins[i])) {
			fprintf(stderr, "pthread_create failed\n");
			return 1;
		}
	}
	for (i = 0; i < threads; i++) {
		double rate;

		pthread_join(spins[i].thread, NULL);
		rate = spins[i].chunks * (CHUNK / 1e6) / spins[i].elapsed;
		printf("thread %d: %lu M iterations in %.3f s = %.1f M/s\n",
		       i, spins[i].chunks, spins[i].elapsed, rate);
		low = i ? (rate < low ? rate : low) : rate;
		high = rate > high ? rate : high;
		total += rate;
		check ^= spins[i].x;
	}
	printf("CPU_SPIN threads=%d seconds=%.1f rate_min=%.1f rate_max=%.1f total=%.1f check=%016llx\n",
	       threads, seconds, low, high, total, (unsigned long long)check);
	return 0;
}

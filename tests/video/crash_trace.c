/*
 * LD_PRELOAD shim that reports where a program crashed, for
 * scripts/jetson/probes/probe-l4t-codec.sh: JetPack 5's H.264 encoder died of
 * SIGSEGV on the Nano (2026-10-23) inside NVIDIA's closed libraries.
 *
 * On SIGSEGV, SIGBUS, SIGILL, SIGFPE or SIGABRT it writes to standard error
 * a CRASH line (the signal, its code, the faulting address, and the program
 * counter and link register as a library and an offset in it, with the
 * nearest exported symbol when there is one), on arm64 the registers
 * (CRASH_REGS), then a CRASH_FRAME line for each frame backtrace() finds,
 * and lets the signal kill the program as it would have. gst-launch-1.0
 * needs --no-fault, or its own handler replaces this one. It changes nothing
 * else.
 *
 * Build: gcc -shared -fPIC -O2 -o crash_trace.so crash_trace.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

#define MAX_FRAMES 32

static const int caught[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT };

static void say(const char *text, int n)
{
	if (n > 0)
		(void)!write(2, text, (size_t)n);
}

/* " LABEL=library+0xOFFSET(symbol+0xOFFSET)", or the bare address. */
static void where(const char *label, void *address)
{
	char line[640];
	Dl_info info;
	int n;

	if (address && dladdr(address, &info) && info.dli_fname) {
		n = snprintf(line, sizeof(line), " %s=%s+0x%lx", label, info.dli_fname,
			     (unsigned long)((char *)address - (char *)info.dli_fbase));
		if (info.dli_sname && info.dli_saddr && n > 0 && (size_t)n < sizeof(line))
			n += snprintf(line + n, sizeof(line) - (size_t)n, "(%s+0x%lx)", info.dli_sname,
				      (unsigned long)((char *)address - (char *)info.dli_saddr));
	} else {
		n = snprintf(line, sizeof(line), " %s=%p", label, address);
	}
	if (n > (int)sizeof(line) - 1)
		n = (int)sizeof(line) - 1;
	say(line, n);
}

static void crashed(int sig, siginfo_t *si, void *context)
{
	ucontext_t *uc = context;
	void *frames[MAX_FRAMES], *pc = NULL, *lr = NULL;
	char line[256];
	int i, count;

#if defined(__aarch64__)
	pc = (void *)uc->uc_mcontext.pc;
	lr = (void *)uc->uc_mcontext.regs[30];
#elif defined(__x86_64__)
	pc = (void *)uc->uc_mcontext.gregs[REG_RIP];
#else
	(void)uc;
#endif
	say(line, snprintf(line, sizeof(line), "CRASH signal=%d code=%d addr=%p pid=%d tid=%d", sig, si->si_code,
			   si->si_addr, (int)getpid(), (int)gettid()));
	where("pc", pc);
	where("lr", lr);
	say("\n", 1);
#if defined(__aarch64__)
	for (i = 0; i < 31; i += 8) {  /* the registers, for what the faulting instruction read */
		int j, n = snprintf(line, sizeof(line), "CRASH_REGS");

		for (j = i; j < i + 8 && j < 31; j++)
			n += snprintf(line + n, sizeof(line) - (size_t)n, " x%d=%llx", j,
				      (unsigned long long)uc->uc_mcontext.regs[j]);
		if (i + 8 >= 31)
			n += snprintf(line + n, sizeof(line) - (size_t)n, " sp=%llx", (unsigned long long)uc->uc_mcontext.sp);
		say(line, n);
		say("\n", 1);
	}
#endif
	count = backtrace(frames, MAX_FRAMES);
	for (i = 0; i < count; i++) {
		say(line, snprintf(line, sizeof(line), "CRASH_FRAME %d", i));
		where("at", frames[i]);
		say("\n", 1);
	}
	/* SA_RESETHAND gave the signal its default action back: let it act. */
	raise(sig);
}

__attribute__((constructor)) static void armed(void)
{
	static char stack[65536];
	stack_t alt = { .ss_sp = stack, .ss_size = sizeof(stack) };
	struct sigaction action;
	void *frame;
	unsigned int i;

	backtrace(&frame, 1);  /* loads libgcc_s now, not in the handler */
	sigaltstack(&alt, NULL);  /* the main thread's own stack may be what overflowed */
	memset(&action, 0, sizeof(action));
	action.sa_sigaction = crashed;
	action.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK;
	sigemptyset(&action.sa_mask);
	for (i = 0; i < sizeof(caught) / sizeof(caught[0]); i++)
		sigaction(caught[i], &action, NULL);
}

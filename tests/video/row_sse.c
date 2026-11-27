/*
 * The CUDA kernel of tests/video/vic_cuda.py: for each row of a frame, each
 * channel's squared error of VIC's RGBA output against limited-range BT.601
 * from the I420 input, with nearest chroma moved one pixel across (the model
 * colour_fit.py --check 1 tests: VIC takes the chroma of the pixel to the
 * right on odd pixels). With DOWN 0 each row takes its own row pair's
 * chroma; with DOWN 1 odd rows take the next pair's, as JetPack 5's
 * converter does on the Nano without the fix's chromaloc group
 * (2026-10-17). Integer arithmetic, so that the CPU can repeat any row
 * exactly; the coefficients are colour_fit.py's, times 65536 and rounded.
 * Pixels within EDGE of the frame's sides are not compared, as there.
 *
 * One thread a row: sse[3 * y + c] is row y's sum for channel c (R, G, B),
 * and 0 for the rows not compared.
 *
 * vic_cuda.py carries this file built for the GPU (sm_53, PTX ISA 4.2, which
 * the CUDA 11.4 driver's JIT compiler takes):
 *   clang-18 --target=nvptx64-nvidia-cuda -march=sm_53 -O2 -S -o row_sse.ptx row_sse.c
 * Built for the host (cc -shared -fPIC), row_sse_host() runs one row, for a
 * stand-in libcuda in host tests.
 */
#define EDGE 2
#define MOVE 1
#define K_Y 76309
#define K_RV 104597
#define K_GU (-25675)
#define K_GV (-53279)
#define K_BU 132201

static int clamp255(int value)
{
	return value < 0 ? 0 : value > 255 ? 255 : value;
}

static void row_sse_row(const unsigned char *i420, const unsigned char *rgba, int width, int height,
			int down, unsigned long long *sse, int y)
{
	unsigned long long r = 0, g = 0, b = 0;
	int x;

	if (y >= EDGE && y < height - EDGE) {
		int cy = (y + down) / 2 < height / 2 ? (y + down) / 2 : height / 2 - 1;
		const unsigned char *luma = i420 + (long)y * width;
		const unsigned char *u = i420 + (long)width * height + (long)cy * (width / 2);
		const unsigned char *v = u + (long)(width / 2) * (height / 2);
		const unsigned char *out = rgba + (long)y * width * 4;

		for (x = EDGE; x < width - EDGE; x++) {
			int c = (x + MOVE) / 2;
			int l = K_Y * (luma[x] - 16) + 32768;
			int cu = u[c] - 128, cv = v[c] - 128;
			int d;

			d = clamp255((l + K_RV * cv) >> 16) - out[4 * x];
			r += d * d;
			d = clamp255((l + K_GU * cu + K_GV * cv) >> 16) - out[4 * x + 1];
			g += d * d;
			d = clamp255((l + K_BU * cu) >> 16) - out[4 * x + 2];
			b += d * d;
		}
	}
	sse[3 * y] = r;
	sse[3 * y + 1] = g;
	sse[3 * y + 2] = b;
}

#ifdef __NVPTX__
__attribute__((nvptx_kernel)) void row_sse(const unsigned char *i420, const unsigned char *rgba, int width,
					   int height, int down, unsigned long long *sse)
{
	int y = __nvvm_read_ptx_sreg_ctaid_x() * __nvvm_read_ptx_sreg_ntid_x() + __nvvm_read_ptx_sreg_tid_x();

	if (y < height)
		row_sse_row(i420, rgba, width, height, down, sse, y);
}
#else
void row_sse_host(const unsigned char *i420, const unsigned char *rgba, int width, int height, int down,
		  unsigned long long *sse, int y)
{
	if (y < height)
		row_sse_row(i420, rgba, width, height, down, sse, y);
}
#endif

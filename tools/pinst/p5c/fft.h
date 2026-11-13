/* PINST5 C encoder: the shared transforms (owner: the integrator).
 *
 * Double precision, power-of-two sizes only, no global state: a plan is made
 * once per size by its caller and is read-only afterwards, so one plan may be
 * shared by any number of calls. Matches numpy/scipy (pocketfft) to rounding
 * (~1e-15 relative), not bit for bit.
 *
 *   p5fft_rfft  : numpy.fft.rfft(x, N)            N real in, N/2+1 complex out
 *   p5fft_dct4  : scipy.fft.dct(x, type=4) * 0.5  i.e. y[k] = sum x[n] cos(pi/N (n+.5)(k+.5))
 *   p5fft_cfft  : forward complex DFT, exp(-2 pi i nk/N), in place
 */
#ifndef P5FFT_H
#define P5FFT_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct p5fft_plan p5fft_plan;

/* N must be a power of two >= 4. Returns NULL otherwise or on no memory. */
p5fft_plan *p5fft_plan_new(int N);
void p5fft_plan_free(p5fft_plan *p);
int p5fft_size(const p5fft_plan *p);

/* Complex in place, interleaved re,im; p made with p5fft_plan_new(N). */
void p5fft_cfft(const p5fft_plan *p, double *z);

/* Real FFT of size N. out: N/2+1 complex (interleaved, N+2 doubles).
 * p must be a plan for N. scratch: N doubles (may be NULL: allocates). */
void p5fft_rfft(const p5fft_plan *p, const double *x, double *out, double *scratch);

/* DCT-IV of size N (scipy's unnormalised type 4, halved). p must be a plan
 * for N. x and y may be the same array. scratch: N doubles (may be NULL). */
void p5fft_dct4(const p5fft_plan *p, const double *x, double *y, double *scratch);

#ifdef __cplusplus
}
#endif
#endif

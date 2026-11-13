/* PINST5 C encoder, stage TQ: the MDCT layers (port of frozen p5/transform.py).
 *
 * The layer grid (pinst_codec.layer_windows): frame f of a layer that starts
 * at sample `start` spans start + f*M - M/2 .. start + f*M + 3M/2, sine
 * window, frame 0's left half flat and folded at `start`. Nothing before
 * `start` is read or made.
 *
 * Coefficient arrays are row-major (frames x M) doubles. M is a power of
 * two, 4 .. 65536 (the encoder uses 128 and 1024).
 *
 * Tables (one FFT plan and the window pieces per M) are made once, on first
 * use of an M, and are read-only afterwards. Call p5tq_init() once before
 * using these functions from more than one thread; it builds the tables for
 * 128 and 1024 (any other M is built on its first call).
 */
#ifndef P5_MDCT_H
#define P5_MDCT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Builds the tables for M = 128 and 1024. Returns 0, or -1 on no memory. */
int p5tq_init(void);

/* pc.layer_frames(n, M): frames a layer of n samples has. */
int64_t p5_layer_frames(int64_t n, int64_t M);

/* transform.frames(n, M, start) = pc.layer_frames(n - start, M). */
int64_t p5_frames(int64_t n, int64_t M, int64_t start);

/* transform._last_nonzero: index of the last nonzero sample of e[start:n],
 * or -1. */
int64_t p5_last_nonzero(const double *e, int64_t n, int64_t start);

/* Weight modes of p5_forward: the signal transformed is
 *   P5W_NONE  e
 *   P5W_MUL   e * w           (encode: transform.forward(e * w, M, s))
 *   P5W_MASK  e * (w > 0)     (encode: transform.forward(g * (w > 0), M, s))
 * computed per sample as numpy does, so no product array is needed. */
enum { P5W_NONE = 0, P5W_MUL = 1, P5W_MASK = 2 };

/* transform.forward(e', M, start), e' as wmode says (w ignored for
 * P5W_NONE): the frames from `start` up to the last that touches e''s last
 * nonzero sample at or after `start`. Returns a malloc'd (frames x M) array
 * and sets *frames, or NULL on bad M / no memory. (The Python cache of the
 * last few results is not ported: a caller keeps what it wants to reuse.) */
double *p5_forward(const double *e, const double *w, int wmode, int64_t n, int64_t M,
                   int64_t start, int64_t *frames);

/* The number of frames p5_forward would return, without transforming. */
int64_t p5_forward_frames(const double *e, const double *w, int wmode, int64_t n, int64_t M,
                          int64_t start);

/* transform.inverse(X, n, M, start): X is (F x K), K <= M, the missing
 * coefficients zero. Writes n samples to y (exactly zero before start).
 * Double precision (a DCT-IV per frame instead of the Python matrix
 * product). Returns 0, or -1 on bad M / no memory. */
int p5_inverse(const double *X, int64_t F, int64_t K, int64_t n, int64_t M, int64_t start,
               double *y);

#ifdef __cplusplus
}
#endif
#endif

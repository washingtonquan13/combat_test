/* PINST5 C encoder: the encoder's measures and decisions (owner: PK).
 *
 * Frozen p5/encode.py's helpers, with numpy's semantics where they set the
 * rounding: np.sum is numpy's pairwise sum (8 accumulators, blocks of 128,
 * over the whole array from 0.0; per row for an axis-1 mean), np.convolve
 * with ones(8)/8 is OpenBLAS ddot's left-to-right sum, np.log10 and the rest
 * are the C runtime's (the same ucrt numpy calls on Windows).
 *
 * Signals are double, with a stride in doubles so a column of an
 * interleaved (n, channels) array is read in place: x + c, stride channels.
 * Nothing here allocates except p5_pre_init (freed by p5_pre_free) and
 * p5_pre_echo_db (which calls it).
 */
#ifndef P5MEASURE_H
#define P5MEASURE_H

#include <stdint.h>

#include "p5code.h"     /* P5_API */

#ifdef __cplusplus
extern "C" {
#endif

/* encode.py's constants */
#define P5_SIDE_DB (-40.0)
#define P5_STEREO_COST 0.03
#define P5_SNR_TOL 0.5
#define P5_PRE_TOL 1.0
#define P5_SNR_GAIN 2.0
#define P5_PRE_GAIN 2.0
#define P5_PRE_OK 1.0
#define P5_FIX_COST 0.25
#define P5_PEAK_OVER 1.02
#define P5_PEAK_DB 6.0
#define P5_PEAK_ROUNDS 3
#define P5_PEAK_LONG_M 1024     /* blocks.LONG_M: _peaks' filter is 2 * LONG_M */

/* ------------------------------------------------------------ sums */

/* np.add.reduce of a contiguous float64 array (numpy's pairwise_sum). */
P5_API double p5_pairwise_sum(const double *a, int64_t n);
/* (x ** 2).sum() */
P5_API double p5_sumsq(const double *x, int64_t sx, int64_t n);
/* ((x - y) ** 2).sum() */
P5_API double p5_sumsqdiff(const double *x, int64_t sx, const double *y, int64_t sy, int64_t n);

/* ------------------------------------------------------------ the measures */

/* encode._snr_db(x, y) */
P5_API double p5_snr_db(const double *x, int64_t sx, const double *y, int64_t sy, int64_t n);
/* the same with xe = max((x**2).sum(), 1e-30) found once for many y */
P5_API double p5_snr_db_xe(double xe, const double *x, int64_t sx, const double *y, int64_t sy, int64_t n);

/* encode.pre_echo_db in two halves: the source's (its 1 ms block levels, the
 * hits, the floor), found once, then any number of decodes measured
 * against it (p5_C/encode.py's _PreEcho). */
typedef struct {
    int64_t b, m;           /* block length, blocks; m < 30 measures 0 */
    int64_t nhits;
    int64_t *hits;          /* the hit blocks, all > 0 */
    double *floor;          /* (m,) max(s, top - 60) */
} P5PreEcho;

P5_API int p5_pre_init(P5PreEcho *pe, const double *x, int64_t sx, int64_t n, int64_t sr);    /* 0, or -1 no memory */
P5_API double p5_pre_measure(const P5PreEcho *pe, const double *y, int64_t sy);
P5_API void p5_pre_free(P5PreEcho *pe);
/* encode.pre_echo_db(x, y, sr) (NaN on no memory) */
P5_API double p5_pre_echo_db(const double *x, int64_t sx, const double *y, int64_t sy, int64_t n, int64_t sr);

/* encode.channels_of: x interleaved (n, nch), nch 1 or 2. mono: mid = x, the
 * flag 0; a pair: mid, side (zeroed when side_db < SIDE_DB), the flag 1.
 * side may be NULL for mono. side_db (may be NULL) gets the measure, 0 for mono. */
P5_API int p5_channels_of(const double *x, int64_t n, int64_t nch, double *mid, double *side, double *side_db);

/* ------------------------------------------------------------ frames */

/* scipy.ndimage.maximum_filter1d(t, size, mode="constant", cval) with origin 0:
 * out[i] = max of t over [i - size/2, i + size - size/2 - 1], cval outside. */
P5_API void p5_maximum_filter1d(const double *t, int64_t n, int64_t size, double cval, double *out);
/* encode._frame_max(t, M, s, F): out[f] = maximum_filter1d(t, 2M)[min(s + f*M + M/2, n - 1)],
 * each frame's window found directly (no pass over all of t). */
P5_API void p5_frame_max(const double *t, int64_t n, int64_t M, int64_t s, int64_t F, double *out);
/* the same from a filter made once: mf = maximum_filter1d(t, 2M, 0) (p5_C's _Tight) */
P5_API void p5_frame_max_mf(const double *mf, int64_t n, int64_t M, int64_t s, int64_t F, double *out);
/* encode._fit: X (rows, cols) cut or zero-padded to F rows in out (F, cols). */
P5_API void p5_fit(const double *X, int64_t rows, int64_t cols, int64_t F, double *out);

/* ------------------------------------------------------------ the decisions */

/* encode._stereo's choice from each coding's (bytes, worse channel's SNR,
 * worse channel's pre-echo): 0 mid/side as summed, 1 mid/side under
 * heard_ms_db, 2 left/right. */
P5_API int p5_stereo_choice(const int64_t nb[3], const double snr[3], const double pre[3]);

/* encode._peaks: lim = PEAK_OVER * max |x| over every sample of every channel. */
P5_API double p5_peak_lim(const double *x, int64_t count);
/* One round of _peaks' rule on y (n, nch) interleaved: returns how many
 * samples are over lim (0: stop, t untouched); else t[over] becomes
 * near + PEAK_DB where near = maximum_filter1d(t, 2 * LONG_M)[over] > 0, dial
 * otherwise. scratch: n doubles. */
P5_API int64_t p5_peaks_step(const double *y, int64_t n, int64_t nch, double lim, double dial, double *t, double *scratch);

#ifdef __cplusplus
}
#endif
#endif

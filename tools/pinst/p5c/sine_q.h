/* PINST5 C encoder, stage SQ: the sine layer's code and its render (owner: SQ).
 *
 * The C port of the frozen Python (2f6c9a8):
 *   p5_sine_quantize      pc.quantize(ch, analysis.TIER), the model tier's track part:
 *                         estimate_f0_track, keyframes, steer_keys, the hdr/dt/df/da/f0
 *                         streams, the info ints, and `sizes` (LZMA'd lengths, via lz)
 *   p5_sine_tracks_of     analysis.tracks_of(code)
 *   p5_sine_render        analysis.render_sines(code, n)  (st_tracks, integrate mode)
 *   p5_sine_worth_keeping analysis.worth_keeping(x, det, sine_bytes)
 *   p5_sine_encode        analysis.encode_sines after _analyse: all of the above composed
 *
 * pc.SR is a parameter here (sr): steer_keys and the render read it.
 * tr->f0 is the analysis' f0 (find_pitch(x) or the hint), 0 for None.
 * No state is kept between calls.
 */
#ifndef P5_SINE_Q_H
#define P5_SINE_Q_H

#include "p5code.h"

#ifndef P5_API
#ifdef _WIN32
#define P5_API __declspec(dllexport)
#else
#define P5_API __attribute__((visibility("default")))
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* pc.quantize + the ints encode_sines sets. Fills out (ints, streams,
 * lz_sizes) even when no track survives. Returns n_tracks (>= 0), or -1 on
 * no memory / an lz error (out zeroed). out is overwritten, not freed first;
 * free it with p5_sine_free. */
P5_API int64_t p5_sine_quantize(const P5Tracks *tr, int64_t sr, p5_lz_fn lz, void *lzctx, P5Sine *out);

/* The decoded tracks, from the code alone. out->n = 0, out->H = the code's H,
 * out->f0 = 0; each track's ph is zero but its first frame. Returns 1, or 0 on
 * no memory or a malformed code (out left empty). Free with p5_tracks_free. */
P5_API int p5_sine_tracks_of(const P5Sine *s, P5Tracks *out);

/* render_sines: out (n samples) = the sines the decoder plays. s == NULL
 * gives zeros. Returns 1, or 0 on no memory or a malformed code.
 * p5_sine_render: the cosines by complex rotation from an exact cos every 64
 * samples, render_sines to rounding (about 1e-13 of the peak) and several times
 * faster. p5_sine_render_exact: native st_tracks, render_sines bit for bit. */
P5_API int p5_sine_render(const P5Sine *s, int64_t n, int64_t sr, double *out);
P5_API int p5_sine_render_exact(const P5Sine *s, int64_t n, int64_t sr, double *out);

/* worth_keeping: 1 keep, 0 drop. sine_bytes = the sum of s->lz_sizes. */
P5_API int p5_sine_worth_keeping(const double *x, const double *det, int64_t n, int64_t sine_bytes);

/* encode_sines after _analyse (tr = _analyse's tracks for x). Returns 1 with
 * out filled (and det, if not NULL, the render), 0 with no code (x silent,
 * n_tracks 0 or not worth keeping: out zeroed, det zeros), -1 on an error
 * (out zeroed). */
P5_API int p5_sine_encode(const double *x, int64_t n, int64_t sr, const P5Tracks *tr, p5_lz_fn lz, void *lzctx,
                          P5Sine *out, double *det);

#ifdef __cplusplus
}
#endif
#endif

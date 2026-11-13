/* PINST5 C encoder, stage SA: the sine analysis (owner: SA).
 *
 * The C port of frozen p5/analysis.py up to pc.quantize: the pitch the sound
 * shows (find_pitch), the tracker's window (window_for), the zero-phase
 * Blackman-Harris peaks (pc.find_peaks_frames) and the partial tracks
 * (pc.track_peaks, through native/trackfast.c's track_assign).
 *
 * Every function reads one channel of n samples at rate sr (pc.SR) and keeps
 * no state between calls. Returns: 0 ok, negative on no memory / bad input.
 */
#ifndef P5_SINE_AN_H
#define P5_SINE_AN_H

#include <stdint.h>

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

/* analysis.encode_sines up to pc.quantize: f0 = find_pitch(x) or f0_hint
 * (f0_hint <= 0: no hint), N = window_for(f0), then _analyse(x, f0, N).
 * Fills out: n, H (the hop), f0 (0 = none), the tracks in pc.track_peaks'
 * order; free with p5_tracks_free. x all zeros: no tracks, f0 = 0, H = 256
 * (encode_sines returns None there). */
P5_API int p5_sine_analyse(const double *x, int64_t n, int64_t sr, double f0_hint, P5Tracks *out);

/* analysis._analyse(x, f0, N) alone (f0 only goes to out->f0). */
P5_API int p5_sa_analyse(const double *x, int64_t n, int64_t sr, double f0, int64_t N, P5Tracks *out);

/* pc.onset_sample(x) (rel_db -40, 44-sample blocks). */
P5_API int64_t p5_sa_onset(const double *x, int64_t n);

/* analysis.find_pitch(x): 1 and *f0 set when the sound shows a pitch, 0 when
 * it shows none (None), negative on error. */
P5_API int p5_sa_find_pitch(const double *x, int64_t n, int64_t sr, double *f0);

/* analysis.window_for(f0); f0 <= 0 means none. */
P5_API int64_t p5_sa_window_for(double f0, int64_t sr);

/* pc.find_peaks_frames(x, N, H, fmax=fmax) with its other defaults: frame i's
 * peaks are f/a/ph[cuts[i] .. cuts[i+1]-1], in the Python order. */
typedef struct {
    int64_t F;
    int64_t *cuts;      /* F + 1 */
    double *f, *a, *ph;
} P5SAPeaks;

P5_API int p5_sa_find_peaks_frames(const double *x, int64_t n, int64_t sr, int64_t N, int64_t H, double fmax,
                                   P5SAPeaks *out);
P5_API void p5_sa_peaks_free(P5SAPeaks *p);

#ifdef __cplusplus
}
#endif
#endif

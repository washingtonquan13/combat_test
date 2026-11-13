/* PINST5 C encoder: what the stages hand each other (owner: the integrator).
 *
 * The C port of the frozen Python encoder (2f6c9a8, tools/pinst/p5). The C
 * encoder is the only encoder; the Python one is the reference that
 * scratchpad/gate/gate.py checks it against: "the same sound" (tier 1 equal
 * bytes or tier 2 inaudible difference), never "a decision changed" (tier 3).
 *
 * Rules for every file under p5c/:
 *   - double precision everywhere a Python float64 is; no float32 in any
 *     decision path. The build is build.bat: MSVC cl /O2 /fp:precise /MD (no
 *     /fp:fast, no FMA contraction), linking the shared UCRT so
 *     cos/sin/exp/log are the ones numpy calls.
 *   - exports: every entry point Python or a test calls is marked P5_API
 *     (defined below); stage-internal shared functions may be marked too.
 *   - deterministic: no global mutable state except read-only tables made
 *     once (plans, windows); every function is safe to call again and again
 *     in one process.
 *   - a stage's private helpers are static; the shared entry points are the
 *     ones declared here and in each stage's own header.
 *   - memory: arrays in these structs are malloc'd by the stage that fills
 *     them and freed by p5_*_free below.
 *
 * Ownership of files:
 *   fft.c/h                    integrator (shared rfft, cfft, dct4)
 *   p5code.h                   integrator (this file; ask, don't edit)
 *   sine_an.c/h       SA       sine analysis: pitch, window, peaks, tracks
 *   sine_q.c/h        SQ       sine quantize (model tier), render, worth_keeping
 *   mdct.c/h blocks.c/h quant.c/h   TQ   transform, block plan, layer quantizer
 *   pack.c/h encode.c/h p5enc.c build.sh encode.py   PK   file, glue, binding
 */
#ifndef P5CODE_H
#define P5CODE_H

#include <stdint.h>

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

/* ------------------------------------------------------------ bytes */

typedef struct {
    uint8_t *p;
    int64_t n;
} P5Buf;

/* The one thing C cannot do here: LZMA (raw LZMA2, preset 9|extreme,
 * dictionary the smallest power of two >= max(4096, n)), exactly
 * pinst_codec.lz_bytes. The Python binding passes a ctypes callback that
 * calls it. Returns the compressed length; writes it to out when out is not
 * NULL and cap is large enough (else returns the length and writes nothing).
 * n == 0 returns 0. A negative return is an error. */
typedef int64_t (*p5_lz_fn)(void *ctx, const uint8_t *in, int64_t n, uint8_t *out, int64_t cap);

/* ------------------------------------------------------------ the sine layer */

/* One partial track as pc.track_peaks returns it (pc.Track): frames
 * start .. start+len-1, f in Hz, a in dB, ph the measured phase. */
typedef struct {
    int64_t start, len;
    double *f, *a, *ph;
} P5Track;

/* pc.Channel's partial part, as analysis._analyse builds it. */
typedef struct {
    int64_t n;          /* samples */
    int64_t H;          /* the tracker's hop */
    double f0;          /* analysis' pitch (0 = none), ch.info["f0"] */
    int64_t ntracks;
    P5Track *tracks;    /* in pc.track_peaks' order */
} P5Tracks;

/* analysis.INT_KEYS, in order. */
enum { P5S_H, P5S_F_C, P5S_A_D, P5S_F0_C, P5S_PBITS, P5S_LOCK, P5S_F0_FRAMES, P5S_N_TRACKS, P5S_NINTS };
/* analysis.STREAM_KEYS, in order. */
enum { P5S_HDR, P5S_DT, P5S_DF, P5S_DA, P5S_F0, P5S_NSTREAMS };

/* contract.SineCode: the raw streams exactly as pc.quantize makes them
 * (dec.info["streams"]): before pack's frame-order reorder, before LZMA. */
typedef struct {
    int64_t ints[P5S_NINTS];
    P5Buf s[P5S_NSTREAMS];
    /* sizes the bound in analysis.worth_keeping uses: pc.quantize's `sizes`
     * for track_hdr, track_dt, track_df, track_da, f0 (LZMA'd lengths) */
    int64_t lz_sizes[P5S_NSTREAMS];
} P5Sine;

/* ------------------------------------------------------------ the MDCT layers */

/* contract.LayerCode. nbx = len(quant.edges(K, nbands)) - 1 is the column
 * count of sc and dq (it may differ from nbands). Row-major arrays. */
typedef struct {
    int64_t M, K, nbands, nbx, dead, frames, seed, start;
    double snr;
    int32_t *sc;        /* frames x nbx */
    int32_t *q;         /* frames x K, zero outside quant.coded_mask */
    int32_t *dq;        /* frames x nbx */
} P5Layer;

typedef struct {
    P5Sine *sines;      /* NULL: no sine layer */
    int64_t nlayers;
    P5Layer *layers;
} P5Channel;

/* contract.NoteCode. stereo: 0 mono (1 channel), 1 mid/side, 2 left/right. */
typedef struct {
    int64_t sr, n, stereo, nch;
    P5Channel ch[2];
} P5Note;

P5_API void p5_buf_free(P5Buf *b);
P5_API void p5_tracks_free(P5Tracks *t);
P5_API void p5_sine_free(P5Sine *s);       /* frees the streams, not s itself */
P5_API void p5_layer_free(P5Layer *L);     /* frees the arrays, not L itself */
P5_API void p5_channel_free(P5Channel *c);
P5_API void p5_note_free(P5Note *note);

#ifdef __cplusplus
}
#endif
#endif

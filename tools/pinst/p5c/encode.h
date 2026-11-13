/* PINST5 C encoder: one note -> bytes (owner: PK).
 *
 * p5_encode_note is frozen p5/encode.py's encode_note (2f6c9a8): channels_of,
 * the mono path or _stereo's three codings (each decoded and measured, the
 * choice by p5_stereo_choice), then _peaks' rounds (at most PEAK_ROUNDS),
 * packed by p5_pack.
 *
 * What the Python recomputes on every code(t) call is made once per note
 * here and reused:
 *   - a channel's sines (encode_sines is a function of the samples alone, so
 *     equal channels share one: lr's left and mid when side is silent, lr's
 *     right and left when they are equal), its remainder e, plan, and per
 *     piece X, Xs, Xr and the heard levels (per heard function);
 *   - top_db per block length;
 *   - each layer, keyed by (piece, seed, heard function, tight frames); a
 *     tight of all zeros is the same key as None (quantize's band SNR is never
 *     under 0 for dial >= 0, so max(bs, 0) is bs);
 *   - each kept layer's inverse transform, so a decode is the sines' render
 *     plus the cached inverses, added in the layer order decode.channel adds
 *     them (no pack/unpack between a coding and its measures);
 *   - each kept layer's LAYR section (the range coder starts fresh per
 *     section, so its bytes are a function of the channel index and the layer
 *     alone): coded on the first pack that holds the layer, copied after;
 *   - every LZMA call (a memo keyed by the input bytes wraps the callback).
 *
 * Sine render: by default p5_sine_render (the rotation render) for
 * encode_sines' det, its worth_keeping and the in-memory decode;
 * P5_SINE_RENDER_EXACT (compile time) picks p5_sine_render_exact
 * (render_sines bit for bit) instead. Either gives the same bytes on all
 * 1213 full-gate notes (gate --against c, 2026-11-13).
 */
#ifndef P5ENCODE_H
#define P5ENCODE_H

#include "p5code.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Errors (pack's are passed through: -1 .. -8, pack.h). */
enum {
    P5_ENC_OK = 0,
    P5_ENC_NOMEM = -1,
    P5_ENC_LZ = -2,
    P5_ENC_SINE = -20,      /* sine analysis, quantize or render failed */
    P5_ENC_TQ = -21,        /* a transform, plan or layer call failed (bad shape) */
    P5_ENC_ARG = -22
};

/* What one encode decided, for tests (all malloc'd; free with
 * p5_enc_debug_free). ncand is 1 (mono, or a silent pair) or 3; cand[i] is
 * candidate i's bytes before the peak rounds and ycand[i] its in-memory
 * decode (n x nout interleaved, nout = 1 for mono, 2 for a pair). y is the
 * in-memory decode of the returned bytes. layers_packed: layer sections in
 * every p5_pack the encode made; layers_coded: how many of them ran the
 * range coder (the rest were cached sections). */
typedef struct {
    int ncand, k, rounds;
    int64_t n, nout;
    P5Buf cand[3];
    double *ycand[3];
    double *y;
    int64_t layers_packed, layers_coded;
} P5EncDebug;

/* x: n x nch interleaved (nch 1, or >= 2: columns 0 and 1 are the pair, the
 * peak limit is over every column, as in the Python). f0: the pitch hint in
 * Hz; <= 0 or NaN is None. dial: contract.DIAL by default. lz:
 * pinst_codec.lz_bytes. dbg may be NULL. out: malloc'd, free with
 * p5_buf_free. Returns P5_ENC_OK or an error (out is then empty). */
int p5_encode_note(const double *x, int64_t n, int64_t nch, int64_t sr, double f0, double dial,
                   p5_lz_fn lz, void *lzctx, P5Buf *out, P5EncDebug *dbg);

void p5_enc_debug_free(P5EncDebug *d);

#ifdef __cplusplus
}
#endif
#endif

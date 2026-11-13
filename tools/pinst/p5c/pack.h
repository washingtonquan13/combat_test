/* PINST5 C encoder: the file (owner: PK).
 *
 * p5_pack is frozen p5/pack.py's pack(): the same bytes for the same
 * NoteCode. Layout and range coder: pack.py's docstring. The range coder is
 * p5/native/p5rc.c, compiled into the same DLL and called, not copied.
 *
 * What pack needs of quant (edges, coded_mask) is ported here as statics, so
 * this file depends on nothing but p5code.h and p5rc.c.
 */
#ifndef P5PACK_H
#define P5PACK_H

#include "p5code.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Errors: each is an assert (or an exception) in frozen pack.pack. */
enum {
    P5_PACK_OK = 0,
    P5_PACK_NOMEM = -1,
    P5_PACK_LZ = -2,        /* the LZMA callback failed */
    P5_PACK_SINE = -3,      /* a sine stream does not parse (pf._reorder's Cur ran off the end) */
    P5_PACK_SHAPE = -4,     /* nbx != len(quant.edges(K, nbands)) - 1, or edges do not end at K */
    P5_PACK_RANGE = -5,     /* a scale delta or coefficient code with |v| >= 2^31 */
    P5_PACK_OUTSIDE = -6,   /* "coefficients outside coded bands" */
    P5_PACK_RC = -7,        /* "range coder overflow" (pack.py's buffer of 64 + 8 * values) */
    P5_PACK_ARG = -8
};

/* note -> out (malloc'd; free with p5_buf_free). lz: pinst_codec.lz_bytes.
 * Returns P5_PACK_OK or an error above (out is then empty). */
P5_API int p5_pack(const P5Note *note, p5_lz_fn lz, void *ctx, P5Buf *out);

/* One LAYR section (tag, length, payload) as p5_pack writes it for layer L
 * of channel ci. The range coder starts fresh in every section, so these
 * bytes depend on (ci, L) only: a caller packing the same layer again (the
 * encoder's stereo candidates and _peaks rounds) codes it once. */
P5_API int p5_pack_layer(int64_t ci, const P5Layer *L, P5Buf *sec);

/* p5_pack with layers already coded: secs (NULL: code every layer) holds one
 * entry per layer, channel 0's then channel 1's, each p5_pack_layer(ci, L)
 * for that layer or NULL to code it here. Same bytes as p5_pack. */
P5_API int p5_pack_secs(const P5Note *note, p5_lz_fn lz, void *ctx, const P5Buf *const *secs, P5Buf *out);

/* Test hook: quant.edges(K, nbands) (pc._xf_edges) into ed (room for
 * nbands + 2); returns the count of edges. */
P5_API int64_t p5_pack_edges(int64_t K, int64_t nbands, int64_t *ed);

#ifdef __cplusplus
}
#endif
#endif

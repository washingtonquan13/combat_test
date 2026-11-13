/* PINST5 C encoder: the DLL's entry points for p5c/encode.py (owner: PK).
 *
 *   p5c_encode_note     encode.encode_note: x (n, nch) float64 C order -> bytes
 *   p5c_buf_free        frees what p5c_encode_note returned
 *   p5c_encode_debug    the same with what it decided (encode.h's P5EncDebug)
 *   p5c_debug_free
 *   p5c_sine_render_fast  1 unless built with P5_SINE_RENDER_EXACT
 */
#include "encode.h"

P5_API int p5c_encode_note(const double *x, int64_t n, int64_t nch, int64_t sr, double f0, double dial,
                           p5_lz_fn lz, void *lzctx, P5Buf *out) {
    return p5_encode_note(x, n, nch, sr, f0, dial, lz, lzctx, out, NULL);
}

P5_API int p5c_encode_debug(const double *x, int64_t n, int64_t nch, int64_t sr, double f0, double dial,
                            p5_lz_fn lz, void *lzctx, P5Buf *out, P5EncDebug *dbg) {
    return p5_encode_note(x, n, nch, sr, f0, dial, lz, lzctx, out, dbg);
}

P5_API void p5c_buf_free(P5Buf *b) { p5_buf_free(b); }

P5_API void p5c_debug_free(P5EncDebug *d) { p5_enc_debug_free(d); }

P5_API int p5c_sine_render_fast(void) {
#ifdef P5_SINE_RENDER_EXACT
    return 0;
#else
    return 1;
#endif
}

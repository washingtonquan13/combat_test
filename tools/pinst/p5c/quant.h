/* PINST5 C encoder, stage TQ: step sizes and the layer quantizer (port of frozen p5/quant.py).
 *
 * Coefficient arrays are row-major (frames x K) doubles, K the coefficients
 * per frame (the encoder's layers have K = M). Band arrays are row-major
 * (frames x nbx) doubles, nbx = p5_edges(K, nbands, ...) - 1 (18 bands ask
 * for 18, but duplicate edges merge: K = 128 gives 18, K = 1024 gives 19).
 *
 * The decisions are made in numpy's arithmetic order (pairwise band sums,
 * scipy's convolve1d for the time smoothing, half-even rounding), so codes
 * match the Python bit for bit unless a value sits on a rounding edge.
 * Nothing here keeps state; the white-noise flatness the tonality measure
 * divides by is a read-only table for (M, K) = (128, 128) and (1024, 1024),
 * the two layer shapes the encoder makes (any other shape returns -2).
 */
#ifndef P5_QUANT_H
#define P5_QUANT_H

#include <stdint.h>

#include "p5code.h"

#ifdef __cplusplus
extern "C" {
#endif

#define P5_NBANDS 18

/* quant.edges(K, nbands) = pc._xf_edges: writes the band edges (at most
 * nbands + 2 values) to ed and returns how many (nbx + 1). */
int64_t p5_edges(int64_t K, int64_t nbands, int64_t *ed);

/* pc.hash_uniform(seed, start, count): count values in [-1, 1). */
void p5_hash_uniform(int64_t seed, int64_t start, int64_t count, double *out);

/* pc.band_power_db(X, nbands): (F x nbx) mean power per coefficient, dB.
 * Returns nbx. */
int64_t p5_band_power_db(const double *X, int64_t F, int64_t K, int64_t nbands, double *out);

/* quant.top_db(Xnote): the loudest band of X (P5_NBANDS bands), dB per
 * coefficient. */
double p5_top_db(const double *X, int64_t F, int64_t K);

/* quant.tonality(Xref, M): (F x nbx) in [1e-6, 1]. Returns 0, -1 on no
 * memory, -2 for an (M, K) without a noise table. */
int p5_tonality(const double *Xref, int64_t F, int64_t K, int64_t M, double *eta);

/* quant.band_snr(Xref, M, snr): (F x nbx) dB. Returns as p5_tonality. */
int p5_band_snr(const double *Xref, int64_t F, int64_t K, int64_t M, double snr, double *bs);

/* quant.heard_db(Xs): nch channels' coefficients (each F x K) -> (F x nbx)
 * dB. Returns 0, -1 on no memory. */
int p5_heard_db(const double *const *Xs, int nch, int64_t F, int64_t K, double *out);

/* quant.heard_ms_db(Xm, Xs): a mid/side pair on one grid -> (F x nbx) dB.
 * Returns 0, -1 on no memory. */
int p5_heard_ms_db(const double *Xm, const double *Xs, int64_t F, int64_t K, double *out);

/* quant.quantize(X, Xref, M, seed, dial, top, heard, tight).
 *   X, Xref  F x K (Xref: the mid on X's grid, same frames)
 *   heard    F x nbx (p5_heard_db or p5_heard_ms_db on X's grid)
 *   tight    F values, or NULL (Python's None)
 * Returns 1 with *L filled (L->start = 0: the caller sets it; free with
 * p5_layer_free), 0 for Python's None (nothing live; *L zeroed), -1 on no
 * memory, -2 for an (M, K) without a noise table. */
int p5_quantize(const double *X, const double *Xref, int64_t F, int64_t K, int64_t M,
                int64_t seed, double dial, double top, const double *heard, const double *tight,
                P5Layer *L);

/* The snr a dial codes to (quant.quantize's round(dial, 2)): the snr
 * argument p5_band_snr takes for p5_quantize_bs. */
double p5_quant_snr(double dial);

/* p5_quantize with Xref's band_snr already made: bsnr is
 * p5_band_snr(Xref, F, K, M, p5_quant_snr(dial)), F x nbx. band_snr depends
 * on Xref, M and the dial only, so a caller coding the same piece again (the
 * stereo candidates, the _peaks rounds: only heard, tight or the side
 * change) makes it once and passes it here; same results as p5_quantize. */
int p5_quantize_bs(const double *X, int64_t F, int64_t K, int64_t M, int64_t seed, double dial,
                   double top, const double *heard, const double *tight, const double *bsnr,
                   P5Layer *L);

/* quant.dequantize(L): writes L->frames x L->K coefficients to Xd. Returns
 * 0, -1 on no memory. */
int p5_dequantize(const P5Layer *L, double *Xd);

/* quant.live_mask(L) / quant.coded_mask(L): frames x K, 1 or 0. */
void p5_live_mask(const P5Layer *L, uint8_t *mask);
void p5_coded_mask(const P5Layer *L, uint8_t *mask);

#ifdef __cplusplus
}
#endif
#endif

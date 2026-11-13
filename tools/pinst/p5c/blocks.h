/* PINST5 C encoder, stage TQ: where short and long blocks go (port of frozen p5/blocks.py).
 *
 * p5_plan(e, ref, heard) is blocks.plan: the pieces (M, w, s) the remainder
 * e is coded in, each as transform.forward(e * w, M, s). The weights are
 * not stored per piece: every w is made from one array, cov (n samples):
 *   kind P5PIECE_LONG   w = 1 - cov over the whole note
 *   kind P5PIECE_SHORT  w = cov on [a, b), zero elsewhere
 * p5_plan_wat gives one sample of a piece's w as numpy makes it (the same
 * bits), p5_plan_w fills a whole w array (for p5_forward's w argument).
 *
 * All arrays are doubles; e, ref and every heard channel have n samples.
 */
#ifndef P5_BLOCKS_H
#define P5_BLOCKS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define P5_SHORT_M 128
#define P5_LONG_M 1024

enum { P5PIECE_LONG = 0, P5PIECE_SHORT = 1 };

typedef struct {
    int64_t M;          /* 1024 (long) or 128 (short) */
    int64_t s;          /* the grid's first sample: transform.forward(e * w, M, s) */
    int64_t a, b;       /* SHORT: w = cov on [a, b); LONG: a = first nonzero of e, b = n */
    int kind;
} P5Piece;

typedef struct {
    int64_t n;
    double *cov;        /* n samples (NULL when there are no pieces) */
    int64_t npieces;
    P5Piece *pieces;    /* in blocks.plan's order: the long piece, then the short ones */
} P5Plan;

/* One sample of piece k's w. */
static inline double p5_plan_wat(const P5Plan *p, int64_t k, int64_t i) {
    const P5Piece *q = &p->pieces[k];
    if (q->kind == P5PIECE_LONG) return 1.0 - p->cov[i];
    return (i >= q->a && i < q->b) ? p->cov[i] : 0.0;
}

/* blocks.plan(e, ref, heard): heard is nheard channels (0, or left and right
 * for a mid/side pair; may be NULL when nheard is 0). Fills *out (free with
 * p5_plan_free). An e with nothing in it gives no pieces. Returns 0, or -1
 * on no memory. */
int p5_plan(const double *e, const double *ref, int64_t n, const double *const *heard,
            int nheard, P5Plan *out);
void p5_plan_free(P5Plan *p);

/* Fills w (n samples) with piece k's weight. */
void p5_plan_w(const P5Plan *p, int64_t k, double *w);

/* ---- the pieces of plan, for tests and other callers ---- */

/* pc.block_db(x, blk): 20 log10 rms of each whole blk-sample block, n / blk
 * values written to out. Returns the count. */
int64_t p5_block_db(const double *x, int64_t n, int64_t blk, double *out);

/* blocks._first_nonzero(e, w, start): the first index >= start where e (or
 * e * w, w may be NULL) is nonzero, or -1. */
int64_t p5_first_nonzero(const double *e, const double *w, int64_t n, int64_t start);

typedef struct {
    int64_t s;
    double j;
} P5Onset;

/* blocks.transients(e, top_db, gaps): writes up to n/128 hits (start
 * sample, jump dB, by-the-gap flag); returns the count, -1 on no memory. */
int64_t p5_transients(const double *e, int64_t n, double top_db, int gaps, int64_t *start,
                      double *jump, uint8_t *gap);

/* blocks.onsets(e, top_db, gaps): *out is malloc'd (free it; NULL when the
 * count is 0). Returns the count, -1 on no memory. */
int64_t p5_onsets(const double *e, int64_t n, double top_db, int gaps, P5Onset **out);

/* blocks.shared_onsets(own, ref_ons, share): sorted by sample; *out malloc'd.
 * Returns the count, -1 on no memory. */
int64_t p5_shared_onsets(const P5Onset *own, int64_t nown, const P5Onset *ref, int64_t nref,
                         int64_t share, P5Onset **out);

#ifdef __cplusplus
}
#endif
#endif

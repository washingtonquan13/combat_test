/* PINST5 C encoder, stage TQ: where short and long blocks go (port of frozen p5/blocks.py). See blocks.h.
 *
 * Sums are taken in numpy's order where a decision rests on them: a row
 * mean is numpy's pairwise sum (8 accumulators, halves past 128), the
 * 8-block mean of np.convolve a plain running sum, np.cumsum a running sum.
 */
#include "blocks.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define BLOCK 128
#define TRANSIENT_DB 12.0
#define TRANSIENT_GAP 2
#define TRANSIENT_PRE 256
#define TRANSIENT_POST 2048
#define TRANSIENT_RAMP 1024
#define AUDIBLE_DB (-60.0)
#define CLEAN_DB 25.0           /* contract.DIAL */
#define ONSET_OVER_PRE_DB 12.0
#define ONSET_UNDER_HIT_DB 24.0
#define ONSET_W 16
#define ONSET_SHARE (2 * BLOCK)
#define HEARD_SHARE ONSET_W

/* numpy's pairwise sum (DOUBLE_pairwise_sum) of a[i]^2 */
static double pw_sq(const double *a, int64_t n) {
    if (n < 8) {
        double r = 0.0;
        int64_t i;
        for (i = 0; i < n; i++) r += a[i] * a[i];
        return r;
    } else if (n <= 128) {
        double r[8], res;
        int64_t i;
        int j;
        for (j = 0; j < 8; j++) r[j] = a[j] * a[j];
        for (i = 8; i < n - (n % 8); i += 8)
            for (j = 0; j < 8; j++) r[j] += a[i + j] * a[i + j];
        res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]));
        for (; i < n; i++) res += a[i] * a[i];
        return res;
    } else {
        int64_t n2 = n / 2;
        n2 -= n2 % 8;
        return pw_sq(a, n2) + pw_sq(a + n2, n - n2);
    }
}

/* (e[:m*B].reshape(m, B) ** 2).mean(1) */
static void block_power(const double *x, int64_t m, double *p) {
    int64_t i;
    for (i = 0; i < m; i++) p[i] = pw_sq(x + i * BLOCK, BLOCK) / (double)BLOCK;
}

int64_t p5_block_db(const double *x, int64_t n, int64_t blk, double *out) {
    int64_t m = n / blk, i;
    for (i = 0; i < m; i++) {
        double r = sqrt(pw_sq(x + i * blk, blk) / (double)blk + 1e-20);
        out[i] = 20.0 * log10(r);
    }
    return m;
}

int64_t p5_first_nonzero(const double *e, const double *w, int64_t n, int64_t start) {
    int64_t i;
    if (start < 0) start = 0;
    if (w) {
        for (i = start; i < n; i++)
            if (e[i] * w[i] != 0.0) return i;
    } else {
        for (i = start; i < n; i++)
            if (e[i] != 0.0) return i;
    }
    return -1;
}

/* blocks.transients from the m block powers bp */
static int64_t transients_bp(const double *bp, int64_t m, double top_db, int gaps, int64_t *start,
                             double *jump, uint8_t *gap) {
    int64_t i, k, nh = 0;
    double *p = (double *)malloc(sizeof(double) * (size_t)(m + 8) * 2 + 8);
    double *pp, *g2;
    if (!p) return -1;
    pp = p;                     /* m + 8: eight zeros, then the block powers */
    g2 = p + m + 8;             /* m + 7: np.convolve(pp, ones(2) / 2, "valid") */
    memset(pp, 0, sizeof(double) * 8);
    if (m) memcpy(pp + 8, bp, sizeof(double) * (size_t)m);
    for (k = 0; k + 1 < m + 8; k++) g2[k] = pp[k] * 0.5 + pp[k + 1] * 0.5;
    for (i = 0; i < m; i++) {
        double db = 10.0 * log10(pp[8 + i] + 1e-30);
        double c8 = 0.0, g, j8, jg, jmp;
        int j, isgap;
        for (j = 0; j < 8; j++) c8 += pp[i + j] * 0.125;
        j8 = db - 10.0 * log10(c8 + 1e-30);
        g = g2[8 - TRANSIENT_GAP + i];
        if (g2[7 - TRANSIENT_GAP + i] < g) g = g2[7 - TRANSIENT_GAP + i];
        jg = db - 10.0 * log10(g + 1e-30);
        isgap = (jg >= CLEAN_DB) && (jg > j8) && gaps && (i > TRANSIENT_GAP);
        jmp = isgap ? jg : j8;
        if (jmp > TRANSIENT_DB && db > top_db + AUDIBLE_DB) {
            start[nh] = i * BLOCK;
            jump[nh] = jmp;
            gap[nh] = (uint8_t)isgap;
            nh++;
        }
    }
    free(p);
    return nh;
}

int64_t p5_transients(const double *e, int64_t n, double top_db, int gaps, int64_t *start,
                      double *jump, uint8_t *gap) {
    int64_t m = n / BLOCK, nh;
    double *bp = (double *)malloc(sizeof(double) * (size_t)(m + 1));
    if (!bp) return -1;
    block_power(e, m, bp);
    nh = transients_bp(bp, m, top_db, gaps, start, jump, gap);
    free(bp);
    return nh;
}

int64_t p5_onsets(const double *e, int64_t n, double top_db, int gaps, P5Onset **out) {
    int64_t m, nt, r0, i, nout = 0;
    int64_t *ts = NULL;
    double *jumps = NULL, *bdb = NULL, *cs = NULL;
    uint8_t *gp = NULL;
    P5Onset *o = NULL;
    const double over_pre = pow(10.0, ONSET_OVER_PRE_DB / 10.0);
    const double under_hit = pow(10.0, -ONSET_UNDER_HIT_DB / 10.0);
    *out = NULL;
    if (n < BLOCK) return 0;
    m = n / BLOCK;
    ts = (int64_t *)malloc(sizeof(int64_t) * (size_t)m);
    jumps = (double *)malloc(sizeof(double) * (size_t)m);
    gp = (uint8_t *)malloc((size_t)m);
    bdb = (double *)malloc(sizeof(double) * (size_t)m);
    if (!ts || !jumps || !gp || !bdb) goto fail;
    block_power(e, m, bdb);
    nt = transients_bp(bdb, m, top_db, gaps, ts, jumps, gp);
    if (nt < 0) goto fail;
    if (nt == 0) goto done;
    for (i = 0; i < m; i++) bdb[i] = 10.0 * log10(bdb[i] + 1e-30);
    {   /* the running sum is read no further than two blocks past the last hit */
        int64_t top = ts[nt - 1] + 2 * BLOCK < n ? ts[nt - 1] + 2 * BLOCK : n;
        cs = (double *)malloc(sizeof(double) * (size_t)(top + 1));
        o = (P5Onset *)malloc(sizeof(P5Onset) * (size_t)nt);
        if (!cs || !o) goto fail;
        cs[0] = 0.0;
        for (i = 0; i < top; i++) cs[i + 1] = cs[i] + e[i] * e[i];
    }
    r0 = 0;
    while (r0 < nt) {
        int64_t r1 = r0 + 1, bi, t, lo, a, t2, nn, n0, s;
        double pre, thr, hit, h1, h2;
        while (r1 < nt) {       /* the run: cut where blocks are not adjacent or a block jumps over the one before */
            int64_t b = ts[r1] / BLOCK;
            if (ts[r1] - ts[r1 - 1] > BLOCK || bdb[b] - bdb[b - 1] > TRANSIENT_DB) break;
            r1++;
        }
        bi = r0;
        for (i = r0 + 1; i < r1; i++)
            if (jumps[i] > jumps[bi]) bi = i;
        r0 = r1;
        t = ts[bi];
        lo = t - BLOCK > 0 ? t - BLOCK : 0;
        a = lo - (gp[bi] ? TRANSIENT_GAP : 8) * BLOCK;
        if (a < 0) a = 0;
        pre = (cs[lo] - cs[a]) / (double)(lo - a > 1 ? lo - a : 1);
        if (gp[bi]) {
            int64_t d = t - a - BLOCK;
            double p2 = (cs[t] - cs[a + BLOCK]) / (double)(d > 1 ? d : 1);
            if (p2 < pre) pre = p2;
        }
        thr = pre * over_pre;
        t2 = t + 2 * BLOCK < n ? t + 2 * BLOCK : n;
        h1 = cs[t + BLOCK] - cs[t];
        {
            int64_t d = t2 - t - BLOCK;
            h2 = (cs[t2] - cs[t + BLOCK]) * (double)BLOCK / (double)(d > 1 ? d : 1);
        }
        hit = (h2 > h1 ? h2 : h1) / (double)BLOCK;
        if (hit * under_hit > thr) thr = hit * under_hit;
        n0 = -1;
        for (nn = lo; nn < t + BLOCK; nn++) {
            int64_t hi = nn + ONSET_W < n ? nn + ONSET_W : n;
            if ((cs[hi] - cs[nn]) / (double)ONSET_W > thr) {
                n0 = nn;
                break;
            }
        }
        if (n0 < 0) continue;
        s = -1;
        for (nn = n0; nn < n0 + ONSET_W && nn < n; nn++)
            if (e[nn] * e[nn] > thr) {
                s = nn;
                break;
            }
        if (s < 0) continue;     /* cannot happen: the window's mean is over thr */
        if (!nout || s > o[nout - 1].s + ONSET_W) {
            o[nout].s = s;
            o[nout].j = jumps[bi];
            nout++;
        } else {
            P5Onset *q = &o[nout - 1];
            if (s < q->s) q->s = s;
            if (jumps[bi] > q->j) q->j = jumps[bi];
        }
    }
done:
    free(ts);
    free(jumps);
    free(gp);
    free(bdb);
    free(cs);
    if (nout == 0) {
        free(o);
        o = NULL;
    }
    *out = o;
    return nout;
fail:
    free(ts);
    free(jumps);
    free(gp);
    free(bdb);
    free(cs);
    free(o);
    return -1;
}

static int onset_cmp(const void *x, const void *y) {
    int64_t a = ((const P5Onset *)x)->s, b = ((const P5Onset *)y)->s;
    return a < b ? -1 : a > b;
}

int64_t p5_shared_onsets(const P5Onset *own, int64_t nown, const P5Onset *ref, int64_t nref,
                         int64_t share, P5Onset **out) {
    int64_t i, k, no = 0;
    P5Onset *o = (P5Onset *)malloc(sizeof(P5Onset) * (size_t)(nown + nref + 1));
    *out = NULL;
    if (!o) return -1;
    for (i = 0; i < nref; i++) {         /* {s: j for s, j in ref_ons} */
        for (k = 0; k < no; k++)
            if (o[k].s == ref[i].s) break;
        if (k == no) o[no++] = ref[i];
        else o[k].j = ref[i].j;
    }
    for (i = 0; i < nown; i++) {
        int64_t s = own[i].s, hitr = -1;
        double j = own[i].j;
        for (k = 0; k < nref; k++)
            if (ref[k].s <= s && ref[k].s >= s - share) hitr = k;
        if (hitr >= 0) s = ref[hitr].s;
        for (k = 0; k < no; k++)
            if (o[k].s == s) break;
        if (k == no) {
            o[no].s = s;
            o[no].j = j;
            no++;
        } else if (j > o[k].j) {
            o[k].j = j;
        }
    }
    qsort(o, (size_t)no, sizeof(P5Onset), onset_cmp);
    if (no == 0) {
        free(o);
        o = NULL;
    }
    *out = o;
    return no;
}

void p5_plan_free(P5Plan *p) {
    if (!p) return;
    free(p->cov);
    free(p->pieces);
    p->cov = NULL;
    p->pieces = NULL;
    p->npieces = 0;
}

void p5_plan_w(const P5Plan *p, int64_t k, double *w) {
    const P5Piece *q = &p->pieces[k];
    int64_t i;
    if (q->kind == P5PIECE_LONG) {
        for (i = 0; i < p->n; i++) w[i] = 1.0 - p->cov[i];
    } else {
        memset(w, 0, sizeof(double) * (size_t)p->n);
        for (i = q->a; i < q->b; i++) w[i] = p->cov[i];
    }
}

int p5_plan(const double *e, const double *ref, int64_t n, const double *const *heard,
            int nheard, P5Plan *out) {
    int64_t nz, i, k, nref = 0, nh = 0, nclean = 0, np_ = 0;
    double top = 0.0;
    P5Onset *refo = NULL, *hits = NULL, *tmp = NULL;
    int64_t *clean = NULL;
    double *cov = NULL;
    P5Piece *pieces = NULL;
    double up[TRANSIENT_RAMP];
    const int64_t R = TRANSIENT_RAMP;
    memset(out, 0, sizeof *out);
    out->n = n;
    nz = p5_first_nonzero(e, NULL, n, 0);
    if (nz < 0) return 0;
    if (n >= BLOCK) {
        int64_t m = n / BLOCK;
        double *bd = (double *)malloc(sizeof(double) * (size_t)m);
        if (!bd) return -1;
        p5_block_db(ref, n, BLOCK, bd);
        top = bd[0];
        for (i = 1; i < m; i++)
            if (bd[i] > top) top = bd[i];
        free(bd);
    }
    nref = p5_onsets(ref, n, top, 0, &refo);
    if (nref < 0) goto fail;
    for (k = 0; k < nheard; k++) {
        P5Onset *ho = NULL, *sh = NULL;
        int64_t nho = p5_onsets(heard[k], n, top, 0, &ho), nc = 0, nsh;
        if (nho < 0) goto fail;
        for (i = 0; i < nho; i++)           /* only clean hits */
            if (ho[i].j >= CLEAN_DB) ho[nc++] = ho[i];
        nsh = p5_shared_onsets(ho, nc, refo, nref, HEARD_SHARE, &sh);
        free(ho);
        if (nsh < 0) goto fail;
        free(refo);
        refo = sh;
        nref = nsh;
    }
    {
        int64_t ne = p5_onsets(e, n, top, 1, &tmp);
        if (ne < 0) goto fail;
        nh = p5_shared_onsets(tmp, ne, refo, nref, ONSET_SHARE, &hits);
        free(tmp);
        tmp = NULL;
        if (nh < 0) goto fail;
    }
    cov = (double *)calloc((size_t)n, sizeof(double));
    clean = (int64_t *)malloc(sizeof(int64_t) * (size_t)(nh + 1));
    if (!cov || !clean) goto fail;
    for (i = 0; i < nh; i++) {
        if (hits[i].s - nz <= ONSET_W) hits[i].s = nz;
        if (hits[i].j >= CLEAN_DB) clean[nclean++] = hits[i].s;
    }
    for (i = 0; i < R; i++) up[i] = 0.5 - 0.5 * cos(3.141592653589793 * ((double)i + 0.5) / (double)R);
    for (k = 0; k < nh; k++) {
        int64_t s = hits[k].s, b = s + TRANSIENT_POST < n ? s + TRANSIENT_POST : n;
        int64_t a = hits[k].j >= CLEAN_DB ? s : (s - TRANSIENT_PRE > 0 ? s - TRANSIENT_PRE : 0);
        int64_t a0 = a - R > 0 ? a - R : 0, hi = b + R < n ? b + R : n;
        for (i = a; i < b; i++) cov[i] = 1.0;
        for (i = a0; i < a; i++) {          /* ramp_up(a): up[R - (a - a0):] */
            double v = up[R - (a - a0) + (i - a0)];
            if (v > cov[i]) cov[i] = v;
        }
        for (i = b; i < hi; i++) {          /* up[::-1][:hi - b] */
            double v = up[R - 1 - (i - b)];
            if (v > cov[i]) cov[i] = v;
        }
    }
    for (i = 0; i < n; i++)
        if (!(cov[i] > 1e-9)) cov[i] = 0.0;
    out->cov = cov;
    pieces = (P5Piece *)malloc(sizeof(P5Piece) * (size_t)(nclean + 2));
    if (!pieces) goto fail;
    out->pieces = pieces;
    for (k = -1; k <= nclean; k++) {
        P5Piece q;
        int64_t live;
        if (k < 0) {
            q.M = P5_LONG_M;
            q.kind = P5PIECE_LONG;
            q.a = nz;
            q.b = n;
        } else {
            q.M = P5_SHORT_M;
            q.kind = P5PIECE_SHORT;
            q.a = k == 0 ? nz : clean[k - 1];
            q.b = k < nclean ? clean[k] : n;
        }
        live = -1;
        if (q.kind == P5PIECE_LONG) {
            for (i = q.a; i < n; i++)
                if (e[i] * (1.0 - cov[i]) != 0.0) {
                    live = i;
                    break;
                }
        } else {
            for (i = q.a; i < q.b; i++)
                if (e[i] * cov[i] != 0.0) {
                    live = i;
                    break;
                }
        }
        if (live >= 0) {        /* skip whole frames of nothing, staying on the grid from a */
            q.s = q.a + (live - q.a) / q.M * q.M;
            pieces[np_++] = q;
        }
    }
    out->npieces = np_;
    free(refo);
    free(hits);
    free(clean);
    return 0;
fail:
    free(refo);
    free(hits);
    free(tmp);
    free(clean);
    if (out->cov) cov = NULL;
    free(cov);
    p5_plan_free(out);
    return -1;
}

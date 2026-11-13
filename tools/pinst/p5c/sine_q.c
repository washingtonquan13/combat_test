/* PINST5 C encoder, stage SQ: the sine layer's code and its render (owner: SQ).
 *
 * A port of the frozen Python (2f6c9a8): pinst_codec.quantize for
 * analysis.TIER (the model tier: no pcm, no tns, junction 0, so every
 * anchor is frame 0), estimate_f0_track, analysis.tracks_of, render_sines and
 * worth_keeping. Each line does numpy's arithmetic in numpy's order with the
 * C runtime's log2/pow/log10/sqrt (the ones numpy calls on this machine), so
 * the streams come out byte for byte. Reused unedited from native/codecfast.c:
 * keyframes, steer_keys, st_tracks.
 *
 * The one place it does not follow numpy's order: the two dot products in
 * worth_keeping (numpy hands them to OpenBLAS, whose FMA kernel C cannot
 * name portably). They agree to rounding; only a note sitting exactly on the
 * keep/drop bound could flip.
 */
#include "sine_q.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifdef _MSC_VER
/* keep the C runtime's own pow/log2/cos: a vectorised loop would swap in another library's */
#define NOVEC __pragma(loop(no_vector))
#else
#define NOVEC
#endif

/* native/codecfast.c */
int64_t keyframes(const double *v, int64_t L, int C, const double *tol, int64_t max_span, int64_t *keep);
int steer_keys(const double *cents, const double *ref, const double *ph, const int64_t *keys, int64_t nk,
               int64_t ki0, double phi0, double H, double q, double gain, double clip, double k,
               double ln2_1200, int64_t *qc);
int st_tracks(const double *f, const double *a, const double *ph, const int64_t *len, const int64_t *start,
              const int64_t *anchor, int64_t ntracks, int H, int integrate, double two_pi, double sr,
              double *out, int64_t nout);

static const double PI_ = 3.141592653589793, TWO_PI_ = 2.0 * 3.141592653589793;

/* analysis.TIER = pc.Tier("model", f_cents=0.5, f_tol=1), the rest Tier's defaults */
#define T_F_CENTS 0.5
#define T_A_DB 1.0
#define T_F_TOL 1.0
#define T_A_TOL 1.0
#define T_CULL_DB (-70.0)
#define T_FLOOR_DB (-96.0)
#define T_PHASE_BITS 6
#define T_F0_CENTS 0.1
#define T_STEER 0.7
#define MAX_SPAN 64

/* ------------------------------------------------------------ numpy's arithmetic */

/* numpy's pairwise sum (ndarray.sum() of a contiguous float64 array in numpy 2.x:
 * the whole array, from 0.0). Not codecfast's np_sum, which adds a[0] first. */
static double pw_sum(const double *a, int64_t n) {
    if (n < 8) {
        double r = 0.0;
        for (int64_t i = 0; i < n; i++) r += a[i];
        return r;
    }
    if (n <= 128) {
        double r[8];
        int64_t i;
        for (i = 0; i < 8; i++) r[i] = a[i];
        for (i = 8; i < n - (n % 8); i += 8)
            for (int j = 0; j < 8; j++) r[j] += a[i + j];
        double res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]));
        for (; i < n; i++) res += a[i];
        return res;
    }
    int64_t n2 = n / 2;
    n2 -= n2 % 8;
    return pw_sum(a, n2) + pw_sum(a + n2, n - n2);
}

static void swapd(double *a, double *b) { double t = *a; *a = *b; *b = t; }

/* the k-th smallest of a[0..n) (a is reordered: a[0..k) <= a[k] <= a[k+1..n)) */
static double select_k(double *a, int64_t n, int64_t k) {
    int64_t lo = 0, hi = n - 1;
    while (hi > lo) {
        int64_t mid = lo + (hi - lo) / 2;
        if (a[mid] < a[lo]) swapd(&a[mid], &a[lo]);
        if (a[hi] < a[lo]) swapd(&a[hi], &a[lo]);
        if (a[hi] < a[mid]) swapd(&a[hi], &a[mid]);
        double p = a[mid];
        int64_t i = lo, j = hi;
        while (i <= j) {
            while (a[i] < p) i++;
            while (a[j] > p) j--;
            if (i <= j) { swapd(&a[i], &a[j]); i++; j--; }
        }
        if (k <= j) hi = j;
        else if (k >= i) lo = i;
        else break;
    }
    return a[k];
}

/* np.median of a[0..n) (n >= 1); tmp holds n doubles */
static double median(const double *a, int64_t n, double *tmp) {
    memcpy(tmp, a, sizeof(double) * (size_t)n);
    int64_t h = n / 2;
    double hi = select_k(tmp, n, h);
    if (n & 1) return hi;
    double lo = tmp[0];
    for (int64_t i = 1; i < h; i++) if (tmp[i] > lo) lo = tmp[i];
    return (lo + hi) / 2.0;
}

/* np.interp(np.arange(L), xp, fp) (xp increasing), into out[i * stride] */
static void interp_ar(const double *xp, const double *fp, int64_t m, int64_t L, double *out, int64_t stride) {
    int64_t j = 0;
    for (int64_t i = 0; i < L; i++) {
        double x = (double)i, r;
        if (x < xp[0]) r = fp[0];
        else if (x > xp[m - 1]) r = fp[m - 1];
        else {
            while (j + 1 < m && xp[j + 1] <= x) j++;
            if (j == m - 1 || xp[j] == x) r = fp[j];
            else {
                double slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j]);
                r = slope * (x - xp[j]) + fp[j];
                if (isnan(r)) {
                    r = slope * (x - xp[j + 1]) + fp[j + 1];
                    if (isnan(r) && fp[j] == fp[j + 1]) r = fp[j];
                }
            }
        }
        out[i * stride] = r;
    }
}

/* numpy's float % (np.remainder) */
static double py_mod(double a, double b) {
    double m = fmod(a, b);
    if (m != 0.0) {
        if ((b < 0) != (m < 0)) m += b;
    } else {
        m = copysign(0.0, b);
    }
    return m;
}

/* ------------------------------------------------------------ bytes */

typedef struct { uint8_t *p; int64_t n, cap; int err; } Bb;

static void bb_put(Bb *b, uint8_t c) {
    if (b->n == b->cap) {
        int64_t cap = b->cap ? 2 * b->cap : 256;
        uint8_t *p = (uint8_t *)realloc(b->p, (size_t)cap);
        if (!p) { b->err = 1; return; }
        b->p = p;
        b->cap = cap;
    }
    b->p[b->n++] = c;
}

/* _varint / _ints: zigzag, 7 bits a byte, low first */
static void bb_varint(Bb *b, int64_t v) {
    uint64_t z = ((uint64_t)v << 1) ^ (uint64_t)(v >> 63);
    while (z >= 128) {
        bb_put(b, (uint8_t)((z & 0x7F) | 0x80));
        z >>= 7;
    }
    bb_put(b, (uint8_t)z);
}

typedef struct { const uint8_t *p; int64_t n, i; int err; } Cur;

static int64_t cur_v(Cur *c) {
    uint64_t z = 0;
    int sh = 0;
    for (;;) {
        if (c->i >= c->n || sh > 63) { c->err = 1; return 0; }
        uint8_t b = c->p[c->i++];
        z |= (uint64_t)(b & 0x7F) << sh;
        sh += 7;
        if (b < 128) return (int64_t)(z >> 1) ^ -(int64_t)(z & 1);
    }
}

static int64_t cur_raw(Cur *c) {
    if (c->i >= c->n) { c->err = 1; return 0; }
    return c->p[c->i++];
}

/* ------------------------------------------------------------ estimate_f0_track */

/* pc.estimate_f0_track(tracks, f0_nominal, n_frames) -> f0t (n_frames). Returns 0 on no memory. */
static int estimate_f0_track(const P5Tracks *T, double f0n, int64_t nfr, double *f0t) {
    int64_t ntr = T->ntracks, maxl = 1;
    for (int64_t i = 0; i < ntr; i++) if (T->tracks[i].len > maxl) maxl = T->tracks[i].len;
    enum { NG = 1201, NS = 12 };
    double *ens = (double *)malloc(sizeof(double) * (size_t)(ntr ? ntr : 1));
    double *tmp = (double *)malloc(sizeof(double) * (size_t)maxl);
    double *num = (double *)calloc((size_t)nfr, sizeof(double));
    double *den = (double *)calloc((size_t)nfr, sizeof(double));
    double *grid = (double *)malloc(sizeof(double) * NG * 3);
    char *used = (char *)calloc((size_t)(ntr ? ntr : 1), 1);
    int ok = ens && tmp && num && den && grid && used;
    if (!ok) goto done;
    double *tot = grid + NG, *comp = tot + NG;

    /* strong = sorted(tracks, key=-energy)[:12] (stable) */
    for (int64_t i = 0; i < ntr; i++) {
        const P5Track *t = &T->tracks[i];
NOVEC
        for (int64_t j = 0; j < t->len; j++) tmp[j] = pow(10.0, t->a[j] / 10.0);
        ens[i] = pw_sum(tmp, t->len);
    }
    int64_t strong[NS], ns = 0;
    while (ns < NS && ns < ntr) {
        int64_t b = -1;
        for (int64_t i = 0; i < ntr; i++)
            if (!used[i] && (b < 0 || ens[i] > ens[b])) b = i;
        used[b] = 1;
        strong[ns++] = b;
    }
    /* grid = f0_nominal * 2 ** (np.linspace(-3, 3, 1201) / 12) */
    const double step = 6.0 / 1200;
NOVEC
    for (int g = 0; g < NG; g++) {
        double l = g == NG - 1 ? 3.0 : (double)g * step + -3.0;
        grid[g] = f0n * pow(2.0, l / 12.0);
        tot[g] = 0.0;
        comp[g] = 0.0;
    }
    double best = f0n;
    if (ns) {
        double fms[NS], es[NS];
        for (int64_t j = 0; j < ns; j++) {
            const P5Track *t = &T->tracks[strong[j]];
            fms[j] = median(t->f, t->len, tmp);
            es[j] = ens[strong[j]];
        }
        /* the score is Python's compensated sum over the strong tracks, in their order */
        for (int64_t j = 0; j < ns; j++) {
NOVEC
            for (int g = 0; g < NG; g++) {
                double h = nearbyint(fms[j] / grid[g]);
                if (h < 1.0) h = 1.0;
                int okj = h <= 10.0 && fabs(log2(fms[j] / (h * grid[g]))) < 0.004;
                double v = okj ? es[j] : 0.0;
                double tt = tot[g] + v;
                comp[g] += fabs(tot[g]) >= fabs(v) ? (tot[g] - tt) + v : (v - tt) + tot[g];
                tot[g] = tt;
            }
        }
        int bi = 0;
        double bs = 0.0;
        for (int g = 0; g < NG; g++) {
            double sc = comp[g] != 0 ? tot[g] + comp[g] : tot[g];
            if (g == 0 || sc > bs) { bs = sc; bi = g; }
        }
        best = grid[bi];
    }
    for (int64_t i = 0; i < ntr; i++) {
        const P5Track *t = &T->tracks[i];
        double hd = nearbyint(median(t->f, t->len, tmp) / best);
        if (hd < 1.0) hd = 1.0;
        if (hd > 10.0) continue;
        double hb = hd * best;
        double *nu = num + t->start, *de = den + t->start;
NOVEC
        for (int64_t j = 0; j < t->len; j++) {
            double dev = log2(t->f[j] / hb);
            double w = pow(10.0, t->a[j] / 20.0) * (fabs(dev) < 0.03 ? 1.0 : 0.0);
            nu[j] += w * log2(t->f[j] / hd);
            de[j] += w;
        }
    }
    /* np.interp over the frames that have a weight, then 2 ** uniform_filter1d(lg, 3, "nearest") */
    int64_t nh = 0;
    for (int64_t i = 0; i < nfr; i++)
        if (den[i] > 0) {
            num[nh] = num[i] / den[i];
            den[nh] = (double)i;
            nh++;
        }
    if (!nh) {
        for (int64_t i = 0; i < nfr; i++) f0t[i] = best;
        goto done;
    }
    double *lg = (double *)malloc(sizeof(double) * (size_t)nfr);
    if (!lg) { ok = 0; goto done; }
    interp_ar(den, num, nh, nfr, lg, 1);
    {
        /* scipy's running sum: the window's sum kept, each output it / 3 */
        double t = (lg[0] + lg[0]) + lg[nfr > 1 ? 1 : 0];
        f0t[0] = t / 3.0;
        for (int64_t l = 1; l < nfr; l++) {
            double in = lg[l + 1 < nfr ? l + 1 : nfr - 1], outv = lg[l - 2 >= 0 ? l - 2 : 0];
            t += in - outv;
            f0t[l] = t / 3.0;
        }
    }
    free(lg);
NOVEC
    for (int64_t i = 0; i < nfr; i++) f0t[i] = pow(2.0, f0t[i]);
done:
    free(ens); free(tmp); free(num); free(den); free(grid); free(used);
    return ok;
}

/* ------------------------------------------------------------ quantize */

static void sort_by_start(const P5Tracks *T, int64_t *idx, int64_t *tmp, int64_t n) {
    /* stable merge sort of track indices by start (Python's sorted) */
    for (int64_t i = 0; i < n; i++) idx[i] = i;
    for (int64_t w = 1; w < n; w *= 2) {
        for (int64_t lo = 0; lo < n; lo += 2 * w) {
            int64_t mid = lo + w < n ? lo + w : n, hi = lo + 2 * w < n ? lo + 2 * w : n;
            int64_t i = lo, j = mid, k = lo;
            while (i < mid && j < hi)
                tmp[k++] = T->tracks[idx[j]].start < T->tracks[idx[i]].start ? idx[j++] : idx[i++];
            while (i < mid) tmp[k++] = idx[i++];
            while (j < hi) tmp[k++] = idx[j++];
        }
        memcpy(idx, tmp, sizeof(int64_t) * (size_t)n);
    }
}

static int64_t lz_len(p5_lz_fn lz, void *ctx, const P5Buf *b) {
    if (!b->n) return 0;
    return lz(ctx, b->p, b->n, NULL, 0);
}

int64_t p5_sine_quantize(const P5Tracks *T, int64_t sr, p5_lz_fn lz, void *lzctx, P5Sine *out) {
    int64_t ntr = T->ntracks, H = T->H, maxl = 1, nfr = 0, kept = 0, rc = -1;
    memset(out, 0, sizeof(*out));
    double top = ntr ? -INFINITY : -200.0;     /* max(t.a.max() for t in tracks, default=-200) */
    for (int64_t i = 0; i < ntr; i++) {
        const P5Track *t = &T->tracks[i];
        if (t->len > maxl) maxl = t->len;
        for (int64_t j = 0; j < t->len; j++) if (t->a[j] > top) top = t->a[j];
    }
    int lock = T->f0 != 0.0 && ntr > 0;
    Bb hdr = {0}, dt = {0}, df = {0}, da = {0}, fs = {0};
    double *f0q = NULL, *f0t = NULL, *c0 = NULL;
    int64_t *k0 = NULL;
    double *sc = (double *)malloc(sizeof(double) * (size_t)maxl * 6);
    int64_t *ki = (int64_t *)malloc(sizeof(int64_t) * (size_t)(maxl * 3 + 2 * (ntr ? ntr : 1)));
    if (!sc || !ki) goto fail;
    double *ref = sc, *cents = ref + maxl, *vals = cents + maxl, *tmp = vals + 2 * maxl, *fq = tmp + maxl;
    int64_t *keys = ki, *qc = keys + maxl, *qa = qc + maxl, *order = qa + maxl, *otmp = order + ntr;

    if (lock) {
        for (int64_t i = 0; i < ntr; i++) {
            int64_t e = T->tracks[i].start + T->tracks[i].len;
            if (e > nfr) nfr = e;
        }
        nfr += 1;
        f0t = (double *)malloc(sizeof(double) * (size_t)nfr * 5);
        k0 = (int64_t *)malloc(sizeof(int64_t) * (size_t)nfr);
        if (!f0t || !k0 || !estimate_f0_track(T, T->f0, nfr, f0t)) goto fail;
        c0 = f0t + nfr;
        f0q = c0 + nfr;
NOVEC
        for (int64_t i = 0; i < nfr; i++) c0[i] = 1200.0 * log2(f0t[i] / 20.0);
        int64_t nk0;
        if (nfr <= 2) {
            nk0 = nfr;
            for (int64_t i = 0; i < nfr; i++) k0[i] = i;
        } else {
            const double tol = T_F0_CENTS;
            nk0 = keyframes(c0, nfr, 1, &tol, MAX_SPAN, k0);
        }
        /* fs = _ints(stack([deltas(k0), deltas(q0)], 1)); f0q = 20 * 2 ** (expand(k0, q0 * f0_cents) / 1200) */
        double *kx = f0q + nfr, *kv = kx + nfr;
        int64_t pk = 0, pq = 0;
        for (int64_t i = 0; i < nk0; i++) {
            int64_t q = (int64_t)nearbyint(c0[k0[i]] / T_F0_CENTS);
            bb_varint(&fs, k0[i] - pk);
            bb_varint(&fs, q - pq);
            pk = k0[i];
            pq = q;
            kx[i] = (double)k0[i];
            kv[i] = (double)q * T_F0_CENTS;
        }
        interp_ar(kx, kv, nk0, nfr, f0q, 1);
NOVEC
        for (int64_t i = 0; i < nfr; i++) f0q[i] = 20.0 * pow(2.0, f0q[i] / 1200.0);
    }

    sort_by_start(T, order, otmp, ntr);
    const double cut = top + T_CULL_DB > T_FLOOR_DB ? top + T_CULL_DB : T_FLOOR_DB;
    const double tol2[2] = {T_F_TOL, T_A_TOL};
    const double kk = TWO_PI_ / (double)sr, ln2_1200 = log(2.0) / 1200;
    int64_t prev_start = 0;
    for (int64_t oi = 0; oi < ntr; oi++) {
        const P5Track *t = &T->tracks[order[oi]];
        int64_t L = t->len, hh = 0;
        double amax = t->a[0];
        for (int64_t j = 1; j < L; j++) if (t->a[j] > amax) amax = t->a[j];
        if (amax < cut) continue;
        if (lock) {
            const double *r0 = f0q + t->start;
            for (int64_t j = 0; j < L; j++) fq[j] = t->f[j] / r0[j];
            double m = nearbyint(median(fq, L, tmp));
            hh = m < 1.0 ? 1 : (int64_t)m;
            for (int64_t j = 0; j < L; j++) ref[j] = (double)hh * r0[j];
        } else {
            for (int64_t j = 0; j < L; j++) ref[j] = 20.0;
        }
NOVEC
        for (int64_t j = 0; j < L; j++) {
            cents[j] = 1200.0 * log2(t->f[j] / ref[j]);
            vals[2 * j] = cents[j];
            vals[2 * j + 1] = t->a[j];
        }
        int64_t nk;
        if (L <= 2) {
            nk = L;
            for (int64_t j = 0; j < L; j++) keys[j] = j;
        } else {
            nk = keyframes(vals, L, 2, tol2, MAX_SPAN, keys);
        }
        /* the anchor is frame 0 (junction 0), which keys already hold */
        int64_t qph = (int64_t)nearbyint(py_mod(t->ph[0], TWO_PI_) / TWO_PI_ * (1 << T_PHASE_BITS)) %
                      (1 << T_PHASE_BITS);
        if (qph < 0) qph += 1 << T_PHASE_BITS;
        for (int64_t j = 0; j < nk; j++) {
            qc[j] = (int64_t)nearbyint(cents[keys[j]] / T_F_CENTS);
            qa[j] = (int64_t)nearbyint(t->a[keys[j]] / T_A_DB);
        }
        /* keyframes' spans are <= 64 and rising, so the C steering never asks for the numpy loop */
        if (steer_keys(cents, ref, t->ph, keys, nk, 0, (double)qph / (1 << T_PHASE_BITS) * TWO_PI_, (double)H,
                       T_F_CENTS, T_STEER, T_F_TOL, kk, ln2_1200, qc))
            goto fail;
        bb_varint(&hdr, t->start - prev_start);
        prev_start = t->start;
        bb_varint(&hdr, nk);
        if (lock) bb_varint(&hdr, hh);
        bb_varint(&hdr, qc[0]);
        bb_varint(&hdr, qa[0]);
        bb_put(&hdr, (uint8_t)qph);
        for (int64_t j = 1; j < nk; j++) {
            bb_varint(&dt, keys[j] - keys[j - 1]);
            bb_varint(&df, qc[j] - qc[j - 1]);
            bb_varint(&da, qa[j] - qa[j - 1]);
        }
        kept++;
    }
    if (hdr.err || dt.err || df.err || da.err || fs.err) goto fail;
    out->ints[P5S_H] = H;
    out->ints[P5S_F_C] = 500;       /* round(TIER.f_cents * 1000) */
    out->ints[P5S_A_D] = 1000;
    out->ints[P5S_F0_C] = 100;
    out->ints[P5S_PBITS] = T_PHASE_BITS;
    out->ints[P5S_LOCK] = lock;
    out->ints[P5S_F0_FRAMES] = nfr;
    out->ints[P5S_N_TRACKS] = kept;
    Bb *bs[P5S_NSTREAMS] = {&hdr, &dt, &df, &da, &fs};
    for (int i = 0; i < P5S_NSTREAMS; i++) {
        out->s[i].p = bs[i]->p;
        out->s[i].n = bs[i]->n;
        bs[i]->p = NULL;
    }
    for (int i = 0; i < P5S_NSTREAMS; i++) {
        out->lz_sizes[i] = lz_len(lz, lzctx, &out->s[i]);
        if (out->lz_sizes[i] < 0) {
            p5_sine_free(out);
            memset(out, 0, sizeof(*out));
            goto fail;
        }
    }
    rc = kept;
fail:
    free(hdr.p); free(dt.p); free(df.p); free(da.p); free(fs.p);
    free(sc); free(ki); free(f0t); free(k0);
    return rc;
}

/* ------------------------------------------------------------ tracks_of */

typedef struct {
    int64_t ntr, tot, cap, tcap;
    double *f, *a, *ph;
    int64_t *len, *start;
} Flat;

static void flat_free(Flat *F) {
    free(F->f); free(F->a); free(F->ph); free(F->len); free(F->start);
    memset(F, 0, sizeof(*F));
}

static int grow(void **p, int64_t cap, size_t el) {
    void *q = realloc(*p, (size_t)cap * el);
    if (!q) return 0;
    *p = q;
    return 1;
}

/* analysis.tracks_of, the tracks end to end. Returns 1, or 0 (F empty). */
static int decode_flat(const P5Sine *s, Flat *F) {
    const int64_t *I = s->ints;
    const double f_c = (double)I[P5S_F_C] / 1000, a_d = (double)I[P5S_A_D] / 1000, f0_c = (double)I[P5S_F0_C] / 1000;
    const int64_t lock = I[P5S_LOCK], pbits = I[P5S_PBITS], nf0 = I[P5S_F0_FRAMES], ntr = I[P5S_N_TRACKS];
    double *f0q = NULL, *kx = NULL, *kv = NULL, *fc = NULL;
    int64_t *keys = NULL, *qc = NULL, *qa = NULL, kcap = 0;
    int ok = 0;
    memset(F, 0, sizeof(*F));
    if (ntr < 0 || pbits < 0 || pbits > 30) return 0;
    if (lock) {
        Cur c = {s->s[P5S_F0].p, s->s[P5S_F0].n, 0, 0};
        int64_t m = 0, cap = 64, kk = 0, qq = 0;
        if (nf0 <= 0) goto out;
        kx = (double *)malloc(sizeof(double) * cap);
        kv = (double *)malloc(sizeof(double) * cap);
        f0q = (double *)malloc(sizeof(double) * (size_t)nf0);
        if (!kx || !kv || !f0q) goto out;
        while (c.i < c.n) {
            kk += cur_v(&c);
            qq += cur_v(&c);
            if (c.err || (m && (double)kk <= kx[m - 1])) goto out;
            if (m == cap) {
                cap *= 2;
                if (!grow((void **)&kx, cap, sizeof(double)) || !grow((void **)&kv, cap, sizeof(double))) goto out;
            }
            kx[m] = (double)kk;
            kv[m] = (double)qq * f0_c;
            m++;
        }
        if (!m) goto out;
        interp_ar(kx, kv, m, nf0, f0q, 1);
NOVEC
        for (int64_t i = 0; i < nf0; i++) f0q[i] = 20.0 * pow(2.0, f0q[i] / 1200.0);
    }
    Cur ch = {s->s[P5S_HDR].p, s->s[P5S_HDR].n, 0, 0}, ct = {s->s[P5S_DT].p, s->s[P5S_DT].n, 0, 0},
        cf = {s->s[P5S_DF].p, s->s[P5S_DF].n, 0, 0}, ca = {s->s[P5S_DA].p, s->s[P5S_DA].n, 0, 0};
    F->tcap = ntr ? ntr : 1;
    F->len = (int64_t *)malloc(sizeof(int64_t) * (size_t)F->tcap);
    F->start = (int64_t *)malloc(sizeof(int64_t) * (size_t)F->tcap);
    if (!F->len || !F->start) goto out;
    int64_t start = 0;
    for (int64_t ti = 0; ti < ntr; ti++) {
        start += cur_v(&ch);
        int64_t nk = cur_v(&ch);
        int64_t hh = lock ? cur_v(&ch) : 0;
        int64_t q0 = cur_v(&ch), a0 = cur_v(&ch), qph = cur_raw(&ch);
        if (ch.err || start < 0) goto out;
        if (nk < 1) nk = 1;     /* Python's loop runs nk - 1 times: none */
        if (nk > kcap) {
            kcap = nk > 2 * kcap ? nk : 2 * kcap;
            if (!grow((void **)&keys, kcap, 8) || !grow((void **)&qc, kcap, 8) || !grow((void **)&qa, kcap, 8))
                goto out;
        }
        keys[0] = 0; qc[0] = q0; qa[0] = a0;
        for (int64_t j = 1; j < nk; j++) {
            keys[j] = keys[j - 1] + cur_v(&ct);
            qc[j] = qc[j - 1] + cur_v(&cf);
            qa[j] = qa[j - 1] + cur_v(&ca);
            if (keys[j] <= keys[j - 1]) goto out;
        }
        if (ct.err || cf.err || ca.err) goto out;
        int64_t L = keys[nk - 1] + 1;
        if (lock && start + L > nf0) goto out;
        if (F->tot + L > F->cap) {
            int64_t cap = F->cap ? 2 * F->cap : 4096;
            while (cap < F->tot + L) cap *= 2;
            if (!grow((void **)&F->f, cap, 8) || !grow((void **)&F->a, cap, 8) || !grow((void **)&F->ph, cap, 8)) goto out;
            F->cap = cap;
        }
        /* expand(keys, [qc * f_c, qa * a_d], L): kx keys, the two value columns in f (scratch) and a */
        double *fo = F->f + F->tot, *ao = F->a + F->tot, *po = F->ph + F->tot;
        double *tx = (double *)malloc(sizeof(double) * (size_t)nk * 3);
        if (!tx) goto out;
        double *tc = tx + nk, *ta = tc + nk;
        for (int64_t j = 0; j < nk; j++) {
            tx[j] = (double)keys[j];
            tc[j] = (double)qc[j] * f_c;
            ta[j] = (double)qa[j] * a_d;
        }
        interp_ar(tx, tc, nk, L, fo, 1);
        interp_ar(tx, ta, nk, L, ao, 1);
        free(tx);
        if (lock) {
            const double *r0 = f0q + start;
NOVEC
            for (int64_t j = 0; j < L; j++) fo[j] = (double)hh * r0[j] * pow(2.0, fo[j] / 1200.0);
        } else {
NOVEC
            for (int64_t j = 0; j < L; j++) fo[j] = 20.0 * pow(2.0, fo[j] / 1200.0);
        }
        memset(po, 0, sizeof(double) * (size_t)L);
        po[0] = (double)qph / (double)((int64_t)1 << pbits) * TWO_PI_;
        F->len[ti] = L;
        F->start[ti] = start;
        F->tot += L;
        F->ntr = ti + 1;
    }
    ok = 1;
out:
    (void)fc;
    free(f0q); free(kx); free(kv); free(keys); free(qc); free(qa);
    if (!ok) flat_free(F);
    return ok;
}

int p5_sine_tracks_of(const P5Sine *s, P5Tracks *out) {
    Flat F;
    memset(out, 0, sizeof(*out));
    if (!decode_flat(s, &F)) return 0;
    out->H = s->ints[P5S_H];
    out->tracks = (P5Track *)calloc((size_t)(F.ntr ? F.ntr : 1), sizeof(P5Track));
    if (!out->tracks) { flat_free(&F); return 0; }
    int64_t off = 0;
    for (int64_t i = 0; i < F.ntr; i++) {
        P5Track *t = &out->tracks[i];
        size_t b = sizeof(double) * (size_t)F.len[i];
        t->start = F.start[i];
        t->len = F.len[i];
        t->f = (double *)malloc(b);
        t->a = (double *)malloc(b);
        t->ph = (double *)malloc(b);
        out->ntracks = i + 1;
        if (!t->f || !t->a || !t->ph) { p5_tracks_free(out); flat_free(&F); return 0; }
        memcpy(t->f, F.f + off, b);
        memcpy(t->a, F.a + off, b);
        memcpy(t->ph, F.ph + off, b);
        off += F.len[i];
    }
    flat_free(&F);
    return 1;
}

/* st_tracks(..., integrate = 1, anchor 0) with the cosines by rotation.
 *
 * st_tracks takes one C-runtime cos per sample per track, which is nearly all
 * of the render's time. Here every frame's phase polynomial
 *   p(i) = ((th0 + w0 i) + al i^2) + be i^3
 * (be is the rounding left of a quadratic, kept) is split into lanes of LANE
 * samples. Each lane's first sample is st_tracks' own cos of st_tracks' own
 * argument; the rest step by unit complex rotations: z(i+1) = z(i) u(i),
 * u(i+1) = u(i) v(i), v(i+1) = v(i) c, with u, v and c the exact first,
 * second and third differences of p, so 8 sin/cos per lane instead of 64 cos.
 * The phase it plays drifts from st_tracks' by rounding only (about 1e-13 rad
 * at a lane's end; st_tracks' own argument carries ulp(th), 1e-10 rad a few
 * seconds into a treble partial). Everything else is st_tracks line for line. */
#define LANE 64
static int render_rot(const Flat *F, int H, double two_pi, double sr, double *out, int64_t nout) {
    int64_t maxl = 0;
    for (int64_t k = 0; k < F->ntr; k++) if (F->len[k] > maxl) maxl = F->len[k];
    const int nl = (H + LANE - 1) / LANE;
    double *mem = (double *)malloc(sizeof(double) * (3 * (size_t)(maxl + 2) + 4 * (size_t)H + (size_t)nl * (LANE + 6)));
    if (!mem) return 0;
    double *w = mem, *th = w + maxl + 2, *amp = th + maxl + 2;
    double *t1 = amp + maxl + 2, *t2 = t1 + H, *t3 = t2 + H, *tT = t3 + H, *buf = tT + H;
    double *zr = buf + (size_t)nl * LANE, *zi = zr + nl, *ur = zi + nl, *ui = ur + nl, *vr = ui + nl, *vi = vr + nl;
    const double T = (double)H, k3 = 3.0 / (T * T), k2 = -2.0 / (T * T * T), TT = T * T;
    for (int i = 0; i < H; i++) {
        t1[i] = (double)i; t2[i] = (double)((int64_t)i * i); t3[i] = (double)((int64_t)i * i * i); tT[i] = (double)i / T;
    }
    const double *f = F->f, *a = F->a, *ph = F->ph;
    for (int64_t k = 0; k < F->ntr; f += F->len[k], a += F->len[k], ph += F->len[k], k++) {
        int64_t L = F->len[k];
        if (L <= 0) continue;
NOVEC
        for (int64_t i = 0; i < L; i++) {
            w[i + 1] = two_pi * f[i] / sr;
            amp[i + 1] = pow(10.0, a[i] / 20.0);
        }
        {
            double c = 0.0;
            th[1] = ph[0];
            for (int64_t i = 0; i < L - 1; i++) {
                double inc = 0.5 * (w[i + 2] + w[i + 1]) * T;
                c = i == 0 ? inc : c + inc;
                th[i + 2] = th[1] + c;
            }
        }
        w[0] = w[1]; w[L + 1] = w[L];
        th[0] = th[1] - w[0] * T; th[L + 1] = th[L] + w[L + 1] * T;
        amp[0] = 0.0; amp[L + 1] = 0.0;
        int64_t s0 = (F->start[k] - 1) * H;
        for (int64_t s = 0; s <= L; s++) {
            double th0 = th[s], w0 = w[s], w1 = w[s + 1];
            double th1 = th0 + 0.5 * (w0 + w1) * T;
            double e = th1 - th0 - w0 * T;
            double al = k3 * e - (w1 - w0) / T, be = k2 * e + (w1 - w0) / TT;
            double a0 = amp[s], da = amp[s + 1] - amp[s];
            int64_t j0 = s0 + H * s;
            int lo = j0 < 0 ? (int)(-j0 < H ? -j0 : H) : 0;
            int hi = j0 + H > nout ? (int)(nout - j0 > 0 ? nout - j0 : 0) : H;
            if (hi <= lo) continue;
            const double cr = cos(6.0 * be), ci = sin(6.0 * be);
            const int b0 = lo / LANE, b1 = (hi + LANE - 1) / LANE;
NOVEC
            for (int b = b0; b < b1; b++) {
                const int i0 = b * LANE;
                const double x0 = (double)i0;
                double p = ((th0 + w0 * t1[i0]) + al * t2[i0]) + be * t3[i0];
                double d1 = w0 + al * (2.0 * x0 + 1.0) + be * ((3.0 * x0 * x0 + 3.0 * x0) + 1.0);
                double d2 = 2.0 * al + be * (6.0 * x0 + 6.0);
                zr[b] = cos(p); zi[b] = sin(p);
                ur[b] = cos(d1); ui[b] = sin(d1);
                vr[b] = cos(d2); vi[b] = sin(d2);
            }
            /* the lanes side by side: independent chains, one step of each at a time,
             * buf transposed (step-major) so the lane loop is contiguous and vectorizes */
            const int nb = b1 - b0;
            double *Zr = zr + b0, *Zi = zi + b0, *Ur = ur + b0, *Ui = ui + b0, *Vr = vr + b0, *Vi = vi + b0;
            for (int i = 0; i < LANE; i++) {
                double *row = buf + (size_t)i * nl;
                for (int b = 0; b < nb; b++) {
                    row[b] = Zr[b];
                    double nzr = Zr[b] * Ur[b] - Zi[b] * Ui[b], nzi = Zr[b] * Ui[b] + Zi[b] * Ur[b];
                    double nur = Ur[b] * Vr[b] - Ui[b] * Vi[b], nui = Ur[b] * Vi[b] + Ui[b] * Vr[b];
                    double nvr = Vr[b] * cr - Vi[b] * ci, nvi = Vr[b] * ci + Vi[b] * cr;
                    Zr[b] = nzr; Zi[b] = nzi; Ur[b] = nur; Ui[b] = nui; Vr[b] = nvr; Vi[b] = nvi;
                }
            }
            for (int b = b0; b < b1; b++) {
                const int ia = b * LANE > lo ? b * LANE : lo, ib = b * LANE + LANE < hi ? b * LANE + LANE : hi;
                const double *col = buf + (b - b0);
                for (int i = ia; i < ib; i++) out[j0 + i] += (a0 + da * tT[i]) * col[(size_t)(i - b * LANE) * nl];
            }
        }
    }
    free(mem);
    return 1;
}

static int render(const P5Sine *s, int64_t n, int64_t sr, double *out, int exact) {
    Flat F;
    if (n > 0) memset(out, 0, sizeof(double) * (size_t)n);
    if (!s || n <= 0) return 1;
    if (!decode_flat(s, &F)) return 0;
    int ok = 1, H = (int)s->ints[P5S_H];
    if (H <= 0) ok = 0;
    else if (F.ntr && exact)
        /* synth_tracks(tracks, n, H, "integrate", anchors=[0]*, gate_from=0). Python's buffer runs
         * 4 hops past n; every sample under n gets the same terms in the same order either way. */
        ok = st_tracks(F.f, F.a, F.ph, F.len, F.start, NULL, F.ntr, H, 1, TWO_PI_, (double)sr, out, n);
    else if (F.ntr)
        ok = render_rot(&F, H, TWO_PI_, (double)sr, out, n);
    flat_free(&F);
    return ok;
}

int p5_sine_render(const P5Sine *s, int64_t n, int64_t sr, double *out) { return render(s, n, sr, out, 0); }

int p5_sine_render_exact(const P5Sine *s, int64_t n, int64_t sr, double *out) { return render(s, n, sr, out, 1); }

/* ------------------------------------------------------------ worth_keeping */

/* pc.onset_sample(x): the first 44-sample block within 40 dB of the loudest.
 * Two passes over the block energies (recomputed, so the same doubles) instead
 * of an array, so worth_keeping allocates nothing and cannot fail. */
static double block_db(const double *xb) {
    double sq[44];
    for (int i = 0; i < 44; i++) sq[i] = xb[i] * xb[i];
    return 20 * log10(sqrt(pw_sum(sq, 44) / 44 + 1e-20));
}

static int64_t onset_sample(const double *x, int64_t n) {
    int64_t m = n / 44;
    double emax = -INFINITY;
NOVEC
    for (int64_t b = 0; b < m; b++) {
        double e = block_db(x + 44 * b);
        if (e > emax || b == 0) emax = e;
    }
NOVEC
    for (int64_t b = 0; b < m; b++)
        if (block_db(x + 44 * b) > emax + -40.0) return b * 44;
    return 0;
}

/* x . y in the shape of OpenBLAS's ddot (16 lanes, then the tail); not its FMA */
static double dot(const double *x, const double *y, int64_t n) {
    double acc[16] = {0};
    int64_t n1 = n & ~(int64_t)15, i;
    for (i = 0; i < n1; i += 16)
        for (int j = 0; j < 16; j++) acc[j] += x[i + j] * y[i + j];
    double v[4];
    for (int j = 0; j < 4; j++) v[j] = (acc[j] + acc[4 + j]) + (acc[8 + j] + acc[12 + j]);
    double d = (v[0] + v[1]) + (v[2] + v[3]);
    for (; i < n; i++) d += y[i] * x[i];
    return d;
}

/* r . r for r = x - det, without r: dot(r, r, n) term for term */
static double dot_diff(const double *x, const double *y, int64_t n) {
    double acc[16] = {0};
    int64_t n1 = n & ~(int64_t)15, i;
    for (i = 0; i < n1; i += 16)
        for (int j = 0; j < 16; j++) {
            double r = x[i + j] - y[i + j];
            acc[j] += r * r;
        }
    double v[4];
    for (int j = 0; j < 4; j++) v[j] = (acc[j] + acc[4 + j]) + (acc[8 + j] + acc[12 + j]);
    double d = (v[0] + v[1]) + (v[2] + v[3]);
    for (; i < n; i++) {
        double r = x[i] - y[i];
        d += r * r;
    }
    return d;
}

int p5_sine_worth_keeping(const double *x, const double *det, int64_t n, int64_t sine_bytes) {
    double rem = dot_diff(x, det, n), xx = dot(x, x, n);
    double delta = 10 * log10(xx / (rem < 1e-30 ? 1e-30 : rem));
    int64_t nn = n - onset_sample(x, n);
    return delta / 6.02 * (double)nn > (double)(8 * sine_bytes);
}

/* ------------------------------------------------------------ encode_sines */

int p5_sine_encode(const double *x, int64_t n, int64_t sr, const P5Tracks *tr, p5_lz_fn lz, void *lzctx,
                   P5Sine *out, double *det) {
    int64_t any = 0;
    for (int64_t i = 0; i < n && !any; i++) any = x[i] != 0.0;
    if (!any) {     /* encode_sines: `if not np.any(x): return None` */
        memset(out, 0, sizeof(*out));
        if (det && n > 0) memset(det, 0, sizeof(double) * (size_t)n);
        return 0;
    }
    int64_t nt = p5_sine_quantize(tr, sr, lz, lzctx, out);
    if (nt < 0) return -1;
    double *d = det ? det : (double *)malloc(sizeof(double) * (size_t)(n ? n : 1));
    int rc = -1;
    if (!d) goto drop_err;
    if (nt == 0) { rc = 0; goto drop; }
    if (!p5_sine_render(out, n, sr, d)) goto drop_err;
    int64_t bytes = 0;
    for (int i = 0; i < P5S_NSTREAMS; i++) bytes += out->lz_sizes[i];
    if (!p5_sine_worth_keeping(x, d, n, bytes)) { rc = 0; goto drop; }
    if (!det) free(d);
    return 1;
drop:
    if (det && n > 0) memset(det, 0, sizeof(double) * (size_t)n);
drop_err:
    if (!det) free(d);
    p5_sine_free(out);
    memset(out, 0, sizeof(*out));
    return rc;
}

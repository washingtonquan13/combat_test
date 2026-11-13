/* PINST5 C encoder, stage TQ: step sizes and the layer quantizer (port of frozen p5/quant.py). See quant.h.
 *
 * numpy's order, kept where a code rests on it:
 *   np.add.reduceat over a band  = v[lo] + pairwise(v[lo + 1 : hi])
 *   pairwise                     = numpy's DOUBLE_pairwise_sum (8 accumulators, halves past 128)
 *   scipy convolve1d (constant)  = NI_Correlate1D: reversed weights, the symmetric
 *                                  form for an odd filter, origin -1 for an even one
 *   np.round                     = nearbyint (half to even)
 */
#include "quant.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define NOISE_FRAC 0.5
#define TONE_SLOPE 3.0
#define MIN_WID 8
#define GATE 1.0
#define FLOOR_DB 80.0
#define HEARD_FLOOR_DB 0.0
#define SPAN 2048
#define HEARD 1024
#define NARROW_WID 2
#define NARROW_TRY 2
#define NARROW_SLACK (-3.0)
#define NARROW_DB 20.0
#define MS_SLACK 8.0
#define MAXB 64

/* quant._noise_flatness(M, M), printed from the frozen Python (numpy's
 * default_rng(12345) noise, which C does not reproduce). */
static const double NOISE_128[18] = {
    0.977253516976007,  1.0,
    1.0,                1.0,
    1.0,                0.9933748906963418,
    0.9903822700075544, 0.9765661316861474,
    0.9781866062864566, 0.9773458105962398,
    0.9737700848924576, 0.9657972030180161,
    0.9511845124560283, 0.9630416719377289,
    0.9580585107282655, 0.9649503443736237,
    0.9563413219075947, 0.9586825826661761};
static const double NOISE_1024[19] = {
    0.9615657622849267, 1.0,
    1.0,                0.9691707285332014,
    0.9535929048060627, 0.8024312881802724,
    0.8211939261634544, 0.8339391711890574,
    0.8033613144962242, 0.8021012297101533,
    0.8065502351019649, 0.7948103333808998,
    0.7878341577106971, 0.7917620367918337,
    0.7788476878481051, 0.7850912965398664,
    0.7860190775136422, 0.7744219206221541,
    0.7760880398328753};

static const double *noise_flatness(int64_t M, int64_t K, int64_t nbx) {
    if (M == 128 && K == 128 && nbx == 18) return NOISE_128;
    if (M == 1024 && K == 1024 && nbx == 19) return NOISE_1024;
    return NULL;
}

/* ---- numpy sums ---- */

static double pw_sum(const double *a, int64_t n) {
    if (n < 8) {
        double r = 0.0;
        int64_t i;
        for (i = 0; i < n; i++) r += a[i];
        return r;
    } else if (n <= 128) {
        double r[8], res;
        int64_t i;
        int j;
        for (j = 0; j < 8; j++) r[j] = a[j];
        for (i = 8; i < n - (n % 8); i += 8)
            for (j = 0; j < 8; j++) r[j] += a[i + j];
        res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]));
        for (; i < n; i++) res += a[i];
        return res;
    } else {
        int64_t n2 = n / 2;
        n2 -= n2 % 8;
        return pw_sum(a, n2) + pw_sum(a + n2, n - n2);
    }
}

/* np.add.reduceat's sum of one segment */
static inline double red_at(const double *a, int64_t w) {
    if (w <= 1) return w == 1 ? a[0] : 0.0;
    return a[0] + pw_sum(a + 1, w - 1);
}

/* ---- edges, hash, band power ---- */

int64_t p5_edges(int64_t K, int64_t nbands, int64_t *ed) {
    /* np.unique([0] + np.round(np.geomspace(2, K, nbands + 1)).astype(int)) */
    double lo = log10(2.0), hi = log10((double)K), step;
    int64_t i, ne = 0;
    if (nbands < 1) {
        ed[0] = 0;
        return 1;
    }
    step = (hi - lo) / (double)nbands;
    ed[ne++] = 0;
    for (i = 0; i <= nbands; i++) {
        double v = i == 0 ? 2.0 : (i == nbands ? (double)K : pow(10.0, (double)i * step + lo));
        int64_t e = (int64_t)nearbyint(v);
        if (e != ed[ne - 1]) ed[ne++] = e;      /* geomspace rises: unique = drop repeats */
    }
    return ne;
}

void p5_hash_uniform(int64_t seed, int64_t start, int64_t count, double *out) {
    int64_t i;
    uint32_t sd = (uint32_t)(uint64_t)seed;
    for (i = 0; i < count; i++) {
        uint32_t x = (uint32_t)(uint64_t)(start + i) * 0x9E3779B9u + sd;
        x ^= x >> 16;
        x *= 0x85EBCA6Bu;
        x ^= x >> 13;
        x *= 0xC2B2AE35u;
        x ^= x >> 16;
        out[i] = (double)x / 2147483648.0 - 1.0;
    }
}

static inline double hash1(uint32_t sd, int64_t c) {
    uint32_t x = (uint32_t)(uint64_t)c * 0x9E3779B9u + sd;
    x ^= x >> 16;
    x *= 0x85EBCA6Bu;
    x ^= x >> 13;
    x *= 0xC2B2AE35u;
    x ^= x >> 16;
    return (double)x / 2147483648.0 - 1.0;
}

/* band sums of the squares of one row (sq: scratch of K) */
static void row_band_sq(const double *x, int64_t K, const int64_t *ed, int64_t nbx, double *sq,
                        double *out) {
    int64_t i, b;
    for (i = 0; i < K; i++) sq[i] = x[i] * x[i];
    for (b = 0; b < nbx; b++) out[b] = red_at(sq + ed[b], ed[b + 1] - ed[b]);
}

static int band_power_db_ed(const double *X, int64_t F, int64_t K, const int64_t *ed, int64_t nbx,
                            double *out) {
    double *sq = (double *)malloc(sizeof(double) * (size_t)(K > 0 ? K : 1));
    int64_t f, b;
    if (!sq) return -1;
    for (f = 0; f < F; f++) {
        double *o = out + f * nbx;
        row_band_sq(X + f * K, K, ed, nbx, sq, o);
        for (b = 0; b < nbx; b++) o[b] = 10.0 * log10(o[b] / (double)(ed[b + 1] - ed[b]) + 1e-30);
    }
    free(sq);
    return 0;
}

int64_t p5_band_power_db(const double *X, int64_t F, int64_t K, int64_t nbands, double *out) {
    int64_t ed[MAXB + 2], nbx;
    if (nbands > MAXB) return -1;
    nbx = p5_edges(K, nbands, ed) - 1;
    if (band_power_db_ed(X, F, K, ed, nbx, out) < 0) return -1;
    return nbx;
}

double p5_top_db(const double *X, int64_t F, int64_t K) {
    int64_t ed[MAXB + 2], nbx = p5_edges(K, P5_NBANDS, ed) - 1, i;
    double *p = (double *)malloc(sizeof(double) * (size_t)(F * nbx > 0 ? F * nbx : 1)), top;
    if (!p || F * nbx == 0 || band_power_db_ed(X, F, K, ed, nbx, p) < 0) {
        free(p);
        return NAN;
    }
    top = p[0];
    for (i = 1; i < F * nbx; i++)       /* ndarray.max: NaN wins */
        if (p[i] > top || isnan(p[i])) top = p[i];
    free(p);
    return top;
}

/* ---- quant._smooth: scipy convolve1d(P, hann / sum, axis=0, mode="constant") ---- */

/* Rows are ld apart in both in and out; only the first C columns of each row
 * are made (the columns are independent). */
static int smooth(const double *in, int64_t F, int64_t C, int64_t ld, int64_t S, double *out) {
    double g[72], wr[72], sum;
    int64_t i, ll, jj, c, N = S + 2, size1, size2;
    if (S <= 1) {
        for (ll = 0; ll < F; ll++)
            if (out != in) memcpy(out + ll * ld, in + ll * ld, sizeof(double) * (size_t)C);
        return 0;
    }
    if (S > 70) return -1;
    for (i = 0; i < S; i++) {           /* np.hanning(S + 2)[1:-1] */
        double n = (double)(1 - N + 2 * (i + 1));
        g[i] = 0.5 + 0.5 * cos(3.141592653589793 * n / (double)(N - 1));
    }
    sum = pw_sum(g, S);
    for (i = 0; i < S; i++) wr[S - 1 - i] = g[i] / sum;      /* convolve1d reverses the weights */
    size1 = S / 2;
    size2 = S - size1 - 1;
#define IN(r) ((r) >= 0 && (r) < F ? in + (r) * ld : NULL)
    if (S & 1) {                        /* symmetric (hann is): o = x[0] w0 + sum (x[-j] + x[j]) w[-j] */
        const double *fw = wr + size1;
        for (ll = 0; ll < F; ll++) {
            double *o = out + ll * ld;
            const double *x0 = in + ll * ld;
            for (c = 0; c < C; c++) o[c] = x0[c] * fw[0];
            for (jj = -size1; jj < 0; jj++) {
                const double *a = IN(ll + jj), *b = IN(ll - jj);
                double wj = fw[jj];
                if (a && b)
                    for (c = 0; c < C; c++) o[c] += (a[c] + b[c]) * wj;
                else if (a)
                    for (c = 0; c < C; c++) o[c] += (a[c] + 0.0) * wj;
                else if (b)
                    for (c = 0; c < C; c++) o[c] += (0.0 + b[c]) * wj;
                else
                    for (c = 0; c < C; c++) o[c] += 0.0 * wj;
            }
        }
    } else {                            /* even: origin -1 */
        const double *fw = wr + size1;
        const int64_t org = -1;
        for (ll = 0; ll < F; ll++) {
            double *o = out + ll * ld;
            const double *x = IN(ll + size2 - org);
            for (c = 0; c < C; c++) o[c] = (x ? x[c] : 0.0) * fw[size2];
            for (jj = -size1; jj < size2; jj++) {
                const double *y = IN(ll + jj - org);
                double wj = fw[jj];
                if (y)
                    for (c = 0; c < C; c++) o[c] += y[c] * wj;
                else
                    for (c = 0; c < C; c++) o[c] += 0.0 * wj;
            }
        }
    }
#undef IN
    return 0;
}

/* ---- tonality, band_snr ---- */

/* quant._flatness from the squares sq (F x K), for the bands tonality keeps:
 * a band narrower than MIN_WID gets eta 1e-6 whatever its flatness, so its
 * columns are neither smoothed nor logged (out holds 1 there). The columns
 * are independent, so the bands made are the same bits. */
static int flatness_sq(const double *sq, int64_t F, int64_t K, int64_t M, const int64_t *ed,
                       int64_t nbx, double *out) {
    int64_t S = 2 * ((SPAN / M) > 1 ? (SPAN / M) : 1) + 1, f, b, i, c0 = K;
    double *P, *lg;
    for (b = 0; b < nbx; b++)
        if (ed[b + 1] - ed[b] >= MIN_WID && ed[b] < c0) c0 = ed[b];
    P = (double *)malloc(sizeof(double) * (size_t)(F * K + K));
    if (!P) return -1;
    lg = P + F * K;
    if (c0 < K && smooth(sq + c0, F, K - c0, K, S, P + c0) < 0) {
        free(P);
        return -1;
    }
    for (f = 0; f < F; f++) {
        double *p = P + f * K, *o = out + f * nbx;
        for (i = c0; i < K; i++) {
            p[i] = p[i] + 1e-30;
            lg[i] = log(p[i]);
        }
        for (b = 0; b < nbx; b++) {
            int64_t w = ed[b + 1] - ed[b];
            double am, gm;
            if (w < MIN_WID) {
                o[b] = 1.0;
                continue;
            }
            am = red_at(p + ed[b], w) / (double)w;
            gm = exp(red_at(lg + ed[b], w) / (double)w);
            o[b] = gm / am;
        }
    }
    free(P);
    return 0;
}

static inline double clip(double v, double lo, double hi) {
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

static int tonality_sq(const double *sq, int64_t F, int64_t K, int64_t M, const int64_t *ed, int64_t nbx,
                       double *eta) {
    const double *nf = noise_flatness(M, K, nbx);
    int64_t f, b;
    int rc;
    if (!nf) return -2;
    rc = flatness_sq(sq, F, K, M, ed, nbx, eta);
    if (rc < 0) return rc;
    for (f = 0; f < F; f++)
        for (b = 0; b < nbx; b++) {
            double *e = eta + f * nbx + b;
            *e = ed[b + 1] - ed[b] < MIN_WID ? 1e-6 : clip(*e / nf[b], 1e-6, 1.0);
        }
    return 0;
}

static double *squares(const double *X, int64_t n) {
    double *sq = (double *)malloc(sizeof(double) * (size_t)(n > 0 ? n : 1));
    int64_t i;
    if (sq)
        for (i = 0; i < n; i++) sq[i] = X[i] * X[i];
    return sq;
}

int p5_tonality(const double *Xref, int64_t F, int64_t K, int64_t M, double *eta) {
    int64_t ed[MAXB + 2], nbx = p5_edges(K, P5_NBANDS, ed) - 1;
    double *sq;
    int rc;
    if (!noise_flatness(M, K, nbx)) return -2;
    sq = squares(Xref, F * K);
    if (!sq) return -1;
    rc = tonality_sq(sq, F, K, M, ed, nbx, eta);
    free(sq);
    return rc;
}

static int band_snr_ed(const double *Xref, int64_t F, int64_t K, int64_t M, double snr,
                       const int64_t *ed, int64_t nbx, double *bs) {
    double *sq, *P, *lvl;
    int64_t f, b, S = HEARD / M;
    int rc;
    if (!noise_flatness(M, K, nbx)) return -2;
    sq = squares(Xref, F * K);
    P = (double *)malloc(sizeof(double) * (size_t)(2 * F * nbx + 1));
    if (!sq || !P) {
        free(sq);
        free(P);
        return -1;
    }
    lvl = P + F * nbx;
    for (f = 0; f < F; f++)             /* np.add.reduceat(Xref ** 2, ...) */
        for (b = 0; b < nbx; b++) P[f * nbx + b] = red_at(sq + f * K + ed[b], ed[b + 1] - ed[b]);
    rc = tonality_sq(sq, F, K, M, ed, nbx, bs);     /* bs holds eta for now */
    free(sq);
    if (rc < 0 || smooth(P, F, nbx, nbx, S, lvl) < 0) {
        free(P);
        return rc < 0 ? rc : -1;
    }
    for (f = 0; f < F; f++) {
        double *l = lvl + f * nbx, *o = bs + f * nbx, mx;
        for (b = 0; b < nbx; b++) l[b] = 10.0 * log10(l[b] + 1e-30);
        mx = l[0];
        for (b = 1; b < nbx; b++)
            if (l[b] > mx || isnan(l[b])) mx = l[b];
        for (b = 0; b < nbx; b++) {
            double t = snr * NOISE_FRAC - (TONE_SLOPE * 10) * log10(o[b]);
            double bsv = t < snr ? t : snr;     /* np.minimum(snr, t) */
            double near = clip((l[b] - mx) / (GATE * snr) + 1, 0.0, 1.0);
            o[b] = snr - (snr - bsv) * near;
        }
    }
    free(P);
    return 0;
}

int p5_band_snr(const double *Xref, int64_t F, int64_t K, int64_t M, double snr, double *bs) {
    int64_t ed[MAXB + 2], nbx = p5_edges(K, P5_NBANDS, ed) - 1;
    return band_snr_ed(Xref, F, K, M, snr, ed, nbx, bs);
}

/* ---- heard ---- */

int p5_heard_db(const double *const *Xs, int nch, int64_t F, int64_t K, double *out) {
    int64_t ed[MAXB + 2], nbx = p5_edges(K, P5_NBANDS, ed) - 1, i, n = F * nbx;
    double *p = (double *)malloc(sizeof(double) * (size_t)(n > 0 ? n : 1));
    int c;
    if (!p) return -1;
    for (i = 0; i < n; i++) out[i] = 0.0;
    for (c = 0; c < nch; c++) {         /* sum(...) starts from 0 */
        if (band_power_db_ed(Xs[c], F, K, ed, nbx, p) < 0) {
            free(p);
            return -1;
        }
        for (i = 0; i < n; i++) {
            double v = pow(10.0, p[i] / 10.0);
            out[i] = c == 0 ? v : out[i] + v;
        }
    }
    for (i = 0; i < n; i++) out[i] = 10.0 * log10(out[i] + 1e-30);
    free(p);
    return 0;
}

int p5_heard_ms_db(const double *Xm, const double *Xs, int64_t F, int64_t K, double *out) {
    int64_t ed[MAXB + 2], nbx = p5_edges(K, P5_NBANDS, ed) - 1, i, f, b, n = F * nbx;
    double *buf = (double *)malloc(sizeof(double) * (size_t)(3 * K + 4 * nbx + 1));
    const double slack = pow(10.0, MS_SLACK / 10);
    if (!buf) return -1;
    for (f = 0; f < F; f++) {
        double *xl = buf, *xr = buf + K, *sq = buf + 2 * K;
        double *pm = buf + 3 * K, *ps = pm + nbx, *pl = ps + nbx, *pr = pl + nbx;
        const double *m = Xm + f * K, *s = Xs + f * K;
        for (i = 0; i < K; i++) {
            xl[i] = m[i] + s[i];
            xr[i] = m[i] - s[i];
        }
        row_band_sq(m, K, ed, nbx, sq, pm);
        row_band_sq(s, K, ed, nbx, sq, ps);
        row_band_sq(xl, K, ed, nbx, sq, pl);
        row_band_sq(xr, K, ed, nbx, sq, pr);
        for (b = 0; b < nbx; b++) {
            double w = (double)(ed[b + 1] - ed[b]);
            double a = pow(10.0, (10.0 * log10(pm[b] / w + 1e-30)) / 10.0);
            double c = pow(10.0, (10.0 * log10(ps[b] / w + 1e-30)) / 10.0);
            double l = pow(10.0, (10.0 * log10(pl[b] / w + 1e-30)) / 10.0);
            double r = pow(10.0, (10.0 * log10(pr[b] / w + 1e-30)) / 10.0);
            double room = (r < l ? r : l) * slack;      /* np.minimum(pl, pr) */
            double lo = c < a ? c : a;
            double H = 2 * lo >= room ? room / 2 : room - lo;
            out[f * nbx + b] = 10.0 * log10(H + 1e-30);
        }
    }
    (void)n;
    free(buf);
    return 0;
}

/* ---- the code ---- */

/* The two powers of ten a step is made of, each a function of one integer
 * (the scale index, the dq), kept per call as they are first asked for:
 * the same pow on the same argument, so the same bits, made once. */
#define PT_N 1024
typedef struct {
    double snr;
    double rms[PT_N], gain[PT_N];
    uint8_t has_rms[PT_N], has_gain[PT_N];
} Pow10s;

static void pow10s_init(Pow10s *p, double snr) {
    p->snr = snr;
    memset(p->has_rms, 0, sizeof p->has_rms);
    memset(p->has_gain, 0, sizeof p->has_gain);
}

/* 10 ** (sc * 1.5 / 20) */
static inline double rms_of(Pow10s *p, int64_t sc) {
    int64_t k = sc + PT_N / 2;
    if (k < 0 || k >= PT_N) return pow(10.0, ((double)sc * 1.5) / 20.0);
    if (!p->has_rms[k]) {
        p->rms[k] = pow(10.0, ((double)sc * 1.5) / 20.0);
        p->has_rms[k] = 1;
    }
    return p->rms[k];
}

/* 10 ** (-(snr - 1.5 dq) / 20) */
static inline double gain_of(Pow10s *p, int64_t dq) {
    int64_t k = dq + PT_N / 2;
    if (k < 0 || k >= PT_N) return pow(10.0, (-(p->snr - 1.5 * (double)dq)) / 20.0);
    if (!p->has_gain[k]) {
        p->gain[k] = pow(10.0, (-(p->snr - 1.5 * (double)dq)) / 20.0);
        p->has_gain[k] = 1;
    }
    return p->gain[k];
}

/* quant._steps for one band-frame */
static inline double step_of(Pow10s *p, int64_t sc, int live, int64_t dq) {
    double rms = rms_of(p, sc) * (live ? 1.0 : 0.0);
    double r = rms > 1e-30 ? rms : 1e-30;
    return (r * gain_of(p, dq)) * sqrt(12.0);
}

/* quant._decoded's error over one band-frame: x, r its w coefficients and hash */
static double decoded_err(Pow10s *p, const double *x, const double *r, int64_t w, int64_t sc,
                          int live, int64_t d) {
    double q[MAXB], xd[MAXB], t[MAXB];
    double snr = p->snr, st = step_of(p, sc, live, d), rms, lack, nzero = 0.0, fill;
    int cod = live && (snr - 1.5 * (double)d > 0);
    int64_t i;
    for (i = 0; i < w; i++) {
        q[i] = cod ? nearbyint(x[i] / st) : 0.0;
        xd[i] = q[i] * st;
        t[i] = xd[i] * xd[i];
        if (q[i] == 0.0) nzero += 1.0;
    }
    rms = rms_of(p, sc) * (live ? 1.0 : 0.0);
    lack = (rms * rms) * (double)w - red_at(t, w);
    if (lack < 0) lack = 0.0;
    fill = sqrt(lack / (nzero > 1 ? nzero : 1.0));
    if (live) {
        double cap = st / sqrt(12.0);
        if (cap < fill) fill = cap;
    }
    for (i = 0; i < w; i++) {
        double dec = xd[i] + ((q[i] == 0.0 ? 1.0 : 0.0) * fill) * r[i];
        double e = x[i] - dec;
        t[i] = e * e;
    }
    return red_at(t, w);
}

/* quant._narrow_dq, in place on dq */
static void narrow_dq(Pow10s *pw, const double *X, int64_t F, int64_t K, const int32_t *sc,
                      const uint8_t *live, const int64_t *ed, int64_t nbx, int64_t *dq,
                      int64_t seed, double top) {
    const double snr = pw->snr;
    int64_t nb = 0, b, f;
    const double sq3 = sqrt(3.0), slack = pow(10.0, NARROW_SLACK / 10);
    static const int tries[2 * NARROW_TRY + 1] = {0, 1, -1, 2, -2};
    uint32_t sd = (uint32_t)(uint64_t)seed;
    for (b = 0; b < nbx; b++)
        if (ed[b + 1] - ed[b] <= NARROW_WID) nb = b + 1;
    if (!nb) return;
    for (f = 0; f < F; f++)
        for (b = 0; b < nb; b++) {
            int64_t w = ed[b + 1] - ed[b], d0 = dq[f * nbx + b], best = d0, i;
            int64_t s = sc[f * nbx + b];
            int lv = live[f * nbx + b];
            double want, bdist = INFINITY, r[MAXB], st0;
            const double *x = X + f * K + ed[b];
            int c;
            if (!(lv && (snr - 1.5 * (double)d0 > 0) && w <= NARROW_WID &&
                  ((double)s * 1.5 > top - NARROW_DB)))
                continue;
            st0 = step_of(pw, s, lv, d0);
            want = (((st0 * st0) / 12) * (double)w) * slack;
            for (i = 0; i < w; i++) r[i] = hash1(sd, f * K + ed[b] + i) * sq3;
            for (c = 0; c < 2 * NARROW_TRY + 1; c++) {
                int64_t d = d0 + tries[c];
                double err, dist;
                if (!(snr - 1.5 * (double)d > 0)) continue;
                err = decoded_err(pw, x, r, w, s, lv, d);
                dist = fabs(log((err + 1e-300) / want));
                if (dist < bdist - 1e-9) {
                    best = d;
                    bdist = dist;
                }
            }
            dq[f * nbx + b] = best;
        }
}

double p5_quant_snr(double dial) {
    return nearbyint(dial * 100) / 100;
}

int p5_quantize(const double *X, const double *Xref, int64_t F, int64_t K, int64_t M,
                int64_t seed, double dial, double top, const double *heard, const double *tight,
                P5Layer *L) {
    int64_t ed[MAXB + 2], nbx = p5_edges(K, P5_NBANDS, ed) - 1;
    double *bs;
    int rc;
    memset(L, 0, sizeof *L);
    if (!noise_flatness(M, K, nbx)) return -2;
    bs = (double *)malloc(sizeof(double) * (size_t)(F * nbx + 1));
    if (!bs) return -1;
    rc = band_snr_ed(Xref, F, K, M, p5_quant_snr(dial), ed, nbx, bs);
    if (rc == 0) rc = p5_quantize_bs(X, F, K, M, seed, dial, top, heard, tight, bs, L);
    free(bs);
    return rc;
}

int p5_quantize_bs(const double *X, int64_t F, int64_t K, int64_t M, int64_t seed, double dial,
                   double top, const double *heard, const double *tight, const double *bsnr,
                   P5Layer *L) {
    int64_t ed[MAXB + 2], nbx, n, i, f, b, qmin = 0;
    double snr = p5_quant_snr(dial), floor_ = top - FLOOR_DB;
    double *bs = NULL, *sdb = NULL;
    int64_t *dq = NULL;
    uint8_t *live = NULL;
    int any = 0;
    Pow10s pw;
    memset(L, 0, sizeof *L);
    nbx = p5_edges(K, P5_NBANDS, ed) - 1;
    n = F * nbx;
    if (!noise_flatness(M, K, nbx)) return -2;
    bs = (double *)malloc(sizeof(double) * (size_t)(2 * n + 1));
    dq = (int64_t *)malloc(sizeof(int64_t) * (size_t)(n + 1));
    live = (uint8_t *)malloc((size_t)(n + 1));
    if (!bs || !dq || !live) goto nomem;
    sdb = bs + n;
    if (n) memcpy(bs, bsnr, sizeof(double) * (size_t)n);
    if (tight)
        for (f = 0; f < F; f++)
            for (b = 0; b < nbx; b++)
                if (tight[f] > bs[f * nbx + b]) bs[f * nbx + b] = tight[f];
    /* _code */
    if (band_power_db_ed(X, F, K, ed, nbx, sdb) < 0) goto nomem;
    for (i = 0; i < n; i++) {
        live[i] = sdb[i] > floor_;
        if (live[i]) {
            int64_t qs = (int64_t)nearbyint(sdb[i] / 1.5);
            if (!any || qs < qmin) qmin = qs;
            any = 1;
        }
    }
    if (!any) {
        free(bs);
        free(dq);
        free(live);
        return 0;
    }
    L->sc = (int32_t *)malloc(sizeof(int32_t) * (size_t)(n + 1));
    L->dq = (int32_t *)malloc(sizeof(int32_t) * (size_t)(n + 1));
    L->q = (int32_t *)calloc((size_t)(F * K + 1), sizeof(int32_t));
    if (!L->sc || !L->dq || !L->q) goto nomem;
    L->dead = qmin - 1;
    for (i = 0; i < n; i++) {
        int64_t qs = (int64_t)nearbyint(sdb[i] / 1.5);
        double over = heard[i] - (double)qs * 1.5, o2;
        if (!(over < 0)) over = over != over ? over : 0.0;         /* np.minimum(., 0) */
        o2 = ((floor_ - HEARD_FLOOR_DB) + bs[i]) - (double)qs * 1.5;
        if (!(o2 < 0)) o2 = o2 != o2 ? o2 : 0.0;
        if (o2 > over) over = o2;                                   /* np.maximum */
        L->sc[i] = (int32_t)(live[i] ? qs : L->dead);
        dq[i] = live[i] ? (int64_t)nearbyint(((snr - bs[i]) + over) / 1.5) : 0;
    }
    pow10s_init(&pw, snr);
    narrow_dq(&pw, X, F, K, L->sc, live, ed, nbx, dq, seed, floor_ + FLOOR_DB);
    for (f = 0; f < F; f++)
        for (b = 0; b < nbx; b++) {
            int64_t j = f * nbx + b;
            L->dq[j] = (int32_t)dq[j];
            if (live[j] && !(snr - 1.5 * (double)dq[j] <= 0)) {
                double st = step_of(&pw, L->sc[j], 1, dq[j]);
                const double *x = X + f * K;
                int32_t *q = L->q + f * K;
                for (i = ed[b]; i < ed[b + 1]; i++) q[i] = (int32_t)nearbyint(x[i] / st);
            }
        }
    L->M = M;
    L->K = K;
    L->nbands = P5_NBANDS;
    L->nbx = nbx;
    L->frames = F;
    L->seed = seed;
    L->start = 0;
    L->snr = snr;
    free(bs);
    free(dq);
    free(live);
    return 1;
nomem:
    free(bs);
    free(dq);
    free(live);
    free(L->sc);
    free(L->dq);
    free(L->q);
    memset(L, 0, sizeof *L);
    return -1;
}

int p5_dequantize(const P5Layer *L, double *Xd) {
    int64_t ed[MAXB + 2], nbx, f, b, i, K = L->K;
    double *t = (double *)malloc(sizeof(double) * (size_t)(K > 0 ? K : 1));
    const double sq3 = sqrt(3.0), sq12 = sqrt(12.0);
    uint32_t sd = (uint32_t)(uint64_t)L->seed;
    Pow10s pw;
    if (!t) return -1;
    pow10s_init(&pw, L->snr);
    nbx = p5_edges(K, L->nbands, ed) - 1;
    for (f = 0; f < L->frames; f++)
        for (b = 0; b < nbx; b++) {
            int64_t j = f * nbx + b, w = ed[b + 1] - ed[b];
            int lv = L->sc[j] != L->dead;
            double rms = rms_of(&pw, L->sc[j]) * (lv ? 1.0 : 0.0);
            double st = step_of(&pw, L->sc[j], lv, L->dq[j]);
            double lack, nzero = 0.0, fill;
            const int32_t *q = L->q + f * K + ed[b];
            double *o = Xd + f * K + ed[b];
            for (i = 0; i < w; i++) {
                o[i] = (double)q[i] * st;
                t[i] = o[i] * o[i];
                if (q[i] == 0) nzero += 1.0;
            }
            lack = (rms * rms) * (double)w - red_at(t, w);
            if (lack < 0) lack = 0.0;
            fill = sqrt(lack / (nzero > 1 ? nzero : 1.0));
            if (lv && st / sq12 < fill) fill = st / sq12;
            for (i = 0; i < w; i++) {
                double r = hash1(sd, f * K + ed[b] + i) * sq3;
                o[i] = o[i] + ((q[i] == 0 ? 1.0 : 0.0) * fill) * r;
            }
        }
    free(t);
    return 0;
}

void p5_live_mask(const P5Layer *L, uint8_t *mask) {
    int64_t ed[MAXB + 2], nbx = p5_edges(L->K, L->nbands, ed) - 1, f, b, i;
    for (f = 0; f < L->frames; f++)
        for (b = 0; b < nbx; b++) {
            uint8_t v = L->sc[f * nbx + b] != L->dead;
            for (i = ed[b]; i < ed[b + 1]; i++) mask[f * L->K + i] = v;
        }
}

void p5_coded_mask(const P5Layer *L, uint8_t *mask) {
    int64_t ed[MAXB + 2], nbx = p5_edges(L->K, L->nbands, ed) - 1, f, b, i;
    for (f = 0; f < L->frames; f++)
        for (b = 0; b < nbx; b++) {
            int64_t j = f * nbx + b;
            uint8_t v = L->sc[j] != L->dead && (L->snr - 1.5 * (double)L->dq[j] > 0);
            for (i = ed[b]; i < ed[b + 1]; i++) mask[f * L->K + i] = v;
        }
}

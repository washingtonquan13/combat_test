/* PINST5 C encoder: the encoder's measures and decisions (owner: PK). See
 * measure.h; frozen p5/encode.py is the reference. */
#include "measure.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------ numpy's pairwise sum */

/* numpy/_core/src/umath/loops_utils.h.src pairwise_sum, element E(i) */
#define PAIRWISE(NAME, ARGS, CALL_LO, CALL_HI, E)                                   \
    static double NAME ARGS {                                                       \
        if (n < 8) {                                                                \
            double res = 0.;                                                        \
            int64_t i;                                                              \
            for (i = 0; i < n; i++) res += E(i);                                    \
            return res;                                                             \
        } else if (n <= 128) {                                                      \
            double r[8], res;                                                       \
            int64_t i, j;                                                           \
            for (j = 0; j < 8; j++) r[j] = E(j);                                    \
            for (i = 8; i < n - (n % 8); i += 8)                                    \
                for (j = 0; j < 8; j++) r[j] += E(i + j);                           \
            res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7])); \
            for (; i < n; i++) res += E(i);                                         \
            return res;                                                             \
        } else {                                                                    \
            int64_t n2 = n / 2;                                                     \
            n2 -= n2 % 8;                                                           \
            return CALL_LO + CALL_HI;                                               \
        }                                                                           \
    }

#define E_A(i) (a[i])
PAIRWISE(pw, (const double *a, int64_t n), pw(a, n2), pw(a + n2, n - n2), E_A)
#define E_SQ(i) (x[(i) * sx] * x[(i) * sx])
PAIRWISE(pw_sq, (const double *x, int64_t sx, int64_t n), pw_sq(x, sx, n2), pw_sq(x + n2 * sx, sx, n - n2), E_SQ)
#define E_SQD(i) ((x[(i) * sx] - y[(i) * sy]) * (x[(i) * sx] - y[(i) * sy]))
PAIRWISE(pw_sqd, (const double *x, int64_t sx, const double *y, int64_t sy, int64_t n),
         pw_sqd(x, sx, y, sy, n2), pw_sqd(x + n2 * sx, sx, y + n2 * sy, sy, n - n2), E_SQD)

double p5_pairwise_sum(const double *a, int64_t n) { return n > 0 ? pw(a, n) : 0.0; }
double p5_sumsq(const double *x, int64_t sx, int64_t n) { return n > 0 ? pw_sq(x, sx, n) : 0.0; }
double p5_sumsqdiff(const double *x, int64_t sx, const double *y, int64_t sy, int64_t n) {
    return n > 0 ? pw_sqd(x, sx, y, sy, n) : 0.0;
}

/* Python's max(a, b) and min(a, b) of two floats: the first unless the second compares over/under */
static double pmax(double a, double b) { return b > a ? b : a; }

/* ------------------------------------------------------------ _snr_db */

double p5_snr_db_xe(double xe, const double *x, int64_t sx, const double *y, int64_t sy, int64_t n) {
    return 10 * log10(xe / pmax(p5_sumsqdiff(x, sx, y, sy, n), 1e-30));
}

double p5_snr_db(const double *x, int64_t sx, const double *y, int64_t sy, int64_t n) {
    return p5_snr_db_xe(pmax(p5_sumsq(x, sx, n), 1e-30), x, sx, y, sy, n);
}

/* ------------------------------------------------------------ pre_echo_db */

/* 10 * np.log10(np.maximum(p, 1e-30)) (np.maximum passes NaN on) */
static double db(double p) { return 10 * log10(p != p ? p : (p > 1e-30 ? p : 1e-30)); }

int p5_pre_init(P5PreEcho *pe, const double *x, int64_t sx, int64_t n, int64_t sr) {
    int64_t b, m, i, j;
    double *ps = NULL, *s = NULL, top;
    memset(pe, 0, sizeof *pe);
    b = (int64_t)nearbyint((double)sr / 1000.0);       /* round(sr / 1000): half to even */
    if (b < 1) b = 1;
    m = n / b;
    pe->b = b;
    pe->m = m;
    if (m < 30) return 0;
    ps = (double *)malloc((size_t)m * sizeof(double));
    s = (double *)malloc((size_t)m * sizeof(double));
    pe->floor = (double *)malloc((size_t)m * sizeof(double));
    pe->hits = (int64_t *)malloc((size_t)m * sizeof(int64_t));
    if (!ps || !s || !pe->floor || !pe->hits) {
        free(ps); free(s);
        p5_pre_free(pe);
        return -1;
    }
    /* (x[:m*b].reshape(m, b) ** 2).mean(1): a pairwise sum per row, over b */
    for (i = 0; i < m; i++) {
        ps[i] = pw_sq(x + i * b * sx, sx, b) / (double)b;
        s[i] = db(ps[i]);
    }
    top = s[0];
    for (i = 1; i < m; i++)
        if (s[i] > top || s[i] != s[i]) top = (top != top) ? top : s[i];      /* ndarray.max: NaN wins */
    for (i = 0; i < m; i++) pe->floor[i] = (s[i] != s[i]) ? s[i] : pmax(s[i], top - 60);  /* np.maximum */
    /* prev = convolve([0]*8 + ps, ones(8)/8, "valid")[:m]: ddot, left to right from 0 */
    for (i = 1; i < m; i++) {
        double prev = 0.0;
        for (j = 0; j < 8; j++) {
            int64_t k = i - 8 + j;
            prev += (k >= 0 ? ps[k] : 0.0) * 0.125;
        }
        if (s[i] > db(prev) + 12 && s[i] > top - 60) pe->hits[pe->nhits++] = i;
    }
    free(ps);
    free(s);
    return 0;
}

double p5_pre_measure(const P5PreEcho *pe, const double *y, int64_t sy) {
    int64_t b = pe->b, m = pe->m, i, j, h0 = -1;
    double worst = 0.0, *over;
    if (m < 30 || !pe->nhits) return 0.0;
    /* over = db(pd) - floor, made only on the blocks some hit looks back on */
    over = (double *)malloc((size_t)m * sizeof(double));
    if (!over) return NAN;
    for (i = 0; i < pe->nhits; i++) {
        int64_t h = pe->hits[i], lo = h - 20 > 0 ? h - 20 : 0;
        double v;
        for (j = (lo > h0 ? lo : h0); j < h; j++) over[j] = db(pw_sq(y + j * b * sy, sy, b) / (double)b) - pe->floor[j];
        if (h > h0) h0 = h;
        /* over[lo:h].max(): NaN wins */
        v = over[lo];
        for (j = lo + 1; j < h; j++)
            if (v == v && (over[j] > v || over[j] != over[j])) v = over[j];
        worst = pmax(worst, v);         /* max(worst, float(v)): NaN keeps worst */
    }
    free(over);
    return worst;
}

void p5_pre_free(P5PreEcho *pe) {
    free(pe->floor);
    free(pe->hits);
    pe->floor = NULL;
    pe->hits = NULL;
    pe->nhits = 0;
}

double p5_pre_echo_db(const double *x, int64_t sx, const double *y, int64_t sy, int64_t n, int64_t sr) {
    P5PreEcho pe;
    double v;
    if (p5_pre_init(&pe, x, sx, n, sr)) return NAN;
    v = p5_pre_measure(&pe, y, sy);
    p5_pre_free(&pe);
    return v;
}

/* ------------------------------------------------------------ channels_of */

int p5_channels_of(const double *x, int64_t n, int64_t nch, double *mid, double *side, double *side_db) {
    int64_t i;
    double sd;
    if (nch == 1) {
        memcpy(mid, x, (size_t)n * sizeof(double));
        if (side_db) *side_db = 0.0;
        return 0;
    }
    for (i = 0; i < n; i++) {
        mid[i] = 0.5 * (x[2 * i] + x[2 * i + 1]);
        side[i] = 0.5 * (x[2 * i] - x[2 * i + 1]);
    }
    sd = 20 * log10(sqrt(p5_sumsq(side, 1, n) / (double)n) / pmax(sqrt(p5_sumsq(mid, 1, n) / (double)n), 1e-12) + 1e-12);
    if (side_db) *side_db = sd;
    if (!(sd >= P5_SIDE_DB)) memset(side, 0, (size_t)n * sizeof(double));
    return 1;
}

/* ------------------------------------------------------------ maximum_filter1d */

/* the most of t over [lo, hi] (cval where that runs outside [0, n)) */
static double win_max(const double *t, int64_t n, int64_t lo, int64_t hi, double cval) {
    int64_t a = lo > 0 ? lo : 0, b = hi < n - 1 ? hi : n - 1, i;
    int pad = lo < 0 || hi > n - 1;
    double v = pad ? cval : -INFINITY;
    for (i = a; i <= b; i++)
        if (t[i] > v) v = t[i];
    if (!pad && a > b) v = cval;
    return v;
}

void p5_maximum_filter1d(const double *t, int64_t n, int64_t size, double cval, double *out) {
    /* the window of out[i]: [i - s1, i + s2] (ni_filters.c: size1 = size / 2,
     * size2 = size - size1 - 1); a deque of indices whose values fall */
    int64_t s1 = size / 2, s2 = size - s1 - 1, i, next = 0, head = 0, tail = 0;
    int64_t *dq;
    if (n <= 0) return;
    dq = (int64_t *)malloc((size_t)n * sizeof(int64_t));
    if (!dq) {          /* no memory: the same values, slower */
        for (i = 0; i < n; i++) out[i] = win_max(t, n, i - s1, i + s2, cval);
        return;
    }
    for (i = 0; i < n; i++) {
        int64_t lo = i - s1, hi = i + s2, top = hi < n - 1 ? hi : n - 1;
        double v;
        for (; next <= top; next++) {
            while (tail > head && t[dq[tail - 1]] <= t[next]) tail--;
            dq[tail++] = next;
        }
        while (tail > head && dq[head] < lo) head++;
        v = tail > head ? t[dq[head]] : cval;
        if ((lo < 0 || hi > n - 1) && cval > v) v = cval;
        out[i] = v;
    }
    free(dq);
}

void p5_frame_max(const double *t, int64_t n, int64_t M, int64_t s, int64_t F, double *out) {
    int64_t f;
    for (f = 0; f < F; f++) {
        int64_t c = s + f * M + M / 2;
        if (c > n - 1) c = n - 1;
        out[f] = win_max(t, n, c - M, c + M - 1, 0.0);       /* size 2M: [c - M, c + M - 1] */
    }
}

void p5_frame_max_mf(const double *mf, int64_t n, int64_t M, int64_t s, int64_t F, double *out) {
    int64_t f;
    for (f = 0; f < F; f++) {
        int64_t c = s + f * M + M / 2;
        out[f] = mf[c < n - 1 ? c : n - 1];
    }
}

void p5_fit(const double *X, int64_t rows, int64_t cols, int64_t F, double *out) {
    int64_t r = rows < F ? rows : F;
    if (r > 0) memcpy(out, X, (size_t)(r * cols) * sizeof(double));
    if (F > r) memset(out + r * cols, 0, (size_t)((F - r) * cols) * sizeof(double));
}

/* ------------------------------------------------------------ _stereo's choice */

int p5_stereo_choice(const int64_t nb[3], const double snr[3], const double pre[3]) {
    double n0 = (double)nb[0];
    int i, k = 0, found = 0;
    for (i = 1; i <= 2; i++) {
        double ni = (double)nb[i];
        if (ni <= n0 * (1 + P5_STEREO_COST) && snr[i] >= snr[0] - P5_SNR_TOL && pre[i] <= pre[0] + P5_PRE_TOL
            && (ni <= n0 * (1 - P5_STEREO_COST) || snr[i] >= snr[0] + P5_SNR_GAIN || pre[i] <= pre[0] - P5_PRE_GAIN)) {
            if (!found || nb[i] < nb[k]) k = i;         /* min(ok, key=n): the first smallest */
            found = 1;
        }
    }
    if (pre[k] > P5_PRE_OK) {
        int fix[3], nf = 0, kk = -1;
        double best, thr;
        for (i = 0; i < 3; i++)
            if ((double)nb[i] <= n0 * (1 + P5_FIX_COST) && snr[i] >= snr[k] - P5_SNR_TOL && pre[i] <= pre[k] - P5_PRE_GAIN)
                fix[nf++] = i;
        if (nf) {
            best = pre[fix[0]];
            for (i = 1; i < nf; i++)
                if (pre[fix[i]] < best) best = pre[fix[i]];     /* Python min: the first unless one is under it */
            thr = pmax(best + P5_PRE_TOL, P5_PRE_OK);
            for (i = 0; i < nf; i++)
                if (pre[fix[i]] <= thr && (kk < 0 || nb[fix[i]] < nb[kk])) kk = fix[i];
            if (kk >= 0) k = kk;        /* (never empty unless NaN, where Python raises) */
        }
    }
    return k;
}

/* ------------------------------------------------------------ _peaks' rule */

double p5_peak_lim(const double *x, int64_t count) {
    double m;
    int64_t i;
    if (count <= 0) return NAN;
    m = fabs(x[0]);
    for (i = 1; i < count; i++) {
        double a = fabs(x[i]);
        if (m == m && (a > m || a != a)) m = a;       /* ndarray.max: NaN wins */
    }
    return P5_PEAK_OVER * m;
}

static int row_over(const double *y, int64_t i, int64_t nch, double lim) {
    int64_t c;
    for (c = 0; c < nch; c++)
        if (fabs(y[i * nch + c]) > lim) return 1;
    return 0;
}

int64_t p5_peaks_step(const double *y, int64_t n, int64_t nch, double lim, double dial, double *t, double *scratch) {
    int64_t i, cnt = 0;
    for (i = 0; i < n; i++) cnt += row_over(y, i, nch, lim);
    if (!cnt) return 0;
    /* near is the filter of t as it stands, before any of it changes */
    p5_maximum_filter1d(t, n, 2 * P5_PEAK_LONG_M, 0.0, scratch);
    for (i = 0; i < n; i++)
        if (row_over(y, i, nch, lim)) t[i] = scratch[i] > 0 ? scratch[i] + P5_PEAK_DB : dial;
    return cnt;
}

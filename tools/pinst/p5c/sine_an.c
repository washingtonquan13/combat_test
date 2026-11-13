/* PINST5 C encoder, stage SA: the sine analysis. See sine_an.h.
 *
 * Ported from frozen p5/analysis.py (find_pitch, window_for, _analyse) and
 * pinst_codec.py (onset_sample, _stft_frames, find_peaks_frames, track_peaks,
 * _cut_tracks). Sums are numpy's pairwise sums where Python sums, so the
 * thresholds see the same numbers up to the FFT's rounding. */
#include "sine_an.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "fft.h"

#if defined(_M_X64) || defined(__SSE2__) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#define SA_SSE2 1   /* plain IEEE double ops two at a time: the same bits as scalar */
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* native/trackfast.c: the tracker's assignment step, as pc.track_peaks calls it */
int64_t track_assign(const double *f, const int64_t *cuts, int64_t F, int64_t first, double tol,
                     int64_t *ids, int64_t *src, int64_t *starts);

#define SA_H 256            /* analysis.H */
#define SA_N_MIN 2048       /* analysis.N_MIN, N_MAX, CYCLES */
#define SA_N_MAX 8192
#define SA_CYCLES 6
#define SA_PITCHED 0.5      /* analysis.PITCHED */

/* ------------------------------------------------------------ helpers */

/* numpy's pairwise sum (contiguous float64 add.reduce), bit for bit */
static double pw_sum(const double *a, int64_t n) {
    if (n < 8) {
        double r = 0.;
        for (int64_t i = 0; i < n; i++) r += a[i];
        return r;
    }
    if (n <= 128) {
        double r0 = a[0], r1 = a[1], r2 = a[2], r3 = a[3], r4 = a[4], r5 = a[5], r6 = a[6], r7 = a[7];
        int64_t i, e = n - (n % 8);
        for (i = 8; i < e; i += 8) {
            r0 += a[i]; r1 += a[i + 1]; r2 += a[i + 2]; r3 += a[i + 3];
            r4 += a[i + 4]; r5 += a[i + 5]; r6 += a[i + 6]; r7 += a[i + 7];
        }
        double res = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7));
        for (; i < n; i++) res += a[i];
        return res;
    }
    int64_t n2 = n / 2;
    n2 -= n2 % 8;
    return pw_sum(a, n2) + pw_sum(a + n2, n - n2);
}

/* (value, index) ascending: numpy's argsort order with ties by position */
typedef struct {
    double v;
    int64_t i;
} VI;

static int vi_cmp(const void *pa, const void *pb) {
    const VI *a = (const VI *)pa, *b = (const VI *)pb;
    if (a->v < b->v) return -1;
    if (a->v > b->v) return 1;
    return (a->i > b->i) - (a->i < b->i);
}

/* pc.onset_sample */
static int64_t onset(const double *x, int64_t n) {
    int64_t m = n / 44;
    if (m <= 0) return 0;
    double *e = (double *)malloc(sizeof(double) * m), sq[44], mx = -INFINITY;
    if (!e) return -1;
    for (int64_t b = 0; b < m; b++) {
        const double *p = x + b * 44;
        for (int j = 0; j < 44; j++) sq[j] = p[j] * p[j];
        e[b] = 20 * log10(sqrt(pw_sum(sq, 44) / 44 + 1e-20));
        if (e[b] > mx) mx = e[b];
    }
    int64_t on = 0;
    double thr = mx + -40.0;
    for (int64_t b = 0; b < m; b++)
        if (e[b] > thr) {
            on = b * 44;
            break;
        }
    free(e);
    return on;
}

/* ------------------------------------------------------------ pitch */

/* scipy.signal._peak_finding_utils._local_maxima_1d: plateau midpoints */
static int64_t local_maxima(const double *x, int64_t L, int64_t *pk) {
    int64_t m = 0, i = 1, imax = L - 1;
    while (i < imax) {
        if (x[i - 1] < x[i]) {
            int64_t ia = i + 1;
            while (ia < imax && x[ia] == x[i]) ia++;
            if (x[ia] < x[i]) {
                pk[m++] = (i + ia - 1) / 2;
                i = ia;
            }
        }
        i++;
    }
    return m;
}

/* scipy's _peak_prominences with wlen = -1 (the whole signal) */
static double prominence(const double *x, int64_t L, int64_t peak) {
    double xp = x[peak], lmin = xp, rmin = xp;
    for (int64_t i = peak; i >= 0 && x[i] <= xp; i--)
        if (x[i] < lmin) lmin = x[i];
    for (int64_t i = peak; i <= L - 1 && x[i] <= xp; i++)
        if (x[i] < rmin) rmin = x[i];
    return xp - (lmin > rmin ? lmin : rmin);
}

/* analysis._long_spectrum + _peaks: up to 40 peaks (Hz, dB), loudest first.
 * Returns the count, or -1. */
static int64_t pitch_peaks(const double *x, int64_t n, int64_t sr, int64_t on, double *pf, double *pa,
                           int64_t *Nout) {
    int64_t N = (int64_t)1 << (int)ceil(log2(0.35 * (double)sr));
    int64_t B = N / 2 + 1, hop = N / 4;
    int64_t want = (int64_t)(1.5 * (double)sr);
    int64_t seglen = n - on < want ? n - on : want;
    if (seglen < 0) seglen = 0;
    int64_t len = seglen < N ? N : seglen;
    int64_t nw = (len - N) / hop + 1;
    double *w = (double *)malloc(sizeof(double) * N), *buf = (double *)malloc(sizeof(double) * N);
    double *scr = (double *)malloc(sizeof(double) * N), *X = (double *)malloc(sizeof(double) * (N + 2));
    double *P = (double *)calloc(B, sizeof(double)), *db = (double *)malloc(sizeof(double) * B);
    int64_t *pk = (int64_t *)malloc(sizeof(int64_t) * (B / 2 + 2));
    VI *ord = (VI *)malloc(sizeof(VI) * (B / 2 + 2));
    double *ff = (double *)malloc(sizeof(double) * (B / 2 + 2));
    p5fft_plan *plan = p5fft_plan_new((int)N);
    int64_t np_ = -1;
    if (!w || !buf || !scr || !X || !P || !db || !pk || !ord || !ff || !plan) goto done;
    for (int64_t j = 0; j < N; j++) w[j] = 0.5 + 0.5 * cos(M_PI * (double)(1 - N + 2 * j) / (double)(N - 1));
    const double *seg = x + on;
    for (int64_t q = 0; q < nw; q++) {
        int64_t s = q * hop;
        for (int64_t j = 0; j < N; j++) buf[j] = (s + j < seglen ? seg[s + j] : 0.0) * w[j];
        p5fft_rfft(plan, buf, X, scr);
        for (int64_t k = 0; k < B; k++) P[k] += X[2 * k] * X[2 * k] + X[2 * k + 1] * X[2 * k + 1];
    }
    double mx = -INFINITY;
    for (int64_t k = 0; k < B; k++) {
        db[k] = 10 * log10(P[k] / (double)nw + 1e-30);
        if (db[k] > mx) mx = db[k];
    }
    int64_t m = local_maxima(db, B, pk), c = 0;
    double hmin = mx + -60.0;
    for (int64_t j = 0; j < m; j++) {
        int64_t k = pk[j];
        if (!(hmin <= db[k])) continue;
        if (!(12.0 <= prominence(db, B, k))) continue;
        if (!(k > 1 && k < B - 1)) continue;
        double a = db[k - 1], b = db[k], cc = db[k + 1];
        double p = 0.5 * (a - cc) / (a - 2 * b + cc);
        ff[c] = ((double)k + p) * (double)sr / (double)N;
        ord[c].v = b - 0.25 * (a - cc) * p;
        ord[c].i = c;
        c++;
    }
    qsort(ord, (size_t)c, sizeof(VI), vi_cmp);
    np_ = c < 40 ? c : 40;
    for (int64_t j = 0; j < np_; j++) {      /* argsort(amp)[::-1][:40] */
        pf[j] = ff[ord[c - 1 - j].i];
        pa[j] = ord[c - 1 - j].v;
    }
    *Nout = N;
done:
    free(w); free(buf); free(scr); free(X); free(P); free(db); free(pk); free(ord); free(ff);
    p5fft_plan_free(plan);
    return np_;
}

static int find_pitch_on(const double *x, int64_t n, int64_t sr, int64_t on, double *f0) {
    double f[40], a[40], e[40], tol[40], hh[40], t1[40], t2[40];
    int64_t N = 0, P = pitch_peaks(x, n, sr, on, f, a, &N);
    *f0 = 0.0;
    if (P < 0) return -1;
    if (P == 0) return 0;
    for (int64_t j = 0; j < P; j++) e[j] = pow(10.0, a[j] / 20);
    double es = pw_sum(e, P);
    double tbase = 0.6 * (double)sr / (double)N;
    for (int64_t j = 0; j < P; j++) {
        e[j] = e[j] / es;
        double t = 0.005 * f[j];
        tol[j] = tbase > t ? tbase : t;
    }
    double stop = 1200 * log2(2000.0 / 15.0);
    int64_t G = (int64_t)ceil(stop / 2);
    double best = -INFINITY, gbest = 0;
    for (int64_t g = 0; g < G; g++) {
        double gr = 15.0 * pow(2.0, (double)(2 * g) / 1200);
        for (int64_t j = 0; j < P; j++) {
            double h = nearbyint(f[j] / gr);
            if (h < 1) h = 1;
            int ok = h <= 40 && fabs(f[j] - h * gr) < tol[j];
            double ch = 2 * tol[j] / gr;
            if (ch > 1) ch = 1;
            t1[j] = ok ? e[j] : 0.0;
            t2[j] = ch * e[j];
        }
        double sc = pw_sum(t1, P) - pw_sum(t2, P);
        if (sc > best) {
            best = sc;
            gbest = gr;
        }
    }
    if (best < SA_PITCHED) return 0;
    int ok[40], any16 = 0;
    for (int64_t j = 0; j < P; j++) {
        double h = nearbyint(f[j] / gbest);
        if (h < 1) h = 1;
        hh[j] = h;
        ok[j] = h <= 40 && fabs(f[j] - h * gbest) < tol[j];
        if (ok[j] && h <= 16) any16 = 1;
    }
    double nn[40], ww[40], rr[40], wr[40];
    int64_t m = 0;
    for (int64_t j = 0; j < P; j++)
        if (ok[j] && (!any16 || hh[j] <= 16)) {
            nn[m] = hh[j];
            ww[m] = sqrt(e[j]);
            rr[m] = f[j] / nn[m];
            wr[m] = ww[m] * rr[m];
            m++;
        }
    double r0 = pw_sum(wr, m) / pw_sum(ww, m);
    int nu = 0;     /* len(np.unique(n)) >= 3 */
    {
        double u[3];
        for (int64_t j = 0; j < m && nu < 3; j++) {
            int seen = 0;
            for (int q = 0; q < nu; q++)
                if (u[q] == nn[j]) seen = 1;
            if (!seen) u[nu++] = nn[j];
        }
    }
    if (nu >= 3) {
        /* lstsq([1, n^2] * w, r * w) by Householder QR */
        double A1[40], A2[40], bb[40];
        for (int64_t j = 0; j < m; j++) {
            A1[j] = ww[j];
            A2[j] = nn[j] * nn[j] * ww[j];
            bb[j] = rr[j] * ww[j];
        }
        double s = 0;
        for (int64_t j = 0; j < m; j++) s += A1[j] * A1[j];
        double al = A1[0] > 0 ? -sqrt(s) : sqrt(s);
        A1[0] -= al;
        double vv = 0, d2 = 0, db_ = 0;
        for (int64_t j = 0; j < m; j++) {
            vv += A1[j] * A1[j];
            d2 += A1[j] * A2[j];
            db_ += A1[j] * bb[j];
        }
        for (int64_t j = 0; j < m; j++) {
            A2[j] -= 2 * A1[j] * d2 / vv;
            bb[j] -= 2 * A1[j] * db_ / vv;
        }
        s = 0;
        for (int64_t j = 1; j < m; j++) s += A2[j] * A2[j];
        double al2 = A2[1] > 0 ? -sqrt(s) : sqrt(s);
        double R12 = A2[0];
        A2[1] -= al2;
        vv = 0;
        db_ = 0;
        for (int64_t j = 1; j < m; j++) {
            vv += A2[j] * A2[j];
            db_ += A2[j] * bb[j];
        }
        for (int64_t j = 1; j < m; j++) bb[j] -= 2 * A2[j] * db_ / vv;
        double s1 = bb[1] / al2;
        double s0 = (bb[0] - R12 * s1) / al;
        if (s1 > 0) r0 = s0;
    }
    *f0 = r0;
    return 1;
}

P5_API int64_t p5_sa_onset(const double *x, int64_t n) { return onset(x, n); }

P5_API int p5_sa_find_pitch(const double *x, int64_t n, int64_t sr, double *f0) {
    int64_t on = onset(x, n);
    if (on < 0) return -1;
    return find_pitch_on(x, n, sr, on, f0);
}

P5_API int64_t p5_sa_window_for(double f0, int64_t sr) {
    if (!(f0 > 0)) return SA_N_MIN;
    double e = ceil(log2((double)(SA_CYCLES * sr) / f0));
    if (e <= 11) return SA_N_MIN;
    if (e >= 13) return SA_N_MAX;
    return (int64_t)1 << (int)e;
}

/* ------------------------------------------------------------ peaks */

static int grow(P5SAPeaks *o, int64_t *cap, int64_t need) {
    if (need <= *cap) return 1;
    int64_t c = *cap * 2 > need ? *cap * 2 : need;
    double *f = (double *)realloc(o->f, sizeof(double) * c);
    if (f) o->f = f;
    double *a = (double *)realloc(o->a, sizeof(double) * c);
    if (a) o->a = a;
    double *p = (double *)realloc(o->ph, sizeof(double) * c);
    if (p) o->ph = p;
    if (!f || !a || !p) return 0;
    *cap = c;
    return 1;
}

/* pc.find_peaks_frames(x, N, H, fmax=fmax); frames before `first` are left
 * empty (the tracker ignores them). */
static int peaks_frames(const double *x, int64_t n, int64_t sr, int64_t N, int64_t H, double fmax, int64_t first,
                        P5SAPeaks *out) {
    const int64_t max_peaks = 100;
    const double rel_db = -80.0, abs_db = -110.0, prom_db = 9.0;
    int64_t Z = 2 * N, L = Z / 2 + 1, half = N / 2;
    int64_t S = Z / 128 > 9 ? Z / 128 : 9, s1 = S / 2, s2 = S - s1 - 1;
    int64_t F = 1 + n / H, cap = 0, tot = 0;
    int rc = -1;
    memset(out, 0, sizeof(*out));
    out->F = F;
    out->cuts = (int64_t *)malloc(sizeof(int64_t) * (F + 1));
    double *w = (double *)malloc(sizeof(double) * N), *buf = (double *)calloc(Z, sizeof(double));
    double *scr = (double *)malloc(sizeof(double) * Z), *X = (double *)malloc(sizeof(double) * (Z + 2));
    /* q = |X|^2 and ua (the floor estimate's u) live at [0, L) of padded rows
     * whose pads [-s1-1, 0) and [L, L+s2] hold the reflected bins */
    const int64_t off = s1 + 1, padn = L + S + 2;
    double *db = (double *)malloc(sizeof(double) * L), *qrow = (double *)malloc(sizeof(double) * padn);
    double *uarow = (double *)malloc(sizeof(double) * padn);
    int64_t *seen = (int64_t *)calloc(L, sizeof(int64_t)), *hit = (int64_t *)malloc(sizeof(int64_t) * (L + 2));
    double *cf = (double *)malloc(sizeof(double) * L), *cph = (double *)malloc(sizeof(double) * L);
    VI *ca = (VI *)malloc(sizeof(VI) * L);
    p5fft_plan *plan = p5fft_plan_new((int)Z);
    if (!out->cuts || !w || !buf || !scr || !X || !db || !qrow || !uarow || !seen || !hit || !cf || !cph || !ca || !plan)
        goto done;
    double *const q = qrow + off, *const ua = uarow + off;
    if (!grow(out, &cap, 64)) goto done;
    {   /* get_window("blackmanharris", N, fftbins=True) */
        const double c0 = 0.35875, c1 = 0.48829, c2 = 0.14128, c3 = 0.01168;
        double step = (M_PI - -M_PI) / (double)N;
        for (int64_t i = 0; i < N; i++) {
            double fac = (double)i * step + -M_PI;
            double v = 0.0;
            v += c0 * cos(0.0 * fac);
            v += c1 * cos(1.0 * fac);
            v += c2 * cos(2.0 * fac);
            v += c3 * cos(3.0 * fac);
            w[i] = v;
        }
    }
    const double wsum = pw_sum(w, N), dS = (double)S, dsr = (double)sr, dZ = (double)Z;
    int64_t fmax_bin = (int64_t)(fmax * dZ / dsr);
    int64_t kend = fmax_bin < L - 1 ? fmax_bin : L - 1;      /* candidates k in [2, kend) */
    /* A frame whose every bin is at or under -110 dB has no peak (a peak needs
     * db > thr >= -110). |X_k| <= sum |b_j|, so sum |b_j| * 2 / wsum + 1e-12
     * under 10^(-110/20), with a margin far above the rounding, skips it
     * exactly (silent heads and tails cost no FFT). */
    const double quiet = pow(10.0, abs_db / 20.0) * (1.0 - 1e-6), bscale = 2.0 / wsum * (1.0 + 1e-6);
    /* the floor estimate's constants (see the candidate loop) */
    const double margin = 1e-6;                                  /* dB */
    const double tlo = ldexp(1.0, -200), tup = ldexp(1.0, 200), lg200 = 200.0 * log10(2.0);
    const double Kp = pow(10.0, dS * prom_db / 20.0);
    const double Rhi = pow(10.0, dS * margin / 20.0), Rlo = pow(10.0, -dS * margin / 20.0);
    for (int64_t i = 0; i < F; i++) {
        out->cuts[i] = tot;
        if (i < first) continue;
        int64_t s = i * H - half;
        double sabs = 0.0;
        if (s >= 0 && s + N <= n) {
            const double *xs = x + s;
#ifdef SA_SSE2
            /* sabs only feeds the quiet test, whose margin (1e-6) is far over
             * any summation order's rounding (N * 2^-53): any order skips the
             * same peakless frames, so it is summed four ways at once */
            const __m128d sm = _mm_castsi128_pd(_mm_set1_epi64x(0x7fffffffffffffffLL));
            __m128d s0 = _mm_setzero_pd(), s1v = _mm_setzero_pd();
            for (int64_t j = 0; j < half; j += 4) {      /* half = N/2 >= 2, a power of 2 */
                if (j + 4 > half) {
                    __m128d v = _mm_mul_pd(_mm_loadu_pd(xs + half + j), _mm_loadu_pd(w + half + j));
                    _mm_storeu_pd(buf + j, v);
                    s0 = _mm_add_pd(s0, _mm_and_pd(v, sm));
                    __m128d q = _mm_mul_pd(_mm_loadu_pd(xs + j), _mm_loadu_pd(w + j));
                    _mm_storeu_pd(buf + Z - half + j, q);
                    s1v = _mm_add_pd(s1v, _mm_and_pd(q, sm));
                    break;
                }
                __m128d v0 = _mm_mul_pd(_mm_loadu_pd(xs + half + j), _mm_loadu_pd(w + half + j));
                __m128d v1 = _mm_mul_pd(_mm_loadu_pd(xs + half + j + 2), _mm_loadu_pd(w + half + j + 2));
                __m128d q0 = _mm_mul_pd(_mm_loadu_pd(xs + j), _mm_loadu_pd(w + j));
                __m128d q1 = _mm_mul_pd(_mm_loadu_pd(xs + j + 2), _mm_loadu_pd(w + j + 2));
                _mm_storeu_pd(buf + j, v0);
                _mm_storeu_pd(buf + j + 2, v1);
                _mm_storeu_pd(buf + Z - half + j, q0);
                _mm_storeu_pd(buf + Z - half + j + 2, q1);
                s0 = _mm_add_pd(s0, _mm_add_pd(_mm_and_pd(v0, sm), _mm_and_pd(v1, sm)));
                s1v = _mm_add_pd(s1v, _mm_add_pd(_mm_and_pd(q0, sm), _mm_and_pd(q1, sm)));
            }
            s0 = _mm_add_pd(s0, s1v);
            sabs = _mm_cvtsd_f64(s0) + _mm_cvtsd_f64(_mm_unpackhi_pd(s0, s0));
#else
            for (int64_t j = 0; j < half; j++) {
                double v = xs[half + j] * w[half + j];
                buf[j] = v;
                sabs += fabs(v);
            }
            for (int64_t j = 0; j < half; j++) {
                double v = xs[j] * w[j];
                buf[Z - half + j] = v;
                sabs += fabs(v);
            }
#endif
        } else {
            for (int64_t j = 0; j < half; j++) {
                int64_t t = s + half + j;
                double v = (t >= 0 && t < n ? x[t] : 0.0) * w[half + j];
                buf[j] = v;
                sabs += fabs(v);
            }
            for (int64_t j = 0; j < half; j++) {
                int64_t t = s + j;
                double v = (t >= 0 && t < n ? x[t] : 0.0) * w[j];
                buf[Z - half + j] = v;
                sabs += fabs(v);
            }
        }
        if (sabs * bscale + 1e-12 < quiet) continue;
        p5fft_rfft(plan, buf, X, scr);
        /* q[k] = |X_k|^2 (re*re + im*im, as Python's). db[k] is
         * 20 log10(u_k), u_k = sqrt(q_k) * 2 / wsum + 1e-12; every step is
         * monotone, so Python's db.max is the db of the largest q (and a tie
         * in q is a tie in db). */
        double qmax;
        {
            int64_t k = 0;
#ifdef SA_SSE2
            __m128d vmax = _mm_setzero_pd();
            for (; k + 2 <= L; k += 2) {
                __m128d p0 = _mm_loadu_pd(X + 2 * k), p1 = _mm_loadu_pd(X + 2 * k + 2);
                __m128d re = _mm_unpacklo_pd(p0, p1), im = _mm_unpackhi_pd(p0, p1);
                __m128d v = _mm_add_pd(_mm_mul_pd(re, re), _mm_mul_pd(im, im));
                _mm_storeu_pd(q + k, v);
                vmax = _mm_max_pd(vmax, v);
            }
            vmax = _mm_max_pd(vmax, _mm_unpackhi_pd(vmax, vmax));
            qmax = _mm_cvtsd_f64(vmax);
#else
            qmax = 0.0;
#endif
            for (; k < L; k++) {
                double re = X[2 * k], im = X[2 * k + 1], v = re * re + im * im;
                q[k] = v;
                if (v > qmax) qmax = v;
            }
        }
        for (int64_t j = -s1 - 1; j < 0; j++) q[j] = q[-1 - j];            /* the reflect pads */
        for (int64_t j = L; j <= L + s2; j++) q[j] = q[2 * L - 1 - j];
        const int64_t stamp = i + 1;
#define SA_DB(j) (seen[j] == stamp ? db[j] : (seen[j] = stamp, db[j] = 20.0 * log10(sqrt(q[j]) * 2.0 / wsum + 1e-12)))
        double mx = 20.0 * log10(sqrt(qmax) * 2.0 / wsum + 1e-12);
        double thr = mx + rel_db;
        if (thr < abs_db) thr = abs_db;
        /* Every test on db is first made on q, with log10 only where q cannot
         * settle it. ut = 10^(thr/20) >= 10^-5.5, so a bin over plo has
         * sqrt(q) * 2 / wsum >= 3e-6, a million times the 1e-12 added; log10
         * errs by a few 1e-15 there, and 20 * (.) rounds monotonically. Then
         *   q_k <= plo                         => db_k < thr  (Python's own prefilter)
         *   q_k >= phi                         => db_k > thr  (u_k >= ut (1 + 1e-9))
         *   q_k < q_j (1 - 1e-9), q_k > plo    => db_k < db_j (u ratio < 1 - 4.9e-10)
         *   q_k > q_j (1 + 1e-9), q_k > plo    => db_k > db_j
         *   q_k == q_j                         => db_k == db_j
         * each u gap 4e-9 dB or more, a million times the rounding; between,
         * db itself decides. */
        const double ut = pow(10.0, thr / 20.0);
        double mlo = (ut - 1e-12) * wsum / 2.0, plo = mlo * mlo * (1.0 - 1e-6);
        double mhi = (ut * (1.0 + 1e-9) - 1e-12) * wsum / 2.0, phi = mhi * mhi * (1.0 + 1e-6);
        const double elo = 1.0 - 1e-9, ehi = 1.0 + 1e-9;
        /* bins not ruled out on q: over plo, not equal to the left neighbour,
         * nor surely under either neighbour */
        int64_t nh = 0;
        {
            int64_t k = 2;
#ifdef SA_SSE2
            const __m128d vlo = _mm_set1_pd(plo), ve = _mm_set1_pd(elo);
            for (; k + 2 <= kend; k += 2) {
                __m128d cq = _mm_loadu_pd(q + k), lq = _mm_loadu_pd(q + k - 1), rq = _mm_loadu_pd(q + k + 1);
                __m128d m = _mm_and_pd(_mm_and_pd(_mm_cmpgt_pd(cq, vlo), _mm_cmpneq_pd(cq, lq)),
                                       _mm_and_pd(_mm_cmpge_pd(cq, _mm_mul_pd(lq, ve)), _mm_cmpge_pd(cq, _mm_mul_pd(rq, ve))));
                int bits = _mm_movemask_pd(m);
                hit[nh] = k;
                nh += bits & 1;
                hit[nh] = k + 1;
                nh += bits >> 1;
            }
#endif
            for (; k < kend; k++) {
                double cq = q[k], lq = q[k - 1], rq = q[k + 1];
                if (cq > plo && cq != lq && cq >= lq * elo && cq >= rq * elo) hit[nh++] = k;
            }
        }
        /* uniform_filter1d(db, S), mode reflect: Python's floor at a
         * candidate is a running sum t, reset at a candidate wk >= S past the
         * last one and slid bin by bin from it otherwise. Its value at k is a
         * function of k and of the reset bin r0 alone: reset sum at r0, then
         * t += db_in - db_out for m = r0+1..k. That sum is worked out (db, in
         * that order: the same bits) only for a candidate the estimate below
         * cannot settle.
         * The estimate: db_k > t/S + prom is, up to roundings, ua_k^S / prod
         * (ua over the window) > K = 10^(S prom / 20), with ua = sqrt(q) * c2
         * + 1e-12 (u to 3 ulps; no log10, no divide). The product is kept as
         * Pin / Pout (bins in, bins out), each as P * 2^(200 E). The exact
         * t / S and the estimate agree to 1e-9 dB (sum roundings over <= 2 L
         * slides; the products' roundings are 1e-12 dB), 1000 times under
         * the margin of 1e-6 dB. */
        const double c2 = 2.0 / wsum;
        int64_t wk = -1, r0 = -1;  /* last candidate and the reset bin of its run */
        double Pin = 1.0, Pout = 1.0;
        int64_t Ein = 0, Eout = 0;
        int64_t xr0 = -1, xk = -1; /* exact t is xt at bin xk of the run reset at xr0 */
        double xt = 0.0;
        int64_t c = 0;
#define SA_RENORM(P, E) do { if ((P) < tlo) { (P) *= tup; (E)--; } else if ((P) > tup) { (P) *= tlo; (E)++; } } while (0)
        for (int64_t h = 0; h < nh; h++) {
            int64_t k = hit[h];
            double qk = q[k];
            if (!(qk >= phi) && !(SA_DB(k) > thr)) continue;
            if (!(qk > q[k - 1] * ehi) && !(SA_DB(k) > SA_DB(k - 1))) continue;
            if (!(qk >= q[k + 1] * ehi || qk == q[k + 1]) && !(SA_DB(k) >= SA_DB(k + 1))) continue;
            /* a candidate: python's db > thr, db[k] > db[k-1], db[k] >= db[k+1] */
            if (wk < 0 || k - wk >= S) {
                r0 = k;
                Pin = Pout = 1.0;
                Ein = Eout = 0;
                for (int64_t j = k - s1; j <= k + s2; j++) {      /* pads: no index reflects */
                    double v = sqrt(q[j]) * c2 + 1e-12;
                    ua[j] = v;
                    Pin *= v;
                    SA_RENORM(Pin, Ein);
                }
            } else {
                for (int64_t m = wk + 1; m <= k; m++) {
                    double v = sqrt(q[m + s2]) * c2 + 1e-12;
                    ua[m + s2] = v;
                    Pin *= v;
                    SA_RENORM(Pin, Ein);
                    Pout *= ua[m - 1 - s1];                       /* set when it came in */
                    SA_RENORM(Pout, Eout);
                }
            }
            wk = k;
            int pass;               /* 1 surely, 0 surely not, -1 too close to call */
            if (S <= 256) {
                /* ua_k = mk 2^ek, mk in [1, 2): mk^S <= 2^256 */
                double uk = ua[k], mk, ms = 1.0;
                uint64_t ub;
                memcpy(&ub, &uk, 8);
                int64_t ek = (int64_t)((ub >> 52) & 0x7ff) - 1023;
                ub = (ub & 0x000fffffffffffffULL) | 0x3ff0000000000000ULL;
                memcpy(&mk, &ub, 8);
                for (int64_t z = S; z; z >>= 1) {
                    if (z & 1) ms *= mk;
                    mk *= mk;
                }
                double R = ms * Pout / (Pin * Kp);                /* in 2^[-783, 656] */
                int64_t D = ek * S - 200 * (Ein - Eout);
                if (D > 900) pass = 1;
                else if (D < -900) pass = 0;
                else {
                    uint64_t tb = (uint64_t)(D + 1023) << 52;
                    double t2;
                    memcpy(&t2, &tb, 8);
                    R *= t2;
                    pass = R > Rhi ? 1 : R < Rlo ? 0 : -1;
                }
            } else {
                double est = 20.0 * (log10(Pin) - log10(Pout) + (double)(Ein - Eout) * lg200) / dS + prom_db;
                double bk = SA_DB(k);
                pass = bk > est + margin ? 1 : bk <= est - margin ? 0 : -1;
            }
            if (!pass) continue;
            double b = SA_DB(k);
            if (pass < 0) {
                if (xr0 != r0) {
                    xt = 0.0;
                    for (int64_t j = r0 - s1; j <= r0 + s2; j++) {
                        int64_t r = j < 0 ? -1 - j : j >= L ? 2 * L - 1 - j : j;
                        xt += SA_DB(r);
                    }
                    xr0 = r0;
                    xk = r0;
                }
                for (int64_t m = xk + 1; m <= k; m++) {
                    int64_t jo = m - 1 - s1, ji = m + s2;
                    int64_t ro = jo < 0 ? -1 - jo : jo >= L ? 2 * L - 1 - jo : jo;
                    int64_t ri = ji < 0 ? -1 - ji : ji >= L ? 2 * L - 1 - ji : ji;
                    double vi = SA_DB(ri), vo = SA_DB(ro);
                    xt += vi - vo;
                }
                xk = k;
                if (!(b > xt / dS + prom_db)) continue;
            }
            double a = SA_DB(k - 1), cc = SA_DB(k + 1);
#undef SA_DB
#undef SA_RENORM
            double den = a - 2 * b + cc;
            double p = fabs(den) > 1e-9 ? 0.5 * (a - cc) / den : 0.0;
            int64_t nb = p >= 0 ? k + 1 : k - 1;
            double ak = atan2(X[2 * k + 1], X[2 * k]);
            double dd = atan2(X[2 * nb + 1], X[2 * nb]) - ak;
            dd = atan2(sin(dd), cos(dd));
            cf[c] = ((double)k + p) * dsr / dZ;
            ca[c].v = b - 0.25 * (a - cc) * p;
            ca[c].i = c;
            cph[c] = ak + fabs(p) * dd;
            c++;
        }
        if (!grow(out, &cap, tot + (c < max_peaks ? c : max_peaks))) goto done;
        if (c > max_peaks) {      /* argsort(amp)[-100:], ascending */
            qsort(ca, (size_t)c, sizeof(VI), vi_cmp);
            for (int64_t j = c - max_peaks; j < c; j++) {
                out->f[tot] = cf[ca[j].i];
                out->a[tot] = ca[j].v;
                out->ph[tot] = cph[ca[j].i];
                tot++;
            }
        } else {
            for (int64_t j = 0; j < c; j++) {
                out->f[tot] = cf[j];
                out->a[tot] = ca[j].v;
                out->ph[tot] = cph[j];
                tot++;
            }
        }
    }
    out->cuts[F] = tot;
    rc = 0;
done:
    free(w); free(buf); free(scr); free(X); free(db); free(qrow); free(uarow); free(seen); free(hit); free(cf); free(cph);
    free(ca);
    p5fft_plan_free(plan);
    if (rc) p5_sa_peaks_free(out);
    return rc;
}

P5_API int p5_sa_find_peaks_frames(const double *x, int64_t n, int64_t sr, int64_t N, int64_t H, double fmax,
                                   P5SAPeaks *out) {
    if (N < 4 || (N & (N - 1)) || H <= 0 || n < 0) return -2;
    return peaks_frames(x, n, sr, N, H, fmax, 0, out);
}

P5_API void p5_sa_peaks_free(P5SAPeaks *p) {
    if (!p) return;
    free(p->cuts);
    free(p->f);
    free(p->a);
    free(p->ph);
    memset(p, 0, sizeof(*p));
}

/* ------------------------------------------------------------ tracks */

typedef struct {
    int64_t end, t;
} EndT;

static int endt_cmp(const void *pa, const void *pb) {
    const EndT *a = (const EndT *)pa, *b = (const EndT *)pb;
    if (a->end != b->end) return (a->end > b->end) - (a->end < b->end);
    return (a->t > b->t) - (a->t < b->t);
}

/* pc.track_peaks(frames, first_frame=first) with tol_oct 0.025, min_len 5 */
static int track_peaks(const P5SAPeaks *pk, int64_t first, P5Tracks *out) {
    const int64_t min_len = 5;
    int64_t F = pk->F, tot = pk->cuts[F];
    int64_t sz = tot > 1 ? tot : 1;
    int rc = -1;
    int64_t *ids = (int64_t *)malloc(sizeof(int64_t) * sz), *src = (int64_t *)malloc(sizeof(int64_t) * sz);
    int64_t *start = (int64_t *)malloc(sizeof(int64_t) * sz), *count = NULL, *pos = NULL;
    double *fo = NULL, *ao = NULL, *po = NULL;
    EndT *ord = NULL;
    out->ntracks = 0;
    out->tracks = NULL;
    if (!ids || !src || !start) goto done;
    int64_t born = F ? track_assign(pk->f, pk->cuts, F, first, 0.025, ids, src, start) : 0;
    if (born < 0) goto done;
    if (born == 0) {
        rc = 0;
        goto done;
    }
    int64_t f0 = first < 0 ? 0 : (first < F ? first : F);
    int64_t m = tot - pk->cuts[f0];
    count = (int64_t *)calloc(born, sizeof(int64_t));
    pos = (int64_t *)malloc(sizeof(int64_t) * born);
    ord = (EndT *)malloc(sizeof(EndT) * born);
    fo = (double *)malloc(sizeof(double) * (m ? m : 1));
    ao = (double *)malloc(sizeof(double) * (m ? m : 1));
    po = (double *)malloc(sizeof(double) * (m ? m : 1));
    if (!count || !pos || !ord || !fo || !ao || !po) goto done;
    for (int64_t o = 0; o < m; o++) count[ids[o]]++;
    int64_t acc = 0, nk = 0;
    for (int64_t t = 0; t < born; t++) {
        pos[t] = acc;
        acc += count[t];
        if (count[t] >= min_len) {
            ord[nk].end = start[t] + count[t];
            ord[nk].t = t;
            nk++;
        }
    }
    for (int64_t o = 0; o < m; o++) {     /* stable argsort by track */
        int64_t q = pos[ids[o]]++, s = src[o];
        fo[q] = pk->f[s];
        ao[q] = pk->a[s];
        po[q] = pk->ph[s];
    }
    qsort(ord, (size_t)nk, sizeof(EndT), endt_cmp);
    out->tracks = (P5Track *)calloc(nk ? nk : 1, sizeof(P5Track));
    if (!out->tracks) goto done;
    for (int64_t j = 0; j < nk; j++) {
        int64_t t = ord[j].t, c = count[t], q = pos[t] - c;
        P5Track *tr = &out->tracks[j];
        tr->start = start[t];
        tr->len = c;
        tr->f = (double *)malloc(sizeof(double) * c);
        tr->a = (double *)malloc(sizeof(double) * c);
        tr->ph = (double *)malloc(sizeof(double) * c);
        out->ntracks = j + 1;
        if (!tr->f || !tr->a || !tr->ph) goto done;
        memcpy(tr->f, fo + q, sizeof(double) * c);
        memcpy(tr->a, ao + q, sizeof(double) * c);
        memcpy(tr->ph, po + q, sizeof(double) * c);
    }
    rc = 0;
done:
    free(ids); free(src); free(start); free(count); free(pos); free(ord); free(fo); free(ao); free(po);
    if (rc) p5_tracks_free(out);
    return rc;
}

/* analysis._analyse */
static int analyse_on(const double *x, int64_t n, int64_t sr, double f0, int64_t N, int64_t on, P5Tracks *out) {
    int64_t hop = N <= 4096 ? SA_H : N / 8;
    int64_t first = (on + N / 4 + hop - 1) / hop;       /* ceil((on + N // 4) / hop) */
    P5SAPeaks pk;
    out->n = n;
    out->H = hop;
    out->f0 = f0;
    out->ntracks = 0;
    out->tracks = NULL;
    if (peaks_frames(x, n, sr, N, hop, (double)sr / 2, first, &pk)) return -1;
    int rc = track_peaks(&pk, first, out);
    p5_sa_peaks_free(&pk);
    return rc;
}

P5_API int p5_sa_analyse(const double *x, int64_t n, int64_t sr, double f0, int64_t N, P5Tracks *out) {
    if (N < 4 || (N & (N - 1)) || n < 0 || sr <= 0) return -2;
    int64_t on = onset(x, n);
    if (on < 0) return -1;
    return analyse_on(x, n, sr, f0, N, on, out);
}

P5_API int p5_sine_analyse(const double *x, int64_t n, int64_t sr, double f0_hint, P5Tracks *out) {
    int any = 0;
    memset(out, 0, sizeof(*out));
    out->n = n;
    out->H = SA_H;
    if (n < 0 || sr <= 0) return -2;
    for (int64_t i = 0; i < n && !any; i++) any = x[i] != 0.0;
    if (!any) return 0;
    int64_t on = onset(x, n);
    if (on < 0) return -1;
    double f0 = 0.0;
    int r = find_pitch_on(x, n, sr, on, &f0);
    if (r < 0) return -1;
    if (!r || f0 == 0.0) f0 = f0_hint > 0 ? f0_hint : 0.0;    /* find_pitch(x) or f0 */
    return analyse_on(x, n, sr, f0, p5_sa_window_for(f0, sr), on, out);
}

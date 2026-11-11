/* The judge's distance sums (metrics.py) in one pass over each block of
   spectra: power, logarithm, compare, add. The logarithm is the fdlibm one,
   four at a time; results differ from numpy in the last bits only, and are
   the same bits with and without AVX2. */
#include <immintrin.h>
#include <intrin.h>
#include <math.h>
#include <stdint.h>

#define EXPORT __declspec(dllexport)

static int has_avx2(void) {
    int r[4];
    __cpuid(r, 1);
    if (!((r[2] & (1 << 27)) && (r[2] & (1 << 28)) && (_xgetbv(0) & 6) == 6)) return 0;
    __cpuidex(r, 7, 0);
    return (r[1] & (1 << 5)) != 0;
}

EXPORT int metric_no_avx = 0;   /* set to 1 to check the plain C path */

#define LG1 6.666666666666735130e-01
#define LG2 3.999999999940941908e-01
#define LG3 2.857142874366239149e-01
#define LG4 2.222219843214978396e-01
#define LG5 1.818357216161805012e-01
#define LG6 1.531383769920937332e-01
#define LG7 1.479819860511658591e-01
#define LN2HI 6.93147180369123816490e-01
#define LN2LO 1.90821492927058770002e-10

/* x[i] = mul * ln((root ? sqrt(x[i]) : x[i]) + add), for positive normal values. */
static void vln_c(double* x, int64_t n, int root, double add, double mul) {
    for (int64_t i = 0; i < n; i++) {
        double v = (root ? sqrt(x[i]) : x[i]) + add;
        union { double d; uint64_t u; } q;
        q.d = v;
        uint64_t t = q.u + 0x00095F6200000000ULL;
        double k = (double)((int32_t)(t >> 52) - 1023);
        q.u = (t & 0x000FFFFFFFFFFFFFULL) + 0x3FE6A09E00000000ULL;
        double f = q.d - 1.0;
        double s = f / (2.0 + f), z = s * s, w = z * z;
        double t1 = w * (LG2 + w * (LG4 + w * LG6));
        double t2 = z * (LG1 + w * (LG3 + w * (LG5 + w * LG7)));
        double R = t2 + t1, h = 0.5 * f * f;
        x[i] = mul * (k * LN2HI - ((h - (s * (h + R) + k * LN2LO)) - f));
    }
}

static void vln_avx(double* x, int64_t n, int root, double add, double mul) {
    const __m256d vadd = _mm256_set1_pd(add), vmul = _mm256_set1_pd(mul), one = _mm256_set1_pd(1.0);
    const __m256d two = _mm256_set1_pd(2.0), half = _mm256_set1_pd(0.5);
    const __m256i bias = _mm256_set1_epi64x(0x00095F6200000000LL), mant = _mm256_set1_epi64x(0x000FFFFFFFFFFFFFLL);
    const __m256i base = _mm256_set1_epi64x(0x3FE6A09E00000000LL), pick = _mm256_setr_epi32(0, 2, 4, 6, 0, 0, 0, 0);
    const __m128i e1023 = _mm_set1_epi32(1023);
    const __m256d l1 = _mm256_set1_pd(LG1), l2 = _mm256_set1_pd(LG2), l3 = _mm256_set1_pd(LG3), l4 = _mm256_set1_pd(LG4);
    const __m256d l5 = _mm256_set1_pd(LG5), l6 = _mm256_set1_pd(LG6), l7 = _mm256_set1_pd(LG7);
    const __m256d hi = _mm256_set1_pd(LN2HI), lo = _mm256_set1_pd(LN2LO);
    int64_t i = 0;
    for (; i + 4 <= n; i += 4) {
        __m256d v = _mm256_loadu_pd(x + i);
        if (root) v = _mm256_sqrt_pd(v);
        v = _mm256_add_pd(v, vadd);
        __m256i t = _mm256_add_epi64(_mm256_castpd_si256(v), bias);
        __m128i e = _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(_mm256_srli_epi64(t, 52), pick));
        __m256d k = _mm256_cvtepi32_pd(_mm_sub_epi32(e, e1023));
        __m256d f = _mm256_sub_pd(_mm256_castsi256_pd(_mm256_add_epi64(_mm256_and_si256(t, mant), base)), one);
        __m256d s = _mm256_div_pd(f, _mm256_add_pd(two, f));
        __m256d z = _mm256_mul_pd(s, s), w = _mm256_mul_pd(z, z);
        __m256d t1 = _mm256_mul_pd(w, _mm256_add_pd(l2, _mm256_mul_pd(w, _mm256_add_pd(l4, _mm256_mul_pd(w, l6)))));
        __m256d t2 = _mm256_mul_pd(z, _mm256_add_pd(l1, _mm256_mul_pd(w, _mm256_add_pd(l3, _mm256_mul_pd(w,
                     _mm256_add_pd(l5, _mm256_mul_pd(w, l7)))))));
        __m256d R = _mm256_add_pd(t2, t1), h = _mm256_mul_pd(_mm256_mul_pd(half, f), f);
        __m256d in = _mm256_add_pd(_mm256_mul_pd(s, _mm256_add_pd(h, R)), _mm256_mul_pd(k, lo));
        __m256d r = _mm256_sub_pd(_mm256_mul_pd(k, hi), _mm256_sub_pd(_mm256_sub_pd(h, in), f));
        _mm256_storeu_pd(x + i, _mm256_mul_pd(vmul, r));
    }
    _mm256_zeroupper();
    vln_c(x + i, n - i, root, add, mul);
}

static void vln(double* x, int64_t n, int root, double add, double mul) {
    static int avx = -1;
    if (avx < 0) avx = has_avx2();
    if (avx && !metric_no_avx) vln_avx(x, n, root, add, mul);
    else vln_c(x, n, root, add, mul);
}

EXPORT void metric_ln(double* x, int64_t n, int root, double add, double mul) { vln(x, n, root, add, mul); }

#define DB10 4.342944819032518      /* 10 / ln 10 */
#define CH 1024

/* Z: count complex values. Sum over the kept ones (m) of
   |Rm[j] - max(20 log10(scale |Z| + 1e-9), lo)|; Rm has one value per kept one. */
EXPORT double mr_absdiff(const double* Z, int64_t count, double scale, const uint8_t* m, const double* Rm, double lo) {
    double p[CH], total = 0.0, s2 = scale * scale;
    for (int64_t a = 0; a < count; a += CH) {
        int64_t n = count - a < CH ? count - a : CH;
        const double* z = Z + 2 * a;
        for (int64_t i = 0; i < n; i++) p[i] = (z[2 * i] * z[2 * i] + z[2 * i + 1] * z[2 * i + 1]) * s2;
        vln(p, n, 1, 1e-9, 2.0 * DB10);
        for (int64_t i = 0; i < n; i++)
            if (m[a + i]) {
                double v = p[i] > lo ? p[i] : lo;
                total += fabs(*Rm++ - v);
            }
    }
    return total;
}

/* out[i] = 20 log10(scale |Z[i]| + 1e-9). */
EXPORT void mr_logmag(const double* Z, int64_t count, double scale, double* out) {
    double s2 = scale * scale;
    for (int64_t i = 0; i < count; i++) out[i] = (Z[2 * i] * Z[2 * i] + Z[2 * i + 1] * Z[2 * i + 1]) * s2;
    for (int64_t a = 0; a < count; a += CH) vln(out + a, count - a < CH ? count - a : CH, 1, 1e-9, 2.0 * DB10);
}

/* Z: rows x bins complex. Filter f covers bins [fs[f], fs[f] + fl[f]) with
   weights fw[fo[f] ..]. out (rows x nmel, may be null) gets
   10 log10(scale^2 |Z|^2 . filter + 1e-18); returns the sum over kept cells
   (m) of |r - that| when r is given. */
EXPORT double mel_rows(const double* Z, int64_t rows, int64_t bins, double scale, int nmel, const int32_t* fs,
                       const int32_t* fl, const int32_t* fo, const double* fw, double* out, const double* r,
                       const uint8_t* m) {
    double p[4100], v[256], total = 0.0, s2 = scale * scale;
    if (bins > 4100 || nmel > 256) return -1.0;
    for (int64_t j = 0; j < rows; j++) {
        const double* z = Z + 2 * bins * j;
        for (int64_t i = 0; i < bins; i++) p[i] = (z[2 * i] * z[2 * i] + z[2 * i + 1] * z[2 * i + 1]) * s2;
        for (int f = 0; f < nmel; f++) {
            const double* q = p + fs[f];
            const double* w = fw + fo[f];
            double a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0;
            int i = 0, l = fl[f];
            for (; i + 4 <= l; i += 4) {
                a0 += q[i] * w[i]; a1 += q[i + 1] * w[i + 1]; a2 += q[i + 2] * w[i + 2]; a3 += q[i + 3] * w[i + 3];
            }
            for (; i < l; i++) a0 += q[i] * w[i];
            v[f] = (a0 + a1) + (a2 + a3);
        }
        vln(v, nmel, 0, 1e-18, DB10);
        if (out) for (int f = 0; f < nmel; f++) out[nmel * j + f] = v[f];
        if (r) for (int f = 0; f < nmel; f++)
            if (m[nmel * j + f]) total += fabs(r[nmel * j + f] - v[f]);
    }
    return total;
}

#define EP1 1.66666666666666019037e-01
#define EP2 -2.77777777770155933842e-03
#define EP3 6.61375632143793436117e-05
#define EP4 -1.65339022054652515390e-06
#define EP5 4.13813679705723846039e-08
#define INVLN2 1.44269504088896338700e+00

/* x[i] = exp(x[i]) for x in [-700, 0]: fdlibm's, four at a time, same bits either way. */
static void vexp_c(double* x, int64_t n) {
    for (int64_t i = 0; i < n; i++) {
        double k = floor(x[i] * INVLN2 + 0.5);
        double hi = x[i] - k * LN2HI, lo = k * LN2LO, r = hi - lo, t = r * r;
        double c = r - t * (EP1 + t * (EP2 + t * (EP3 + t * (EP4 + t * EP5))));
        double y = 1.0 - ((lo - (r * c) / (2.0 - c)) - hi);
        union { double d; uint64_t u; } q;
        q.u = (uint64_t)((int64_t)k + 1023) << 52;
        x[i] = y * q.d;
    }
}

static void vexp_avx(double* x, int64_t n) {
    const __m256d inv = _mm256_set1_pd(INVLN2), half = _mm256_set1_pd(0.5), hi2 = _mm256_set1_pd(LN2HI), lo2 = _mm256_set1_pd(LN2LO);
    const __m256d p1 = _mm256_set1_pd(EP1), p2 = _mm256_set1_pd(EP2), p3 = _mm256_set1_pd(EP3), p4 = _mm256_set1_pd(EP4);
    const __m256d p5 = _mm256_set1_pd(EP5), one = _mm256_set1_pd(1.0), two = _mm256_set1_pd(2.0);
    const __m128i e1023 = _mm_set1_epi32(1023);
    int64_t i = 0;
    for (; i + 4 <= n; i += 4) {
        __m256d v = _mm256_loadu_pd(x + i);
        __m256d k = _mm256_floor_pd(_mm256_add_pd(_mm256_mul_pd(v, inv), half));
        __m256d hi = _mm256_sub_pd(v, _mm256_mul_pd(k, hi2)), lo = _mm256_mul_pd(k, lo2);
        __m256d r = _mm256_sub_pd(hi, lo), t = _mm256_mul_pd(r, r);
        __m256d c = _mm256_sub_pd(r, _mm256_mul_pd(t, _mm256_add_pd(p1, _mm256_mul_pd(t, _mm256_add_pd(p2, _mm256_mul_pd(t,
                    _mm256_add_pd(p3, _mm256_mul_pd(t, _mm256_add_pd(p4, _mm256_mul_pd(t, p5))))))))));
        __m256d y = _mm256_sub_pd(one, _mm256_sub_pd(_mm256_sub_pd(lo, _mm256_div_pd(_mm256_mul_pd(r, c), _mm256_sub_pd(two, c))), hi));
        __m256i e = _mm256_slli_epi64(_mm256_cvtepi32_epi64(_mm_add_epi32(_mm256_cvtpd_epi32(k), e1023)), 52);
        _mm256_storeu_pd(x + i, _mm256_mul_pd(y, _mm256_castsi256_pd(e)));
    }
    _mm256_zeroupper();
    vexp_c(x + i, n - i);
}

EXPORT void metric_exp(double* x, int64_t n) {
    if (!metric_no_avx && has_avx2()) vexp_avx(x, n);
    else vexp_c(x, n);
}

/* The amp's compressor (amp.comp) on n stereo frames: level of the louder
   side in dB, the part over thr followed up fast (ga) and down slow (gr),
   gain 10^(-that * slope / 20) on both sides. */
EXPORT void comp_stereo(const double* x, double* out, int64_t n, double thr, double ga, double gr, double slope) {
    double p[CH], e = 0.0, k = -slope / 20.0 * 2.302585092994046;
    for (int64_t a = 0; a < n; a += CH) {
        int64_t m = n - a < CH ? n - a : CH;
        const double* z = x + 2 * a;
        for (int64_t i = 0; i < m; i++) {
            double l = fabs(z[2 * i]), r = fabs(z[2 * i + 1]);
            p[i] = l > r ? l : r;
        }
        vln(p, m, 0, 1e-12, 2.0 * DB10);
        for (int64_t i = 0; i < m; i++) {
            double v = p[i] - thr;
            if (!(v > 0.0)) v = 0.0;
            e = v > e ? ga * e + (1 - ga) * v : gr * e + (1 - gr) * v;
            p[i] = e * k;
        }
        metric_exp(p, m);
        for (int64_t i = 0; i < m; i++) {
            out[2 * (a + i)] = z[2 * i] * p[i];
            out[2 * (a + i) + 1] = z[2 * i + 1] * p[i];
        }
    }
}

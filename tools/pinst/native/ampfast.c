/* The two per-sample loops of amp.py, in C: the same operations in the same
   order, so the numbers are the ones numpy gives. Built by build.bat into
   pinst_fast.dll; amp.py falls back to numpy when the DLL is not there. */
#include <immintrin.h>
#include <intrin.h>
#include <stdint.h>

#define EXPORT __declspec(dllexport)

EXPORT void comp_env(const double* over, double* env, int64_t n, double ga, double gr) {
    double e = 0.0;
    for (int64_t i = 0; i < n; i++) {
        double v = over[i];
        e = v > e ? ga * e + (1 - ga) * v : gr * e + (1 - gr) * v;
        env[i] = e;
    }
}

/* st: per stage [last_x, last_state, z1, z2], carried between calls.
   A stage is about sixty instructions a sample and the processor is busy the
   whole time, so the gain is in doing three stages with one set of
   instructions: stages3_avx keeps stage 1, 2 and 3 in three lanes of one AVX
   register. Stage 2 works LAG samples behind stage 1 and stage 3 LAG behind
   stage 2, so no lane waits for another lane. Every lane does the operations
   of the plain loop in the same order: same numbers. */
#define BLOCK 2048
#define LAG 4

#define STAGE(v, last, state, z1, z2, y) { \
    if (v > last && v > 0.25) state = 0.0; \
    else if (v < last && v < -0.25) state = 1.0; \
    last = v; \
    double rec1 = z1 + (1 - c4) * state; \
    z1 = state * 0.0 - rec1 * (-c4); \
    double t2 = 12.75 * (s0 * v + 10.0); \
    if (!(t2 > 0.0)) t2 = 0.0; \
    int64_t i3 = (int64_t)t2; \
    double t4 = table[i3 < 255 ? i3 : 255]; \
    double t5 = t4 + (t2 - (double)i3) * (table[i3 + 1 < 255 ? i3 + 1 : 255] - t4); \
    double t6 = rec1 * (t5 - s1 - 1.0) + (1 - rec1) * (t5 - s1); \
    y = z2 + b0 * t6; \
    z2 = t6 * b1 - y * a1; }

static void stage1(const double* in, double* o, int64_t m, double s0, double s1, double c4,
                   double b0, double b1, double a1, const double* table, double* q) {
    double last = q[0], state = q[1], z1 = q[2], z2 = q[3];
    for (int64_t i = 0; i < m; i++) {
        double v = in[i], y;
        STAGE(v, last, state, z1, z2, y)
        o[i] = y;
    }
    q[0] = last; q[1] = state; q[2] = z1; q[3] = z2;
}

/* Three stages, n >= 2 * LAG, in place allowed. tt: 256 pairs (table[i],
   table[min(i + 1, 255)] - table[i]). The position in the table is capped at
   255, where the step between entries is already zero in the plain loop. */
static void stages3_avx(const double* x, double* out, int64_t n, double s0, double s1, double c4,
                        double b0, double b1, double a1, const double* table, const double* tt, double* st) {
    double pa[2 * LAG], pb[2 * LAG];
    __declspec(align(32)) double ring[LAG][4];
    stage1(x, pa, 2 * LAG, s0, s1, c4, b0, b1, a1, table, st);
    stage1(pa, pb, LAG, s0, s1, c4, b0, b1, a1, table, st + 4);
    for (int j = 0; j < LAG; j++) {
        ring[j][0] = pa[LAG + j]; ring[j][1] = pb[j]; ring[j][2] = 0.0; ring[j][3] = 0.0;
    }
    __m256d last = _mm256_set_pd(0.0, st[8], st[4], st[0]), state = _mm256_set_pd(0.0, st[9], st[5], st[1]);
    __m256d z1 = _mm256_set_pd(0.0, st[10], st[6], st[2]), z2 = _mm256_set_pd(0.0, st[11], st[7], st[3]);
    const __m256d one = _mm256_set1_pd(1.0), zero = _mm256_setzero_pd();
    const __m256d q25 = _mm256_set1_pd(0.25), mq25 = _mm256_set1_pd(-0.25);
    const __m256d k1 = _mm256_set1_pd(1 - c4), mc4 = _mm256_set1_pd(-c4);
    const __m256d vs0 = _mm256_set1_pd(s0), vs1 = _mm256_set1_pd(s1), ten = _mm256_set1_pd(10.0);
    const __m256d c1275 = _mm256_set1_pd(12.75), c255 = _mm256_set1_pd(255.0);
    const __m256d vb0 = _mm256_set1_pd(b0), vb1 = _mm256_set1_pd(b1), va1 = _mm256_set1_pd(a1);
    for (int64_t t = 2 * LAG; t < n; t++) {
        __m256d prev = _mm256_load_pd(ring[t & (LAG - 1)]);
        __m256d v = _mm256_blend_pd(_mm256_permute4x64_pd(prev, 0xD0), _mm256_set_pd(0.0, 0.0, 0.0, x[t]), 9);
        __m256d up = _mm256_and_pd(_mm256_cmp_pd(v, last, _CMP_GT_OQ), _mm256_cmp_pd(v, q25, _CMP_GT_OQ));
        __m256d dn = _mm256_and_pd(_mm256_cmp_pd(v, last, _CMP_LT_OQ), _mm256_cmp_pd(v, mq25, _CMP_LT_OQ));
        state = _mm256_andnot_pd(up, _mm256_blendv_pd(state, one, dn));
        last = v;
        __m256d rec1 = _mm256_add_pd(z1, _mm256_mul_pd(k1, state));
        z1 = _mm256_sub_pd(_mm256_mul_pd(state, zero), _mm256_mul_pd(rec1, mc4));
        __m256d t2 = _mm256_mul_pd(c1275, _mm256_add_pd(_mm256_mul_pd(vs0, v), ten));
        t2 = _mm256_min_pd(_mm256_max_pd(t2, zero), c255);
        __m128i idx = _mm256_cvttpd_epi32(t2);
        __m128d e0 = _mm_load_pd(tt + 2 * _mm_cvtsi128_si32(idx));
        __m128d e1 = _mm_load_pd(tt + 2 * _mm_extract_epi32(idx, 1));
        __m128d e2 = _mm_load_pd(tt + 2 * _mm_extract_epi32(idx, 2));
        __m256d t4 = _mm256_set_m128d(_mm_unpacklo_pd(e2, e2), _mm_unpacklo_pd(e0, e1));
        __m256d dt = _mm256_set_m128d(_mm_unpackhi_pd(e2, e2), _mm_unpackhi_pd(e0, e1));
        __m256d t5 = _mm256_add_pd(t4, _mm256_mul_pd(_mm256_sub_pd(t2, _mm256_cvtepi32_pd(idx)), dt));
        __m256d w = _mm256_sub_pd(t5, vs1);
        __m256d t6 = _mm256_add_pd(_mm256_mul_pd(rec1, _mm256_sub_pd(w, one)),
                                   _mm256_mul_pd(_mm256_sub_pd(one, rec1), w));
        __m256d y = _mm256_add_pd(z2, _mm256_mul_pd(vb0, t6));
        z2 = _mm256_sub_pd(_mm256_mul_pd(t6, vb1), _mm256_mul_pd(y, va1));
        _mm256_store_pd(ring[t & (LAG - 1)], y);
        _mm_store_sd(out + t - 2 * LAG, _mm256_extractf128_pd(y, 1));
    }
    double r[4][4];
    _mm256_storeu_pd(r[0], last); _mm256_storeu_pd(r[1], state);
    _mm256_storeu_pd(r[2], z1); _mm256_storeu_pd(r[3], z2);
    for (int s = 0; s < 3; s++)
        for (int k = 0; k < 4; k++) st[4 * s + k] = r[k][s];
    _mm256_zeroupper();
    for (int j = 0; j < LAG; j++) {         /* ring[(n + j) % LAG] is step n - LAG + j */
        const double* e = ring[(n + j) & (LAG - 1)];
        pa[j] = e[0]; pb[j] = e[1];
    }
    stage1(pa, pb + LAG, LAG, s0, s1, c4, b0, b1, a1, table, st + 4);
    stage1(pb, out + n - 2 * LAG, 2 * LAG, s0, s1, c4, b0, b1, a1, table, st + 8);
}

static int has_avx2(void);
EXPORT int force_no_avx = 0;    /* set to 1 to check the plain C path */

static void run_stages(const double* x, double* out, int64_t n, int stages, double s0, double s1, double c4,
                       double b0, double b1, double a1, const double* table, const double* tt, double* st) {
    if (stages == 3 && n >= 2 * LAG && tt) {
        stages3_avx(x, out, n, s0, s1, c4, b0, b1, a1, table, tt, st);
        return;
    }
    for (int64_t a = 0; a < n; a += BLOCK) {
        int64_t m = n - a < BLOCK ? n - a : BLOCK;
        const double* in = x + a;
        for (int s = 0; s < stages; s++) {
            stage1(in, out + a, m, s0, s1, c4, b0, b1, a1, table, st + 4 * s);
            in = out + a;
        }
    }
}

static void pair_table(const double* table, double* tt) {
    for (int i = 0; i < 256; i++) {
        tt[2 * i] = table[i];
        tt[2 * i + 1] = table[i + 1 < 255 ? i + 1 : 255] - table[i];
    }
}

EXPORT void disto_stages(const double* x, double* out, int64_t n, int stages, double s0, double s1, double c4,
                         double b0, double b1, double a1, const double* table, double* st) {
    __declspec(align(16)) double tt[512];
    int fast = stages == 3 && !force_no_avx && has_avx2();
    if (fast) pair_table(table, tt);
    run_stages(x, out, n, stages, s0, s1, c4, b0, b1, a1, table, fast ? tt : 0, st);
}

/* The whole oversampled distortion in one pass: 8x up, the stages, 8x down,
   a block at a time, so the oversampled signal never leaves the cache.
   hup: 8 phases of 21 taps laid against x[i-10 .. i+10]; hdn: 161 taps laid
   against u[8j-80 .. 8j+80]. The up filter makes its 8 outputs per input
   side by side; the down filter sums in 16 chains. Both therefore differ
   from scipy's resample_poly in the last bits, and give the same bits with
   and without AVX. */
#define OS 8
#define HALF 80
#define UPT 21
#define DNT 161
#define XB 512

static int has_avx(void) {
    int r[4];
    __cpuid(r, 1);
    return (r[2] & (1 << 27)) && (r[2] & (1 << 28)) && (_xgetbv(0) & 6) == 6;
}

static int has_avx2(void) {
    int r[4];
    if (!has_avx()) return 0;
    __cpuidex(r, 7, 0);
    return (r[1] & (1 << 5)) != 0;
}

/* ht: the up filter as 21 rows of 8 phases. o gets 8 outputs per input. */
static void up_avx(const double* xw, const double* ht, double* o, int m) {
    int i = 0;
    for (; i + 2 <= m; i += 2) {
        __m256d a0 = _mm256_setzero_pd(), a1 = a0, b0 = a0, b1 = a0;
        for (int t = 0; t < UPT; t++) {
            __m256d h0 = _mm256_loadu_pd(ht + 8 * t), h1 = _mm256_loadu_pd(ht + 8 * t + 4);
            __m256d xa = _mm256_broadcast_sd(xw + i + t), xb = _mm256_broadcast_sd(xw + i + 1 + t);
            a0 = _mm256_add_pd(a0, _mm256_mul_pd(xa, h0));
            a1 = _mm256_add_pd(a1, _mm256_mul_pd(xa, h1));
            b0 = _mm256_add_pd(b0, _mm256_mul_pd(xb, h0));
            b1 = _mm256_add_pd(b1, _mm256_mul_pd(xb, h1));
        }
        _mm256_storeu_pd(o + 8 * i, a0); _mm256_storeu_pd(o + 8 * i + 4, a1);
        _mm256_storeu_pd(o + 8 * i + 8, b0); _mm256_storeu_pd(o + 8 * i + 12, b1);
    }
    for (; i < m; i++) {
        __m256d a0 = _mm256_setzero_pd(), a1 = a0;
        for (int t = 0; t < UPT; t++) {
            __m256d xa = _mm256_broadcast_sd(xw + i + t);
            a0 = _mm256_add_pd(a0, _mm256_mul_pd(xa, _mm256_loadu_pd(ht + 8 * t)));
            a1 = _mm256_add_pd(a1, _mm256_mul_pd(xa, _mm256_loadu_pd(ht + 8 * t + 4)));
        }
        _mm256_storeu_pd(o + 8 * i, a0); _mm256_storeu_pd(o + 8 * i + 4, a1);
    }
    _mm256_zeroupper();
}

static void up_c(const double* xw, const double* ht, double* o, int m) {
    for (int i = 0; i < m; i++) {
        double a[OS] = {0};
        for (int t = 0; t < UPT; t++)
            for (int p = 0; p < OS; p++) a[p] += xw[i + t] * ht[8 * t + p];
        for (int p = 0; p < OS; p++) o[OS * i + p] = a[p];
    }
}

static void down_avx(const double* u, const double* h, double* y, int m) {
    for (int j = 0; j < m; j++) {
        const double* a = u + OS * j;
        __m256d s0 = _mm256_setzero_pd(), s1 = s0, s2 = s0, s3 = s0;
        for (int k = 0; k < 160; k += 16) {
            s0 = _mm256_add_pd(s0, _mm256_mul_pd(_mm256_loadu_pd(a + k), _mm256_loadu_pd(h + k)));
            s1 = _mm256_add_pd(s1, _mm256_mul_pd(_mm256_loadu_pd(a + k + 4), _mm256_loadu_pd(h + k + 4)));
            s2 = _mm256_add_pd(s2, _mm256_mul_pd(_mm256_loadu_pd(a + k + 8), _mm256_loadu_pd(h + k + 8)));
            s3 = _mm256_add_pd(s3, _mm256_mul_pd(_mm256_loadu_pd(a + k + 12), _mm256_loadu_pd(h + k + 12)));
        }
        double v[4];
        _mm256_storeu_pd(v, _mm256_add_pd(_mm256_add_pd(s0, s1), _mm256_add_pd(s2, s3)));
        y[j] = ((v[0] + v[1]) + (v[2] + v[3])) + a[160] * h[160];
    }
    _mm256_zeroupper();
}

static void down_c(const double* u, const double* h, double* y, int m) {
    for (int j = 0; j < m; j++) {
        const double* a = u + OS * j;
        double s[16] = {0}, v[4];
        for (int k = 0; k < 160; k += 16)
            for (int c = 0; c < 16; c++) s[c] += a[k + c] * h[k + c];
        for (int l = 0; l < 4; l++) v[l] = (s[l] + s[4 + l]) + (s[8 + l] + s[12 + l]);
        y[j] = ((v[0] + v[1]) + (v[2] + v[3])) + a[160] * h[160];
    }
}

EXPORT void disto_os(const double* x, double* y, int64_t n, const double* hup, const double* hdn, int stages,
                     double s0, double s1, double c4, double b0, double b1, double a1, const double* table) {
    int avx = !force_no_avx && has_avx();
    double st[4 * 16] = {0};
    __declspec(align(16)) double tt[512];
    int fast = stages == 3 && !force_no_avx && has_avx2();
    if (fast) pair_table(table, tt);
    double ht[UPT * OS];
    for (int t = 0; t < UPT; t++)
        for (int p = 0; p < OS; p++) ht[OS * t + p] = hup[UPT * p + t];
    double xw[XB + 64];              /* a padded copy of the input block */
    double u[2 * HALF + OS * (XB + 16)];     /* u[g0 ..), g0 = OS * j0 - HALF */
    int64_t gen = 0;                         /* input samples already oversampled */
    for (int i = 0; i < HALF; i++) u[i] = 0.0;
    int have = HALF;                         /* filled length of u, starts at index -HALF */
    for (int64_t j0 = 0; j0 < n; j0 += XB) {
        int64_t j1 = j0 + XB < n ? j0 + XB : n;
        int64_t want = j1 + 11 < n ? j1 + 11 : n;       /* input samples to have oversampled */
        int m = (int)(want - gen);
        if (m > 0) {
            for (int i = -10; i < m + 10; i++) {
                int64_t k = gen + i;
                xw[i + 10] = k >= 0 && k < n ? x[k] : 0.0;
            }
            double* o = u + have;
            if (avx) up_avx(xw, ht, o, m);
            else up_c(xw, ht, o, m);
            run_stages(o, o, (int64_t)OS * m, stages, s0, s1, c4, b0, b1, a1, table, fast ? tt : 0, st);
            have += OS * m;
            gen = want;
        }
        int need = (int)(OS * (j1 - 1 - j0)) + DNT;     /* u indices the block reads */
        for (int i = have; i < need; i++) u[i] = 0.0;   /* past the end of the signal */
        if (avx) down_avx(u, hdn, y + j0, (int)(j1 - j0));
        else down_c(u, hdn, y + j0, (int)(j1 - j0));
        int keep = have - (int)(OS * (j1 - j0));
        if (keep < 0) keep = 0;
        for (int i = 0; i < keep; i++) u[i] = u[i + OS * (j1 - j0)];
        have = keep;
    }
}

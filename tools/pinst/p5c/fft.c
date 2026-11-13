/* PINST5 C encoder: the shared transforms. See fft.h.
 *
 * The complex FFT is a self-sorting (Stockham) radix 4/8 transform in
 * pocketfft's pass layout (FFTPACK cfftp): pass p reads cc[k][r][ido] and
 * writes ch[j][k][ido] with that pass's twiddles stored contiguously, so there
 * is no bit-reversal pass and every inner loop walks memory in order. The
 * passes ping-pong between two buffers; the real FFT and the DCT-IV use their
 * output and scratch arrays for that, so given scratch (and no aliasing in
 * rfft) they allocate nothing. Twiddles are cos/sin of an angle folded into
 * the first octant, one call per index (no recurrences).
 *
 * Arithmetic is plain double add/sub/mul with no fused multiply-add. The
 * scalar, SSE2 and AVX paths do the same operations in the same order, so all
 * three give the same bits; AVX is picked at plan creation from cpuid.
 * -DP5FFT_SCALAR forces the scalar path, -DP5FFT_NOAVX the SSE2 one. */
#include "fft.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#if !defined(P5FFT_SCALAR) && (defined(_M_X64) || defined(__SSE2__) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2))
#define P5FFT_SSE2 1
#endif
#if defined(P5FFT_SSE2) && defined(_MSC_VER) && defined(_M_X64) && !defined(P5FFT_NOAVX)
#define P5FFT_AVX 1
#endif

/* ------------------------------------------------------------ complex ops */

#ifdef P5FFT_SSE2
#include <emmintrin.h>
typedef __m128d cx;
#define LD(p) _mm_loadu_pd(p)
#define ST(p, v) _mm_storeu_pd((p), (v))
#define CADD(a, b) _mm_add_pd((a), (b))
#define CSUB(a, b) _mm_sub_pd((a), (b))
#define CSCALE(a, s) _mm_mul_pd((a), _mm_set1_pd(s))
static inline cx cswap(cx a) { return _mm_shuffle_pd(a, a, 1); }
/* a * w: (ar wr + -ai wi, ai wr + ar wi) */
static inline cx CMUL(cx a, cx w) {
    cx wr = _mm_unpacklo_pd(w, w), wi = _mm_unpackhi_pd(w, w);
    return _mm_add_pd(_mm_mul_pd(a, wr), _mm_mul_pd(_mm_xor_pd(cswap(a), _mm_set_pd(0.0, -0.0)), wi));
}
/* a * -i: (ai, -ar) */
static inline cx CROTM(cx a) { return _mm_xor_pd(cswap(a), _mm_set_pd(-0.0, 0.0)); }
/* conj a */
static inline cx CCONJ(cx a) { return _mm_xor_pd(a, _mm_set_pd(-0.0, 0.0)); }
/* (p[0], q[0]) */
static inline cx LD2(const double *p, const double *q) { return _mm_loadh_pd(_mm_load_sd(p), q); }
/* p[0] = re v, q[0] = -im v */
static inline void ST2N(double *p, double *q, cx v) {
    _mm_store_sd(p, v);
    _mm_storeh_pd(q, _mm_xor_pd(v, _mm_set_pd(-0.0, 0.0)));
}
#else
typedef struct {
    double r, i;
} cx;
static inline cx LD(const double *p) { cx v; v.r = p[0]; v.i = p[1]; return v; }
static inline void ST(double *p, cx v) { p[0] = v.r; p[1] = v.i; }
static inline cx CADD(cx a, cx b) { cx v; v.r = a.r + b.r; v.i = a.i + b.i; return v; }
static inline cx CSUB(cx a, cx b) { cx v; v.r = a.r - b.r; v.i = a.i - b.i; return v; }
static inline cx CSCALE(cx a, double s) { cx v; v.r = a.r * s; v.i = a.i * s; return v; }
static inline cx CMUL(cx a, cx w) {
    cx v;
    v.r = a.r * w.r + -a.i * w.i;
    v.i = a.i * w.r + a.r * w.i;
    return v;
}
static inline cx CROTM(cx a) { cx v; v.r = a.i; v.i = -a.r; return v; }
static inline cx CCONJ(cx a) { cx v; v.r = a.r; v.i = -a.i; return v; }
static inline cx LD2(const double *p, const double *q) { cx v; v.r = p[0]; v.i = q[0]; return v; }
static inline void ST2N(double *p, double *q, cx v) { p[0] = v.r; q[0] = -v.i; }
#endif

/* ------------------------------------------------------------ twiddles */

/* cos and sin of 2 pi m / n, n a power of two, folded into [0, pi/4] */
static void cs2pi(long long m, long long n, double *c, double *s) {
    int neg_s = 0, swap = 0, neg_c = 0;
    m %= n;
    if (m < 0) m += n;
    if (2 * m > n) { m = n - m; neg_s = 1; }     /* 2 pi - a: (c, -s) */
    if (4 * m > n) { m = n / 2 - m; neg_c = 1; } /* pi - a: (-c, s) */
    if (8 * m > n) { m = n / 4 - m; swap = 1; }  /* pi/2 - a: (s, c) */
    double a = 2.0 * M_PI * ((double)m / (double)n), cc = cos(a), ss = sin(a);
    if (swap) { double t = cc; cc = ss; ss = t; }
    if (neg_c) cc = -cc;
    if (neg_s) ss = -ss;
    *c = cc;
    *s = ss;
}

/* ------------------------------------------------------------ passes
 *
 * CC(i, m, k): input m of butterfly k at offset i; CH(i, k, j): output j.
 * Twiddles exist for every i (i = 0 has exactly 1 + 0i, which changes
 * nothing but the sign of a zero), blocked by pairs of i so that the AVX
 * path loads w_j(i), w_j(i+1) together: complex (i/2*(R-1) + j-1)*2 + i%2. */

#define CC(i, m, k) (cc + 2 * ((i) + ido * ((m) + R * (k))))
#define CH(i, k, j) (ch + 2 * ((i) + ido * ((k) + l1 * (j))))

/* forward DFT-4; T is the vector type, A/S/RM its add, sub, times -i */
#define BF4(T, A, S, RM, a0, a1, a2, a3, y0, y1, y2, y3) \
    {                                                    \
        T t1_ = A(a0, a2), t2_ = S(a0, a2);              \
        T t3_ = A(a1, a3), t4_ = RM(S(a1, a3));          \
        y0 = A(t1_, t3_);                                \
        y2 = S(t1_, t3_);                                \
        y1 = A(t2_, t4_);                                \
        y3 = S(t2_, t4_);                                \
    }

/* DFT-8 = radix 2 on (m, m+4), then DFT-4 of the sums (even outputs) and of
 * the differences times w8^m (odd outputs) */
#define BF8(T, A, S, RM, SC, a0, a1, a2, a3, a4, a5, a6, a7, y0, y1, y2, y3, y4, y5, y6, y7) \
    {                                                                                        \
        T s0_ = A(a0, a4), s1_ = A(a1, a5), s2_ = A(a2, a6), s3_ = A(a3, a7);                \
        T d0_ = S(a0, a4), d1_ = S(a1, a5), d2_ = S(a2, a6), d3_ = S(a3, a7);                \
        d1_ = SC(A(d1_, RM(d1_)), 0.70710678118654752440); /* (1 - i) / sqrt 2 */            \
        d2_ = RM(d2_);                                      /* -i */                         \
        d3_ = SC(S(RM(d3_), d3_), 0.70710678118654752440); /* (-1 - i) / sqrt 2 */           \
        BF4(T, A, S, RM, s0_, s1_, s2_, s3_, y0, y2, y4, y6);                                \
        BF4(T, A, S, RM, d0_, d1_, d2_, d3_, y1, y3, y5, y7);                                \
    }

#define BF4C(a0, a1, a2, a3, y0, y1, y2, y3) BF4(cx, CADD, CSUB, CROTM, a0, a1, a2, a3, y0, y1, y2, y3)
#define BF8C(a0, a1, a2, a3, a4, a5, a6, a7, y0, y1, y2, y3, y4, y5, y6, y7) \
    BF8(cx, CADD, CSUB, CROTM, CSCALE, a0, a1, a2, a3, a4, a5, a6, a7, y0, y1, y2, y3, y4, y5, y6, y7)
#define TW(j, h) LD(w + 4 * ((j) - 1) + 2 * (h))

static void pass2(int ido, int l1, const double *cc, double *ch, const double *wa) {
    const int R = 2;
    if (ido == 1) {
        for (int k = 0; k < l1; k++) {
            cx a0 = LD(CC(0, 0, k)), a1 = LD(CC(0, 1, k));
            ST(CH(0, k, 0), CADD(a0, a1));
            ST(CH(0, k, 1), CSUB(a0, a1));
        }
        return;
    }
    for (int k = 0; k < l1; k++) {
        const double *w = wa;
        for (int i = 0; i < ido; i += 2, w += 4 * (R - 1))
            for (int h = 0; h < 2; h++) {
                cx a0 = LD(CC(i + h, 0, k)), a1 = LD(CC(i + h, 1, k));
                ST(CH(i + h, k, 0), CADD(a0, a1));
                ST(CH(i + h, k, 1), CMUL(CSUB(a0, a1), TW(1, h)));
            }
    }
}

static void pass4(int ido, int l1, const double *cc, double *ch, const double *wa) {
    const int R = 4;
    cx y0, y1, y2, y3;
    if (ido == 1) {
        for (int k = 0; k < l1; k++) {
            BF4C(LD(CC(0, 0, k)), LD(CC(0, 1, k)), LD(CC(0, 2, k)), LD(CC(0, 3, k)), y0, y1, y2, y3);
            ST(CH(0, k, 0), y0);
            ST(CH(0, k, 1), y1);
            ST(CH(0, k, 2), y2);
            ST(CH(0, k, 3), y3);
        }
        return;
    }
    for (int k = 0; k < l1; k++) {
        const double *w = wa;
        for (int i = 0; i < ido; i += 2, w += 4 * (R - 1))
            for (int h = 0; h < 2; h++) {
                BF4C(LD(CC(i + h, 0, k)), LD(CC(i + h, 1, k)), LD(CC(i + h, 2, k)), LD(CC(i + h, 3, k)), y0, y1,
                     y2, y3);
                ST(CH(i + h, k, 0), y0);
                ST(CH(i + h, k, 1), CMUL(y1, TW(1, h)));
                ST(CH(i + h, k, 2), CMUL(y2, TW(2, h)));
                ST(CH(i + h, k, 3), CMUL(y3, TW(3, h)));
            }
    }
}

static void pass8(int ido, int l1, const double *cc, double *ch, const double *wa) {
    const int R = 8;
    cx y0, y1, y2, y3, y4, y5, y6, y7;
    if (ido == 1) {
        for (int k = 0; k < l1; k++) {
            BF8C(LD(CC(0, 0, k)), LD(CC(0, 1, k)), LD(CC(0, 2, k)), LD(CC(0, 3, k)), LD(CC(0, 4, k)),
                 LD(CC(0, 5, k)), LD(CC(0, 6, k)), LD(CC(0, 7, k)), y0, y1, y2, y3, y4, y5, y6, y7);
            ST(CH(0, k, 0), y0); ST(CH(0, k, 1), y1); ST(CH(0, k, 2), y2); ST(CH(0, k, 3), y3);
            ST(CH(0, k, 4), y4); ST(CH(0, k, 5), y5); ST(CH(0, k, 6), y6); ST(CH(0, k, 7), y7);
        }
        return;
    }
    for (int k = 0; k < l1; k++) {
        const double *w = wa;
        for (int i = 0; i < ido; i += 2, w += 4 * (R - 1))
            for (int h = 0; h < 2; h++) {
                int q = i + h;
                BF8C(LD(CC(q, 0, k)), LD(CC(q, 1, k)), LD(CC(q, 2, k)), LD(CC(q, 3, k)), LD(CC(q, 4, k)),
                     LD(CC(q, 5, k)), LD(CC(q, 6, k)), LD(CC(q, 7, k)), y0, y1, y2, y3, y4, y5, y6, y7);
                ST(CH(q, k, 0), y0);
                ST(CH(q, k, 1), CMUL(y1, TW(1, h)));
                ST(CH(q, k, 2), CMUL(y2, TW(2, h)));
                ST(CH(q, k, 3), CMUL(y3, TW(3, h)));
                ST(CH(q, k, 4), CMUL(y4, TW(4, h)));
                ST(CH(q, k, 5), CMUL(y5, TW(5, h)));
                ST(CH(q, k, 6), CMUL(y6, TW(6, h)));
                ST(CH(q, k, 7), CMUL(y7, TW(7, h)));
            }
    }
}

#ifdef P5FFT_AVX
/* the same passes on two complex per register: i, i+1 when ido > 1, and
 * butterflies k, k+1 when ido == 1 */
#include <immintrin.h>
#include <intrin.h>
typedef __m256d cy;
#define YLD(p) _mm256_loadu_pd(p)
#define YST(p, v) _mm256_storeu_pd((p), (v))
#define YADD(a, b) _mm256_add_pd((a), (b))
#define YSUB(a, b) _mm256_sub_pd((a), (b))
#define YSCALE(a, s) _mm256_mul_pd((a), _mm256_set1_pd(s))
static __forceinline cy YMUL(cy a, cy w) {
    cy wr = _mm256_movedup_pd(w), wi = _mm256_permute_pd(w, 0xF);
    return _mm256_add_pd(_mm256_mul_pd(a, wr),
                         _mm256_mul_pd(_mm256_xor_pd(_mm256_permute_pd(a, 5), _mm256_set_pd(0.0, -0.0, 0.0, -0.0)), wi));
}
static __forceinline cy YROTM(cy a) {
    return _mm256_xor_pd(_mm256_permute_pd(a, 5), _mm256_set_pd(-0.0, 0.0, -0.0, 0.0));
}
/* (p[0..1], q[0..1]) */
static __forceinline cy YLD2(const double *p, const double *q) {
    return _mm256_insertf128_pd(_mm256_castpd128_pd256(_mm_loadu_pd(p)), _mm_loadu_pd(q), 1);
}
#define BF4Y(a0, a1, a2, a3, y0, y1, y2, y3) BF4(cy, YADD, YSUB, YROTM, a0, a1, a2, a3, y0, y1, y2, y3)
#define BF8Y(a0, a1, a2, a3, a4, a5, a6, a7, y0, y1, y2, y3, y4, y5, y6, y7) \
    BF8(cy, YADD, YSUB, YROTM, YSCALE, a0, a1, a2, a3, a4, a5, a6, a7, y0, y1, y2, y3, y4, y5, y6, y7)
#define YTW(j) YLD(w + 4 * ((j) - 1))
/* input m of butterflies k and k+1 when ido == 1 */
#define CC2(m, k) YLD2(CC(0, m, k), CC(0, m, (k) + 1))

static void pass4_avx(int ido, int l1, const double *cc, double *ch, const double *wa) {
    const int R = 4;
    cy y0, y1, y2, y3;
    if (ido == 1) {
        int k = 0;
        for (; k + 1 < l1; k += 2) {
            BF4Y(CC2(0, k), CC2(1, k), CC2(2, k), CC2(3, k), y0, y1, y2, y3);
            YST(CH(0, k, 0), y0);
            YST(CH(0, k, 1), y1);
            YST(CH(0, k, 2), y2);
            YST(CH(0, k, 3), y3);
        }
        _mm256_zeroupper();
        if (k < l1) {
            cx z0, z1, z2, z3;
            BF4C(LD(CC(0, 0, k)), LD(CC(0, 1, k)), LD(CC(0, 2, k)), LD(CC(0, 3, k)), z0, z1, z2, z3);
            ST(CH(0, k, 0), z0);
            ST(CH(0, k, 1), z1);
            ST(CH(0, k, 2), z2);
            ST(CH(0, k, 3), z3);
        }
        return;
    }
    for (int k = 0; k < l1; k++) {
        const double *w = wa;
        for (int i = 0; i < ido; i += 2, w += 4 * (R - 1)) {
            BF4Y(YLD(CC(i, 0, k)), YLD(CC(i, 1, k)), YLD(CC(i, 2, k)), YLD(CC(i, 3, k)), y0, y1, y2, y3);
            YST(CH(i, k, 0), y0);
            YST(CH(i, k, 1), YMUL(y1, YTW(1)));
            YST(CH(i, k, 2), YMUL(y2, YTW(2)));
            YST(CH(i, k, 3), YMUL(y3, YTW(3)));
        }
    }
    _mm256_zeroupper();
}

static void pass8_avx(int ido, int l1, const double *cc, double *ch, const double *wa) {
    const int R = 8;
    cy y0, y1, y2, y3, y4, y5, y6, y7;
    if (ido == 1) {
        int k = 0;
        for (; k + 1 < l1; k += 2) {
            BF8Y(CC2(0, k), CC2(1, k), CC2(2, k), CC2(3, k), CC2(4, k), CC2(5, k), CC2(6, k), CC2(7, k), y0, y1,
                 y2, y3, y4, y5, y6, y7);
            YST(CH(0, k, 0), y0); YST(CH(0, k, 1), y1); YST(CH(0, k, 2), y2); YST(CH(0, k, 3), y3);
            YST(CH(0, k, 4), y4); YST(CH(0, k, 5), y5); YST(CH(0, k, 6), y6); YST(CH(0, k, 7), y7);
        }
        _mm256_zeroupper();
        if (k < l1) {
            cx z0, z1, z2, z3, z4, z5, z6, z7;
            BF8C(LD(CC(0, 0, k)), LD(CC(0, 1, k)), LD(CC(0, 2, k)), LD(CC(0, 3, k)), LD(CC(0, 4, k)),
                 LD(CC(0, 5, k)), LD(CC(0, 6, k)), LD(CC(0, 7, k)), z0, z1, z2, z3, z4, z5, z6, z7);
            ST(CH(0, k, 0), z0); ST(CH(0, k, 1), z1); ST(CH(0, k, 2), z2); ST(CH(0, k, 3), z3);
            ST(CH(0, k, 4), z4); ST(CH(0, k, 5), z5); ST(CH(0, k, 6), z6); ST(CH(0, k, 7), z7);
        }
        return;
    }
    for (int k = 0; k < l1; k++) {
        const double *w = wa;
        for (int i = 0; i < ido; i += 2, w += 4 * (R - 1)) {
            BF8Y(YLD(CC(i, 0, k)), YLD(CC(i, 1, k)), YLD(CC(i, 2, k)), YLD(CC(i, 3, k)), YLD(CC(i, 4, k)),
                 YLD(CC(i, 5, k)), YLD(CC(i, 6, k)), YLD(CC(i, 7, k)), y0, y1, y2, y3, y4, y5, y6, y7);
            YST(CH(i, k, 0), y0);
            YST(CH(i, k, 1), YMUL(y1, YTW(1)));
            YST(CH(i, k, 2), YMUL(y2, YTW(2)));
            YST(CH(i, k, 3), YMUL(y3, YTW(3)));
            YST(CH(i, k, 4), YMUL(y4, YTW(4)));
            YST(CH(i, k, 5), YMUL(y5, YTW(5)));
            YST(CH(i, k, 6), YMUL(y6, YTW(6)));
            YST(CH(i, k, 7), YMUL(y7, YTW(7)));
        }
    }
    _mm256_zeroupper();
}

#define YNEGHI(a) _mm256_xor_pd((a), _mm256_set_pd(-0.0, 0.0, -0.0, 0.0)) /* conj */
#define YHSWAP(a) _mm256_permute2f128_pd((a), (a), 1)

/* rfft post, two k and their mirrors at a time, while k+1 < H/2; the same
 * operations as the loop in p5fft_rfft. Returns the first k not done. */
static int rpost_avx(int H, const double *r, double *out, const double *rtw) {
    int k = 1;
    for (; k + 1 < H / 2; k += 2) {
        int b = H - k - 1; /* complex b, b+1 mirror k+1, k */
        cy zk = YLD(r + 2 * k), zc = YNEGHI(YHSWAP(YLD(r + 2 * b)));
        cy e = YSCALE(YADD(zk, zc), 0.5);
        cy t = YMUL(YSCALE(YROTM(YSUB(zk, zc)), 0.5), YLD(rtw + 2 * k));
        YST(out + 2 * k, YADD(e, t));
        YST(out + 2 * b, YHSWAP(YNEGHI(YSUB(e, t))));
    }
    _mm256_zeroupper();
    return k;
}

/* dct4 pre-twiddle, two n at a time (H even) */
static void dpre_avx(int N, int H, const double *x, double *t, const double *pre) {
    for (int n = 0; n < H; n += 2) {
        cy a = YLD(x + 2 * n), b = YLD(x + N - 4 - 2 * n);
        /* (x[2n], x[N-1-2n], x[2n+2], x[N-3-2n]) */
        cy v = _mm256_shuffle_pd(a, YHSWAP(b), 0xA);
        YST(t + 2 * n, YMUL(v, YLD(pre + 2 * n)));
    }
    _mm256_zeroupper();
}

/* dct4 post-twiddle from s into y (s may be y), blocks n, n+1 and their
 * mirrors H-2-n, H-1-n, for n < H/2 (H/2 even) */
static void dpost_avx(int H, const double *s, double *y, const double *post) {
    for (int n = 0; n < H / 2; n += 2) {
        int m = H - 2 - n;
        cy va = YNEGHI(YMUL(YLD(s + 2 * n), YLD(post + 2 * n)));
        cy vb = YNEGHI(YMUL(YLD(s + 2 * m), YLD(post + 2 * m)));
        /* y[2n..2n+3] = (A0r, -B1i, A1r, -B0i); y[2m..2m+3] = (B0r, -A1i, B1r, -A0i) */
        YST(y + 2 * n, _mm256_blend_pd(va, YHSWAP(vb), 0xA));
        YST(y + 2 * m, _mm256_blend_pd(vb, YHSWAP(va), 0xA));
    }
    _mm256_zeroupper();
}

static int have_avx(void) {
    int r[4];
    __cpuid(r, 1);
    if (!((r[2] >> 27) & 1) || !((r[2] >> 28) & 1)) return 0; /* OSXSAVE, AVX */
    return (_xgetbv(0) & 6) == 6;                                /* XMM and YMM state on */
}
#endif

#undef CC
#undef CH

/* ------------------------------------------------------------ plans */

#define MAXP 40

typedef struct {
    int n, np, avx;
    int r[MAXP], l1[MAXP], ido[MAXP];
    double *tw[MAXP];
    double *mem;
} cplan;

struct p5fft_plan {
    int N, H;
    cplan full;   /* size N, for p5fft_cfft */
    cplan half;   /* size N/2, for rfft and dct4 */
    double *rtw;  /* H/2+1 complex: exp(-2 pi i k / N) */
    double *pre;  /* H complex: exp(-i pi n / N) */
    double *post; /* H complex: exp(-i pi (n + 1/4) / N) */
};

static int is_pow2(int n) { return n > 0 && (n & (n - 1)) == 0; }

static int cplan_init(cplan *c, int n) {
    int m = 0, np = 0;
    memset(c, 0, sizeof(*c));
    c->n = n;
    while ((1 << m) < n) m++;
    {
        /* radix 4 first, while the strides are long; radix 8 only in the
         * last passes, where its 16 streams don't fight over cache sets: one
         * when m is odd, two when it is even (one radix 2 for n = 2) */
        int k8 = m < 3 ? 0 : (m & 1) ? 1 : (m >= 6 ? 2 : 0);
        int left = m - 3 * k8, n2 = left & 1;
        left -= n2;
        while (left > 0) { c->r[np++] = 4; left -= 2; }
        while (k8--) c->r[np++] = 8;
        while (n2--) c->r[np++] = 2;
    }
    c->np = np;
    size_t tot = 0;
    int l1 = 1;
    for (int p = 0; p < np; p++) {
        c->l1[p] = l1;
        c->ido[p] = n / (l1 * c->r[p]);
        if (c->ido[p] > 1) tot += (size_t)(c->r[p] - 1) * (size_t)c->ido[p];
        l1 *= c->r[p];
    }
    c->mem = (double *)malloc(sizeof(double) * 2 * (tot ? tot : 1));
    if (!c->mem) return 0;
    double *q = c->mem;
    for (int p = 0; p < np; p++) {
        int r = c->r[p], ido = c->ido[p];
        c->tw[p] = q;
        if (ido == 1) continue;
        for (int i = 0; i < ido; i++)
            for (int j = 1; j < r; j++) {
                double cs, sn;
                size_t at = 2 * ((size_t)(i >> 1) * (r - 1) + (j - 1)) + (i & 1);
                cs2pi((long long)j * c->l1[p] * i, n, &cs, &sn);
                q[2 * at] = cs;
                q[2 * at + 1] = -sn;
            }
        q += 2 * (size_t)(r - 1) * (size_t)ido;
    }
#ifdef P5FFT_AVX
    c->avx = have_avx();
#endif
    return 1;
}

static void cplan_free(cplan *c) { free(c->mem); }

/* Runs the passes: the first reads in, then they alternate a, b, a, ...
 * Returns the buffer holding the result (a when np is odd, else b). in may
 * not be a. */
static double *cplan_run(const cplan *c, const double *in, double *a, double *b) {
    const double *src = in;
    double *dst = a;
    for (int p = 0; p < c->np; p++) {
        int r = c->r[p], ido = c->ido[p], l1 = c->l1[p];
#ifdef P5FFT_AVX
        if (c->avx && r == 4) pass4_avx(ido, l1, src, dst, c->tw[p]);
        else if (c->avx && r == 8) pass8_avx(ido, l1, src, dst, c->tw[p]);
        else
#endif
        if (r == 4) pass4(ido, l1, src, dst, c->tw[p]);
        else if (r == 8) pass8(ido, l1, src, dst, c->tw[p]);
        else pass2(ido, l1, src, dst, c->tw[p]);
        src = dst;
        dst = dst == a ? b : a;
    }
    return (double *)src;
}

p5fft_plan *p5fft_plan_new(int N) {
    p5fft_plan *p;
    int H, k;
    if (N < 4 || !is_pow2(N)) return NULL;
    p = (p5fft_plan *)calloc(1, sizeof(*p));
    if (!p) return NULL;
    H = N / 2;
    p->N = N;
    p->H = H;
    p->rtw = (double *)malloc(sizeof(double) * 2 * (H / 2 + 1));
    p->pre = (double *)malloc(sizeof(double) * 2 * H);
    p->post = (double *)malloc(sizeof(double) * 2 * H);
    if (!p->rtw || !p->pre || !p->post || !cplan_init(&p->full, N) || !cplan_init(&p->half, H)) {
        p5fft_plan_free(p);
        return NULL;
    }
    for (k = 0; k <= H / 2; k++) {
        double c, s;
        cs2pi(k, N, &c, &s);
        p->rtw[2 * k] = c;
        p->rtw[2 * k + 1] = -s;
    }
    for (k = 0; k < H; k++) {
        double c, s;
        cs2pi(k, 2LL * N, &c, &s);           /* pi k / N */
        p->pre[2 * k] = c;
        p->pre[2 * k + 1] = -s;
        cs2pi(4LL * k + 1, 8LL * N, &c, &s); /* pi (k + 1/4) / N */
        p->post[2 * k] = c;
        p->post[2 * k + 1] = -s;
    }
    return p;
}

void p5fft_plan_free(p5fft_plan *p) {
    if (!p) return;
    cplan_free(&p->full);
    cplan_free(&p->half);
    free(p->rtw);
    free(p->pre);
    free(p->post);
    free(p);
}

int p5fft_size(const p5fft_plan *p) { return p->N; }

void p5fft_cfft(const p5fft_plan *p, double *z) {
    int n = p->N;
    double *t = (double *)malloc(sizeof(double) * 2 * (size_t)n);
    if (!t) return;
    double *r = cplan_run(&p->full, z, t, z);
    if (r != z) memcpy(z, r, sizeof(double) * 2 * (size_t)n);
    free(t);
}

void p5fft_rfft(const p5fft_plan *p, const double *x, double *out, double *scratch) {
    int H = p->H, N = p->N;
    double *z = scratch ? scratch : (double *)malloc(sizeof(double) * N);
    double *xc = NULL;
    if (x == out || x == z) { /* the passes need x apart from both buffers */
        xc = (double *)malloc(sizeof(double) * N);
        memcpy(xc, x, sizeof(double) * N);
        x = xc;
    }
    /* x[2n], x[2n+1] are already re, im: the half-size complex FFT reads x
     * itself and ends in z (out is the other buffer) */
    double *r = (p->half.np & 1) ? cplan_run(&p->half, x, z, out) : cplan_run(&p->half, x, out, z);
    /* Z = r. X[k] = E + W^k O, X[H-k] = conj(E - W^k O) with
     * E = (Z[k] + conj Z[H-k]) / 2, O = (Z[k] - conj Z[H-k]) / 2i */
    double z0r = r[0], z0i = r[1];
    out[0] = z0r + z0i;
    out[1] = 0.0;
    out[2 * H] = z0r - z0i;
    out[2 * H + 1] = 0.0;
    int k = 1;
#ifdef P5FFT_AVX
    if (p->half.avx) k = rpost_avx(H, r, out, p->rtw);
#endif
    for (; k <= H / 2; k++) {
        int b = H - k;
        cx zk = LD(r + 2 * k), zc = CCONJ(LD(r + 2 * b));
        cx e = CSCALE(CADD(zk, zc), 0.5);
        cx t = CMUL(CSCALE(CROTM(CSUB(zk, zc)), 0.5), LD(p->rtw + 2 * k));
        ST(out + 2 * k, CADD(e, t));
        if (b != k) ST(out + 2 * b, CCONJ(CSUB(e, t)));
    }
    free(xc);
    if (!scratch) free(z);
}

void p5fft_dct4(const p5fft_plan *p, const double *x, double *y, double *scratch) {
    int N = p->N, H = p->H, n;
    double *t = scratch ? scratch : (double *)malloc(sizeof(double) * N);
#ifdef P5FFT_AVX
    if (p->half.avx && H >= 4) {
        dpre_avx(N, H, x, t, p->pre);
        double *r = cplan_run(&p->half, t, y, t);
        dpost_avx(H, r, y, p->post);
        if (!scratch) free(t);
        return;
    }
#endif
    /* t[n] = (x[2n] + i x[N-1-2n]) exp(-i pi n / N) */
    for (n = 0; n < H; n++) ST(t + 2 * n, CMUL(LD2(x + 2 * n, x + N - 1 - 2 * n), LD(p->pre + 2 * n)));
    /* x is read: y and t are the two buffers */
    double *r = cplan_run(&p->half, t, y, t);
    /* v = T[n] exp(-i pi (n + 1/4) / N): y[2n] = re v, y[N-1-2n] = -im v */
    if (r == t) {
        for (n = 0; n < H; n++) ST2N(y + 2 * n, y + N - 1 - 2 * n, CMUL(LD(t + 2 * n), LD(p->post + 2 * n)));
    } else {
        /* the result is in y: complex n and H-1-n fill exactly the four
         * slots their outputs go to, so do them in pairs, in place */
        for (n = 0; n < H / 2; n++) {
            int m = H - 1 - n;
            cx a = CMUL(LD(y + 2 * n), LD(p->post + 2 * n));
            cx b = CMUL(LD(y + 2 * m), LD(p->post + 2 * m));
            ST2N(y + 2 * n, y + N - 1 - 2 * n, a);
            ST2N(y + 2 * m, y + N - 1 - 2 * m, b);
        }
    }
    if (!scratch) free(t);
}

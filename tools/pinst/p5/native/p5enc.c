/* PINST5 encoder helpers: the MDCT's fold and unfold around scipy's DCT-IV
   (transform.py). Each is the numpy expression it replaces, operation for
   operation in the same order, so the results are the same to the bit.
   Double precision, no threads, no fast-math, no contraction.

   Build (MinGW):  gcc -O2 -ffp-contract=off -fno-fast-math -shared -o p5enc.dll p5enc.c */
#include <stdint.h>

#ifdef _WIN32
#define API __declspec(dllexport)
#else
#define API
#endif

/* buf = (M/2 zeros, e[0..n), zeros) cut into rows of M; frame f is rows f and
   f + 1 = quarters a b | c d, folded to u = (-(c~ * wcr) - d * wd, a * wa - b~ * wbr);
   frame 0's right half is -b~ (transform._mdct_frames). u: F x M. */
API void p5_mdct_fold(const double* e, int64_t n, int64_t M, int64_t F,
                      const double* wa, const double* wbr, const double* wcr, const double* wd, double* u) {
    const int64_t h = M / 2;
#define BUF(i) (((i) - h >= 0 && (i) - h < n) ? e[(i) - h] : 0.0)
    for (int64_t f = 0; f < F; f++) {
        double* uf = u + f * M;
        const int64_t r0 = f * M, r1 = (f + 1) * M;
        /* fast path: every sample read inside e */
        int inside = (r0 - h >= 0) && (r1 + M - 1 - h < n);
        if (inside) {
            const double* R0 = e + (r0 - h);
            const double* R1 = e + (r1 - h);
            for (int64_t j = 0; j < h; j++) {
                double t = -(R1[h - 1 - j] * wcr[j]);
                uf[j] = t - R1[h + j] * wd[j];
            }
            for (int64_t j = 0; j < h; j++) {
                double a = R0[j] * wa[j];
                uf[h + j] = a - R0[M - 1 - j] * wbr[j];
            }
        } else {
            for (int64_t j = 0; j < h; j++) {
                double t = -(BUF(r1 + h - 1 - j) * wcr[j]);
                uf[j] = t - BUF(r1 + h + j) * wd[j];
            }
            if (f == 0) {
                for (int64_t j = 0; j < h; j++) uf[h + j] = -BUF(M - 1 - j);
            } else {
                for (int64_t j = 0; j < h; j++) {
                    double a = BUF(r0 + j) * wa[j];
                    uf[h + j] = a - BUF(r0 + M - 1 - j) * wbr[j];
                }
            }
        }
    }
#undef BUF
}

/* V: F x M, DCT-IV of the coefficients (scipy's). Frame f's 2M samples are
   yf = (V[h..M) | -V reversed | -V[0..h)) / M, times w0 (frame 0) or w; the
   frames overlap-add at hop M into (F + 1) M samples, out = those from off,
   m of them, as numpy's zeros, += first halves, += second halves makes them. */
API void p5_imdct_unfold(const double* V, int64_t F, int64_t M, const double* w0, const double* w,
                         int64_t off, int64_t m, double* out) {
    const int64_t h = M / 2;
    const double s = 1.0 / (double)M;
    for (int64_t i = 0; i < m; i++) {
        int64_t p = off + i, r = p / M, j = p % M;
        double o = 0.0;
        if (r < F) {        /* yf[r][j], j < M: first half */
            const double* v = V + r * M;
            const double* ww = r ? w : w0;
            double y = j < h ? (v[j + h] * s) : -(v[M - 1 - (j - h)] * s);
            o += y * ww[j];
        }
        if (r >= 1) {       /* yf[r - 1][M + j]: second half */
            const double* v = V + (r - 1) * M;
            const double* ww = (r - 1) ? w : w0;
            int64_t nn = M + j;
            double y = nn < 3 * h ? -(v[M - 1 - (nn - h)] * s) : -(v[nn - 3 * h] * s);
            o += y * ww[nn];
        }
        out[i] = o;
    }
}

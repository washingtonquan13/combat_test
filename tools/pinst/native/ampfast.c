/* The two per-sample loops of amp.py, in C: the same operations in the same
   order, so the numbers are the ones numpy gives. Built by build.bat into
   ampfast.dll; amp.py falls back to numpy when the DLL is not there. */
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
   A stage runs over a whole block before the next one starts: the only
   values carried from sample to sample are then the two one-pole states, so
   the processor overlaps the rest of the work across samples. */
#define BLOCK 2048

EXPORT void disto_stages(const double* x, double* out, int64_t n, int stages, double s0, double s1, double c4,
                         double b0, double b1, double a1, const double* table, double* st) {
    for (int64_t a = 0; a < n; a += BLOCK) {
        int64_t m = n - a < BLOCK ? n - a : BLOCK;
        const double* in = x + a;
        double* o = out + a;
        for (int s = 0; s < stages; s++) {
            double* q = st + 4 * s;
            double last = q[0], state = q[1], z1 = q[2], z2 = q[3];
            for (int64_t i = 0; i < m; i++) {
                double v = in[i];
                if (v > last && v > 0.25) state = 0.0;
                else if (v < last && v < -0.25) state = 1.0;
                last = v;
                double rec1 = z1 + (1 - c4) * state;
                z1 = state * 0.0 - rec1 * (-c4);
                double t2 = 12.75 * (s0 * v + 10.0);
                if (!(t2 > 0.0)) t2 = 0.0;
                int64_t i3 = (int64_t)t2;
                double t4 = table[i3 < 255 ? i3 : 255];
                double t5 = t4 + (t2 - (double)i3) * (table[i3 + 1 < 255 ? i3 + 1 : 255] - t4);
                double t6 = rec1 * (t5 - s1 - 1.0) + (1 - rec1) * (t5 - s1);
                double y = z2 + b0 * t6;
                z2 = t6 * b1 - y * a1;
                o[i] = y;
            }
            q[0] = last; q[1] = state; q[2] = z1; q[3] = z2;
            in = o;
        }
    }
}

/* The whole oversampled distortion in one pass: 8x up, the stages, 8x down,
   a block at a time, so the oversampled signal never leaves the cache.
   hup: 8 phases of 21 taps laid against x[i-10 .. i+10]; hdn: 161 taps laid
   against u[8j-80 .. 8j+80]. Sums run in four chains, so the result differs
   from scipy's resample_poly in the last bits. */
#define OS 8
#define HALF 80
#define UPT 21
#define DNT 161
#define XB 512

static double dot4(const double* a, const double* b, int n) {
    double s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    int i = 0;
    for (; i + 4 <= n; i += 4) {
        s0 += a[i] * b[i]; s1 += a[i + 1] * b[i + 1];
        s2 += a[i + 2] * b[i + 2]; s3 += a[i + 3] * b[i + 3];
    }
    for (; i < n; i++) s0 += a[i] * b[i];
    return (s0 + s1) + (s2 + s3);
}

EXPORT void disto_os(const double* x, double* y, int64_t n, const double* hup, const double* hdn, int stages,
                     double s0, double s1, double c4, double b0, double b1, double a1, const double* table) {
    double st[4 * 16] = {0};
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
            for (int i = 0; i < m; i++)
                for (int p = 0; p < OS; p++) o[OS * i + p] = dot4(xw + i, hup + UPT * p, UPT);
            disto_stages(o, o, (int64_t)OS * m, stages, s0, s1, c4, b0, b1, a1, table, st);
            have += OS * m;
            gen = want;
        }
        int need = (int)(OS * (j1 - 1 - j0)) + DNT;     /* u indices the block reads */
        for (int i = have; i < need; i++) u[i] = 0.0;   /* past the end of the signal */
        for (int64_t j = j0; j < j1; j++) y[j] = dot4(u + OS * (j - j0), hdn, DNT);
        int keep = have - (int)(OS * (j1 - j0));
        if (keep < 0) keep = 0;
        for (int i = 0; i < keep; i++) u[i] = u[i + OS * (j1 - j0)];
        have = keep;
    }
}

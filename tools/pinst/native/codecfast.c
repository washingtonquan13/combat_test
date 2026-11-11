/* Loops of pinst_codec.py that spent their time in the interpreter, in C.
   Every one does the same operations in the same order as the Python it
   replaces, so a bake gives the same bytes with or without this library. */
#include <math.h>
#include <stdint.h>

#define EXPORT __declspec(dllexport)

/* numpy's pairwise sum of a contiguous double array. */
static double pairwise(const double* a, int64_t n) {
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
    return pairwise(a, n2) + pairwise(a + n2, n - n2);
}

/* ndarray.sum(): the first element, plus the pairwise sum of the rest. */
EXPORT double np_sum(const double* a, int64_t n) {
    return n > 0 ? a[0] + pairwise(a + 1, n - 1) : 0.0;
}

/* keyframes(): v is (L, C) row-major. Returns how many indices went to keep. */
EXPORT int64_t keyframes(const double* v, int64_t L, int C, const double* tol, int64_t max_span, int64_t* keep) {
    int64_t n = 0, k = 0;
    keep[n++] = 0;
    while (k < L - 1) {
        int64_t best = k + 1;
        int64_t hi = L - 1 < k + max_span ? L - 1 : k + max_span;
        const double* vk = v + k * C;
        for (int64_t j = k + 2; j <= hi; j++) {
            const double* vj = v + j * C;
            int bad = 0;
            for (int64_t m = k + 1; m < j && !bad; m++) {
                double r = (double)(m - k) / (double)(j - k);
                const double* vm = v + m * C;
                for (int c = 0; c < C; c++) {
                    double interp = vk[c] + r * (vj[c] - vk[c]);
                    if (fabs(interp - vm[c]) > tol[c]) { bad = 1; break; }
                }
            }
            if (bad) break;
            best = j;
        }
        keep[n++] = best;
        k = best;
    }
    return n;
}

#define MAXSPAN 4096
static const double PI = 3.141592653589793, TWO_PI = 6.283185307179586;

static double wrap(double a) { /* (a + pi) % TWO_PI - pi with Python's % */
    double m = fmod(a + PI, TWO_PI);
    if (m < 0.0) m += TWO_PI;
    else if (m == 0.0) m = 0.0;
    return m - PI;
}

/* steer_keys(): qc comes in rounded open-loop and leaves steered. Returns 0,
   or 1 when a span is longer than this was built for (caller falls back). */
EXPORT int steer_keys(const double* cents, const double* ref, const double* ph, const int64_t* keys, int64_t nk,
                      int64_t ki0, double phi0, double H, double q, double gain, double clip, double k,
                      double ln2_1200, int64_t* qc) {
    double fr[MAXSPAN + 1], w[MAXSPAN + 1], s[MAXSPAN];
    double th = phi0;
    for (int64_t i = ki0 + 1; i < nk; i++)
        if (keys[i] - keys[i - 1] > MAXSPAN || keys[i] <= keys[i - 1]) return 1;
    for (int64_t i = ki0 + 1; i < nk; i++) {
        int64_t a = keys[i - 1], b = keys[i], span = b - a;
        const double* r = ref + a;
        double cp = (double)qc[i - 1] * q, cn = cents[b];
        for (int64_t j = 0; j <= span; j++) fr[j] = (double)j / (double)span;
        for (int64_t j = 0; j <= span; j++) w[j] = k * r[j] * pow(2.0, (cp + (cn - cp) * fr[j]) / 1200.0);
        for (int64_t j = 0; j < span; j++) s[j] = w[j] + w[j + 1];
        double tb = th + 0.5 * np_sum(s, span) * H;
        for (int64_t j = 0; j <= span; j++) w[j] = w[j] * fr[j] * ln2_1200;
        for (int64_t j = 0; j < span; j++) s[j] = w[j] + w[j + 1];
        double deriv = 0.5 * np_sum(s, span) * H;
        double den = 1e-9 > deriv ? 1e-9 : deriv;
        double step = gain * wrap(ph[b] - tb) / den;
        if (step < -clip) step = -clip;
        if (step > clip) step = clip;
        double cb = cn + step;
        qc[i] = (int64_t)rint(cb / q);
        cb = (double)qc[i] * q;
        for (int64_t j = 0; j <= span; j++) w[j] = k * r[j] * pow(2.0, (cp + (cb - cp) * fr[j]) / 1200.0);
        for (int64_t j = 0; j < span; j++) s[j] = w[j] + w[j + 1];
        th = th + 0.5 * np_sum(s, span) * H;
    }
    return 0;
}

/* synth_tracks, a few frames of many partials at a time. st_phase writes the
   cubic phase of each frame, numpy takes its cosine, st_acc scales it by the
   frame's amplitude ramp and adds it to the note. The sums are written out
   in numpy's order: ((th + w t) + al t^2) + be t^3 and a0 + da (t / T). */
EXPORT void st_phase(const double* th0, const double* w0, const double* al, const double* be, int64_t rows, int H,
                     const double* t1, const double* t2, const double* t3, double* buf) {
    for (int64_t r = 0; r < rows; r++) {
        double a = th0[r], b = w0[r], c = al[r], d = be[r];
        double* o = buf + r * H;
        for (int i = 0; i < H; i++) o[i] = ((a + b * t1[i]) + c * t2[i]) + d * t3[i];
    }
}

EXPORT void st_acc(const double* cosv, const double* a0, const double* da, const double* tT, int64_t rows, int H,
                   const int64_t* off, double* out, int64_t nout) {
    for (int64_t r = 0; r < rows; r++) {
        const double* c = cosv + r * H;
        double a = a0[r], d = da[r];
        int64_t j0 = off[r];
        int lo = j0 < 0 ? (int)(-j0 < H ? -j0 : H) : 0;
        int hi = j0 + H > nout ? (int)(nout - j0 > 0 ? nout - j0 : 0) : H;
        for (int i = lo; i < hi; i++) out[j0 + i] += (a + d * tT[i]) * c[i];
    }
}

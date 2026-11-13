/* The sine layer's peak picking (sines_fast.py): the part of
   pinst_codec.find_peaks_frames between the FFT and the phases, the numpy
   and scipy lines it replaces done in the same operations in the same order,
   so the same bits. No libm call but fabs: numpy keeps abs, log10 and the
   angles. Build (no -march: SSE2 doubles, no FMA):
     gcc -O2 -ffp-contract=off -fno-fast-math -shared -o sines.dll sines.c */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>

#define EXPORT __declspec(dllexport)

/* mag = |X| * 2.0 / wsum + 1e-12, in place (the argument of log10). */
EXPORT void pk_scale(double *d, int64_t n, double wsum)
{
    for (int64_t i = 0; i < n; i++)
        d[i] = ((d[i] * 2.0) / wsum) + 1e-12;
}

/* lg: (rows, nb) log10 of the scaled magnitudes; becomes db = 20 * lg in place.
   floor = scipy.ndimage.uniform_filter1d(db, size, axis=1) (mode reflect: its
   running mean, NI_UniformFilter1D). A bin k is a peak when 2 <= k < min(kmax, nb - 1),
   db[k] > db[k-1], db[k] >= db[k+1], db[k] > max(rowmax + rel_db, abs_db) and
   db[k] > floor[k] + prom_db. Per peak, in row then bin order: row + row0, bin,
   the parabola's offset p, frequency (k + p) * sr / z, amplitude b - 0.25 (a - c) p,
   X at the bin and at the neighbour bin the phase is read from (X: (rows, nb)
   complex, interleaved). Returns the number of peaks, -1 without memory. */
EXPORT int64_t pk_rows(double *lg, int64_t rows, int64_t nb, int64_t size, int64_t kmax,
                       double rel_db, double abs_db, double prom_db, double sr, double z,
                       const double *X, int64_t row0,
                       int64_t *ofi, double *op, double *of, double *oamp, double *oxk, double *oxn)
{
    int64_t s1 = size / 2, s2 = size - s1 - 1;
    double *e = malloc(sizeof(double) * (size_t)(s1 + nb + s2));
    double *fl = malloc(sizeof(double) * (size_t)nb);
    if (!e || !fl) {
        free(e); free(fl);
        return -1;
    }
    int64_t n = 0, hi = kmax < nb - 1 ? kmax : nb - 1;
    double fs = (double)size;
    for (int64_t r = 0; r < rows; r++) {
        double *d = lg + r * nb;
        for (int64_t k = 0; k < nb; k++)
            d[k] = 20.0 * d[k];
        double mx = d[0];
        for (int64_t k = 1; k < nb; k++)
            if (d[k] > mx || d[k] != d[k]) mx = d[k];     /* numpy's max: NaN wins */
        /* the line, reflected at both ends ("d c b a | a b c d | d c b a") */
        for (int64_t k = 0; k < nb; k++) e[s1 + k] = d[k];
        for (int64_t j = 0; j < s1; j++) e[s1 - 1 - j] = d[j < nb ? j : nb - 1];
        for (int64_t j = 0; j < s2; j++) e[s1 + nb + j] = d[nb - 1 - j >= 0 ? nb - 1 - j : 0];
        double tmp = 0.0;
        for (int64_t l = 0; l < size; l++) tmp += e[l];
        tmp /= fs;
        fl[0] = tmp;
        for (int64_t l = 1; l < nb; l++) {
            tmp += (e[l + size - 1] - e[l - 1]) / fs;
            fl[l] = tmp;
        }
        double thr = mx + rel_db;
        if (!(thr >= abs_db)) thr = (thr != thr) ? thr : abs_db;    /* np.maximum: NaN wins */
        const double *x = X + 2 * r * nb;
        for (int64_t k = 2; k < hi; k++) {
            double b = d[k];
            if (!(b > d[k - 1] && b >= d[k + 1] && b > thr && b > fl[k] + prom_db))
                continue;
            double a = d[k - 1], c = d[k + 1];
            double den = (a - 2.0 * b) + c;
            double p = fabs(den) > 1e-9 ? (0.5 * (a - c)) / den : 0.0;
            int64_t kn = p >= 0 ? k + 1 : k - 1;
            ofi[n] = r + row0;
            op[n] = p;
            of[n] = (((double)k + p) * sr) / z;
            oamp[n] = b - (0.25 * (a - c)) * p;
            oxk[2 * n] = x[2 * k]; oxk[2 * n + 1] = x[2 * k + 1];
            oxn[2 * n] = x[2 * kn]; oxn[2 * n + 1] = x[2 * kn + 1];
            n++;
        }
    }
    free(e); free(fl);
    return n;
}

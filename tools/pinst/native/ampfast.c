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

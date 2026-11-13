/* PINST5 C encoder, stage TQ: the MDCT layers (port of frozen p5/transform.py). See mdct.h. */
#include "mdct.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "fft.h"

typedef struct {
    p5fft_plan *plan;
    double *w;                      /* pc._mdct(M)[1]: sin(pi (n + .5) / 2M), 2M values */
    double *wa, *wbr, *wcr, *wd;    /* transform._WIN[M]: w[:h], w[h:M][::-1], w[M:M+h][::-1], w[M+h:] */
} Tab;

static Tab g_tab[17];               /* by log2(M), 2 .. 16; made once, read-only after */

static int log2_of(int64_t M) {
    int k;
    if (M < 4 || M > 65536 || (M & (M - 1))) return -1;
    for (k = 0; ((int64_t)1 << k) != M; k++) {}
    return k;
}

static const Tab *tab_for(int64_t M) {
    int k = log2_of(M);
    Tab *t;
    int64_t i, h = M / 2;
    if (k < 0) return NULL;
    t = &g_tab[k];
    if (t->plan) return t;
    {
        double *w = (double *)malloc(sizeof(double) * (size_t)(4 * M));
        p5fft_plan *p = p5fft_plan_new((int)M);
        if (!w || !p) {
            free(w);
            p5fft_plan_free(p);
            return NULL;
        }
        for (i = 0; i < 2 * M; i++) w[i] = sin(3.141592653589793 * ((double)i + 0.5) / (double)(2 * M));
        t->w = w;
        t->wa = w + 2 * M;
        t->wbr = t->wa + h;
        t->wcr = t->wbr + h;
        t->wd = t->wcr + h;
        for (i = 0; i < h; i++) {
            t->wa[i] = w[i];
            t->wbr[i] = w[M - 1 - i];
            t->wcr[i] = w[M + h - 1 - i];
            t->wd[i] = w[M + h + i];
        }
        t->plan = p;     /* last: marks the table made */
    }
    return t;
}

int p5tq_init(void) {
    return (tab_for(128) && tab_for(1024)) ? 0 : -1;
}

int64_t p5_layer_frames(int64_t n, int64_t M) {
    /* int(np.ceil((n + M // 2) / M)) + 1 */
    return (int64_t)ceil((double)(n + M / 2) / (double)M) + 1;
}

int64_t p5_frames(int64_t n, int64_t M, int64_t start) {
    return p5_layer_frames(n - start, M);
}

int64_t p5_last_nonzero(const double *e, int64_t n, int64_t start) {
    int64_t i;
    if (start < 0) start = 0;
    for (i = n - 1; i >= start; i--)
        if (e[i] != 0.0) return i;
    return -1;
}

static inline double wval(const double *e, const double *w, int wmode, int64_t i) {
    if (wmode == P5W_MUL) return e[i] * w[i];
    if (wmode == P5W_MASK) return e[i] * (w[i] > 0.0 ? 1.0 : 0.0);
    return e[i];
}

/* The length of the piece transform.forward cuts: e[start : start + L]. */
static int64_t piece_len(const double *e, const double *w, int wmode, int64_t n, int64_t start) {
    int64_t i, last = -1, L;
    if (start < 0) start = 0;
    for (i = n - 1; i >= start; i--)
        if (wval(e, w, wmode, i) != 0.0) {
            last = i;
            break;
        }
    L = last >= start ? last - start + 1 : 1;
    if (L > n - start) L = n - start;
    if (L < 0) L = 0;
    return L;
}

int64_t p5_forward_frames(const double *e, const double *w, int wmode, int64_t n, int64_t M,
                          int64_t start) {
    return p5_layer_frames(piece_len(e, w, wmode, n, start), M);
}

double *p5_forward(const double *e, const double *w, int wmode, int64_t n, int64_t M,
                   int64_t start, int64_t *frames) {
    const Tab *t = tab_for(M);
    int64_t L, F, f, i, h = M / 2;
    double *buf, *X, *u;
    if (!t) return NULL;
    if (wmode != P5W_NONE && !w) wmode = P5W_NONE;
    L = piece_len(e, w, wmode, n, start);
    F = p5_layer_frames(L, M);
    buf = (double *)calloc((size_t)((F + 1) * M), sizeof(double));
    X = (double *)malloc(sizeof(double) * (size_t)(F * M));
    u = (double *)malloc(sizeof(double) * (size_t)(2 * M));
    if (!buf || !X || !u) {
        free(buf);
        free(X);
        free(u);
        return NULL;
    }
    for (i = 0; i < L; i++) buf[h + i] = wval(e, w, wmode, start + i);
    for (f = 0; f < F; f++) {
        const double *R0 = buf + f * M, *R1 = R0 + M;
        for (i = 0; i < h; i++) {          /* -c~ - d */
            double a = -(R1[h - 1 - i] * t->wcr[i]);
            u[i] = a - R1[h + i] * t->wd[i];
        }
        if (f == 0)                        /* frame 0's left half is flat: a = 0, b = 1 */
            for (i = 0; i < h; i++) u[h + i] = -R0[M - 1 - i];
        else                               /* a - b~ */
            for (i = 0; i < h; i++) u[h + i] = R0[i] * t->wa[i] - R0[M - 1 - i] * t->wbr[i];
        p5fft_dct4(t->plan, u, X + f * M, u + M);
    }
    free(buf);
    free(u);
    *frames = F;
    return X;
}

int p5_inverse(const double *X, int64_t F, int64_t K, int64_t n, int64_t M, int64_t start,
               double *y) {
    const Tab *t = tab_for(M);
    int64_t f, i, h = M / 2, len, m;
    double *out, *c, s = 2.0 / (double)M;
    if (!t || K > M || K < 0) return -1;
    memset(y, 0, sizeof(double) * (size_t)(n > 0 ? n : 0));
    len = (F + 1) * M;
    m = n - start;
    if (len - h < m) m = len - h;
    if (m <= 0) return 0;
    out = (double *)calloc((size_t)len, sizeof(double));
    c = (double *)malloc(sizeof(double) * (size_t)(3 * M));
    if (!out || !c) {
        free(out);
        free(c);
        return -1;
    }
    for (f = 0; f < F; f++) {
        double *o = out + f * M, *cc = c + M, *scr = c + 2 * M;
        const double *w = t->w;
        memcpy(c, X + f * K, sizeof(double) * (size_t)K);
        for (i = K; i < M; i++) c[i] = 0.0;
        /* cc[m] = sum_k X[k] cos(pi/M (m + .5)(k + .5)); the basis row n is that at m = n + M/2,
           odd about m = M and even about m = 2M */
        p5fft_dct4(t->plan, c, cc, scr);
        if (f == 0) {    /* w0: 0 over the first half frame, 1 to M, the window after */
            for (i = h; i < M; i++) o[i] += -cc[2 * M - 1 - (i + h)] * s;
            for (i = M; i < M + h; i++) o[i] += (-cc[2 * M - 1 - (i + h)] * s) * w[i];
            for (i = M + h; i < 2 * M; i++) o[i] += (-cc[i + h - 2 * M] * s) * w[i];
        } else {
            for (i = 0; i < h; i++) o[i] += (cc[i + h] * s) * w[i];
            for (i = h; i < M + h; i++) o[i] += (-cc[2 * M - 1 - (i + h)] * s) * w[i];
            for (i = M + h; i < 2 * M; i++) o[i] += (-cc[i + h - 2 * M] * s) * w[i];
        }
    }
    memcpy(y + start, out + h, sizeof(double) * (size_t)m);
    free(out);
    free(c);
    return 0;
}

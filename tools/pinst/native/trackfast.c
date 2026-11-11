/* Partial tracking: which peak of each frame continues which live track.
   The assignment is scipy's linear_sum_assignment step for step (Crouse's
   shortest augmenting paths), so ties fall the way they do there. */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __declspec(dllexport)

typedef struct {
    double *u, *v, *spc;
    int64_t *path, *col4row, *row4col, *remaining;
    char *SR, *SC;
} Work;

static int64_t aug_path(int64_t nr, int64_t nc, const double *cost, Work *w, int64_t i, double *p_min)
{
    double minVal = 0;
    int64_t num_remaining = nc, sink = -1;
    for (int64_t it = 0; it < nc; it++) {
        w->remaining[it] = nc - it - 1;
        w->spc[it] = INFINITY;
    }
    memset(w->SR, 0, nr);
    memset(w->SC, 0, nc);
    while (sink == -1) {
        int64_t index = -1;
        double lowest = INFINITY;
        w->SR[i] = 1;
        for (int64_t it = 0; it < num_remaining; it++) {
            int64_t j = w->remaining[it];
            double r = minVal + cost[i * nc + j] - w->u[i] - w->v[j];
            if (r < w->spc[j]) {
                w->path[j] = i;
                w->spc[j] = r;
            }
            if (w->spc[j] < lowest || (w->spc[j] == lowest && w->row4col[j] == -1)) {
                lowest = w->spc[j];
                index = it;
            }
        }
        minVal = lowest;
        if (minVal == INFINITY)
            return -1;
        int64_t j = w->remaining[index];
        if (w->row4col[j] == -1)
            sink = j;
        else
            i = w->row4col[j];
        w->SC[j] = 1;
        w->remaining[index] = w->remaining[--num_remaining];
    }
    *p_min = minVal;
    return sink;
}

/* nr <= nc. Leaves the column of every row in w->col4row. */
static int lsap(int64_t nr, int64_t nc, const double *cost, Work *w)
{
    for (int64_t i = 0; i < nr; i++) { w->u[i] = 0; w->col4row[i] = -1; }
    for (int64_t j = 0; j < nc; j++) { w->v[j] = 0; w->row4col[j] = -1; w->path[j] = -1; }
    for (int64_t cur = 0; cur < nr; cur++) {
        double minVal;
        int64_t sink = aug_path(nr, nc, cost, w, cur, &minVal);
        if (sink < 0)
            return 0;
        w->u[cur] += minVal;
        for (int64_t i = 0; i < nr; i++)
            if (w->SR[i] && i != cur)
                w->u[i] += minVal - w->spc[w->col4row[i]];
        for (int64_t j = 0; j < nc; j++)
            if (w->SC[j])
                w->v[j] -= minVal - w->spc[j];
        int64_t j = sink;
        for (;;) {
            int64_t i = w->path[j];
            w->row4col[j] = i;
            int64_t t = w->col4row[i];
            w->col4row[i] = j;
            j = t;
            if (i == cur)
                break;
        }
    }
    return 1;
}

/* f: every frame's peak frequencies end to end, frame i at cuts[i]..cuts[i+1].
   Frames before `first` count as empty. For every peak from there on, in
   frame order (continued tracks first, in the order they were live, then new
   ones): ids = its track's number, src = where it sits in f. starts[t] = the
   frame track t was born in. Returns the number of tracks, or -1. */
EXPORT int64_t track_assign(const double *f, const int64_t *cuts, int64_t F, int64_t first, double tol,
                            int64_t *ids, int64_t *src, int64_t *starts)
{
    int64_t maxp = 1;
    for (int64_t i = 0; i < F; i++)
        if (cuts[i + 1] - cuts[i] > maxp)
            maxp = cuts[i + 1] - cuts[i];
    Work w;
    double *dbl = malloc(sizeof(double) * (maxp * maxp + 4 * maxp));
    int64_t *ints = malloc(sizeof(int64_t) * 7 * maxp);
    char *flags = malloc(3 * maxp);
    if (!dbl || !ints || !flags) {
        free(dbl); free(ints); free(flags);
        return -1;
    }
    double *cost = dbl, *last = dbl + maxp * maxp;
    w.u = last + maxp; w.v = w.u + maxp; w.spc = w.v + maxp;
    w.path = ints; w.col4row = ints + maxp; w.row4col = ints + 2 * maxp; w.remaining = ints + 3 * maxp;
    int64_t *act = ints + 4 * maxp, *match = ints + 5 * maxp, *nact = ints + 6 * maxp;
    w.SR = flags; w.SC = flags + maxp;
    char *used = flags + 2 * maxp;
    int64_t nA = 0, born = 0, o = 0, ok = 1;
    for (int64_t i = first < 0 ? 0 : first; i < F && ok; i++) {
        const double *fp = f + cuts[i];
        int64_t nP = cuts[i + 1] - cuts[i];
        for (int64_t r = 0; r < nA; r++) match[r] = -1;
        if (nA && nP) {
            int tall = nP < nA;     /* scipy turns a tall matrix on its side */
            for (int64_t r = 0; r < nA; r++)
                for (int64_t c = 0; c < nP; c++) {
                    double q = fp[c] / last[r], v = 1e6;
                    if (q > 0.97 && q < 1.03) {     /* well outside tol otherwise */
                        v = fabs(log2(q));
                        if (!(v < tol)) v = 1e6;
                    }
                    if (tall) cost[c * nA + r] = v; else cost[r * nP + c] = v;
                }
            if (tall) {
                ok = lsap(nP, nA, cost, &w);
                for (int64_t c = 0; c < nP && ok; c++)
                    if (cost[c * nA + w.col4row[c]] < 1e6) match[w.col4row[c]] = c;
            } else {
                ok = lsap(nA, nP, cost, &w);
                for (int64_t r = 0; r < nA && ok; r++)
                    if (cost[r * nP + w.col4row[r]] < 1e6) match[r] = w.col4row[r];
            }
        }
        memset(used, 0, nP);
        int64_t m = 0;
        for (int64_t r = 0; r < nA; r++)
            if (match[r] >= 0) {
                used[match[r]] = 1;
                ids[o] = nact[m++] = act[r];
                src[o++] = cuts[i] + match[r];
            }
        for (int64_t c = 0; c < nP; c++)
            if (!used[c]) {
                starts[born] = i;
                ids[o] = nact[m++] = born++;
                src[o++] = cuts[i] + c;
            }
        nA = m;
        for (int64_t r = 0; r < nA; r++) {
            act[r] = nact[r];
            last[r] = f[src[o - nA + r]];
        }
    }
    free(dbl); free(ints); free(flags);
    return ok ? born : -1;
}

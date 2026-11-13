/* PINST5 C encoder: one note -> bytes (owner: PK). See encode.h.
 *
 * Python names in the comments are frozen p5/encode.py's (2f6c9a8). */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "encode.h"
#include "pack.h"
#include "measure.h"
#include "sine_an.h"
#include "sine_q.h"
#include "mdct.h"
#include "blocks.h"
#include "quant.h"

#ifdef P5_SINE_RENDER_EXACT
#define SINE_RENDER p5_sine_render_exact
#else
#define SINE_RENDER p5_sine_render
#endif

/* ------------------------------------------------------------ the LZMA memo */

typedef struct {
    uint64_t h;
    int64_t n, zn;
    uint8_t *in, *z;
} LzEnt;

typedef struct {
    p5_lz_fn fn;
    void *ctx;
    int64_t n, cap;
    LzEnt *e;
    int err;
} LzMemo;

static uint64_t fnv1a(const uint8_t *p, int64_t n) {
    uint64_t h = 1469598103934665603ULL;
    int64_t i;
    for (i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static int64_t lz_memo(void *ctx, const uint8_t *in, int64_t n, uint8_t *out, int64_t cap) {
    LzMemo *m = (LzMemo *)ctx;
    LzEnt *e = NULL;
    uint64_t h;
    int64_t i;
    if (n <= 0) return 0;
    h = fnv1a(in, n);
    for (i = 0; i < m->n; i++)
        if (m->e[i].h == h && m->e[i].n == n && !memcmp(m->e[i].in, in, (size_t)n)) {
            e = &m->e[i];
            break;
        }
    if (!e) {
        int64_t zc = n + n / 8 + 1024, zn;
        uint8_t *z = (uint8_t *)malloc((size_t)zc), *cp;
        if (!z) { m->err = P5_ENC_NOMEM; return -1; }
        zn = m->fn(m->ctx, in, n, z, zc);
        if (zn > zc) {
            free(z);
            zc = zn;
            z = (uint8_t *)malloc((size_t)zc);
            if (!z) { m->err = P5_ENC_NOMEM; return -1; }
            zn = m->fn(m->ctx, in, n, z, zc);
            if (zn != zc) zn = -1;
        }
        if (zn < 0) { free(z); m->err = P5_ENC_LZ; return -1; }
        cp = (uint8_t *)malloc((size_t)n);
        if (!cp) { free(z); m->err = P5_ENC_NOMEM; return -1; }
        memcpy(cp, in, (size_t)n);
        if (m->n == m->cap) {
            int64_t nc = m->cap ? 2 * m->cap : 32;
            LzEnt *ne = (LzEnt *)realloc(m->e, (size_t)nc * sizeof(LzEnt));
            if (!ne) { free(z); free(cp); m->err = P5_ENC_NOMEM; return -1; }
            m->e = ne;
            m->cap = nc;
        }
        e = &m->e[m->n++];
        e->h = h;
        e->n = n;
        e->in = cp;
        e->zn = zn;
        e->z = z;
    }
    if (out && cap >= e->zn) memcpy(out, e->z, (size_t)e->zn);
    return e->zn;
}

static void lz_free(LzMemo *m) {
    int64_t i;
    for (i = 0; i < m->n; i++) {
        free(m->e[i].in);
        free(m->e[i].z);
    }
    free(m->e);
    m->e = NULL;
    m->n = m->cap = 0;
}

/* ------------------------------------------------------------ the note's state */

/* analysis.encode_sines(x, f0) for one channel's samples. */
typedef struct {
    const double *x;
    P5Sine *s;          /* NULL: None */
    double *det;        /* its render (NULL with s) */
} SineRes;

/* One kept or dropped layer: quant.quantize's answer for a key. */
typedef struct {
    double *tf;         /* the key's tight frames (F), NULL for None or all zero */
    int64_t seed;
    int hk, kept;
    P5Layer L;          /* L.start set */
    int64_t a, len;     /* the inverse's nonzero span */
    double *inv;
    P5Buf sec;          /* p5_pack_layer(sec_ci, L), made on the first pack that holds it */
    int64_t sec_ci;
} Ent;

/* One (M, w, s) of blocks.plan with what encode_channel finds for it. */
typedef struct {
    int64_t M, s, F, nbx;
    int whole;
    double *X, *Xs[2], *Xr;     /* Xr is Xs[0] when whole */
    double *hd[2];              /* heard_db(Xs), heard_ms_db(*Xs) */
    double *bsnr;               /* band_snr(Xr, M, quant_snr(dial)): made once, every coding's */
    Ent **ent;
    int64_t nent, cap;
} Piece;

/* encode_channel's inputs but the seed, heard_of and tight: x, ref, sigs, lr. */
typedef struct {
    const double *x, *ref, *sigs[2], *lr[2];
    int nsigs, nlr;
    int ready, empty;
    SineRes *sn;
    P5Plan plan;
    Piece *pc;
    int ntop;
    int64_t topM[4];
    double top[4];
} Prep;

typedef struct {
    Prep *p;
    int64_t seed0;
} Unit;

/* One coded channel: the ChannelCode (shallow: its sines and layers belong to
 * the Prep) and the entries its layers came from. */
typedef struct {
    P5Channel ch;
    const double *det;
    Ent **ents;
} Chan;

typedef struct {
    int64_t n, sr;
    double hint, dial;
    int zero_is_none;
    LzMemo lz;
    SineRes sn[4];
    int nsn;
    Prep pr[4];
    int npr;
    double *w, *yb, *d0, *d1;   /* n each */
    int64_t layers_packed, layers_coded;
} Enc;

static int any_nz(const double *x, int64_t n, int64_t stride) {
    int64_t i;
    for (i = 0; i < n; i++)
        if (x[i * stride] != 0) return 1;
    return 0;
}

static int sine_err(Enc *E) { return E->lz.err ? E->lz.err : P5_ENC_SINE; }

/* encode_sines: None for a silent x, n_tracks 0, or a layer not worth keeping. */
static int get_sines(Enc *E, const double *x, SineRes **out) {
    int64_t n = E->n, nt, sb = 0;
    int i;
    SineRes *r;
    P5Tracks tr;
    for (i = 0; i < E->nsn; i++)
        if (E->sn[i].x == x || !memcmp(E->sn[i].x, x, (size_t)n * sizeof(double))) {
            *out = &E->sn[i];
            return 0;
        }
    r = &E->sn[E->nsn++];
    r->x = x;
    r->s = NULL;
    r->det = NULL;
    *out = r;
    if (!any_nz(x, n, 1)) return 0;
    memset(&tr, 0, sizeof(tr));
    if (p5_sine_analyse(x, n, E->sr, E->hint, &tr) < 0) {
        p5_tracks_free(&tr);
        return P5_ENC_SINE;
    }
    r->s = (P5Sine *)calloc(1, sizeof(P5Sine));
    if (!r->s) { p5_tracks_free(&tr); return P5_ENC_NOMEM; }
    nt = p5_sine_quantize(&tr, E->sr, lz_memo, &E->lz, r->s);
    p5_tracks_free(&tr);
    if (nt > 0) {
        r->det = (double *)malloc((size_t)n * sizeof(double));
        if (!r->det) return P5_ENC_NOMEM;
        if (SINE_RENDER(r->s, n, E->sr, r->det) != 1) return P5_ENC_SINE;
        for (i = 0; i < P5S_NSTREAMS; i++) sb += r->s->lz_sizes[i];
        if (p5_sine_worth_keeping(x, r->det, n, sb)) return 0;
    }
    p5_sine_free(r->s);
    free(r->s);
    r->s = NULL;
    free(r->det);
    r->det = NULL;
    return nt < 0 ? sine_err(E) : 0;
}

/* encode._fit, taking X (Fx frames) and giving an F-frame array. */
static double *fit_own(double *X, int64_t Fx, int64_t M, int64_t F) {
    double *o;
    if (!X || Fx == F) return X;
    o = (double *)malloc((size_t)(F * M) * sizeof(double));
    if (o) p5_fit(X, Fx, M, F, o);
    free(X);
    return o;
}

static double get_top(Enc *E, Prep *P, int64_t M, int *rc) {
    int i;
    int64_t F;
    double *X, t;
    for (i = 0; i < P->ntop; i++)
        if (P->topM[i] == M) return P->top[i];
    X = p5_forward(P->ref, NULL, P5W_NONE, E->n, M, 0, &F);
    if (!X) { *rc = P5_ENC_TQ; return 0; }
    t = p5_top_db(X, F, M);
    free(X);
    if (P->ntop < 4) {
        P->topM[P->ntop] = M;
        P->top[P->ntop++] = t;
    }
    return t;
}

/* encode_channel up to the quantizer: sines, e, plan, and each piece's
 * X, Xs, Xr (what does not depend on seed, heard_of or tight). */
static int prep_ready(Enc *E, Prep *P) {
    int64_t n = E->n, k, i;
    int rc, g;
    double *e;
    if (P->ready) return 0;
    P->ready = 1;
    if (!any_nz(P->x, n, 1)) { P->empty = 1; return 0; }
    rc = get_sines(E, P->x, &P->sn);
    if (rc) return rc;
    e = (double *)malloc((size_t)n * sizeof(double));
    if (!e) return P5_ENC_NOMEM;
    for (i = 0; i < n; i++) e[i] = P->x[i] - (P->sn->det ? P->sn->det[i] : 0.0);
    if (p5_plan(e, P->ref, n, P->nlr ? P->lr : NULL, P->nlr, &P->plan) < 0) { free(e); return P5_ENC_NOMEM; }
    P->pc = (Piece *)calloc((size_t)(P->plan.npieces ? P->plan.npieces : 1), sizeof(Piece));
    if (!P->pc) { free(e); return P5_ENC_NOMEM; }
    for (k = 0; k < P->plan.npieces; k++) {
        Piece *q = &P->pc[k];
        int64_t M = P->plan.pieces[k].M, s = P->plan.pieces[k].s, F, Fg, ed[P5_NBANDS + 2];
        double *w = E->w;
        q->M = M;
        q->s = s;
        p5_plan_w(&P->plan, k, w);
        q->X = p5_forward(e, w, P5W_MUL, n, M, s, &F);
        if (!q->X) { free(e); return P5_ENC_TQ; }
        q->F = F;
        q->whole = 1;
        for (i = s; i < n; i++)
            if (!(w[i] > 0)) { q->whole = 0; break; }
        for (g = 0; g < P->nsigs; g++) {
            double *Xg = p5_forward(P->sigs[g], w, q->whole ? P5W_NONE : P5W_MASK, n, M, s, &Fg);
            q->Xs[g] = fit_own(Xg, Fg, M, F);
            if (!q->Xs[g]) { free(e); return P5_ENC_TQ; }
        }
        if (q->whole) q->Xr = q->Xs[0];
        else {
            double *Xg = p5_forward(P->sigs[0], NULL, P5W_NONE, n, M, s, &Fg);
            q->Xr = fit_own(Xg, Fg, M, F);
            if (!q->Xr) { free(e); return P5_ENC_TQ; }
        }
        q->nbx = p5_edges(M, P5_NBANDS, ed) - 1;
    }
    free(e);
    return 0;
}

static int tf_eq(const double *a, const double *b, int64_t F) {
    if (!a || !b) return a == b;
    return !memcmp(a, b, (size_t)F * sizeof(double));
}

/* quant.quantize for piece k under (seed, hk, tight), from the cache or made
 * (with its inverse). tf: the frames Python passes (NULL = None); key: tf, or
 * NULL when tf is all zero. */
static int piece_layer(Enc *E, Prep *P, int64_t k, int64_t seed, int hk, const double *tf, const double *key, Ent **out) {
    Piece *q = &P->pc[k];
    int64_t n = E->n, F = q->F, M = q->M, i, a, b;
    Ent *t;
    int rc = 0;
    double top;
    for (i = 0; i < q->nent; i++) {
        t = q->ent[i];
        if (t->seed == seed && t->hk == hk && tf_eq(t->tf, key, F)) { *out = t; return 0; }
    }
    if (!q->hd[hk]) {
        q->hd[hk] = (double *)malloc((size_t)(F * q->nbx) * sizeof(double));
        if (!q->hd[hk]) return P5_ENC_NOMEM;
        if ((hk ? p5_heard_ms_db(q->Xs[0], q->Xs[1], F, M, q->hd[hk])
                : p5_heard_db((const double *const *)q->Xs, P->nsigs, F, M, q->hd[hk])) < 0)
            return P5_ENC_NOMEM;
    }
    if (!q->bsnr) {
        q->bsnr = (double *)malloc((size_t)(F * q->nbx) * sizeof(double));
        if (!q->bsnr) return P5_ENC_NOMEM;
        rc = p5_band_snr(q->Xr, F, M, M, p5_quant_snr(E->dial), q->bsnr);
        if (rc < 0) {
            free(q->bsnr);
            q->bsnr = NULL;
            return rc == -1 ? P5_ENC_NOMEM : P5_ENC_TQ;
        }
    }
    top = get_top(E, P, M, &rc);
    if (rc) return rc;
    t = (Ent *)calloc(1, sizeof(Ent));
    if (!t) return P5_ENC_NOMEM;
    if (q->nent == q->cap) {
        int64_t nc = q->cap ? 2 * q->cap : 8;
        Ent **ne = (Ent **)realloc(q->ent, (size_t)nc * sizeof(Ent *));
        if (!ne) { free(t); return P5_ENC_NOMEM; }
        q->ent = ne;
        q->cap = nc;
    }
    q->ent[q->nent++] = t;
    t->seed = seed;
    t->hk = hk;
    if (key) {
        t->tf = (double *)malloc((size_t)F * sizeof(double));
        if (!t->tf) return P5_ENC_NOMEM;
        memcpy(t->tf, key, (size_t)F * sizeof(double));
    }
    rc = p5_quantize_bs(q->X, F, M, M, seed, E->dial, top, q->hd[hk], tf, q->bsnr, &t->L);
    if (rc < 0) return rc == -1 ? P5_ENC_NOMEM : P5_ENC_TQ;
    t->kept = rc == 1;
    if (t->kept) {
        double *Xd = (double *)malloc((size_t)(t->L.frames * t->L.K) * sizeof(double) + 8);
        t->L.start = q->s;
        if (!Xd) return P5_ENC_NOMEM;
        if (p5_dequantize(&t->L, Xd) < 0) { free(Xd); return P5_ENC_NOMEM; }
        rc = p5_inverse(Xd, t->L.frames, t->L.K, n, t->L.M, q->s, E->yb);
        free(Xd);
        if (rc < 0) return P5_ENC_TQ;
        for (a = 0; a < n && E->yb[a] == 0; a++) {}
        for (b = n; b > a && E->yb[b - 1] == 0; b--) {}
        t->a = a;
        t->len = b - a;
        if (t->len) {
            t->inv = (double *)malloc((size_t)t->len * sizeof(double));
            if (!t->inv) return P5_ENC_NOMEM;
            memcpy(t->inv, E->yb + a, (size_t)t->len * sizeof(double));
        }
    }
    *out = t;
    return 0;
}

/* encode_channel(x, ref, f0, seed0, dial, sigs, heard_of, sines, tight, lr).
 * t: tight per sample or NULL; mf: maximum_filter1d(t, 2M) for M = 128, 1024. */
static int unit_code(Enc *E, Unit u, int hk, const double *t, double *const mf[2], Chan *c) {
    Prep *P = u.p;
    int64_t k, nk = 0;
    int rc;
    memset(c, 0, sizeof(*c));
    rc = prep_ready(E, P);
    if (rc) return rc;
    if (P->empty) return 0;
    c->ch.sines = P->sn->s;
    c->det = P->sn->det;
    c->ch.layers = (P5Layer *)malloc((size_t)(P->plan.npieces + 1) * sizeof(P5Layer));
    c->ents = (Ent **)malloc((size_t)(P->plan.npieces + 1) * sizeof(Ent *));
    if (!c->ch.layers || !c->ents) return P5_ENC_NOMEM;
    if (P->nsigs != 2) hk = 0;      /* heard(Xs) of one channel is heard_db */
    for (k = 0; k < P->plan.npieces; k++) {
        Piece *q = &P->pc[k];
        double *tf = NULL;
        const double *key = NULL;
        Ent *ent = NULL;
        if (t) {
            int64_t f;
            tf = (double *)malloc((size_t)q->F * sizeof(double));
            if (!tf) return P5_ENC_NOMEM;
            if (q->M == 128) p5_frame_max_mf(mf[0], E->n, q->M, q->s, q->F, tf);
            else if (q->M == 1024) p5_frame_max_mf(mf[1], E->n, q->M, q->s, q->F, tf);
            else p5_frame_max(t, E->n, q->M, q->s, q->F, tf);
            key = tf;
            if (E->zero_is_none) {
                for (f = 0; f < q->F && tf[f] == 0; f++) {}
                if (f == q->F) key = NULL;
            }
        }
        rc = piece_layer(E, P, k, u.seed0 + 1 + nk, hk, tf, key, &ent);
        free(tf);
        if (rc) return rc;
        if (ent->kept) {
            c->ch.layers[nk] = ent->L;
            c->ents[nk++] = ent;
        }
    }
    c->ch.nlayers = nk;
    return 0;
}

static void chan_free(Chan *c) {
    free(c->ch.layers);
    free(c->ents);
    memset(c, 0, sizeof(*c));
}

/* decode.channel from the cache: the render plus each layer's inverse. */
static void chan_decode(Enc *E, const Chan *c, double *y) {
    int64_t n = E->n, j, i;
    if (c->det) memcpy(y, c->det, (size_t)n * sizeof(double));
    else memset(y, 0, (size_t)n * sizeof(double));
    for (j = 0; j < c->ch.nlayers; j++) {
        const Ent *t = c->ents[j];
        double *yy = y + t->a;
        for (i = 0; i < t->len; i++) yy[i] = yy[i] + t->inv[i];
    }
}

/* One candidate's coding: its channels, and (Y not NULL) its decode. */
typedef struct {
    Chan ch[2];
    int nch, stereo;
} Coded;

static void coded_free(Coded *k) {
    chan_free(&k->ch[0]);
    chan_free(&k->ch[1]);
    k->nch = 0;
}

static void coded_decode(Enc *E, const Coded *k, double *Y) {
    int64_t n = E->n, i;
    chan_decode(E, &k->ch[0], E->d0);
    if (k->nch == 1) {
        memcpy(Y, E->d0, (size_t)n * sizeof(double));
        return;
    }
    chan_decode(E, &k->ch[1], E->d1);
    for (i = 0; i < n; i++) {
        if (k->stereo == 1) {
            Y[2 * i] = E->d0[i] + E->d1[i];
            Y[2 * i + 1] = E->d0[i] - E->d1[i];
        } else {
            Y[2 * i] = E->d0[i];
            Y[2 * i + 1] = E->d1[i];
        }
    }
}

/* p5_pack of a coding, each layer's LAYR section taken from its entry (coded
 * there the first time any coding packs it: the section depends on (ci, L)
 * only, the range coder starting fresh in each). */
static int coded_pack(Enc *E, const Coded *k, P5Buf *out) {
    P5Note note;
    const P5Buf *secs[2 * 64], **sp = secs;
    int64_t ci, j, nl = 0;
    int rc;
    for (ci = 0; ci < k->nch; ci++) nl += k->ch[ci].ch.nlayers;
    if (nl > (int64_t)(sizeof(secs) / sizeof(secs[0]))) {
        sp = (const P5Buf **)malloc((size_t)nl * sizeof(*sp));
        if (!sp) return P5_ENC_NOMEM;
    }
    nl = 0;
    for (ci = 0; ci < k->nch; ci++)
        for (j = 0; j < k->ch[ci].ch.nlayers; j++) {
            Ent *t = k->ch[ci].ents[j];
            if (!t->sec.p || t->sec_ci != ci) {
                p5_buf_free(&t->sec);
                rc = p5_pack_layer(ci, &t->L, &t->sec);
                if (rc) { if (sp != secs) free(sp); return rc; }
                t->sec_ci = ci;
                E->layers_coded++;
            }
            sp[nl++] = &t->sec;
        }
    E->layers_packed += nl;
    memset(&note, 0, sizeof(note));
    note.sr = E->sr;
    note.n = E->n;
    note.stereo = k->stereo;
    note.nch = k->nch;
    note.ch[0] = k->ch[0].ch;
    note.ch[1] = k->ch[1].ch;
    rc = p5_pack_secs(&note, lz_memo, &E->lz, sp, out);
    if (sp != secs) free(sp);
    if (rc == P5_PACK_LZ && E->lz.err) rc = E->lz.err;
    return rc;
}

/* cand: -1 mono, 0 ms(heard_db), 1 ms(heard), 2 lr. units: mono [0]; ms [0, 1]; lr [2, 3]. */
static int code_cand(Enc *E, int cand, const Unit *units, const double *t, double *const mf[2], Coded *k) {
    int rc;
    memset(k, 0, sizeof(*k));
    if (cand < 0) {
        k->nch = 1;
        k->stereo = 0;
        return unit_code(E, units[0], 0, t, mf, &k->ch[0]);
    }
    k->nch = 2;
    k->stereo = cand == 2 ? 2 : 1;
    rc = unit_code(E, units[cand == 2 ? 2 : 0], cand == 1, t, mf, &k->ch[0]);
    if (rc) return rc;
    return unit_code(E, units[cand == 2 ? 3 : 1], cand == 1, t, mf, &k->ch[1]);
}

static void prep_free(Prep *P) {
    int64_t k, i;
    if (P->pc) {
        for (k = 0; k < P->plan.npieces; k++) {
            Piece *q = &P->pc[k];
            free(q->X);
            if (q->Xr != q->Xs[0]) free(q->Xr);
            free(q->Xs[0]);
            free(q->Xs[1]);
            free(q->hd[0]);
            free(q->hd[1]);
            free(q->bsnr);
            for (i = 0; i < q->nent; i++) {
                free(q->ent[i]->tf);
                free(q->ent[i]->inv);
                p5_buf_free(&q->ent[i]->sec);
                p5_layer_free(&q->ent[i]->L);
                free(q->ent[i]);
            }
            free(q->ent);
        }
        free(P->pc);
    }
    p5_plan_free(&P->plan);
    memset(P, 0, sizeof(*P));
}

static double *dup_d(const double *y, int64_t m) {
    double *o = (double *)malloc((size_t)(m ? m : 1) * sizeof(double));
    if (o && m) memcpy(o, y, (size_t)m * sizeof(double));
    return o;
}

static int dup_buf(const P5Buf *b, P5Buf *o) {
    o->n = b->n;
    o->p = (uint8_t *)malloc((size_t)(b->n ? b->n : 1));
    if (!o->p) return P5_ENC_NOMEM;
    if (b->n) memcpy(o->p, b->p, (size_t)b->n);
    return 0;
}

int p5_encode_note(const double *x, int64_t n, int64_t nch, int64_t sr, double f0, double dial,
                   p5_lz_fn lz, void *lzctx, P5Buf *out, P5EncDebug *dbg) {
    Enc E;
    Unit units[4];
    Coded cands[3], cur;
    P5Buf bytes[3];
    double *Y[3] = {NULL, NULL, NULL}, *mid = NULL, *side = NULL, *x0 = NULL, *x1 = NULL, *xx = NULL;
    double *t = NULL, *mf[2] = {NULL, NULL}, *yr = NULL, *sc = NULL, *y;
    P5PreEcho pe[2];
    int live[2] = {0, 0}, ncand, k = 0, c, rc = 0, rounds = 0, haveCur = 0, i;
    int64_t nout = nch == 1 ? 1 : 2, j;

    memset(&E, 0, sizeof(E));
    memset(cands, 0, sizeof(cands));
    memset(&cur, 0, sizeof(cur));
    memset(bytes, 0, sizeof(bytes));
    memset(pe, 0, sizeof(pe));
    memset(units, 0, sizeof(units));
    if (out) { out->p = NULL; out->n = 0; }
    if (dbg) memset(dbg, 0, sizeof(*dbg));
    if (!x || n <= 0 || nch < 1 || sr <= 0 || !lz || !out) return P5_ENC_ARG;
    if (p5tq_init() < 0) return P5_ENC_NOMEM;
    E.n = n;
    E.sr = sr;
    E.hint = f0 > 0 ? f0 : 0.0;
    E.dial = dial;
    E.zero_is_none = dial >= 0;
    E.lz.fn = lz;
    E.lz.ctx = lzctx;
#define NEW_D(p, m) do { (p) = (double *)calloc((size_t)(m), sizeof(double)); if (!(p)) { rc = P5_ENC_NOMEM; goto done; } } while (0)
#define TRY(e) do { rc = (e); if (rc) goto done; } while (0)
    NEW_D(E.w, n);
    NEW_D(E.yb, n);
    NEW_D(E.d0, n);
    NEW_D(E.d1, n);
    NEW_D(mid, n);

    if (nch == 1) {
        Prep *P = &E.pr[E.npr++];
        p5_channels_of(x, n, 1, mid, NULL, NULL);
        P->x = P->ref = P->sigs[0] = mid;
        P->nsigs = 1;
        units[0].p = P;
        units[0].seed0 = 7;
        ncand = 1;
        TRY(code_cand(&E, -1, units, NULL, mf, &cands[0]));
        TRY(coded_pack(&E, &cands[0], &bytes[0]));
        NEW_D(Y[0], n);
        coded_decode(&E, &cands[0], Y[0]);
        live[0] = any_nz(mid, n, 1);
    } else {
        Prep *PM, *PS, *PL0, *PL1;
        NEW_D(side, n);
        NEW_D(x0, n);
        NEW_D(x1, n);
        for (j = 0; j < n; j++) {
            x0[j] = x[j * nch];
            x1[j] = x[j * nch + 1];
        }
        if (nch == 2) p5_channels_of(x, n, 2, mid, side, NULL);
        else {
            NEW_D(xx, 2 * n);
            for (j = 0; j < n; j++) {
                xx[2 * j] = x0[j];
                xx[2 * j + 1] = x1[j];
            }
            p5_channels_of(xx, n, 2, mid, side, NULL);
        }
        PM = &E.pr[E.npr++];
        PS = &E.pr[E.npr++];
        PL0 = &E.pr[E.npr++];
        PM->x = PM->ref = mid;
        PS->x = side;
        PS->ref = mid;
        PM->sigs[0] = PS->sigs[0] = mid;
        PM->sigs[1] = PS->sigs[1] = side;
        PM->nsigs = PS->nsigs = 2;
        PM->lr[0] = PS->lr[0] = x0;
        PM->lr[1] = PS->lr[1] = x1;
        PM->nlr = PS->nlr = 2;
        PL0->x = PL0->ref = PL0->sigs[0] = x0;
        PL0->nsigs = 1;
        if (!memcmp(x0, x1, (size_t)n * sizeof(double))) PL1 = PL0;     /* the same channel twice */
        else {
            PL1 = &E.pr[E.npr++];
            PL1->x = PL1->ref = PL1->sigs[0] = x1;
            PL1->nsigs = 1;
        }
        units[0].p = PM;
        units[0].seed0 = 7;
        units[1].p = PS;
        units[1].seed0 = 107;
        units[2].p = PL0;
        units[2].seed0 = 7;
        units[3].p = PL1;
        units[3].seed0 = 107;
        live[0] = any_nz(x, n, nch);
        live[1] = any_nz(x + 1, n, nch);
        ncand = (live[0] || live[1]) ? 3 : 1;
        for (c = 0; c < ncand; c++) {
            TRY(code_cand(&E, c, units, NULL, mf, &cands[c]));
            TRY(coded_pack(&E, &cands[c], &bytes[c]));
            NEW_D(Y[c], 2 * n);
            coded_decode(&E, &cands[c], Y[c]);
        }
        if (ncand == 3) {
            int64_t nb[3];
            double snr[3], pre[3], xe[2] = {0, 0};
            for (c = 0; c < 2; c++)
                if (live[c]) {
                    double s2 = p5_sumsq(x + c, nch, n);
                    xe[c] = s2 > 1e-30 ? s2 : 1e-30;
                    if (p5_pre_init(&pe[c], x + c, nch, n, sr) < 0) { rc = P5_ENC_NOMEM; goto done; }
                }
            for (i = 0; i < 3; i++) {
                int first = 1;
                nb[i] = bytes[i].n;
                for (c = 0; c < 2; c++)
                    if (live[c]) {
                        double s = p5_snr_db_xe(xe[c], x + c, nch, Y[i] + c, 2, n);
                        double p = p5_pre_measure(&pe[c], Y[i] + c, 2);
                        if (first) { snr[i] = s; pre[i] = p; first = 0; }
                        else {
                            if (s < snr[i]) snr[i] = s;     /* min(): the first of equals */
                            if (p > pre[i]) pre[i] = p;     /* max() */
                        }
                    }
            }
            k = p5_stereo_choice(nb, snr, pre);
        }
    }

    /* _peaks */
    y = Y[k];
    if (live[0] || live[1]) {
        double lim = p5_peak_lim(x, n * nch);
        NEW_D(t, n);
        NEW_D(sc, n);
        NEW_D(mf[0], n);
        NEW_D(mf[1], n);
        NEW_D(yr, n * nout);
        for (rounds = 0; rounds < P5_PEAK_ROUNDS; rounds++) {
            if (!p5_peaks_step(y, n, nout, lim, dial, t, sc)) break;
            p5_maximum_filter1d(t, n, 2 * 128, 0.0, mf[0]);
            p5_maximum_filter1d(t, n, 2 * 1024, 0.0, mf[1]);
            if (haveCur) coded_free(&cur);
            haveCur = 1;
            TRY(code_cand(&E, ncand == 1 ? -1 : k, units, t, mf, &cur));
            coded_decode(&E, &cur, yr);
            y = yr;
        }
    }
    if (haveCur) TRY(coded_pack(&E, &cur, out));
    else {
        *out = bytes[k];
        bytes[k].p = NULL;
        bytes[k].n = 0;
    }
    if (dbg) {
        dbg->ncand = ncand;
        dbg->k = k;
        dbg->rounds = rounds;
        dbg->n = n;
        dbg->nout = nout;
        for (c = 0; c < ncand; c++) {
            const P5Buf *b = (c == k && !haveCur) ? out : &bytes[c];
            if (dup_buf(b, &dbg->cand[c]) || !(dbg->ycand[c] = dup_d(Y[c], n * nout))) { rc = P5_ENC_NOMEM; goto done; }
        }
        if (!(dbg->y = dup_d(y, n * nout))) { rc = P5_ENC_NOMEM; goto done; }
        dbg->layers_packed = E.layers_packed;
        dbg->layers_coded = E.layers_coded;
    }
done:
    if (rc) {
        p5_buf_free(out);
        if (dbg) p5_enc_debug_free(dbg);
    }
    if (haveCur) coded_free(&cur);
    for (c = 0; c < 3; c++) {
        coded_free(&cands[c]);
        p5_buf_free(&bytes[c]);
        free(Y[c]);
    }
    p5_pre_free(&pe[0]);
    p5_pre_free(&pe[1]);
    for (i = 0; i < E.npr; i++) prep_free(&E.pr[i]);
    for (i = 0; i < E.nsn; i++) {
        if (E.sn[i].s) { p5_sine_free(E.sn[i].s); free(E.sn[i].s); }
        free(E.sn[i].det);
    }
    lz_free(&E.lz);
    free(E.w); free(E.yb); free(E.d0); free(E.d1);
    free(mid); free(side); free(x0); free(x1); free(xx);
    free(t); free(sc); free(mf[0]); free(mf[1]); free(yr);
    return rc;
#undef NEW_D
#undef TRY
}

void p5_enc_debug_free(P5EncDebug *d) {
    int c;
    if (!d) return;
    for (c = 0; c < 3; c++) {
        p5_buf_free(&d->cand[c]);
        free(d->ycand[c]);
    }
    free(d->y);
    memset(d, 0, sizeof(*d));
}

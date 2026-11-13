/* PINST5 C encoder: the file (owner: PK). See pack.h; frozen p5/pack.py is
 * the reference, byte for byte. */
#include "pack.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* p5/native/p5rc.c, linked in (its state is opaque: p5rc_state_size bytes) */
int64_t p5rc_state_size(void);
void p5rc_enc_init(void *s, uint8_t *out, int64_t cap);
int64_t p5rc_enc_grid(void *s, int64_t kind, int64_t F, int64_t K, const int32_t *v, const uint8_t *mk);
int64_t p5rc_enc_finish(void *s);

#define MAGIC "PIN5"
#define VERSION 1
#define GRID_SC 0
#define GRID_Q 1

/* ------------------------------------------------------------ a growing byte buffer */

typedef struct {
    uint8_t *p;
    int64_t n, cap;
    int err;
} Out;

static int out_room(Out *o, int64_t more) {
    if (o->err) return 0;
    if (o->n + more > o->cap) {
        int64_t c = o->cap ? o->cap : 256;
        uint8_t *q;
        while (c < o->n + more) c *= 2;
        q = (uint8_t *)realloc(o->p, (size_t)c);
        if (!q) { o->err = P5_PACK_NOMEM; return 0; }
        o->p = q;
        o->cap = c;
    }
    return 1;
}

static void out_bytes(Out *o, const void *b, int64_t n) {
    if (n <= 0 || !out_room(o, n)) return;
    memcpy(o->p + o->n, b, (size_t)n);
    o->n += n;
}

/* pc._varint: zigzag, then LEB128 */
static void out_varint(Out *o, int64_t v) {
    uint64_t z = ((uint64_t)v << 1) ^ (uint64_t)(v >> 63);
    if (!out_room(o, 10)) return;
    for (;;) {
        uint8_t b = (uint8_t)(z & 0x7F);
        z >>= 7;
        if (z) o->p[o->n++] = (uint8_t)(b | 0x80);
        else { o->p[o->n++] = b; return; }
    }
}

static void out_free(Out *o) {
    free(o->p);
    memset(o, 0, sizeof *o);
}

/* ------------------------------------------------------------ a reader (pf.Cur) */

typedef struct {
    const uint8_t *b;
    int64_t n, i;
    int err;
} Cur;

static int64_t cur_v(Cur *c) {
    uint64_t z = 0;
    int sh = 0;
    for (;;) {
        uint8_t x;
        if (c->i >= c->n) { c->err = 1; return 0; }
        x = c->b[c->i++];
        if (sh < 64) z |= (uint64_t)(x & 0x7F) << sh;
        sh += 7;
        if (x < 128) return (int64_t)(z >> 1) ^ -(int64_t)(z & 1);
    }
}

static void cur_raw(Cur *c) {
    if (c->i >= c->n) { c->err = 1; return; }
    c->i++;
}

/* ------------------------------------------------------------ pf._reorder(to_frames=True) */

typedef struct { int64_t fr, i; } HeapItem;

static int hless(HeapItem a, HeapItem b) { return a.fr < b.fr || (a.fr == b.fr && a.i < b.i); }

static void hpush(HeapItem *h, int64_t *n, HeapItem x) {
    int64_t k = (*n)++;
    while (k > 0) {
        int64_t p = (k - 1) / 2;
        if (!hless(x, h[p])) break;
        h[k] = h[p];
        k = p;
    }
    h[k] = x;
}

static HeapItem hpop(HeapItem *h, int64_t *n) {
    HeapItem top = h[0], x = h[--(*n)];
    int64_t k = 0;
    for (;;) {
        int64_t c = 2 * k + 1;
        if (c >= *n) break;
        if (c + 1 < *n && hless(h[c + 1], h[c])) c++;
        if (!hless(h[c], x)) break;
        h[k] = h[c];
        k = c;
    }
    if (*n > 0) h[k] = x;
    return top;
}

static int64_t imax0(int64_t a) { return a > 0 ? a : 0; }

/* dt df da (track order) -> frame order, each a varint stream in o[0..2].
 * The order is a min-heap on (frame, track); every key is unique (one entry
 * per track at a time), so any correct heap pops what heapq pops. */
static int reorder(const P5Buf *hdr, const P5Buf *dt, const P5Buf *df, const P5Buf *da,
                   int64_t lock, int64_t ntr, Out o[3]) {
    Cur ch = {hdr->p, hdr->n, 0, 0};
    Cur cs[3] = {{dt->p, dt->n, 0, 0}, {df->p, df->n, 0, 0}, {da->p, da->n, 0, 0}};
    int64_t *start = NULL, *nk = NULL, *base = NULL, *last = NULL, *got = NULL, *key = NULL;
    HeapItem *heap = NULL;
    int64_t i, j, nkeys = 0, hn = 0, s = 0;
    int rc = P5_PACK_OK;
    if (ntr < 0) return P5_PACK_SINE;
    if (ntr > 0) {
        start = (int64_t *)calloc((size_t)ntr, sizeof(int64_t));
        nk = (int64_t *)calloc((size_t)ntr, sizeof(int64_t));
        base = (int64_t *)calloc((size_t)ntr, sizeof(int64_t));
        last = (int64_t *)calloc((size_t)ntr, sizeof(int64_t));
        got = (int64_t *)calloc((size_t)ntr, sizeof(int64_t));
        heap = (HeapItem *)malloc((size_t)ntr * sizeof(HeapItem));
        if (!start || !nk || !base || !last || !got || !heap) { rc = P5_PACK_NOMEM; goto done; }
    }
    /* _key_order */
    for (i = 0; i < ntr; i++) {
        s += cur_v(&ch);
        nk[i] = cur_v(&ch);
        if (lock) cur_v(&ch);
        cur_v(&ch);
        cur_v(&ch);
        cur_raw(&ch);
        if (ch.err) { rc = P5_PACK_SINE; goto done; }
        start[i] = s;
        base[i] = nkeys;
        if (nk[i] > 1) nkeys += nk[i] - 1;
    }
    /* each track's keys, read in track order */
    if (nkeys > 0) {
        key = (int64_t *)malloc((size_t)nkeys * 3 * sizeof(int64_t));
        if (!key) { rc = P5_PACK_NOMEM; goto done; }
    }
    for (i = 0; i < nkeys; i++)
        for (j = 0; j < 3; j++) key[3 * i + j] = cur_v(&cs[j]);
    if (cs[0].err || cs[1].err || cs[2].err) { rc = P5_PACK_SINE; goto done; }
    for (i = 0; i < ntr; i++)
        if (nk[i] > 1) {
            HeapItem h = {imax0(start[i] - 1), i};
            hpush(heap, &hn, h);
        }
    while (hn > 0) {
        HeapItem h = hpop(heap, &hn);
        const int64_t *d = key + 3 * (base[h.i] + got[h.i]);
        i = h.i;
        for (j = 0; j < 3; j++) out_varint(&o[j], d[j]);
        last[i] += d[0];
        got[i]++;
        if (got[i] < nk[i] - 1) {
            HeapItem e = {imax0(start[i] + last[i] - 1), i};
            hpush(heap, &hn, e);
        }
    }
    for (j = 0; j < 3; j++)
        if (o[j].err) rc = o[j].err;
done:
    free(start); free(nk); free(base); free(last); free(got); free(heap); free(key);
    return rc;
}

/* ------------------------------------------------------------ _stream: varint length + LZMA */

static int put_stream(Out *o, const uint8_t *b, int64_t n, p5_lz_fn lz, void *ctx) {
    int64_t cap, z;
    uint8_t *buf;
    if (n <= 0) { out_varint(o, 0); return o->err; }
    cap = n + n / 8 + 1024;
    buf = (uint8_t *)malloc((size_t)cap);
    if (!buf) return P5_PACK_NOMEM;
    z = lz(ctx, b, n, buf, cap);
    if (z > cap) {
        free(buf);
        cap = z;
        buf = (uint8_t *)malloc((size_t)cap);
        if (!buf) return P5_PACK_NOMEM;
        z = lz(ctx, b, n, buf, cap);
        if (z != cap) { free(buf); return P5_PACK_LZ; }
    }
    if (z < 0) { free(buf); return P5_PACK_LZ; }
    out_varint(o, z);
    out_bytes(o, buf, z);
    free(buf);
    return o->err;
}

static void put_section(Out *o, const char *tag, const Out *payload) {
    out_bytes(o, tag, 4);
    out_varint(o, payload->n);
    out_bytes(o, payload->p, payload->n);
}

/* ------------------------------------------------------------ quant.edges (pc._xf_edges) */

static int cmp_i64(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : x > y;
}

/* np.unique(concat([0], round(geomspace(2, K, nbands + 1)).astype(int))),
 * geomspace as numpy 2.5 builds it: 10 ** linspace(log10(2), log10(K)),
 * linspace as arange * step + start with the last set to stop, then the
 * ends set to 2 and K exactly. */
int64_t p5_pack_edges(int64_t K, int64_t nbands, int64_t *ed) {
    int64_t num = nbands + 1, div = num - 1, i, m;
    double ls = log10(2.0), le = log10((double)K), delta = le - ls, step;
    if (nbands < 0 || K <= 0) return 0;
    step = div > 0 ? delta / (double)div : 0.0;
    ed[0] = 0;
    for (i = 0; i < num; i++) {
        double y, g;
        if (div > 0 && step == 0.0) y = (double)i / (double)div * delta + ls;
        else y = (double)i * step + ls;
        if (num > 1 && i == num - 1) y = le;
        g = pow(10.0, y);
        if (i == 0) g = 2.0;
        if (num > 1 && i == num - 1) g = (double)K;
        ed[1 + i] = (int64_t)nearbyint(g);
    }
    qsort(ed, (size_t)(num + 1), sizeof(int64_t), cmp_i64);
    m = 1;
    for (i = 1; i < num + 1; i++)
        if (ed[i] != ed[m - 1]) ed[m++] = ed[i];
    return m;
}

/* ------------------------------------------------------------ one LAYR section */

static int put_layer(Out *o, int64_t ci, const P5Layer *L) {
    int64_t F = L->frames, K = L->K, nbx = L->nbx, f, b, k, ne, nlive = 0, cap, nout;
    int64_t *ed = NULL;
    int32_t *d = NULL;
    uint8_t *ones = NULL, *lb = NULL, *live = NULL, *st = NULL, *buf = NULL;
    int has_dq = 0, rc = P5_PACK_OK;
    Out p = {0};
    if (F < 0 || K < 0 || nbx < 0 || L->nbands < 0) return P5_PACK_ARG;
    ed = (int64_t *)malloc((size_t)(L->nbands + 2) * sizeof(int64_t));
    if (!ed) return P5_PACK_NOMEM;
    ne = p5_pack_edges(K, L->nbands, ed);
    if (ne - 1 != nbx || ed[ne - 1] != K) { rc = P5_PACK_SHAPE; goto done; }
    if (F * nbx > 0) {
        d = (int32_t *)malloc((size_t)(F * nbx) * sizeof(int32_t));
        ones = (uint8_t *)malloc((size_t)(F * nbx));
        lb = (uint8_t *)malloc((size_t)(F * nbx));
        if (!d || !ones || !lb) { rc = P5_PACK_NOMEM; goto done; }
    }
    if (F * K > 0) {
        live = (uint8_t *)malloc((size_t)(F * K));
        if (!live) { rc = P5_PACK_NOMEM; goto done; }
    }
    /* the scale codes' frame deltas, the live band-frames, has_dq, coded_mask */
    for (f = 0; f < F; f++)
        for (b = 0; b < nbx; b++) {
            int64_t i = f * nbx + b, v = L->sc[i], dv = f ? v - (int64_t)L->sc[i - nbx] : v;
            int alive = L->sc[i] != L->dead, ok;
            if (dv >= ((int64_t)1 << 31) || dv <= -((int64_t)1 << 31)) { rc = P5_PACK_RANGE; goto done; }
            d[i] = (int32_t)dv;
            ones[i] = 1;
            lb[i] = (uint8_t)alive;
            if (alive && L->dq[i]) has_dq = 1;
            ok = alive && (L->snr - 1.5 * (double)L->dq[i] > 0);
            for (k = ed[b]; k < ed[b + 1]; k++) live[f * K + k] = (uint8_t)ok;
            if (ok) nlive += ed[b + 1] - ed[b];
        }
    for (k = 0; k < F * K; k++) {
        if (L->q[k] == INT32_MIN) { rc = P5_PACK_RANGE; goto done; }
        if (!live[k] && L->q[k]) { rc = P5_PACK_OUTSIDE; goto done; }
    }
    out_varint(&p, ci);
    out_varint(&p, L->M);
    out_varint(&p, L->K);
    out_varint(&p, L->nbands);
    out_varint(&p, (int64_t)nearbyint(L->snr * 100.0));     /* Python round(): half to even */
    out_varint(&p, L->dead);
    out_varint(&p, L->frames);
    out_varint(&p, L->seed);
    out_varint(&p, L->start);
    out_varint(&p, has_dq);
    /* the range coder, with pack.py's buffer: an overflow there is one here */
    cap = 64 + 8 * (2 * F * nbx + nlive);
    st = (uint8_t *)malloc((size_t)p5rc_state_size());
    buf = (uint8_t *)malloc((size_t)cap);
    if (!st || !buf) { rc = P5_PACK_NOMEM; goto done; }
    p5rc_enc_init(st, buf, cap);
    if (p5rc_enc_grid(st, GRID_SC, F, nbx, d, ones) < 0) { rc = P5_PACK_RC; goto done; }
    if (has_dq && p5rc_enc_grid(st, GRID_SC, F, nbx, L->dq, lb) < 0) { rc = P5_PACK_RC; goto done; }
    if (p5rc_enc_grid(st, GRID_Q, F, K, L->q, live) < 0) { rc = P5_PACK_RC; goto done; }
    nout = p5rc_enc_finish(st);
    if (nout < 0) { rc = P5_PACK_RC; goto done; }
    out_bytes(&p, buf, nout);
    if (p.err) { rc = p.err; goto done; }
    put_section(o, "LAYR", &p);
    rc = o->err;
done:
    free(ed); free(d); free(ones); free(lb); free(live); free(st); free(buf);
    out_free(&p);
    return rc;
}

/* ------------------------------------------------------------ one SINE section */

static int put_sine(Out *o, int64_t ci, const P5Sine *S, p5_lz_fn lz, void *ctx) {
    Out p = {0}, r[3] = {{0}, {0}, {0}};
    const P5Buf *b[5];
    int i, rc;
    out_varint(&p, ci);
    for (i = 0; i < P5S_NINTS; i++) out_varint(&p, S->ints[i]);
    rc = reorder(&S->s[P5S_HDR], &S->s[P5S_DT], &S->s[P5S_DF], &S->s[P5S_DA],
                 S->ints[P5S_LOCK], S->ints[P5S_N_TRACKS], r);
    if (!rc) {
        P5Buf rb[3];
        for (i = 0; i < 3; i++) { rb[i].p = r[i].p; rb[i].n = r[i].n; }
        b[0] = &S->s[P5S_HDR]; b[1] = &rb[0]; b[2] = &rb[1]; b[3] = &rb[2]; b[4] = &S->s[P5S_F0];
        for (i = 0; i < 5 && !rc; i++) rc = put_stream(&p, b[i]->p, b[i]->n, lz, ctx);
    }
    if (!rc) rc = p.err;
    if (!rc) {
        put_section(o, "SINE", &p);
        rc = o->err;
    }
    out_free(&p);
    for (i = 0; i < 3; i++) out_free(&r[i]);
    return rc;
}

/* ------------------------------------------------------------ the file */

int p5_pack_layer(int64_t ci, const P5Layer *L, P5Buf *sec) {
    Out o = {0};
    int rc;
    if (!sec) return P5_PACK_ARG;
    sec->p = NULL;
    sec->n = 0;
    if (!L) return P5_PACK_ARG;
    rc = put_layer(&o, ci, L);
    if (!rc) rc = o.err;
    if (rc) { out_free(&o); return rc; }
    sec->p = o.p;
    sec->n = o.n;
    return P5_PACK_OK;
}

int p5_pack(const P5Note *note, p5_lz_fn lz, void *ctx, P5Buf *out) {
    return p5_pack_secs(note, lz, ctx, NULL, out);
}

int p5_pack_secs(const P5Note *note, p5_lz_fn lz, void *ctx, const P5Buf *const *secs, P5Buf *out) {
    Out o = {0};
    int64_t ci, li, j = 0;
    int rc = P5_PACK_OK;
    if (!out) return P5_PACK_ARG;
    out->p = NULL;
    out->n = 0;
    if (!note || !lz || note->nch < 0 || note->nch > 2) return P5_PACK_ARG;
    out_bytes(&o, MAGIC, 4);
    out_varint(&o, VERSION);
    out_varint(&o, note->sr);
    out_varint(&o, note->n);
    out_varint(&o, note->stereo);
    out_varint(&o, note->nch);
    for (ci = 0; ci < note->nch && !rc; ci++) {
        const P5Channel *ch = &note->ch[ci];
        if (ch->sines) rc = put_sine(&o, ci, ch->sines, lz, ctx);
        for (li = 0; li < ch->nlayers && !rc; li++, j++) {
            const P5Buf *s = secs ? secs[j] : NULL;
            if (s) {
                out_bytes(&o, s->p, s->n);
                rc = o.err;
            } else rc = put_layer(&o, ci, &ch->layers[li]);
        }
    }
    if (!rc) rc = o.err;
    if (rc) { out_free(&o); return rc; }
    out->p = o.p;
    out->n = o.n;
    return P5_PACK_OK;
}

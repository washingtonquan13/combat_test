/* PINST5 decoder (agent F): a C99 port of p5/decode.py and the decode halves
   it calls (pack.unpack, analysis.tracks_of / render_sines with
   pinst_codec.synth_tracks' "integrate" mode, quant.dequantize,
   transform.inverse). p5dec.h is the interface; decode.py is the reference.

   Build (MinGW, with p5rc.c beside it and the LZMA SDK decoder):
     gcc -O2 -DP5DEC_DLL -shared -o p5dec.dll p5dec.c p5rc.c \
         $LZ/Lzma2Dec.c $LZ/LzmaDec.c -I$LZ -lm
   where LZ is sfpp_test/native/vendor/lzma. Nothing here is Windows-only;
   it also builds as C++.

   What is decoded when.
   * p5_parse decodes the LZMA sine streams (to per-track keys; a track's
     integrated phase is kept every CP frames). Of the range-coded layer
     grids it decodes the scale codes and step offsets once, to keep the
     coder state at the start of each grid and the per-frame tables; no
     grid is kept frame by frame. Transform tables are shared by every note
     of a layer length.
   * A voice decodes a layer's grids row by row as it plays (a cursor holding
     the last three rows), plus a bookmark: a copy of the cursor at the frame
     it was last seeked to. A row behind the cursor restarts from the
     bookmark when it can, from frame 0 when not.
   * p5_seek sets where the bookmark falls, and each sounding track's
     oscillator from its nearest phase checkpoint (at most CP frame steps).
   * p5_render runs one complex oscillator per sounding track (exact for the
     reference's quadratic phase, re-aimed every hop), and per layer
     dequantizes and inverse-transforms (FFT) one frame per M samples.
   A voice keeps the sine state at the last seek and the bookmark, so a loop
   that wraps to the same point decodes only from there. */
#include "p5dec.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <pthread.h>
#endif
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "Lzma2Dec.h"

#ifdef __cplusplus
extern "C" {
#endif
/* the range coder's decode half (p5rc.c; its state is opaque) */
int64_t p5rc_state_size(void);
void p5rc_dec_init(void* s, const uint8_t* in, int64_t len);
void p5rc_dec_grid(void* s, int64_t kind, int64_t F, int64_t K, const uint8_t* mk, int32_t* v);
int64_t p5rc_model_size(void);
void p5rc_model_init(void* m, int64_t kind);
void p5rc_dec_row(void* s, void* m, int64_t f, int64_t K, const uint8_t* mk0, int32_t* v0,
                  const uint8_t* mk1, const int32_t* v1, const uint8_t* mk2, const int32_t* v2);
#ifdef __cplusplus
}
#endif

/* The hot loops (oscillators, FFT) are written once as always-inline bodies
   and built twice where GCC/Clang target x86: generic, and for AVX2+FMA,
   picked at parse by the CPU. Elsewhere (MSVC, ARM) only the generic build
   exists. -DP5DEC_NO_SIMD, or P5DEC_GENERIC=1 in the environment at parse,
   forces the generic one. */
#if defined(__GNUC__) || defined(__clang__)
#define P5_INLINE inline __attribute__((always_inline))
#elif defined(_MSC_VER)
#define P5_INLINE __forceinline
#else
#define P5_INLINE inline
#endif
#if (defined(__GNUC__) || defined(__clang__)) && (defined(__x86_64__) || defined(__i386__)) && !defined(P5DEC_NO_SIMD)
#define P5_X86 1
#define P5_AVX2 __attribute__((target("avx2,fma")))
#endif

#define PI_ 3.141592653589793
#define TWO_PI_ (2.0 * 3.141592653589793)
#define CP 8        /* frames between a track's phase checkpoints */
#define G 8         /* tracks per oscillator group */
#define CHUNK 256   /* samples rendered per inner pass */
#define RING_SPAN 1024 /* a voice keeps every layer's frames for this many samples */

/* ------------------------------------------------------------------ note */

typedef struct { int32_t key, qc, qa; } Key;

typedef struct {
    int64_t start;  /* first frame */
    int32_t L;      /* frames */
    int32_t nk;     /* keys (>= 1) */
    int32_t k0;     /* first key in Sines.keys */
    int32_t c0;     /* first checkpoint in Sines.cps */
    double ph0;     /* phase at frame 0 */
    double hh;      /* harmonic number (lock) */
} Track;

typedef struct {
    int H, lock, ntr, maxact;
    double f_c, a_d, T, sr;
    Track* tr;      /* sorted by start */
    Key* keys;
    double* cps;    /* integrated phase (less ph0) at frames 0, CP, 2CP, .. */
    double* f0q;    /* lock: the pitch curve, Hz per frame */
    int64_t f0n;
} Sines;

typedef struct {
    int M, K, nbx, mi, ring, has_dq;
    int64_t F, start, dead;
    uint32_t seed;
    double snr;
    int32_t* edges;     /* nbx + 1 */
    char* rst;          /* range-coder states at the start of the scale, step and coefficient grids */
    double* rmsT;       /* 10 ** ((dead + sc) * 1.5 / 20) by stored sc */
    double* stepT;      /* 10 ** (-(snr - 1.5 dq) / 20) by dq - dqmin */
    int dqmin;
    size_t lzsz;        /* bytes of one row cursor (Lz) */
} Layer;

typedef struct {
    Sines* s;
    Layer* lay;
    int nl;
} Chan;

typedef struct {        /* inverse-transform tables for one M; FFT ones when M is a power of two */
    int M, fft;
    double *prc, *prs;  /* pre-twiddle exp(-i pi (4m + 1) / 4M), m < M/2 */
    double *poc, *pos;  /* post-twiddle exp(-i pi m / M) */
    double *twr, *twi;  /* FFT stage of half-length h at [h, 2h): exp(-i pi j / h) */
    double* win;        /* sin(pi (i + 0.5) / 2M), i < M (the rest by symmetry) */
    int32_t* br;        /* bit reversal of m < M/2 */
} Tab;

struct p5_note {
    int sr, stereo, nch;
    int64_t n;
    Chan ch[2];
    int nm;             /* distinct layer lengths */
    int Ms[16];
    const Tab* tabs[16]; /* by Layer.mi; one per length for the whole process */
    uint8_t* ones;      /* the scale grid's mask row: widest nbx */
    int simd;          /* use the AVX2+FMA builds of the hot loops */
    size_t mem;
};

/* ------------------------------------------------------------------ voice */

typedef struct {        /* per sounding track, structure of arrays */
    double *zr, *zi, *rr, *ri, *qr, *qi, *a, *ai, *we, *ae;
    int32_t *tid, *s, *kj;
} TArr;

typedef struct {
    int cap;            /* multiple of G */
    int na, next, t, valid;
    int64_t g;
    TArr x;
    char* blk;          /* the arrays above */
    char* snap;         /* the same arrays at the last seek */
    size_t blksz;
    int snap_ok, snap_na, snap_next, snap_t;
    int64_t snap_g, snap_pos;
} SineVoice;

typedef struct {
    float* data;        /* ring x 2M */
    int64_t* idx;
    uint64_t* stamp;
} Ring;

/* A layer's grids decoded row by row. One block (Layer.lzsz bytes, so a
   bookmark is a copy): the last row decoded, the three grids' coder states
   and models, and rows last-2 .. last of each grid (row r in slot r % 3). */
typedef struct {
    int64_t* last;      /* -1: nothing decoded */
    char *st, *md;      /* 3 each: scale, step, coefficient grid */
    int32_t* sd;        /* 3 x nbx: scale-code deltas (the grid's values) */
    int32_t* ss;        /* 3 x nbx: scale code less dead */
    uint8_t* sm;        /* 3 x nbx: ss != 0 (the step grid's mask) */
    int32_t* dv;        /* 3 x nbx: step offsets (0 without a step grid) */
    int32_t* qv;        /* 3 x K: coefficient codes */
    uint8_t* qm;        /* 3 x K: coded */
} Lz;

typedef struct {
    char* cur;          /* the cursor */
    char* bm;           /* the cursor at row `want` (the first row the last seek needs) */
    int bm_ok;
    int64_t want;
} LzV;

struct p5_voice {
    const p5_note* note;
    int64_t pos;
    uint64_t clock;
    SineVoice sv[2];
    Ring* rings[2];
    LzV* lz[2];
    double* acc[2];
    double *X, *buf;    /* frame scratch: Mmax each */
    int32_t* qi;        /* a frame's coefficient codes: Mmax */
};

/* ------------------------------------------------------------------ helpers */

typedef struct { const uint8_t* b; size_t n, i; int bad; } Cur;

static int64_t cv(Cur* c) {
    uint64_t z = 0;
    int sh = 0;
    for (;;) {
        if (c->i >= c->n || sh > 63) { c->bad = 1; return 0; }
        uint8_t x = c->b[c->i++];
        z |= (uint64_t)(x & 0x7F) << sh;
        sh += 7;
        if (x < 128) break;
    }
    return (int64_t)(z >> 1) ^ -(int64_t)(z & 1);
}

static int craw(Cur* c) {
    if (c->i >= c->n) { c->bad = 1; return 0; }
    return c->b[c->i++];
}

static void* nalloc(p5_note* nt, size_t n) {
    void* p = calloc(n ? n : 1, 1);
    if (p) nt->mem += n;
    return p;
}

static void* sz_alloc(ISzAllocPtr p, size_t n) { (void)p; return malloc(n); }
static void sz_free(ISzAllocPtr p, void* a) { (void)p; free(a); }

/* raw LZMA2 -> malloc'd bytes (NULL and *n = 0 for an empty stream) */
static int unlz(const uint8_t* src, size_t n, uint8_t** out, size_t* outn) {
    *out = NULL;
    *outn = 0;
    if (!n) return 1;
    size_t total = 0, i = 0;
    for (;;) {
        if (i >= n) return 0;
        uint8_t c = src[i];
        if (c == 0) break;
        if (c < 0x80) {
            if (c > 2 || i + 3 > n) return 0;
            size_t len = ((size_t)src[i + 1] << 8 | src[i + 2]) + 1;
            total += len;
            i += 3 + len;
        } else {
            if (i + 5 > n) return 0;
            total += ((size_t)(c & 0x1F) << 16 | (size_t)src[i + 1] << 8 | src[i + 2]) + 1;
            size_t packed = ((size_t)src[i + 3] << 8 | src[i + 4]) + 1;
            i += 5 + (c >= 0xC0 ? 1 : 0) + packed;
        }
    }
    uint8_t* o = (uint8_t*)malloc(total ? total : 1);
    if (!o) return 0;
    static const ISzAlloc alloc = {sz_alloc, sz_free};
    SizeT dl = total, sl = n;
    ELzmaStatus st;
    SRes r = Lzma2Decode(o, &dl, src, &sl, 40, LZMA_FINISH_END, &st, &alloc);
    if (r != SZ_OK || dl != total) { free(o); return 0; }
    *out = o;
    *outn = total;
    return 1;
}

/* np.interp at integer x over nondecreasing xp (fp from fpv(j)) */
static double interp_k(const Key* K, int nk, double scale, int which, int64_t x, int* hint) {
    int j = *hint;
    if (j < 0) j = 0;
    while (j + 1 < nk && K[j + 1].key <= x) j++;
    *hint = j;
    double f0 = (double)(which ? K[j].qa : K[j].qc) * scale;
    if (j == nk - 1 || x < K[0].key) return x < K[0].key ? (double)(which ? K[0].qa : K[0].qc) * scale : f0;
    double f1 = (double)(which ? K[j + 1].qa : K[j + 1].qc) * scale;
    double slope = (f1 - f0) / ((double)K[j + 1].key - (double)K[j].key);
    return slope * ((double)x - (double)K[j].key) + f0;
}

/* w (radians per sample) and linear amplitude of track t at frame i */
static void frame_wa(const Sines* S, const Track* t, int64_t i, int* kj, double* w, double* amp) {
    const Key* K = S->keys + t->k0;
    int h = *kj;
    double c = interp_k(K, t->nk, S->f_c, 0, i, &h);
    double ref = S->lock ? t->hh * S->f0q[t->start + i] : 20.0;
    double f = ref * exp2(c / 1200.0);
    *w = TWO_PI_ * f / S->sr;
    if (amp) {
        int h2 = *kj;
        double d = interp_k(K, t->nk, S->a_d, 1, i, &h2);
        *amp = exp(d * (2.302585092994046 / 20.0));
    }
    *kj = h;
}

static uint32_t hash_u32(uint32_t seed, uint64_t c) {
    uint32_t x = (uint32_t)(c * 0x9E3779B9ull + seed);
    x ^= x >> 16;
    x *= 0x85EBCA6Bu;
    x ^= x >> 13;
    x *= 0xC2B2AE35u;
    x ^= x >> 16;
    return x;
}

typedef struct { char* base; size_t off; } Bump;

static void* bump(Bump* b, size_t n) {
    size_t o = (b->off + 63) & ~(size_t)63;
    b->off = o + n;
    return b->base ? (void*)(b->base + o) : NULL;
}

/* layer L's row cursor in the block at base (NULL: only its size) */
static size_t lz_bind(const Layer* L, char* base, Lz* z) {
    Bump b = {base, 0};
    size_t ss = (size_t)p5rc_state_size(), ms = (size_t)p5rc_model_size();
    size_t nb = (size_t)L->nbx, K = (size_t)L->K;
    int64_t* last = (int64_t*)bump(&b, sizeof(int64_t));
    char* st = (char*)bump(&b, 3 * ss);
    char* md = (char*)bump(&b, 3 * ms);
    int32_t* sd = (int32_t*)bump(&b, 3 * nb * sizeof(int32_t));
    int32_t* sv = (int32_t*)bump(&b, 3 * nb * sizeof(int32_t));
    uint8_t* sm = (uint8_t*)bump(&b, 3 * nb);
    int32_t* dv = (int32_t*)bump(&b, 3 * nb * sizeof(int32_t));
    int32_t* qv = (int32_t*)bump(&b, 3 * K * sizeof(int32_t));
    uint8_t* qm = (uint8_t*)bump(&b, 3 * K);
    if (z) {
        z->last = last; z->st = st; z->md = md; z->sd = sd; z->ss = sv;
        z->sm = sm; z->dv = dv; z->qv = qv; z->qm = qm;
    }
    return b.off;
}

/* ------------------------------------------------------------------ parse */

static void sines_free(Sines* s) {
    if (!s) return;
    free(s->tr);
    free(s->keys);
    free(s->cps);
    free(s->f0q);
    free(s);
}

static void layer_free(Layer* L) {
    free(L->edges);
    free(L->rst);
    free(L->rmsT);
    free(L->stepT);
}

void p5_note_free(p5_note* nt) {
    if (!nt) return;
    for (int c = 0; c < 2; c++) {
        sines_free(nt->ch[c].s);
        for (int l = 0; l < nt->ch[c].nl; l++) layer_free(&nt->ch[c].lay[l]);
        free(nt->ch[c].lay);
    }
    free(nt->ones);
    free(nt);
}

typedef struct { int64_t key; int32_t i; } HE;

static int he_less(HE a, HE b) { return a.key < b.key || (a.key == b.key && a.i < b.i); }

static void heap_push(HE* h, int* n, HE e) {
    int i = (*n)++;
    while (i) {
        int p = (i - 1) / 2;
        if (!he_less(e, h[p])) break;
        h[i] = h[p];
        i = p;
    }
    h[i] = e;
}

static HE heap_pop(HE* h, int* n) {
    HE top = h[0], e = h[--(*n)];
    int i = 0;
    for (;;) {
        int c = 2 * i + 1;
        if (c >= *n) break;
        if (c + 1 < *n && he_less(h[c + 1], h[c])) c++;
        if (!he_less(h[c], e)) break;
        h[i] = h[c];
        i = c;
    }
    if (*n) h[i] = e;
    return top;
}

static int track_cmp(const void* a, const void* b) {
    const Track *x = (const Track*)a, *y = (const Track*)b;
    if (x->start != y->start) return x->start < y->start ? -1 : 1;
    return x->k0 < y->k0 ? -1 : x->k0 > y->k0;
}

static const char* parse_sine(p5_note* nt, Cur* body) {
    int64_t ci = cv(body);
    int64_t I[8];
    for (int k = 0; k < 8; k++) I[k] = cv(body);
    if (body->bad) return "truncated SINE section";
    if (ci < 0 || ci >= nt->nch) return "SINE channel out of range";
    int64_t H = I[0], pbits = I[4], lock = I[5], f0n = I[6], ntr = I[7];
    if (H <= 0 || H > (1 << 20) || pbits < 0 || pbits > 62 || f0n < 0 || ntr < 0 || ntr > (1 << 24) || f0n > (1 << 28))
        return "bad SINE parameters";
    uint8_t* st[5] = {0, 0, 0, 0, 0};
    size_t sn[5] = {0, 0, 0, 0, 0};
    const char* err = NULL;
    for (int k = 0; k < 5 && !err; k++) {
        int64_t len = cv(body);
        if (body->bad || len < 0 || (uint64_t)len > body->n - body->i) { err = "truncated SINE stream"; break; }
        if (!unlz(body->b + body->i, (size_t)len, &st[k], &sn[k])) err = "bad LZMA2 stream";
        body->i += (size_t)len;
    }
    Sines* S = NULL;
    HE* heap = NULL;
    int64_t* last = NULL;
    int32_t* got = NULL;
    int32_t* qc0 = NULL;
    double f0_c = (double)I[3] / 1000;
    if (err) goto done;
    S = (Sines*)calloc(1, sizeof(Sines));
    if (!S) { err = "out of memory"; goto done; }
    nt->mem += sizeof(Sines);
    S->H = (int)H;
    S->T = (double)H;
    S->lock = lock != 0;
    S->f_c = (double)I[1] / 1000;
    S->a_d = (double)I[2] / 1000;
    S->sr = (double)nt->sr;
    S->ntr = (int)ntr;
    if (S->lock) {     /* the pitch curve: _pairs, then expand */
        Cur c = {st[4], sn[4], 0, 0};
        int64_t np_ = 0, cap = 0;
        int64_t* kk = NULL;
        int64_t* qq = NULL;
        int64_t ak = 0, aq = 0;
        while (c.i < c.n) {
            ak += cv(&c);
            aq += cv(&c);
            if (c.bad) break;
            if (np_ == cap) {
                cap = cap ? 2 * cap : 64;
                int64_t* k2 = (int64_t*)realloc(kk, (size_t)cap * sizeof(int64_t));
                int64_t* q2 = (int64_t*)realloc(qq, (size_t)cap * sizeof(int64_t));
                if (k2) kk = k2;
                if (q2) qq = q2;
                if (!k2 || !q2) { c.bad = 1; break; }
            }
            if (np_ && ak < kk[np_ - 1]) { c.bad = 1; break; }
            kk[np_] = ak;
            qq[np_] = aq;
            np_++;
        }
        if (c.bad || !np_) err = "bad pitch curve";
        else {
            S->f0n = f0n;
            S->f0q = (double*)nalloc(nt, (size_t)(f0n ? f0n : 1) * sizeof(double));
            if (!S->f0q) err = "out of memory";
            else {
                int64_t j = 0;
                for (int64_t x = 0; x < f0n; x++) {
                    double v;
                    while (j + 1 < np_ && kk[j + 1] <= x) j++;
                    if (x < kk[0]) v = (double)qq[0] * f0_c;
                    else if (j == np_ - 1) v = (double)qq[j] * f0_c;
                    else {
                        double a = (double)qq[j] * f0_c, b = (double)qq[j + 1] * f0_c;
                        v = (b - a) / ((double)kk[j + 1] - (double)kk[j]) * ((double)x - (double)kk[j]) + a;
                    }
                    S->f0q[x] = 20.0 * pow(2.0, v / 1200);
                }
            }
        }
        free(kk);
        free(qq);
        if (err) goto done;
    }
    /* track headers */
    S->tr = (Track*)nalloc(nt, (size_t)(ntr ? ntr : 1) * sizeof(Track));
    if (!S->tr) { err = "out of memory"; goto done; }
    {
        Cur c = {st[0], sn[0], 0, 0};
        int64_t start = 0, nkeys = 0;
        qc0 = (int32_t*)malloc((size_t)(ntr ? ntr : 1) * 3 * sizeof(int32_t));
        if (!qc0) { err = "out of memory"; goto done; }
        for (int64_t i = 0; i < ntr; i++) {
            Track* t = &S->tr[i];
            start += cv(&c);
            int64_t nk = cv(&c);
            int64_t hh = S->lock ? cv(&c) : 0;
            int64_t qc = cv(&c), qa = cv(&c);
            int qph = craw(&c);
            if (c.bad || start < 0 || nk < 0 || nk > (1 << 24) || qc != (int32_t)qc || qa != (int32_t)qa) { err = "bad track header"; break; }
            t->start = start;
            t->nk = nk > 1 ? (int32_t)nk : 1;
            t->k0 = (int32_t)nkeys;
            t->hh = (double)hh;
            t->ph0 = (double)qph / (double)((int64_t)1 << pbits) * TWO_PI_;
            qc0[3 * i] = (int32_t)qc;
            qc0[3 * i + 1] = (int32_t)qa;
            nkeys += t->nk;
            if (nkeys > (1 << 28)) { err = "too many keys"; break; }
        }
        if (!err) {
            S->keys = (Key*)nalloc(nt, (size_t)(nkeys ? nkeys : 1) * sizeof(Key));
            if (!S->keys) err = "out of memory";
        }
        if (!err)
            for (int64_t i = 0; i < ntr; i++) {
                Key* K = S->keys + S->tr[i].k0;
                K[0].key = 0;
                K[0].qc = qc0[3 * i];
                K[0].qa = qc0[3 * i + 1];
            }
    }
    free(qc0);
    if (err) goto done;
    /* dt df da: frame order back to track order (pinst_file._reorder) */
    heap = (HE*)malloc((size_t)(ntr ? ntr : 1) * sizeof(HE));
    last = (int64_t*)calloc((size_t)(ntr ? ntr : 1), sizeof(int64_t));
    got = (int32_t*)calloc((size_t)(ntr ? ntr : 1), sizeof(int32_t));
    if (!heap || !last || !got) { err = "out of memory"; goto done; }
    {
        int nh = 0;
        for (int64_t i = 0; i < ntr; i++)
            if (S->tr[i].nk > 1) {
                HE e = {S->tr[i].start - 1 > 0 ? S->tr[i].start - 1 : 0, (int32_t)i};
                heap_push(heap, &nh, e);
            }
        Cur ct = {st[1], sn[1], 0, 0}, cf = {st[2], sn[2], 0, 0}, ca = {st[3], sn[3], 0, 0};
        while (nh) {
            HE e = heap_pop(heap, &nh);
            Track* t = &S->tr[e.i];
            int64_t dt = cv(&ct), df = cv(&cf), da = cv(&ca);
            if (ct.bad || cf.bad || ca.bad || dt < 0) { err = "bad track keys"; break; }
            Key* K = S->keys + t->k0;
            int j = ++got[e.i];
            int64_t k = (int64_t)K[j - 1].key + dt, q1 = (int64_t)K[j - 1].qc + df, q2 = (int64_t)K[j - 1].qa + da;
            if (k != (int32_t)k || q1 != (int32_t)q1 || q2 != (int32_t)q2) { err = "bad track keys"; break; }
            K[j].key = (int32_t)k;
            K[j].qc = (int32_t)q1;
            K[j].qa = (int32_t)q2;
            last[e.i] += dt;
            if (j < t->nk - 1) {
                int64_t key = t->start + last[e.i] - 1;
                HE e2 = {key > 0 ? key : 0, e.i};
                heap_push(heap, &nh, e2);
            }
        }
    }
    if (err) goto done;
    /* frames, checkpoints */
    {
        int64_t ncp = 0;
        for (int64_t i = 0; i < ntr; i++) {
            Track* t = &S->tr[i];
            int64_t L = (int64_t)S->keys[t->k0 + t->nk - 1].key + 1;
            if (L > (1 << 26) || t->start + L > ((int64_t)1 << 40)) { err = "track too long"; break; }
            if (S->lock && t->start + L > S->f0n) { err = "track past the pitch curve"; break; }
            t->L = (int32_t)L;
            t->c0 = (int32_t)ncp;
            ncp += (L - 1) / CP + 1;
            if (ncp > (1 << 28)) { err = "too many frames"; break; }
        }
        if (err) goto done;
        S->cps = (double*)nalloc(nt, (size_t)(ncp ? ncp : 1) * sizeof(double));
        if (!S->cps) { err = "out of memory"; goto done; }
        for (int64_t i = 0; i < ntr; i++) {
            Track* t = &S->tr[i];
            int kj = 0;
            double wp, wi, c = 0.0;
            frame_wa(S, t, 0, &kj, &wp, NULL);
            S->cps[t->c0] = 0.0;
            for (int64_t f = 1; f < t->L; f++) {
                frame_wa(S, t, f, &kj, &wi, NULL);
                double inc = 0.5 * (wi + wp) * S->T;
                c = f == 1 ? inc : c + inc;
                if (f % CP == 0) S->cps[t->c0 + f / CP] = c;
                wp = wi;
            }
        }
    }
    /* sounding order, and the most tracks sounding at once */
    {
        int sorted = 1;
        for (int64_t i = 1; i < ntr; i++)
            if (S->tr[i].start < S->tr[i - 1].start) sorted = 0;
        if (!sorted) qsort(S->tr, (size_t)ntr, sizeof(Track), track_cmp);
        int64_t hmax = 0;
        for (int64_t i = 0; i < ntr; i++) {
            int64_t e = S->tr[i].start - 1 + S->tr[i].L;
            if (e > hmax) hmax = e;
        }
        int32_t* d = (int32_t*)calloc((size_t)hmax + 3, sizeof(int32_t));
        if (!d) { err = "out of memory"; goto done; }
        for (int64_t i = 0; i < ntr; i++) {
            int64_t a = S->tr[i].start - 1, b = a + S->tr[i].L;
            if (a < 0) a = 0;
            d[a]++;
            d[b + 1]--;
        }
        int run = 0, mx = 0;
        for (int64_t h = 0; h <= hmax + 1; h++) {
            run += d[h];
            if (run > mx) mx = run;
        }
        free(d);
        S->maxact = mx;
    }
done:
    for (int k = 0; k < 5; k++) free(st[k]);
    free(heap);
    free(last);
    free(got);
    if (err) {
        sines_free(S);
        return err;
    }
    if (nt->ch[ci].s) {     /* a later SINE for the channel replaces it, as unpack does */
        Sines* o = nt->ch[ci].s;
        sines_free(o);
    }
    nt->ch[ci].s = S;
    return NULL;
}

/* pinst_codec._xf_edges: unique([0] + round(geomspace(2, K, nb + 1))) */
static int xf_edges(int K, int nb, int32_t* out) {
    double lo = log10(2.0), hi = log10((double)K);
    double step = (hi - lo) / nb;
    int32_t v[1 + 512];
    v[0] = 0;
    for (int i = 0; i <= nb; i++) {
        double y = i == nb ? hi : (double)i * step + lo;
        double g = pow(10.0, y);
        if (i == 0) g = 2.0;
        if (i == nb) g = (double)K;
        v[1 + i] = (int32_t)nearbyint(g);
    }
    int n = nb + 2;     /* sort (insertion), unique */
    for (int i = 1; i < n; i++) {
        int32_t x = v[i];
        int j = i - 1;
        while (j >= 0 && v[j] > x) { v[j + 1] = v[j]; j--; }
        v[j + 1] = x;
    }
    int m = 0;
    for (int i = 0; i < n; i++)
        if (!m || v[i] != out[m - 1]) out[m++] = v[i];
    return m;
}

static const char* parse_layer(p5_note* nt, Cur* body) {
    int64_t I[10];
    for (int k = 0; k < 10; k++) I[k] = cv(body);
    if (body->bad) return "truncated LAYR section";
    int64_t ci = I[0], M = I[1], K = I[2], nb = I[3], snr = I[4], dead = I[5], F = I[6], seed = I[7], start = I[8], has_dq = I[9];
    if (ci < 0 || ci >= nt->nch) return "LAYR channel out of range";
    if (M < 2 || M > (1 << 16) || K < 2 || K > M || nb < 1 || nb > 510 || F < 0 || start < 0 || F * K > ((int64_t)1 << 28))
        return "bad LAYR parameters";
    Chan* ch = &nt->ch[ci];
    Layer* nl = (Layer*)realloc(ch->lay, (size_t)(ch->nl + 1) * sizeof(Layer));
    if (!nl) return "out of memory";
    ch->lay = nl;
    Layer* L = &ch->lay[ch->nl];
    memset(L, 0, sizeof *L);
    ch->nl++;
    nt->mem += sizeof(Layer);
    L->M = (int)M;
    L->K = (int)K;
    L->F = F;
    L->start = start;
    L->dead = dead;
    L->seed = (uint32_t)seed;
    L->snr = (double)snr / 100;
    int32_t ed[512 + 2];
    int ne = xf_edges((int)K, (int)nb, ed);
    if (ed[ne - 1] != K) return "bad band edges";
    int nbx = ne - 1;
    L->nbx = nbx;
    L->edges = (int32_t*)nalloc(nt, (size_t)ne * sizeof(int32_t));
    if (!L->edges) return "out of memory";
    memcpy(L->edges, ed, (size_t)ne * sizeof(int32_t));
    {
        int m;
        for (m = 0; m < nt->nm; m++)
            if (nt->Ms[m] == L->M) break;
        if (m == nt->nm) {
            if (nt->nm == 16) return "too many layer lengths";
            nt->Ms[nt->nm++] = L->M;
        }
        L->mi = m;
        int r = (RING_SPAN + L->M - 1) / L->M + 2;
        L->ring = r < 3 ? 3 : r;
    }
    L->has_dq = has_dq != 0;
    /* The scale and step grids are decoded here only to find where the next
       grid starts in the stream and which levels and steps occur; voices
       decode all three grids row by row as they play (lz_row). */
    const char* err = NULL;
    size_t ss = (size_t)p5rc_state_size();
    void* rc = malloc(ss);
    size_t nbf = (size_t)F * (size_t)nbx;
    uint8_t* mk = (uint8_t*)malloc(nbf + 1);
    int32_t* v = (int32_t*)malloc((nbf + 1) * sizeof(int32_t));
    int32_t* dq = (int32_t*)calloc(nbf + 1, sizeof(int32_t));
    L->rst = (char*)nalloc(nt, 3 * ss);
    if (!rc || !mk || !v || !dq || !L->rst) { err = "out of memory"; goto done; }
    p5rc_dec_init(rc, body->b + body->i, (int64_t)(body->n - body->i));
    memcpy(L->rst, rc, ss);
    memset(mk, 1, nbf);
    p5rc_dec_grid(rc, 0, F, nbx, mk, v);
    int smax = 0;
    for (size_t b = 0; b < (size_t)nbx; b++) {    /* v becomes the scale code less dead */
        int64_t a = 0;
        for (int64_t f = 0; f < F; f++) {
            size_t i = (size_t)f * nbx + b;
            a += v[i];
            int64_t o = a - dead;
            if (o < 0 || o > 65535) { err = "scale code out of range"; goto done; }
            v[i] = (int32_t)o;
            if (o > smax) smax = (int)o;
        }
    }
    memcpy(L->rst + ss, rc, ss);
    if (has_dq) {
        for (size_t i = 0; i < nbf; i++) mk[i] = v[i] != 0;
        p5rc_dec_grid(rc, 0, F, nbx, mk, dq);
        for (size_t i = 0; i < nbf; i++)
            if (dq[i] < -32768 || dq[i] > 32767) { err = "step offset out of range"; goto done; }
    }
    memcpy(L->rst + 2 * ss, rc, ss);
    L->lzsz = lz_bind(L, NULL, NULL);
    {   /* the band levels and step factors this layer uses, as dequantize computes them */
        int dmin = 0, dmax = 0;
        for (size_t i = 0; i < nbf; i++) {
            if (dq[i] < dmin) dmin = dq[i];
            if (dq[i] > dmax) dmax = dq[i];
        }
        L->rmsT = (double*)nalloc(nt, ((size_t)smax + 1) * sizeof(double));
        L->stepT = (double*)nalloc(nt, ((size_t)(dmax - dmin) + 1) * sizeof(double));
        if (!L->rmsT || !L->stepT) { err = "out of memory"; goto done; }
        for (int s = 0; s <= smax; s++) L->rmsT[s] = pow(10.0, (double)(dead + s) * 1.5 / 20);
        for (int d = dmin; d <= dmax; d++) L->stepT[d - dmin] = pow(10.0, -(L->snr - 1.5 * (double)d) / 20);
        L->dqmin = dmin;
    }
done:
    free(rc);
    free(mk);
    free(v);
    free(dq);
    return err;
}

static int is_pow2(int M) { return M >= 4 && (M & (M - 1)) == 0; }

/* Transform tables depend only on the length, so each length's are built
   once for the process (on first use, under a lock) and never freed. */
typedef struct TabNode { Tab t; struct TabNode* next; } TabNode;
static TabNode* g_tabs;
#ifdef _WIN32
static SRWLOCK g_tab_lock = SRWLOCK_INIT;
#define TAB_LOCK() AcquireSRWLockExclusive(&g_tab_lock)
#define TAB_UNLOCK() ReleaseSRWLockExclusive(&g_tab_lock)
#else
static pthread_mutex_t g_tab_lock = PTHREAD_MUTEX_INITIALIZER;
#define TAB_LOCK() pthread_mutex_lock(&g_tab_lock)
#define TAB_UNLOCK() pthread_mutex_unlock(&g_tab_lock)
#endif

static TabNode* tab_make(int M) {
    int P = M / 2;
    size_t tot = sizeof(TabNode);
    if (is_pow2(M)) tot += (size_t)(6 * P + M) * sizeof(double) + (size_t)P * sizeof(int32_t);
    TabNode* n = (TabNode*)calloc(1, tot);
    if (!n) return NULL;
    char* p = (char*)(n + 1);
    Tab* t = &n->t;
    t->M = M;
    if (is_pow2(M)) {
        t->fft = 1;
        double* d = (double*)p;
        p += (size_t)(6 * P + M) * sizeof(double);
        t->prc = d; t->prs = d + P; t->poc = d + 2 * P; t->pos = d + 3 * P;
        t->twr = d + 4 * P; t->twi = d + 5 * P; t->win = d + 6 * P;
        t->br = (int32_t*)p;
        p += (size_t)P * sizeof(int32_t);
        int lg = 0;
        while ((1 << lg) < P) lg++;
        for (int i = 0; i < P; i++) {
            double a = PI_ * (4.0 * i + 1) / (4.0 * M), b = PI_ * i / M;
            t->prc[i] = cos(a);
            t->prs[i] = -sin(a);
            t->poc[i] = cos(b);
            t->pos[i] = -sin(b);
            int r = 0;
            for (int k = 0; k < lg; k++) r |= ((i >> k) & 1) << (lg - 1 - k);
            t->br[i] = r;
        }
        t->twr[0] = 1;
        t->twi[0] = 0;
        for (int h = 1; h < P; h *= 2)
            for (int j = 0; j < h; j++) {
                t->twr[h + j] = cos(PI_ * j / h);
                t->twi[h + j] = -sin(PI_ * j / h);
            }
        for (int i = 0; i < M; i++) t->win[i] = sin(PI_ * (i + 0.5) / (2 * M));
    }
    return n;
}

static const Tab* tab_get(int M) {
    TAB_LOCK();
    TabNode* n = g_tabs;
    while (n && n->t.M != M) n = n->next;
    if (!n && (n = tab_make(M)) != NULL) {
        n->next = g_tabs;
        g_tabs = n;
    }
    TAB_UNLOCK();
    return n ? &n->t : NULL;
}

/* every layer length's transform tables, and the scale grid's mask row */
static const char* note_tables(p5_note* nt) {
    for (int m = 0; m < nt->nm; m++)
        if (!(nt->tabs[m] = tab_get(nt->Ms[m]))) return "out of memory";
    int w = 1;
    for (int c = 0; c < nt->nch; c++)
        for (int l = 0; l < nt->ch[c].nl; l++)
            if (nt->ch[c].lay[l].nbx > w) w = nt->ch[c].lay[l].nbx;
    nt->ones = (uint8_t*)nalloc(nt, (size_t)w);
    if (!nt->ones) return "out of memory";
    memset(nt->ones, 1, (size_t)w);
    return NULL;
}

static int pick_simd(void) {
#ifdef P5_X86
    const char* g = getenv("P5DEC_GENERIC");
    if (g && *g && *g != '0') return 0;
    __builtin_cpu_init();
    return __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma");
#else
    return 0;
#endif
}

p5_note* p5_parse(const uint8_t* data, size_t size, const char** err) {
    const char* e = NULL;
    p5_note* nt = NULL;
    if (err) *err = NULL;
    if (!data || size < 4 || memcmp(data, "PIN5", 4) != 0) { e = "not a PINST5 file"; goto fail; }
    nt = (p5_note*)calloc(1, sizeof(p5_note));
    if (!nt) { e = "out of memory"; goto fail; }
    nt->mem = sizeof(p5_note);
    {
        Cur c = {data, size, 4, 0};
        int64_t ver = cv(&c), sr = cv(&c), n = cv(&c), stereo = cv(&c), nch = cv(&c);
        if (c.bad) { e = "truncated header"; goto fail; }
        if (ver != 1) { e = "unknown PINST5 version"; goto fail; }
        if (sr <= 0 || sr > 1000000 || n < 0 || nch < 1 || nch > 2 || stereo < 0 || stereo > 2 || (stereo == 1 && nch != 2)) {
            e = "bad header";
            goto fail;
        }
        nt->sr = (int)sr;
        nt->n = n;
        nt->stereo = (int)stereo;
        nt->nch = (int)nch;
        while (c.i < c.n) {
            if (c.n - c.i < 4) { e = "truncated section"; goto fail; }
            const uint8_t* tag = c.b + c.i;
            c.i += 4;
            int64_t len = cv(&c);
            if (c.bad || len < 0 || (uint64_t)len > c.n - c.i) { e = "truncated section"; goto fail; }
            Cur body = {c.b + c.i, (size_t)len, 0, 0};
            c.i += (size_t)len;
            if (!memcmp(tag, "SINE", 4)) e = parse_sine(nt, &body);
            else if (!memcmp(tag, "LAYR", 4)) e = parse_layer(nt, &body);
            if (e) goto fail;
        }
    }
    e = note_tables(nt);
    if (e) goto fail;
    nt->simd = pick_simd();
    return nt;
fail:
    if (err) *err = e;
    p5_note_free(nt);
    return NULL;
}

int p5_rate(const p5_note* nt) { return nt->sr; }
int p5_channels(const p5_note* nt) { return nt->nch; }
int64_t p5_frames(const p5_note* nt) { return nt->n; }
size_t p5_note_memory(const p5_note* nt) { return nt->mem; }

/* ------------------------------------------------------------------ voice layout */

static void tarr_bind(TArr* x, char* blk, int cap) {
    double* d = (double*)blk;
    x->zr = d; x->zi = d + cap; x->rr = d + 2 * cap; x->ri = d + 3 * cap; x->qr = d + 4 * cap;
    x->qi = d + 5 * cap; x->a = d + 6 * cap; x->ai = d + 7 * cap; x->we = d + 8 * cap; x->ae = d + 9 * cap;
    int32_t* i = (int32_t*)(d + 10 * cap);
    x->tid = i; x->s = i + cap; x->kj = i + 2 * cap;
}

static size_t voice_build(const p5_note* nt, p5_voice* v) {
    Bump b = {(char*)v, 0};
    bump(&b, sizeof(p5_voice));
    int Mmax = 4;
    for (int m = 0; m < nt->nm; m++)
        if (nt->Ms[m] > Mmax) Mmax = nt->Ms[m];
    for (int c = 0; c < nt->nch; c++) {
        const Chan* ch = &nt->ch[c];
        double* acc = (double*)bump(&b, CHUNK * sizeof(double));
        if (v) v->acc[c] = acc;
        if (ch->s) {
            int cap = (ch->s->maxact + G - 1) / G * G;
            if (cap < G) cap = G;
            size_t sz = (size_t)cap * (10 * sizeof(double) + 3 * sizeof(int32_t));
            char* blk = (char*)bump(&b, sz);
            char* snap = (char*)bump(&b, sz);
            if (v) {
                SineVoice* s = &v->sv[c];
                s->cap = cap;
                s->blk = blk;
                s->snap = snap;
                s->blksz = sz;
                tarr_bind(&s->x, blk, cap);
            }
        }
        Ring* rings = (Ring*)bump(&b, (size_t)(ch->nl ? ch->nl : 1) * sizeof(Ring));
        LzV* lz = (LzV*)bump(&b, (size_t)(ch->nl ? ch->nl : 1) * sizeof(LzV));
        if (v) { v->rings[c] = rings; v->lz[c] = lz; }
        for (int l = 0; l < ch->nl; l++) {
            const Layer* L = &ch->lay[l];
            float* d = (float*)bump(&b, (size_t)L->ring * 2 * L->M * sizeof(float));
            int64_t* idx = (int64_t*)bump(&b, (size_t)L->ring * sizeof(int64_t));
            uint64_t* st = (uint64_t*)bump(&b, (size_t)L->ring * sizeof(uint64_t));
            char* cur = (char*)bump(&b, L->lzsz);
            char* bm = (char*)bump(&b, L->lzsz);
            if (v) {
                rings[l].data = d;
                rings[l].idx = idx;
                rings[l].stamp = st;
                lz[l].cur = cur;
                lz[l].bm = bm;
            }
        }
    }
    double* X = (double*)bump(&b, (size_t)Mmax * sizeof(double));
    double* buf = (double*)bump(&b, (size_t)Mmax * sizeof(double));
    int32_t* qi = (int32_t*)bump(&b, (size_t)Mmax * sizeof(int32_t));
    if (v) { v->X = X; v->buf = buf; v->qi = qi; }
    return b.off;
}

size_t p5_voice_memory(const p5_note* nt) { return voice_build(nt, NULL); }

static void sines_seek(p5_voice* v, int c, int64_t p);
static void lz_restart(const Layer* L, char* blk);

p5_voice* p5_voice_new(const p5_note* nt) {
    size_t sz = voice_build(nt, NULL);
    p5_voice* v = (p5_voice*)calloc(1, sz);
    if (!v) return NULL;
    voice_build(nt, v);
    v->note = nt;
    for (int c = 0; c < nt->nch; c++)
        for (int l = 0; l < nt->ch[c].nl; l++) {
            for (int r = 0; r < nt->ch[c].lay[l].ring; r++) v->rings[c][l].idx[r] = -1;
            lz_restart(&nt->ch[c].lay[l], v->lz[c][l].cur);
            v->lz[c][l].want = -1;
        }
    v->pos = -1;
    p5_seek(v, 0);
    return v;
}

void p5_voice_free(p5_voice* v) { free(v); }

/* ------------------------------------------------------------------ sines */

static void pad_dummies(SineVoice* s) {
    int end = (s->na + G - 1) / G * G;
    for (int j = s->na; j < end; j++) {
        s->x.zr[j] = 1; s->x.zi[j] = 0; s->x.rr[j] = 1; s->x.ri[j] = 0;
        s->x.qr[j] = 1; s->x.qi[j] = 0; s->x.a[j] = 0; s->x.ai[j] = 0;
    }
}

/* exp(i x) for the small chirp step: exact to double for |x| < 0.05 */
static void cis_small(double x, double* c, double* s) {
    if (fabs(x) < 0.05) {
        double x2 = x * x;
        *c = 1 - x2 * (1.0 / 2 - x2 * (1.0 / 24 - x2 * (1.0 / 720 - x2 * (1.0 / 40320))));
        *s = x * (1 - x2 * (1.0 / 6 - x2 * (1.0 / 120 - x2 * (1.0 / 5040 - x2 * (1.0 / 362880)))));
    } else {
        *c = cos(x);
        *s = sin(x);
    }
}

/* a segment from w0, a0 to w1, a1, entered t0 samples in: rate, chirp, level.
   Phase over the segment: th0 + w0 t + al t^2, al = (w1 - w0) / 2T (the
   reference's integrate mode; its cubic term is zero). */
static void seg_set(SineVoice* s, int j, double T, double w0, double w1, double a0, double a1, int t0) {
    double al = 0.5 * (w1 - w0) / T;
    double r = w0 + al * (2.0 * t0 + 1);
    s->x.rr[j] = cos(r);
    s->x.ri[j] = sin(r);
    cis_small(2 * al, &s->x.qr[j], &s->x.qi[j]);
    s->x.ai[j] = (a1 - a0) / T;
    s->x.a[j] = a0 + (a1 - a0) * ((double)t0 / T);
    s->x.we[j] = w1;
    s->x.ae[j] = a1;
}

/* integrated phase (less ph0) and w at frame f, from the nearest checkpoint */
static double phase_at(const Sines* S, const Track* t, int64_t f, int* kj, double* wf) {
    int64_t f0 = f / CP * CP;
    double c = S->cps[t->c0 + f / CP];
    /* key under frame f0 */
    const Key* K = S->keys + t->k0;
    int lo = 0, hi = t->nk - 1;
    while (lo < hi) {
        int mid = (lo + hi + 1) / 2;
        if (K[mid].key <= f0) lo = mid;
        else hi = mid - 1;
    }
    *kj = lo;
    double wp, wi;
    frame_wa(S, t, f0, kj, &wp, NULL);
    for (int64_t m = f0 + 1; m <= f; m++) {
        frame_wa(S, t, m, kj, &wi, NULL);
        double inc = 0.5 * (wi + wp) * S->T;
        c = m == 1 ? inc : c + inc;
        wp = wi;
    }
    *wf = wp;
    return c;
}

/* track tid entering segment sg, t0 samples in, into slot j */
static void track_enter(SineVoice* s, const Sines* S, int j, int tid, int64_t sg, int t0) {
    const Track* t = &S->tr[tid];
    double T = S->T, th0, w0, w1, a0, a1;
    int kj = 0;
    if (sg == 0) {
        frame_wa(S, t, 0, &kj, &w0, &a1);
        w1 = w0;
        a0 = 0.0;
        th0 = t->ph0 - w0 * T;
    } else {
        double c = phase_at(S, t, sg - 1, &kj, &w0);
        double wdummy;
        frame_wa(S, t, sg - 1, &kj, &wdummy, &a0);
        th0 = t->ph0 + c;
        if (sg < t->L) frame_wa(S, t, sg, &kj, &w1, &a1);
        else { w1 = w0; a1 = 0.0; }
    }
    double al = 0.5 * (w1 - w0) / T;
    double ph = th0 + w0 * t0 + al * (double)t0 * t0;
    s->x.zr[j] = cos(ph);
    s->x.zi[j] = sin(ph);
    s->x.tid[j] = tid;
    s->x.s[j] = (int32_t)sg;
    s->x.kj[j] = kj;
    seg_set(s, j, T, w0, w1, a0, a1, t0);
}

static void sines_seek(p5_voice* v, int c, int64_t p) {
    const Sines* S = v->note->ch[c].s;
    SineVoice* s = &v->sv[c];
    if (!S) return;
    if (s->snap_ok && s->snap_pos == p) {
        memcpy(s->blk, s->snap, s->blksz);
        s->na = s->snap_na; s->next = s->snap_next; s->t = s->snap_t; s->g = s->snap_g;
        s->valid = 1;
        return;
    }
    int64_t g = p / S->H;
    int t0 = (int)(p % S->H);
    int na = 0, k;
    for (k = 0; k < S->ntr; k++) {
        const Track* t = &S->tr[k];
        if (t->start - 1 > g) break;
        int64_t sg = g - (t->start - 1);
        if (sg > t->L) continue;
        track_enter(s, S, na++, k, sg, t0);
    }
    s->na = na;
    s->next = k;
    s->g = g;
    s->t = t0;
    s->valid = 1;
    pad_dummies(s);
    memcpy(s->snap, s->blk, s->blksz);
    s->snap_na = na; s->snap_next = k; s->snap_t = t0; s->snap_g = g; s->snap_pos = p;
    s->snap_ok = 1;
}

static void slot_move(TArr* x, int to, int from) {
    x->zr[to] = x->zr[from]; x->zi[to] = x->zi[from]; x->rr[to] = x->rr[from]; x->ri[to] = x->ri[from];
    x->qr[to] = x->qr[from]; x->qi[to] = x->qi[from]; x->a[to] = x->a[from]; x->ai[to] = x->ai[from];
    x->we[to] = x->we[from]; x->ae[to] = x->ae[from];
    x->tid[to] = x->tid[from]; x->s[to] = x->s[from]; x->kj[to] = x->kj[from];
}

/* the next hop: every sounding track to its next segment, new tracks in */
static void sines_hop(SineVoice* s, const Sines* S) {
    double T = S->T;
    s->g++;
    s->t = 0;
    for (int j = 0; j < s->na;) {
        const Track* t = &S->tr[s->x.tid[j]];
        int32_t sg = ++s->x.s[j];
        if (sg > t->L) {
            slot_move(&s->x, j, --s->na);
            continue;
        }
        double w0 = s->x.we[j], a0 = s->x.ae[j], w1, a1;
        if (sg < t->L) {
            int kj = s->x.kj[j];
            frame_wa(S, t, sg, &kj, &w1, &a1);
            s->x.kj[j] = kj;
        } else { w1 = w0; a1 = 0.0; }
        seg_set(s, j, T, w0, w1, a0, a1, 0);
        j++;
    }
    while (s->next < S->ntr && S->tr[s->next].start - 1 == s->g) track_enter(s, S, s->na++, s->next++, 0, 0);
    pad_dummies(s);
}

/* len samples of every sounding track into acc */
static P5_INLINE void osc_body(TArr* x, int na, double* acc, int len) {
    for (int g0 = 0; g0 < na; g0 += G) {
        double Zr[G], Zi[G], Rr[G], Ri[G], Qr[G], Qi[G], A[G], AI[G];
        for (int u = 0; u < G; u++) {
            Zr[u] = x->zr[g0 + u]; Zi[u] = x->zi[g0 + u]; Rr[u] = x->rr[g0 + u]; Ri[u] = x->ri[g0 + u];
            Qr[u] = x->qr[g0 + u]; Qi[u] = x->qi[g0 + u]; A[u] = x->a[g0 + u]; AI[u] = x->ai[g0 + u];
        }
        for (int t = 0; t < len; t++) {
            double y[G];
            for (int u = 0; u < G; u++) {
                y[u] = A[u] * Zr[u];
                double nr = Zr[u] * Rr[u] - Zi[u] * Ri[u];
                double ni = Zr[u] * Ri[u] + Zi[u] * Rr[u];
                double mr = Rr[u] * Qr[u] - Ri[u] * Qi[u];
                double mi = Rr[u] * Qi[u] + Ri[u] * Qr[u];
                Zr[u] = nr; Zi[u] = ni; Rr[u] = mr; Ri[u] = mi;
                A[u] += AI[u];
            }
            acc[t] += ((y[0] + y[1]) + (y[2] + y[3])) + ((y[4] + y[5]) + (y[6] + y[7]));
        }
        for (int u = 0; u < G; u++) {
            x->zr[g0 + u] = Zr[u]; x->zi[g0 + u] = Zi[u]; x->rr[g0 + u] = Rr[u]; x->ri[g0 + u] = Ri[u];
            x->a[g0 + u] = A[u];
        }
    }
}

static void osc_gen(TArr* x, int na, double* acc, int len) { osc_body(x, na, acc, len); }
#ifdef P5_X86
P5_AVX2 static void osc_avx2(TArr* x, int na, double* acc, int len) { osc_body(x, na, acc, len); }
#endif

static void osc(const p5_voice* v, TArr* x, int na, double* acc, int len) {
#ifdef P5_X86
    if (v->note->simd) { osc_avx2(x, na, acc, len); return; }
#endif
    (void)v;
    osc_gen(x, na, acc, len);
}

/* ------------------------------------------------------------------ layers */

/* a forward FFT of P points (re, im apart), input already in bit-reversed order */
static P5_INLINE void fft_body(double* re, double* im, int P, const double* twr, const double* twi) {
    for (int i = 0; i < P; i += 2) {
        double ar = re[i], ai = im[i], br = re[i + 1], bi = im[i + 1];
        re[i] = ar + br; im[i] = ai + bi;
        re[i + 1] = ar - br; im[i + 1] = ai - bi;
    }
    if (P >= 4)
        for (int i = 0; i < P; i += 4) {
            double ur = re[i], ui = im[i], vr = re[i + 2], vi = im[i + 2];
            re[i] = ur + vr; im[i] = ui + vi;
            re[i + 2] = ur - vr; im[i + 2] = ui - vi;
            ur = re[i + 1]; ui = im[i + 1]; vr = im[i + 3]; vi = -re[i + 3];     /* times -i */
            re[i + 1] = ur + vr; im[i + 1] = ui + vi;
            re[i + 3] = ur - vr; im[i + 3] = ui - vi;
        }
    for (int h = 4; h < P; h *= 2) {
        const double* wr = twr + h;
        const double* wi = twi + h;
        for (int i = 0; i < P; i += 2 * h) {
            double* pr = re + i;
            double* pi = im + i;
            double* qr = pr + h;
            double* qi = pi + h;
            for (int j = 0; j < h; j++) {
                double vr = qr[j] * wr[j] - qi[j] * wi[j], vi = qr[j] * wi[j] + qi[j] * wr[j];
                double ur = pr[j], ui = pi[j];
                pr[j] = ur + vr; pi[j] = ui + vi;
                qr[j] = ur - vr; qi[j] = ui - vi;
            }
        }
    }
}

/* ------------------------------------------------------------------ layer rows */

/* the cursor at row -1: the coder states the parse found, fresh models */
static void lz_restart(const Layer* L, char* blk) {
    Lz z;
    lz_bind(L, blk, &z);
    size_t ss = (size_t)p5rc_state_size(), ms = (size_t)p5rc_model_size();
    *z.last = -1;
    memcpy(z.st, L->rst, 3 * ss);
    p5rc_model_init(z.md, 0);
    p5rc_model_init(z.md + ms, 0);
    p5rc_model_init(z.md + 2 * ms, 1);
}

/* decode the cursor's next row of all three grids */
static void lz_step(const p5_note* nt, const Layer* L, const Lz* z) {
    size_t ss = (size_t)p5rc_state_size(), ms = (size_t)p5rc_model_size();
    int64_t r = *z->last + 1;
    size_t nb = (size_t)L->nbx, K = (size_t)L->K;
    size_t s0 = (size_t)(r % 3), s1 = (size_t)((r + 2) % 3), s2 = (size_t)((r + 1) % 3);
    const uint8_t* one = nt->ones;
    int32_t *sd0 = z->sd + s0 * nb, *ss0 = z->ss + s0 * nb, *dv0 = z->dv + s0 * nb, *qv0 = z->qv + s0 * K;
    uint8_t *sm0 = z->sm + s0 * nb, *qm0 = z->qm + s0 * K;
    p5rc_dec_row(z->st, z->md, r, L->nbx, one, sd0, one, z->sd + s1 * nb, one, z->sd + s2 * nb);
    const int32_t* ss1 = z->ss + s1 * nb;
    for (size_t b = 0; b < nb; b++) {
        int32_t s = r ? ss1[b] + sd0[b] : (int32_t)(sd0[b] - L->dead);
        ss0[b] = s;
        sm0[b] = s != 0;
    }
    if (L->has_dq)
        p5rc_dec_row(z->st + ss, z->md + ms, r, L->nbx, sm0, dv0, z->sm + s1 * nb, z->dv + s1 * nb, z->sm + s2 * nb,
                     z->dv + s2 * nb);
    const int32_t* ed = L->edges;
    for (size_t b = 0; b < nb; b++) {   /* quant.coded_mask */
        int ok = sm0[b] && L->snr - 1.5 * (double)dv0[b] > 0;
        memset(qm0 + ed[b], ok, (size_t)(ed[b + 1] - ed[b]));
    }
    p5rc_dec_row(z->st + 2 * ss, z->md + 2 * ms, r, L->K, qm0, qv0, z->qm + s1 * K, z->qv + s1 * K, z->qm + s2 * K,
                 z->qv + s2 * K);
    *z->last = r;
}

/* Row f of layer L's grids, in its slot (f % 3) of the cursor z. Forward
   rows are decoded in order; an earlier row than the cursor holds restarts
   from the bookmark (the first row the last seek needed, so a loop's wrap
   costs nothing) when it is not past f, else from row 0. */
static void lz_row(const p5_note* nt, const Layer* L, LzV* zv, int64_t f, Lz* z) {
    lz_bind(L, zv->cur, z);
    if (f <= *z->last && f >= *z->last - 2) return;
    if (f < *z->last - 2) {
        Lz b;
        lz_bind(L, zv->bm, &b);
        if (zv->bm_ok && *b.last >= 0 && f >= *b.last - 2) memcpy(zv->cur, zv->bm, L->lzsz);
        else lz_restart(L, zv->cur);
        if (f <= *z->last) return;
    }
    while (*z->last < f) {
        lz_step(nt, L, z);
        if (*z->last == zv->want && !(zv->bm_ok && *(int64_t*)zv->bm == zv->want)) {
            memcpy(zv->bm, zv->cur, L->lzsz);
            zv->bm_ok = 1;
        }
    }
}

/* quant.dequantize of frame f -> X[0..M) (zero past K), from its rows:
   scale codes less dead, step offsets, coefficient codes */
static void dequant(const Layer* L, int64_t f, const int32_t* sc, const int32_t* dq, const int32_t* qv, double* X,
                    int32_t* qi) {
    const int32_t* ed = L->edges;
    const double sq12 = sqrt(12.0), sq3 = sqrt(3.0);
    for (int b = 0; b < L->nbx; b++) {
        int lo = ed[b], hi = ed[b + 1], wid = hi - lo;
        if (!sc[b]) {
            for (int k = lo; k < hi; k++) X[k] = 0.0;
            continue;
        }
        int dqv = dq[b];
        double rms = L->rmsT[sc[b]];
        double step = (rms > 1e-30 ? rms : 1e-30) * L->stepT[dqv - L->dqmin] * sq12;
        double sumsq = 0.0;
        int nz = 0;
        if (L->snr - 1.5 * (double)dqv > 0) {
            for (int k = lo; k < hi; k++) {
                int32_t q = qv[k];
                double xd = (double)q * step;
                qi[k] = q;
                X[k] = xd;
                sumsq += xd * xd;
                nz += q == 0;
            }
        } else {
            for (int k = lo; k < hi; k++) qi[k] = 0;
            nz = wid;
        }
        if (!nz) continue;
        double lack = rms * rms * wid - sumsq;
        if (!(lack > 0)) lack = 0.0;
        double fill = sqrt(lack / (double)nz);
        double lim = step / sq12;
        if (fill > lim) fill = lim;
        fill *= sq3;
        uint64_t c0 = (uint64_t)f * (uint64_t)L->K;
        for (int k = lo; k < hi; k++)
            if (qi[k] == 0) {
                double r = (double)hash_u32(L->seed, c0 + (uint64_t)k) / 2147483648.0 - 1.0;
                X[k] = fill * r;
            }
    }
    for (int k = L->K; k < L->M; k++) X[k] = 0.0;
}

/* frame f of layer L, windowed, into 2M floats (transform.inverse's yf[f]) */
/* the DCT-IV of X (M points, in place) through a complex FFT of M/2, then
   the windowed 2M-sample frame (f0: the first frame, flat on its back half) */
static P5_INLINE void imdct_body(const Tab* t, double* X, double* buf, int f0, float* out) {
    int M = t->M, P = M / 2, h = M / 2;
    double* re = buf;
    double* im = buf + P;
    const int32_t* br = t->br;
    for (int m = 0; m < P; m++) {
        double a = X[2 * m], b = X[M - 1 - 2 * m], c = t->prc[m], s = t->prs[m];
        int j = br[m];
        re[j] = a * c - b * s;
        im[j] = a * s + b * c;
    }
    fft_body(re, im, P, t->twr, t->twi);
    for (int m = 0; m < P; m++) {
        double tr = re[m], ti = im[m], c = t->poc[m], s = t->pos[m];
        X[2 * m] = tr * c - ti * s;
        X[M - 1 - 2 * m] = -(tr * s + ti * c);
    }
    double sc = 2.0 / M;
    const double* w = t->win;
    if (f0) {
        for (int i = 0; i < h; i++) out[i] = 0.0f;
        for (int i = h; i < M; i++) out[i] = (float)(-X[3 * h - 1 - i] * sc);
    } else {
        for (int i = 0; i < h; i++) out[i] = (float)(X[i + h] * sc * w[i]);
        for (int i = h; i < M; i++) out[i] = (float)(-X[3 * h - 1 - i] * sc * w[i]);
    }
    /* the window's back half mirrors its front: w[2M - 1 - i] */
    for (int i = M; i < 3 * h; i++) out[i] = (float)(-X[3 * h - 1 - i] * sc * w[2 * M - 1 - i]);
    for (int i = 3 * h; i < 2 * M; i++) out[i] = (float)(-X[i - 3 * h] * sc * w[2 * M - 1 - i]);
}

static void imdct_gen(const Tab* t, double* X, double* buf, int f0, float* out) { imdct_body(t, X, buf, f0, out); }
#ifdef P5_X86
P5_AVX2 static void imdct_avx2(const Tab* t, double* X, double* buf, int f0, float* out) { imdct_body(t, X, buf, f0, out); }
#endif

static void frame_decode(p5_voice* v, const Layer* L, LzV* zv, int64_t f, float* out) {
    int M = L->M;
    double* X = v->X;
    const Tab* t = v->note->tabs[L->mi];
    Lz z;
    lz_row(v->note, L, zv, f, &z);
    size_t s = (size_t)(f % 3), nb = (size_t)L->nbx;
    dequant(L, f, z.ss + s * nb, z.dv + s * nb, z.qv + s * (size_t)L->K, X, v->qi);
    if (t->fft) {
#ifdef P5_X86
        if (v->note->simd) { imdct_avx2(t, X, v->buf, f == 0, out); return; }
#endif
        imdct_gen(t, X, v->buf, f == 0, out);
    } else {    /* any other length: the basis directly */
        double sc = 2.0 / M;
        int hm = M / 2;
        for (int i = 0; i < 2 * M; i++) {
            double y = 0.0;
            for (int k = 0; k < L->K; k++) y += X[k] * cos(PI_ / M * (i + 0.5 + M / 2.0) * (k + 0.5));
            y *= sc;
            double w = sin(PI_ * (i + 0.5) / (2 * M));
            if (f == 0 && i < M) w = i < hm ? 0.0 : 1.0;
            out[i] = (float)(y * w);
        }
    }
}

static const float* get_frame(p5_voice* v, const Layer* L, Ring* R, LzV* zv, int64_t f, int64_t keep) {
    int victim = -1;
    for (int r = 0; r < L->ring; r++)
        if (R->idx[r] == f) {
            R->stamp[r] = ++v->clock;
            return R->data + (size_t)r * 2 * L->M;
        }
    for (int r = 0; r < L->ring; r++) {
        if (R->idx[r] == keep && keep >= 0) continue;
        if (victim < 0 || R->stamp[r] < R->stamp[victim]) victim = r;
    }
    float* d = R->data + (size_t)victim * 2 * L->M;
    frame_decode(v, L, zv, f, d);
    R->idx[victim] = f;
    R->stamp[victim] = ++v->clock;
    return d;
}

/* layer L's samples [p, p + len) added into acc */
static void layer_add(p5_voice* v, const Layer* L, Ring* R, LzV* zv, int64_t p, int len, double* acc) {
    int64_t M = L->M, off = L->M / 2;
    int64_t jmax = v->note->n - L->start;
    if ((L->F + 1) * M - off < jmax) jmax = (L->F + 1) * M - off;
    int64_t j0 = p - L->start, a = j0 < 0 ? 0 : j0, b = j0 + len < jmax ? j0 + len : jmax;
    while (a < b) {
        int64_t u = off + a, g = u / M, r = u % M;
        int64_t run = M - r < b - a ? M - r : b - a;
        const float* fa = g < L->F ? get_frame(v, L, R, zv, g, g - 1) : NULL;
        const float* fb = g >= 1 && g - 1 < L->F ? get_frame(v, L, R, zv, g - 1, g) : NULL;
        double* o = acc + (a - j0);
        if (fa && fb)
            for (int64_t i = 0; i < run; i++) o[i] += (double)fa[r + i] + (double)fb[M + r + i];
        else if (fa)
            for (int64_t i = 0; i < run; i++) o[i] += (double)fa[r + i];
        else if (fb)
            for (int64_t i = 0; i < run; i++) o[i] += (double)fb[M + r + i];
        a += run;
    }
}

/* ------------------------------------------------------------------ real time */

void p5_seek(p5_voice* v, int64_t frame) {
    if (frame == v->pos) return;
    v->pos = frame;
    const p5_note* nt = v->note;
    int64_t p = frame < 0 ? 0 : frame;
    for (int c = 0; c < nt->nch; c++) {
        if (!nt->ch[c].s) continue;
        if (p >= nt->n) v->sv[c].valid = 0;
        else sines_seek(v, c, p);
    }
    /* bookmark the first row this position needs (a loop seeks back to it) */
    for (int c = 0; c < nt->nch; c++)
        for (int l = 0; l < nt->ch[c].nl; l++) {
            const Layer* L = &nt->ch[c].lay[l];
            if (L->F <= 0) continue;
            LzV* zv = &v->lz[c][l];
            int64_t d = p - L->start, g = (L->M / 2 + (d > 0 ? d : 0)) / L->M;
            if (g > L->F - 1) g = L->F - 1;
            zv->want = g;
            if (*(const int64_t*)zv->cur == g && !(zv->bm_ok && *(const int64_t*)zv->bm == g)) {
                memcpy(zv->bm, zv->cur, L->lzsz);
                zv->bm_ok = 1;
            }
        }
}

void p5_render(p5_voice* v, float* out, int k) {
    const p5_note* nt = v->note;
    int nc = nt->nch;
    int i = 0;
    while (i < k) {
        int64_t p = v->pos;
        int len = k - i < CHUNK ? k - i : CHUNK;
        if (p < 0 || p >= nt->n) {
            if (p < 0 && len > -p) len = (int)(-p);
            memset(out + (size_t)i * nc, 0, (size_t)len * nc * sizeof(float));
            v->pos += len;
            i += len;
            continue;
        }
        if (len > nt->n - p) len = (int)(nt->n - p);
        for (int c = 0; c < nc; c++) {
            const Sines* S = nt->ch[c].s;
            if (S) {
                int left = S->H - v->sv[c].t;
                if (len > left) len = left;
            }
        }
        for (int c = 0; c < nc; c++) {
            double* acc = v->acc[c];
            const Chan* ch = &nt->ch[c];
            memset(acc, 0, (size_t)len * sizeof(double));
            if (ch->s) {
                SineVoice* s = &v->sv[c];
                if (!s->valid) sines_seek(v, c, p);
                osc(v, &s->x, s->na, acc, len);
                s->t += len;
                if (s->t == ch->s->H) sines_hop(s, ch->s);
                /* the snapshot holds the state at the seek point; moving on leaves it */
            }
            for (int l = 0; l < ch->nl; l++) layer_add(v, &ch->lay[l], &v->rings[c][l], &v->lz[c][l], p, len, acc);
        }
        float* o = out + (size_t)i * nc;
        if (nc == 1) {
            const double* m = v->acc[0];
            for (int t = 0; t < len; t++) o[t] = (float)m[t];
        } else if (nt->stereo == 1) {
            const double *m = v->acc[0], *s = v->acc[1];
            for (int t = 0; t < len; t++) {
                o[2 * t] = (float)(m[t] + s[t]);
                o[2 * t + 1] = (float)(m[t] - s[t]);
            }
        } else {
            const double *l = v->acc[0], *r = v->acc[1];
            for (int t = 0; t < len; t++) {
                o[2 * t] = (float)l[t];
                o[2 * t + 1] = (float)r[t];
            }
        }
        v->pos += len;
        i += len;
    }
}

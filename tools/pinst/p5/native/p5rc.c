/* PINST5 range coder (agent D). The same algorithm as pack.py's _Enc/_Dec;
   pack.py's docstring is the specification. Integer only, deterministic.

   Build (MinGW):  gcc -O2 -shared -o p5rc.dll p5rc.c
   Build (MSVC):   cl /nologo /O2 /LD p5rc.c /Fe:p5rc.dll

   State is opaque to the caller: p5rc_state_size() bytes, zeroed or not.
   Encoder: enc_init(out buffer), enc_grid() per grid, enc_finish() -> bytes
   written (-1 if the buffer was too small). Decoder: dec_init(bytes),
   dec_grid() per grid, in the same order and of the same kinds. */
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#define API __declspec(dllexport)
#else
#define API
#endif

#define PB 15
#define ONE (1u << PB)
#define HALF (ONE >> 1)
#define NC 24
#define NU 31
#define U0 0
#define T0 (4 * NC * 32)
#define S0 (T0 + 32 * 8)
#define NMODEL (S0 + 1)

/* grid kinds: 0 the scale-code deltas, 1 the coefficient codes */
typedef struct { int wl, col, rmax, ma; } Kind;
static const Kind KIND[2] = { {2, 0, 6, 2}, {1, 4, 8, 3} };

typedef struct {
    /* encoder */
    uint64_t low;
    uint32_t rng, cache;
    int64_t csize, pos, cap;
    uint8_t *out;
    int over;
    /* decoder */
    uint32_t code;
    const uint8_t *in;
    int64_t len;
} St;

typedef struct {
    uint16_t p[NMODEL];
    uint8_t n[NMODEL];
    uint8_t rate[256];
    Kind k;
} Model;

static int bitlen(uint32_t v) {
    int b = 0;
    while (v) { b++; v >>= 1; }
    return b;
}

static void model_init(Model *m, int64_t kind) {
    m->k = KIND[kind ? 1 : 0];
    for (int i = 0; i < NMODEL; i++) { m->p[i] = HALF; m->n[i] = 0; }
    for (int n = 0; n < 256; n++) {
        int r = 1 + bitlen((uint32_t)n);
        m->rate[n] = (uint8_t)(r < m->k.rmax ? r : m->k.rmax);
    }
}

static int cls(uint32_t e) {
    if (e < 2) return (int)e;
    int b = bitlen(e);
    int c = 2 * b - 2 + (int)((e >> (b - 2)) & 1);
    return c < NC - 1 ? c : NC - 1;
}

static uint32_t mag(int32_t v) { return v < 0 ? (uint32_t)(-(int64_t)v) : (uint32_t)v; }

/* U base of pack.py's _ctx, from the magnitudes already coded */
static int ctx(const Model *m, const int32_t *v, const uint8_t *mk, int64_t f, int64_t k, int64_t K) {
#define A(ff, kk) (mk[(ff) * K + (kk)] ? mag(v[(ff) * K + (kk)]) : 0u)
    uint32_t e = 0;
    int up = 0;
    if (k > 0) e += (uint32_t)m->k.wl * A(f, k - 1);
    if (k > 1) e += A(f, k - 2);
    if (f > 0) {
        e += 2 * A(f - 1, k);
        if (k > 0) e += A(f - 1, k - 1);
        if (k + 1 < K) e += A(f - 1, k + 1);
        up = mk[(f - 1) * K + k] != 0;
        if (f > 1) e += 2 * A(f - 2, k);
    }
#undef A
    int c = m->k.col && bitlen((uint32_t)k) >= m->k.col;
    return U0 + (4 * cls(e) + 2 * up + c) * 32;
}

API int64_t p5rc_state_size(void) { return (int64_t)sizeof(St); }

/* ------------------------------------------------------------- encoder */

static void put(St *s, uint32_t b) {
    if (s->pos < s->cap) s->out[s->pos] = (uint8_t)b; else s->over = 1;
    s->pos++;
}

static void shift_low(St *s) {
    if (s->low < 0xFF000000u || s->low >= ((uint64_t)1 << 32)) {
        uint32_t carry = (uint32_t)(s->low >> 32), t = s->cache;
        do { put(s, (t + carry) & 0xFF); t = 0xFF; } while (--s->csize != 0);
        s->cache = (uint32_t)(s->low >> 24) & 0xFF;
    }
    s->csize++;
    s->low = (s->low & 0x00FFFFFFu) << 8;
}

static void ebit(St *s, Model *m, int i, int b) {
    uint32_t p = m->p[i], bound = (s->rng >> PB) * p, r = m->rate[m->n[i]];
    if (b) { s->low += bound; s->rng -= bound; m->p[i] = (uint16_t)(p - (p >> r)); }
    else { s->rng = bound; m->p[i] = (uint16_t)(p + ((ONE - p) >> r)); }
    if (m->n[i] < 255) m->n[i]++;
    while (s->rng < (1u << 24)) { s->rng <<= 8; shift_low(s); }
}

static void eraw(St *s, int b) {
    uint32_t bound = (s->rng >> PB) * HALF;
    if (b) { s->low += bound; s->rng -= bound; } else s->rng = bound;
    while (s->rng < (1u << 24)) { s->rng <<= 8; shift_low(s); }
}

API void p5rc_enc_init(St *s, uint8_t *out, int64_t cap) {
    memset(s, 0, sizeof *s);
    s->rng = 0xFFFFFFFFu;
    s->csize = 1;
    s->out = out;
    s->cap = cap;
}

API int64_t p5rc_enc_grid(St *s, int64_t kind, int64_t F, int64_t K, const int32_t *v, const uint8_t *mk) {
    Model m;
    model_init(&m, kind);
    int tree = 1 << m.k.ma;
    for (int64_t f = 0; f < F; f++)
        for (int64_t k = 0; k < K; k++) {
            if (!mk[f * K + k]) continue;
            int base = ctx(&m, v, mk, f, k, K);
            int32_t x = v[f * K + k];
            uint32_t a = mag(x);
            int b = bitlen(a);
            for (int i = 0; i < NU; i++) {
                ebit(s, &m, base + i, b > i);
                if (b <= i) break;
            }
            int node = 1;
            for (int j = b - 2; j >= 0; j--) {
                int bit = (a >> j) & 1;
                if (node < tree) { ebit(s, &m, T0 + 8 * b + node, bit); node = 2 * node + bit; }
                else eraw(s, bit);
            }
            if (a) ebit(s, &m, S0, x < 0);
        }
    return s->over ? -1 : 0;
}

API int64_t p5rc_enc_finish(St *s) {
    uint64_t hi = s->low + s->rng;
    for (int z = 40; z >= 0; z--) {
        uint64_t v = ((s->low + ((uint64_t)1 << z) - 1) >> z) << z;
        if (v < hi) { s->low = v; break; }
    }
    for (int i = 0; i < 5; i++) shift_low(s);
    if (s->over) return -1;
    /* drop the first byte (always 0) and the trailing zeros */
    int64_t n = s->pos;
    while (n > 1 && s->out[n - 1] == 0) n--;
    if (n <= 1) return 0;
    memmove(s->out, s->out + 1, (size_t)(n - 1));
    return n - 1;
}

/* ------------------------------------------------------------- decoder */

static uint32_t get(St *s) { return s->pos < s->len ? s->in[s->pos++] : (s->pos++, 0u); }

static int dbit(St *s, Model *m, int i) {
    uint32_t p = m->p[i], bound = (s->rng >> PB) * p, r = m->rate[m->n[i]];
    int b;
    if (s->code < bound) { s->rng = bound; m->p[i] = (uint16_t)(p + ((ONE - p) >> r)); b = 0; }
    else { s->code -= bound; s->rng -= bound; m->p[i] = (uint16_t)(p - (p >> r)); b = 1; }
    if (m->n[i] < 255) m->n[i]++;
    while (s->rng < (1u << 24)) { s->rng <<= 8; s->code = (s->code << 8) | get(s); }
    return b;
}

static int draw_(St *s) {
    uint32_t bound = (s->rng >> PB) * HALF;
    int b;
    if (s->code < bound) { s->rng = bound; b = 0; }
    else { s->code -= bound; s->rng -= bound; b = 1; }
    while (s->rng < (1u << 24)) { s->rng <<= 8; s->code = (s->code << 8) | get(s); }
    return b;
}

API void p5rc_dec_init(St *s, const uint8_t *in, int64_t len) {
    memset(s, 0, sizeof *s);
    s->in = in;
    s->len = len;
    s->rng = 0xFFFFFFFFu;
    for (int i = 0; i < 4; i++) s->code = (s->code << 8) | get(s);
}

API void p5rc_dec_grid(St *s, int64_t kind, int64_t F, int64_t K, const uint8_t *mk, int32_t *v) {
    Model m;
    model_init(&m, kind);
    int tree = 1 << m.k.ma;
    for (int64_t f = 0; f < F; f++)
        for (int64_t k = 0; k < K; k++) {
            if (!mk[f * K + k]) { v[f * K + k] = 0; continue; }
            int base = ctx(&m, v, mk, f, k, K);
            int b = 0;
            while (b < NU && dbit(s, &m, base + b)) b++;
            uint32_t a = b ? 1 : 0;
            int node = 1;
            for (int j = 0; j < b - 1; j++) {
                int bit;
                if (node < tree) { bit = dbit(s, &m, T0 + 8 * b + node); node = 2 * node + bit; }
                else bit = draw_(s);
                a = 2 * a + (uint32_t)bit;
            }
            v[f * K + k] = (a && dbit(s, &m, S0)) ? -(int32_t)a : (int32_t)a;
        }
}

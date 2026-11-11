/* pinst_fast.dll: numpy's big arrays, kept and handed out again.

   The C heap gives a block over about a megabyte straight back to Windows,
   and the next one arrives as fresh pages, each zeroed by the kernel on first
   touch and cold in the cache. The baker makes and drops such arrays all day
   (a signal, a spectrogram, a temporary of either): gigabytes of new pages a
   minute, and with a worker per core they all queue for the same memory.
   This allocator rounds a big block up to one of four sizes per power of two
   and keeps freed blocks for the next asker. Small blocks go to malloc. */
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __declspec(dllexport)
#define HDR 16                          /* [block size or 0, class] before the data */
#define BIG ((size_t)1 << 17)
#define NCLASS 96
#define KEEP ((size_t)768 << 20)        /* most bytes kept idle */

typedef struct Blk { size_t size, cls; } Blk;
static SRWLOCK lock = SRWLOCK_INIT;
static void* freel[NCLASS];
static size_t kept;

static size_t round_up(size_t s, size_t* cls) {
    unsigned long k;
    _BitScanReverse64(&k, s);
    size_t q = (size_t)1 << (k - 2), base = (size_t)1 << k;
    size_t n = (s - base + q - 1) / q;
    *cls = (size_t)(k - 17) * 4 + n;
    return base + n * q;
}

static void* take(size_t n, int zero) {
    size_t s = n + HDR, cls = 0, size = 0;
    Blk* b = 0;
    if (s >= BIG) {
        size = round_up(s, &cls);
        if (cls < NCLASS) {
            AcquireSRWLockExclusive(&lock);
            b = (Blk*)freel[cls];
            if (b) { freel[cls] = *(void**)(b + 1); kept -= size; }
            ReleaseSRWLockExclusive(&lock);
            if (b) {
                if (zero) memset(b + 1, 0, n);
                return b + 1;
            }
            s = size;
        } else size = 0;
    }
    b = (Blk*)(zero ? calloc(1, s) : malloc(s));
    if (!b) return 0;
    b->size = size; b->cls = cls;
    return b + 1;
}

static void give(void* p) {
    if (!p) return;
    Blk* b = (Blk*)p - 1;
    if (b->size) {
        int keep = 0;
        AcquireSRWLockExclusive(&lock);
        if (kept + b->size <= KEEP) {
            *(void**)p = freel[b->cls]; freel[b->cls] = b; kept += b->size; keep = 1;
        }
        ReleaseSRWLockExclusive(&lock);
        if (keep) return;
    }
    free(b);
}

static void* h_malloc(void* ctx, size_t n) { return take(n ? n : 1, 0); }
static void* h_calloc(void* ctx, size_t a, size_t b) {
    if (b && a > (SIZE_MAX - HDR) / b) return 0;
    return take(a * b ? a * b : 1, 1);
}
static void h_free(void* ctx, void* p, size_t n) { give(p); }
static void* h_realloc(void* ctx, void* p, size_t n) {
    if (!p) return take(n ? n : 1, 0);
    Blk* b = (Blk*)p - 1;
    if (!n) n = 1;
    if (b->size) {
        if (n + HDR <= b->size && n + HDR > b->size / 2) return p;
        void* q = take(n, 0);
        if (!q) return 0;
        memcpy(q, p, n + HDR < b->size ? n : b->size - HDR);
        give(p);
        return q;
    }
    if (n + HDR < BIG) {
        b = (Blk*)realloc(b, n + HDR);
        return b ? b + 1 : 0;
    }
    /* a small block growing big: its old length is unknown, _msize tells */
    void* q = take(n, 0);
    if (!q) return 0;
    size_t old = _msize(b) - HDR;
    memcpy(q, p, old < n ? old : n);
    free(b);
    return q;
}

/* numpy's PyDataMem_Handler, version 1 */
typedef struct {
    char name[127];
    uint8_t version;
    void* ctx;
    void* (*malloc)(void*, size_t);
    void* (*calloc)(void*, size_t, size_t);
    void* (*realloc)(void*, void*, size_t);
    void (*free)(void*, void*, size_t);
} Handler;

EXPORT Handler mem_handler = {"pinst_recycle", 1, 0, h_malloc, h_calloc, h_realloc, h_free};
EXPORT size_t mem_kept(void) { return kept; }

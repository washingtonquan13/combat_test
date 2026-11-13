"""PINST5 stage: the file (owner: agent D).

pack(NoteCode) -> bytes;  unpack(bytes) -> NoteCode

Layout (frozen only at the end of the plan):
    "PIN5", varints: version, sample rate, n, stereo, channel count
    then sections, each: 4-byte tag, varint payload length, payload
      SINE  varint channel, the SineCode ints (analysis.INT_KEYS), then each
            stream (analysis.STREAM_KEYS) as varint length + LZMA; dt df da
            are stored in frame order (pinst_file._reorder), which packs smaller
      LAYR  varint channel, M, K, nbands, snr*100, dead, frames, seed, start, has_dq,
            then one range-coder stream to the end of the section holding: the
            scale codes' frame deltas (frames x bands, every cell); if has_dq,
            the step offsets dq (frames x bands, live cells, an SC-kind grid);
            and the coefficient codes (frames x K, the coded cells only,
            quant.coded_mask, which the decoder knows from what it has read)
A reader skips tags it does not know. Varints are zigzag LEB128 (pinst_codec._varint).

The range coder (native/p5rc.c is the same algorithm in C; this file's
_Enc/_Dec are the reference and run when the DLL is not built):

  Binary range coder, LZMA's: 32-bit range, 64-bit low with carry cache,
  renormalise a byte at a time while range < 2^24. A bit with probability
  p/2^15 of being 0 splits at bound = (range >> 15) * p; 0 takes the low part.
  Start: low 0, range 0xFFFFFFFF. End: low is moved to the number in
  [low, low + range) with the most trailing zero bits, then 5 bytes are
  shifted out. The first byte out (always 0) and trailing zero bytes are not
  stored; the decoder starts by reading 4 bytes and reads 0 past the end.

  Adaptive bit: a 15-bit probability p (start 2^14) and a count n (start 0,
  stops at 255). After coding bit b with rate r = min(1 + bitlen(n), RMAX):
  b == 0: p += (2^15 - p) >> r;  b == 1: p -= p >> r;  then n += 1.
  So a fresh bit averages its first few symbols, then follows a window of
  about 2^RMAX symbols. A raw bit is coded at p = 2^14 and never changes.

  Integer grid (F rows x K columns, a 0/1 mask of the cells that are coded,
  raster order: row by row, column by column), of a kind with parameters
  (WL, COL, RMAX, MA):
    SC, the scale-code frame deltas:  WL 2, COL 0, RMAX 6, MA 2
    Q,  the coefficient codes:        WL 1, COL 4, RMAX 8, MA 3
  Each grid starts a fresh model (all p = 2^14, n = 0). Uncoded and outside
  cells count as 0. For cell (f, k) with value v, a(f, k) = |v| if coded:
    e   = WL*a(f,k-1) + a(f,k-2) + 2a(f-1,k) + a(f-1,k-1) + a(f-1,k+1) + 2a(f-2,k)
    cls = 0 if e == 0, 1 if e == 1, else min(NC - 1, 2*bitlen(e) - 2 + bit (bitlen(e)-2) of e)
    col = 1 if COL and bitlen(k) >= COL else 0
    ctx = 4*cls + 2*mask[f-1,k] + col           (mask 0 on row 0)
    m = |v|, b = bitlen(m) (0..31)
    b in unary: for i = 0, 1, ..: bit (b > i) on U[ctx][i], stop after a 0 or after i = 30
    if b >= 2, the b-1 bits under the leading 1, high first: the first
      min(b-1, MA) on a bit tree T[b][node] (node 1, then 2*node + bit), the rest raw
    if m != 0: the sign (v < 0) on S
  Model, NC = 24: U[96][32] at 0, T[32][8] at 3072, S at 3328; 3329 bits.
"""
from __future__ import annotations

import ctypes
import os

import numpy as np

import analysis
import contract as C
import pinst_codec as pc
import pinst_file as pf
import quant

PB = 15
ONE = 1 << PB
HALF = ONE >> 1
NC = 24
NU = 31                     # unary bits per context (bitlen of |v| < 2^31)
U0, T0 = 0, 4 * NC * 32     # model layout: U[ctx][32], then T[b][8], then S
S0 = T0 + 32 * 8
NMODEL = S0 + 1
# per grid kind: (left weight WL, column split COL, RMAX, tree bits MA)
SC, Q = 0, 1
KIND = ((2, 0, 6, 2), (1, 4, 8, 3))
_BL = [1 + int(n).bit_length() for n in range(256)]


def _cls(e):
    if e < 2:
        return e
    b = e.bit_length()
    return min(NC - 1, 2 * b - 2 + ((e >> (b - 2)) & 1))


def _ctx(A, Ml, f, k, K, wl, col):
    """U base for cell (f, k) from the magnitudes already coded (A is 0 where not coded)."""
    a = A[f]
    e = wl * a[k - 1] if k else 0
    if k > 1:
        e += a[k - 2]
    up = 0
    if f:
        u = A[f - 1]
        e += 2 * u[k] + (u[k - 1] if k else 0) + (u[k + 1] if k + 1 < K else 0)
        up = Ml[f - 1][k]
        if f > 1:
            e += 2 * A[f - 2][k]
    c = 1 if col and k.bit_length() >= col else 0
    return U0 + (4 * _cls(e) + 2 * up + c) * 32


class _Enc:
    def __init__(s):
        s.low, s.rng, s.cache, s.csize, s.out = 0, 0xFFFFFFFF, 0, 1, bytearray()

    def _shift(s):
        if s.low < 0xFF000000 or s.low >= 1 << 32:
            carry = s.low >> 32
            t = s.cache
            while True:
                s.out.append((t + carry) & 0xFF)
                t = 0xFF
                s.csize -= 1
                if not s.csize:
                    break
            s.cache = (s.low >> 24) & 0xFF
        s.csize += 1
        s.low = (s.low & 0x00FFFFFF) << 8

    def bit(s, P, N, i, b):
        p = P[i]
        bound = (s.rng >> PB) * p
        r = min(_BL[N[i]], s.rmax)
        if b:
            s.low += bound
            s.rng -= bound
            P[i] = p - (p >> r)
        else:
            s.rng = bound
            P[i] = p + ((ONE - p) >> r)
        if N[i] < 255:
            N[i] += 1
        while s.rng < 1 << 24:
            s.rng <<= 8
            s._shift()

    def raw(s, b):
        bound = (s.rng >> PB) * HALF
        if b:
            s.low += bound
            s.rng -= bound
        else:
            s.rng = bound
        while s.rng < 1 << 24:
            s.rng <<= 8
            s._shift()

    def grid(s, kind, V, mask):
        wl, col, s.rmax, ma = KIND[kind]
        F, K = V.shape
        P, N = [HALF] * NMODEL, [0] * NMODEL
        A = np.where(mask, np.abs(V), 0).tolist()
        Vl, Ml = V.tolist(), mask.astype(np.int64).tolist()
        for f in range(F):
            for k in range(K):
                if not Ml[f][k]:
                    continue
                base = _ctx(A, Ml, f, k, K, wl, col)
                v = Vl[f][k]
                mag = A[f][k]
                b = mag.bit_length()
                for i in range(NU):
                    s.bit(P, N, base + i, b > i)
                    if b <= i:
                        break
                node = 1
                for j in range(b - 2, -1, -1):
                    bit = (mag >> j) & 1
                    if node < 1 << ma:
                        s.bit(P, N, T0 + 8 * b + node, bit)
                        node = 2 * node + bit
                    else:
                        s.raw(bit)
                if mag:
                    s.bit(P, N, S0, v < 0)

    def finish(s):
        hi = s.low + s.rng
        for z in range(40, -1, -1):
            v = ((s.low + (1 << z) - 1) >> z) << z
            if v < hi:
                s.low = v
                break
        for _ in range(5):
            s._shift()
        out = bytes(s.out[1:])
        return out.rstrip(b"\0")


class _Dec:
    def __init__(s, data):
        s.b, s.i, s.rng, s.code = data, 0, 0xFFFFFFFF, 0
        for _ in range(4):
            s.code = (s.code << 8) | s._byte()

    def _byte(s):
        s.i += 1
        return s.b[s.i - 1] if s.i <= len(s.b) else 0

    def bit(s, P, N, i):
        p = P[i]
        bound = (s.rng >> PB) * p
        r = min(_BL[N[i]], s.rmax)
        if s.code < bound:
            s.rng = bound
            P[i] = p + ((ONE - p) >> r)
            b = 0
        else:
            s.code -= bound
            s.rng -= bound
            P[i] = p - (p >> r)
            b = 1
        if N[i] < 255:
            N[i] += 1
        while s.rng < 1 << 24:
            s.rng <<= 8
            s.code = ((s.code << 8) | s._byte()) & 0xFFFFFFFF
        return b

    def raw(s):
        bound = (s.rng >> PB) * HALF
        if s.code < bound:
            s.rng = bound
            b = 0
        else:
            s.code -= bound
            s.rng -= bound
            b = 1
        while s.rng < 1 << 24:
            s.rng <<= 8
            s.code = ((s.code << 8) | s._byte()) & 0xFFFFFFFF
        return b

    def grid(s, kind, mask):
        wl, col, s.rmax, ma = KIND[kind]
        F, K = mask.shape
        P, N = [HALF] * NMODEL, [0] * NMODEL
        Ml = mask.astype(np.int64).tolist()
        A = [[0] * K for _ in range(F)]
        out = [[0] * K for _ in range(F)]
        for f in range(F):
            for k in range(K):
                if not Ml[f][k]:
                    continue
                base = _ctx(A, Ml, f, k, K, wl, col)
                b = 0
                while b < NU and s.bit(P, N, base + b):
                    b += 1
                mag = 1 if b else 0
                node = 1
                for _ in range(b - 1):
                    if node < 1 << ma:
                        bit = s.bit(P, N, T0 + 8 * b + node)
                        node = 2 * node + bit
                    else:
                        bit = s.raw()
                    mag = 2 * mag + bit
                A[f][k] = mag
                out[f][k] = -mag if mag and s.bit(P, N, S0) else mag
        return np.array(out, dtype=np.int64).reshape(F, K)


# ------------------------------------------------------------- the C coder

def _load():
    try:
        lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "native", "p5rc.dll"))
    except OSError:
        return None
    p, i64 = ctypes.c_void_p, ctypes.c_int64
    for name, res, args in (("p5rc_state_size", i64, []),
                            ("p5rc_enc_init", None, [p, p, i64]),
                            ("p5rc_enc_grid", i64, [p, i64, i64, i64, p, p]),
                            ("p5rc_enc_finish", i64, [p]),
                            ("p5rc_dec_init", None, [p, p, i64]),
                            ("p5rc_dec_grid", None, [p, i64, i64, i64, p, p])):
        f = getattr(lib, name)
        f.restype, f.argtypes = res, args
    return lib


_lib = None if os.environ.get("P5RC_PY") else _load()


class _CEnc:
    def __init__(s, cap):
        s.st = ctypes.create_string_buffer(int(_lib.p5rc_state_size()))
        s.buf = ctypes.create_string_buffer(int(cap))
        _lib.p5rc_enc_init(s.st, s.buf, cap)

    def grid(s, kind, V, mask):
        V = np.ascontiguousarray(V, dtype=np.int32)
        m = np.ascontiguousarray(mask, dtype=np.uint8)
        assert _lib.p5rc_enc_grid(s.st, kind, V.shape[0], V.shape[1], V.ctypes.data, m.ctypes.data) == 0, "range coder overflow"

    def finish(s):
        n = _lib.p5rc_enc_finish(s.st)
        assert n >= 0, "range coder overflow"
        return s.buf.raw[:n]


class _CDec:
    def __init__(s, data):
        s.data = bytes(data)
        s.st = ctypes.create_string_buffer(int(_lib.p5rc_state_size()))
        _lib.p5rc_dec_init(s.st, s.data, len(s.data))

    def grid(s, kind, mask):
        m = np.ascontiguousarray(mask, dtype=np.uint8)
        V = np.zeros(m.shape, dtype=np.int32)
        _lib.p5rc_dec_grid(s.st, kind, m.shape[0], m.shape[1], m.ctypes.data, V.ctypes.data)
        return V.astype(np.int64)


def _enc(nvals):
    return _CEnc(64 + 8 * nvals) if _lib is not None else _Enc()


def _dec(data):
    return _CDec(data) if _lib is not None else _Dec(data)


# ------------------------------------------------------------- the file

def _put(out, *vals):
    for v in vals:
        pc._varint(int(v), out)


def _stream(out, b):
    z = pc.lz_bytes(b) if b else b""
    _put(out, len(z))
    out += z


def _section(out, tag, payload):
    out += tag
    _put(out, len(payload))
    out += payload


def _sc_grid(sc):
    d = sc.copy()
    d[1:] -= sc[:-1]
    return d


def pack(note: C.NoteCode) -> bytes:
    out = bytearray(C.MAGIC)
    _put(out, C.VERSION, note.sr, note.n, note.stereo, len(note.channels))
    for ci, ch in enumerate(note.channels):
        if ch.sines is not None:
            I, S = ch.sines.ints, ch.sines.streams
            p = bytearray()
            _put(p, ci, *(I[k] for k in analysis.INT_KEYS))
            dt, df, da = pf._reorder(S["hdr"], S["dt"], S["df"], S["da"], I["lock"], I["n_tracks"], to_frames=True)
            for b in (S["hdr"], dt, df, da, S["f0"]):
                _stream(p, b)
            _section(out, b"SINE", p)
        for L in ch.layers:
            p = bytearray()
            lb = L.sc != L.dead
            has_dq = int(L.dq[lb].any())
            _put(p, ci, L.M, L.K, L.nbands, round(L.snr * 100), L.dead, L.frames, L.seed, L.start, has_dq)
            d = _sc_grid(L.sc)
            live = quant.coded_mask(L)
            assert np.abs(d).max(initial=0) < 1 << 31 and np.abs(L.q).max(initial=0) < 1 << 31
            assert not L.q[~live].any(), "coefficients outside coded bands"
            rc = _enc(2 * d.size + int(live.sum()))
            rc.grid(SC, d, np.ones(d.shape, dtype=bool))
            if has_dq:
                rc.grid(SC, L.dq, lb)
            rc.grid(Q, L.q, live)
            p += rc.finish()
            _section(out, b"LAYR", p)
    return bytes(out)


def unpack(data: bytes) -> C.NoteCode:
    assert data[:4] == C.MAGIC, "not a PINST5 file"
    c = pf.Cur(data)
    c.i = 4
    ver, sr, n, stereo, nch = (c.v() for _ in range(5))
    assert ver == C.VERSION, f"PINST5 version {ver}"
    note = C.NoteCode(sr, n, stereo, [C.ChannelCode() for _ in range(nch)])
    while c.left():
        tag = bytes(c.take(4))
        body = pf.Cur(bytes(c.take(c.v())))
        if tag == b"SINE":
            ci = body.v()
            I = {k: body.v() for k in analysis.INT_KEYS}
            hdr, dt, df, da, f0 = (pf._unlz(bytes(body.take(body.v()))) for _ in range(5))
            dt, df, da = pf._reorder(hdr, dt, df, da, I["lock"], I["n_tracks"], to_frames=False)
            note.channels[ci].sines = C.SineCode(I, dict(zip(analysis.STREAM_KEYS, (hdr, dt, df, da, f0))))
        elif tag == b"LAYR":
            ci, M, K, nb, snr, dead, F, seed, start, has_dq = (body.v() for _ in range(10))
            nbx = len(quant.edges(K, nb)) - 1
            rc = _dec(body.b[body.i:])
            sc = np.cumsum(rc.grid(SC, np.ones((F, nbx), dtype=bool)), axis=0)
            dq = rc.grid(SC, sc != dead) if has_dq else np.zeros((F, nbx), dtype=np.int64)
            L = C.LayerCode(M, K, nb, snr / 100, dead, F, seed, sc, None, dq, start)
            L.q = rc.grid(Q, quant.coded_mask(L))
            note.channels[ci].layers.append(L)
    return note

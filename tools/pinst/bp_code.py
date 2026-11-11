"""Breakpoint coding for slowly changing generator values (SMS_PLAN.md
stage 6).

Input is integer codes, already quantized: one value per frame, in the
value's own quantization steps. A *track* is a run of frames `(start, vals)`
with vals (L,) or (L, C); the C columns of one track share their
breakpoints. A 2-D frames x tracks array with per-track spans goes through
`from_grid`.

1. Breakpoints. `select` keeps the frames where the piecewise-linear line
   through the kept points would leave the source by more than `tol` steps,
   and drops the rest. The first and last frame are always kept, and the
   kept values are the source's own integers, so the decoder's line is
   within `tol` steps of the input everywhere (exact at tol 0).
2. Entropy coding. One adaptive binary range coder per payload (LZMA's:
   32-bit range, 11-bit probabilities, shift-4 adaptation, carry by a
   cached byte). Integers are binarized as zero flag, sign, Elias-gamma
   length in unary and mantissa bits, each bit with its own adaptive
   probability.

What is coded, per track: the start (step from the last track's), the last
frame, the side integers (`side`, for example a harmonic number or a start
phase; one model per position), the first value per column (step from the
last track's first value; context: same start or not), then per breakpoint
the gap in frames (context: the last gap's class) and per column the step
from the last breakpoint (context: this column's last step's class and the
previous column's step class at this breakpoint). Tracks decode in the
order they were given.

Decoding is one multiply, one compare and a probability update per binary
decision (`decode` counts them in `stats`), and a shift-in byte every 8 or
so; state is the probabilities only (a few thousand uint16 per payload).
"""
from __future__ import annotations

import numpy as np

TOL = 1.0    # steps; one value for every stream and every instrument (set on the 16-note listening set)

_TOP = 1 << 24
_PB = 11
_MOVE = 4
_P0 = 1 << (_PB - 1)
_GAMMA = 24          # longest Elias-gamma prefix handled (|v| < 2^24)


# ------------------------------------------------------------ breakpoints

def select(vals, tol=TOL) -> np.ndarray:
    """Kept frame indices of vals (L,) or (L, C). From each kept frame k,
    the next is the farthest j whose line k..j stays within tol of every
    frame between, on every column. The test is a slope cone: each frame t
    allows slopes [(v[t]-tol-v[k])/(t-k), (v[t]+tol-v[k])/(t-k)]; j is good
    while its own slope is inside all the cones so far, and nothing past the
    point where the cone empties can be.

    vals may be a float line in steps (for example a decoder's line through
    integer points): only frames whose value is an integer on every column
    can be kept, so the kept values stay integers and the error against
    vals stays within tol. The first and last frames must be integers."""
    v = np.asarray(vals, dtype=float)
    if v.ndim == 1:
        v = v[:, None]
    L = len(v)
    if L <= 2:
        return np.arange(L, dtype=np.int64)
    eps = 1e-9
    cand = np.all(np.abs(v - np.rint(v)) < 1e-6, axis=1)
    assert cand[0] and cand[-1], "first and last frame must hold integers"
    keep = [0]
    k = 0
    while k < L - 1:
        lo = np.full(v.shape[1], -np.inf)
        hi = np.full(v.shape[1], np.inf)
        best = None
        for j in range(k + 1, L):
            d = j - k
            sl = (v[j] - v[k]) / d
            if cand[j] and (best is None or (np.all(sl >= lo - eps) and np.all(sl <= hi + eps))):
                best = j
            lo = np.maximum(lo, (v[j] - tol - v[k]) / d)
            hi = np.minimum(hi, (v[j] + tol - v[k]) / d)
            if np.any(lo > hi + eps):
                break
        if best is None:     # the cone emptied before any integer frame
            best = k + 1 + int(np.argmax(cand[k + 1 :]))
        keep.append(best)
        k = best
    return np.array(keep, dtype=np.int64)


def expand(keys, kvals, L) -> np.ndarray:
    """The decoder's line: (L, C) float from kept frames and their values."""
    kv = np.asarray(kvals, dtype=float)
    if kv.ndim == 1:
        kv = kv[:, None]
    t = np.arange(L)
    return np.stack([np.interp(t, keys, kv[:, c]) for c in range(kv.shape[1])], axis=1)


def from_grid(a, spans=None):
    """(frames, tracks) integer grid -> one 1-column track per grid column.
    spans: per column (first, end) frames, end exclusive; default all."""
    a = np.asarray(a, dtype=np.int64)
    F, T = a.shape
    spans = [(0, F)] * T if spans is None else spans
    return [(int(s), a[s:e, i]) for i, (s, e) in enumerate(spans) if e > s]


def to_grid(points, frames):
    """decode()'s points of 1-column tracks back to a (frames, tracks) float
    grid (the decoder's line), NaN outside each track's span."""
    g = np.full((frames, len(points)), np.nan)
    for i, (s, keys, kv, _) in enumerate(points):
        L = int(keys[-1]) + 1
        g[s : s + L, i] = expand(keys, kv, L)[:, 0]
    return g


# ------------------------------------------------------------ range coder

class _Enc:
    def __init__(self):
        self.low, self.rng, self.cache, self.csize = 0, 0xFFFFFFFF, 0, 1
        self.out = bytearray()

    def bit(self, p, i, b):
        q = p[i]
        bound = (self.rng >> _PB) * q
        if b:
            self.low += bound
            self.rng -= bound
            p[i] = q - (q >> _MOVE)
        else:
            self.rng = bound
            p[i] = q + (((1 << _PB) - q) >> _MOVE)
        while self.rng < _TOP:
            self.rng = (self.rng << 8) & 0xFFFFFFFF
            self._shift()

    def _shift(self):
        lo = self.low
        if (lo & 0xFFFFFFFF) < 0xFF000000 or lo >> 32:
            carry = lo >> 32
            t = self.cache
            while True:
                self.out.append((t + carry) & 0xFF)
                t = 0xFF
                self.csize -= 1
                if not self.csize:
                    break
            self.cache = (lo >> 24) & 0xFF
        self.csize += 1
        self.low = (lo << 8) & 0xFFFFFFFF

    def finish(self) -> bytes:
        for _ in range(5):
            self._shift()
        b = bytes(self.out[1:])      # the first byte is always 0
        return b.rstrip(b"\x00")     # the decoder reads zeros past the end


class _Dec:
    def __init__(self, data: bytes):
        self.d, self.pos = data, 0
        self.rng = 0xFFFFFFFF
        self.code = 0
        for _ in range(4):
            self.code = (self.code << 8) | self._byte()
        self.bits = 0

    def _byte(self):
        b = self.d[self.pos] if self.pos < len(self.d) else 0
        self.pos += 1
        return b

    def bit(self, p, i):
        self.bits += 1
        q = p[i]
        bound = (self.rng >> _PB) * q
        if self.code < bound:
            self.rng = bound
            p[i] = q + (((1 << _PB) - q) >> _MOVE)
            b = 0
        else:
            self.code -= bound
            self.rng -= bound
            p[i] = q - (q >> _MOVE)
            b = 1
        while self.rng < _TOP:
            self.rng = (self.rng << 8) & 0xFFFFFFFF
            self.code = ((self.code << 8) | self._byte()) & 0xFFFFFFFF
        return b


# ---------------------------------------------------------- integer model

class _Int:
    """Adaptive model of one integer kind, `nctx` contexts. Layout per
    context: [zero, sign, gamma prefix x _GAMMA, mantissa (len, bit)...]."""
    MANT = 8          # mantissa bits below this many get a context each

    def __init__(self, nctx=1):
        self.n = 2 + _GAMMA + self.MANT * self.MANT
        self.p = [_P0] * (self.n * nctx)

    def put(self, e, v, ctx=0, signed=True):
        p, o = self.p, ctx * self.n
        v = int(v)
        e.bit(p, o, v != 0)
        if not v:
            return
        if signed:
            e.bit(p, o + 1, v < 0)
        m = abs(v)                    # >= 1, Elias gamma of m
        nb = m.bit_length() - 1
        for i in range(nb):
            e.bit(p, o + 2 + min(i, _GAMMA - 1), 1)
        if nb < _GAMMA:
            e.bit(p, o + 2 + min(nb, _GAMMA - 1), 0)
        for j in range(nb - 1, -1, -1):
            k = min(nb, self.MANT) - 1
            e.bit(p, o + 2 + _GAMMA + k * self.MANT + min(nb - 1 - j, self.MANT - 1), (m >> j) & 1)

    def get(self, d, ctx=0, signed=True):
        p, o = self.p, ctx * self.n
        if not d.bit(p, o):
            return 0
        neg = d.bit(p, o + 1) if signed else 0
        nb = 0
        while nb < _GAMMA and d.bit(p, o + 2 + min(nb, _GAMMA - 1)):
            nb += 1
        m = 1
        for j in range(nb - 1, -1, -1):
            k = min(nb, self.MANT) - 1
            m = (m << 1) | d.bit(p, o + 2 + _GAMMA + k * self.MANT + min(nb - 1 - j, self.MANT - 1))
        return -m if neg else m


def _cls(v):
    """Size class of a step, for contexts: 0, 1, 2-3, more."""
    a = abs(int(v))
    return 0 if a == 0 else 1 if a == 1 else 2 if a < 4 else 3


class _Models:
    def __init__(self, C, nside):
        self.hdr = _Int(3)               # 0: tracks, 1: columns, 2: side count
        self.start = _Int(1)
        self.length = _Int(1)
        self.side = [_Int(1) for _ in range(nside)]
        self.first = [_Int(2) for _ in range(C)]      # ctx: same start as the last track
        self.gap = _Int(5)               # ctx: last gap's class (4 = none)
        # ctx: own last step's class x the previous column's step here (4 = none)
        self.step = [_Int(5 * 5) for _ in range(C)]


class _Put:
    def __init__(self):
        self.e = _Enc()

    def __call__(self, model, v, ctx=0, signed=True):
        model.put(self.e, v, ctx, signed)
        return int(v)


class _Get:
    def __init__(self, data):
        self.d = _Dec(data)

    def __call__(self, model, v, ctx=0, signed=True):
        return model.get(self.d, ctx, signed)


def _code(io, points=None, side=None, C=None, ns=None):
    """The one walk over a payload, for both directions: io writes the value
    it is given and returns it (_Put), or ignores it and returns the decoded
    one (_Get). points/side are None when decoding."""
    hdr = _Int(3)
    n = io(hdr, len(points) if points is not None else 0, 0, False)
    C = io(hdr, C or 0, 1, False)
    ns = io(hdr, ns or 0, 2, False)
    M = _Models(C, ns)
    out = []
    prev_s, prev_first = 0, [0] * C
    for ti in range(n):
        if points is not None:
            s, keys, kv = points[ti]
            sd = side[ti] if ns else []
        else:
            s, keys, kv, sd = 0, None, None, [0] * ns
        s = prev_s + io(M.start, s - prev_s)
        same = int(s == prev_s and ti > 0)
        prev_s = s
        last = io(M.length, int(keys[-1]) if keys is not None else 0, 0, False)
        sd = [io(M.side[j], sd[j]) for j in range(ns)]
        first = [prev_first[c] + io(M.first[c], (int(kv[0, c]) - prev_first[c]) if kv is not None else 0, same)
                 for c in range(C)]
        prev_first = first
        ks, rows = [0], [first]
        last_gap = 4
        own = [4] * C
        pos, i = 0, 0
        while pos < last:
            i += 1
            g = int(keys[i] - keys[i - 1]) if keys is not None else 0
            if last - pos > 1:           # one frame left: the gap is 1
                g = 1 + io(M.gap, g - 1, last_gap, False)
            else:
                g = 1
            pos += g
            last_gap = _cls(g - 1)
            pc = 4
            row = []
            for c in range(C):
                dv = io(M.step[c], (int(kv[i, c]) - int(kv[i - 1, c])) if kv is not None else 0, own[c] * 5 + pc)
                row.append(rows[-1][c] + dv)
                own[c] = pc = _cls(dv)
            ks.append(pos)
            rows.append(row)
        out.append((s, np.array(ks, dtype=np.int64), np.array(rows, dtype=np.int64).reshape(len(ks), C), sd))
    return out


# ------------------------------------------------------------ public API

def encode(tracks, tol=TOL, side=None) -> bytes:
    """tracks: list of (start, vals) with vals (L,) or (L, C) in steps, all
    the same C (integers, or a line through integers: see select). side:
    optional per-track lists of ints, the same length for every track.
    Returns the payload; decode() gives back the kept points."""
    pts = []
    for s, v in tracks:
        v = np.asarray(v, dtype=float)
        v = v[:, None] if v.ndim == 1 else v
        k = select(v, tol)
        pts.append((int(s), k, np.rint(v[k]).astype(np.int64)))
    return encode_points(pts, side)


def encode_points(points, side=None) -> bytes:
    """points: list of (start, keys, kvals int (K,) or (K, C)). Keys start at
    0 and end at the track's last frame, strictly rising."""
    C = 1
    if points:
        kv0 = np.asarray(points[0][2])
        C = 1 if kv0.ndim == 1 else kv0.shape[1]
    ns = len(side[0]) if side else 0
    pts = [(int(s), np.asarray(k, dtype=np.int64), np.asarray(kv, dtype=np.int64).reshape(len(k), C))
           for s, k, kv in points]
    for _, k, _ in pts:
        assert k[0] == 0 and np.all(np.diff(k) > 0)
    io = _Put()
    _code(io, pts, side if ns else None, C, ns)
    return io.e.finish()


def decode(data: bytes, stats=None):
    """Returns [(start, keys, kvals int (K, C), side list)], in coded order.
    stats, a dict, gets 'bits' (binary decisions decoded) and 'values'."""
    io = _Get(data)
    out = _code(io)
    if stats is not None:
        stats["bits"] = io.d.bits
        stats["values"] = int(sum(len(k) * kv.shape[1] for _, k, kv, _ in out))
    return out

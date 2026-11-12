"""Generator 3 candidate: pulses as matching pursuit over damped multi-scale
atoms (SMS_PLAN.md stage 5; Daudet and Torresani's hybrid decomposition with
Goodwin and Vetterli's damped atoms).

An atom is a start sample, a scale (decay time constant), a frequency, a
phase and a level:

    a w(t - u) cos(2 pi f (t - u) + phi),   w = 0 before u

w rises from 0 over one of RISES_S (raised sine; 0 is a sharp start) and then
falls as exp(-t / tau). It starts at its sample and decays, so nothing of it
sounds before the hit (a symmetric Gabor atom would put half of itself
there). The rise is there because a sharp start of a strong low atom is a
step: its spectrum is a skirt over every band above it, and on the first
note measured (bass d#4 release) one such atom took 80 % of the attack's
energy and raised det_over in 25 bands; with a 0.5 ms rise the same atom
raised none.

Analysis, on what the partials and modes left:

1. Onsets from the audio by gen_modes.onsets (one definition for both), on
   what is left; several per note. No atom starts before the note's onset
   (pinst_codec.onset_sample of the source, as sms.run codes it).
2. At each onset, atoms are picked one at a time from what is left (matching
   pursuit), starting anywhere in the onset's first ATT_S, at any of
   SCALES_S x RISES_S.
   The correlation with every atom of a scale is one batch of FFTs of the
   residual under the scale's one-sided window, at a position stride of
   STRIDE of the scale; the energy each would take is the exact projection
   on its (cos, sin) pair (the pair's Gram matrix from the FFT of the
   squared window). The best is refined to the sample and the finer
   frequency (FFT padded REFINE_PAD times), subtracted, and the search runs
   again, at most CAP atoms per onset. CAP is what keeps this a generator
   and not a stored waveform in another basis; past it the attack belongs to
   the noise.
3. Levels and phases of the onset's atoms are refitted jointly (least
   squares), on the quantized starts, scales and frequencies.
4. Each atom must lower the residual in its own band (its ERB band widened
   to its bandwidth), over the time it takes to fall RING_DB, by GAIN_DB
   with the others held; the worst failing ones are dropped and the rest
   refitted until all pass.
5. Steps 3-4 run on the pursuit's first k atoms for k = CAP, CAP/2, ... 1.
   Each set is judged by the report card itself over what the onset's sets
   touch, as gen_modes judges its modes (gen_modes._counts: report_card.card
   cut to that span and CARD_PAD_S either side, noise analysed by gen_noise
   from the whole of what is left after the atoms, at the card's seeds,
   scored on the card's grid and on the shifted grid). A set may be taken only if
   the missed band-frames fall in total, no band's det_over band-frames
   rise, and the shifted grid's misses do not rise; of those, the one with
   the fewest misses is taken. If
   none passes, the one with the fewest misses is repaired: while some
   band's det_over rises, the atoms in the band where it rose most (if none,
   the one nearest it) are dropped and the rest refitted. If nothing passes,
   the onset has no atoms. What is taken is what the next onset and the
   noise are given.

Nothing here knows the instrument. Every constant is one value for all.
"""
from __future__ import annotations

import numpy as np
from scipy import fft as sfft

import lzma

import gen_modes as gm
import gen_noise as gn
import need_map as nm
import pinst_codec as pc
import report_card as rc

RANDOM = False

# dictionary
SCALES_S = (0.00025, 0.0005, 0.001, 0.002, 0.004, 0.008, 0.016)  # decay time constants
RISES_S = (0.0, 0.0005, 0.002)  # an atom's rise from 0 (raised sine), before its decay
TAIL_DB = 80.0       # an atom is cut where it has fallen this far (analysis and render)
ATT_S = 0.05         # atoms start within this of their onset
STRIDE = 0.125       # position step of the search, as a share of the scale
REFINE_PAD = 4       # the best atom's frequency is refined on an FFT padded this much more
F_LO = 16.0          # lowest atom frequency

# selection
CAP = 16             # atoms per onset, at most
GAIN_DB = 1.0        # each atom lowers its own band's residual this much
RING_DB = 30.0       # an atom's band is judged over the time it takes to fall this far

TRACE = None         # a list to log selection steps into (debugging)

# quantization
QA_STEP = 0.5        # dB, an atom's level under its onset's top
QT_STEP = 1.0        # dB, an onset's top level
QT_TOP = 100.0       # dB re full scale


# ---------------------------------------------------------------- atoms

WINDOWS = [(tau, rise) for tau in SCALES_S for rise in RISES_S]   # an atom's shape index


def _len(si, sr):
    tau, rise = WINDOWS[si]
    return int(round(rise * sr)) + max(2, int(np.ceil(tau * np.log(10 ** (TAIL_DB / 20)) * sr)))


_W = {}


def _win(si, sr):
    """The shape: a raised-sine rise over its rise time from 0 (none if 0),
    then exp(-t / tau)."""
    k = (si, sr)
    if k not in _W:
        tau, rise = WINDOWS[si]
        R = int(round(rise * sr))
        t = np.arange(_len(si, sr))
        w = np.exp(-np.maximum(t - R, 0) / (tau * sr))
        if R > 0:
            w[:R] *= 0.5 - 0.5 * np.cos(np.pi * (t[:R] + 1) / (R + 1))
        _W[k] = w
    return _W[k]


def _pair(u, si, f, n, sr):
    """(start, cos column, sin column) of an atom, cut at n."""
    w = _win(si, sr)
    L = min(len(w), n - u)
    ph = 2 * np.pi * f * np.arange(L) / sr
    return u, w[:L] * np.cos(ph), w[:L] * np.sin(ph)


def _atom(u, si, f, c, s, n, sr):
    a, wc, ws = _pair(u, si, f, n, sr)
    return a, c * wc + s * ws


class _Scale:
    """Everything about one scale that does not depend on the residual."""

    def __init__(self, si, sr):
        self.si = si
        tau = WINDOWS[si][0]
        self.w = _win(si, sr)
        self.L = len(self.w)
        self.Nf = sfft.next_fast_len(max(64, 2 * self.L))
        self.stride = max(1, int(round(STRIDE * tau * sr)))
        k = np.arange(self.Nf // 2 + 1)
        self.f = k * sr / self.Nf
        E = float(np.sum(self.w ** 2))
        D = sfft.fft(self.w ** 2, self.Nf)[(2 * k) % self.Nf]
        # Gram of (w cos, w sin) at each bin
        self.gcc = 0.5 * (E + D.real)
        self.gss = 0.5 * (E - D.real)
        self.gcs = -0.5 * D.imag
        self.det = self.gcc * self.gss - self.gcs ** 2
        self.ok = (self.f >= F_LO) & (self.f < sr / 2 * 0.98) & (self.det > 1e-9 * E * E)


def _gain(C, gcc, gss, gcs, det):
    """Energy the best (cos, sin) pair takes, and its coefficients, from the
    complex correlation C = sum r w e^{-iwt}."""
    bc, bs = C.real, -C.imag
    dd = np.where(det > 0, det, np.inf)
    c = (gss * bc - gcs * bs) / dd
    s = (gcc * bs - gcs * bc) / dd
    return c * bc + s * bs, c, s


def _frames(r, sc, us):
    """Per start in us: the best gain over frequency and its bin."""
    pad = np.concatenate([r, np.zeros(sc.L)])
    seg = np.lib.stride_tricks.sliding_window_view(pad, sc.L)[us] * sc.w
    C = sfft.rfft(seg, sc.Nf, axis=1)
    g, _, _ = _gain(C, sc.gcc, sc.gss, sc.gcs, sc.det)
    g[:, ~sc.ok] = -np.inf
    k = np.argmax(g, 1)
    return g[np.arange(len(us)), k], k


def _best(r, a0, a1, scales, sr, cache, touched=None):
    """The atom (gain, u, si, f, c, s) that takes the most energy from r,
    starting in [a0, a1). cache holds each scale's per-start best; only the
    starts whose window meets touched = [t0, t1) are computed again."""
    best = None
    for sc in scales:
        if sc.si not in cache:
            us = np.arange(a0, a1, sc.stride)
            if len(us) == 0:
                continue
            cache[sc.si] = [us, *_frames(r, sc, us)]
        us, gb, kb = cache[sc.si]
        if touched is not None:
            m = np.flatnonzero((us + sc.L > touched[0]) & (us < touched[1]))
            if len(m):
                gb[m], kb[m] = _frames(r, sc, us[m])
        i = int(np.argmax(gb))
        if best is None or gb[i] > best[0]:
            best = (float(gb[i]), int(us[i]), sc, int(kb[i]))
    if best is None or not np.isfinite(best[0]) or best[0] <= 0:
        return None
    # refine: every sample around the start, finer frequency around the bin
    _, u0, sc, k0 = best
    Nf = sc.Nf * REFINE_PAD
    fr = np.arange(Nf // 2 + 1) * sr / Nf
    lo = max(0, (k0 - 1) * REFINE_PAD)
    hi = min(len(fr), (k0 + 1) * REFINE_PAD + 1)
    us = np.arange(max(a0, u0 - sc.stride + 1), min(a1, u0 + sc.stride))
    pad = np.concatenate([r, np.zeros(sc.L)])
    seg = np.lib.stride_tricks.sliding_window_view(pad, sc.L)[us] * sc.w
    C = sfft.rfft(seg, Nf, axis=1)[:, lo:hi]
    kk = np.arange(lo, hi)
    D = sfft.fft(sc.w ** 2, Nf)[(2 * kk) % Nf]
    E = float(np.sum(sc.w ** 2))
    gcc, gss, gcs = 0.5 * (E + D.real), 0.5 * (E - D.real), -0.5 * D.imag
    det = gcc * gss - gcs ** 2
    g, c, s = _gain(C, gcc, gss, gcs, det)
    bad = (fr[kk] < F_LO) | (det <= 1e-9 * E * E)
    g[:, bad] = -np.inf
    i, k = np.unravel_index(int(np.argmax(g)), g.shape)
    if not np.isfinite(g[i, k]) or g[i, k] <= 0:
        return None
    return float(g[i, k]), int(us[i]), sc.si, float(fr[kk[k]]), float(c[i, k]), float(s[i, k])


def pursue(r, a0, a1, sr, cap):
    """Matching pursuit on r (changed in place): at most cap atoms starting
    in [a0, a1). Returns [(u, si, f)]."""
    scales = [_Scale(si, sr) for si in range(len(WINDOWS))]
    n = len(r)
    out, cache, touched = [], {}, None
    for _ in range(cap):
        b = _best(r, a0, a1, scales, sr, cache, touched)
        if b is None:
            break
        g, u, si, f, c, s = b
        a, y = _atom(u, si, f, c, s, n, sr)
        r[a : a + len(y)] -= y
        touched = (a, a + len(y))
        out.append((u, si, f))
    return out


# ---------------------------------------------------------------- fit

def _fit(x, atoms, sr):
    """Joint least-squares (cos, sin) of each atom on x. Returns (K x 2,
    region start, region end, K x region renders)."""
    n = len(x)
    if not atoms:
        return np.zeros((0, 2)), 0, 0, np.zeros((0, 0))
    a = min(u for u, _, _ in atoms)
    e = max(min(n, u + _len(si, sr)) for u, si, _ in atoms)
    W = e - a
    A = np.zeros((W, 2 * len(atoms)))
    for k, (u, si, f) in enumerate(atoms):
        s0, wc, ws = _pair(u, si, f, n, sr)
        A[s0 - a : s0 - a + len(wc), 2 * k] = wc
        A[s0 - a : s0 - a + len(ws), 2 * k + 1] = ws
    G = A.T @ A
    G += np.eye(len(G)) * 1e-12 * np.trace(G) / len(G)
    c = np.linalg.lstsq(G, A.T @ x[a:e], rcond=1e-12)[0].reshape(-1, 2)
    Y = (A[:, 0::2] * c[:, 0] + A[:, 1::2] * c[:, 1]).T
    return c, a, e, Y


def _gains(x, atoms, sr, erb):
    """dB by which each atom lowers the residual in its own band over its
    ring time, the others held; and the jointly fitted coefficients."""
    c, a, e, Y = _fit(x, atoms, sr)
    r = x[a:e] - Y.sum(0)
    g = np.zeros(len(atoms))
    for k, (u, si, f) in enumerate(atoms):
        tau, rise = WINDOWS[si]
        T = int(round(rise * sr)) + max(int(np.ceil(tau * np.log(10 ** (RING_DB / 20)) * sr)), 8)
        i0, i1 = u - a, min(e - a, u - a + T)
        Nf = sfft.next_fast_len(max(256, 4 * (i1 - i0)))
        lo, hi = gm._band_of(f, 1.0 / tau, erb)
        e1 = gm._band_energy(r[i0:i1], lo, hi, sr, Nf)
        e0 = gm._band_energy(r[i0:i1] + Y[k, i0:i1], lo, hi, sr, Nf)
        g[k] = 10 * np.log10((e0 + 1e-30) / (e1 + 1e-30))
    return g, c


def select(x, atoms, sr):
    """The atoms that each explain their own band (worst failing half dropped
    and the rest refitted until all pass)."""
    erb = np.concatenate([[0.0], pc.erb_edges(), [sr / 2]])
    atoms = list(atoms)
    while atoms:
        g, c = _gains(x, atoms, sr, erb)
        bad = np.flatnonzero(g < GAIN_DB)
        if not len(bad):
            return atoms
        o = bad[np.argsort(g[bad])]
        drop = set(o[: max(1, len(o) // 2)].tolist())
        atoms = [a for k, a in enumerate(atoms) if k not in drop]
    return atoms


# ---------------------------------------------------------------- quantization

def _quant_atoms(atoms):
    """The atoms with their frequencies on gen_modes' 16-bit log grid (as
    decoded); starts stay absolute samples (a group codes them under its
    onset in _group)."""
    return [(int(u), int(si), float(gm._df(gm._qf(np.array([f])))[0])) for u, si, f in atoms]


def _group(x, atoms, t0, sr):
    if not atoms:
        return None
    c, _, _, _ = _fit(x, atoms, sr)
    a = np.hypot(c[:, 0], c[:, 1])
    ph = np.arctan2(-c[:, 1], c[:, 0])   # a cos(wt + ph) = a cos ph cos wt - a sin ph sin wt
    adb = 20 * np.log10(a + 1e-300)
    top = int(np.clip(np.floor((QT_TOP - adb.max()) / QT_STEP), 0, 255))
    tdb = QT_TOP - top * QT_STEP
    qa = np.clip(np.round((tdb - adb) / QA_STEP), 0, 255).astype(np.uint8)
    qp = (np.round(ph / (2 * np.pi) * 256) % 256).astype(np.uint8)
    live = qa < 255
    if not live.any():
        return None
    k = np.flatnonzero(live)
    return {"t0": int(t0), "top": top,
            "du": np.array([atoms[i][0] - t0 for i in k], np.int64),
            "si": np.array([atoms[i][1] for i in k], np.uint8),
            "qf": gm._qf(np.array([atoms[i][2] for i in k])),
            "qa": qa[k], "qp": qp[k]}


def _render_group(g, n, sr):
    y = np.zeros(n)
    tdb = QT_TOP - g["top"] * QT_STEP
    a = 10 ** ((tdb - g["qa"].astype(float) * QA_STEP) / 20)
    ph = g["qp"].astype(float) * 2 * np.pi / 256
    f = gm._df(g["qf"])
    for k in range(len(f)):
        u = g["t0"] + int(g["du"][k])
        if u >= n:
            continue
        w = _win(int(g["si"][k]), sr)[: n - u]
        y[u : u + len(w)] += a[k] * w * np.cos(2 * np.pi * f[k] * np.arange(len(w)) / sr + ph[k])
    return y


# ---------------------------------------------------------------- interface

def _counts(src, det, left, sr, ref, a, b):
    """gen_modes._counts(src, det, left, sr, ref, a, b): the card cut to
    [a - CARD_PAD_S, b + CARD_PAD_S) (gen_modes' pad), counted over [a, b),
    with the noise analysed from the whole left; and the shifted grid's
    misses per band from the same noise renders. Returns (miss, det_over,
    edges, shifted miss)."""
    return nm.memo(_MEMO, (src, det, left, sr, ref, a, b), lambda: _counts_run(src, det, left, sr, ref, a, b))


_MEMO = {}


def _counts_run(src, det, left, sr, ref, a, b):
    n = len(src)
    H = nm.HOP
    pad = int(gm.CARD_PAD_S * sr)
    c0 = max(0, (a - pad) // H * H)
    c1 = min(n, b + pad)
    ns = gn.analyse(left, sr, {"src": src})
    noises = [gn.render(ns, n, sr, sd, c0, c1) for sd in nm.SEEDS]
    f0, f1 = max(0, (a - c0) // H), int(np.ceil((b - c0) / H))
    out = []
    for edges in (None, rc.shifted_edges()):
        c = rc.card(src[c0:c1], det[c0:c1], noises, sr, ref=ref, edges=edges)
        k, aud = c["kind"][f0:f1], c["audible"][f0:f1]
        out.append((((k >= 0) & aud).sum(0), ((k == rc.KINDS.index("det_over")) & aud).sum(0), c["edges"]))
    (m, o, e), (ms, _, _) = out
    return m, o, e, ms


def _span(sets, n, sr):
    """[first atom start, last atom end) over an onset's candidate sets: what
    any of them (or a repair, a subset) touches."""
    a = min(u for s in sets for u, _, _ in s)
    b = max(u + _len(si, sr) for s in sets for u, si, _ in s)
    return int(a), int(min(n, b))


def _accept(src, det, x, sets, t0, sr, ref, base, span):
    """The onset's group as the card takes it, or None: of the candidate
    sets, the one with the fewest misses over span (what the sets touch)
    among those with fewer misses than without atoms, no band's det_over
    band-frames higher, and no more misses on the shifted grid."""
    n = len(x)
    m0, o0, edges, s0 = base

    def judge(atoms):
        g = _group(x, atoms, t0, sr)
        if g is None:
            return None, None, None, None
        y = _render_group(g, n, sr)
        m1, o1, _, s1 = _counts(src, det + y, x - y, sr, ref, *span)
        if TRACE is not None:
            TRACE.append(("card", t0, len(g["qf"]), int(m0.sum()), int(m1.sum()), int(o0.sum()), int(o1.sum()),
                          int(s0.sum()), int(s1.sum())))
        return g, m1, o1, s1

    def passes(m1, o1, s1):
        return m1.sum() < m0.sum() and not (o1 > o0).any() and s1.sum() <= s0.sum()

    best, tried = None, []
    for atoms in sets:
        g, m1, o1, s1 = judge(atoms)
        if g is None:
            continue
        tried.append((m1.sum(), atoms, o1, s1))
        if passes(m1, o1, s1) and (best is None or m1.sum() < best[0]):
            best = (m1.sum(), g)
    if best is not None or not tried:
        return None if best is None else best[1]
    # none passed: the set with the fewest misses is repaired. While some
    # band's det_over rises, the atoms in the band where it rose most (if
    # none is in it, the one nearest it) are dropped and the rest refitted.
    m, atoms, o1, s1 = min(tried, key=lambda t: t[0])
    while m < m0.sum() and (o1 > o0).any():
        wb = int(np.argmax(o1 - o0))
        f = np.array([a[2] for a in atoms])
        band = np.clip(np.searchsorted(edges, f) - 1, 0, len(edges) - 2)
        inb = np.flatnonzero(band == wb)
        k = set(inb.tolist()) if len(inb) else {int(np.argmin(np.abs(np.log(f / np.sqrt(edges[wb] * edges[wb + 1])))))}
        atoms = [a for i, a in enumerate(atoms) if i not in k]
        g, m1, o1, s1 = judge(atoms)
        if g is None:
            return None
        m = m1.sum()
    return g if passes(m1, o1, s1) else None


def analyse(left, sr, hint):
    assert 1 <= CAP <= 255, "an onset's atom count is one byte"
    x = np.asarray(left, float).copy()
    n = len(x)
    src = np.asarray(hint.get("src", left), float)
    det = np.asarray(hint["det"], float).copy() if "det" in hint else np.zeros(n)
    edges = pc.erb_edges(nm.MODEL.noise_bands)
    px, _ = nm.band_stats([src], sr, edges)
    ref = float(px.max())
    first = pc.onset_sample(src)
    groups = []
    att = int(ATT_S * sr)
    for t0 in gm.onsets(x, sr):
        a0 = max(int(t0), first)
        a1 = min(n, a0 + att)
        if a1 - a0 < 2:
            continue
        r = x.copy()
        atoms = pursue(r, a0, a1, sr, CAP)
        if not atoms:
            continue
        atoms = _quant_atoms(atoms)
        # the pursuit's first k atoms, k = CAP, CAP/2, ... 1, each selected
        sets, k = [], len(atoms)
        while k >= 1:
            s = select(x, atoms[:k], sr)
            if s and s not in sets:
                sets.append(s)
            k //= 2
        if not sets:
            continue
        if TRACE is not None:
            TRACE.append(("atoms", a0, [len(s) for s in sets], [(u - a0, WINDOWS[si], round(f)) for u, si, f in sets[0][:6]]))
        span = _span(sets, n, sr)
        base = _counts(src, det, x, sr, ref, *span)
        g = _accept(src, det, x, sets, a0, sr, ref, base, span)
        if g is None:
            continue
        y = _render_group(g, n, sr)
        groups.append(g)
        x -= y
        det += y
    return {"groups": groups}


def render(s, n, sr, seed=0):
    y = np.zeros(n)
    for g in s["groups"]:
        y += _render_group(g, n, sr)
    return y


def render_at(s, n, sr, seed, idx):
    """The render played along idx (sms.loop_index): each atom's window is
    read at idx, its phase runs on the played samples."""
    y = np.zeros(len(idx))
    tl = np.arange(len(idx))
    for g in s["groups"]:
        tdb = QT_TOP - g["top"] * QT_STEP
        a = 10 ** ((tdb - g["qa"].astype(float) * QA_STEP) / 20)
        ph = g["qp"].astype(float) * 2 * np.pi / 256
        f = gm._df(g["qf"])
        for k in range(len(f)):
            u = g["t0"] + int(g["du"][k])
            if u >= n:
                continue
            w = _win(int(g["si"][k]), sr)[: n - u]
            m = (idx >= u) & (idx < u + len(w))
            if not m.any():
                continue
            y[m] += a[k] * w[idx[m] - u] * np.cos(2 * np.pi * f[k] * (tl[m] - u) / sr + ph[k])
    return y


def pack(s):
    """Streams: per onset the sample delta (varint), count and top level;
    per atom (in start order) the start under the onset (varint), scale,
    frequency (2 bytes, log), level under the top and phase (1 byte each)."""
    hdr, du, sq, fq, aq, pq = (bytearray() for _ in range(6))
    last = 0
    for g in s["groups"]:
        pc._varint(g["t0"] - last, hdr)
        last = g["t0"]
        hdr.append(len(g["qf"]))
        hdr.append(g["top"])
        o = np.argsort(g["du"], kind="stable")
        for v in g["du"][o]:
            pc._varint(int(v), du)
        sq += g["si"][o].tobytes()
        fq += g["qf"][o].astype("<u2").tobytes()
        aq += g["qa"][o].tobytes()
        pq += g["qp"][o].tobytes()
    if not hdr:
        return b""
    return b"".join(pc.lz_bytes(bytes(b)) for b in (hdr, du, sq, fq, aq, pq))


def _uvarints(b, i, k):
    """k zigzag varints from b at i -> (values, next i)."""
    out = []
    for _ in range(k):
        v = s = 0
        while True:
            c = b[i]; i += 1
            v |= (c & 0x7F) << s; s += 7
            if not c & 0x80:
                break
        out.append((v >> 1) ^ -(v & 1))
    return out, i


def unpack(z):
    """bytes -> settings, as pack wrote them (atoms in start order)."""
    if not z:
        return {"groups": []}
    streams = []
    for _ in range(6):
        # each stream is one raw LZMA2 stream; its end marker delimits it
        d = lzma.LZMADecompressor(lzma.FORMAT_RAW, filters=[{"id": lzma.FILTER_LZMA2, "dict_size": 1 << 24}])
        streams.append(d.decompress(z))
        z = d.unused_data
    hdr, du, sq, fq, aq, pq = streams
    fq = np.frombuffer(fq, "<u2")
    groups, i, j, ku, last = [], 0, 0, 0, 0
    while i < len(hdr):
        (dt,), i = _uvarints(hdr, i, 1)
        k, top = hdr[i], hdr[i + 1]
        i += 2
        last += dt
        d, ku = _uvarints(du, ku, k)
        groups.append({"t0": last, "top": int(top), "du": np.array(d, np.int64),
                       "si": np.frombuffer(sq[j:j + k], np.uint8).copy(),
                       "qf": fq[j:j + k].astype(np.uint16),
                       "qa": np.frombuffer(aq[j:j + k], np.uint8).copy(),
                       "qp": np.frombuffer(pq[j:j + k], np.uint8).copy()})
        j += k
    return {"groups": groups}

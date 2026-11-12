"""Generator 2: modes (SMS_PLAN.md stage 4). Decaying sines, each an onset
time, frequency, decay rate, level and phase. A mode starts sharp at its
onset sample and rings down, so nothing sounds before the hit.

Analysis, on what the partials left:

1. Onsets from the audio: hops whose short-window power rises ONSET_DB
   over the mean power of the PAST_S before them, within FLOOR_DB of the
   note's loudest hop, at least GAP_S apart. The onset is the first sample
   within REFINE_DB of the hit's peak, so a mode never starts early.
2. At each onset, candidate poles by ESPRIT in octave sub-bands, each
   analysed with OVERLAP of its width on either side (shifted to base band
   and decimated in one FFT), ORDER poles per band, on up to SEG_S of
   signal. A pole is kept only from the band it falls in, so a pole near an
   edge is seen well inside some band's analysis. Poles closer than they
   can be told apart (their half-widths plus one bin of the window) are
   merged into the stronger.
3. Levels and phases of all candidates by one joint least-squares fit over
   the onset's window (to the next onset, at most SEG_S).
4. A mode is kept only if it explains its own band: with the others fixed,
   the band's residual over the mode's ring time is at least GAIN_DB lower
   with it than without. The worst failing modes are dropped and the rest
   refitted until all pass. Then at most CAP modes per onset, the ones that
   explain the most energy. Past the cap the sound is dense and is left to
   the noise. Steps 3-5 run once per rise in RISE_S; the rise kept is the
   one the card (step 6) scores best.
5. Frequency and decay are quantized, levels and phases refitted on the
   quantized poles and quantized relative to the onset's loudest mode. The
   onset is kept only if what is rendered lowers the energy from the onset
   to the next one by GROUP_DB; else the sound there is dense and belongs
   to the noise.
6. The set is judged by report_card.card itself, on the onset's span
   (CARD_PAD_S before it to the ring's end), with noise analysed by
   gen_noise from what is left after the modes and rendered at the
   harness's seeds. Accepted only if the missed band-frames fall in total
   and no band's det_over band-frames rise. While some band's det_over
   rises, the modes in the band where it rose most are dropped; then each
   dropped mode is tried back, most energy first, and kept if the misses
   fall further with no band's det_over rising. What is rendered is what
   the next onset and the noise are given.

hint: "src" (the channel) and "det" (what the generators before this one
render) let step 6 judge as the card does; without them the left signal
stands for the source and det is zero.

Nothing here knows the instrument. Every constant is one value for all.
"""
from __future__ import annotations

import numpy as np
from scipy import fft as sfft

import gen_noise
import need_map as nm
import pinst_codec as pc
import report_card as rc

RANDOM = False

# onsets
ON_HOP_S = 0.003
ON_WIN_S = 0.012
PAST_S = 0.05
ONSET_DB = 9.0
FLOOR_DB = -40.0
GAP_S = 0.05
REFINE_DB = 30.0     # the onset sample: first within this of the hit's peak amplitude

# poles
SEG_S = 1.0          # longest fit window; a mode must fall DECAY_DB within it
DECAY_DB = 40.0
Q_MIN = 2.0          # at least this many radians of ring per neper of decay
F_LO = 20.0
SUB_EDGES = (0.0, 100.0, 200.0, 400.0, 800.0, 1600.0, 3200.0, 6400.0, 12800.0)
OVERLAP = 0.5        # each sub-band is analysed this much of its width past either edge
ORDER = 10
ESP_MAX_N = 4096     # decimated samples per sub-band, at most
ESP_SKIP_S = 0.002   # the first instants of a hit are left out of the pole fit

# selection
GAIN_DB = 1.0
RING_DB = 30.0       # a mode's band is judged over the time it takes to fall this far
CAP = 24
GROUP_DB = 3.0       # an onset's modes must take this much of the energy there
CARD_PAD_S = 0.2     # the card is run this far either side of what an onset's modes touch
RISE_S = (0.0, 0.0005, 0.001, 0.002, 0.004)  # an onset's rise, fitted per onset from these
ATTACK_S = 0.02     # the rise is fitted on the start of the hit this long

TRACE = None         # a list to log selection steps into (debugging)

# quantization
QF_LO, QF_HI = 16.0, 24000.0
QD_LO, QD_HI = 0.5, 40000.0
QA_STEP = 0.5        # dB, a mode's level under its onset's top
QT_STEP = 1.0        # dB, an onset's top level
QT_TOP = 100.0       # dB re full scale, the highest top (255 steps down from here)


# ---------------------------------------------------------------- onsets

def onsets(x, sr):
    n = len(x)
    hop, win = max(1, int(round(ON_HOP_S * sr))), max(1, int(round(ON_WIN_S * sr)))
    F = max(1, n // hop)
    i = np.arange(F) * hop
    c = np.concatenate([[0.0], np.cumsum(x * x)])
    now = np.maximum(c[np.minimum(i + win, n)] - c[i], 0.0) / win  # power of [i, i+win)
    P = int(PAST_S * sr)
    a = np.maximum(i - P, 0)
    past = np.maximum(c[i] - c[a], 0.0) / P
    db = 10 * np.log10(now + 1e-30)
    top = db.max()
    rise = db - 10 * np.log10(past + 1e-30)
    hit = (rise > ONSET_DB) & (db > top + FLOOR_DB)
    out = []
    gap = int(GAP_S * sr)
    for k in np.flatnonzero(hit):
        s = _refine(x, int(i[k]), win)
        if not out or s - out[-1] >= gap:
            out.append(s)
    return out


def _refine(x, i, win):
    """The hit's first sample: from win before i, the first sample within
    REFINE_DB of the peak amplitude in the 2 win after i."""
    a = max(0, i - win)
    seg = np.abs(x[a : i + 2 * win])
    if len(seg) == 0:
        return i
    k = np.flatnonzero(seg > seg.max() * 10 ** (-REFINE_DB / 20))
    return a + int(k[0]) if len(k) else i


# ---------------------------------------------------------------- poles

def _esprit(y, p):
    N = len(y)
    L = min(N // 2, 256)
    if L < p + 2:
        return np.zeros(0, complex)
    M = N - L + 1
    Y = np.lib.stride_tricks.sliding_window_view(y, L)[:M].T  # L x M
    R = Y @ Y.conj().T
    w, V = np.linalg.eigh(R)
    U = V[:, ::-1][:, :p]
    Phi = np.linalg.lstsq(U[:-1], U[1:], rcond=None)[0]
    return np.linalg.eigvals(Phi)


def candidates(s, sr):
    """(f Hz, d 1/s) pole candidates in segment s (starts at the onset)."""
    skip = int(ESP_SKIP_S * sr)
    s = s[skip:]
    W = len(s)
    Nf = sfft.next_fast_len(2 * W)
    X = sfft.fft(s, Nf)
    fr = sfft.fftfreq(Nf, 1 / sr)
    edges = list(SUB_EDGES) + [sr / 2]
    d_min = np.log(10 ** (DECAY_DB / 20)) / SEG_S
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        if lo >= sr / 2:
            break
        m = OVERLAP * (hi - lo)
        alo, ahi = max(lo - m, 0.0), min(hi + m, sr / 2)
        # flat over [lo - m/2, hi + m/2], raised cosine out to [lo - m, hi + m]
        flo, fhi = max(lo - m / 2, 0.0), min(hi + m / 2, sr / 2)
        fc = 0.5 * (alo + ahi)
        rate = 1.25 * (ahi - alo)
        D = max(1, int(sr // rate))
        Nd = Nf // D
        rate = Nd * sr / Nf      # the rate the shortened spectrum's inverse is at
        g = np.zeros(Nf)
        pos = (fr >= alo) & (fr <= ahi)
        f = fr[pos]
        w = np.ones_like(f)
        if flo > alo:
            r = f < flo
            w[r] = 0.5 - 0.5 * np.cos(np.pi * (f[r] - alo) / (flo - alo))
        if ahi > fhi:
            r = f > fhi
            w[r] = 0.5 + 0.5 * np.cos(np.pi * (f[r] - fhi) / (ahi - fhi))
        g[pos] = w
        Z = X * g
        k0 = int(round(fc * Nf / sr))
        idx = (np.arange(Nd) - Nd // 2 + k0) % Nf
        Zb = np.zeros(Nd, complex)
        Zb[(np.arange(Nd) - Nd // 2) % Nd] = Z[idx]
        yb = sfft.ifft(Zb) * (Nd / Nf)
        fc = k0 * sr / Nf
        nb = min(int(np.ceil(W * rate / sr)), ESP_MAX_N, Nd)
        yb = yb[:nb]
        if np.sum(np.abs(yb) ** 2) <= 0:
            continue
        z = _esprit(yb, ORDER)
        z = z[np.abs(z) > 1e-9]
        f = fc + np.angle(z) * rate / (2 * np.pi)
        d = -np.log(np.abs(z)) * rate
        ok = (f >= max(lo, F_LO)) & (f < hi) & (d >= d_min) & (np.pi * f >= Q_MIN * d)
        out += list(zip(f[ok], d[ok]))
    return out


def merge(s, f, d, sr):
    """Poles closer than they can be told apart on s are one: keep the
    stronger (by its own projection on s). Apart means the gap is over the
    sum of their half-widths (d / 2 pi each) plus one bin of the window."""
    f, d = np.asarray(f, float), np.asarray(d, float)
    if len(f) < 2:
        return f, d
    A = _basis(f, d, len(s), sr)
    K = len(f)
    c, sn = A[:, :K], A[:, K:]
    p = ((c.T @ s) ** 2 / np.maximum(np.sum(c * c, 0), 1e-30)
         + (sn.T @ s) ** 2 / np.maximum(np.sum(sn * sn, 0), 1e-30))
    res = sr / len(s)
    keep = []
    for k in np.argsort(-p):
        if all(abs(f[k] - f[j]) > (d[k] + d[j]) / (2 * np.pi) + res for j in keep):
            keep.append(k)
    keep = np.sort(np.array(keep, int))
    return f[keep], d[keep]


# ---------------------------------------------------------------- fit

def _rise(W, R):
    """The onset's rise over its first R samples (raised sine), 1 after; R=0 is sharp."""
    r = np.ones(W)
    if R > 0:
        k = np.arange(min(R, W))
        r[: len(k)] = 0.5 - 0.5 * np.cos(np.pi * (k + 1) / (R + 1))
    return r


def _basis(f, d, W, sr, R=0):
    """W x 2K: per pole a damped cosine, then the sines, from sample 0 with
    the onset's rise R."""
    t = np.arange(W) / sr
    env = np.exp(-np.outer(t, d)) * _rise(W, R)[:, None]
    ph = 2 * np.pi * np.outer(t, f)
    return np.concatenate([env * np.cos(ph), env * np.sin(ph)], 1)


class _Fit:
    """Joint least squares on any subset of a fixed set of poles, from one
    Gram matrix."""

    def __init__(self, s, f, d, sr, R=0):
        self.K = len(f)
        self.A = _basis(f, d, len(s), sr, R)
        self.G = self.A.T @ self.A
        self.b = self.A.T @ s

    def solve(self, idx):
        cols = np.concatenate([idx, idx + self.K])
        G = self.G[np.ix_(cols, cols)]
        G = G + np.eye(len(cols)) * 1e-12 * np.trace(G) / len(cols)
        c = np.linalg.lstsq(G, self.b[cols], rcond=1e-12)[0]
        return c, cols

    def renders(self, idx):
        c, cols = self.solve(idx)
        k = len(idx)
        return self.A[:, cols[:k]] * c[:k] + self.A[:, cols[k:]] * c[k:], np.stack([c[:k], c[k:]], 1)


def _fit(s, f, d, sr, R=0):
    """Levels (cos, sin) of each pole on s: joint least squares."""
    if len(f) == 0:
        return np.zeros((0, 2))
    return _Fit(s, f, d, sr, R).renders(np.arange(len(f)))[1]


def rise_of(s, f, d, sr):
    """The onset's rise (index into RISE_S): the one under which all the
    candidates together explain the start of s (its first ATTACK_S) best."""
    T = min(len(s), int(ATTACK_S * sr))
    best, out = None, 0
    for i, r in enumerate(RISE_S):
        R = int(round(r * sr))
        fit = _Fit(s, f, d, sr, R)
        Y, _ = fit.renders(np.arange(len(f)))
        e = s[:T] - Y[:T].sum(1)
        e = float(e @ e)
        if best is None or e < best:
            best, out = e, i
    return out


def _band_of(f, d, erb):
    k = int(np.clip(np.searchsorted(erb, f) - 1, 0, len(erb) - 2))
    bw = d / np.pi
    return min(erb[k], f - bw), max(erb[k + 1], f + bw)


def _band_energy(r, lo, hi, sr, Nf):
    R = sfft.rfft(r, Nf)
    fr = sfft.rfftfreq(Nf, 1 / sr)
    m = (fr >= lo) & (fr < hi)
    return float(np.sum(np.abs(R[m]) ** 2))


def _gains(s, Y, f, d, sr, erb):
    """dB by which each mode (column of Y) lowers the residual in its own
    band, the others held, over its ring time; and the energy it explains
    there."""
    W = len(s)
    r = s - Y.sum(1)
    g = np.zeros(len(f))
    ex = np.zeros(len(f))
    for k in range(len(f)):
        T = int(min(W, max(int(0.01 * sr), np.log(10 ** (RING_DB / 20)) / d[k] * sr)))
        Nf = sfft.next_fast_len(T)
        lo, hi = _band_of(f[k], d[k], erb)
        e1 = _band_energy(r[:T], lo, hi, sr, Nf)
        e0 = _band_energy(r[:T] + Y[:T, k], lo, hi, sr, Nf)
        g[k] = 10 * np.log10((e0 + 1e-30) / (e1 + 1e-30))
        ex[k] = e0 - e1
    return g, ex, r


# ---------------------------------------------------------------- the card itself

def _counts(src, det, left, sr, ref, a, b):
    """The report card on src with this det and noise analysed (gen_noise)
    from this left at the card's seeds, cut to [a - CARD_PAD_S, b + CARD_PAD_S):
    per band, the missed and the det_over band-frames in [a, b)."""
    return nm.memo(_MEMO, (src, det, left, sr, ref, a, b), lambda: _counts_run(src, det, left, sr, ref, a, b))


_MEMO = {}


def _counts_run(src, det, left, sr, ref, a, b):
    n = len(src)
    H = nm.HOP
    pad = int(CARD_PAD_S * sr)
    c0 = max(0, (a - pad) // H * H)
    c1 = min(n, b + pad)
    ns = gen_noise.analyse(left, sr, {"src": src})
    noises = [gen_noise.render(ns, n, sr, sd, c0, c1) for sd in nm.SEEDS]
    c = rc.card(src[c0:c1], det[c0:c1], noises, sr, ref=ref)
    f0, f1 = max(0, (a - c0) // H), int(np.ceil((b - c0) / H))
    k, aud = c["kind"][f0:f1], c["audible"][f0:f1]
    miss = ((k >= 0) & aud).sum(0)
    over = ((k == rc.KINDS.index("det_over")) & aud).sum(0)
    return miss, over, c["edges"]


def select(s, f, d, sr, cap=True, R=0):
    """The poles (f, d) that each explain their own band, at most CAP, the
    ones that explain the most energy first."""
    erb = np.concatenate([[0.0], pc.erb_edges(), [sr / 2]])
    f0, d0 = np.asarray(f, float), np.asarray(d, float)
    fit = _Fit(s, f0, d0, sr, R)
    idx = np.arange(len(f0))
    while len(idx):
        f, d = f0[idx], d0[idx]
        Y, _ = fit.renders(idx)
        g, ex, r = _gains(s, Y, f, d, sr, erb)
        keep = np.ones(len(f), bool)
        bad = np.flatnonzero(g < GAIN_DB)
        if len(bad):
            # drop the worst half of the failing ones (at least one)
            o = bad[np.argsort(g[bad])]
            keep[o[: max(1, len(o) // 2)]] = False
        elif cap and len(f) > CAP:
            keep[:] = False
            keep[np.argsort(-ex)[:CAP]] = True
        else:
            # most explained energy first
            idx = idx[np.argsort(-ex)]
            break
        idx = idx[keep]
    return f0[idx], d0[idx]


# ---------------------------------------------------------------- quantization

def _qf(f):
    return np.clip(np.round(np.log(f / QF_LO) / np.log(QF_HI / QF_LO) * 65535), 0, 65535).astype(np.uint16)


def _df(q):
    return QF_LO * (QF_HI / QF_LO) ** (q.astype(float) / 65535)


def _qd(d):
    return np.clip(np.round(np.log(d / QD_LO) / np.log(QD_HI / QD_LO) * 255), 0, 255).astype(np.uint8)


def _dd(q):
    return QD_LO * (QD_HI / QD_LO) ** (q.astype(float) / 255)


def _qa(c):
    """(top, qa, qp): the onset's top level (1 byte, QT_STEP dB under
    QT_TOP, rounded up), each mode's level under it (QA_STEP dB) and phase."""
    a = np.hypot(c[:, 0], c[:, 1])
    ph = np.arctan2(-c[:, 1], c[:, 0])  # a cos(wt + ph) = a cos ph cos wt - a sin ph sin wt
    adb = 20 * np.log10(a + 1e-300)
    top = int(np.clip(np.floor((QT_TOP - adb.max()) / QT_STEP), 0, 255))
    tdb = QT_TOP - top * QT_STEP
    qa = np.clip(np.round((tdb - adb) / QA_STEP), 0, 255).astype(np.uint8)
    qp = (np.round(ph / (2 * np.pi) * 256) % 256).astype(np.uint8)
    return top, qa, qp


def _da(top, qa, qp):
    tdb = QT_TOP - top * QT_STEP
    return 10 ** ((tdb - qa.astype(float) * QA_STEP) / 20), qp.astype(float) * 2 * np.pi / 256


# ---------------------------------------------------------------- interface

def _group(s, fq, dq, ri, R, t0, sr):
    if len(fq) == 0:
        return None
    c = _fit(s, fq, dq, sr, R)
    top, qa, qp = _qa(c)
    live = qa < 255
    if not live.any():
        return None
    return {"t0": t0, "top": top, "rise": ri, "qf": _qf(fq)[live], "qd": _qd(dq)[live],
            "qa": qa[live], "qp": qp[live]}


def _accept(src, det, x, s, fq, dq, ri, R, t0, end, span, sr, ref, base):
    """The onset's group as the card takes it, or None. All the poles
    together must first take GROUP_DB of the energy to the next onset (else
    the sound is dense and belongs to the noise). Then the card on the
    onset's span (report_card.card, noise from gen_noise on what the modes
    leave, at the card's seeds): the set is taken if the card's misses fall
    in total and no band's det_over band-frames rise. While some band's
    det_over rises, the modes in the band where it rose most are dropped (if
    none is in it, the one nearest it) and the rest refitted. Then each
    dropped mode, most explained energy first, is tried back and kept if the
    misses fall further and still no band's det_over rises."""
    n = len(x)
    e0 = float(np.dot(x[t0:end], x[t0:end]))
    g = _group(s, fq, dq, ri, R, t0, sr)
    if g is None:
        return None
    r = x[t0:end] - _render_group(g, n, sr)[t0:end]
    gdb = 10 * np.log10((e0 + 1e-30) / (float(np.dot(r, r)) + 1e-30))
    if gdb < GROUP_DB:
        if TRACE is not None:
            TRACE.append(("group_db", t0, len(g["qf"]), round(gdb, 2)))
        return None
    m0, o0, edges = base
    fa, da = fq, dq                      # every pole, for the second pass

    def judge(fq, dq):
        g = _group(s, fq, dq, ri, R, t0, sr)
        if g is None:
            return None, None, None
        y = _render_group(g, n, sr)
        m1, o1, _ = _counts(src, det + y, x - y, sr, ref, *span)
        if TRACE is not None:
            up = o1 - o0
            TRACE.append(("card", t0, len(g["qf"]), int(m0.sum()), int(m1.sum()), int(o0.sum()), int(o1.sum()),
                          [(round(edges[b]), int(m1[b] - m0[b]), int(up[b])) for b in np.flatnonzero(up > 0)][:8]))
        return g, m1, o1

    g, m1, o1 = judge(fq, dq)
    while g is not None and (o1 > o0).any():
        # drop the modes in the band whose det_over rose most (if none is
        # in it, the one nearest it) and refit the rest
        wb = int(np.argmax(o1 - o0))
        f = _df(g["qf"])
        band = np.clip(np.searchsorted(edges, f) - 1, 0, len(edges) - 2)
        inb = np.flatnonzero(band == wb)
        k = inb if len(inb) else np.argmin(np.abs(np.log(f / np.sqrt(edges[wb] * edges[wb + 1]))))
        keep = ~np.isin(np.round(fq, 6), np.round(np.atleast_1d(f[k]), 6))
        fq, dq = fq[keep], dq[keep]
        g, m1, o1 = judge(fq, dq)
    if g is None:
        fq, dq, cur = fq[:0], dq[:0], m0.sum()
    else:
        cur = m1.sum()
    # second pass: each dropped pole, most explained energy first, comes
    # back if with it the misses fall and no band's det_over rises
    for k in range(len(fa)):
        if np.any(np.isclose(fq, fa[k])):
            continue
        t = np.concatenate([fq, fa[k : k + 1]]), np.concatenate([dq, da[k : k + 1]])
        g2, m2, o2 = judge(*t)
        if g2 is not None and m2.sum() < cur and not (o2 > o0).any():
            fq, dq, cur, g = t[0], t[1], m2.sum(), g2
    if g is None or cur >= m0.sum():
        return None
    return _group(s, fq, dq, ri, R, t0, sr)


def analyse(left, sr, hint):
    x = np.asarray(left, float).copy()
    n = len(x)
    src = np.asarray(hint.get("src", left), float)
    det = np.asarray(hint["det"], float).copy() if "det" in hint else np.zeros(n)
    edges = pc.erb_edges(nm.MODEL.noise_bands)
    px, _ = nm.band_stats([src], sr, edges)
    ref = float(px.max())
    ons = onsets(x, sr)
    groups = []
    for j, t0 in enumerate(ons):
        end = ons[j + 1] if j + 1 < len(ons) else n
        W = int(min(end - t0, SEG_S * sr))
        if W < int(0.01 * sr):
            continue
        s = x[t0 : t0 + W]
        cand = candidates(s, sr)
        if not cand:
            continue
        f, d = merge(s, *zip(*cand), sr)
        # the card is judged until the slowest candidate has fallen out of
        # what is audible (AUDIBLE_DB), past the next onset if it rings on
        ring = np.log(10 ** (-nm.AUDIBLE_DB / 20)) / np.min(d) * sr
        span = (t0 - int(CARD_PAD_S * sr), t0 + int(min(n - t0, max(W, ring))))
        # the rise: the one under which the whole set does best on the card
        base = _counts(src, det, x, sr, ref, *span)
        best = None
        for ri in range(len(RISE_S)):
            R = int(round(RISE_S[ri] * sr))
            fr, dr = select(s, f, d, sr, R=R)
            if len(fr) == 0:
                continue
            # quantize the poles, then check them again as stored
            fq, dq = select(s, _df(_qf(fr)), _dd(_qd(dr)), sr, cap=False, R=R)
            g = _group(s, fq, dq, ri, R, int(t0), sr)
            if g is None:
                continue
            y = _render_group(g, n, sr)
            m1, o1, _ = _counts(src, det + y, x - y, sr, ref, *span)
            score = m1.sum() + np.maximum(o1 - base[1], 0).sum()
            if TRACE is not None:
                TRACE.append(("rise", t0, RISE_S[ri], len(fq), int(m1.sum()), int(o1.sum()), int(score)))
            if best is None or score < best[0]:
                best = (score, ri, R, fq, dq)
        if best is None:
            continue
        _, ri, R, fq, dq = best
        g = _accept(src, det, x, s, fq, dq, ri, R, int(t0), end, span, sr, ref, base)
        if g is None:
            continue
        y = _render_group(g, n, sr)
        groups.append(g)
        x -= y
        det += y
    return {"groups": groups}


def _render_group(g, n, sr):
    t0 = g["t0"]
    f, d = _df(g["qf"]), _dd(g["qd"])
    a, ph = _da(g["top"], g["qa"], g["qp"])
    R = int(round(RISE_S[g.get("rise", 0)] * sr))
    y = np.zeros(n)
    for k in range(len(f)):
        T = int(min(n - t0, np.ceil(np.log(10 ** (120 / 20)) / d[k] * sr)))  # to -120 dB
        t = np.arange(T) / sr
        y[t0 : t0 + T] += a[k] * np.exp(-d[k] * t) * np.cos(2 * np.pi * f[k] * t + ph[k]) * _rise(T, R)
    return y


def render(s, n, sr, seed=0):
    y = np.zeros(n)
    for g in s["groups"]:
        y += _render_group(g, n, sr)
    return y


def pack(s):
    """Streams: per onset the sample delta (varint), count, top level and rise;
    per mode the frequency (2 bytes, log, delta in rising order), decay,
    level under the top and phase (1 byte each)."""
    hdr = bytearray()
    fq, dq, aq, pq = bytearray(), bytearray(), bytearray(), bytearray()
    last = 0
    for g in s["groups"]:
        v = g["t0"] - last
        last = g["t0"]
        while True:
            b = v & 0x7F
            v >>= 7
            hdr.append(b | (0x80 if v else 0))
            if not v:
                break
        hdr.append(len(g["qf"]))
        hdr.append(g["top"])
        hdr.append(g["rise"])
        o = np.argsort(g["qf"])
        q = g["qf"][o].astype(np.int64)
        dlt = np.diff(np.concatenate([[0], q]))
        fq += dlt.astype("<u2").tobytes()
        dq += g["qd"][o].tobytes()
        aq += g["qa"][o].tobytes()
        pq += g["qp"][o].tobytes()
    if not hdr:
        return b""
    return b"".join(pc.lz_bytes(bytes(b)) for b in (hdr, fq, dq, aq, pq))


def unpack(z):
    """bytes -> settings, as pack wrote them (modes in rising frequency)."""
    hdr, fq, dq, aq, pq = pc.lz_split(z, 5)
    fq = np.frombuffer(fq, "<u2").astype(np.int64)
    groups, i, j, last = [], 0, 0, 0
    while i < len(hdr):
        v = s = 0
        while True:          # unsigned varint, as pack writes it
            c = hdr[i]; i += 1
            v |= (c & 0x7F) << s; s += 7
            if not c & 0x80:
                break
        last += v
        k, top, rise = hdr[i], hdr[i + 1], hdr[i + 2]
        i += 3
        groups.append({"t0": last, "top": int(top), "rise": int(rise),
                       "qf": np.cumsum(fq[j:j + k]).astype(np.uint16),
                       "qd": np.frombuffer(dq[j:j + k], np.uint8).copy(),
                       "qa": np.frombuffer(aq[j:j + k], np.uint8).copy(),
                       "qp": np.frombuffer(pq[j:j + k], np.uint8).copy()})
        j += k
    return {"groups": groups}

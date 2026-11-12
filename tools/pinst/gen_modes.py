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
   refitted until all pass. Then the card's det_over test, in the card's
   bands and windows: where the source is audible, the deterministic
   output plus noise at the power of what is left may not run LEVEL_DB / 2
   over the source in more excess than without the modes. While it does,
   the mode whose absence lowers the excess most is dropped. Then at most
   CAP modes per onset, the ones that explain the most energy. Past the cap
   the sound is dense and is left to the noise.
5. Frequency and decay are quantized, levels and phases refitted on the
   quantized poles and quantized relative to the onset's loudest mode. The
   onset is kept only if what is rendered lowers the energy from the onset
   to the next one by GROUP_DB; else the sound there is dense and belongs
   to the noise. What is rendered is what the next onset and the noise are
   given.

hint: "src" (the channel) and "det" (what the generators before this one
render) let step 4 judge as the card does; without them the left signal
stands for the source and det is zero.

Nothing here knows the instrument. Every constant is one value for all.
"""
from __future__ import annotations

import numpy as np
from scipy import fft as sfft

import need_map as nm
import pinst_codec as pc

RANDOM = False

# onsets
ON_HOP_S = 0.003
ON_WIN_S = 0.012
PAST_S = 0.05
ONSET_DB = 9.0
FLOOR_DB = -40.0
GAP_S = 0.05
REFINE_DB = 20.0     # the onset sample: first within this of the hit's peak amplitude

# poles
SEG_S = 1.0          # longest fit window; a mode must fall DECAY_DB within it
DECAY_DB = 40.0
Q_MIN = 2.0          # at least this many radians of ring per neper of decay
F_LO = 20.0
SUB_EDGES = (0.0, 100.0, 200.0, 400.0, 800.0, 1600.0, 3200.0, 6400.0, 12800.0)
OVERLAP = 0.5        # each sub-band is analysed this much of its width past either edge
ORDER = 16
ESP_MAX_N = 4096     # decimated samples per sub-band, at most
ESP_SKIP_S = 0.002   # the first instants of a hit are left out of the pole fit

# selection
GAIN_DB = 1.0
RING_DB = 30.0       # a mode's band is judged over the time it takes to fall this far
CAP = 24
GROUP_DB = 3.0       # an onset's modes must take this much of the energy there
OVER_FRAC = 0.02     # det_over band-frames the modes may add, as a share of the audible ones
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


# ---------------------------------------------------------------- the card's det_over test

class _Card:
    """The report card's det_over measure on one onset's window, in its
    bands and windows (need_map.band_stats: Hann windows of the band's
    length, power over one window length), framed at a quarter window.
    det_over: where the source is audible, det plus noise at the power of
    what is left runs over the source by more than LEVEL_DB / 2."""

    def __init__(self, src, det, t0, W, sr, ref):
        edges = pc.erb_edges(nm.MODEL.noise_bands)
        plan = nm._plan(sr, edges)
        self.sr, self.t0, self.W = sr, t0, W
        self.groups = []                       # per window length: (N, H, bins a..e, band starts)
        for N in sorted({p[0] for p in plan}):
            bands = [(a, e) for (n, a, e) in plan if n == N]
            a0, e0 = min(b[0] for b in bands), max(b[1] for b in bands)
            starts = np.array([a - a0 for a, _ in bands])
            self.groups.append((N, N // 4, a0, e0, starts))
        self.lim = 10 ** ((nm.LEVEL_DB / 2) / 10)
        self.S = [self._spec(src, N, H, a, e) for N, H, a, e, _ in self.groups]
        self.Dp = [self._spec(det, N, H, a, e) for N, H, a, e, _ in self.groups]
        self.px = [self._pow(np.abs(S) ** 2, k) for k, S in enumerate(self.S)]
        self.thr = ref * 10 ** (nm.AUDIBLE_DB / 10)
        self.aud = [p > self.thr for p in self.px]

    def _spec(self, x, N, H, a, e):
        """Complex spectra (frames, bins a..e) of x around [t0, t0+W): frames
        centred every H samples from t0 - N/2 to t0 + W."""
        F = int(np.ceil((self.W + N // 2) / H))
        lo = self.t0 - N // 2 - N // 2
        L = (F - 1) * H + N
        buf = np.zeros(L)
        i0, i1 = max(lo, 0), min(lo + L, len(x))
        if i1 > i0:
            buf[i0 - lo : i1 - lo] = x[i0:i1]
        fr = np.lib.stride_tricks.sliding_window_view(buf, N)[::H][:F]
        return np.fft.rfft(fr * np.hanning(N + 1)[:-1], axis=1)[:, a:e].astype(np.complex64)

    def _segspec(self, Y, k):
        """Spectra of mode renders (W x K, starting at t0) for group k: (K, frames, bins)."""
        N, H, a, e, _ = self.groups[k]
        F = int(np.ceil((self.W + N // 2) / H))
        L = (F - 1) * H + N
        o = N  # t0 sits N samples into the buffer (lo = t0 - N)
        n = min(Y.shape[0], L - o)
        w = np.hanning(N + 1)[:-1]
        out = np.zeros((Y.shape[1], F, e - a), np.complex64)
        buf = np.zeros(L)
        for k in range(Y.shape[1]):
            buf[o : o + n] = Y[:n, k]
            fr = np.lib.stride_tricks.sliding_window_view(buf, N)[::H][:F]
            out[k] = np.fft.rfft(fr * w, axis=1)[:, a:e]
        return out

    def _pow(self, P, k):
        """Bin power (..., frames, bins) -> band power over one window (..., frames, bands)."""
        starts = self.groups[k][4]
        b = np.add.reduceat(P, starts, axis=-1)
        # one window length = 4 frames at a quarter-window hop
        c = np.cumsum(b, axis=-2)
        c = np.concatenate([np.zeros_like(c[..., :1, :]), c], axis=-2)
        F = b.shape[-2]
        i = np.arange(F)
        lo, hi = np.maximum(i - 2, 0), np.minimum(i + 2, F)
        return (c[..., hi, :] - c[..., lo, :]) / (hi - lo)[:, None]

    def prepare(self, Y):
        """Spectra of the current set's mode renders Y (W x K)."""
        self.Y = [self._segspec(Y, k) for k in range(len(self.groups))]

    def _excess(self, pd, pl, k):
        both = pd + pl
        x = np.maximum(10 * np.log10((both + 1e-30) / (self.px[k] * self.lim + 1e-30)), 0.0)
        # audible as the card has it: the source or the output (a mode
        # ringing on where the source has gone quiet is heard)
        aud = self.aud[k] | (both > self.thr)
        if self.cells:
            return np.sum(aud & (x > 0), axis=(-2, -1)).astype(float)
        return np.sum(np.where(aud, x, 0.0), axis=(-2, -1))

    cells = False

    def audible(self):
        return float(sum(a.sum() for a in self.aud))

    def excess(self, drop=None, none=False, cells=False):
        """Total excess (dB summed over audible band-frames, or with
        cells=True the number of band-frames over) of the set, or, with
        drop=True, of the set less each mode in turn (array), or with
        none=True of no modes at all."""
        self.cells = cells
        tot = 0.0
        for k in range(len(self.groups)):
            Dp, Lf = self.Dp[k], self.S[k] - self.Dp[k]   # left = src - det
            if none:
                tot = tot + self._excess(self._pow(np.abs(Dp) ** 2, k), self._pow(np.abs(Lf) ** 2, k), k)
                continue
            Ys = self.Y[k]
            Ysum = Ys.sum(0)
            if drop:
                pd = self._pow(np.abs(Dp + Ysum - Ys) ** 2, k)
                pl = self._pow(np.abs(Lf - Ysum + Ys) ** 2, k)
            else:
                pd = self._pow(np.abs(Dp + Ysum) ** 2, k)
                pl = self._pow(np.abs(Lf - Ysum) ** 2, k)
            tot = tot + self._excess(pd, pl, k)
        return tot


def select(s, f, d, sr, card, cap=True, R=0):
    """The poles (f, d) that each explain their own band and add no det_over,
    at most CAP."""
    erb = np.concatenate([[0.0], pc.erb_edges(), [sr / 2]])
    f0, d0 = np.asarray(f, float), np.asarray(d, float)
    fit = _Fit(s, f0, d0, sr, R)
    idx = np.arange(len(f0))
    base = None
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
        else:
            # judged over all the time the modes ring, not just the fit window
            c, _ = fit.solve(idx)
            A = _basis(f, d, card.W, sr, R)
            k = len(idx)
            card.prepare(A[:, :k] * c[:k] + A[:, k:] * c[k:])
            if base is None:
                base = float(card.excess(none=True, cells=True)) + OVER_FRAC * card.audible()
            if float(card.excess(cells=True)) > base:
                now = float(card.excess())
                # drop the mode that removes the most excess per energy it
                # explains (a mode whose absence removes none goes last)
                cost = card.excess(drop=True)
                gain = now - cost
                k = int(np.argmax(gain / np.maximum(ex, 1e-30))) if (gain > 1e-6).any() else int(np.argmin(ex))
                keep[k] = False
                if TRACE is not None:
                    TRACE.append(("over", float(card.excess(cells=True)), round(base, 1), round(now, 1), round(float(cost[k]), 1), round(f[k]), round(d[k]), round(g[k], 1)))
            elif cap and len(f) > CAP:
                keep[:] = False
                keep[np.argsort(-ex)[:CAP]] = True
            else:
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

def analyse(left, sr, hint):
    x = np.asarray(left, float).copy()
    n = len(x)
    src = np.asarray(hint.get("src", left), float)
    det = np.asarray(hint["det"], float).copy() if "det" in hint else np.zeros(n)
    edges = pc.erb_edges(nm.MODEL.noise_bands)
    px, _ = nm.band_stats([src], sr, edges)
    ref = 10 ** (px.max() / 10)
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
        card = _Card(src, det, t0, int(min(n - t0, max(W, ring))), sr, ref)
        ri = rise_of(s, f, d, sr)
        R = int(round(RISE_S[ri] * sr))
        f, d = select(s, f, d, sr, card, R=R)
        if len(f) == 0:
            continue
        # quantize the poles, then check them again as stored
        fq, dq = select(s, _df(_qf(f)), _dd(_qd(d)), sr, card, cap=False, R=R)
        if len(fq) == 0:
            continue
        qf, qd = _qf(fq), _qd(dq)
        c = _fit(s, fq, dq, sr, R)
        top, qa, qp = _qa(c)
        live = qa < 255
        if not live.any():
            continue
        g = {"t0": int(t0), "top": top, "rise": ri, "qf": qf[live], "qd": qd[live], "qa": qa[live], "qp": qp[live]}
        y = _render_group(g, n, sr)
        # the onset as a whole must be mostly modes: if they take less than
        # GROUP_DB of what is there up to the next onset, the sound is dense
        # and belongs to the noise
        e0 = float(np.dot(x[t0:end], x[t0:end]))
        r = x[t0:end] - y[t0:end]
        if TRACE is not None:
            TRACE.append(("group", t0, len(qf), round(10 * np.log10((e0 + 1e-30) / (float(np.dot(r, r)) + 1e-30)), 2)))
        if 10 * np.log10((e0 + 1e-30) / (float(np.dot(r, r)) + 1e-30)) < GROUP_DB:
            continue
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

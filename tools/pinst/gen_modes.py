"""Generator 2: modes (SMS_PLAN.md stage 4). Decaying sines, each an onset
time, frequency, decay rate, level and phase. A mode starts at its onset and
rings down, so nothing sounds before the hit.

Analysis, on what the partials left:

1. Onsets from the audio: frames whose short-window power rises ONSET_DB
   over the mean power of the PAST_S before them, within FLOOR_DB of the
   note's loudest frame, at least GAP_S apart.
2. At each onset, candidate poles by ESPRIT in octave sub-bands (each band
   shifted to base band and decimated in one FFT), ORDER poles per band, on
   up to SEG_S of signal.
3. Levels and phases of all candidates by one joint least-squares fit over
   the onset's window (to the next onset, at most SEG_S).
4. A mode is kept only if it explains its own band: with the others fixed,
   the band's residual over the mode's ring time is at least GAIN_DB lower
   with it than without. The worst failing modes are dropped and the rest
   refitted until all pass. Then the output (modes, plus noise at the
   power of what they leave) is checked per ERB band and FRAME: where the
   source is audible it may not run BAND_GROW_DB over it. While dropping one
   mode lowers that excess, the one that lowers it most is dropped. Then at
   most CAP modes per onset, the ones that explain the most energy. Past the
   cap the sound is dense and is left to the noise.
5. Frequency and decay are quantized, levels and phases refitted on the
   quantized poles and quantized. The onset is kept only if what is
   rendered from the stored values lowers the energy from the onset on by
   GROUP_DB; else the sound there is dense and belongs to the noise. What
   is rendered is what the next onset and the noise are given.

Nothing here knows the instrument. Every constant is one value for all.
"""
from __future__ import annotations

import numpy as np
from scipy import fft as sfft

import pinst_codec as pc

RANDOM = False

# onsets
ON_HOP = 128
ON_WIN = 512
PAST_S = 0.05
ONSET_DB = 9.0
FLOOR_DB = -40.0
GAP_S = 0.05

# poles
SEG_S = 1.0          # longest fit window; a mode must fall DECAY_DB within it
DECAY_DB = 40.0
Q_MIN = 2.0          # at least this many radians of ring per neper of decay
F_LO = 20.0
SUB_EDGES = (0.0, 100.0, 200.0, 400.0, 800.0, 1600.0, 3200.0, 6400.0, 12800.0)
ORDER = 10
ESP_MAX_N = 4096     # decimated samples per sub-band, at most
ESP_SKIP_S = 0.002   # the first instants of a hit are left out of the pole fit

# selection
GAIN_DB = 1.0
RING_DB = 30.0       # a mode's band is judged over the time it takes to fall this far
CAP = 24
GROUP_DB = 3.0       # an onset's modes must take this much of the energy there
ATTACK_S = 0.001     # every mode rises over this long (raised sine)
FRAME = 2048         # band-frames the output is checked in (hop FRAME / 4)
BAND_GROW_DB = 6.0   # no band-frame of the output (modes + noise at what they leave) may be this much louder than the source
ADD_FLOOR_DB = -60.0 # ... where the source is within this of its loudest band-frame (the card's audible floor)

TRACE = None         # a list to log selection steps into (debugging)

# quantization
QF_LO, QF_HI = 16.0, 24000.0
QD_LO, QD_HI = 0.5, 40000.0
QA_STEP = 0.5        # dB
QA_TOP = 12.0        # dB re full scale, highest storable level


# ---------------------------------------------------------------- onsets

def onsets(x, sr):
    n = len(x)
    F = max(1, n // ON_HOP)
    i = np.arange(F) * ON_HOP
    c = np.concatenate([[0.0], np.cumsum(x * x)])
    now = np.maximum(c[np.minimum(i + ON_WIN, n)] - c[i], 0.0) / ON_WIN  # power of [i, i+WIN)
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
        s = _refine(x, int(i[k]), sr)
        if not out or s - out[-1] >= gap:
            out.append(s)
    return out


def _refine(x, i, sr):
    """The hit's first sample: the first 32-sample block from ON_WIN before i
    within 20 dB of the loudest block in the 2 ON_WIN after that."""
    B = 32
    a = max(0, i - ON_WIN)
    seg = x[a : i + 2 * ON_WIN]
    m = len(seg) // B
    if m == 0:
        return i
    e = np.mean(seg[: m * B].reshape(m, B) ** 2, 1)
    k = np.flatnonzero(e > e.max() * 1e-2)
    return a + int(k[0]) * B if len(k) else i


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
        m = (hi - lo) / 4
        alo, ahi = max(lo - m, 0.0), min(hi + m, sr / 2)
        fc = 0.5 * (alo + ahi)
        rate = 1.25 * (ahi - alo)
        D = max(1, int(sr // rate))
        rate = sr / D
        Nd = Nf // D
        # smooth band window: flat on [lo, hi], raised cosine over the margins
        g = np.zeros(Nf)
        pos = (fr >= alo) & (fr <= ahi)
        f = fr[pos]
        w = np.ones_like(f)
        if lo > alo:
            r = f < lo
            w[r] = 0.5 - 0.5 * np.cos(np.pi * (f[r] - alo) / (lo - alo))
        if ahi > hi:
            r = f > hi
            w[r] = 0.5 + 0.5 * np.cos(np.pi * (f[r] - hi) / (ahi - hi))
        g[pos] = w
        Z = X * g
        # shift fc to 0 and keep the Nd bins around it
        k0 = int(round(fc * Nf / sr))
        idx = (np.arange(Nd) - Nd // 2 + k0) % Nf
        Zb = np.zeros(Nd, complex)
        Zb[(np.arange(Nd) - Nd // 2) % Nd] = Z[idx]
        yb = sfft.ifft(Zb) * (Nd / Nf)
        fc = k0 * sr / Nf
        nb = min(int(np.ceil(W / D)), ESP_MAX_N, Nd)
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


# ---------------------------------------------------------------- fit

def _ramp(W, sr):
    """Every mode's onset: a raised-sine rise over ATTACK_S, so a start does
    not spray a click over the high bands."""
    w = np.ones(W)
    A = min(W, max(1, int(round(ATTACK_S * sr))))
    w[:A] = np.sin(0.5 * np.pi * (np.arange(A) + 0.5) / A) ** 2
    return w


def _basis(f, d, W, sr):
    """W x 2K: per pole a ramped damped cosine, then the sines."""
    t = np.arange(W) / sr
    env = np.exp(-np.outer(t, d)) * _ramp(W, sr)[:, None]
    ph = 2 * np.pi * np.outer(t, f)
    return np.concatenate([env * np.cos(ph), env * np.sin(ph)], 1)


class _Fit:
    """Joint least squares on any subset of a fixed set of poles, from one
    Gram matrix."""

    def __init__(self, s, f, d, sr):
        self.K = len(f)
        self.A = _basis(f, d, len(s), sr)
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


def _fit(s, f, d, sr):
    """Levels (cos, sin) of each pole on s: joint least squares."""
    if len(f) == 0:
        return np.zeros((0, 2))
    return _Fit(s, f, d, sr).renders(np.arange(len(f)))[1]


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


def _frames(X, sr):
    """Short-time spectra of the columns of X: (columns, frames, bins)."""
    L, H = FRAME, FRAME // 4
    W = X.shape[0]
    F = max(1, int(np.ceil(W / H)))
    P = np.zeros(((F - 1) * H + L, X.shape[1]))
    P[:W] = X
    i = np.arange(F)[:, None] * H + np.arange(L)[None, :]
    win = np.hanning(L)
    return sfft.rfft(P[i].transpose(2, 0, 1) * win, axis=2).astype(np.complex64)


class _Over:
    """Per ERB band and frame, how far an output's power runs over the
    source's, in dB summed over the band-frames where the source is audible."""

    def __init__(self, s, sr):
        erb = np.concatenate([[0.0], pc.erb_edges(), [sr / 2]])
        nb = len(erb) - 1
        b = np.clip(np.searchsorted(erb, np.fft.rfftfreq(FRAME, 1 / sr)) - 1, 0, nb - 1)
        self.B = np.zeros((len(b), nb), np.float32)
        self.B[np.arange(len(b)), b] = 1.0
        ps = (np.abs(_frames(s[:, None], sr)[0]) ** 2) @ self.B
        self.aud = ps > ps.max() * 10 ** (ADD_FLOOR_DB / 10)
        self.lim = ps[self.aud] * 10 ** (BAND_GROW_DB / 10)

    def excess(self, p):
        po = (p @ self.B)[self.aud]
        return float(np.sum(np.maximum(10 * np.log10(po / self.lim + 1e-30), 0.0)))


def select(s, f, d, sr, cap=True):
    """The poles (f, d) that each explain their own band, at most CAP."""
    erb = np.concatenate([[0.0], pc.erb_edges(), [sr / 2]])
    sf = _Over(s, sr)
    f0, d0 = np.asarray(f, float), np.asarray(d, float)
    fit = _Fit(s, f0, d0, sr)
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
        else:
            # what the output will be per ERB band and frame: the modes, plus
            # noise at the power of what they leave. It may not come out
            # louder than the source where the source is audible. Drop the
            # one mode whose absence lowers that excess most, while one does.
            Ys = _frames(Y, sr)                    # (k, frames, bins)
            Ysum = Ys.sum(0)
            R = _frames(r[:, None], sr)[0]
            now = sf.excess(np.abs(Ysum) ** 2 + np.abs(R) ** 2)
            cost = np.array([sf.excess(np.abs(Ysum - Ys[k]) ** 2 + np.abs(R + Ys[k]) ** 2)
                             for k in range(len(f))]) if now > 0 else np.zeros(0)
            if now > 0 and cost.min() < now:
                keep[int(np.argmin(cost))] = False
                if TRACE is not None:
                    k = int(np.argmin(cost))
                    TRACE.append(("over", round(now, 1), round(cost[k], 1), round(f[k]), round(d[k]), round(g[k], 1)))
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
    a = np.hypot(c[:, 0], c[:, 1])
    ph = np.arctan2(-c[:, 1], c[:, 0])  # a cos(wt + ph) = a cos ph cos wt - a sin ph sin wt
    qa = np.clip(np.round((QA_TOP - 20 * np.log10(a + 1e-30)) / QA_STEP), 0, 255).astype(np.uint8)
    qp = (np.round(ph / (2 * np.pi) * 256) % 256).astype(np.uint8)
    return qa, qp


def _da(qa, qp):
    return 10 ** ((QA_TOP - qa.astype(float) * QA_STEP) / 20), qp.astype(float) * 2 * np.pi / 256


# ---------------------------------------------------------------- interface

def analyse(left, sr, hint):
    x = np.asarray(left, float).copy()
    n = len(x)
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
        f, d = zip(*cand)
        f, d = select(s, f, d, sr)
        if len(f) == 0:
            continue
        # quantize the poles, then check them again as stored
        fq, dq = select(s, _df(_qf(f)), _dd(_qd(d)), sr, cap=False)
        if len(fq) == 0:
            continue
        qf, qd = _qf(fq), _qd(dq)
        c = _fit(s, fq, dq, sr)
        qa, qp = _qa(c)
        live = qa < 255
        g = {"t0": int(t0), "qf": qf[live], "qd": qd[live], "qa": qa[live], "qp": qp[live]}
        if not live.any():
            continue
        y = _render_group(g, n, sr)
        # the onset as a whole must be mostly modes: if they take less than
        # GROUP_DB of what is there, the sound is dense and belongs to noise
        e0 = float(np.dot(x[t0:], x[t0:]))
        r = x[t0:] - y[t0:]
        if 10 * np.log10((e0 + 1e-30) / (float(np.dot(r, r)) + 1e-30)) < GROUP_DB:
            continue
        groups.append(g)
        x -= y
    return {"groups": groups}


def _render_group(g, n, sr):
    t0 = g["t0"]
    f, d = _df(g["qf"]), _dd(g["qd"])
    a, ph = _da(g["qa"], g["qp"])
    y = np.zeros(n)
    for k in range(len(f)):
        T = int(min(n - t0, np.ceil(np.log(10 ** (120 / 20)) / d[k] * sr)))  # to -120 dB
        t = np.arange(T) / sr
        y[t0 : t0 + T] += a[k] * _ramp(T, sr) * np.exp(-d[k] * t) * np.cos(2 * np.pi * f[k] * t + ph[k])
    return y


def render(s, n, sr, seed=0):
    y = np.zeros(n)
    for g in s["groups"]:
        y += _render_group(g, n, sr)
    return y


def pack(s):
    """Streams: per onset the sample delta (varint) and count; per mode the
    frequency (2 bytes, log), decay, level and phase (1 byte each)."""
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

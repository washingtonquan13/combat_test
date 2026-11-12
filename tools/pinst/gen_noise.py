"""Generator 4: band noise (SMS_PLAN.md stage 2).

The 40 ERB bands (need_map.MODEL.noise_bands) each get a level every HOP
samples, stored as breakpoints per band.

- Shape. Band b's response rises from the centre of band b-1 to its own
  centre and falls to the centre of band b+1 (cosine in log frequency; the
  squares of neighbouring bands sum to one). The rendered spectrum is
  therefore a smooth line through the band levels, not a staircase flat
  inside each band, so it follows the source's slope inside a band and
  across band edges, wherever another grid cuts it. Each band plays its
  own noise table with that response: TABLE_N samples of seeded white
  noise (the players' integer hash), one FFT, the response applied, one
  inverse FFT. A table is periodic, so it loops without a seam. The tables
  depend only on the sample rate: a player builds them once. The note's
  seed picks where in each table the note starts reading.
- Envelope. The band's gain is set at every HOP-th sample and moves
  linearly in amplitude between them. It does not filter the noise.

Analysis: what is left is split with the same responses (one long FFT).
The band's power is its Hilbert power p(t), and the level at frame t is

    min(L, K * S)

  L  p averaged over a Hann window of CYCLES periods of the band's width
     (at least one HOP): the estimate, its variance low enough to code;
  S  p averaged over SHORT_CYCLES periods: the band locally.

Then one common gain G(t) = Q / sum_b level where that is under
1 / HEADROOM, else 1, where Q is x^2 over
the HOP either side of frame t, weighted as the linear gain ramp weights
it, the quieter side: the bands together cannot be louder than everything
there is where that frame's gain sounds. A per-band bound does not do
this: 40 bands each allowed up to the bound sum to 40 times it, and that
was the pre-echo before a hit. G is one more breakpoint track; render
multiplies the summed bands by it (1 outside its span). Every average uses
only samples inside the note, normalised by the window weight that lies
inside: what is before sample 0 is unknown, not silence, so the first
frame is measured, not muted. With squared responses summing to one,
g^2 = band power over unit-power tables gives the noise the source's power
density at each band centre, interpolated between.

Coding: levels in dB relative to the note's loudest band-frame (measured on
the source, note_top, not on what is left), Q_DB steps
down to need_map.AUDIBLE_DB, LO_DB steps below it (quiet bands only need
to be quiet), nothing under FLOOR_DB. Each band sounds over one span of
frames; bp_code codes the spans' breakpoints (tol 1 step). A band with no
frame above FLOOR_DB has no span and costs nothing to render. unpack()
turns the bytes back into the settings render() reads.

Render cost per output sample: one table read and one multiply-add per
band that has a span there, one gain step per band (the linear ramp), and
one multiply for G. There is no FFT at play time.
"""
from __future__ import annotations

import hashlib

import numpy as np
from scipy import fft as sfft
from scipy.signal import fftconvolve

import bp_code
import need_map as nm
import pinst_codec as pc

RANDOM = True
HOP = nm.HOP
TABLE_N = 1 << 17          # band noise table length (3 s at 44.1 kHz)
TABLE_SEED = 0x51A7        # the tables' own hash seed: fixed, not per note
CYCLES = 4.0               # level window: this many periods of the band's width
SHORT_CYCLES = 1.0         # local band window: the shortest the band's width allows
K_LOCAL = 10.0             # how far (power ratio) the level may exceed a local measure
HEADROOM = 2.0             # the bands' sum may exceed Q by this (power) before G cuts:
                           # Q's quieter side is low on steady noise (G = 1 there
                           # holds white noise to 0.3 dB; cutting at once, 1.7 dB low)
FLOOR_DB = nm.MODEL.noise_floor   # under the note's loudest band-frame: no sound
AUDIBLE_DB = nm.AUDIBLE_DB        # under it relative to the top, coarse steps
Q_DB = 1.5                 # level step, dB, down to AUDIBLE_DB
LO_DB = 6.0                # level step, dB, below AUDIBLE_DB
TOL = 1                    # breakpoint tolerance, steps
SILENT = -np.inf           # a grid value: no sound


def _edges():
    return pc.erb_edges(nm.MODEL.noise_bands)


def _bins(f, edges):
    """Per band, the [a, e) range of frequency bins f inside its edges:
    disjoint, every band at least one bin (for measuring by band)."""
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        a, e = int(np.searchsorted(f, lo)), int(np.searchsorted(f, hi))
        out.append((a, max(e, a + 1)))
    return out


def shapes(f, edges):
    """(bands, len(f)) amplitude responses: band b is 1 at its centre and
    crosses to its neighbours' centres as cos / sin of a quarter turn over
    log frequency, so squares sum to one from the first band's lower edge
    to the last band's upper edge. Outside those, the outer bands fall to
    zero over the same log distance as from that edge to their centre
    (and stop at Nyquist)."""
    B = len(edges) - 1
    c = np.sqrt(edges[:-1] * edges[1:])
    lf = np.log(np.maximum(f, 1e-9))
    W = np.zeros((B, len(f)))
    lc, le = np.log(c), np.log(edges)

    def ramp(w, a, z, rise):
        m = (lf >= a) & (lf < z)
        u = (lf[m] - a) / (z - a)
        w[m] = np.sin(0.5 * np.pi * u) if rise else np.cos(0.5 * np.pi * u)

    for b in range(B):
        w = np.zeros(len(f))
        if b == 0:
            w[(lf >= le[0]) & (lf < lc[0])] = 1.0
            ramp(w, 2 * le[0] - lc[0], le[0], True)
        else:
            ramp(w, lc[b - 1], lc[b], True)
        if b == B - 1:
            w[(lf >= lc[b]) & (lf < le[-1])] = 1.0
            ramp(w, le[-1], 2 * le[-1] - lc[b], False)
        else:
            ramp(w, lc[b], lc[b + 1], False)
        W[b] = w
    return W


_TABLES = {}


def tables(sr):
    """(bands, TABLE_N) float32 band noise at unit power, for sample rate sr."""
    if sr not in _TABLES:
        u = pc.hash_uniform(TABLE_SEED, 0, TABLE_N) * np.sqrt(3.0)
        U = np.fft.rfft(u)
        W = shapes(np.fft.rfftfreq(TABLE_N, 1 / sr), _edges())
        T = np.zeros((W.shape[0], TABLE_N))
        for b in range(W.shape[0]):
            t = np.fft.irfft(U * W[b], TABLE_N)
            T[b] = t / np.sqrt(np.mean(t * t))
        _TABLES[sr] = T.astype(np.float32)
    return _TABLES[sr]


def offsets(seed, nb):
    """Where each band starts reading its table for this seed."""
    u = pc.hash_uniform(int(seed) & 0xFFFFFFFF, 0x7000_0000, nb)
    return ((u + 1.0) * 0.5 * TABLE_N).astype(np.int64) % TABLE_N


def _mean(p, win, idx):
    """p averaged over a centred Hann of win samples, at idx, using only the
    samples inside p (normalised by the window weight inside)."""
    w = np.hanning(int(win) + 2)[1:-1]
    num = fftconvolve(p, w, mode="same")[idx]
    den = fftconvolve(np.ones(len(p)), w, mode="same")[idx]
    return np.maximum(num, 0.0) / np.maximum(den, 1e-12)


def _local_power(p, idx):
    """x^2 where the gain at each frame sounds: the HOP either side, weighted as
    the linear gain ramp weights it (a triangle); the quieter side of the two,
    so a frame next to a hit does not take the hit's level. A side that is
    mostly outside the note is unknown: the other side stands."""
    n = len(p)
    r = np.arange(1, HOP + 1) / HOP                # rises to the frame
    out_l = np.zeros(len(idx)); out_r = np.zeros(len(idx))
    for i, t in enumerate(idx):
        seg = p[max(0, t - HOP + 1): t + 1]; wl = r[HOP - len(seg):]
        out_l[i] = (seg * wl).sum() / wl.sum()
        seg = p[t: min(n, t + HOP)]; wr = r[::-1][: len(seg)]
        out_r[i] = (seg * wr).sum() / wr.sum()
        if len(wl) < HOP // 2: out_l[i] = out_r[i]
        if len(wr) < HOP // 2: out_r[i] = out_l[i]
    return np.minimum(out_l, out_r)


def band_power(x, sr, edges):
    """(frames, bands) level of x's bands at every HOP-th sample, power; and
    the (frames,) common gain G <= 1 (power) that brings the bands' sum down
    to what x holds where that frame's gain sounds, when it is over by more
    than HEADROOM."""
    n = len(x)
    F = int(np.ceil(n / HOP))
    bw = np.diff(edges)
    pad = int(np.max(CYCLES * sr / bw)) + HOP
    L = sfft.next_fast_len(n + 2 * pad)
    X = sfft.rfft(x, L, workers=-1)
    f = sfft.rfftfreq(L, 1 / sr)
    idx = np.minimum(np.arange(F) * HOP, n - 1)
    W = shapes(f, edges)
    Qloc = _local_power(x * x, idx)
    P = np.zeros((F, len(bw)))
    for b in range(len(bw)):
        nz = np.nonzero(W[b])[0]
        a, e = nz[0], nz[-1] + 1
        Z = np.zeros(L, np.complex128)
        Z[a:e] = X[a:e] * W[b, a:e]        # analytic band
        z = sfft.ifft(Z, workers=-1)[:n]
        p = 2.0 * np.abs(z) ** 2           # real band power
        Lb = _mean(p, max(HOP, round(CYCLES * sr / bw[b])), idx)
        Sb = _mean(p, max(HOP, round(SHORT_CYCLES * sr / bw[b])), idx)
        P[:, b] = np.minimum(Lb, K_LOCAL * Sb)
    # the bands together against everything there is, where they sound
    tot = P.sum(1)
    G = Qloc / np.maximum(tot, 1e-300)
    G[G >= 1 / HEADROOM] = 1.0
    G[tot <= 0] = 1.0
    return P, G


# ------------------------------------------------------------- coding

_CA = round(AUDIBLE_DB / Q_DB)            # the code at AUDIBLE_DB


def _to_code(u):
    """dB relative to the top -> float code (steps)."""
    u = np.asarray(u, float)
    return np.where(u >= AUDIBLE_DB, u / Q_DB, _CA + (u - AUDIBLE_DB) / LO_DB)


def _from_code(c):
    c = np.asarray(c, float)
    return np.where(c >= _CA, c * Q_DB, AUDIBLE_DB + (c - _CA) * LO_DB)


def encode_grid(db, gain=None, top=None):
    """(frames, bands) dB grid (SILENT where silent), and the (frames,) common
    gain in dB (None: 0) -> bytes."""
    F, B = db.shape
    top = float(np.max(db[np.isfinite(db)])) if top is None else top
    topq = int(round(2 * top))
    top = topq / 2
    tracks, side = [], []
    for b in range(B):
        live = np.isfinite(db[:, b]) & (db[:, b] - top >= FLOOR_DB)
        if not live.any():
            continue
        s = int(np.argmax(live)); e = F - int(np.argmax(live[::-1]))
        u = np.maximum(db[s:e, b] - top, FLOOR_DB)
        tracks.append((s, np.rint(_to_code(u)).astype(np.int64)))
        side.append([b, topq])
    if gain is not None:
        g = np.rint(np.maximum(np.asarray(gain, float), FLOOR_DB) / Q_DB).astype(np.int64)
        if g.any():
            nz = np.nonzero(g)[0]
            s, e = int(nz[0]), int(nz[-1]) + 1
            tracks.append((s, g[s:e])); side.append([B, 0])
    return bp_code.encode(tracks, TOL, side)


def unpack(z):
    """bytes -> settings: per sounding band, its first frame and its decoded
    dB line (absolute); the common gain (first frame, dB line) or None."""
    out, gain = [], None
    for s, keys, kv, sd in bp_code.decode(z):
        line = bp_code.expand(keys, kv, int(keys[-1]) + 1)[:, 0]
        if sd[0] == nm.MODEL.noise_bands:
            gain = (int(s), line * Q_DB)
        else:
            out.append((int(sd[0]), int(s), sd[1] / 2 + _from_code(line)))
    return {"tracks": out, "gain": gain, "z": z}


def grid(s, F, B=None):
    """settings -> (F, bands) dB grid, SILENT outside the spans."""
    B = nm.MODEL.noise_bands if B is None else B
    g = np.full((F, B), SILENT)
    for b, st, line in s["tracks"]:
        e = min(F, st + len(line))
        g[st:e, b] = line[: e - st]
    return g


def from_grid(db):
    """A dB grid (tests) -> settings, through the bytes."""
    return unpack(encode_grid(db))


_TOP = {}   # source fingerprint -> its loudest band-frame (dB); card runs reuse it


def note_top(src, sr):
    """The note's loudest band-frame, dB, measured on the source as the
    noise measures its bands. The coding's top: the floor and the level grid
    hang from it. Measured on what is left instead, they would move with
    whatever the generators before noise take (one that takes the loudest
    frame drops the floor by tens of dB and re-rounds every level in the
    note, changing bytes and misses far from what it took)."""
    x = np.ascontiguousarray(src, dtype=float)
    key = (len(x), sr, hashlib.blake2b(x.tobytes(), digest_size=16).digest())
    if key not in _TOP:
        if len(_TOP) >= 16:
            _TOP.clear()
        P, _ = band_power(x, sr, _edges())
        _TOP[key] = float(10 * np.log10(P.max())) if (P > 0).any() else None
    return _TOP[key]


def analyse(left, sr, hint):
    """hint["src"], when given, is the note: the coding's top is measured on
    it (note_top). Without it, `left` is taken to be the note."""
    P, G = band_power(np.asarray(left, float), sr, _edges())
    db = 10 * np.log10(P + 1e-300)
    db[P <= 0] = SILENT
    top = note_top(hint["src"], sr) if hint.get("src") is not None else None
    return unpack(encode_grid(db, 10 * np.log10(np.maximum(G, 1e-300)), top=top))


def render(s, n, sr, seed=0):
    T = tables(sr)
    off = offsets(seed, T.shape[0])
    y = np.zeros(n)
    t = np.arange(n)
    F = int(np.ceil(n / HOP))
    for b, st, line in s["tracks"]:
        e = min(F, st + len(line))
        if e <= st:
            continue
        # gain at the span's frames; zero one frame either side, so a band
        # that starts after frame 0 ramps in over one HOP (and out after)
        fr = np.arange(st, e)
        amp = 10 ** (line[: e - st] / 20)
        if st > 0:
            fr = np.r_[st - 1, fr]; amp = np.r_[0.0, amp]
        if e < F:
            fr = np.r_[fr, e]; amp = np.r_[amp, 0.0]
        a0 = fr[0] * HOP
        a1 = n if e == F else min(n, fr[-1] * HOP + 1)   # the last span holds to the end
        tt = t[a0:a1]
        g = np.interp(tt, fr * HOP, amp)
        y[a0:a1] += g * T[b, (off[b] + tt) % TABLE_N]
    if s.get("gain") is not None:
        st, line = s["gain"]
        fr = np.arange(st - 1, st + len(line) + 1)
        amp = np.r_[1.0, 10 ** (line / 20), 1.0]
        y *= np.interp(t, fr * HOP, amp)
    return y


def pack(s):
    return s["z"]

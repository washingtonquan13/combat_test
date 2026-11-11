"""Generator 4: band noise (SMS_PLAN.md stage 2).

The 40 ERB bands (need_map.MODEL.noise_bands) each get a level every HOP
samples, stored as breakpoints per band. The band shape and the envelope
step are separate:

- Shape. Each band plays its own band-limited noise table: TABLE_N samples
  of seeded white noise (the players' integer hash), one FFT, the band's
  bins kept and nothing else, one inverse FFT. A table is periodic, so it
  loops without a seam, and it holds no energy outside its band. The tables
  depend only on the sample rate: a player builds them once. The note's
  seed picks where in each table the note starts reading.
- Envelope. The band's gain is set at every HOP-th sample and moves
  linearly in amplitude between them. It does not filter the noise, so the
  128-sample step does not widen the band beyond what the envelope's own
  motion does.

Analysis: what is left is split into the same bands (one long FFT; the
bands meet in power-complementary quarter-cosine crossovers XOVER wide, not
brick walls, whose 1/t time tails smeared attacks and decays), the band's power is its Hilbert envelope power, averaged over
CYCLES periods of the band's width (at least one HOP), read at every HOP-th
sample. The gain is the square root of that power over the table's power,
so the noise's expected band power is what was left in the band.

Render cost per output sample: one table read and one multiply-add per
sounding band, plus one gain step per band (the linear ramp). There is no
FFT at play time.
"""
from __future__ import annotations

import numpy as np
from scipy import fft as sfft
from scipy.signal import fftconvolve

import need_map as nm
import pinst_codec as pc

RANDOM = True
HOP = nm.HOP
TABLE_N = 1 << 17          # band noise table length (3 s at 44.1 kHz)
TABLE_SEED = 0x51A7        # the tables' own hash seed: fixed, not per note
CYCLES = 4.0               # level window: this many periods of the band's width
XOVER = 1.0                # analysis crossover width, in units of the narrower neighbour's width
FLOOR_DB = nm.MODEL.noise_floor   # under the note's loudest band-frame: silent
Q_DB = 1.5                 # level quantum, dB
TOL_DB = 1.5               # breakpoint tolerance, dB
MAX_SPAN = 64              # frames between breakpoints at most
SILENT = -200.0


def _edges():
    return pc.erb_edges(nm.MODEL.noise_bands)


def _bins(f, edges):
    """Per band, the [a, e) range of frequency bins f it owns: disjoint, every
    band at least one bin."""
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        a, e = int(np.searchsorted(f, lo)), int(np.searchsorted(f, hi))
        out.append((a, max(e, a + 1)))
    return out


_TABLES = {}


def tables(sr):
    """(bands, TABLE_N) float32 band noise at unit power, for sample rate sr."""
    if sr not in _TABLES:
        edges = _edges()
        u = pc.hash_uniform(TABLE_SEED, 0, TABLE_N) * np.sqrt(3.0)
        U = np.fft.rfft(u)
        f = np.fft.rfftfreq(TABLE_N, 1 / sr)
        T = np.zeros((len(edges) - 1, TABLE_N))
        for b, (a, e) in enumerate(_bins(f, edges)):
            Z = np.zeros_like(U)
            Z[a:e] = U[a:e]
            t = np.fft.irfft(Z, TABLE_N)
            T[b] = t / np.sqrt(np.mean(t * t))
        _TABLES[sr] = T.astype(np.float32)
    return _TABLES[sr]


def offsets(seed, nb):
    """Where each band starts reading its table for this seed."""
    u = pc.hash_uniform(int(seed) & 0xFFFFFFFF, 0x7000_0000, nb)
    return ((u + 1.0) * 0.5 * TABLE_N).astype(np.int64) % TABLE_N


def analysis_shapes(f, edges):
    """(bands, len(f)) amplitude responses of the analysis bands: flat inside,
    a quarter-cosine crossover XOVER times the narrower neighbour's width
    wide at each edge, power-complementary (squares sum to one), so a flat
    spectrum measures the same as with brick-wall bands but the bands' time
    responses have short tails. The rendered bands stay brick-wall."""
    B = len(edges) - 1
    bw = np.diff(edges)
    W = np.zeros((B, len(f)))
    for b in range(B):
        lo, hi = edges[b], edges[b + 1]
        w = ((f >= lo) & (f < hi)).astype(float)
        if XOVER > 0:
            for j, e in ((b, lo), (b + 1, hi)):
                # the outer edges too: a brick-wall edge anywhere gives the
                # band a slow 1/t time tail
                d = XOVER * min(bw[max(j - 1, 0)], bw[min(j, B - 1)])
                if e + d / 2 > f[-1]:
                    d = 2 * (f[-1] - e)
                u = np.clip((f - (e - d / 2)) / d, 0.0, 1.0)     # 0 below the crossover, 1 above
                m = (f >= e - d / 2) & (f < e + d / 2)
                w[m] = np.sin(0.5 * np.pi * u[m]) if j == b else np.cos(0.5 * np.pi * u[m])
        W[b] = w
    return W


def band_power(x, sr, edges):
    """(frames, bands) power of x's bands at every HOP-th sample, in dB."""
    n = len(x)
    F = int(np.ceil(n / HOP))
    bw = np.diff(edges)
    win = np.maximum(HOP, np.round(CYCLES * sr / bw)).astype(int)
    pad = int(win.max())
    L = sfft.next_fast_len(n + 2 * pad)
    X = sfft.rfft(x, L, workers=-1)
    f = sfft.rfftfreq(L, 1 / sr)
    idx = np.minimum(np.arange(F) * HOP, n - 1)
    P = np.zeros((F, len(bw)))
    W = analysis_shapes(f, edges)
    for b in range(len(bw)):
        nz = np.nonzero(W[b])[0]
        a, e = nz[0], nz[-1] + 1
        Z = np.zeros(L, np.complex128)
        Z[a:e] = X[a:e] * W[b, a:e]        # analytic band: |z|^2 = 2 x_band^2 on average
        z = sfft.ifft(Z, workers=-1)[:n]
        p = 2.0 * np.abs(z) ** 2           # real band power (|2Z|^2 / 2)
        w = np.hanning(win[b] + 2)[1:-1]
        P[:, b] = np.maximum(fftconvolve(p, w / w.sum(), mode="same")[idx], 0.0)
    return 10 * np.log10(P + 1e-30)


def _encode(db):
    """Per band breakpoints of the quantized dB track. Returns (stream, decoded dB)."""
    F, B = db.shape
    out = bytearray(pc._ints([F]))
    dec = np.full((F, B), SILENT)
    for b in range(B):
        v = db[:, b]
        if (v <= SILENT).all():
            out += pc._ints([0])
            continue
        keys = pc.keyframes(v[:, None], np.array([TOL_DB]), MAX_SPAN)
        q = np.round(np.maximum(v[keys], SILENT) / Q_DB).astype(np.int64)
        out += pc._ints([len(keys)])
        out += pc._ints(np.stack([pc._deltas(keys), pc._deltas(q)], axis=1))
        dec[:, b] = np.interp(np.arange(F), keys, q * Q_DB)
    return bytes(out), dec


def analyse(left, sr, hint):
    edges = _edges()
    db = band_power(np.asarray(left, float), sr, edges)
    db = np.where(db < db.max() + FLOOR_DB, SILENT, db)
    # A note is preceded by silence: every band starts from zero gain at
    # sample 0 and ramps to its level at HOP. Starting a noise table at full
    # gain would put a step at sample 0, which is broadband.
    db[0] = SILENT
    stream, dec = _encode(db)
    return {"db": dec, "stream": stream}


def render(s, n, sr, seed=0):
    T = tables(sr)
    db = s["db"]
    off = offsets(seed, T.shape[0])
    y = np.zeros(n)
    t = np.arange(n)
    F = db.shape[0]
    for b in range(T.shape[0]):
        if (db[:, b] <= SILENT).all():
            continue
        g = np.interp(t, np.arange(F) * HOP, np.where(db[:, b] <= SILENT, 0.0, 10 ** (db[:, b] / 20)))
        y += g * T[b, (off[b] + t) % TABLE_N]
    return y


def pack(s):
    return pc.lz_bytes(s["stream"])

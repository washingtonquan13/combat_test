"""numpy port of the metal-gtx-head.sfz <effect> chain plus the band's cab IR,
so a baked DI note can be heard the way the game plays it. The filters and
disto follow sfizz's code; the compressor is a plain feed-forward stand-in.
Both sides of every A/B go through the same chain."""
from __future__ import annotations

import numpy as np
import soundfile as sf
from scipy.signal import lfilter, resample_poly, fftconvolve

SR = 44100
CAB = "samples/cab/jester-brutal/Impulses/44.1kHz/14_Cathode_Ray_Fleshburn_44.wav"


def _biquad(b, a, x):
    return lfilter(np.array(b) / a[0], np.array(a) / a[0], x, axis=0)


def hpf(x, fc, q=0.7071):
    w = 2 * np.pi * fc / SR
    al = np.sin(w) / (2 * q)
    c = np.cos(w)
    return _biquad([(1 + c) / 2, -(1 + c), (1 + c) / 2], [1 + al, -2 * c, 1 - al], x)


def peak(x, fc, bw_oct, gain_db):
    A = 10 ** (gain_db / 40)
    w = 2 * np.pi * fc / SR
    al = np.sin(w) * np.sinh(np.log(2) / 2 * bw_oct * w / np.sin(w))
    c = np.cos(w)
    return _biquad([1 + al * A, -2 * c, 1 - al * A], [1 + al / A, -2 * c, 1 - al / A], x)


def comp(x, thr_db=-26, ratio=4, att=0.005, rel=0.100):
    lvl = 20 * np.log10(np.abs(x).max(axis=1) + 1e-12)     # stereo link
    over = np.maximum(lvl - thr_db, 0)
    ga, gr = np.exp(-1 / (att * SR)), np.exp(-1 / (rel * SR))
    env = np.empty_like(over)
    e = 0.0
    for i, v in enumerate(over):
        e = ga * e + (1 - ga) * v if v > e else gr * e + (1 - gr) * v
        env[i] = e
    return x * (10 ** (-env * (1 - 1 / ratio) / 20))[:, None]


_TABLE = 1 / (1 + np.exp(-(0.078125 * np.arange(256) - 10.0)))


def _disto_stage(x, fs, depth):
    s0 = 0.2 * depth + 2.0
    s1 = _TABLE[127] + 0.5 * (_TABLE[128] - _TABLE[127])
    prev = np.concatenate([[0.0], x[:-1]])
    ev = np.full(len(x), np.nan)
    ev[(x > prev) & (x > 0.25)] = 0.0
    ev[(x < prev) & (x < -0.25)] = 1.0
    idx = np.where(np.isnan(ev), 0, np.arange(len(x)))
    np.maximum.accumulate(idx, out=idx)
    state = np.nan_to_num(ev[idx], nan=0.0)
    c4 = np.exp(-100.0 / fs)
    rec1 = lfilter([1 - c4], [1, -c4], state)
    t2 = np.maximum(0.0, 12.75 * (s0 * x + 10.0))
    i3 = t2.astype(np.int64)
    t4 = _TABLE[np.minimum(255, i3)]
    t5 = t4 + (t2 - i3) * (_TABLE[np.minimum(255, i3 + 1)] - t4)
    t6 = rec1 * (t5 - s1 - 1.0) + (1 - rec1) * (t5 - s1)
    c1 = 125.663704 / fs
    c2, c3 = 1 / (c1 + 1), 1 - c1
    return lfilter([2 * c2, -2 * c2], [1, -c2 * c3], t6)


def disto(x, depth=85, stages=3, tone=100, dry=0.01, wet=1.0):
    mk = 21 + tone * 1.08
    fc = 440 * 2 ** ((mk - 69) / 12)
    pole = np.exp(-2 * np.pi * fc / SR)
    out = np.empty_like(x)
    for c in range(x.shape[1]):
        lp = lfilter([dry * (1 - pole)], [1, -pole], x[:, c])
        up = resample_poly(lp, 8, 1)
        for _ in range(stages):
            up = _disto_stage(up, 8 * SR, depth)
        y = resample_poly(up, 1, 8)[: len(x)]
        out[:, c] = y * wet + x[:, c] * (1 - wet)
    return out


_cab = None


def amp_cab(x: np.ndarray) -> np.ndarray:
    """x: (n, 2) DI. Returns (n + tail, 2)."""
    global _cab
    if _cab is None:
        ir, sr = sf.read(CAB, always_2d=True)
        assert sr == SR
        _cab = ir.mean(axis=1)
    y = hpf(x, 110)
    y = peak(y, 800, 1.0, 6)
    y = comp(y)
    y = y * 10 ** (18 / 20)
    y = disto(y)
    y = hpf(y, 80)
    y = peak(y, 300, 1.4, -4)
    y = y * 10 ** (-24.5 / 20)
    return np.stack([fftconvolve(y[:, c], _cab)[: len(y) + 2048] for c in range(2)], axis=1)

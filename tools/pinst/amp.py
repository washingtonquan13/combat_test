"""numpy port of the metal-gtx-head.sfz <effect> chain plus the band's cab IR,
so a baked DI note can be heard the way the game plays it. The filters and
disto follow sfizz's code; the compressor is a plain feed-forward stand-in.
Both sides of every A/B go through the same chain."""
from __future__ import annotations

import fastlib
import numpy as np
import soundfile as sf
from scipy.fft import irfft, next_fast_len, rfft
from scipy.signal import firwin, lfilter, resample_poly, fftconvolve

SR = 44100


_native = fastlib.lib
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
    if _native and x.ndim == 2 and x.shape[1] == 2:     # the lines below in one pass in C, last bits apart
        x, out = np.ascontiguousarray(x, dtype=float), np.empty(x.shape)
        _native.comp_stereo(x.ctypes.data, out.ctypes.data, len(x), thr_db, np.exp(-1 / (att * SR)),
                            np.exp(-1 / (rel * SR)), 1 - 1 / ratio)
        return out
    lvl = 20 * np.log10(np.abs(x).max(axis=1) + 1e-12)     # stereo link
    over = np.maximum(lvl - thr_db, 0)
    ga, gr = np.exp(-1 / (att * SR)), np.exp(-1 / (rel * SR))
    env = np.empty_like(over)
    if _native:
        over = np.ascontiguousarray(over)
        _native.comp_env(over.ctypes.data, env.ctypes.data, len(over), ga, gr)
    else:
        e = 0.0
        for i, v in enumerate(over):
            e = ga * e + (1 - ga) * v if v > e else gr * e + (1 - gr) * v
            env[i] = e
    return x * (10 ** (-env * (1 - 1 / ratio) / 20))[:, None]


_TABLE = 1 / (1 + np.exp(-(0.078125 * np.arange(256) - 10.0)))


_BLOCK = 16384      # samples a pass: every array of a stage stays in the cache


class _Stage:
    """One distortion stage, fed in blocks; the same numbers as one pass
    over the whole signal."""

    def __init__(self, fs, depth):
        self.s0 = 0.2 * depth + 2.0
        self.s1 = _TABLE[127] + 0.5 * (_TABLE[128] - _TABLE[127])
        self.c4 = c4 = np.exp(-100.0 / fs)
        self.f1 = ([1 - c4], [1, -c4])
        c1 = 125.663704 / fs
        c2, c3 = 1 / (c1 + 1), 1 - c1
        self.f2 = ([2 * c2, -2 * c2], [1, -c2 * c3])
        self.last_x = self.last_state = 0.0
        self.z1, self.z2 = np.zeros(1), np.zeros(1)

    def run(self, x):
        prev = np.concatenate([[self.last_x], x[:-1]])
        ev = np.full(len(x), np.nan)
        ev[(x > prev) & (x > 0.25)] = 0.0
        ev[(x < prev) & (x < -0.25)] = 1.0
        idx = np.where(np.isnan(ev), 0, np.arange(len(x)))
        np.maximum.accumulate(idx, out=idx)
        state = ev[idx]
        state[np.isnan(state)] = self.last_state
        self.last_x, self.last_state = x[-1], state[-1]
        rec1, self.z1 = lfilter(*self.f1, state, zi=self.z1)
        t2 = np.maximum(0.0, 12.75 * (self.s0 * x + 10.0))
        i3 = t2.astype(np.int64)
        t4 = _TABLE[np.minimum(255, i3)]
        t5 = t4 + (t2 - i3) * (_TABLE[np.minimum(255, i3 + 1)] - t4)
        t6 = rec1 * (t5 - self.s1 - 1.0) + (1 - rec1) * (t5 - self.s1)
        y, self.z2 = lfilter(*self.f2, t6, zi=self.z2)
        return y


def _disto_stages(x, fs, depth, stages):
    chain = [_Stage(fs, depth) for _ in range(stages)]
    out = np.empty_like(x)
    if _native:
        st, x = chain[0], np.ascontiguousarray(x)
        carry = np.zeros(4 * stages)
        _native.disto_stages(x.ctypes.data, out.ctypes.data, len(x), stages, st.s0, st.s1, st.c4,
                             st.f2[0][0], st.f2[0][1], st.f2[1][1], _TABLE.ctypes.data, carry.ctypes.data)
        return out
    for a in range(0, len(x), _BLOCK):
        y = x[a:a + _BLOCK]
        for st in chain:
            y = st.run(y)
        out[a:a + _BLOCK] = y
    return out


def _os_filters():
    """The two filters resample_poly(x, 8, 1) and resample_poly(x, 1, 8) use,
    laid out for the native pass: the up filter as 8 phases of 21 taps
    against x[i-10 .. i+10], the down filter against u[8j-80 .. 8j+80]."""
    h = firwin(161, 1 / 8, window=("kaiser", 5.0))
    hup = np.zeros((8, 21))
    for p in range(8):
        for d in range(-10, 11):
            k = p + 80 - 8 * d
            if 0 <= k <= 160:
                hup[p, d + 10] = 8 * h[k]
    return np.ascontiguousarray(hup), np.ascontiguousarray(h[::-1])


_OSF = None


def _disto_os(lp, depth, stages):
    """8x up, the distortion stages, 8x down."""
    global _OSF
    if not _native:
        up = resample_poly(lp, 8, 1)
        up = _disto_stages(up, 8 * SR, depth, stages)
        return resample_poly(up, 1, 8)[: len(lp)]
    if _OSF is None:
        _OSF = _os_filters()
    st, lp, y = _Stage(8 * SR, depth), np.ascontiguousarray(lp), np.empty(len(lp))
    _native.disto_os(lp.ctypes.data, y.ctypes.data, len(lp), _OSF[0].ctypes.data, _OSF[1].ctypes.data, stages,
                     st.s0, st.s1, st.c4, st.f2[0][0], st.f2[0][1], st.f2[1][1], _TABLE.ctypes.data)
    return y


def disto(x, depth=85, stages=3, tone=100, dry=0.01, wet=1.0):
    mk = 21 + tone * 1.08
    fc = 440 * 2 ** ((mk - 69) / 12)
    pole = np.exp(-2 * np.pi * fc / SR)
    out = np.empty_like(x)
    for c in range(x.shape[1]):
        if c and np.array_equal(x[:, c], x[:, 0]):
            out[:, c] = out[:, 0]
            continue
        lp = lfilter([dry * (1 - pole)], [1, -pole], x[:, c])
        y = _disto_os(lp, depth, stages)
        out[:, c] = y * wet + x[:, c] * (1 - wet)
    return out


_cab = None


_cab_spec = [0, None]


def _cab_conv(y):
    """fftconvolve(y, _cab), its numbers exactly, with the cab's spectrum kept
    for the next signal of the same length: a file's original and its
    rebuilds all are."""
    size = next_fast_len(len(y) + len(_cab) - 1, real=True)
    if _cab_spec[0] != size:
        _cab_spec[:] = size, rfft(_cab, size)
    return irfft(rfft(y, size) * _cab_spec[1], size)[: len(y) + len(_cab) - 1]


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
    left = _cab_conv(y[:, 0])[: len(y) + 2048]
    same = np.array_equal(y[:, 1], y[:, 0])
    return np.stack([left, left if same else _cab_conv(y[:, 1])[: len(y) + 2048]], axis=1)

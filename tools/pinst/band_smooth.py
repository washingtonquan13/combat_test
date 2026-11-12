"""A band's power, smoothed by a window and read at a few times, from the
band's own bins.

The card and the noise analysis both take a band of a signal (its bins of an
L-point FFT), make the band's time signal z, and average |z|^2 over a window
at every HOP-th sample. Done plainly that is one L-point inverse FFT per band
and signal. This gives the same numbers (to rounding) from the band's B bins:

  |z(t)|^2 = 1/L^2 sum_q R(q) e^(2 pi i q t / L),  R = the bins' autocorrelation

so the windowed power at t0 is 1/L^2 sum_q R(q) H(q) e^(2 pi i q t0 / L), with H
the window's transform: a sum over 2B-1 lags, evaluated at the read times by a
chirp-z transform. It is linear in R, so several signals' mean is one
transform of their mean R. That holds where the window lies inside the
signal; at the edges (where the plain way counts zeros outside it) z is made
over the edge samples only and the window summed there. A band whose bins are
many next to the frames read (a short note) is cheaper the plain way, and
takes it: the caller's own filter, so those numbers are the plain ones exactly.

Phases are reduced exactly in integers, so the chirps stay accurate at any L.
"""
from __future__ import annotations

import numpy as np
from scipy import fft as sfft
from scipy.signal import fftconvolve

# What one chirp-z transform costs beyond its FFTs, in FFT points (numpy
# call overhead: phases, chirps, padding).
CZT_OVERHEAD = 4096


def _phase(m, L):
    """exp(2 pi i m / L) for integer m (exact reduction mod L)."""
    return np.exp(2j * np.pi * (np.asarray(m, np.int64) % L) / L)


_CHIRPS = {}


def _chirp(s, L, J):
    """exp(i pi s j^2 / L) for j = 0..J-1 (j^2 s reduced mod 2L): one
    sequence per (s, L), kept and grown as longer prefixes are asked for."""
    c = _CHIRPS.get((s, L))
    if c is None or len(c) < J:
        if c is None and len(_CHIRPS) >= 8:
            _CHIRPS.clear()
        j = np.arange(max(J, 2 * (0 if c is None else len(c))), dtype=np.int64)
        c = np.exp(1j * np.pi * ((s * j % (2 * L)) * j % (2 * L)) / L)
        _CHIRPS[(s, L)] = c
    return c[:J]


def czt(x, m, s, n0, k0, L):
    """y_k = sum_n x_n exp(2 pi i s (n + n0)(k + k0) / L), k = 0..m-1."""
    x = np.asarray(x, np.complex128)
    N = len(x)
    n = np.arange(N, dtype=np.int64)
    k = np.arange(m, dtype=np.int64)
    if k0 % L:
        x = x * _phase(s * k0 % L * n, L)
    # nk = (n^2 + k^2 - (k - n)^2) / 2: chirps exp(i pi s j^2 / L)
    c = _chirp(s, L, max(N, m))
    M = sfft.next_fast_len(N + m - 1)
    A = np.zeros(M, np.complex128); A[:N] = x * c[:N]
    C = np.zeros(M, np.complex128)
    C[: N - 1] = np.conj(c[N - 1 : 0 : -1]); C[N - 1 : N - 1 + m] = np.conj(c[:m])
    y = sfft.ifft(sfft.fft(A, workers=-1) * sfft.fft(C, workers=-1), workers=-1)[N - 1 : N - 1 + m]
    y *= c[:m]
    if n0 % L:
        y *= _phase(s * n0 % L * (k + k0), L)
    return y


def band_signal(Zs, a, L, t_lo, t_hi):
    """z(t) = 1/L sum_k Zs_k exp(2 pi i (a + k) t / L) for t in [t_lo, t_hi):
    the band's samples, as ifft of the full spectrum would give them."""
    if t_hi <= t_lo:
        return np.zeros(0, np.complex128)
    return czt(Zs, t_hi - t_lo, 1, a, t_lo, L) / L


def _sums(v, lo, h, o, t):
    """sum_j h[j] v'[t + j + o] at each t, v' = v placed at lo and zero
    elsewhere; every window must touch v's span."""
    full = fftconvolve(v, h[::-1])
    return full[t + o - lo + len(h) - 1]


def _cost(N):
    """Rough cost of one FFT of N points, in points."""
    return sfft.next_fast_len(int(N))


def _czt_cost(N, m):
    """Three FFTs plus the chirp and phase products: about 6 FFTs' worth
    (measured against the plain path at 0.3-10 s notes)."""
    return 6 * _cost(N + m - 1) + CZT_OVERHEAD


def _runs(idx):
    """Split sorted indices into runs of consecutive values."""
    return np.split(idx, np.nonzero(np.diff(idx) > 1)[0] + 1)


def smoothed(Zss, a, L, n, windows, t0):
    """The band's windowed power, mean over signals, clamped at zero.

    Zss: each signal's bins of the band (from bin a of an L-point spectrum);
    its band signal z is on [0, n) and zero outside it. windows: (h, o, plain)
    each, -len(h) < o <= 0, for sum_j h[j] |z(t + j + o)|^2; plain(v) is the
    caller's own filter of the full power v (read at t0 the plain way). t0:
    f * HOP over a range of frames, except possibly a last one clamped to
    n - 1. Returns one (len(t0),) array per window."""
    t0 = np.asarray(t0, np.int64)
    B = len(Zss[0])
    S_n = len(Zss)
    step = int(t0[1] - t0[0]) if len(t0) > 1 else 1
    reg = t0 == t0[0] + step * np.arange(len(t0))
    plan = []
    fast = S_n * 2 * _cost(2 * B - 1)
    plain = S_n * (L + sum(_cost(n + len(w[0])) for w in windows))
    for h, o, _ in windows:
        T = len(h)
        f = np.nonzero(reg & (t0 + o >= 0) & (t0 + o + T <= n))[0]
        f1, f2 = (int(f[0]), int(f[-1]) + 1) if len(f) else (0, 0)
        edge = np.setdiff1d(np.arange(len(t0)), np.arange(f1, f2))
        runs = []
        for run in (_runs(edge) if len(edge) else []):
            rlo = max(0, int(t0[run].min()) + o)
            rhi = min(n, int(t0[run].max()) + o + T)
            runs.append((run, rlo, rhi))
            fast += S_n * _czt_cost(B, rhi - rlo) + _cost(rhi - rlo + T)
        if f2 > f1:
            fast += _czt_cost(T, 2 * B - 1) + _czt_cost(2 * B - 1, f2 - f1)
        plan.append((h, o, f1, f2, runs))
    if plain <= fast:
        out = [np.zeros(len(t0)) for _ in windows]
        for Zs in Zss:
            Z = np.zeros(L, np.complex128)
            Z[a : a + B] = Zs
            v = np.abs(sfft.ifft(Z, workers=-1)[:n]) ** 2
            for o_, (_, _, fn) in zip(out, windows):
                o_ += np.maximum(fn(v)[t0], 0.0) / S_n
        return out
    M = sfft.next_fast_len(2 * B - 1)
    P = np.zeros(M)
    for Zs in Zss:
        P += np.abs(sfft.fft(Zs, M, workers=-1)) ** 2
    R = sfft.ifft(P, workers=-1) / S_n                      # mean autocorrelation
    q = np.arange(-(B - 1), B, dtype=np.int64)
    Rq = R[q % M]
    out = []
    for h, o, f1, f2, runs in plan:
        S = np.zeros(len(t0))
        if f2 > f1:
            H = czt(h, 2 * B - 1, 1, 0, -(B - 1), L)          # H(q), q = -(B-1)..B-1
            c = Rq * H * _phase(q * (int(t0[0]) + o), L) / (L * L)
            # sum_q c_q exp(2 pi i q step k / L), k = f1..f2-1
            S[f1:f2] = czt(c, f2 - f1, step, -(B - 1), f1, L).real
        # the edge frames, in runs at the start and end: z over each run only
        for run, rlo, rhi in runs:
            v = sum(np.abs(band_signal(Zs, a, L, rlo, rhi)) ** 2 for Zs in Zss) / S_n
            S[run] = _sums(v, rlo, h, o, t0[run])
        out.append(np.maximum(S, 0.0))
    return out

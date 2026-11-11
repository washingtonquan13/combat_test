"""Distance between a rebuilt note and its original. Not a perceptual
model: a yardstick for ranking tiers against reference codecs at known
sizes. The ear decides."""
import numpy as np
from scipy.fft import rfft
from scipy.signal import get_window

import fastlib

SR = 44100


def _fit(x, N=4096):
    """A note shorter than the longest window, padded with silence up to it."""
    return x if len(x) >= N else np.pad(x, (0, N - len(x)))


_WIN = {}


def _spectra(x, N, raw=False):
    """The frames scipy.signal.stft(x, nperseg=N, noverlap=3N/4) gives with
    its defaults, as (frames, bins) pieces small enough to stay in the
    cache: a note's whole spectrogram is tens of megabytes, and walking it
    several times is what made bake workers slow each other down."""
    if N not in _WIN:
        w = get_window("hann", N)
        _WIN[N] = w, 1.0 / w.sum()
    win, scale = _WIN[N]
    hop = N // 4
    x = np.concatenate([np.zeros(N // 2), x, np.zeros(N // 2)])
    x = np.concatenate([x, np.zeros((-(len(x) - N) % hop) % N)])
    rows = np.lib.stride_tricks.sliding_window_view(x, N)[::hop]
    step = max(8, 32768 // N)
    for a in range(0, len(rows), step):
        Z = rfft(win * rows[a:a + step], axis=-1)
        yield a, (Z, scale) if raw else Z * scale


def _logmag(Z):
    return 20 * np.log10(np.abs(Z) + 1e-9)


def _kept(cache, key, make):
    """make() once per key when the caller passes a dict to keep the
    original's side in: one original is scored against several rebuilds."""
    if cache is None:
        return make()
    if key not in cache:
        cache[key] = make()
    return cache[key]


def mrstft_db(ref, test, floor_db=-80.0, cache=None):
    """Mean |dB difference| over 256/1024/4096 STFTs, counted only where the
    original sits within floor_db of its own peak."""
    n = min(len(ref), len(test))
    out = []
    for N in (256, 1024, 4096):
        def side(N=N):
            if fastlib.lib:
                R = []
                for _, (Z, scale) in _spectra(_fit(ref[:n]), N, raw=True):
                    R.append(np.empty(Z.shape))
                    fastlib.lib.mr_logmag(Z.ctypes.data, Z.size, scale, R[-1].ctypes.data)
                R = np.concatenate(R)
            else:
                R = np.concatenate([_logmag(Z) for _, Z in _spectra(_fit(ref[:n]), N)])
            lo = R.max() + floor_db
            m = R > lo
            at = np.concatenate([[0], np.cumsum(m.sum(axis=1))])    # where each frame's kept bins start
            return lo, m, np.maximum(R, lo)[m], at
        lo, m, Rm, at = _kept(cache, ("mrstft", N, n, floor_db), side)
        total = 0.0
        if fastlib.lib:      # the same sum in one pass in C, last bits apart
            for a, (Z, scale) in _spectra(_fit(test[:n]), N, raw=True):
                total += fastlib.lib.mr_absdiff(Z.ctypes.data, Z.size, scale, m.ctypes.data + a * m.shape[1],
                                                Rm.ctypes.data + 8 * int(at[a]), lo)
        else:
            for a, Z in _spectra(_fit(test[:n]), N):
                b = a + len(Z)
                total += np.abs(Rm[at[a]:at[b]] - np.maximum(_logmag(Z)[m[a:b]], lo)).sum()
        out.append(total / len(Rm) if len(Rm) else np.nan)
    return float(np.mean(out))


_MEL = {}


def _mel_bank(f, nmel):
    if (SR, len(f), nmel) not in _MEL:
        mel = lambda h: 2595 * np.log10(1 + h / 700)
        edges = 700 * (10 ** (np.linspace(mel(30), mel(16000), nmel + 2) / 2595) - 1)
        fb = np.zeros((nmel, len(f)))
        for i in range(nmel):
            lo, c, hi = edges[i : i + 3]
            fb[i] = np.clip(np.minimum((f - lo) / (c - lo), (hi - f) / (hi - c)), 0, None)
        _MEL[SR, len(f), nmel] = fb
    return _MEL[SR, len(f), nmel]


def _mel(x, N, nmel):
    fb = _mel_bank(np.fft.rfftfreq(N, 1 / SR), nmel).T
    for a, Z in _spectra(x, N):
        yield a, 10 * np.log10((Z.real ** 2 + Z.imag ** 2) @ fb + 1e-18)


_SPARSE = {}


def _mel_sparse(N, nmel):
    """The bank as the run of bins each filter touches: (start, length, offset, weights)."""
    if (SR, N, nmel) not in _SPARSE:
        fb = _mel_bank(np.fft.rfftfreq(N, 1 / SR), nmel)
        nz = [np.flatnonzero(r) for r in fb]
        fs = np.array([k[0] if len(k) else 0 for k in nz], dtype=np.int32)
        fl = np.array([k[-1] - k[0] + 1 if len(k) else 0 for k in nz], dtype=np.int32)
        fo = (np.cumsum(fl) - fl).astype(np.int32)
        fw = np.concatenate([fb[i, fs[i]:fs[i] + fl[i]] for i in range(nmel)] + [np.zeros(1)])
        _SPARSE[SR, N, nmel] = fs, fl, fo, fw
    return _SPARSE[SR, N, nmel]


def mel_db(ref, test, nmel=64, N=2048, cache=None):
    n = min(len(ref), len(test))
    fast = bool(fastlib.lib) and N // 2 + 1 <= 4100 and nmel <= 256
    if fast:
        fs, fl, fo, fw = _mel_sparse(N, nmel)

    def side():
        if fast:
            r = []
            for _, (Z, scale) in _spectra(_fit(ref[:n]), N, raw=True):
                r.append(np.empty((len(Z), nmel)))
                fastlib.lib.mel_rows(Z.ctypes.data, Z.shape[0], Z.shape[1], scale, nmel, fs.ctypes.data, fl.ctypes.data,
                                     fo.ctypes.data, fw.ctypes.data, r[-1].ctypes.data, None, None)
            r = np.concatenate(r)
        else:
            r = np.concatenate([t for _, t in _mel(_fit(ref[:n]), N, nmel)])
        return r, r > r.max() - 80
    r, m = _kept(cache, ("mel", N, nmel, n), side)
    total = 0.0
    if fast:
        for a, (Z, scale) in _spectra(_fit(test[:n]), N, raw=True):
            total += fastlib.lib.mel_rows(Z.ctypes.data, Z.shape[0], Z.shape[1], scale, nmel, fs.ctypes.data,
                                          fl.ctypes.data, fo.ctypes.data, fw.ctypes.data, None,
                                          r.ctypes.data + 8 * a * nmel, m.ctypes.data + a * nmel)
    else:
        for a, t in _mel(_fit(test[:n]), N, nmel):
            b = a + len(t)
            total += np.abs(r[a:b] - t)[m[a:b]].sum()
    k = int(m.sum())
    return float(total / k) if k else float("nan")

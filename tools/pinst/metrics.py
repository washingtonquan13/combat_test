"""Distance between a rebuilt note and its original. Not a perceptual
model: a yardstick for ranking tiers against reference codecs at known
sizes. The ear decides."""
import numpy as np
from scipy.signal import stft

SR = 44100


def _fit(x, N=4096):
    """A note shorter than the longest window, padded with silence up to it."""
    return x if len(x) >= N else np.pad(x, (0, N - len(x)))


def _logmag(x, N):
    _, _, Z = stft(x, SR, window="hann", nperseg=N, noverlap=N * 3 // 4)
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
            R = _logmag(_fit(ref[:n]), N)
            lo = R.max() + floor_db
            m = R > lo
            return lo, m, np.maximum(R, lo)[m]
        lo, m, Rm = _kept(cache, ("mrstft", N, n, floor_db), side)
        T = _logmag(_fit(test[:n]), N)
        out.append(np.abs(Rm - np.maximum(T[m], lo)).mean())
    return float(np.mean(out))


_MEL = {}


def _mel_bank(f, nmel):
    if (len(f), nmel) not in _MEL:
        mel = lambda h: 2595 * np.log10(1 + h / 700)
        edges = 700 * (10 ** (np.linspace(mel(30), mel(16000), nmel + 2) / 2595) - 1)
        fb = np.zeros((nmel, len(f)))
        for i in range(nmel):
            lo, c, hi = edges[i : i + 3]
            fb[i] = np.clip(np.minimum((f - lo) / (c - lo), (hi - f) / (hi - c)), 0, None)
        _MEL[len(f), nmel] = fb
    return _MEL[len(f), nmel]


def mel_db(ref, test, nmel=64, N=2048, cache=None):
    n = min(len(ref), len(test))

    def side():
        f, _, R = stft(_fit(ref[:n]), SR, nperseg=N, noverlap=N * 3 // 4)
        r = 10 * np.log10(_mel_bank(f, nmel) @ np.abs(R) ** 2 + 1e-18)
        return f, r, r > r.max() - 80
    f, r, m = _kept(cache, ("mel", N, nmel, n), side)
    _, _, T = stft(_fit(test[:n]), SR, nperseg=N, noverlap=N * 3 // 4)
    t = 10 * np.log10(_mel_bank(f, nmel) @ np.abs(T) ** 2 + 1e-18)
    return float(np.abs(r - t)[m].mean())

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


def mrstft_db(ref, test, floor_db=-80.0):
    """Mean |dB difference| over 256/1024/4096 STFTs, counted only where the
    original sits within floor_db of its own peak."""
    n = min(len(ref), len(test))
    out = []
    for N in (256, 1024, 4096):
        R, T = _logmag(_fit(ref[:n]), N), _logmag(_fit(test[:n]), N)
        m = R > R.max() + floor_db
        out.append(np.abs(np.maximum(R, R.max() + floor_db) - np.maximum(T, R.max() + floor_db))[m].mean())
    return float(np.mean(out))


def mel_db(ref, test, nmel=64, N=2048):
    n = min(len(ref), len(test))
    f, _, R = stft(_fit(ref[:n]), SR, nperseg=N, noverlap=N * 3 // 4)
    _, _, T = stft(_fit(test[:n]), SR, nperseg=N, noverlap=N * 3 // 4)
    mel = lambda h: 2595 * np.log10(1 + h / 700)
    edges = 700 * (10 ** (np.linspace(mel(30), mel(16000), nmel + 2) / 2595) - 1)
    fb = np.zeros((nmel, len(f)))
    for i in range(nmel):
        lo, c, hi = edges[i : i + 3]
        fb[i] = np.clip(np.minimum((f - lo) / (c - lo), (hi - f) / (hi - c)), 0, None)
    r = 10 * np.log10(fb @ np.abs(R) ** 2 + 1e-18)
    t = 10 * np.log10(fb @ np.abs(T) ** 2 + 1e-18)
    m = r > r.max() - 80
    return float(np.abs(r - t)[m].mean())

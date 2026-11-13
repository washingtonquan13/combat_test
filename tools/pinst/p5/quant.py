"""PINST5 stage: step sizes (owner: agent C).

quantize(X, Xref, M, seed, dial, top, heard) -> LayerCode or None (nothing to store)
dequantize(L) -> (frames, K) coefficients

One dial sets every step.

* Tonal bands keep the wave-0 step: the band's level less `dial` dB.
* A band's own noise hides error under it, so a noise-like band may be coded
  as coarse as `dial` * NOISE_FRAC dB under its level. How noise-like a band
  is: the flatness of its time-smoothed power (geometric over arithmetic mean)
  divided by the flatness white noise measures in the same band. Every dB a
  band sits under noise's flatness gives TONE_SLOPE dB of SNR back, up to the
  dial; a band with fewer than MIN_WID coefficients is too narrow to judge
  and counts as tonal. The measure is taken on the note itself (Xref), not on
  what the sines left, so a band is tonal when the note is tonal there.
  Only bands near their frame's loudest go coarser: a band `dial` dB or more
  under its frame's loudest keeps the dial, rising linearly to the full drop
  at the loudest. A quiet noise band between loud partials keeps its step.
* A band's level for the step is the quieter of its own and the level heard
  there (the source, every channel summed): where the remainder stands over
  the source (the sines overshoot it before an attack), its error is put
  under the source, which keeps that error out of the quiet. Setting every
  step under the source alone was measured and costs 15-30 % more at the same
  accuracy (wave 1 merge).
* The quiet floor is FLOOR_DB under the note's own loudest band (per
  coefficient, top); under that a band stores nothing, at any dial.
* Stereo stays mid/side for every band. Each signal is coded relative to its
  own band level, so left/right costs the same as mid/side wherever all four
  bands are over the floor; a per-band choice was built and measured (it
  saved at most 0.1 kB a note and its shared block plan cost up to 2.2 kB),
  so it is not used.

Each band-frame's step is stored as `dq`: how many 1.5 dB steps its SNR sits
under the dial, so the decoder needs no measure of its own. A band-frame whose
SNR reaches 0 dB codes no coefficients and is refilled from the hash at its own
energy. A coefficient that rounds to zero is refilled from the hash so each
band keeps its energy, never louder than half a step.
"""
from __future__ import annotations

import numpy as np
from scipy.ndimage import convolve1d

import contract as C
import pinst_codec as pc

NBANDS = 18
NOISE_FRAC = 0.5        # a pure-noise band is coded dial * this under its level
TONE_SLOPE = 3.0        # dB of SNR back per dB a band's flatness sits under noise's
MIN_WID = 8             # bands narrower than this count as tonal
GATE = 1.0              # a band dial * this under its frame's loudest keeps the dial
FLOOR_DB = 80.0         # no band this far under the note's loudest (per coefficient): unheard at any dial
SPAN = 2048             # samples each side the band power is smoothed over before flatness
HEARD = 1024            # samples a band's level is averaged over for the frame gate
_SQ3 = np.sqrt(3.0)
_NOISE = {}


def edges(K, nbands=NBANDS):
    return pc._xf_edges(K, nbands)


def _smooth(P, S):
    if S <= 1:
        return P
    g = np.hanning(S + 2)[1:-1]
    return convolve1d(P, g / g.sum(), axis=0, mode="constant")


def _flatness(X, M, ed):
    """(frames, bands) geometric over arithmetic mean of the time-smoothed power."""
    P = _smooth(X ** 2, 2 * max(1, SPAN // M) + 1) + 1e-30
    wid = np.diff(ed)
    am = np.add.reduceat(P, ed[:-1], axis=1) / wid
    gm = np.exp(np.add.reduceat(np.log(P), ed[:-1], axis=1) / wid)
    return gm / am


def _noise_flatness(M, K):
    """Per band, the flatness white noise measures here (median over frames)."""
    if (M, K) not in _NOISE:
        import transform
        x = np.random.default_rng(12345).standard_normal(max(16 * SPAN, 64 * M))
        X = transform.forward(x, M)[:, :K]
        f = _flatness(X, M, edges(K))
        S = max(1, SPAN // M)
        _NOISE[(M, K)] = np.median(f[2 * S + 2 : -2 * S - 2], axis=0)
    return _NOISE[(M, K)]


def tonality(Xref, M):
    """(frames, bands) flatness over white noise's, clipped to (1e-6, 1]: 1 is
    noise, small is tonal. Narrow bands are 1e-6 (tonal)."""
    F, K = Xref.shape
    ed = edges(K)
    eta = np.clip(_flatness(Xref, M, ed) / _noise_flatness(M, K), 1e-6, 1.0)
    eta[:, np.diff(ed) < MIN_WID] = 1e-6
    return eta


def band_snr(Xref, M, snr):
    """(frames, bands) SNR, dB, each band-frame is coded to (before the floor)."""
    F, K = Xref.shape
    ed = edges(K)
    bs = np.minimum(snr, snr * NOISE_FRAC - TONE_SLOPE * 10 * np.log10(tonality(Xref, M)))
    P = _smooth(np.add.reduceat(Xref ** 2, ed[:-1], axis=1), HEARD // M)
    lvl = 10 * np.log10(P + 1e-30)
    near = np.clip((lvl - lvl.max(axis=1, keepdims=True)) / (GATE * snr) + 1, 0, 1)
    return snr - (snr - bs) * near


def top_db(Xnote):
    """The note's loudest band (per coefficient, dB) at this block length."""
    return float(pc.band_power_db(Xnote, NBANDS).max())


def _code(X, M, seed, snr, bs, floor, hdb):
    """One layer from coefficients X, each band-frame's error put bs dB (SNR)
    under the quieter of X's own level and hdb, the level heard there (source
    band power per coefficient, dB)."""
    F, K = X.shape
    wid = np.diff(edges(K))
    sdb = pc.band_power_db(X, NBANDS)
    live = sdb > floor
    if not live.any():
        return None
    qs = np.round(sdb / 1.5).astype(np.int64)
    dead = int(qs[live].min() - 1)
    sc = np.where(live, qs, dead)
    over = np.minimum(hdb - qs * 1.5, 0)            # where X is louder than what is heard
    dq = np.where(live, np.round((snr - bs + over) / 1.5), 0).astype(np.int64)
    fill = np.repeat(snr - 1.5 * dq <= 0, wid, axis=1)
    step = _steps(sc, live, wid, snr, dq)
    q = np.where(np.repeat(live, wid, axis=1) & ~fill, np.round(X / step), 0).astype(np.int64)
    return C.LayerCode(M, K, NBANDS, snr, dead, F, seed, sc, q, dq)


def quantize(X: np.ndarray, Xref: np.ndarray, M: int, seed: int, dial: float, top: float,
             heard: np.ndarray) -> C.LayerCode | None:
    """Xref: the mid on X's own grid (same frames). top: top_db of the whole mid.
    heard: (frames, bands) the source's band power on X's grid, all channels
    summed (heard_db), which each step is set under."""
    snr = round(dial * 100) / 100
    return _code(X, M, seed, snr, band_snr(Xref, M, snr), top - FLOOR_DB, heard)


def heard_db(Xs) -> np.ndarray:
    """(frames, bands) dB per coefficient of the summed power of the channels' coefficients."""
    return 10 * np.log10(sum(10 ** (pc.band_power_db(X, NBANDS) / 10) for X in Xs) + 1e-30)


def _steps(sc, live, wid, snr, dq):
    rms = 10 ** (sc * 1.5 / 20) * live
    return np.repeat(np.maximum(rms, 1e-30) * 10 ** (-(snr - 1.5 * dq) / 20) * np.sqrt(12), wid, axis=1)


def live_mask(L: C.LayerCode) -> np.ndarray:
    """(frames, K): the coefficients the file stores."""
    return np.repeat(L.sc != L.dead, np.diff(edges(L.K, L.nbands)), axis=1)


def coded_mask(L: C.LayerCode) -> np.ndarray:
    """(frames, K): the coefficients with a code; live bands whose SNR reaches
    0 dB are filled from the hash and store none."""
    ok = (L.sc != L.dead) & (L.snr - 1.5 * L.dq > 0)
    return np.repeat(ok, np.diff(edges(L.K, L.nbands)), axis=1)


def dequantize(L: C.LayerCode) -> np.ndarray:
    ed = edges(L.K, L.nbands)
    wid = np.diff(ed)
    live = L.sc != L.dead
    rms = 10 ** (L.sc * 1.5 / 20) * live
    step = _steps(L.sc, live, wid, L.snr, L.dq)
    coded = np.repeat(live, wid, axis=1)
    Xd = L.q * step
    lack = np.maximum(rms**2 * wid - np.add.reduceat(Xd**2, ed[:-1], axis=1), 0)
    nzero = np.add.reduceat((L.q == 0).astype(float), ed[:-1], axis=1)
    fill = np.repeat(np.sqrt(lack / np.maximum(nzero, 1)), wid, axis=1)
    fill = np.where(coded, np.minimum(fill, step / np.sqrt(12)), fill)
    r = pc.hash_uniform(L.seed, 0, L.frames * L.K).reshape(L.frames, L.K) * _SQ3
    return Xd + (L.q == 0) * fill * r

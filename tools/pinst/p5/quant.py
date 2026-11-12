"""PINST5 stage: step sizes (owner: agent C).

quantize(X, Xref, M, seed, dial) -> LayerCode or None (nothing to store)
dequantize(L) -> (frames, K) coefficients

Wave 0 is PINST3's layer_code with no need map: every band within FLOOR_DB
of the reference's loudest band is coded; the step is the band's level less
`dial` dB (uniform quantizer, step = rms * 10^(-dial/20) * sqrt(12)); a
coefficient that rounds to zero is refilled from the hash so each band keeps
its energy, never louder than half a step.
"""
from __future__ import annotations

import numpy as np

import contract as C
import pinst_codec as pc

NBANDS = 18
FLOOR_DB = -80.0
_SQ3 = np.sqrt(3.0)


def edges(K, nbands=NBANDS):
    return pc._xf_edges(K, nbands)


def quantize(X: np.ndarray, Xref: np.ndarray, M: int, seed: int, dial: float = C.DIAL) -> C.LayerCode | None:
    F, K = X.shape
    ed = edges(K)
    wid = np.diff(ed)
    sdb = pc.band_power_db(X, NBANDS)
    floor = pc.band_power_db(Xref, NBANDS).max() + FLOOR_DB
    live = sdb > floor
    if not live.any():
        return None
    qs = np.round(sdb / 1.5).astype(np.int64)
    dead = int(qs[live].min() - 1)
    sc = np.where(live, qs, dead)
    snr = round(dial * 100) / 100
    step = _steps(sc, live, wid, snr)
    lv = np.repeat(live, wid, axis=1)
    q = np.where(lv, np.round(X / step), 0).astype(np.int64)
    return C.LayerCode(M, K, NBANDS, snr, dead, F, seed, sc, q)


def _steps(sc, live, wid, snr):
    rms = 10 ** (sc * 1.5 / 20) * live
    return np.repeat(np.maximum(rms, 1e-30) * 10 ** (-snr / 20) * np.sqrt(12), wid, axis=1)


def live_mask(L: C.LayerCode) -> np.ndarray:
    """(frames, K): the coefficients the file stores."""
    return np.repeat(L.sc != L.dead, np.diff(edges(L.K, L.nbands)), axis=1)


def dequantize(L: C.LayerCode) -> np.ndarray:
    ed = edges(L.K, L.nbands)
    wid = np.diff(ed)
    live = L.sc != L.dead
    rms = 10 ** (L.sc * 1.5 / 20) * live
    step = _steps(L.sc, live, wid, L.snr)
    coded = np.repeat(live, wid, axis=1)
    Xd = L.q * step
    lack = np.maximum(rms**2 * wid - np.add.reduceat(Xd**2, ed[:-1], axis=1), 0)
    nzero = np.add.reduceat((L.q == 0).astype(float), ed[:-1], axis=1)
    fill = np.repeat(np.sqrt(lack / np.maximum(nzero, 1)), wid, axis=1)
    fill = np.where(coded, np.minimum(fill, step / np.sqrt(12)), fill)
    r = pc.hash_uniform(L.seed, 0, L.frames * L.K).reshape(L.frames, L.K) * _SQ3
    return Xd + (L.q == 0) * fill * r

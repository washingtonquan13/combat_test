"""PINST5 stage: the MDCT (owner: agent B, with blocks.py).

forward(e, M) -> (frames, M) coefficients
inverse(X, n, M) -> n samples

PINST3's layer grid: frame f spans f*M - M/2 .. f*M + 3M/2, sine window,
frame 0's left half folds at sample 0 so nothing is made before the note
(pinst_codec.layer_windows).
"""
from __future__ import annotations

import numpy as np

import contract  # noqa: F401  (puts the legacy modules on the path)
import pinst_codec as pc


def frames(n: int, M: int) -> int:
    return pc.layer_frames(n, M)


def forward(e: np.ndarray, M: int) -> np.ndarray:
    return pc.mdct_frames(e, M)


def inverse(X: np.ndarray, n: int, M: int) -> np.ndarray:
    B, _ = pc._mdct(M)
    K = X.shape[1]
    yf = (X @ B[:, :K].T) * (2 / M)
    w0, w = pc.layer_windows(M)
    yf[1:] *= w
    yf[0] *= w0
    F = len(X)
    out = np.zeros((F + 1) * M)
    out[: F * M] += yf[:, :M].ravel()
    out[M : (F + 1) * M] += yf[:, M:].ravel()
    off = M // 2
    return out[off : off + n]

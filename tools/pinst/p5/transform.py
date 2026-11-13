"""PINST5 stage: the MDCT (owner: agent B, with blocks.py).

forward(e, M, start=0) -> (frames, M) coefficients
inverse(X, n, M, start=0) -> n samples, exactly zero before `start`

PINST3's layer grid, with its origin moved to the layer's start sample:
frame f spans start + f*M - M/2 .. start + f*M + 3M/2, sine window, frame 0's
left half folds at `start` (pinst_codec.layer_windows). Nothing before
`start` is read or made, so a layer's coding error cannot reach back past
the sample it starts on: that is what keeps a hit's noise out of the quiet
before it, and exact silence before a note exact.
"""
from __future__ import annotations

import numpy as np

import contract  # noqa: F401  (puts the legacy modules on the path)
import pinst_codec as pc


def frames(n: int, M: int, start: int = 0) -> int:
    """The most frames a layer from `start` has (fewer when its piece ends early)."""
    return pc.layer_frames(n - start, M)


def forward(e: np.ndarray, M: int, start: int = 0) -> np.ndarray:
    """Frames from `start` up to the last that touches e's last nonzero sample:
    a layer stores nothing for the silence after its piece ends."""
    nz = np.flatnonzero(e[start:])
    return pc.mdct_frames(e[start : start + (int(nz[-1]) + 1 if len(nz) else 1)], M)


def inverse(X: np.ndarray, n: int, M: int, start: int = 0) -> np.ndarray:
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
    y = np.zeros(n)
    m = max(0, min(n - start, len(out) - off))
    y[start : start + m] = out[off : off + m]
    return y

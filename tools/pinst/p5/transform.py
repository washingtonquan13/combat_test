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
import scipy.fft as sfft

import contract  # noqa: F401  (puts the legacy modules on the path)
import pinst_codec as pc


def frames(n: int, M: int, start: int = 0) -> int:
    """The most frames a layer from `start` has (fewer when its piece ends early)."""
    return pc.layer_frames(n - start, M)


def _last_nonzero(e: np.ndarray, start: int = 0, chunk: int = 8192) -> int:
    """Index of the last nonzero sample of e at or after `start`, or -1 (scans
    from the end in chunks, so it stops at the last nonzero without a pass
    over the whole of e)."""
    hi = len(e)
    while hi > start:
        lo = max(start, hi - chunk)
        nz = np.flatnonzero(e[lo:hi])
        if len(nz):
            return lo + int(nz[-1])
        hi = lo
    return -1


_CACHE: list = []      # (e, M, start, X, len): the last few forward() results; e is held so its id stays its own


def forward(e: np.ndarray, M: int, start: int = 0) -> np.ndarray:
    """Frames from `start` up to the last that touches e's last nonzero sample:
    a layer stores nothing for the silence after its piece ends.

    The same array (the mid, asked for once per channel and piece) is
    transformed once and the result shared, read-only. e must not be
    changed in place after it has been passed here."""
    for c in _CACHE:
        if c[0] is e and c[1] == M and c[2] == start and c[4] == len(e):
            return c[3]
    last = _last_nonzero(e, start)
    X = _mdct_frames(e[start : start + (last - start + 1 if last >= start else 1)], M)
    X.setflags(write=False)
    _CACHE.append((e, M, start, X, len(e)))
    if len(_CACHE) > 12:
        del _CACHE[0]
    return X


_WIN = {}


def _mdct_frames(e: np.ndarray, M: int) -> np.ndarray:
    """pc.mdct_frames by folding to a DCT-IV (an FFT) instead of a matrix product.

    The buffer (M/2 zeros, then e) is cut into rows of M: frame f is row f
    then row f+1, quarters a b | c d, which fold to (-c~ - d, a - b~)
    (~ is reversed). Frame 0's left half is flat (pc.layer_windows): a=0, b=1."""
    h = M // 2
    if M not in _WIN:
        w = pc.layer_windows(M)[1]
        _WIN[M] = (w[:h].copy(), w[h:M][::-1].copy(), w[M : M + h][::-1].copy(), w[M + h :].copy())
    wa, wbr, wcr, wd = _WIN[M]
    F = pc.layer_frames(len(e), M)
    buf = np.zeros((F + 1) * M)
    buf[h : h + len(e)] = e
    R = buf.reshape(F + 1, M)
    u = np.empty((F, M))
    np.multiply(R[1:, h - 1 :: -1], wcr, out=u[:, :h])          # c~
    np.negative(u[:, :h], out=u[:, :h])
    u[:, :h] -= R[1:, h:] * wd                                  # -c~ - d
    np.multiply(R[:-1, :h], wa, out=u[:, h:])                   # a
    u[:, h:] -= R[:-1, M - 1 : h - 1 : -1] * wbr                # a - b~
    u[0, h:] = -R[0, M - 1 : h - 1 : -1]
    return sfft.dct(u, type=4, axis=1) * 0.5


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

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

import ctypes
import os

import numpy as np
import scipy.fft as sfft

import contract  # noqa: F401  (puts the legacy modules on the path)
import memo
import pinst_codec as pc


def _load():
    """native/p5enc.dll: the fold and unfold below, operation for operation
    (the same bits); None -> the numpy code (also with P5ENC_PY set)."""
    if os.environ.get("P5ENC_PY"):
        return None
    try:
        lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "native", "p5enc.dll"))
    except OSError:
        return None
    p, i64 = ctypes.c_void_p, ctypes.c_int64
    lib.p5_mdct_fold.restype, lib.p5_mdct_fold.argtypes = None, [p, i64, i64, i64, p, p, p, p, p]
    lib.p5_imdct_unfold.restype, lib.p5_imdct_unfold.argtypes = None, [p, i64, i64, p, p, i64, i64, p]
    return lib


_lib = _load()


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
_MEMO = memo.Memo(48, 256 << 20)    # by content: (the samples transformed, M) -> X


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
    seg = e[start : start + (last - start + 1 if last >= start else 1)]
    hit, X = _MEMO.get((seg,), M)       # the same samples again (another coding of the note, a peak round)
    if not hit:
        X = _mdct_frames(seg, M)
        X.setflags(write=False)
        _MEMO.put((seg,), M, X, X.nbytes)
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
    if _lib is not None:
        e = np.ascontiguousarray(e, dtype=np.float64)
        u = np.empty((F, M))
        _lib.p5_mdct_fold(e.ctypes.data, len(e), M, F, wa.ctypes.data, wbr.ctypes.data,
                          wcr.ctypes.data, wd.ctypes.data, u.ctypes.data)
        X = sfft.dct(u, type=4, axis=1, overwrite_x=True)
        X *= 0.5
        return X
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


_IWIN = {}


def inverse(X: np.ndarray, n: int, M: int, start: int = 0) -> np.ndarray:
    lo, seg = inverse_seg(X, n, M, start)
    y = np.zeros(n)
    y[lo : lo + len(seg)] = seg
    return y


def inverse_seg(X: np.ndarray, n: int, M: int, start: int = 0):
    """-> (lo, seg): inverse(X, n, M, start) is seg at lo.. and zero elsewhere.

    inverse_mat (X @ B.T * 2/M, windowed, overlap-added) by a DCT-IV (an FFT).

    With v = DCT-IV(X) (zero-padded to M; scipy's, so 2x the plain sum), the
    basis row n of frame f is cos(pi/M (n + M/2 + 0.5)(k + 0.5)), which unfolds
    from v as  v[n + h] | -v~ | -v[n - 3h]  over n in [0, h) | [h, 3h) | [3h, 2M)
    (h = M/2, ~ reversed), so yf = that / M."""
    h = M // 2
    if M not in _IWIN:
        w0, w = pc.layer_windows(M)
        _IWIN[M] = (np.ascontiguousarray(w0, dtype=np.float64), np.ascontiguousarray(w, dtype=np.float64))
    w0, w = _IWIN[M]
    F = len(X)
    V = sfft.dct(X, type=4, n=M, axis=1) if X.shape[1] < M else sfft.dct(X, type=4, axis=1)
    off = M // 2
    if _lib is not None:
        V = np.ascontiguousarray(V, dtype=np.float64)
        m = max(0, min(n - start, (F + 1) * M - off))
        seg = np.empty(m)
        _lib.p5_imdct_unfold(V.ctypes.data, F, M, w0.ctypes.data, w.ctypes.data, off, m, seg.ctypes.data)
        return start, seg
    V *= 1.0 / M
    yf = np.empty((F, 2 * M))
    yf[:, :h] = V[:, h:]
    np.negative(V[:, ::-1], out=yf[:, h : 3 * h])
    np.negative(V[:, :h], out=yf[:, 3 * h :])
    yf[1:] *= w
    yf[0] *= w0
    out = np.zeros((F + 1) * M)
    out[: F * M] += yf[:, :M].ravel()
    out[M : (F + 1) * M] += yf[:, M:].ravel()
    off = M // 2
    m = max(0, min(n - start, len(out) - off))
    return start, out[off : off + m]


def inverse_mat(X: np.ndarray, n: int, M: int, start: int = 0) -> np.ndarray:
    """The reference inverse (a full matrix product); inverse() matches it to rounding."""
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

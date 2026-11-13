"""Exact memos for the encoder's repeated work (speed only, no effect on output).

The encoder codes a stereo note three ways and re-codes it in up to three
peak rounds; most of what each coding transforms, plans and decodes is the
same arrays again (the same e, the same pieces). A Memo hands back the
result computed for inputs bit-for-bit equal to these (arrays compared
whole, by their bytes, so -0.0 and 0.0 are different inputs and NaNs equal
themselves), so a hit returns exactly what the call would have.

Results are handed out shared: callers must not change them in place
(arrays are stored read-only where they are arrays)."""
from __future__ import annotations

import numpy as np


_UINT = {1: np.uint8, 2: np.uint16, 4: np.uint32, 8: np.uint64}


def _bits(a):
    """a's bits as unsigned integers of its own item size (a view, strided or
    not: no copy), or, for other item sizes, a contiguous byte view."""
    a = np.asarray(a)
    u = _UINT.get(a.dtype.itemsize)
    if u is not None and a.dtype.kind in "biuf":
        return a.view(u)
    return np.ascontiguousarray(a).reshape(-1).view(np.uint8)


def _fp(a):
    """A cheap fingerprint: shape, dtype and ~64 sampled values."""
    a = np.asarray(a)
    if a.ndim == 1:
        f = a
    else:
        f = a.reshape(-1) if a.flags.c_contiguous else np.ascontiguousarray(a).reshape(-1)
    st = max(1, len(f) // 61)
    return (a.shape, a.dtype.str, f[::st].tobytes(), f[-3:].tobytes())


class Memo:
    def __init__(self, n=8, max_bytes=256 << 20):
        self.n, self.max_bytes = n, max_bytes
        self.ent = []       # (key, fps, copies, result, size)
        self.hits = self.miss = 0
        self._pend = None

    def get(self, arrays, key=()):
        fps = tuple(_fp(a) for a in arrays)
        self._pend = (tuple(map(id, arrays)), fps)      # put() after a miss on these arrays reuses them
        for i, (k, f, cp, res, _) in enumerate(self.ent):
            if k == key and f == fps and all(np.array_equal(_bits(a), b) for a, b in zip(arrays, cp)):
                if i != len(self.ent) - 1:
                    self.ent.append(self.ent.pop(i))
                self.hits += 1
                return True, res
        self.miss += 1
        return False, None

    def put(self, arrays, key, res, res_bytes=0):
        cp = [np.array(_bits(a)) for a in arrays]
        pend, self._pend = self._pend, None
        fps = pend[1] if pend is not None and pend[0] == tuple(map(id, arrays)) else tuple(_fp(a) for a in arrays)
        size = sum(c.nbytes for c in cp) + res_bytes
        self.ent.append((key, fps, cp, res, size))
        while len(self.ent) > self.n or (len(self.ent) > 1 and sum(e[4] for e in self.ent) > self.max_bytes):
            del self.ent[0]
        return res


def frozen(a):
    a.setflags(write=False)
    return a

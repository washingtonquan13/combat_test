"""PINST5 decoder: bytes -> samples. The one decoder source; F ports it (and
the decode halves it calls) to C. Owned by the integrator.

  python -I -B decode.py in.pinst5 out.wav

decode() is decode_py() with the encoder's trial decodes made cheaper and
nothing else: bytes this process just packed are decoded from the NoteCode
they were packed from (pack.packed: what unpack would give back), and a
sine layer or MDCT layer decoded before (the same codes again: another
coding of the note, a peak round) is not decoded again (memo.py). The
samples are the same to the bit; decode_py is the reference.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))      # python -I leaves it out
import numpy as np  # noqa: E402

import analysis
import contract as C
import memo
import pack
import quant
import transform

_SINES = {}                             # (ints, streams, n) -> render_sines' samples (read-only)
_LAYERS = memo.Memo(32, 192 << 20)      # a layer's codes -> (lo, its samples at lo..)


def _sines(code, n, sr):
    if code is None:
        return None
    k = (tuple(code.ints.items()), tuple(code.streams.items()), n, sr)
    y = _SINES.get(k)
    if y is None:
        y = memo.frozen(np.array(analysis.render_sines(code, n), dtype=np.float64, copy=True))
        _SINES[k] = y
        while len(_SINES) > 6:
            del _SINES[next(iter(_SINES))]
    return y


def _layer(L, n):
    key = (L.M, L.K, L.nbands, L.snr, L.dead, L.frames, L.seed, L.start, n)
    arrs = (L.sc, L.q, L.dq)
    hit, r = _LAYERS.get(arrs, key)
    if not hit:
        lo, seg = transform.inverse_seg(quant.dequantize(L), n, L.M, L.start)
        r = (lo, memo.frozen(seg))
        _LAYERS.put(arrs, key, r, seg.nbytes)
    return r


def channel(ch: C.ChannelCode, n: int) -> np.ndarray:
    s = _sines(ch.sines, n, C.pc.SR)
    y = np.zeros(n) if s is None else s.copy()
    for L in ch.layers:
        lo, seg = _layer(L, n)
        y[lo : lo + len(seg)] += seg
    return y


def decode(data: bytes):
    """-> (samples (n, channels), sample rate)."""
    note = pack.packed(data) or pack.unpack(data)
    C.set_rate(note.sr)
    ys = [channel(ch, note.n) for ch in note.channels]
    return _out(note, ys)


def _out(note, ys):
    if note.stereo == 1:
        m, s = ys
        return np.stack([m + s, m - s], axis=1), note.sr
    return np.stack(ys, axis=1), note.sr


def channel_py(ch: C.ChannelCode, n: int) -> np.ndarray:
    y = analysis.render_sines(ch.sines, n)
    for L in ch.layers:
        y = y + transform.inverse(quant.dequantize(L), n, L.M, L.start)
    return y


def decode_py(data: bytes):
    """The reference decoder: unpack, then every layer decoded as it is."""
    note = pack.unpack(data)
    C.set_rate(note.sr)
    return _out(note, [channel_py(ch, note.n) for ch in note.channels])


if __name__ == "__main__":
    import soundfile as sf
    y, sr = decode_py(open(sys.argv[1], "rb").read())
    sf.write(sys.argv[2], y, sr, subtype="FLOAT")

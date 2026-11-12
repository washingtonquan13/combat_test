"""PINST5 decoder: bytes -> samples. The one decoder source; F ports it (and
the decode halves it calls) to C. Owned by the integrator.

  python -I -B decode.py in.pinst5 out.wav
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))      # python -I leaves it out
import numpy as np  # noqa: E402

import analysis
import contract as C
import pack
import quant
import transform


def channel(ch: C.ChannelCode, n: int) -> np.ndarray:
    y = analysis.render_sines(ch.sines, n)
    for L in ch.layers:
        y = y + transform.inverse(quant.dequantize(L), n, L.M)
    return y


def decode(data: bytes):
    """-> (samples (n, channels), sample rate)."""
    note = pack.unpack(data)
    C.set_rate(note.sr)
    ys = [channel(ch, note.n) for ch in note.channels]
    if note.stereo:
        m, s = ys
        return np.stack([m + s, m - s], axis=1), note.sr
    return np.stack(ys, axis=1), note.sr


if __name__ == "__main__":
    import soundfile as sf
    y, sr = decode(open(sys.argv[1], "rb").read())
    sf.write(sys.argv[2], y, sr, subtype="FLOAT")

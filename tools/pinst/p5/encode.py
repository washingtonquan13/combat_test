"""PINST5 encoder glue: one note -> bytes. Owned by the integrator; the
work is in the stage files (contract.py lists who calls what).

  python -I -B encode.py in.wav out.pinst5 [f0_hz]
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))      # python -I leaves it out
import numpy as np  # noqa: E402

import analysis
import blocks
import contract as C
import pack
import quant
import transform

SIDE_DB = -40.0     # a side this far under the mid is silence (PINST3)


def channels_of(x):
    """(n, 1 or 2) -> ([mono] or [mid, side], stereo flag)."""
    if x.shape[1] == 1:
        return [x[:, 0]], 0
    m, s = 0.5 * (x[:, 0] + x[:, 1]), 0.5 * (x[:, 0] - x[:, 1])
    side_db = 20 * np.log10(np.sqrt((s**2).mean()) / max(np.sqrt((m**2).mean()), 1e-12) + 1e-12)
    return [m, s if side_db >= SIDE_DB else np.zeros_like(s)], 1


def encode_channel(x, ref, f0, seed, dial, sigs):
    """sigs: every channel (mid first); their summed level sets each step."""
    ch = C.ChannelCode()
    if not np.any(x):
        return ch
    ch.sines = analysis.encode_sines(x, f0)
    e = x - analysis.render_sines(ch.sines, len(x))
    tops = {}
    for M, w, s in blocks.plan(e, ref):
        if M not in tops:
            tops[M] = quant.top_db(transform.forward(ref, M))
        X = transform.forward(e * w, M, s)
        Xs = [_fit(transform.forward(g, M, s), len(X)) for g in sigs]    # every channel on X's grid
        L = quant.quantize(X, Xs[0], M, seed + 1 + len(ch.layers), dial, tops[M], quant.heard_db(Xs))
        if L is not None:
            L.start = s
            ch.layers.append(L)
    return ch


def _fit(X, F):
    """X cut or zero-padded to F frames."""
    if len(X) >= F:
        return X[:F]
    return np.concatenate([X, np.zeros((F - len(X), X.shape[1]))])


def encode_note(x: np.ndarray, sr: int, f0: float | None, dial: float = C.DIAL) -> bytes:
    """x: (n, 1 or 2) float. f0: a pitch hint in Hz, or None."""
    C.set_rate(sr)
    sigs, stereo = channels_of(x)
    chans = [encode_channel(s, sigs[0], f0, 7 + 100 * i, dial, sigs) for i, s in enumerate(sigs)]
    return pack.pack(C.NoteCode(int(sr), len(x), stereo, chans))


if __name__ == "__main__":
    import soundfile as sf
    x, sr = sf.read(sys.argv[1], always_2d=True)
    data = encode_note(x, sr, float(sys.argv[3]) if len(sys.argv) > 3 else None)
    open(sys.argv[2], "wb").write(data)

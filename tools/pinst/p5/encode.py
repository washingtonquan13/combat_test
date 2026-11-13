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
import decode
import pack
import quant
import transform

SIDE_DB = -40.0     # a side this far under the mid is silence (PINST3)
STEREO_COST = 0.03  # a pair's other codings (_stereo): bytes they may cost or must save
SNR_TOL = 0.5       # ... SNR, dB, they may lose
PRE_TOL = 1.0       # ... pre-echo, dB, they may gain
SNR_GAIN = 2.0      # ... SNR they must gain
PRE_GAIN = 2.0      # ... or pre-echo they must lose


def channels_of(x):
    """(n, 1 or 2) -> ([mono] or [mid, side], stereo flag)."""
    if x.shape[1] == 1:
        return [x[:, 0]], 0
    m, s = 0.5 * (x[:, 0] + x[:, 1]), 0.5 * (x[:, 0] - x[:, 1])
    side_db = 20 * np.log10(np.sqrt((s**2).mean()) / max(np.sqrt((m**2).mean()), 1e-12) + 1e-12)
    return [m, s if side_db >= SIDE_DB else np.zeros_like(s)], 1


def encode_channel(x, ref, f0, seed, dial, sigs, heard_of=None, sines=None):
    """sigs: the channels coded together (mid first): one channel, whose own
    level sets each step, or mid and side, under the level heard_of (default
    heard_ms_db) finds. sines: x's, when already found."""
    heard_of = heard_of or heard
    ch = C.ChannelCode()
    if not np.any(x):
        return ch
    ch.sines = analysis.encode_sines(x, f0) if sines is None else sines
    e = x - analysis.render_sines(ch.sines, len(x))
    tops = {}
    for M, w, s in blocks.plan(e, ref):
        if M not in tops:
            tops[M] = quant.top_db(transform.forward(ref, M))
        X = transform.forward(e * w, M, s)
        Xs = [_fit(transform.forward(g, M, s), len(X)) for g in sigs]    # every channel on X's grid
        L = quant.quantize(X, Xs[0], M, seed + 1 + len(ch.layers), dial, tops[M], heard_of(Xs))
        if L is not None:
            L.start = s
            ch.layers.append(L)
    return ch


def heard(Xs):
    return quant.heard_ms_db(*Xs) if len(Xs) == 2 else quant.heard_db(Xs)


def _fit(X, F):
    """X cut or zero-padded to F frames."""
    if len(X) >= F:
        return X[:F]
    return np.concatenate([X, np.zeros((F - len(X), X.shape[1]))])


def encode_note(x: np.ndarray, sr: int, f0: float | None, dial: float = C.DIAL) -> bytes:
    """x: (n, 1 or 2) float. f0: a pitch hint in Hz, or None."""
    C.set_rate(sr)
    sigs, stereo = channels_of(x)
    if stereo == 0:
        return pack.pack(C.NoteCode(int(sr), len(x), 0, [encode_channel(sigs[0], sigs[0], f0, 7, dial, sigs)]))
    return _stereo(x, sr, f0, dial, sigs)


def _stereo(x, sr, f0, dial, sigs):
    """A pair is coded three ways, each decoded and measured (bytes, the
    worse channel's SNR and pre-echo): mid/side with each step under the
    summed level (the format's way, and smallest when the channels share
    most of what they hold), mid/side under heard_ms_db (mid and side errors
    kept under the quieter channel), and left and right as they are. The
    first is kept unless another is no worse on all three (STEREO_COST more
    bytes, SNR_TOL less SNR, PRE_TOL more pre-echo at most) and clearly better
    on one (STEREO_COST fewer bytes, SNR_GAIN more SNR or PRE_GAIN less
    pre-echo); of those, the smallest."""
    found = [analysis.encode_sines(s, f0) if np.any(s) else None for s in sigs]

    def ms(hd):
        return pack.pack(C.NoteCode(int(sr), len(x), 1, [
            encode_channel(s, sigs[0], f0, 7 + 100 * i, dial, sigs, hd, found[i]) for i, s in enumerate(sigs)]))
    lr = pack.pack(C.NoteCode(int(sr), len(x), 2, [
        encode_channel(x[:, i], x[:, i], f0, 7 + 100 * i, dial, [x[:, i]]) for i in range(2)]))
    cands = [ms(quant.heard_db), ms(heard), lr]
    live = [c for c in range(2) if np.any(x[:, c])]
    if not live:
        return cands[0]
    n, snr, pre = [], [], []
    for d in cands:
        y = decode.decode(d)[0]
        n.append(len(d))
        snr.append(min(_snr_db(x[:, c], y[:, c]) for c in live))
        pre.append(max(pre_echo_db(x[:, c], y[:, c], sr) for c in live))
    ok = [i for i in (1, 2)
          if n[i] <= n[0] * (1 + STEREO_COST) and snr[i] >= snr[0] - SNR_TOL and pre[i] <= pre[0] + PRE_TOL
          and (n[i] <= n[0] * (1 - STEREO_COST) or snr[i] >= snr[0] + SNR_GAIN or pre[i] <= pre[0] - PRE_GAIN)]
    return cands[min(ok, key=lambda i: n[i]) if ok else 0]


def _snr_db(x, y):
    return 10 * np.log10(max((x**2).sum(), 1e-30) / max(((x - y) ** 2).sum(), 1e-30))


def pre_echo_db(x, y, sr):
    """How far (dB) the decoded y stands over the source x (or 60 dB under
    its loudest) in the 20 ms before a hit: a 1 ms block 12 dB over the 8 ms
    before it."""
    b = max(1, round(sr / 1000))
    m = len(x) // b
    if m < 30:
        return 0.0
    ps = (x[: m * b].reshape(m, b) ** 2).mean(1)
    pd = (y[: m * b].reshape(m, b) ** 2).mean(1)
    db = lambda p: 10 * np.log10(np.maximum(p, 1e-30))
    s, d = db(ps), db(pd)
    top = s.max()
    prev = np.convolve(np.concatenate([np.zeros(8), ps]), np.ones(8) / 8, mode="valid")[:m]
    over = d - np.maximum(s, top - 60)
    worst = 0.0
    for h in np.flatnonzero((s > db(prev) + 12) & (s > top - 60)):
        if h > 0:
            worst = max(worst, float(over[max(0, h - 20):h].max()))
    return worst


if __name__ == "__main__":
    import soundfile as sf
    x, sr = sf.read(sys.argv[1], always_2d=True)
    data = encode_note(x, sr, float(sys.argv[3]) if len(sys.argv) > 3 else None)
    open(sys.argv[2], "wb").write(data)

"""PINST5 encoder glue: one note -> bytes. Owned by the integrator; the
work is in the stage files (contract.py lists who calls what).

  python -I -B encode.py in.wav out.pinst5 [f0_hz]
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))      # python -I leaves it out
import numpy as np  # noqa: E402
from scipy.ndimage import maximum_filter1d  # noqa: E402

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
PRE_OK = 1.0        # ... pre-echo, dB, that is none; over it, a coding that cuts it PRE_GAIN or more
FIX_COST = 0.25     # ... may cost this many more bytes (the least pre-echo, within PRE_TOL, then the fewest bytes)
PEAK_OVER = 1.02   # a decoded sample this many times the source's peak is over it (_peaks)
PEAK_DB = 6.0       # ... the frames over it are coded this much finer each round after the first
PEAK_ROUNDS = 3     # ... for at most this many rounds


def channels_of(x):
    """(n, 1 or 2) -> ([mono] or [mid, side], stereo flag)."""
    if x.shape[1] == 1:
        return [x[:, 0]], 0
    m, s = 0.5 * (x[:, 0] + x[:, 1]), 0.5 * (x[:, 0] - x[:, 1])
    side_db = 20 * np.log10(np.sqrt((s**2).mean()) / max(np.sqrt((m**2).mean()), 1e-12) + 1e-12)
    return [m, s if side_db >= SIDE_DB else np.zeros_like(s)], 1


def encode_channel(x, ref, f0, seed, dial, sigs, heard_of=None, sines=None, tight=None, lr=()):
    """sigs: the channels coded together (mid first): one channel, whose own
    level sets each step, or mid and side, under the level heard_of (default
    heard_ms_db) finds. sines: x's, when already found. tight: None, or per
    sample the least SNR (dB) every frame that covers it is coded to (_peaks)."""
    heard_of = heard_of or heard
    ch = C.ChannelCode()
    if not np.any(x):
        return ch
    ch.sines = analysis.encode_sines(x, f0) if sines is None else sines
    e = x - analysis.render_sines(ch.sines, len(x))
    tops = {}
    for M, w, s in blocks.plan(e, ref, lr):
        if M not in tops:
            tops[M] = quant.top_db(transform.forward(ref, M))
        X = transform.forward(e * w, M, s)
        on = w[s:] > 0      # heard where this piece covers: a frame that runs past a clean cut hears no hit after it
        whole = on.all()
        Xs = [_fit(transform.forward(g if whole else g * (w > 0), M, s), len(X)) for g in sigs]
        Xr = Xs[0] if whole else _fit(transform.forward(sigs[0], M, s), len(X))     # the note's tonality: all of it
        tf = None if tight is None else _frame_max(tight, M, s, len(X))
        L = quant.quantize(X, Xr, M, seed + 1 + len(ch.layers), dial, tops[M], heard_of(Xs), tf)
        if L is not None:
            L.start = s
            ch.layers.append(L)
    return ch


def heard(Xs):
    return quant.heard_ms_db(*Xs) if len(Xs) == 2 else quant.heard_db(Xs)


def _frame_max(t, M, s, F):
    """(F,) the most of t over each frame's support (start + f*M - M/2 to
    start + f*M + 3M/2, transform.py)."""
    c = np.minimum(s + np.arange(F) * M + M // 2, len(t) - 1)
    return maximum_filter1d(t, 2 * M, mode="constant", cval=0.0)[c]


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
        sn = analysis.encode_sines(sigs[0], f0) if np.any(sigs[0]) else None

        def code(t):
            return pack.pack(C.NoteCode(int(sr), len(x), 0, [encode_channel(sigs[0], sigs[0], f0, 7, dial, sigs, None, sn, t)]))
        data = code(None)
        return _peaks(x, code, data, decode.decode(data)[0] if np.any(x) else None, dial)
    return _peaks(x, *_stereo(x, sr, f0, dial, sigs), dial)


def _peaks(x, code, data, y, dial):
    """A noise-like band is coded as coarse as dial * NOISE_FRAC under its
    level (quant.py), its own noise hiding the error; but where the source
    stands near its peak that error stands over the peak (16-20 dB of SNR
    puts a sample of noise 20-30 % over a peak 2.5 times the RMS, past full
    scale on a loud note). So each decoded sample over PEAK_OVER times the
    source's peak has every frame that covers it, in every layer and channel,
    coded again to the dial at least, and a frame still over PEAK_DB finer
    each round, for PEAK_ROUNDS rounds at most. code(tight) codes the note as
    chosen, each frame to at least the most of tight (per sample, dB) over it."""
    if y is None:
        return data
    lim = PEAK_OVER * np.abs(x).max()
    t = np.zeros(len(x))
    for _ in range(PEAK_ROUNDS):
        over = (np.abs(y) > lim).any(axis=1)
        if not over.any():
            break
        near = maximum_filter1d(t, 2 * blocks.LONG_M, mode="constant", cval=0.0)[over]
        t[over] = np.where(near > 0, near + PEAK_DB, dial)
        data = code(t)
        y = decode.decode(data)[0]
    return data


def _stereo(x, sr, f0, dial, sigs):
    """A pair is coded three ways, each decoded and measured (bytes, the
    worse channel's SNR and pre-echo): mid/side with each step under the
    summed level (the format's way, and smallest when the channels share
    most of what they hold), mid/side under heard_ms_db (mid and side errors
    kept under the quieter channel), and left and right as they are. The
    first is kept unless another is no worse on all three (STEREO_COST more
    bytes, SNR_TOL less SNR, PRE_TOL more pre-echo at most) and clearly better
    on one (STEREO_COST fewer bytes, SNR_GAIN more SNR or PRE_GAIN less
    pre-echo); of those, the smallest. A kept coding with pre-echo over
    PRE_OK then gives way to one that cuts it PRE_GAIN or more for FIX_COST
    more bytes at most (one channel silent while the other hits: mid and side
    must cancel to the silent one, which the summed level does not code them
    to; Marimba 25.7 dB, e2_Mute_Fret 12.0). Returns (code(tight), its bytes,
    its decode) for _peaks."""
    found = [analysis.encode_sines(s, f0) if np.any(s) else None for s in sigs]
    own = [analysis.encode_sines(x[:, i], f0) if np.any(x[:, i]) else None for i in range(2)]
    lrs = (x[:, 0], x[:, 1])     # blocks.plan: hits in one channel the pair does not show

    def ms(hd):
        return lambda t: pack.pack(C.NoteCode(int(sr), len(x), 1, [
            encode_channel(s, sigs[0], f0, 7 + 100 * i, dial, sigs, hd, found[i], t, lrs) for i, s in enumerate(sigs)]))

    def lr(t):
        return pack.pack(C.NoteCode(int(sr), len(x), 2, [
            encode_channel(x[:, i], x[:, i], f0, 7 + 100 * i, dial, [x[:, i]], None, own[i], t) for i in range(2)]))
    codes = [ms(quant.heard_db), ms(heard), lr]
    cands = [c(None) for c in codes]
    live = [c for c in range(2) if np.any(x[:, c])]
    if not live:
        return codes[0], cands[0], None
    n, snr, pre, ys = [], [], [], []
    for d in cands:
        y = decode.decode(d)[0]
        ys.append(y)
        n.append(len(d))
        snr.append(min(_snr_db(x[:, c], y[:, c]) for c in live))
        pre.append(max(pre_echo_db(x[:, c], y[:, c], sr) for c in live))
    ok = [i for i in (1, 2)
          if n[i] <= n[0] * (1 + STEREO_COST) and snr[i] >= snr[0] - SNR_TOL and pre[i] <= pre[0] + PRE_TOL
          and (n[i] <= n[0] * (1 - STEREO_COST) or snr[i] >= snr[0] + SNR_GAIN or pre[i] <= pre[0] - PRE_GAIN)]
    k = min(ok, key=lambda i: n[i]) if ok else 0
    if pre[k] > PRE_OK:
        fix = [i for i in range(3) if n[i] <= n[0] * (1 + FIX_COST) and snr[i] >= snr[k] - SNR_TOL
               and pre[i] <= pre[k] - PRE_GAIN]
        if fix:
            best = min(pre[i] for i in fix)
            k = min((i for i in fix if pre[i] <= max(best + PRE_TOL, PRE_OK)), key=lambda i: n[i])
    return codes[k], cands[k], ys[k]


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

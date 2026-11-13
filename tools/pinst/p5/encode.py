"""PINST5 encoder glue: one note -> bytes. Owned by the integrator; the
work is in the stage files (contract.py lists who calls what).

  python -I -B encode.py in.wav out.pinst5 [f0_hz]

A note is coded several times over (_stereo's three codings, _peaks'
rounds), and those codings differ only in their steps: each channel's
sines, block plan and coefficients are found once (Channel) and every
coding re-runs quant.quantize alone, then pack. A coding is measured on
what the decoder makes of it, built from the same layers in memory
(Channel.decoded: decode.channel's sum, each layer's samples made once).
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


def _ro(a):
    """a, read-only: what every coding shares is never changed in place."""
    a.setflags(write=False)
    return a


class Channel:
    """One channel, as far as every coding of it is the same: its sines and
    their samples, the block plan, and per piece the coefficients of the
    remainder (X), of the note (Xr) and of every channel coded with it (Xs),
    and the note's top. Only the steps differ between codings (heard_of,
    tight); each layer is kept by what it was quantized from, with its
    decoded samples, so a coding asking for the same layer gets it again.

    sigs: the channels coded together (mid first): one channel, whose own
    level sets each step, or mid and side, under the level heard_of finds.
    sines: x's, when already found (find=False: as given, None included)."""

    def __init__(self, x, ref, f0, sigs, sines=None, lr=(), find=True):
        self.n = len(x)
        self.live = bool(np.any(x))
        self.pieces = []
        self._heard = {}
        self._layers = {}
        self._inv = {}
        self.sines = None
        if not self.live:
            self.det = _ro(np.zeros(self.n))
            return
        self.sines = analysis.encode_sines(x, f0) if sines is None and find else sines
        self.det = _ro(analysis.render_sines(self.sines, len(x)))
        e = x - self.det
        tops = {}
        for M, w, s in blocks.plan(e, ref, lr):
            if M not in tops:
                tops[M] = quant.top_db(transform.forward(ref, M))
            X = transform.forward(e * w, M, s)
            on = w[s:] > 0      # heard where this piece covers: a frame that runs past a clean cut hears no hit after it
            whole = on.all()
            Xs = [_ro(_fit(transform.forward(g if whole else g * (w > 0), M, s), len(X))) for g in sigs]
            Xr = Xs[0] if whole else _ro(_fit(transform.forward(sigs[0], M, s), len(X)))     # the note's tonality: all of it
            self.pieces.append((M, s, X, Xr, Xs, tops[M]))

    def heard(self, heard_of):
        if heard_of not in self._heard:
            self._heard[heard_of] = [_ro(heard_of(p[4])) for p in self.pieces]
        return self._heard[heard_of]

    def code(self, seed, dial, heard_of, tight=None):
        """tight: None, or a _Tight: per sample the least SNR (dB) every frame
        that covers it is coded to (_peaks)."""
        ch = C.ChannelCode()
        if not self.live:
            return ch
        ch.sines = self.sines
        hs = self.heard(heard_of)
        for i, (M, s, X, Xr, Xs, top) in enumerate(self.pieces):
            tf = None if tight is None else tight.frame_max(M, s, len(X))
            if tf is not None and not tf.any():
                tf = None       # 0 leaves every frame as band_snr has it (quant.quantize), as None does
            sd = seed + 1 + len(ch.layers)
            key = (i, sd, dial, heard_of, None if tf is None else tf.tobytes())
            if key not in self._layers:
                L = quant.quantize(X, Xr, M, sd, dial, top, hs[i], tf)
                if L is not None:
                    L.start = s
                self._layers[key] = L
            L = self._layers[key]
            if L is not None:
                ch.layers.append(L)
        return ch

    def decoded(self, ch):
        """decode.channel of this channel's code, from the layers in memory."""
        y = self.det
        for L in ch.layers:
            k = id(L)       # L is held in _layers, so its id stays its own
            if k not in self._inv:
                self._inv[k] = _ro(transform.inverse(quant.dequantize(L), self.n, L.M, L.start))
            y = y + self._inv[k]
        return y


def encode_channel(x, ref, f0, seed, dial, sigs, heard_of=None, sines=None, tight=None, lr=()):
    """One coding of one channel (heard_of: default heard). tight: None, or
    per sample the least SNR (dB) every frame that covers it is coded to."""
    return Channel(x, ref, f0, sigs, sines, lr).code(seed, dial, heard_of or heard, None if tight is None else _Tight(tight))


def heard(Xs):
    return quant.heard_ms_db(*Xs) if len(Xs) == 2 else quant.heard_db(Xs)


class _Tight:
    """t (per sample, dB) as each frame takes it: the most of t over the
    frame's support (start + f*M - M/2 to start + f*M + 3M/2, transform.py)."""

    def __init__(self, t):
        self.t = t
        self._mf = {}

    def frame_max(self, M, s, F):
        if M not in self._mf:
            self._mf[M] = maximum_filter1d(self.t, 2 * M, mode="constant", cval=0.0)
        c = np.minimum(s + np.arange(F) * M + M // 2, len(self.t) - 1)
        return self._mf[M][c]


def _fit(X, F):
    """X cut or zero-padded to F frames."""
    if len(X) >= F:
        return X[:F]
    return np.concatenate([X, np.zeros((F - len(X), X.shape[1]))])


def _coder(sr, n, stereo, chans, seeds, dial, heard_of):
    """code(tight per sample, or None) -> (bytes, what decode.decode makes of them)."""
    def code(t):
        tt = None if t is None else _Tight(t)
        note = C.NoteCode(int(sr), n, stereo, [c.code(sd, dial, heard_of, tt) for c, sd in zip(chans, seeds)])
        ys = [c.decoded(ch) for c, ch in zip(chans, note.channels)]
        if stereo == 1:
            m, s = ys
            y = np.stack([m + s, m - s], axis=1)
        else:
            y = np.stack(ys, axis=1)
        return pack.pack(note), y
    return code


def encode_note(x: np.ndarray, sr: int, f0: float | None, dial: float = C.DIAL) -> bytes:
    """x: (n, 1 or 2) float. f0: a pitch hint in Hz, or None."""
    C.set_rate(sr)
    sigs, stereo = channels_of(x)
    if stereo == 0:
        sn = analysis.encode_sines(sigs[0], f0) if np.any(sigs[0]) else None
        code = _coder(sr, len(x), 0, [Channel(sigs[0], sigs[0], f0, sigs, sn, find=False)], (7,), dial, heard)
        data, y = code(None)
        return _peaks(x, code, data, y if np.any(x) else None, dial)
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
    chosen, each frame to at least the most of tight (per sample, dB) over it,
    and gives its bytes and their decode."""
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
        data, y = code(t)
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
    lrs = (x[:, 0], x[:, 1])     # blocks.plan: hits in one channel the pair does not show
    n = len(x)
    # each channel straight after its sines: render_sines then has their samples, made once (analysis' render cache)
    ms = [Channel(s, sigs[0], f0, sigs, analysis.encode_sines(s, f0) if np.any(s) else None, lrs, find=False)
          for s in sigs]
    lr = []
    for i in range(2):
        xi = x[:, i]
        if i and np.array_equal(xi, x[:, 0]):
            lr.append(lr[0])        # the same samples code the same (the seed is code's)
            continue
        sn = ms[0].sines if np.array_equal(xi, sigs[0]) else analysis.encode_sines(xi, f0) if np.any(xi) else None
        lr.append(Channel(xi, xi, f0, [xi], sn, find=False))
    seeds = (7, 107)
    codes = [_coder(sr, n, 1, ms, seeds, dial, quant.heard_db), _coder(sr, n, 1, ms, seeds, dial, heard),
             _coder(sr, n, 2, lr, seeds, dial, heard)]
    cands = [c(None) for c in codes]
    live = [c for c in range(2) if np.any(x[:, c])]
    if not live:
        return codes[0], cands[0][0], None
    xe = {c: max((x[:, c] ** 2).sum(), 1e-30) for c in live}
    pe = {c: _PreEcho(x[:, c], sr) for c in live}
    nb, snr, pre, ys = [], [], [], []
    for d, y in cands:
        ys.append(y)
        nb.append(len(d))
        snr.append(min(10 * np.log10(xe[c] / max(((x[:, c] - y[:, c]) ** 2).sum(), 1e-30)) for c in live))
        pre.append(max(pe[c](y[:, c]) for c in live))
    ok = [i for i in (1, 2)
          if nb[i] <= nb[0] * (1 + STEREO_COST) and snr[i] >= snr[0] - SNR_TOL and pre[i] <= pre[0] + PRE_TOL
          and (nb[i] <= nb[0] * (1 - STEREO_COST) or snr[i] >= snr[0] + SNR_GAIN or pre[i] <= pre[0] - PRE_GAIN)]
    k = min(ok, key=lambda i: nb[i]) if ok else 0
    if pre[k] > PRE_OK:
        fix = [i for i in range(3) if nb[i] <= nb[0] * (1 + FIX_COST) and snr[i] >= snr[k] - SNR_TOL
               and pre[i] <= pre[k] - PRE_GAIN]
        if fix:
            best = min(pre[i] for i in fix)
            k = min((i for i in fix if pre[i] <= max(best + PRE_TOL, PRE_OK)), key=lambda i: nb[i])
    return codes[k], cands[k][0], ys[k]


def _snr_db(x, y):
    return 10 * np.log10(max((x**2).sum(), 1e-30) / max(((x - y) ** 2).sum(), 1e-30))


def _db(p):
    return 10 * np.log10(np.maximum(p, 1e-30))


class _PreEcho:
    """pre_echo_db against one source x: its own half (the hits, the floor)
    found once for every decode measured against it."""

    def __init__(self, x, sr):
        self.b = b = max(1, round(sr / 1000))
        self.m = m = len(x) // b
        if m < 30:
            return
        ps = (x[: m * b].reshape(m, b) ** 2).mean(1)
        s = _db(ps)
        top = s.max()
        prev = np.convolve(np.concatenate([np.zeros(8), ps]), np.ones(8) / 8, mode="valid")[:m]
        self.floor = np.maximum(s, top - 60)
        h = np.flatnonzero((s > _db(prev) + 12) & (s > top - 60))
        self.hits = h[h > 0]

    def __call__(self, y):
        b, m = self.b, self.m
        if m < 30 or not len(self.hits):
            return 0.0
        over = _db((y[: m * b].reshape(m, b) ** 2).mean(1)) - self.floor
        pad = np.concatenate([np.full(20, -np.inf), over])      # hit h's window: over[max(0, h - 20):h]
        v = np.lib.stride_tricks.sliding_window_view(pad, 20)[self.hits].max(axis=1)
        v = v[~np.isnan(v)]         # max(worst, nan) keeps worst
        return max(0.0, float(v.max())) if len(v) else 0.0


def pre_echo_db(x, y, sr):
    """How far (dB) the decoded y stands over the source x (or 60 dB under
    its loudest) in the 20 ms before a hit: a 1 ms block 12 dB over the 8 ms
    before it."""
    return _PreEcho(x, sr)(y)


if __name__ == "__main__":
    import soundfile as sf
    x, sr = sf.read(sys.argv[1], always_2d=True)
    data = encode_note(x, sr, float(sys.argv[3]) if len(sys.argv) > 3 else None)
    open(sys.argv[2], "wb").write(data)

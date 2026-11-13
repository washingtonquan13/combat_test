"""PINST5 stage: the sine layer (owner: agent A).

encode_sines(x, f0) -> SineCode or None
render_sines(code, n) -> the samples the decoder plays for it

Wave 1: the pitch comes from the sound (find_pitch; the caller's f0 is only
a fallback), the tracker's window from that pitch, peaks run to Nyquist, and
a channel's whole sine layer is dropped when it cannot pay for itself
(worth_keeping). The tracks are still PINST3's tracker and quantizer.
"""
from __future__ import annotations

import hashlib
from collections import OrderedDict

import numpy as np
from scipy.signal import find_peaks

import contract as C
import pinst_codec as pc
import pinst_file as pf
import sines_fast as sfast

TIER = pc.Tier("model", f_cents=0.5, f_tol=1)       # PINST3's partial settings (need_map.MODEL)
H = 256

# ------------------------------------------------------------------ pitch

def _long_spectrum(x, on=None):
    """Mean power spectrum over the 1.5 s after the onset, ~0.35 s windows.
    on: pc.onset_sample(x), when the caller has it."""
    sr = pc.SR
    N = 1 << int(np.ceil(np.log2(0.35 * sr)))
    on = pc.onset_sample(x) if on is None else on
    seg = x[on : on + int(1.5 * sr)]
    if len(seg) < N:
        seg = np.concatenate([seg, np.zeros(N - len(seg))])
    w = np.hanning(N)
    fr = np.lib.stride_tricks.sliding_window_view(seg, N)[:: N // 4]
    P = (np.abs(np.fft.rfft(fr * w, axis=1)) ** 2).mean(0)
    return P, N


def _peaks(P, N, rel_db=-60.0, prom_db=12.0, maxp=40):
    """The loudest spectral peaks: (Hz, dB), parabola-refined."""
    db = 10 * np.log10(P + 1e-30)
    k, _ = find_peaks(db, height=db.max() + rel_db, prominence=prom_db)
    k = k[(k > 1) & (k < len(db) - 1)]
    a, b, c = db[k - 1], db[k], db[k + 1]
    p = 0.5 * (a - c) / (a - 2 * b + c)
    f = (k + p) * pc.SR / N
    amp = b - 0.25 * (a - c) * p
    o = np.argsort(amp)[::-1][:maxp]
    return f[o], amp[o]


PITCHED = 0.5       # share of the peaks' amplitude a harmonic series must explain, past chance


def find_pitch(x, on=None):
    """The fundamental the sound's own spectrum shows, or None.

    Every candidate f0 on a 2-cent grid is scored by the share of the peaks'
    amplitude that sits on one of its first 40 harmonics, minus the share a
    random peak would hit by chance (so low candidates, whose harmonics lie
    dense, gain nothing for density alone). The best candidate wins if the
    series explains most of the spectrum; it is then refined by least squares
    on the peaks it matched. on: pc.onset_sample(x), when the caller has it."""
    P, N = _long_spectrum(x, on)
    f, a = _peaks(P, N)
    if len(f) == 0:
        return None
    grid = 15.0 * 2 ** (np.arange(0, 1200 * np.log2(2000.0 / 15.0), 2) / 1200)
    e = 10 ** (a / 20)
    e = e / e.sum()
    tol = np.maximum(0.6 * pc.SR / N, 0.005 * f)
    h = np.maximum(1, np.round(f[None, :] / grid[:, None]))
    ok = (h <= 40) & (np.abs(f[None, :] - h * grid[:, None]) < tol[None, :])
    chance = np.minimum(1, 2 * tol[None, :] / grid[:, None])
    sc = (ok * e).sum(1) - (chance * e).sum(1)
    i = int(np.argmax(sc))
    if sc[i] < PITCHED:
        return None
    m = ok[i] & (h[i] <= 16)
    if not m.any():
        m = ok[i]
    n, w = h[i, m], np.sqrt(e[m])
    r = f[m] / n                                     # each partial's own guess at f0
    f0 = float(np.sum(w * r) / np.sum(w))
    if len(np.unique(n)) >= 3:
        # a stiff string's partials run sharp, f_n / n = f0 (1 + B n^2 / 2): fit both
        sol, *_ = np.linalg.lstsq(np.stack([np.ones_like(n), n * n], 1) * w[:, None], r * w, rcond=None)
        if sol[1] > 0:
            f0 = float(sol[0])
    return f0


# ------------------------------------------------------------------ sines

CYCLES = 6          # analysis window: this many periods of the fundamental ...
N_MIN, N_MAX = 2048, 8192   # ... within these; 2048 when the sound shows no pitch


def window_for(f0):
    """The tracker's window: long enough to part the harmonics of the pitch
    the sound shows, no shorter than wave 0's."""
    if not f0:
        return N_MIN
    return int(np.clip(1 << int(np.ceil(np.log2(CYCLES * pc.SR / f0))), N_MIN, N_MAX))


def _analyse(x, f0, N, on=None):
    """pc.analyse's partial part: peaks up to Nyquist, tracks; no noise model.
    (The peaks and tracks are sines_fast.find_tracks: the legacy tracker's,
    bit for bit, faster.)"""
    # 8x overlap for the 8192 window halves its cost and measured no worse;
    # at 4096 a 512 hop cost a3_Sus_Up1 3.5 dB, so it keeps wave 0's 256
    hop = H if N <= 4096 else N // 8
    on = pc.onset_sample(x) if on is None else on
    first = int(np.ceil((on + N // 4) / hop))
    tracks = sfast.find_tracks(x, N, hop, first)
    ch = pc.Channel(len(x), hop, tracks, np.full((1, 1), -200.0), 512)
    ch.info = {"f0": f0}
    return ch


def worth_keeping(x, det, sine_bytes, on=None):
    """Whether the sine layer can save more than it costs.

    Taking the rendered sines out leaves a remainder Delta dB weaker than the
    sound. At any accuracy, the most that can save the MDCT is Delta / 6.02
    bits for every coefficient after the onset (the high-rate rule). The
    layer stays only if that bound beats its own compressed size: a layer
    that takes out a sliver of the energy (an inharmonic crash, a click) goes."""
    rem = float(np.dot(x - det, x - det))
    delta = 10 * np.log10(float(np.dot(x, x)) / max(rem, 1e-30))
    n = len(x) - (pc.onset_sample(x) if on is None else on)
    return delta / 6.02 * n > 8 * sine_bytes


# encode_sines is asked for the same signal more than once (a dual-mono pair's
# mid is its left and its right; every coding of a pair asks again): the
# answer depends only on the samples, the hint and the rate, so it is kept.
_ENC: OrderedDict = OrderedDict()
_ENC_KEEP = 4       # a note asks for 4 signals at most (mid, side, left, right)


def _quantize(ch):
    """(info, sizes) of pc.quantize(ch, TIER), the sine part (sines_fast.quantize)."""
    q = sfast.quantize(ch.tracks, ch.H, ch.info["f0"], TIER)
    if q is None:
        dec, sizes = pc.quantize(ch, TIER)
        return dec.info, sizes
    return q


def encode_sines(x: np.ndarray, f0: float | None) -> C.SineCode | None:
    """f0 is a hint, used only when the sound itself shows no pitch."""
    if not np.any(x):
        return None
    xb = np.ascontiguousarray(x, dtype=float)
    key = (pc.SR, f0, len(xb), x.dtype.str, hashlib.blake2b(memoryview(xb).cast("B"), digest_size=32).digest())
    if key in _ENC:
        _ENC.move_to_end(key)
        code = _ENC[key]
        return None if code is None else C.SineCode(dict(code.ints), dict(code.streams))
    code = _encode_sines(x, f0)
    _ENC[key] = code
    while len(_ENC) > _ENC_KEEP:
        _ENC.popitem(last=False)
    return None if code is None else C.SineCode(dict(code.ints), dict(code.streams))


def _encode_sines(x, f0):
    on = pc.onset_sample(x)
    f0 = find_pitch(x, on) or f0
    ch = _analyse(x, f0, window_for(f0), on)
    I, sizes = _quantize(ch)
    S = I["streams"]
    if not I["n_tracks"]:
        return None
    ints = {"H": ch.H, "f_c": round(TIER.f_cents * 1000), "a_d": round(TIER.a_db * 1000),
            "f0_c": round(TIER.f0_cents * 1000), "pbits": TIER.phase_bits, "lock": int(I["lock"]),
            "f0_frames": I["f0_frames"], "n_tracks": I["n_tracks"]}
    code = C.SineCode(ints, {k: S[k] for k in STREAM_KEYS})
    det = render_sines(code, len(x))    # kept in _REN: encode.py asks for it next
    if not worth_keeping(x, det, sum(sizes[k] for k in ("track_hdr", "track_dt", "track_df", "track_da", "f0")), on):
        return None
    return code


INT_KEYS = ("H", "f_c", "a_d", "f0_c", "pbits", "lock", "f0_frames", "n_tracks")
STREAM_KEYS = ("hdr", "dt", "df", "da", "f0")


def tracks_of(code: C.SineCode):
    """The decoded tracks, from the code alone (pinst_file._model's track part)."""
    I, S = code.ints, code.streams
    f_c, a_d, f0_c = I["f_c"] / 1000, I["a_d"] / 1000, I["f0_c"] / 1000
    lock, pbits = I["lock"], I["pbits"]
    f0q = None
    if lock:
        k0, q0 = pf._pairs(S["f0"])
        f0q = 20.0 * 2 ** (pc.expand(k0, (q0 * f0_c).astype(float)[:, None], I["f0_frames"])[:, 0] / 1200)
    tracks = []
    ch_, ct, cf, ca = pf.Cur(S["hdr"]), pf.Cur(S["dt"]), pf.Cur(S["df"]), pf.Cur(S["da"])
    start = 0
    for _ in range(I["n_tracks"]):
        start += ch_.v()
        nk = ch_.v()
        hh = ch_.v() if lock else 0
        qc, qa, qph = [ch_.v()], [ch_.v()], ch_.raw()
        keys = [0]
        for _ in range(nk - 1):
            keys.append(keys[-1] + ct.v())
            qc.append(qc[-1] + cf.v())
            qa.append(qa[-1] + ca.v())
        L = keys[-1] + 1
        ref = hh * f0q[start : start + L] if lock else np.full(L, 20.0)
        full = pc.expand(np.array(keys), np.stack([np.array(qc) * f_c, np.array(qa) * a_d], axis=1).astype(float), L)
        ph = np.zeros(L)
        ph[0] = qph / (1 << pbits) * pc.TWO_PI
        tracks.append(pc.Track(start, ref * 2 ** (full[:, 0] / 1200), full[:, 1], ph))
    return tracks


def _render(code, n):
    tr = tracks_of(code)
    return pc.synth_tracks(tr, n, code.ints["H"], mode="integrate", anchors=[0] * len(tr), gate_from=0)


# The encoder plays one code many times (every coding it tries, every decode
# of one, each a fresh SineCode from the bytes): the samples depend only on
# the code's content, n and the rate, so the last few are kept.
_REN: OrderedDict = OrderedDict()
_REN_KEEP = 6


def render_sines(code: C.SineCode | None, n: int) -> np.ndarray:
    if code is None:
        return np.zeros(n)
    key = (pc.SR, int(n), tuple(int(code.ints[k]) for k in INT_KEYS),
           tuple(bytes(code.streams[k]) for k in STREAM_KEYS))
    y = _REN.get(key)
    if y is None:
        # sines_fast.render: _render's samples, bit for bit (the same tracks into the same C synth)
        y = _REN[key] = sfast.render(code, n, _render)
        while len(_REN) > _REN_KEEP:
            _REN.popitem(last=False)
    else:
        _REN.move_to_end(key)
    return y.copy()

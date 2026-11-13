"""PINST5 stage: the sine layer (owner: agent A).

encode_sines(x, f0) -> SineCode or None
render_sines(code, n) -> the samples the decoder plays for it

Wave 1: the pitch comes from the sound (find_pitch; the caller's f0 is only
a fallback), the tracker's window from that pitch, peaks run to Nyquist, and
a channel's whole sine layer is dropped when it cannot pay for itself
(worth_keeping). The tracks are still PINST3's tracker and quantizer.
"""
from __future__ import annotations

import numpy as np
from scipy.signal import find_peaks

import contract as C
import pinst_codec as pc
import pinst_file as pf

TIER = pc.Tier("model", f_cents=0.5, f_tol=1)       # PINST3's partial settings (need_map.MODEL)
H = 256

# ------------------------------------------------------------------ pitch

def _long_spectrum(x):
    """Mean power spectrum over the 1.5 s after the onset, ~0.35 s windows."""
    sr = pc.SR
    N = 1 << int(np.ceil(np.log2(0.35 * sr)))
    on = pc.onset_sample(x)
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


def find_pitch(x):
    """The fundamental the sound's own spectrum shows, or None.

    Every candidate f0 on a 2-cent grid is scored by the share of the peaks'
    amplitude that sits on one of its first 40 harmonics, minus the share a
    random peak would hit by chance (so low candidates, whose harmonics lie
    dense, gain nothing for density alone). The best candidate wins if the
    series explains most of the spectrum; it is then refined by least squares
    on the peaks it matched."""
    P, N = _long_spectrum(x)
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


def _analyse(x, f0, N):
    """pc.analyse's partial part: peaks up to Nyquist, tracks; no noise model."""
    # 8x overlap for the 8192 window halves its cost and measured no worse;
    # at 4096 a 512 hop cost a3_Sus_Up1 3.5 dB, so it keeps wave 0's 256
    hop = H if N <= 4096 else N // 8
    on = pc.onset_sample(x)
    first = int(np.ceil((on + N // 4) / hop))
    frames = pc.find_peaks_frames(x, N, hop, fmax=pc.SR / 2)
    tracks = pc.track_peaks(frames, first_frame=first)
    ch = pc.Channel(len(x), hop, tracks, np.full((1, 1), -200.0), 512)
    ch.info = {"f0": f0}
    return ch


def worth_keeping(x, det, sine_bytes):
    """Whether the sine layer can save more than it costs.

    Taking the rendered sines out leaves a remainder Delta dB weaker than the
    sound. At any accuracy, the most that can save the MDCT is Delta / 6.02
    bits for every coefficient after the onset (the high-rate rule). The
    layer stays only if that bound beats its own compressed size: a layer
    that takes out a sliver of the energy (an inharmonic crash, a click) goes."""
    rem = float(np.dot(x - det, x - det))
    delta = 10 * np.log10(float(np.dot(x, x)) / max(rem, 1e-30))
    n = len(x) - pc.onset_sample(x)
    return delta / 6.02 * n > 8 * sine_bytes


_last = (None, None)    # the layer encode_sines kept and its render, which encode.py asks for next


def encode_sines(x: np.ndarray, f0: float | None) -> C.SineCode | None:
    """f0 is a hint, used only when the sound itself shows no pitch."""
    global _last
    if not np.any(x):
        return None
    f0 = find_pitch(x) or f0
    ch = _analyse(x, f0, window_for(f0))
    dec, sizes = pc.quantize(ch, TIER)
    I, S = dec.info, dec.info["streams"]
    if not I["n_tracks"]:
        return None
    ints = {"H": ch.H, "f_c": round(TIER.f_cents * 1000), "a_d": round(TIER.a_db * 1000),
            "f0_c": round(TIER.f0_cents * 1000), "pbits": TIER.phase_bits, "lock": int(I["lock"]),
            "f0_frames": I["f0_frames"], "n_tracks": I["n_tracks"]}
    code = C.SineCode(ints, {k: S[k] for k in STREAM_KEYS})
    det = render_sines(code, len(x))
    if not worth_keeping(x, det, sum(sizes[k] for k in ("track_hdr", "track_dt", "track_df", "track_da", "f0"))):
        return None
    _last = (code, det)
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


def render_sines(code: C.SineCode | None, n: int) -> np.ndarray:
    if code is None:
        return np.zeros(n)
    if code is _last[0] and len(_last[1]) == n:
        return _last[1].copy()      # the same call's samples, made once
    tr = tracks_of(code)
    return pc.synth_tracks(tr, n, code.ints["H"], mode="integrate", anchors=[0] * len(tr), gate_from=0)

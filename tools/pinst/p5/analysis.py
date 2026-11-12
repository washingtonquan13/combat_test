"""PINST5 stage: the sine layer (owner: agent A).

encode_sines(x, f0) -> SineCode or None
render_sines(code, n) -> the samples the decoder plays for it

Wave 0 is PINST3's partial tracker and track quantizer unchanged (window
from the file-name pitch, 18 kHz ceiling inside find_peaks_frames). The band
noise the legacy analysis also measures is thrown away: PINST5 has no noise
model, the MDCT layers code everything the sines leave.
"""
from __future__ import annotations

import numpy as np

import contract as C
import pinst_codec as pc
import pinst_file as pf

TIER = pc.Tier("model", f_cents=0.5, f_tol=1)       # PINST3's partial settings (need_map.MODEL)


def encode_sines(x: np.ndarray, f0: float | None) -> C.SineCode | None:
    if not np.any(x):
        return None
    ch = pc.analyse(x, f0 is not None, f0, TIER)
    ch.tns = None
    dec, _ = pc.quantize(ch, TIER)
    I, S = dec.info, dec.info["streams"]
    if not I["n_tracks"]:
        return None
    ints = {"H": ch.H, "f_c": round(TIER.f_cents * 1000), "a_d": round(TIER.a_db * 1000),
            "f0_c": round(TIER.f0_cents * 1000), "pbits": TIER.phase_bits, "lock": int(I["lock"]),
            "f0_frames": I["f0_frames"], "n_tracks": I["n_tracks"]}
    streams = {k: S[k] for k in ("hdr", "dt", "df", "da", "f0")}
    return C.SineCode(ints, streams)


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
    tr = tracks_of(code)
    return pc.synth_tracks(tr, n, code.ints["H"], mode="integrate", anchors=[0] * len(tr), gate_from=0)

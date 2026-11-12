"""PINST5 stage: where short and long blocks go (owner: agent B, with transform.py).

plan(e, ref) -> [(M, w)]: the remainder e is coded once per piece, as
transform.forward(e * w, M). The w sum to 1 at every sample.

Wave 0 is PINST3's split: a 128-sample block whose level jumps 12 dB over
the 8 before it is a hit; short blocks (128) from 256 samples before to 2048
after each hit with 1024-sample raised-cosine ramps, long blocks (1024)
everywhere else.
"""
from __future__ import annotations

import numpy as np

import contract  # noqa: F401  (puts the legacy modules on the path)
import pinst_codec as pc

SHORT_M, LONG_M = 128, 1024
TRANSIENT_DB = 12.0
TRANSIENT_PRE, TRANSIENT_POST, TRANSIENT_RAMP = 256, 2048, 1024
BLOCK = 128
AUDIBLE_DB = -60.0


def transients(e, top_db):
    m = len(e) // BLOCK
    p = (e[: m * BLOCK].reshape(m, BLOCK) ** 2).mean(1)
    pp = np.concatenate([np.zeros(8), p])
    prev = np.convolve(pp, np.ones(8) / 8, mode="valid")[:m]
    db = 10 * np.log10(p + 1e-30)
    hit = (db > 10 * np.log10(prev + 1e-30) + TRANSIENT_DB) & (db > top_db + AUDIBLE_DB)
    return np.flatnonzero(hit) * BLOCK


def short_window(n, ts):
    w = np.zeros(n)
    R = TRANSIENT_RAMP
    ramp = 0.5 - 0.5 * np.cos(np.pi * (np.arange(R) + 0.5) / R)
    for t in ts:
        a, b = max(0, t - TRANSIENT_PRE), min(n, t + TRANSIENT_POST)
        w[a:b] = 1
        lo = max(0, a - R)
        w[lo:a] = np.maximum(w[lo:a], ramp[R - (a - lo):])
        hi = min(n, b + R)
        w[b:hi] = np.maximum(w[b:hi], ramp[::-1][: hi - b])
    return w


def plan(e: np.ndarray, ref: np.ndarray):
    ts = transients(e, pc.block_db(ref, BLOCK).max()) if len(ref) >= BLOCK else []
    ws = short_window(len(e), ts)
    return [(M, w) for M, w in ((SHORT_M, ws), (LONG_M, 1 - ws)) if w.any()]

"""PINST5 stage: where short and long blocks go (owner: agent B, with transform.py).

plan(e, ref) -> [(M, w, start)]: the remainder e is coded once per piece, as
transform.forward(e * w, M, start). The w sum to 1 wherever e is not zero,
and each w is zero before its start.

A hit is a 128-sample block whose level jumps 12 dB over the 8 before it
(PINST3's test); a run of such blocks is one hit, found to the sample.

Short blocks (128) cover each hit from 256 samples before to 2048 after,
with 1024-sample raised-cosine ramps, long blocks (1024) the rest, as in
PINST3. A hit that jumps CLEAN_DB or more over what comes before it is
"clean": a short layer's coding noise sits about the dial under the hit,
so before such a hit it would stand over the quiet. A clean hit therefore
starts a new short layer exactly at its onset, on a grid of its own that
makes nothing before that sample (transform.py), and its short cover has
no lead before the onset: the long blocks fade out into the previous short
layer over the 1024 samples before it, and that layer ends at the onset.
Each short layer is one segment of time between clean onsets, so a note
has one short layer per clean hit (plus one for what comes before the
first). Every other layer's grid is laid from the note's first sample that
is not zero (starting at its first frame with something in it), so exact
silence before a note stays exact silence, and a note
that starts at sample 0 keeps PINST3's grid (moving the long grid a few
samples moves the whole-note SNR by up to 3 dB: quant.py's one-coefficient
low bands round to anywhere from 25 to 37 dB under the band).
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
CLEAN_DB = contract.DIAL    # a hit this far over what is before it gets a grid of its own
ONSET_OVER_PRE_DB = 12.0    # the onset sample is the first louder than this over the level before the hit
ONSET_UNDER_HIT_DB = 24.0   # ... and no quieter than this under the hit block's level
ONSET_W = 16
ONSET_CUT = 32              # the cut moves on to a zero crossing at most this far after the onset
ONSET_SHARE = 2 * BLOCK     # a channel's onset this close after one of the mid's is that hit


def transients(e, top_db):
    """(start sample, jump dB) of each 128-block that jumps TRANSIENT_DB over
    the mean of the 8 before."""
    m = len(e) // BLOCK
    p = (e[: m * BLOCK].reshape(m, BLOCK) ** 2).mean(1)
    pp = np.concatenate([np.zeros(8), p])
    prev = np.convolve(pp, np.ones(8) / 8, mode="valid")[:m]
    db = 10 * np.log10(p + 1e-30)
    jump = db - 10 * np.log10(prev + 1e-30)
    hit = np.flatnonzero((jump > TRANSIENT_DB) & (db > top_db + AUDIBLE_DB))
    return hit * BLOCK, jump[hit]


def cut_at_crossing(e, s):
    """The first sample at or after s, at most ONSET_CUT on, where e crosses
    zero (the side nearer zero), else s. Cut there, the layer that ends and
    the one that starts both meet the cut near zero, not with a step the
    MDCT spreads over every band; the few samples before it are still far
    under the hit, so the layer they stay in makes no pre-echo of it."""
    seg = e[s : min(len(e), s + ONSET_CUT + 1)]
    c = np.flatnonzero((np.signbit(seg[1:]) != np.signbit(seg[:-1])) | (seg[1:] == 0))
    if not len(c):
        return s
    k = s + int(c[0]) + 1
    return k if abs(e[k]) <= abs(e[k - 1]) else k - 1


def onsets(e, top_db):
    """[(onset sample, jump dB)], one per run of hit blocks. The run's hit is
    its block with the biggest jump; its onset is the first sample, from one
    block before that, whose power stands ONSET_OVER_PRE_DB over the mean
    power of the 8 blocks before and within ONSET_UNDER_HIT_DB of the hit
    block's, in a run of ONSET_W samples whose mean does too (so one stray
    sample is not it), moved on to the next zero crossing."""
    if len(e) < BLOCK:
        return []
    ts, jumps = transients(e, top_db)
    runs = np.split(np.arange(len(ts)), np.flatnonzero(np.diff(ts) > BLOCK) + 1) if len(ts) else []
    e2 = e**2
    cs = np.concatenate([[0.0], np.cumsum(e2)])
    out = []
    for r in runs:
        i = r[np.argmax(jumps[r])]
        t = int(ts[i])
        lo = max(0, t - BLOCK)
        a = max(0, lo - 8 * BLOCK)
        thr = (cs[lo] - cs[a]) / max(lo - a, 1) * 10 ** (ONSET_OVER_PRE_DB / 10)
        thr = max(thr, (cs[t + BLOCK] - cs[t]) / BLOCK * 10 ** (-ONSET_UNDER_HIT_DB / 10))
        n = np.arange(lo, t + BLOCK)
        win = (cs[np.minimum(n + ONSET_W, len(e))] - cs[n]) / ONSET_W
        ok = np.flatnonzero(win > thr)
        if not len(ok):
            continue
        n0 = lo + int(ok[0])
        s = cut_at_crossing(e, n0 + int(np.flatnonzero(e2[n0 : n0 + ONSET_W] > thr)[0]))
        if not out or s > out[-1][0]:
            out.append((s, float(jumps[i])))
    return out


def shared_onsets(own, ref_ons):
    """The mid's onsets, plus this channel's own where the mid has none at or
    up to ONSET_SHARE before it (a mid onset that stands for one takes the
    bigger jump). Mid and side then put a shared hit on one grid, and an own
    onset earlier than the mid's still starts its own layer, so no noise
    lands before it."""
    out = {s: j for s, j in ref_ons}
    r = np.array([s for s, _ in ref_ons], dtype=np.int64)
    for s, j in own:
        m = np.flatnonzero((r <= s) & (r >= s - ONSET_SHARE))
        if len(m):
            k = int(r[m[-1]])
            out[k] = max(out[k], j)
        else:
            out[s] = max(out.get(s, j), j)
    return sorted(out.items())


def plan(e: np.ndarray, ref: np.ndarray):
    n = len(e)
    nz = np.flatnonzero(e)
    if not len(nz):
        return []
    top = pc.block_db(ref, BLOCK).max() if len(ref) >= BLOCK else 0.0
    hits = shared_onsets(onsets(e, top), onsets(ref, top))
    hits = [(int(nz[0]) if s - nz[0] <= ONSET_W else s, j) for s, j in hits]
    clean = [s for s, j in hits if j >= CLEAN_DB]
    R = TRANSIENT_RAMP
    up = 0.5 - 0.5 * np.cos(np.pi * (np.arange(R) + 0.5) / R)
    cov = np.zeros(n)

    def ramp_up(end):            # cov rises to 1 over the R samples before `end`
        a = max(0, end - R)
        cov[a:end] = np.maximum(cov[a:end], up[R - (end - a) :])

    for s, j in hits:
        b = min(n, s + TRANSIENT_POST)
        a = s if j >= CLEAN_DB else max(0, s - TRANSIENT_PRE)
        cov[a:b] = 1
        ramp_up(a)               # a clean hit's lead-in is the previous layer's
        hi = min(n, b + R)
        cov[b:hi] = np.maximum(cov[b:hi], up[::-1][: hi - b])
    cov = np.where(cov > 1e-9, cov, 0.0)
    first = int(nz[0])
    pieces = [(LONG_M, 1 - cov, first)]
    for a, b in zip([first] + clean, clean + [n]):
        w = np.zeros(n)
        w[a:b] = cov[a:b]
        pieces.append((SHORT_M, w, a))
    out = []
    for M, w, a in pieces:
        live = np.flatnonzero(w[a:] * e[a:])
        if len(live):            # skip whole frames of nothing, staying on the grid from `a`
            out.append((M, w, a + int(live[0]) // M * M))
    return out

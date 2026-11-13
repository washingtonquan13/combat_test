"""PINST5 stage: where short and long blocks go (owner: agent B, with transform.py).

plan(e, ref) -> [(M, w, start)]: the remainder e is coded once per piece, as
transform.forward(e * w, M, start). The w sum to 1 wherever e is not zero,
and each w is zero before its start.

A hit is a 128-sample block whose level jumps 12 dB over the 8 before it
(PINST3's test) or CLEAN_DB over the 2 just before (a dip, then a re-hit); a run of
such blocks is one hit, found to the sample.

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
TRANSIENT_GAP = 2           # blocks: a dip this long that a block jumps CLEAN_DB over is a hit (transients)
TRANSIENT_PRE, TRANSIENT_POST, TRANSIENT_RAMP = 256, 2048, 1024
BLOCK = 128
AUDIBLE_DB = -60.0
CLEAN_DB = contract.DIAL    # a hit this far over what is before it gets a grid of its own
ONSET_OVER_PRE_DB = 12.0    # the onset sample is the first louder than this over the level before the hit
ONSET_UNDER_HIT_DB = 24.0   # ... and no quieter than this under the hit block's level
ONSET_W = 16
ONSET_SHARE = 2 * BLOCK     # a channel's onset this close after one of the mid's is that hit
HEARD_SHARE = ONSET_W       # ... and a left or right channel's (plan's heard): its own hit, a few ms on, is not the other's


def transients(e, top_db, gaps=True):
    """(start sample, jump dB, by the gap) of each 128-block that jumps
    TRANSIENT_DB over the mean of the 8 blocks before, or (if gaps) CLEAN_DB
    over the mean of the TRANSIENT_GAP just before or one block earlier (then
    "by the gap", and that is its jump). The 8 alone (23 ms) hear a sound
    that dips for a few ms and hits again as no jump, the loud part before the
    dip standing in for it, and the long blocks over the re-hit put its noise,
    about the dial under it, in the dip (Timpani, 13.7 dB of pre-echo). A dip
    shallower than CLEAN_DB hides that noise; heard as hits, such dips (a
    horn's tremolo, a drum roll) put whole notes in short blocks (bytes -27 to
    +45 %, b10 down 2-5 dB). gaps is for the signal coded (plan's e), not the
    note it is heard against: the coding noise sits under e's own hit, and a
    low pulse-like tone's source dips between its pulses every period (Horn,
    gap hits every 1-2 periods, b10 -3.6 dB) where the sines leave e no dip."""
    m = len(e) // BLOCK
    p = (e[: m * BLOCK].reshape(m, BLOCK) ** 2).mean(1)
    pp = np.concatenate([np.zeros(8), p])
    G = TRANSIENT_GAP
    db = 10 * np.log10(p + 1e-30)
    j8 = db - 10 * np.log10(np.convolve(pp, np.ones(8) / 8, mode="valid")[:m] + 1e-30)
    g = np.convolve(pp, np.ones(G) / G, mode="valid")
    g = np.minimum(g[8 - G : 8 - G + m], g[7 - G : 7 - G + m])     # the gap just before, or one block earlier (onsets' lo)
    jg = db - 10 * np.log10(g + 1e-30)
    gap = (jg >= CLEAN_DB) & (jg > j8) & gaps & (np.arange(m) > G)     # a gap is in e, not before it
    jump = np.where(gap, jg, j8)
    hit = np.flatnonzero((jump > TRANSIENT_DB) & (db > top_db + AUDIBLE_DB))
    return hit * BLOCK, jump[hit], gap[hit]


def onsets(e, top_db, gaps=True):
    """[(onset sample, jump dB)], one per run of hit blocks. A block that
    stands TRANSIENT_DB over the block just before it starts a run of its
    own: the first block with anything in it jumps without limit over the
    silence before it, so a quiet lead-in whose next block holds the hit
    would otherwise take the run, and the hit would get no onset (pre-echo
    of 10-28 dB in the few ms before it). The run's hit is
    its block with the biggest jump; its onset is the first sample, from one
    block before that, whose power stands ONSET_OVER_PRE_DB over the power
    before (as transients() measures it) and within ONSET_UNDER_HIT_DB of the hit's
    level (the louder of the hit block and the next: the block with the
    biggest jump is often the one the hit starts in, half lead-in, and under
    its mean a sample 30 dB under the hit passed as the onset), in a run of
    ONSET_W samples whose mean does too (so one stray sample is not it).
    The cut is that sample, not a zero crossing near it: moved on, the cut
    lands inside the attack and the layer that ends there spreads those
    samples over the quiet before the hit (Triangle3, 10.7 dB); moved back,
    the new layer's noise, about the dial under the hit, fills the quiet
    samples between (ht_qo, 10.8 dB)."""
    if len(e) < BLOCK:
        return []
    ts, jumps, gaps = transients(e, top_db, gaps)
    m = len(e) // BLOCK
    bdb = 10 * np.log10((e[: m * BLOCK].reshape(m, BLOCK) ** 2).mean(1) + 1e-30)
    b = ts[1:] // BLOCK
    cut = (np.diff(ts) > BLOCK) | (bdb[b] - bdb[b - 1] > TRANSIENT_DB)
    runs = np.split(np.arange(len(ts)), np.flatnonzero(cut) + 1) if len(ts) else []
    e2 = e**2
    cs = np.concatenate([[0.0], np.cumsum(e2)])
    out = []
    for r in runs:
        i = r[np.argmax(jumps[r])]
        t = int(ts[i])
        lo = max(0, t - BLOCK)
        a = max(0, lo - (TRANSIENT_GAP if gaps[i] else 8) * BLOCK)      # as transients() found it
        pre = (cs[lo] - cs[a]) / max(lo - a, 1)
        if gaps[i]:
            pre = min(pre, (cs[t] - cs[a + BLOCK]) / max(t - a - BLOCK, 1))
        thr = pre * 10 ** (ONSET_OVER_PRE_DB / 10)
        t2 = min(len(e), t + 2 * BLOCK)     # the hit's level: the louder of its block and the next
        hit = max(cs[t + BLOCK] - cs[t], (cs[t2] - cs[t + BLOCK]) * BLOCK / max(t2 - t - BLOCK, 1)) / BLOCK
        thr = max(thr, hit * 10 ** (-ONSET_UNDER_HIT_DB / 10))
        n = np.arange(lo, t + BLOCK)
        win = (cs[np.minimum(n + ONSET_W, len(e))] - cs[n]) / ONSET_W
        ok = np.flatnonzero(win > thr)
        if not len(ok):
            continue
        n0 = lo + int(ok[0])
        s = n0 + int(np.flatnonzero(e2[n0 : n0 + ONSET_W] > thr)[0])
        if not out or s > out[-1][0] + ONSET_W:
            out.append((s, float(jumps[i])))
        else:       # the lead-in's run found the hit's own onset (its level is the next block's), or one a few samples on: one hit, the bigger jump
            out[-1] = (min(s, out[-1][0]), max(out[-1][1], float(jumps[i])))
    return out


def shared_onsets(own, ref_ons, share=ONSET_SHARE):
    """The mid's onsets, plus this channel's own where the mid has none at or
    up to ONSET_SHARE before it (a mid onset that stands for one takes the
    bigger jump). Mid and side then put a shared hit on one grid, and an own
    onset earlier than the mid's still starts its own layer, so no noise
    lands before it."""
    out = {s: j for s, j in ref_ons}
    r = np.array([s for s, _ in ref_ons], dtype=np.int64)
    for s, j in own:
        m = np.flatnonzero((r <= s) & (r >= s - share))
        if len(m):
            k = int(r[m[-1]])
            out[k] = max(out[k], j)
        else:
            out[s] = max(out.get(s, j), j)
    return sorted(out.items())


def _first_nonzero(e, w=None, start=0, chunk=8192):
    """Index of the first nonzero of e (or of e * w) at or after `start`, or -1
    (scans in chunks: stops at the first without a pass over the rest)."""
    for lo in range(start, len(e), chunk):
        seg = e[lo : lo + chunk] if w is None else e[lo : lo + chunk] * w[lo : lo + chunk]
        nz = np.flatnonzero(seg)
        if len(nz):
            return lo + int(nz[0])
    return -1


def plan(e: np.ndarray, ref: np.ndarray, heard=()):
    """heard: the channels a mid/side pair is heard as (left, right), whose
    clean hits it also takes, each on a layer of its own: one channel's hit
    a few ms after the other's (or under its steady sound) is no hit of mid
    or side's own, and a layer over both puts noise sized to the louder
    channel in the silent one before its hit (Marimba, 11.6 dB)."""
    n = len(e)
    nz = [_first_nonzero(e)]
    if nz[0] < 0:
        return []
    top = pc.block_db(ref, BLOCK).max() if len(ref) >= BLOCK else 0.0
    ref_ons = onsets(ref, top, gaps=False)
    for h in heard:         # only clean hits: a short cover over the others bought nothing (A0v1: +3.6 % bytes, b10 -0.6)
        ref_ons = shared_onsets([o for o in onsets(h, top, gaps=False) if o[1] >= CLEAN_DB], ref_ons, HEARD_SHARE)
    hits = shared_onsets(onsets(e, top), ref_ons)
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
        live = _first_nonzero(e, w, a)
        if live >= 0:            # skip whole frames of nothing, staying on the grid from `a`
            out.append((M, w, a + (live - a) // M * M))
    return out

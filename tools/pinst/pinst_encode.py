"""The one encoder (ONE_STANDARD_PLAN.md, stage 2).

Every note, every instrument, one path:

1. Partials and band noise as before (one setting, STANDARD), no attack
   envelope.
2. The need map (need_map.py) marks the band-frames where that plain model is
   audibly wrong.
3. The noise is muted on those band-frames, and the rest of the note (source
   minus partials minus the noise that is left) is kept on them, a band-frame
   either side included, so a coded band-frame meets the noise around it
   without a gap.
4. That residual is coded as MDCT layers: short blocks (128) around each
   transient found in it, long blocks (1024) everywhere else. The transients
   are found per 128-sample block, any number of them, or none.

A layer stores only the bands that carry something, so a note whose map is
empty costs what its partials and noise cost and nothing more.

Every constant is one value for every instrument (the plan's rule for
constants).
"""
from __future__ import annotations

import numpy as np
from scipy.ndimage import binary_dilation

import need_map as nm
import pinst_codec as pc

STANDARD = nm.MODEL         # the plain model is the standard's partials and noise
SNR_DB = 18.0               # coded residual: signal to quantization noise per band
LAYER_BANDS = 18
SHORT_M, LONG_M = 128, 1024
FLOOR_DB = -80.0            # a layer band this far under the source's loudest is not coded
TRANSIENT_DB = 12.0         # a 128-sample block this far over the 8 before it
TRANSIENT_PRE, TRANSIENT_POST, TRANSIENT_RAMP = 256, 2048, 1024
BLOCK = 128


def noise_mute(need, frames):
    """(noise frames, bands): a noise row is muted in a band when the map
    needs that band anywhere inside the row's 512-sample hop around it."""
    NH = pc.NOISE_N // 2
    r = NH // nm.HOP
    pad = np.zeros((frames * r + r, need.shape[1]), bool)
    k = min(len(need), frames * r - r // 2)
    pad[r // 2 : r // 2 + k] = need[:k]       # frame j covers need rows 4j-2 .. 4j+1
    return pad[: frames * r].reshape(frames, r, -1).any(axis=1)


def cover_rows(mute):
    """(need-map rows, bands): where the residual has to stand in for the
    noise. A muted noise frame takes its noise out over its whole window
    (NOISE_N samples around it), and a band either side is included, so a
    coded band-frame meets the noise around it without a gap."""
    r = (pc.NOISE_N // 2) // nm.HOP
    up = np.repeat(mute, r, axis=0)
    up = np.concatenate([up[r // 2 :], np.zeros((r // 2, up.shape[1]), bool)])   # row k belongs to frame round(k / r)
    return binary_dilation(up, np.ones((r + 1, 3), bool))       # owned rows +-r/2 = the window's +-r


def layer_allow(cover, edges, M, nbands, frames):
    """(layer frames, layer bands): a layer band-frame may carry the residual
    where it overlaps a covered need-map cell. Layer frame f spans samples
    f * M - M / 2 .. f * M + 3M / 2 (pc.layer_windows)."""
    lb = pc.layer_bands_hz(M, nbands)
    over = (edges[:-1, None] < lb[None, 1:]) & (edges[1:, None] > lb[None, :-1])     # (ERB bands, layer bands)
    a = (cover.astype(float) @ over.astype(float)) > 0
    cs = np.concatenate([np.zeros((1, a.shape[1])), np.cumsum(a, axis=0)])
    f = np.arange(frames)
    lo = np.clip((f * M - M // 2) // nm.HOP, 0, len(a))
    hi = np.clip((f * M + 3 * M // 2 + nm.HOP - 1) // nm.HOP, 0, len(a))
    return (cs[hi] - cs[lo]) > 0


def transients(e, top_db):
    """Sample positions where e's 128-sample block level jumps TRANSIENT_DB
    over the mean of the 8 blocks before it (silence before the note counts)
    and is audible: within the need map's range of top_db."""
    m = len(e) // BLOCK
    p = (e[: m * BLOCK].reshape(m, BLOCK) ** 2).mean(1)
    pp = np.concatenate([np.zeros(8), p])
    prev = np.convolve(pp, np.ones(8) / 8, mode="valid")[:m]
    db = 10 * np.log10(p + 1e-30)
    hit = (db > 10 * np.log10(prev + 1e-30) + TRANSIENT_DB) & (db > top_db + nm.AUDIBLE_DB)
    return np.flatnonzero(hit) * BLOCK


def short_window(n, ts):
    """1 around each transient (TRANSIENT_PRE before, TRANSIENT_POST after),
    raised-cosine ramps of TRANSIENT_RAMP either side, 0 elsewhere."""
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


def encode_channel(x, pitched, f0, seed, ref=None, snr=SNR_DB):
    """x: one channel (mid or side). ref: the mid, which sets what is audible
    and every floor (a side is judged by how loud the note is). Returns the
    decoded Channel (render() plays it) and its info for the file."""
    ref = x if ref is None else ref
    n = len(x)
    ch = pc.analyse(x, pitched, f0, STANDARD)
    ch.tns = None
    dec, _ = pc.quantize(ch, STANDARD)
    det = pc.synth_tracks(dec.tracks, n, ch.H, mode="integrate", anchors=dec.info["anchors"], gate_from=0)
    edges = pc.erb_edges(STANDARD.noise_bands)
    noises = [pc.hash_noise(dec.noise_db, n, edges, s) for s in nm.SEEDS]
    ref_px = None
    if ref is not x:
        ref_px = nm.band_stats([ref], pc.SR, edges)[0].max()
    r = nm.need_map(x, det, noises, pc.SR, ref=ref_px)
    mute = noise_mute(r["need"], len(ch.noise_db))
    # A transient is past what 1024-sample noise frames can follow, in every
    # band: the frames around it go silent and the short blocks carry all of
    # it. The noise comes back on its own window ramp, so it never starts
    # with a step (out of silence, a step is a click in every band).
    ts = transients(x - det, pc.block_db(ref, BLOCK).max())
    NH = pc.NOISE_N // 2
    for t in ts:
        mute[max(0, (t - TRANSIENT_PRE) // NH) : (t + TRANSIENT_POST) // NH + 1] = True
    nd = ch.noise_db.copy()
    nd[mute] = -200.0
    nstream, dec.noise_db = pc.quantize_noise(nd, STANDARD)
    dec.info["streams"]["noise"] = nstream
    nz = pc.hash_noise(dec.noise_db, n, edges, seed)
    layers, lay_info = [], []
    if mute.any():
        cover = cover_rows(mute)
        e = x - det - nz
        ws = short_window(n, ts)
        for M, w in ((SHORT_M, ws), (LONG_M, 1 - ws)):
            if not w.any():
                continue
            floor = pc.band_power_db(pc.mdct_frames(ref, M), LAYER_BANDS).max() + FLOOR_DB
            allow = layer_allow(cover, edges, M, LAYER_BANDS, pc.layer_frames(n, M))
            y, lay = pc.layer_code(e * w, M, LAYER_BANDS, snr, floor, seed + 1 + len(layers), allow)
            if lay["live"] == 0:
                continue
            layers.append(y)
            lay_info.append(lay)
        dec.info["transients"] = [int(t) for t in ts]
    dec.tns = None
    dec.layers = layers
    dec.seed = seed
    dec.info["layers"] = lay_info
    dec.info["need_pct"] = round(100 * float(r["need"].sum()) / max(1, int(r["audible"].sum())), 2)
    dec.info["mute_pct"] = round(100 * float(mute.mean()), 2)
    return dec


SIDE_DB = -40.0     # a side this far under the mid is silence


def channels_of(x):
    """x: (n, 1 or 2) -> the signals coded: [mono] or [mid, side]."""
    if x.shape[1] == 1:
        return [x[:, 0]]
    M, S = 0.5 * (x[:, 0] + x[:, 1]), 0.5 * (x[:, 0] - x[:, 1])
    side_db = 20 * np.log10(np.sqrt((S**2).mean()) / max(np.sqrt((M**2).mean()), 1e-12) + 1e-12)
    return [M, S if side_db >= SIDE_DB else np.zeros_like(S)]


def encode_note(x, f0, snr=SNR_DB):
    """x: (n, 1 or 2) at pc.SR. f0: Hz or None (unpitched).
    Returns (decoded Channels, offline render shaped like x)."""
    sigs = channels_of(x)
    chans, ys = [], []
    for i, sig in enumerate(sigs):
        live = bool(np.any(sig))
        dec = encode_channel(sig, live and f0 is not None, f0 if live else None, 7 + 100 * i,
                             ref=sigs[0] if i else None, snr=snr)
        chans.append(dec)
        ys.append(pc.render(dec, STANDARD))
    y = ys[0][:, None] if len(ys) == 1 else np.stack([ys[0] + ys[1], ys[0] - ys[1]], axis=1)
    return chans, y

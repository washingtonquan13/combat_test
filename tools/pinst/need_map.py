"""Where a note needs a coded residual: the need map.

The plain model is the note's partials plus band noise, as the decoder plays
them, with no residual layer and no attack envelope. The map compares it with
the source band by band (the noise model's 40 ERB bands) and frame by frame
(HOP samples), and marks the band-frames where the model is audibly wrong:

- level: the model's band level is more than LEVEL_DB over or under the
  source's. Noise that cannot follow an attack shows here, as does a partial
  that starts late or a band the noise model left empty.
- tone: the source's band has a peak the model's does not (or the other way
  round) by more than TONE_DB, measured as peak bin over mean bin. A tone the
  partials missed, rendered as noise at the right level, shows here.

and only where the band-frame is audible: within AUDIBLE_DB of the note's
loudest band-frame.

Each band is measured with the shortest window that still gives it MIN_BINS
bins, so high bands get a fine time grid and low bands enough frequency
resolution, and its power is averaged over one window length. With both, a
source that is the model itself with another noise draw marks 0.1-2.5% of
its band-frames, where real failures mark 40-55%. The model's noise is drawn
with several seeds and averaged, so the comparison is against what the model
is, not one draw of it.

Nothing here knows the instrument. Every constant is one value for all of
them (ONE_STANDARD_PLAN.md, rule for constants).
"""
from __future__ import annotations

import hashlib

import numpy as np
from scipy import fft as sfft
from scipy.ndimage import uniform_filter1d

import pinst_codec as pc

HOP = 128
WINDOWS = (256, 512, 1024, 2048, 4096)
MIN_BINS = 16
LEVEL_DB = 6.0
TONE_DB = 8.0
AUDIBLE_DB = -60.0
SEEDS = (7, 8, 9, 10)
FRAME_BLOCK = 128

# The partial and noise settings of the plain model.
MODEL = pc.Tier("model", f_cents=0.5, f_tol=1)


def plain_model(x, pitched, f0, seeds=SEEDS):
    """(partials as decoded, [noise as decoded, one per seed], decoded Channel)."""
    ch = pc.analyse(x, pitched, f0, MODEL)
    dec, _ = pc.quantize(ch, MODEL)
    det = pc.synth_tracks(dec.tracks, ch.n, ch.H, mode="integrate", anchors=dec.info["anchors"], gate_from=0)
    edges = pc.erb_edges(MODEL.noise_bands)
    noises = [pc.hash_noise(dec.noise_db, ch.n, edges, s) for s in seeds]
    return det, noises, dec


def _frames(x, N, kmax=None):
    """Power spectra of N-sample Hann windows centred on every HOP-th sample,
    bins below kmax (default all). Done FRAME_BLOCK frames at a time: the
    whole note's windowed frames at once do not fit in cache (a long note's
    are hundreds of MB), and only a band's bins are wanted."""
    F = int(np.ceil(len(x) / HOP))
    xp = np.zeros(F * HOP + N)
    xp[N // 2 : N // 2 + len(x)] = x
    w = np.hanning(N + 1)[:-1]
    fr = np.lib.stride_tricks.sliding_window_view(xp, N)[::HOP][:F]
    k = N // 2 + 1 if kmax is None else min(int(kmax), N // 2 + 1)
    out = np.empty((F, k))
    for i in range(0, F, FRAME_BLOCK):
        out[i : i + FRAME_BLOCK] = np.abs(sfft.rfft(fr[i : i + FRAME_BLOCK] * w, axis=1)[:, :k]) ** 2
    return out


def _plan(sr, edges):
    """For each band: (window, first bin, last bin + 1)."""
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        for N in WINDOWS:
            a, b = int(np.ceil(lo * N / sr)), int(np.ceil(hi * N / sr))
            if b - a >= MIN_BINS or N == WINDOWS[-1]:
                out.append((N, a, max(b, a + 1)))
                break
    return out


def band_stats(sigs, sr, edges):
    """Band power and peakiness (dB) per frame, averaged over the signals."""
    plan = _plan(sr, edges)
    F = int(np.ceil(len(sigs[0]) / HOP))
    P = np.zeros((F, len(plan)))
    K = np.zeros((F, len(plan)))
    for N in sorted({p[0] for p in plan}):
        kmax = max(e for n, a, e in plan if n == N)
        for s in sigs:
            S = _frames(s, N, kmax)
            for b, (n, a, e) in enumerate(plan):
                if n == N:
                    seg = S[:, a:e]
                    # power over one window length: one draw of a noisy band
                    # varies too much frame to frame to judge on its own.
                    # The running mean can come out a hair under zero.
                    sm = uniform_filter1d(seg.sum(1), max(1, N // HOP), mode="nearest")
                    P[:, b] += np.maximum(sm, 0.0) / len(sigs)
                    K[:, b] += (seg.max(1) / (seg.mean(1) + 1e-30)) / len(sigs)
    return 10 * np.log10(P + 1e-30), 10 * np.log10(K + 1e-30)


def source_key(x, sr, edges, what):
    """A key for a value measured on one signal: the encoder measures the
    same source on every card run."""
    x = np.ascontiguousarray(x, dtype=float)
    return (what, len(x), sr, np.asarray(edges, float).tobytes(),
            hashlib.blake2b(x.tobytes(), digest_size=16).digest())


def memo(store, key_parts, make, size=64):
    """make() once per inputs: key_parts are arrays (hashed by their bytes)
    and plain values. For a judge that meets the same candidate twice."""
    h = hashlib.blake2b(digest_size=16)
    for p in key_parts:
        if isinstance(p, np.ndarray):
            h.update(np.ascontiguousarray(p).tobytes()); h.update(str((p.dtype, p.shape)).encode())
        else:
            h.update(repr(p).encode())
        h.update(b"|")
    k = h.digest()
    if k not in store:
        if len(store) >= size:
            store.clear()
        store[k] = make()
    return store[k]


_SRC = {}


def cached(key, make):
    """make() once per key (a few sources and grids at a time)."""
    if key not in _SRC:
        if len(_SRC) >= 32:
            _SRC.clear()
        v = make()
        for a in (v if isinstance(v, tuple) else (v,)):
            a.flags.writeable = False
        _SRC[key] = v
    return _SRC[key]


def source_stats(x, sr, edges):
    """band_stats([x]), kept per source: read-only, do not write into it."""
    return cached(source_key(x, sr, edges, "band_stats"), lambda: band_stats([x], sr, edges))


def need_map(x, det, noises, sr=None, ref=None, edges=None):
    """x: the source channel. det, noises: the plain model (plain_model()).
    ref: the dB that audible is measured from (default: x's loudest
    band-frame); a side channel passes the mid's, so a quiet side is judged
    by how loud the note is, not by itself. edges: the band grid (default
    the model's ERB bands).
    Returns a dict of (frames, bands) arrays: need (bool), level (model over
    source, dB), tone (source peakiness over model's, dB), audible (bool),
    and the band edges."""
    sr = sr or pc.SR
    if edges is None:
        edges = pc.erb_edges(MODEL.noise_bands)
    px, kx = source_stats(x, sr, edges)
    py, ky = band_stats([det + nz for nz in noises], sr, edges)
    level = py - px
    tone = kx - ky
    audible = np.maximum(px, py) > (px.max() if ref is None else ref) + AUDIBLE_DB
    need = audible & ((np.abs(level) > LEVEL_DB) | (np.abs(tone) > TONE_DB))
    return {"need": need, "level": level, "tone": tone, "audible": audible, "edges": edges, "px": px}

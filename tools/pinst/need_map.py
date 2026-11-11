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

import numpy as np
from scipy.ndimage import uniform_filter1d

import pinst_codec as pc

HOP = 128
WINDOWS = (256, 512, 1024, 2048, 4096)
MIN_BINS = 16
LEVEL_DB = 6.0
TONE_DB = 8.0
AUDIBLE_DB = -60.0
SEEDS = (7, 8, 9, 10)

# The partial and noise settings of the plain model.
MODEL = pc.Tier("model", f_cents=0.5, f_tol=1)


def plain_model(x, pitched, f0, seeds=SEEDS):
    """(partials as decoded, [noise as decoded, one per seed], decoded Channel)."""
    ch = pc.analyse(x, pitched, f0, MODEL)
    dec, _ = pc.quantize(ch, MODEL)
    det = pc.synth_tracks(dec.tracks, ch.n, ch.H, mode="integrate", anchors=dec.info["anchors"], gate_from=0)
    edges = pc.erb_edges(MODEL.noise_bands)
    noises = [pc.synth_noise(dec.noise_db, dec.noise_H, ch.n, edges, seed=s) for s in seeds]
    return det, noises, dec


def _frames(x, N):
    """Power spectra of N-sample Hann windows centred on every HOP-th sample."""
    F = int(np.ceil(len(x) / HOP))
    xp = np.zeros(F * HOP + N)
    xp[N // 2 : N // 2 + len(x)] = x
    w = np.hanning(N + 1)[:-1]
    fr = np.lib.stride_tricks.sliding_window_view(xp, N)[::HOP][:F]
    return np.abs(np.fft.rfft(fr * w, axis=1)) ** 2


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
        for s in sigs:
            S = _frames(s, N)
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


def need_map(x, det, noises, sr=None):
    """x: the source channel. det, noises: the plain model (plain_model()).
    Returns a dict of (frames, bands) arrays: need (bool), level (model over
    source, dB), tone (source peakiness over model's, dB), audible (bool),
    and the band edges."""
    sr = sr or pc.SR
    edges = pc.erb_edges(MODEL.noise_bands)
    px, kx = band_stats([x], sr, edges)
    py, ky = band_stats([det + nz for nz in noises], sr, edges)
    level = py - px
    tone = kx - ky
    audible = np.maximum(px, py) > px.max() + AUDIBLE_DB
    need = audible & ((np.abs(level) > LEVEL_DB) | (np.abs(tone) > TONE_DB))
    return {"need": need, "level": level, "tone": tone, "audible": audible, "edges": edges, "px": px}

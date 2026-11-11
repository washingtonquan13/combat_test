"""The report card (SMS_PLAN.md stage 1): per band and 128-sample frame,
does the generators' output sound like the source, and if not, which kind
of miss is it.

Measures, per audible band-frame (need_map.py's 40 ERB bands, HOP frames):

- level: the output's band power over the band's analysis window is more
  than LEVEL_DB off the source's (need_map.py). The window is long (512 to
  4096 samples) so that a noise band can be judged at all.
- tone: one side has a spectral peak in the band the other lacks, by more
  than TONE_DB (need_map.py). By sign: a tone the source has and the output
  lacks (tone), or an output tone the source lacks (tone_extra).
- fine level: the band's Hilbert-envelope power, averaged over a window of
  FINE_CYCLES / bandwidth (at least 2 HOP, at most the analysis window),
  source over output. This is what a noise envelope must follow, at the
  finest time the band's width allows a noise level to be known.

Kinds, one per missing band-frame, first match wins:

- tone, tone_extra.
- det_over: the output is too loud and the deterministic generators are the
  cause: det plus noise at the power of what they left is over the source,
  so det and what is left are anti-correlated (det is wrong, and the noise
  adds its error back as power).
- level: the long-window level is off for any other reason.
- envelope: the long-window level is right but the fine level is off by
  more than ENV_DB: the timing inside the window is wrong.

Nothing here knows the instrument. Every constant is one value for all of
them, set against a calibration source (the output itself with another
noise draw), which should miss almost nowhere.
"""
from __future__ import annotations

import numpy as np
from scipy import fft as sfft
from scipy.ndimage import uniform_filter1d

import need_map as nm
import pinst_codec as pc

HOP = nm.HOP
ENV_DB = 10.0
FINE_CYCLES = 8.0

KINDS = ("tone", "tone_extra", "det_over", "level", "envelope")


def _bands(x, sr, edges, L):
    """Yield (band, analytic band signal) for each band (brick-wall in one FFT)."""
    X = sfft.rfft(x, L, workers=-1)
    f = sfft.rfftfreq(L, 1 / sr)
    n = len(x)
    for b, (lo, hi) in enumerate(zip(edges[:-1], edges[1:])):
        a, e = np.searchsorted(f, lo), np.searchsorted(f, hi)
        e = max(e, a + 1)
        Z = np.zeros(L, np.complex128)
        Z[a:e] = 2 * X[a:e]
        yield b, sfft.ifft(Z, workers=-1)[:n]


def _L(n, sr, edges):
    return sfft.next_fast_len(n + 2 * max(p[0] for p in nm._plan(sr, edges)))


def fine_windows(sr, edges):
    plan = nm._plan(sr, edges)
    bw = np.diff(edges)
    return [int(np.clip(FINE_CYCLES * sr / bw[b], 2 * HOP, plan[b][0])) for b in range(len(bw))]


def fine_power(sigs, sr, edges):
    """(frames, bands) band power in dB at the fine windows, mean over sigs."""
    n = len(sigs[0])
    F = int(np.ceil(n / HOP))
    T = fine_windows(sr, edges)
    L = _L(n, sr, edges)
    i = np.minimum(np.arange(F) * HOP, n - 1)
    out = np.zeros((F, len(T)))
    for s in sigs:
        for b, a in _bands(s, sr, edges, L):
            sm = uniform_filter1d(np.abs(a) ** 2, T[b], mode="constant")
            out[:, b] += np.maximum(sm[i], 0.0) / len(sigs)
    return 10 * np.log10(out + 1e-30)


def card(x, det, noises, sr, ref=None):
    """x: the source channel. det: the deterministic generators' sum. noises:
    the random generators' output, one per seed. ref: band dB that audible is
    measured from (the mid's for a side). Returns a dict: kind (frames, bands)
    int, -1 where no miss, else an index into KINDS; audible; the measures."""
    edges = pc.erb_edges(nm.MODEL.noise_bands)
    r = nm.need_map(x, det, noises, sr, ref=ref)
    aud = r["audible"]
    fine = fine_power([x], sr, edges) - fine_power([det + nz for nz in noises], sr, edges)
    pd, _ = nm.band_stats([det], sr, edges)
    tone_m = aud & (r["tone"] > nm.TONE_DB)
    tone_x = aud & (r["tone"] < -nm.TONE_DB)
    lvl = aud & (np.abs(r["level"]) > nm.LEVEL_DB)
    pl, _ = nm.band_stats([x - det], sr, edges)
    # x = det + left, so px = pd + pl + 2 cross. The output is det plus noise
    # at left's power: pd + pl. Where that is over px, det and left are
    # anti-correlated: the deterministic part is wrong and the noise puts its
    # error back as power.
    both = 10 * np.log10(10 ** (pd / 10) + 10 ** (pl / 10))
    det_over = lvl & (r["level"] > 0) & (both > r["px"] + nm.LEVEL_DB / 2)
    env = aud & (np.abs(fine) > ENV_DB)
    kind = np.full(aud.shape, -1)
    for k, m in reversed(list(enumerate((tone_m, tone_x, det_over, lvl, env)))):
        kind[m] = k
    return {"kind": kind, "audible": aud, "level": r["level"], "tone": r["tone"], "fine": fine,
            "edges": edges, "px": r["px"]}


def summary(c, onset, sr):
    """Shares (% of audible band-frames) by kind, overall and by region:
    attack = the 50 ms from the onset; low < 300 Hz, high > 4 kHz."""
    k, aud = c["kind"], c["audible"]
    e = c["edges"]
    cen = np.sqrt(e[:-1] * e[1:])
    F = k.shape[0]
    a0 = onset // HOP
    att = np.zeros(F, bool)
    att[a0 : a0 + int(0.05 * sr) // HOP + 1] = True
    full = np.ones_like(aud)
    regions = {"all": full, "attack": att[:, None] & full, "body": ~att[:, None] & full,
               "low": full & (cen < 300)[None, :], "high": full & (cen > 4000)[None, :]}
    out = {}
    for name, reg in regions.items():
        A = aud & reg
        tot = max(1, int(A.sum()))
        out[name] = {kn: round(100 * float(((k == i) & A).sum()) / tot, 2) for i, kn in enumerate(KINDS)}
        out[name]["miss"] = round(100 * float(((k >= 0) & A).sum()) / tot, 2)
    return out

"""Generator 1: partials that follow pitch (SMS_PLAN.md stage 3).

Two analyses of `left`, and the one that explains it better is kept:

- free: peaks picked with a window per frequency band (long in low bands,
  short in high ones) and tracked frame to frame (PINST3's tracker).
- locked: the pitch is estimated from the audio frame by frame (YIN), the
  harmonics' stretch is fitted to the peaks, and each harmonic is measured
  along the pitch's own phase with a window a few periods long, so it
  follows slides and hammer-ons and starts at the onset. The free analysis
  then runs on what the harmonics leave.

Harmonic lock is the fit: the locked analysis is kept when it leaves less
than the free one by LOCK_DB. The file name's pitch is not used; YIN's
octave slips are corrected per frame from the peaks (octave_fix).

The coded streams are PINST3's (hdr, dt, df, da, f0), with the f0 track
taken from the audio pitch instead of re-estimated from the tracks.

Nothing here names a kind of sound. Every constant is one value for all
instruments (SMS_PLAN.md, rule for constants).
"""
from __future__ import annotations

import numpy as np
from scipy.ndimage import median_filter, uniform_filter1d

import need_map as nm
import pinst_codec as pc

RANDOM = False
TIER = nm.MODEL

H = 256                    # frame hop, as PINST3 (the synth's frame)
# free analysis: window per band, (from Hz, N). Low bands keep the long
# window's resolution; high bands get a short one so attacks are followed.
BANDS = ((0.0, 4096), (500.0, 2048), (2000.0, 1024), (6000.0, 512))
# pitch (YIN)
FMIN, FMAX = 30.0, 2000.0
YIN_W = 2048               # integration window
YIN_THR = 0.2              # CMNDF dip that counts as periodic
VOICED_DB = -50.0          # frames this far under the loudest are not used for pitch
# harmonic analysis
PERIODS = 4.0              # demodulation window, pitch periods (Blackman-Harris: neighbours at its nulls)
MAX_L = 8192
MATCH = 0.2                # a peak belongs to harmonic h within this fraction of f0
GAP = 3                    # presence gaps this short (frames) are closed
MIN_RUN = 5                # and runs shorter than this dropped (the tracker's min_len)
PH_SMOOTH = 9              # frames the phase offset from the pitch is smoothed over
OCT_K = (0.5, 1.0, 2.0, 3.0, 4.0)   # octave slips of the YIN pitch that are tried
OCT_TOL = 0.05             # a peak is on a harmonic within this fraction of the pitch
OCT_H = 16                 # peaks below this many YIN periods' harmonic are scored
OCT_SPAN = 1               # frames the octave fit is pooled over (pooling k across frames mixes base octaves)
OCT_FRAC = 0.01          # share of the scored peak power a lower pitch must explain more
LOCK_DB = 1.0             # the locked analysis must leave this much less (dB) to be kept


# ------------------------------------------------------------------ pitch

def yin(x, sr):
    """Per frame (centred at i*H): f0 (Hz), aperiodicity (CMNDF at the dip),
    frame energy (dB)."""
    n = len(x)
    F = 1 + n // H
    tmax = int(np.ceil(sr / FMIN))
    tmin = max(2, int(sr / FMAX))
    W = YIN_W
    Nf = 1 << int(np.ceil(np.log2(W + tmax + 1)))
    xp = np.concatenate([np.zeros(W // 2), x, np.zeros(W + tmax + H)])
    f0 = np.zeros(F)
    ap = np.ones(F)
    en = np.full(F, -300.0)
    taus = np.arange(tmax + 1)
    for a in range(0, F, 256):
        idx = np.arange(a, min(F, a + 256))
        seg = xp[idx[:, None] * H + np.arange(W + tmax + 1)[None, :]]
        A = np.fft.rfft(seg[:, :W], Nf, axis=1)
        B = np.fft.rfft(seg, Nf, axis=1)
        r = np.fft.irfft(np.conj(A) * B, Nf, axis=1)[:, : tmax + 1]
        c2 = np.concatenate([np.zeros((len(idx), 1)), np.cumsum(seg**2, axis=1)], axis=1)
        e0 = c2[:, W]
        et = c2[:, taus + W] - c2[:, taus]
        d = np.maximum(e0[:, None] + et - 2 * r, 0.0)
        cs = np.cumsum(d[:, 1:], axis=1)
        dn = np.ones_like(d)
        dn[:, 1:] = d[:, 1:] * np.arange(1, tmax + 1)[None, :] / np.maximum(cs, 1e-30)
        dn[:, :tmin] = 2.0
        below = dn < YIN_THR
        rising = np.zeros_like(below)
        rising[:, :-1] = dn[:, 1:] > dn[:, :-1]
        has = below.any(axis=1)
        first = np.argmax(below, axis=1)
        after = rising & (np.arange(tmax + 1)[None, :] >= first[:, None])
        loc = np.where(has, np.argmax(after, axis=1), np.argmin(dn, axis=1))
        loc = np.clip(loc, tmin, tmax - 1)
        rr = np.arange(len(idx))
        y0, y1, y2 = dn[rr, loc - 1], dn[rr, loc], dn[rr, loc + 1]
        den = y0 - 2 * y1 + y2
        p = np.where(np.abs(den) > 1e-12, 0.5 * (y0 - y2) / den, 0.0)
        p = np.clip(p, -1, 1)
        f0[idx] = sr / (loc + p)
        ap[idx] = np.clip(y1 - 0.25 * (y0 - y2) * p, 0, 2)
        en[idx] = 10 * np.log10(e0 / W + 1e-30)
    return f0, ap, en


def octave_fix(f0, voiced, peaks):
    """YIN's octave slips (it can flip between a pitch and its octave within
    one note), decided by fit, per frame: the peak power left unexplained by
    the harmonics of k*f0 for each k in OCT_K, pooled over OCT_SPAN frames.
    A lower pitch's harmonics include a higher one's, so it always explains
    at least as much; the highest k that explains within OCT_FRAC of the
    scored power as much as the best is kept (a lower pitch has to earn its
    extra harmonics, and noise peaks between them do not).
    Returns the corrected f0 and the median factor over voiced frames."""
    F = len(f0)
    R = np.zeros((len(OCT_K), F))
    T = np.zeros(F)
    for i in np.flatnonzero(voiced):
        if i >= len(peaks):
            break
        f, a = peaks[i][0], peaks[i][1]
        m = f < OCT_H * f0[i]
        f, p = f[m], 10.0 ** (a[m] / 10.0)
        if not len(f):
            continue
        T[i] = p.sum()
        for j, k in enumerate(OCT_K):
            g = k * f0[i]
            h = np.round(f / g)
            R[j, i] = p[~((h >= 1) & (np.abs(f - h * g) < OCT_TOL * g))].sum()
    R = uniform_filter1d(R, size=OCT_SPAN, axis=1, mode="nearest")
    T = uniform_filter1d(T, size=OCT_SPAN, mode="nearest")
    ks = np.array(OCT_K)
    ok = R <= R.min(axis=0, keepdims=True) + OCT_FRAC * T[None, :]
    kf = np.where(T > 0, np.max(np.where(ok, ks[:, None], 0.0), axis=0), 1.0)
    vi = np.flatnonzero(voiced)
    return f0 * kf, float(np.median(kf[vi])) if len(vi) else 1.0


def pitch_track(x, sr, peaks):
    """Smoothed f0 per frame and the voiced mask. Unvoiced frames take the
    nearest voiced pitch."""
    f0, ap, en = yin(x, sr)
    voiced = (ap < YIN_THR) & (en > en.max() + VOICED_DB)
    if voiced.sum() < MIN_RUN:
        return None, voiced, 1.0
    f0, k = octave_fix(f0, voiced, peaks)
    lg = np.log2(f0)
    vi = np.flatnonzero(voiced)
    # median over voiced frames only (frame-wise slips), then fill the rest
    lv = median_filter(lg[vi], size=5, mode="nearest")
    lg = np.interp(np.arange(len(f0)), vi, lv)
    return 2.0**lg, voiced, k


# ---------------------------------------------------------- free analysis

def band_peaks(x, sr, on):
    """Peaks per frame, each band from its own window, gated so no window
    mostly precedes the hit."""
    pc.SR = sr
    out = None
    for b, (lo, N) in enumerate(BANDS):
        hi = BANDS[b + 1][0] if b + 1 < len(BANDS) else sr / 2
        fr = pc.find_peaks_frames(x, N, H)
        first = int(np.ceil((on + N // 4) / H))
        if out is None:
            out = [[[], [], []] for _ in fr]
        for i, (f, a, ph) in enumerate(fr):
            if i < first:
                continue
            m = (f >= lo) & (f < hi)
            out[i][0].append(f[m]); out[i][1].append(a[m]); out[i][2].append(ph[m])
    return [tuple(np.concatenate(c) if c else np.zeros(0) for c in fr) for fr in out]


def free_tracks(x, sr, on):
    peaks = band_peaks(x, sr, on)
    return pc.track_peaks(peaks), peaks


# ------------------------------------------------------- locked analysis

def stretch_fit(peaks, f0, voiced, sr):
    """(a, b) with harmonic h at h * f0 * sqrt(a + b h^2), fitted to the
    peaks of voiced frames; and the highest harmonic seen."""
    a, b = 1.0, 0.0
    kmax = 1
    for it in range(4):
        hs, rs = [], []
        for i in np.flatnonzero(voiced):
            f = peaks[i][0]
            if not len(f):
                continue
            g = f0[i]
            hh = np.maximum(1, np.round(f / g))
            # undo the stretch to find the harmonic number
            for _ in range(2):
                hh = np.maximum(1, np.round(f / (g * np.sqrt(np.maximum(a + b * hh**2, 0.25)))))
            pred = hh * g * np.sqrt(np.maximum(a + b * hh**2, 0.25))
            ok = np.abs(f - pred) < MATCH * g
            hs.append(hh[ok]); rs.append((f[ok] / (hh[ok] * g)) ** 2)
        if not hs:
            break
        hs, rs = np.concatenate(hs), np.concatenate(rs)
        if len(hs) < 8:
            break
        kmax = int(hs.max())
        if len(np.unique(hs)) >= 3:
            A = np.stack([np.ones_like(hs), hs**2], axis=1)
            sol, *_ = np.linalg.lstsq(A, rs, rcond=None)
            a, b = float(sol[0]), float(max(sol[1], 0.0))
    return a, b, kmax


def presence(peaks, f0, voiced, a, b, kmax, F):
    """P[h-1, i]: a peak sits on harmonic h in frame i."""
    P = np.zeros((kmax, F), bool)
    hs = np.arange(1, kmax + 1)
    st = np.sqrt(a + b * hs**2)
    for i in range(min(F, len(peaks))):
        f = peaks[i][0]
        if not voiced[i] or not len(f):
            continue
        pred = hs * f0[i] * st
        j = np.searchsorted(pred, f)
        for jj in (np.clip(j - 1, 0, kmax - 1), np.clip(j, 0, kmax - 1)):
            ok = np.abs(f - pred[jj]) < MATCH * f0[i]
            P[jj[ok], i] = True
    return P


def runs(row):
    """(start, end) of True runs, gaps <= GAP closed, runs < MIN_RUN dropped."""
    r = row.copy()
    idx = np.flatnonzero(r)
    if not len(idx):
        return []
    gaps = np.flatnonzero(np.diff(idx) > 1)
    out = []
    s = idx[0]
    for g in gaps:
        if idx[g + 1] - idx[g] - 1 <= GAP:
            continue
        out.append((s, idx[g] + 1)); s = idx[g + 1]
    out.append((s, idx[-1] + 1))
    return [(s, e) for s, e in out if e - s >= MIN_RUN]


def demod(x, sr, f0, on, items, a, b):
    """items: [(h, start, end)]. Measures each harmonic along the pitch's
    phase with a PERIODS-period Blackman-Harris window, cut at the onset.
    Returns tracks."""
    n = len(x)
    F = len(f0)
    fs = np.interp(np.arange(n), np.arange(F) * H, f0)
    Phi = 2 * np.pi * np.concatenate([[0.0], np.cumsum(fs)])[:n] / sr
    tracks = []
    if not items:
        return tracks
    # every frame's window once, then all harmonics live in it at once
    by_frame = {}
    for k, (h, s, e) in enumerate(items):
        for i in range(s, e):
            by_frame.setdefault(i, []).append(k)
    amp = [np.zeros(e - s) for h, s, e in items]
    phs = [np.zeros(e - s) for h, s, e in items]
    hs_all = np.array([h for h, s, e in items], dtype=float)
    st_all = np.sqrt(a + b * hs_all**2)
    for i, ks in by_frame.items():
        c = i * H
        L = int(min(MAX_L, max(64, PERIODS * sr / f0[i])))
        t0, t1 = c - L // 2, c - L // 2 + L
        w = pc.get_window("blackmanharris", L, fftbins=False)
        lo, hi = max(t0, on, 0), min(t1, n)
        if hi - lo < 8:
            continue
        ww = w[lo - t0 : hi - t0]
        seg = x[lo:hi] * ww
        rel = Phi[lo:hi] - Phi[min(c, n - 1)]
        ks = np.array(ks)
        mult = (hs_all[ks] * st_all[ks])[:, None]
        # demodulating against the phase relative to the centre leaves the
        # harmonic's absolute phase at the centre in angle(z)
        z = np.exp(-1j * mult * rel[None, :]) @ seg * (2.0 / ww.sum())
        for kk, zz in zip(ks, z):
            h, s, e = items[kk]
            amp[kk][i - s] = abs(zz)
            phs[kk][i - s] = np.angle(zz)
    for k, (h, s, e) in enumerate(items):
        ab = amp[k]
        ok = ab > 0
        if ok.sum() < MIN_RUN:
            continue
        # frequency from phase: the measured phase less the pitch's own phase
        # is unwrapped and smoothed, and the frequency is the derivative of
        # the sum, so the decoder's integrated phase follows the measured one
        # without drift (a per-frame offset would integrate its noise)
        mult = h * np.sqrt(a + b * h * h)
        cs = np.minimum(np.arange(s, e) * H, n - 1)
        model = mult * Phi[cs]
        r = np.unwrap(np.angle(np.exp(1j * (phs[k] - model))))
        r = uniform_filter1d(r, size=PH_SMOOTH, mode="nearest")
        th = model + r
        dt = 2 * np.pi * H / sr
        f = np.gradient(th) / dt if len(th) > 1 else mult * f0[s:e]
        f = np.maximum(f, 1.0)
        # the smoothed phase is the track's phase, so the coder's one phase
        # (frame 0) and its steering agree with the frequencies
        tracks.append(pc.Track(int(s), f, 20 * np.log10(np.maximum(ab, 1e-10)), th % (2 * np.pi)))
    return tracks


def locked_tracks(x, sr, on, peaks, hint_f0):
    F = 1 + len(x) // H
    f0, voiced, octk = pitch_track(x, sr, peaks)
    if f0 is None:
        return [], None, {}
    a, b, kmax = stretch_fit(peaks, f0, voiced, sr)
    kmax = int(min(kmax, (0.45 * sr) // (f0.min() * np.sqrt(a + b * kmax**2))))
    if kmax < 1:
        return [], None, {}
    P = presence(peaks, f0, voiced, a, b, kmax, F)
    of = int(np.ceil(on / H))
    items = []
    back = BANDS[0][1] // 2 // H
    for h in range(1, kmax + 1):
        prev = of
        for s, e in runs(P[h - 1]):
            # the long windows see a harmonic late: it is measured from as far
            # back as the longest window reaches, never before the onset or
            # into this harmonic's previous run
            items.append((h, max(prev, s - back), min(e, F)))
            prev = e + 1
    tr = demod(x, sr, f0, on, items, a, b)
    return tr, f0, {"stretch_b": b, "kmax": kmax, "voiced": int(voiced.sum()), "oct_k": octk}


# ------------------------------------------------------------- the module

def _energy(v):
    return 10 * np.log10(float((v**2).sum()) + 1e-30)


def analyse(left, sr, hint):
    pc.SR = sr
    x = np.asarray(left, dtype=float)
    n = len(x)
    on = pc.onset_sample(x)
    free, peaks = free_tracks(x, sr, on)
    yf = pc.synth_tracks(free, n, H, mode="phase")
    lt, f0, info = locked_tracks(x, sr, on, peaks, hint.get("f0"))
    # the free side gets the same second pass the locked side does, so the
    # comparison is between pitch-following and not, not one pass and two
    rf = x - yf
    freeb, _ = free_tracks(rf, sr, on)
    rf = rf - pc.synth_tracks(freeb, n, H, mode="phase")
    free = free + freeb
    choice = {"lock": False, "tracks": free, "f0": None}
    e_free = _energy(rf)
    e_lock = None
    if lt:
        yl = pc.synth_tracks(lt, n, H, mode="phase")
        r = x - yl
        free2, _ = free_tracks(r, sr, on)
        y2 = pc.synth_tracks(free2, n, H, mode="phase")
        e_lock = _energy(r - y2)
        if e_lock < e_free - LOCK_DB:
            choice = {"lock": True, "tracks": lt + free2, "f0": f0}
    dec = quantize(choice["tracks"], choice["f0"], n, TIER)
    dec["info"].update({"lock": choice["lock"], "e_free": e_free, "e_lock": e_lock, "onset": on, **info,
                        "f0_med": None if f0 is None else float(np.median(f0))})
    return dec


def quantize(tracks, f0t, n, tier):
    """PINST3's track coder (pinst_codec.quantize), with the f0 track given."""
    if not tracks:
        return {"tracks": [], "anchors": [], "info": {"streams": {k: b"" for k in ("hdr", "dt", "df", "da", "f0")}}}
    top = max(t.a.max() for t in tracks)
    hdr, dts, dfs, das = bytearray(), [], [], []
    dec, anchors = [], []
    prev_start = 0
    fs = bytearray()
    f0q = None
    if f0t is not None:
        nfr = max(max(t.start + len(t.f) for t in tracks) + 1, len(f0t))
        f0t = np.concatenate([f0t, np.full(max(0, nfr - len(f0t)), f0t[-1])])[:nfr]
        c0 = 1200 * np.log2(f0t / 20.0)
        k0 = pc.keyframes(c0[:, None], np.array([tier.f0_cents]))
        q0 = np.round(c0[k0] / tier.f0_cents).astype(np.int64)
        fs += pc._ints(np.stack([pc._deltas(k0), pc._deltas(q0)], axis=1))
        f0q = 20.0 * 2 ** (pc.expand(k0, (q0 * tier.f0_cents).astype(float)[:, None], nfr)[:, 0] / 1200)
    for tr in sorted(tracks, key=lambda t: t.start):
        if tr.a.max() < max(top + tier.cull_db, tier.floor_db):
            continue
        if f0q is not None:
            ref = f0q[tr.start : tr.start + len(tr.f)]
            hh = max(1, int(round(np.median(tr.f / ref))))
            ref = hh * ref
        else:
            hh, ref = 0, np.full(len(tr.f), 20.0)
        cents = 1200 * np.log2(tr.f / ref)
        vals = np.stack([cents, tr.a], axis=1)
        keys = pc.keyframes(vals, np.array([tier.f_tol, tier.a_tol]))
        anchor = 0
        keys = np.union1d(keys, [anchor])
        qph = int(np.round((tr.ph[anchor] % pc.TWO_PI) / pc.TWO_PI * (1 << tier.phase_bits))) % (1 << tier.phase_bits)
        qc = pc.steer_keys(cents, ref, tr.ph, keys, int(np.searchsorted(keys, anchor)),
                           qph / (1 << tier.phase_bits) * pc.TWO_PI, H, tier.f_cents, tier.steer, tier.f_tol)
        qa = np.round(tr.a[keys] / tier.a_db).astype(np.int64)
        pc._varint(tr.start - prev_start, hdr); prev_start = tr.start
        pc._varint(len(keys), hdr)
        if f0q is not None:
            pc._varint(hh, hdr)
        pc._varint(qc[0], hdr); pc._varint(qa[0], hdr); hdr.append(qph)
        dts.append(np.diff(keys)); dfs.append(np.diff(qc)); das.append(np.diff(qa))
        L = len(tr.f)
        kv = np.stack([qc * tier.f_cents, qa * tier.a_db], axis=1).astype(float)
        full = pc.expand(keys, kv, L)
        ph = np.zeros(L)
        ph[anchor] = qph / (1 << tier.phase_bits) * pc.TWO_PI
        dec.append(pc.Track(tr.start, ref * 2 ** (full[:, 0] / 1200), full[:, 1], ph))
        anchors.append(anchor)
    dts, dfs, das = (pc._ints(np.concatenate(v)) if v else b"" for v in (dts, dfs, das))
    return {"tracks": dec, "anchors": anchors,
            "info": {"streams": {"hdr": bytes(hdr), "dt": bytes(dts), "df": bytes(dfs), "da": bytes(das), "f0": bytes(fs)},
                     "n_tracks": len(dec)}}


def render(dec, n, sr, seed=0):
    pc.SR = sr
    return pc.synth_tracks(dec["tracks"], n, H, mode="integrate", anchors=dec["anchors"], gate_from=0)


def pack(dec):
    st = dec["info"]["streams"]
    return b"".join(pc.lz_bytes(st[k]) for k in ("hdr", "dt", "df", "da", "f0"))

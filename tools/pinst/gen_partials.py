"""Generator 1: partials that follow pitch (SMS_PLAN.md stage 3).

Two analyses of `left`, and the one that explains it better is kept:

- free: peaks picked with a window per frequency band (long in low bands,
  short in high ones) and tracked frame to frame (PINST3's tracker).
- locked: the pitch is estimated from the audio frame by frame (YIN), the
  peaks say where each harmonic is present, and each harmonic is measured
  along the pitch's own phase with a window a few periods long, so it
  follows slides and hammer-ons and starts at the onset. The free analysis
  then runs on what the harmonics leave.

Harmonic lock is the fit: each side is coded and rendered, and the locked
one is kept when it leaves less than the free one by LOCK_DB; within LOCK_DB
either way, the side with fewer bytes. The file name's pitch is not used;
YIN's octave is decided once per voiced run from the peaks (octave_fix).

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
MAX_L_S = 0.186            # s, longest demodulation window (8192 samples at 44.1 kHz)
CUT_MIN_PERIODS = 1.0      # a window cut by the onset or end needs this many periods left
CUT_RCOND = 1e-6           # least-squares cutoff for the cut-window joint fit
TOP_FRAC = 0.45            # harmonics are kept below this fraction of the sample rate
GATE_FRAC = 0.25           # a band window may reach this share of its length before the onset
BACK = BANDS[0][1] // 2    # samples a run is measured back from where the peaks see it (half the longest window)
MATCH = 0.2                # a peak belongs to harmonic h within this fraction of f0
GAP = 3                    # voiced gaps this short (frames) are closed
PRES_GAP = BANDS[0][1] // H  # frames: a harmonic's peak gap shorter than the longest window is
                           # the peak picker's (bin alignment), not the sound's, and is closed
MIN_RUN = 5                # and runs shorter than this dropped (the tracker's min_len)
PH_SMOOTH = 9              # frames the phase offset from the pitch is smoothed over
PITCH_MED_S = 0.03         # s, median over voiced frames' log pitch (frame-wise slips)
# octave of a voiced run (octave_fix)
OCT_TOL = 0.05             # a peak is on a multiple of the pitch within this fraction of it
OCT_H = 16                 # peaks below this many folded YIN periods' harmonic are scored
OCT_Z = 3.0                # odd-multiple peaks must exceed chance by this many standard errors
OCT_MIN_PEAKS = 20         # scored peaks a run needs to decide its own octave
OCT_DOWN, OCT_UP = 1, 2    # octaves below / above YIN's that are tried
LOCK_DB = 1.0              # the locked analysis must leave this much less (dB) to be kept;
                           # within it either way, the cheaper side is kept


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


def _odd_evidence(fr, g):
    """Peaks on odd multiples of g (what g has that 2g lacks) less what
    chance puts there: the count at the thirds between g's multiples
    (harmonics of no octave of g), scaled to the same width. Returns
    (excess, its noise scale)."""
    u = fr / g
    m = np.round(u)
    odd = ((m % 2) == 1) & (np.abs(u - m) < OCT_TOL)
    t = u - np.floor(u)
    ctl = (np.abs(t - 1 / 3) < OCT_TOL) | (np.abs(t - 2 / 3) < OCT_TOL)
    exp = ctl.sum() / 4.0      # thirds: 2 per unit of u, odd multiples: 1 per 2
    return odd.sum() - exp, np.sqrt(exp + 1.0)


def _supported(fr, g):
    e, s = _odd_evidence(fr, g)
    return e > OCT_Z * s


def octave_fix(f0, voiced, peaks):
    """YIN's octave slips, decided once per voiced run (pooled), not per
    frame. Each frame's YIN pitch is first folded to the octave of the run's
    median, so every frame names the same pitch; then the run's octave is
    the lowest one whose odd harmonics the run's peaks (weak ones counted
    the same as strong ones) show above chance (OCT_Z). Moving up from
    YIN's octave needs the same evidence for the higher pitch and its
    absence for YIN's. A run with fewer than OCT_MIN_PEAKS scored peaks has
    no evidence either way and keeps the octave nearest the previous run's
    pitch (YIN's own if it is the first).
    Returns the corrected f0 and the number of runs moved off YIN's octave."""
    F = len(f0)
    out = f0.copy()
    lg = np.log2(np.maximum(f0, 1e-6))
    prev = None
    moved = 0
    for s, e in runs(voiced):
        idx = np.arange(s, e)
        idx = idx[voiced[idx]]
        r = float(np.median(lg[idx]))
        fold = f0[idx] * 2.0 ** np.round(r - lg[idx])    # within half an octave of 2^r
        fr = []
        for i, g in zip(idx, fold):
            if i >= len(peaks):
                continue
            f = peaks[i][0]
            f = f[f < OCT_H * g]
            fr.append(f / g)
        fr = np.concatenate(fr) if fr else np.zeros(0)   # peaks in units of each frame's folded pitch
        oc = 0
        if len(fr) >= OCT_MIN_PEAKS:
            while oc > -OCT_DOWN and 2.0 ** (r + oc - 1) >= FMIN and _supported(fr, 2.0 ** (oc - 1)):
                oc -= 1
            if oc == 0:
                while (oc < OCT_UP and 2.0 ** (r + oc + 1) <= FMAX and not _supported(fr, 2.0 ** oc)
                       and _supported(fr, 2.0 ** (oc + 1))):
                    oc += 1
        elif prev is not None:
            oc = int(np.round(prev - r))
        out[idx] = fold * 2.0 ** oc
        moved += int(oc != 0)
        prev = r + oc
    return out, moved


def pitch_track(x, sr, peaks):
    """Smoothed f0 per frame and the voiced mask. Unvoiced frames take the
    nearest voiced pitch; voiced frames in runs too short to be a note are
    not used."""
    f0, ap, en = yin(x, sr)
    voiced = (ap < YIN_THR) & (en > en.max() + VOICED_DB)
    keep = np.zeros_like(voiced)
    for s, e in runs(voiced):
        keep[s:e] = voiced[s:e]
    voiced = keep
    if voiced.sum() < MIN_RUN:
        return None, voiced, 0
    f0, moved = octave_fix(f0, voiced, peaks)
    lg = np.log2(f0)
    vi = np.flatnonzero(voiced)
    # median over voiced frames only (frame-wise slips), then fill the rest
    med = max(1, int(round(PITCH_MED_S * sr / H)) | 1)
    lv = median_filter(lg[vi], size=med, mode="nearest")
    lg = np.interp(np.arange(len(f0)), vi, lv)
    return 2.0**lg, voiced, moved


# ---------------------------------------------------------- free analysis

def band_peaks(x, sr, on):
    """Peaks per frame, each band from its own window, gated so no window
    mostly precedes the hit."""
    pc.SR = sr
    out = None
    for b, (lo, N) in enumerate(BANDS):
        hi = BANDS[b + 1][0] if b + 1 < len(BANDS) else sr / 2
        fr = pc.find_peaks_frames(x, N, H)
        first = int(np.ceil((on + GATE_FRAC * N) / H))
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

def top_harmonic(peaks, f0, voiced):
    """The highest harmonic number a voiced frame's peak sits on.

    Harmonics are at exact multiples of the pitch: a fitted stretch
    (h f0 sqrt(1 + b h^2)) was tried and left the same or more residual
    and more bytes on every pitched note; the per-harmonic phase offset
    (demod) already follows a harmonic that is a little sharp."""
    vi = np.flatnonzero(voiced[: len(peaks)])
    fr = [peaks[i][0] for i in vi]
    if not fr:
        return 1
    gs = np.concatenate([np.full(len(f), f0[i]) for i, f in zip(vi, fr)])
    fr = np.concatenate(fr)
    hh = np.maximum(1, np.round(fr / gs))
    hs = hh[np.abs(fr - hh * gs) < MATCH * gs]
    return int(hs.max()) if len(hs) >= 8 else 1


def presence(peaks, f0, voiced, kmax, F):
    """P[h-1, i]: a peak sits on harmonic h in frame i."""
    P = np.zeros((kmax, F), bool)
    hs = np.arange(1, kmax + 1)
    for i in range(min(F, len(peaks))):
        f = peaks[i][0]
        if not voiced[i] or not len(f):
            continue
        pred = hs * f0[i]
        j = np.searchsorted(pred, f)
        for jj in (np.clip(j - 1, 0, kmax - 1), np.clip(j, 0, kmax - 1)):
            ok = np.abs(f - pred[jj]) < MATCH * f0[i]
            P[jj[ok], i] = True
    return P


def runs(row, gap=None):
    """(start, end) of True runs, gaps <= gap (GAP) closed, runs < MIN_RUN dropped."""
    gap = GAP if gap is None else gap
    r = row.copy()
    idx = np.flatnonzero(r)
    if not len(idx):
        return []
    gaps = np.flatnonzero(np.diff(idx) > 1)
    out = []
    s = idx[0]
    for g in gaps:
        if idx[g + 1] - idx[g] - 1 <= gap:
            continue
        out.append((s, idx[g] + 1)); s = idx[g + 1]
    out.append((s, idx[-1] + 1))
    return [(s, e) for s, e in out if e - s >= MIN_RUN]


def demod(x, sr, f0, on, items):
    """items: [(h, start, end)]. Measures each harmonic along the pitch's
    phase with a PERIODS-period Blackman-Harris window; where the onset or the
    end cuts the window, the frame's harmonics are fitted jointly instead.
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
    wcache = {}
    for i, ks in by_frame.items():
        c = i * H
        per = sr / f0[i]
        L = int(min(MAX_L_S * sr, PERIODS * per))
        t0, t1 = c - L // 2, c - L // 2 + L
        lo, hi = max(t0, on, 0), min(t1, n)
        if hi - lo < CUT_MIN_PERIODS * per:
            continue
        ks = np.array(ks)
        rel = Phi[lo:hi] - Phi[min(c, n - 1)]
        # the harmonics are whole multiples: exp(-j h rel) by repeated product
        hi_h = int(hs_all[ks].max())
        pw = np.empty((hi_h, hi - lo), complex)
        pw[0] = np.exp(-1j * rel)
        for k in range(1, hi_h):
            pw[k] = pw[k - 1] * pw[0]
        pw = pw[hs_all[ks].astype(int) - 1]
        if L not in wcache:
            wcache[L] = pc.get_window("blackmanharris", L, fftbins=False)
        ww = wcache[L]
        if lo == t0 and hi == t1:
            # demodulating against the phase relative to the centre leaves the
            # harmonic's absolute phase at the centre in angle(z)
            z = pw @ (x[lo:hi] * ww) * (2.0 / ww.sum())
        else:
            # window cut by the onset or the end: a cut window's edge leaks
            # every harmonic into all the others (the fundamental into the
            # top band), and a shorter whole window no longer parts
            # neighbours, so the frame's harmonics are fitted jointly by
            # least squares, weighted by what is left of the frame's window
            # (still centred on the frame, so the fit is of this frame)
            sw = np.sqrt(ww[lo - t0 : hi - t0])
            D = np.concatenate([pw.real, pw.imag], axis=0).T * sw[:, None]
            sol, *_ = np.linalg.lstsq(D, x[lo:hi] * sw, rcond=CUT_RCOND)
            z = sol[: len(ks)] + 1j * sol[len(ks):]
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
        mult = h
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


def locked_tracks(x, sr, on, peaks):
    F = 1 + len(x) // H
    f0, voiced, moved = pitch_track(x, sr, peaks)
    if f0 is None:
        return [], None, {}
    kmax = int(min(top_harmonic(peaks, f0, voiced), (TOP_FRAC * sr) // f0.min()))
    if kmax < 1:
        return [], None, {}
    P = presence(peaks, f0, voiced, kmax, F)
    # a track fades in over the hop before its first frame (the synth): the
    # first frame is the first at or after the onset, and never frame 0, whose
    # fade-in lies before the file, so a harmonic would step in at full level.
    # (Waiting until the whole fade-in is after the onset costs fast attacks
    # a hop: tom2 16.5 dB against 11.5.)
    of = max(int(np.ceil(on / H)), 1)
    items = []
    back = BACK // H
    for h in range(1, kmax + 1):
        prev = of
        for s, e in runs(P[h - 1], PRES_GAP):
            # the long windows see a harmonic late: it is measured from as far
            # back as the longest window reaches, never before the onset or
            # into this harmonic's previous run
            items.append((h, max(prev, s - back), min(e, F)))
            prev = e + 1
    tr = demod(x, sr, f0, on, items)
    return tr, f0, {"kmax": kmax, "voiced": int(voiced.sum()), "oct_runs_moved": moved}


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
    lt, f0, info = locked_tracks(x, sr, on, peaks)
    # the free side gets the same second pass the locked side does, so the
    # comparison is between pitch-following and not, not one pass and two
    rf = x - yf
    freeb, _ = free_tracks(rf, sr, on)
    rf = rf - pc.synth_tracks(freeb, n, H, mode="phase")
    free = free + freeb
    # each side is judged as the decoder will play it: coded, then rendered
    dec = quantize(free, None, n, TIER)
    e_free, b_free = _energy(x - render(dec, n, sr)), len(pack(dec))
    lock, e_lock, b_lock = False, None, None
    if lt:
        r = x - pc.synth_tracks(lt, n, H, mode="phase")
        free2, _ = free_tracks(r, sr, on)
        dl = quantize(lt + free2, f0, n, TIER)
        e_lock, b_lock = _energy(x - render(dl, n, sr)), len(pack(dl))
        # clearly better is kept; within LOCK_DB either way, the cheaper side
        lock = e_lock < e_free - LOCK_DB or (abs(e_lock - e_free) <= LOCK_DB and b_lock < b_free)
        if lock:
            dec = dl
    dec["info"].update({"lock": lock, "e_free": e_free, "e_lock": e_lock, "b_free": b_free, "b_lock": b_lock,
                        "onset": on, **info, "f0_med": None if f0 is None else float(np.median(f0))})
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

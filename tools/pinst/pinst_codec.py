"""Prototype .pinst compiler and synth: one channel of a sample becomes
sinusoidal tracks plus a band-shaped noise envelope, and is rebuilt from
those alone (or from a short PCM attack and those).

Offline only, numpy/scipy. Nothing here runs in the game.

Model (per channel):
  sines  - partial tracks (frequency, amplitude per analysis frame), kept
           only at keyframes where linear interpolation would miss by more
           than a tolerance, and a start phase per track. Synthesis
           integrates frequency, so per-frame phase is never stored.
  noise  - the residual after phase-accurate sine subtraction, as dB per
           ERB band per frame, keyframed the same way.
  tns    - a 1 ms broadband envelope of the residual around the onset, so
           the noise keeps a hit's sharpness that a 23 ms frame smears.
  pcm    - optional: the first few ms verbatim (FLAC-sized), for the
           hybrid tier.
"""
from __future__ import annotations

import copy
import io
import lzma
from dataclasses import dataclass, field

import numpy as np
import soundfile as sf
from scipy.optimize import linear_sum_assignment
from scipy.ndimage import uniform_filter1d
from scipy.signal import get_window, stft, istft

SR = 44100
TWO_PI = 2.0 * np.pi


# --------------------------------------------------------------------- tracks

@dataclass
class Track:
    start: int                       # first frame index
    f: np.ndarray                    # Hz per frame
    a: np.ndarray                    # dB (linear amplitude in dBFS) per frame
    ph: np.ndarray                   # measured phase per frame (analysis only)


@dataclass
class Channel:
    n: int
    H: int
    tracks: list
    noise_db: np.ndarray             # (frames, bands)
    noise_H: int
    tns: np.ndarray | None = None    # 1 ms envelope ratio, dB
    tns_start: int = 0
    pcm: np.ndarray | None = None    # verbatim attack (hybrid tier)
    junction: int = 0                # sample where the model takes over
    info: dict = field(default_factory=dict)
    xres: np.ndarray | None = None   # decoded transform-coded residual over the attack
    xlf: np.ndarray | None = None    # decoded low-band residual, whole note


def _stft_frames(x: np.ndarray, N: int, H: int, Z: int):
    """Zero-phase windowed spectra, one per frame centred at i*H."""
    w = get_window("blackmanharris", N, fftbins=True)
    xp = np.concatenate([np.zeros(N // 2), x, np.zeros(N)])
    F = 1 + len(x) // H
    idx = np.arange(F)[:, None] * H + np.arange(N)[None, :]
    seg = xp[idx] * w
    buf = np.zeros((F, Z))
    buf[:, : N - N // 2] = seg[:, N // 2 :]
    buf[:, Z - N // 2 :] = seg[:, : N // 2]
    return np.fft.rfft(buf, axis=1), w.sum()


def find_peaks_frames(x, N, H, max_peaks=100, rel_db=-80.0, abs_db=-110.0, prom_db=9.0, fmax=18000.0):
    Z = 2 * N
    X, wsum = _stft_frames(x, N, H, Z)
    mag = np.abs(X) * 2.0 / wsum
    db = 20.0 * np.log10(mag + 1e-12)
    floor = uniform_filter1d(db, size=max(9, Z // 128), axis=1)
    loc = np.zeros_like(db, dtype=bool)
    loc[:, 1:-1] = (db[:, 1:-1] > db[:, :-2]) & (db[:, 1:-1] >= db[:, 2:])
    fmax_bin = int(fmax * Z / SR)
    loc[:, fmax_bin:] = False
    loc[:, :2] = False
    thr = np.maximum(db.max(axis=1, keepdims=True) + rel_db, abs_db)
    loc &= (db > thr) & (db > floor + prom_db)
    ang = np.angle(X)
    frames = []
    for i in range(db.shape[0]):
        k = np.flatnonzero(loc[i])
        if len(k) == 0:
            frames.append((np.zeros(0), np.zeros(0), np.zeros(0)))
            continue
        a, b, c = db[i, k - 1], db[i, k], db[i, k + 1]
        den = a - 2 * b + c
        p = np.where(np.abs(den) > 1e-9, 0.5 * (a - c) / den, 0.0)
        f = (k + p) * SR / Z
        amp = b - 0.25 * (a - c) * p
        nb = np.where(p >= 0, k + 1, k - 1)
        d = np.angle(np.exp(1j * (ang[i, nb] - ang[i, k])))
        ph = ang[i, k] + np.abs(p) * d
        if len(k) > max_peaks:
            keep = np.argsort(amp)[-max_peaks:]
            f, amp, ph = f[keep], amp[keep], ph[keep]
        frames.append((f, amp, ph))
    return frames


def track_peaks(frames, tol_oct=0.025, min_len=5, first_frame=0):
    done, active = [], []   # active: [start, [f], [a], [ph]]
    for i, (f, a, ph) in enumerate(frames):
        if i < first_frame:
            f = np.zeros(0)
        nxt = []
        used = np.zeros(len(f), dtype=bool)
        if active and len(f):
            last = np.array([t[1][-1] for t in active])
            cost = np.abs(np.log2(f[None, :] / last[:, None]))
            cost = np.where(cost < tol_oct, cost, 1e6)
            r, c = linear_sum_assignment(cost)
            ok = cost[r, c] < 1e6
            matched = dict(zip(r[ok], c[ok]))
        else:
            matched = {}
        for ti, t in enumerate(active):
            if ti in matched:
                j = matched[ti]
                used[j] = True
                t[1].append(f[j]); t[2].append(a[j]); t[3].append(ph[j])
                nxt.append(t)
            else:
                done.append(t)
        for j in np.flatnonzero(~used):
            nxt.append([i, [f[j]], [a[j]], [ph[j]]])
        active = nxt
    done.extend(active)
    out = []
    for s, f, a, ph in done:
        if len(f) >= min_len:
            out.append(Track(s, np.array(f), np.array(a), np.array(ph)))
    return out


# ---------------------------------------------------------------- synthesis

def synth_tracks(tracks, n, H, mode="phase", anchors=None, gate_from=0):
    """mode 'phase': cubic phase through every measured phase (analysis).
    mode 'integrate': phase set once per track (at anchors[i] frame offset,
    default its first frame) and integrated from frequency after that."""
    out = np.zeros(n + 4 * H)
    t = np.arange(H)
    for ti, tr in enumerate(tracks):
        L = len(tr.f)
        w = TWO_PI * tr.f / SR
        amp = 10.0 ** (tr.a / 20.0)
        if mode == "phase":
            th = tr.ph.astype(float).copy()
        else:
            k = 0 if anchors is None else anchors[ti]
            th = np.empty(L)
            th[k] = tr.ph[k]
            if L > 1:
                inc = 0.5 * (w[1:] + w[:-1]) * H
                th[k + 1 :] = th[k] + np.cumsum(inc[k:])
                if k > 0:
                    th[:k] = th[k] - np.cumsum(inc[:k][::-1])[::-1]
        # fade in one hop before the first frame and out one hop after the last
        w = np.concatenate([[w[0]], w, [w[-1]]])
        th = np.concatenate([[th[0] - w[0] * H], th, [th[-1] + w[-1] * H]])
        amp = np.concatenate([[0.0], amp, [0.0]])
        T = float(H)
        th0, th1, w0, w1 = th[:-1], th[1:], w[:-1], w[1:]
        if mode == "phase":
            M = np.round(((th0 + w0 * T - th1) + (w1 - w0) * T / 2) / TWO_PI)
        else:
            M = np.zeros_like(th0)
            th1 = th0 + 0.5 * (w0 + w1) * T   # exact for linear frequency
        e = th1 - th0 - w0 * T + TWO_PI * M
        al = 3.0 / T**2 * e - (w1 - w0) / T
        be = -2.0 / T**3 * e + (w1 - w0) / T**2
        phase = th0[:, None] + w0[:, None] * t + al[:, None] * t**2 + be[:, None] * t**3
        A = amp[:-1, None] + (amp[1:] - amp[:-1])[:, None] * (t / T)
        y = (A * np.cos(phase)).ravel()
        s0 = (tr.start - 1) * H
        a0, b0 = max(0, s0), min(len(out), s0 + len(y))
        if b0 > a0:
            out[a0:b0] += y[a0 - s0 : b0 - s0]
    out = out[:n]
    if gate_from > 0:
        out[:gate_from] = 0.0
    return out


# --------------------------------------------------------------------- noise

def erb_edges(nb=40, lo=30.0, hi=20000.0):
    e = lambda f: 21.4 * np.log10(1 + 0.00437 * f)
    ie = lambda v: (10 ** (v / 21.4) - 1) / 0.00437
    return ie(np.linspace(e(lo), e(hi), nb + 1))


NOISE_N = 1024


def _band_db(x, H, edges):
    f, _, Z = stft(x, SR, window="hann", nperseg=NOISE_N, noverlap=NOISE_N - H, boundary="even", padded=True)
    P = np.abs(Z) ** 2
    out = np.empty((P.shape[1], len(edges) - 1))
    for b in range(len(edges) - 1):
        m = (f >= edges[b]) & (f < edges[b + 1])
        if not m.any():
            m = np.abs(f - 0.5 * (edges[b] + edges[b + 1])) == np.abs(f - 0.5 * (edges[b] + edges[b + 1])).min()
        out[:, b] = 10.0 * np.log10(P[m].mean(axis=0) + 1e-20)
    return out


_REF = {}


def _ref_db(H, edges):
    key = (H, len(edges))
    if key not in _REF:
        rng = np.random.default_rng(1)
        _REF[key] = _band_db(rng.standard_normal(SR * 4), H, edges)[8:-8].mean(axis=0)
    return _REF[key]


def synth_noise(db, H, n, edges, seed=7):
    rng = np.random.default_rng(seed)
    wn = rng.standard_normal(n + NOISE_N)
    f, _, Z = stft(wn, SR, window="hann", nperseg=NOISE_N, noverlap=NOISE_N - H, boundary="even", padded=True)
    F = min(Z.shape[1], db.shape[0])
    centres = np.sqrt(edges[:-1] * edges[1:])
    g_db = db[:F] - _ref_db(H, edges)[None, :]
    g = np.empty((len(f), F))
    for i in range(F):
        g[:, i] = np.interp(f, centres, g_db[i])
    Z = Z[:, :F] * 10.0 ** (g / 20.0)
    _, y = istft(Z, SR, window="hann", nperseg=NOISE_N, noverlap=NOISE_N - H, boundary=True)
    y = y[:n]
    return np.pad(y, (0, n - len(y)))


TNS_BLOCK = 44   # ~1 ms


def block_db(x, blk=TNS_BLOCK):
    m = len(x) // blk
    r = np.sqrt((x[: m * blk].reshape(m, blk) ** 2).mean(axis=1) + 1e-20)
    return 20 * np.log10(r)


def apply_tns(y, tns_db, start, blk=TNS_BLOCK):
    """Scale y's 1 ms blocks from `start` toward the stored envelope."""
    m = len(tns_db)
    seg = y[start : start + m * blk]
    m = len(seg) // blk
    if m < 2:
        return y
    have = block_db(seg[: m * blk], blk)
    have = uniform_filter1d(have, 3)
    gain_db = np.clip(tns_db[:m] - have, -40, 24)
    c = (np.arange(m) + 0.5) * blk
    g = 10 ** (np.interp(np.arange(m * blk), c, gain_db) / 20)
    y = y.copy()
    y[start : start + m * blk] *= g
    return y


# ------------------------------------------------------------- keyframing

def keyframes(vals: np.ndarray, tol: np.ndarray, max_span=64):
    """Indices to keep so linear interpolation stays within tol on every
    column. vals: (L, C)."""
    L = len(vals)
    if L <= 2:
        return np.arange(L)
    keep = [0]
    k = 0
    while k < L - 1:
        best = k + 1
        j0, batch = k + 2, 4
        hi = min(L - 1, k + max_span)
        while j0 <= hi:
            # test a batch of candidate ends at once; stop at the first that fails
            js = np.arange(j0, min(hi, j0 + batch - 1) + 1)
            m = np.arange(k + 1, js[-1])
            r = (m[None, :] - k) / (js[:, None] - k)
            interp = vals[k] + r[:, :, None] * (vals[js] - vals[k])[:, None, :]
            bad = (np.abs(interp - vals[m]) > tol) & (m[None, :] < js[:, None])[:, :, None]
            fail = bad.any(axis=(1, 2))
            if fail.any():
                f = int(np.argmax(fail))
                if f:
                    best = int(js[f - 1])
                break
            best = int(js[-1])
            j0, batch = best + 1, min(batch * 2, 32)
        keep.append(best)
        k = best
    return np.array(keep)


def expand(keys, kvals, L):
    out = np.empty((L, kvals.shape[1]))
    for c in range(kvals.shape[1]):
        out[:, c] = np.interp(np.arange(L), keys, kvals[:, c])
    return out


# -------------------------------------------------------------- bit budget

def _lz(b: bytes) -> int:
    if not b:
        return 0
    f = [{"id": lzma.FILTER_LZMA2, "preset": 9 | lzma.PRESET_EXTREME}]
    return len(lzma.compress(b, format=lzma.FORMAT_RAW, filters=f))


def _varint(v: int, out: bytearray):
    v = int(v)
    v = (v << 1) ^ (v >> 63)   # zigzag
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return


@dataclass
class Tier:
    name: str
    f_cents: float = 4.0      # frequency quantum
    a_db: float = 1.0         # amplitude quantum
    f_tol: float = 4.0        # keyframe tolerance, cents
    a_tol: float = 1.0        # keyframe tolerance, dB
    cull_db: float = -70.0    # drop a track whose peak sits this far under the channel's loudest
    floor_db: float = -96.0   # and anything quieter than this outright
    noise_q: float = 1.5      # noise band dB quantum
    noise_tol: float = 1.5
    noise_bands: int = 40
    noise_H: int = 512        # noise envelope hop; TNS carries the onset at 1 ms
    noise_smooth: int = 5     # frames of power averaging: store the envelope, not one draw of it
    noise_floor: float = -130.0  # band dB under the note's loudest band: below it is silent
    pcm_ms: float = 0.0       # hybrid: verbatim attack length
    xf_ms: float = 0.0        # transform-coded residual: how long after the onset it runs (big = whole note)
    xf_snr: float = 12.0      # its signal-to-noise target per band, dB
    xf_M: int = 128           # MDCT hop
    xf_bands: int = 18
    xf_floor: float = -80.0   # bands this far under the residual's loudest band are not coded
    xf_noise_hz: float = 0.0  # attack layer: bands from here up carry a level only, filled with noise
    xf_lf_hz: float = 0.0     # low-band layer: below this the residual is coded for the whole note (drum bodies)
    xf_lf_snr: float = 15.0
    xf_lf_M: int = 1024
    phase_bits: int = 6
    f0_cents: float = 0.1     # harmonic lock: the shared f0 track's quantum and tolerance
    harmonic_lock: bool = True
    steer: float = 0.7        # closed-loop phase steering gain at each frequency key (0 = open loop)


def estimate_f0_track(tracks, f0_nominal, n_frames):
    """Per-frame fundamental from the low partials (h <= 10). A partial's
    frequency is then coded as h * f0 * 2^(cents/1200): an f0 error moves
    every partial together, so intermodulation through the amp stays on
    harmonics instead of beating."""
    strong = sorted(tracks, key=lambda t: -(10 ** (t.a / 10)).sum())[:12]
    grid = f0_nominal * 2 ** (np.linspace(-3, 3, 1201) / 12)
    best, score = f0_nominal, -1.0
    fms = np.array([np.median(t.f) for t in strong])
    ens = np.array([(10 ** (t.a / 10)).sum() for t in strong])
    for g in grid:
        h = np.maximum(1, np.round(fms / g))
        sc = sum(ens[(h <= 10) & (np.abs(np.log2(fms / (h * g))) < 0.004)].tolist(), 0.0)
        if sc > score:
            best, score = g, sc
    num = np.zeros(n_frames)
    den = np.zeros(n_frames)
    for t in tracks:
        h = max(1, round(np.median(t.f) / best))
        if h > 10:
            continue
        dev = np.log2(t.f / (h * best))
        ok = np.abs(dev) < 0.03
        idx = t.start + np.arange(len(t.f))
        w = 10 ** (t.a / 20) * ok
        np.add.at(num, idx, w * np.log2(t.f / h))
        np.add.at(den, idx, w)
    have = den > 0
    if not have.any():
        return np.full(n_frames, best)
    lg = np.interp(np.arange(n_frames), np.flatnonzero(have), num[have] / den[have])
    return 2 ** uniform_filter1d(lg, 3, mode="nearest")


def _wrap(a):
    return (a + np.pi) % TWO_PI - np.pi


def steer_keys(cents, ref, ph, keys, ki0, phi0, H, q, gain, clip):
    """Quantize the cents keys so the decoder's integrated phase keeps
    returning to the measured phase: each key's value is nudged (within
    clip) to cancel the wrapped phase error the decoder would have there.
    Open-loop rounding lets frequency bias integrate into drift that never
    comes back; this keeps every partial's phase error bounded."""
    qc = np.round(cents[keys] / q).astype(np.int64)
    if gain <= 0:
        return qc
    k = 2 * np.pi / SR
    th = phi0
    for i in range(ki0 + 1, len(keys)):
        a, b = keys[i - 1], keys[i]
        span = b - a
        fr = np.arange(span + 1) / span
        cp = qc[i - 1] * q
        r = ref[a : b + 1]

        def phase_at(cb):
            w = k * r * 2 ** ((cp + (cb - cp) * fr) / 1200)
            return th + 0.5 * (w[:-1] + w[1:]).sum() * H, w

        cn = cents[b]
        tb, w = phase_at(cn)
        dw = w * fr * (np.log(2) / 1200)
        deriv = 0.5 * (dw[:-1] + dw[1:]).sum() * H
        cb = cn + np.clip(gain * _wrap(ph[b] - tb) / max(deriv, 1e-9), -clip, clip)
        qc[i] = int(np.round(cb / q))
        th, _ = phase_at(qc[i] * q)
    return qc


def quantize(ch: Channel, tier: Tier):
    """Returns (decoded Channel, bytes). Decoded tracks hold only what a
    stream would: keyframes expanded back, quantized values, one phase."""
    H = ch.H
    jf = ch.junction // H if tier.pcm_ms > 0 else 0
    top = max([t.a.max() for t in ch.tracks], default=-200)
    hdr, dts, dfs, das = bytearray(), bytearray(), bytearray(), bytearray()
    dec, anchors = [], []
    prev_start = 0
    f0_bytes = 0
    f0q = None
    if tier.harmonic_lock and ch.info.get("f0"):
        nfr = max(t.start + len(t.f) for t in ch.tracks) + 1
        f0t = estimate_f0_track(ch.tracks, ch.info["f0"], nfr)
        c0 = 1200 * np.log2(f0t / 20.0)
        k0 = keyframes(c0[:, None], np.array([tier.f0_cents]))
        q0 = np.round(c0[k0] / tier.f0_cents).astype(np.int64)
        fs = bytearray()
        for i in range(len(k0)):
            _varint(k0[i] - (k0[i - 1] if i else 0), fs)
            _varint(q0[i] - (q0[i - 1] if i else 0), fs)
        f0_bytes = _lz(bytes(fs))
        f0q = 20.0 * 2 ** (expand(k0, (q0 * tier.f0_cents).astype(float)[:, None], nfr)[:, 0] / 1200)
    for tr in sorted(ch.tracks, key=lambda t: t.start):
        if tr.a.max() < max(top + tier.cull_db, tier.floor_db):
            continue
        if tr.start + len(tr.f) <= jf:
            continue    # fully inside the verbatim attack
        if f0q is not None:
            ref = f0q[tr.start : tr.start + len(tr.f)]
            hh = max(1, int(round(np.median(tr.f / ref))))
            ref = hh * ref
        else:
            hh, ref = 0, np.full(len(tr.f), 20.0)
        cents = 1200 * np.log2(tr.f / ref)
        vals = np.stack([cents, tr.a], axis=1)
        keys = keyframes(vals, np.array([tier.f_tol, tier.a_tol]))
        anchor = min(max(0, jf - tr.start), len(tr.f) - 1)
        keys = np.union1d(keys, [anchor])
        qph = int(np.round((tr.ph[anchor] % TWO_PI) / TWO_PI * (1 << tier.phase_bits))) % (1 << tier.phase_bits)
        qc = steer_keys(cents, ref, tr.ph, keys, int(np.searchsorted(keys, anchor)),
                        qph / (1 << tier.phase_bits) * TWO_PI, H, tier.f_cents, tier.steer, tier.f_tol)
        qa = np.round(tr.a[keys] / tier.a_db).astype(np.int64)
        _varint(tr.start - prev_start, hdr); prev_start = tr.start
        _varint(len(keys), hdr)
        if f0q is not None:
            _varint(hh, hdr)
        _varint(qc[0], hdr); _varint(qa[0], hdr); hdr.append(qph)
        for i in range(1, len(keys)):
            _varint(keys[i] - keys[i - 1], dts)
            _varint(qc[i] - qc[i - 1], dfs)
            _varint(qa[i] - qa[i - 1], das)
        L = len(tr.f)
        kv = np.stack([qc * tier.f_cents, qa * tier.a_db], axis=1).astype(float)
        full = expand(keys, kv, L)
        ph = np.zeros(L)
        ph[anchor] = qph / (1 << tier.phase_bits) * TWO_PI
        dec.append(Track(tr.start, ref * 2 ** (full[:, 0] / 1200), full[:, 1], ph))
        anchors.append(anchor)
    # noise
    nd = ch.noise_db
    nkeys = keyframes(nd, np.full(nd.shape[1], tier.noise_tol))
    qn = np.round(np.maximum(nd[nkeys], -200) / tier.noise_q).astype(np.int64)
    nstream = bytearray()
    for b in range(qn.shape[1]):
        _varint(qn[0, b], nstream)
    for i in range(1, len(nkeys)):
        _varint(nkeys[i] - nkeys[i - 1], nstream)
        for b in range(qn.shape[1]):
            _varint(qn[i, b] - qn[i - 1, b], nstream)
    noise_dec = expand(nkeys, qn.astype(float) * tier.noise_q, len(nd))
    tns_bytes = 0
    tns_dec = None
    if ch.tns is not None:
        tk = keyframes(ch.tns[:, None], np.array([1.5]))
        qt = np.round(ch.tns[tk] / 1.5).astype(np.int64)
        ts = bytearray()
        for i in range(len(tk)):
            _varint(tk[i] - (tk[i - 1] if i else 0), ts)
            _varint(qt[i] - (qt[i - 1] if i else 0), ts)
        tns_bytes = _lz(bytes(ts))
        tns_dec = expand(tk, (qt * 1.5).astype(float)[:, None], len(ch.tns))[:, 0]
    pcm_bytes = 0
    if ch.pcm is not None:
        bio = io.BytesIO()
        sf.write(bio, ch.pcm, SR, format="FLAC", subtype="PCM_16")
        pcm_bytes = len(bio.getvalue()) - 40    # FLAC container header, not data
    sizes = {
        "track_hdr": _lz(bytes(hdr)),
        "track_dt": _lz(bytes(dts)),
        "track_df": _lz(bytes(dfs)),
        "track_da": _lz(bytes(das)),
        "noise": _lz(bytes(nstream)),
        "tns": tns_bytes,
        "pcm": pcm_bytes,
        "f0": f0_bytes,
    }
    out = Channel(ch.n, H, dec, noise_dec, ch.noise_H, tns_dec, ch.tns_start, ch.pcm, ch.junction,
                  {"anchors": anchors, "n_tracks": len(dec), "n_keys": int(sum(len(t.f) for t in dec))})
    return out, sizes


# ------------------------------------------------- transform-coded residual

_MDCT = {}


def _mdct(M):
    if M not in _MDCT:
        n = np.arange(2 * M)
        _MDCT[M] = (np.cos(np.pi / M * (n[:, None] + 0.5 + M / 2) * (np.arange(M)[None, :] + 0.5)),
                    np.sin(np.pi * (n + 0.5) / (2 * M)))
    return _MDCT[M]


def _ints(a) -> bytes:
    """Zigzag varints of an int array."""
    a = np.asarray(a, dtype=np.int64).ravel()
    z = (a << 1) ^ (a >> 63)
    if not len(z) or z.max() < 128:
        return z.astype(np.uint8).tobytes()
    out = bytearray()
    for v in a:
        _varint(v, out)
    return bytes(out)


def xform_code(e, tier, M=None, snr=None, fmax=None):
    """What the partials miss, as quantized MDCT coefficients: a scale per
    band and frame, coefficients rounded to a step set by the SNR target.
    Coefficients that round to nothing are refilled with noise so each band
    keeps its energy. Returns (decoded signal, bytes)."""
    M = M or tier.xf_M
    snr = tier.xf_snr if snr is None else snr
    K = M if fmax is None else max(4, int(np.ceil(fmax * 2 * M / SR)))    # bins kept
    B, w = _mdct(M)
    B = B[:, :K]
    F = int(np.ceil(len(e) / M)) + 1
    buf = np.zeros((F + 1) * M)
    buf[M : M + len(e)] = e
    X = (np.lib.stride_tricks.sliding_window_view(buf, 2 * M)[::M] * w) @ B
    edges = np.unique(np.concatenate([[0], np.round(np.geomspace(2, K, tier.xf_bands + 1)).astype(int)]))
    wid = np.diff(edges)
    sdb = 10 * np.log10(np.add.reduceat(X**2, edges[:-1], axis=1) / wid + 1e-30)
    live = sdb > sdb.max() + tier.xf_floor
    qs = np.round(sdb / 1.5).astype(np.int64)
    rms = 10 ** (qs * 1.5 / 20) * live
    step = np.repeat(np.maximum(rms, 1e-30) * 10 ** (-snr / 20) * np.sqrt(12), wid, axis=1)
    noisy = (edges[:-1] * SR / (2 * M) >= tier.xf_noise_hz) if (tier.xf_noise_hz > 0 and fmax is None) else np.zeros(len(wid), bool)
    coded = np.repeat(live & ~noisy[None, :], wid, axis=1)
    q = np.where(coded, np.round(X / step), 0).astype(np.int64)
    Xd = q * step
    lack = np.maximum(rms**2 * wid - np.add.reduceat(Xd**2, edges[:-1], axis=1), 0)
    nzero = np.add.reduceat((q == 0).astype(float), edges[:-1], axis=1)
    fill = np.repeat(np.sqrt(lack / np.maximum(nzero, 1)), wid, axis=1)
    fill = np.where(coded, np.minimum(fill, step / np.sqrt(12)), fill)    # a coded zero was under half a step: never louder than that
    Xd = Xd + (q == 0) * fill * np.random.default_rng(11).standard_normal(X.shape)
    yf = (Xd @ B.T) * w * (2 / M)
    out = np.zeros_like(buf)
    for i in range(F):
        out[i * M : i * M + 2 * M] += yf[i]
    sc = np.where(live, qs, qs[live].min() - 1 if live.any() else 0)
    sc[1:] -= sc[:-1].copy()
    return out[M : M + len(e)], _lz(_ints(sc)) + _lz(_ints(q))


# ------------------------------------------------------------------ compile

def onset_sample(x, rel_db=-40.0):
    e = block_db(x, 44)
    i = np.flatnonzero(e > e.max() + rel_db)
    return int(i[0] * 44) if len(i) else 0


_ANALYSIS: dict = {}


def analyse(x: np.ndarray, pitched: bool, f0: float | None, tier: Tier) -> Channel:
    n = len(x)
    H = 256
    if pitched and f0 and f0 < 200:
        N = 4096
    elif pitched:
        N = 2048
    else:
        N = 2048
    on = onset_sample(x)
    first = int(np.ceil((on + N // 4) / H))     # no partial whose window mostly precedes the hit
    # the partial analysis does not depend on the tier: keep the last few
    key = (hash(x.tobytes()), N)
    if key not in _ANALYSIS:
        frames = find_peaks_frames(x, N, H)
        tr = track_peaks(frames, first_frame=first)
        if len(_ANALYSIS) >= 4:
            _ANALYSIS.pop(next(iter(_ANALYSIS)))
        _ANALYSIS[key] = (tr, synth_tracks(tr, n, H, mode="phase"))
    tracks, sines = _ANALYSIS[key]
    tracks = copy.deepcopy(tracks)
    resid = x - sines
    nH = tier.noise_H
    edges = erb_edges(tier.noise_bands)
    ndb = _band_db(resid, nH, edges)
    if tier.noise_smooth > 1:
        ndb = 10 * np.log10(uniform_filter1d(10 ** (ndb / 10), tier.noise_smooth, axis=0, mode="nearest") + 1e-20)
    # under the floor is silence, not floor-level hiss: the amp's gain and
    # compressor lift a constant floor into an audible bed under the decay
    ndb = np.where(ndb < _band_db(x, nH, edges).max() + tier.noise_floor, -200.0, ndb)
    ch = Channel(n, H, tracks, ndb, nH)
    # 1 ms residual envelope over the onset and the 200 ms after it
    noise_try = synth_noise(ndb, nH, n, edges)
    s0 = max(0, on - 10 * TNS_BLOCK)
    m = min(len(x) - s0, int(0.2 * SR)) // TNS_BLOCK
    ch.tns = block_db(resid[s0 : s0 + m * TNS_BLOCK]) if m > 2 else None
    ch.tns_start = s0
    if tier.pcm_ms > 0:
        ch.junction = on + int(tier.pcm_ms * SR / 1000)
        ch.pcm = x[: ch.junction + int(0.004 * SR)].astype(np.float32)
    snr = 10 * np.log10((x**2).sum() / max((resid**2).sum(), 1e-20))
    ch.info = {"f0": f0 if pitched else None, "N": N, "onset": on, "sine_snr_db": float(snr), "raw_tracks": len(tracks),
               "noise_try_rms": float(np.sqrt((noise_try**2).mean()))}
    return ch


def render(ch: Channel, tier: Tier, edges=None) -> np.ndarray:
    edges = erb_edges(tier.noise_bands) if edges is None else edges
    anchors = ch.info.get("anchors")
    y = synth_tracks(ch.tracks, ch.n, ch.H, mode="integrate", anchors=anchors, gate_from=0)
    nz = synth_noise(ch.noise_db, ch.noise_H, ch.n, edges)
    if ch.tns is not None:
        nz = apply_tns(nz, ch.tns, ch.tns_start)
    if ch.xres is not None:
        # the coded residual stands in for the noise model while it runs
        L, j = len(ch.xres), ch.junction
        w = np.ones(L)
        if L > j:
            w[j:] = np.linspace(1, 0, L - j)
        nz[:L] *= 1 - w
        y[:L] += ch.xres * w
    y = y + nz
    if ch.xlf is not None:
        y = y + ch.xlf
    if ch.pcm is not None and ch.junction > 0:
        xf = int(0.004 * SR)
        j = ch.junction
        ramp = np.linspace(0, 1, xf)
        out = y.copy()
        out[:j] = ch.pcm[:j]
        out[j : j + xf] = ch.pcm[j : j + xf] * (1 - ramp) + y[j : j + xf] * ramp
        y = out
    return y


def compile_channel(x, pitched, f0, tier):
    ch = analyse(x, pitched, f0, tier)
    dec, sizes = quantize(ch, tier)
    if tier.xf_ms > 0:
        j = min(ch.n, ch.info["onset"] + int(tier.xf_ms * SR / 1000))
        L = min(ch.n, j + int(0.004 * SR))
        det = synth_tracks(dec.tracks, ch.n, ch.H, mode="integrate", anchors=dec.info["anchors"], gate_from=0)
        dec.xres, sizes["xform"] = xform_code(x[:L] - det[:L], tier)
        dec.junction = j
        if j >= dec.tns_start + int(0.2 * SR):
            # the layer already covers the stretch the 1 ms envelope was for
            dec.tns, sizes["tns"] = None, 0
        if tier.xf_lf_hz > 0:
            # what is left under the cutoff once the attack layer is in, for the whole note
            w = np.zeros(ch.n)
            w[:j] = 1
            w[j:L] = np.linspace(1, 0, L - j)
            left = x - det
            left[:L] -= dec.xres * w[:L]
            dec.xlf, sizes["xform_lf"] = xform_code(left, tier, M=tier.xf_lf_M, snr=tier.xf_lf_snr, fmax=tier.xf_lf_hz)
            edges = erb_edges(tier.noise_bands)
            dec.noise_db = dec.noise_db.copy()
            dec.noise_db[:, np.sqrt(edges[:-1] * edges[1:]) < tier.xf_lf_hz] = -200.0
    return ch, dec, sizes

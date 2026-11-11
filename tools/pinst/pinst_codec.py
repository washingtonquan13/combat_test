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
import dataclasses
import io
import lzma
from dataclasses import dataclass, field

import fastlib
import numpy as np
import soundfile as sf
from scipy.optimize import linear_sum_assignment
from scipy.ndimage import uniform_filter1d
from scipy.fft import rfft as _rfft     # numpy's own gives the same bits, slower
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


def _stft_frames(x: np.ndarray, N: int, H: int, Z: int, rows: int = 0):
    """Zero-phase windowed spectra, one per frame centred at i*H, yielded a
    few frames at a time: every later step works frame by frame, and a
    whole note's spectra are far larger than the cache."""
    w = get_window("blackmanharris", N, fftbins=True)
    xp = np.concatenate([np.zeros(N // 2), x, np.zeros(N)])
    F = 1 + len(x) // H
    rows = rows or max(4, 65536 // Z)
    for f0 in range(0, F, rows):
        idx = np.arange(f0, min(F, f0 + rows))[:, None] * H + np.arange(N)[None, :]
        seg = xp[idx] * w
        buf = np.zeros((len(idx), Z))
        buf[:, : N - N // 2] = seg[:, N // 2 :]
        buf[:, Z - N // 2 :] = seg[:, : N // 2]
        yield _rfft(buf, axis=1), w.sum()


def find_peaks_frames(x, N, H, max_peaks=100, rel_db=-80.0, abs_db=-110.0, prom_db=9.0, fmax=18000.0):
    Z = 2 * N
    frames = []
    for X, wsum in _stft_frames(x, N, H, Z):
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
        # every peak of the batch at once, then dealt out to its frame
        fi, k = np.nonzero(loc)
        a, b, c = db[fi, k - 1], db[fi, k], db[fi, k + 1]
        den = a - 2 * b + c
        p = np.where(np.abs(den) > 1e-9, 0.5 * (a - c) / den, 0.0)
        f = (k + p) * SR / Z
        amp = b - 0.25 * (a - c) * p
        nb = np.where(p >= 0, k + 1, k - 1)
        ak = np.angle(X[fi, k])     # phases only where there is a peak
        d = np.angle(np.exp(1j * (np.angle(X[fi, nb]) - ak)))
        ph = ak + np.abs(p) * d
        cuts = np.searchsorted(fi, np.arange(db.shape[0] + 1))
        for i in range(db.shape[0]):
            s0, s1 = cuts[i], cuts[i + 1]
            if s1 - s0 > max_peaks:
                keep = s0 + np.argsort(amp[s0:s1])[-max_peaks:]
                frames.append((f[keep], amp[keep], ph[keep]))
            else:
                frames.append((f[s0:s1], amp[s0:s1], ph[s0:s1]))
    return frames


_TRACK_PY = False      # tests: run the numpy tracker


def track_peaks(frames, tol_oct=0.025, min_len=5, first_frame=0):
    """Tracks are numbered as they are born, so the live ones are always in
    number order. Each frame records which track took which peak; the tracks
    are cut out of those records at the end, in the order they ended."""
    if fastlib.lib and frames and not _TRACK_PY:
        cuts = np.zeros(len(frames) + 1, dtype=np.int64)
        cuts[1:] = np.cumsum([len(fr[0]) for fr in frames])
        fc, ac, pc = (np.ascontiguousarray(np.concatenate([fr[k] for fr in frames]), dtype=float) for k in range(3))
        ids, src, start = (np.empty(max(1, int(cuts[-1])), dtype=np.int64) for _ in range(3))
        born = fastlib.lib.track_assign(fc.ctypes.data, cuts.ctypes.data, len(frames), first_frame, tol_oct,
                                        ids.ctypes.data, src.ctypes.data, start.ctypes.data)
        assert born >= 0
        if not born:
            return []
        m = int(cuts[-1] - cuts[min(max(first_frame, 0), len(frames))])
        ids, src, start = ids[:m], src[:m], start[:born]
        return _cut_tracks(ids, fc[src], ac[src], pc[src], start, born, min_len)
    none = np.zeros(0, dtype=np.int64)
    act_id, act_last, born = none, np.zeros(0), 0
    ids, fs, as_, phs, starts = [], [], [], [], []
    for i, (f, a, ph) in enumerate(frames):
        if i < first_frame:
            f = np.zeros(0)
        r = c = none
        if len(act_id) and len(f):
            cost = np.abs(np.log2(f[None, :] / act_last[:, None]))
            cost = np.where(cost < tol_oct, cost, 1e6)
            r, c = linear_sum_assignment(cost)
            ok = cost[r, c] < 1e6
            r, c = r[ok], c[ok]
        used = np.zeros(len(f), dtype=bool)
        used[c] = True
        new = np.flatnonzero(~used)
        act_id = np.concatenate([act_id[r], born + np.arange(len(new))])
        js = np.concatenate([c, new])
        act_last = f[js]
        starts.append(np.full(len(new), i))
        born += len(new)
        ids.append(act_id); fs.append(act_last); as_.append(a[js]); phs.append(ph[js])
    if not born:
        return []
    return _cut_tracks(np.concatenate(ids), np.concatenate(fs), np.concatenate(as_), np.concatenate(phs),
                       np.concatenate(starts), born, min_len)


def _cut_tracks(ids, f, a, ph, start, born, min_len):
    order = np.argsort(ids, kind="stable")      # by track, frames in order
    f, a, ph = f[order], a[order], ph[order]
    count = np.bincount(ids, minlength=born)
    first = np.cumsum(count) - count
    out = []
    for t in np.lexsort((np.arange(born), start + count)):     # by the frame it ended, then by number
        if count[t] >= min_len:
            q = slice(first[t], first[t] + count[t])
            out.append(Track(int(start[t]), f[q].copy(), a[q].copy(), ph[q].copy()))
    return out


# ---------------------------------------------------------------- synthesis

def synth_tracks(tracks, n, H, mode="phase", anchors=None, gate_from=0):
    """mode 'phase': cubic phase through every measured phase (analysis).
    mode 'integrate': phase set once per track (at anchors[i] frame offset,
    default its first frame) and integrated from frequency after that."""
    out = np.zeros(n + 4 * H)
    t = np.arange(H)
    rows = []
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
        s0 = (tr.start - 1) * H
        if fastlib.lib:
            rows.append((th0, w0, al, be, amp[:-1], amp[1:] - amp[:-1], s0 + H * np.arange(len(al))))
            continue
        phase = th0[:, None] + w0[:, None] * t + al[:, None] * t**2 + be[:, None] * t**3
        A = amp[:-1, None] + (amp[1:] - amp[:-1])[:, None] * (t / T)
        y = (A * np.cos(phase)).ravel()
        a0, b0 = max(0, s0), min(len(out), s0 + len(y))
        if b0 > a0:
            out[a0:b0] += y[a0 - s0 : b0 - s0]
    if rows:
        _synth_rows(rows, H, out)
    out = out[:n]
    if gate_from > 0:
        out[:gate_from] = 0.0
    return out


def _synth_rows(rows, H, out):
    """The frames of every partial, in order, a cache-sized batch at a time."""
    th0, w0, al, be, a0, da = (np.ascontiguousarray(np.concatenate([r[k] for r in rows]), dtype=float) for k in range(6))
    off = np.ascontiguousarray(np.concatenate([r[6] for r in rows]), dtype=np.int64)
    t = np.arange(H)
    t1, t2, t3, tT = t.astype(float), (t**2).astype(float), (t**3).astype(float), t / float(H)
    step = max(1, 16384 // H)
    buf = np.empty(step * H)
    ptr = lambda a, i=0: a.ctypes.data + 8 * i
    for a in range(0, len(off), step):
        m = min(step, len(off) - a)
        fastlib.lib.st_phase(ptr(th0, a), ptr(w0, a), ptr(al, a), ptr(be, a), m, H, ptr(t1), ptr(t2), ptr(t3), ptr(buf))
        np.cos(buf[: m * H], out=buf[: m * H])
        fastlib.lib.st_acc(ptr(buf), ptr(a0, a), ptr(da, a), ptr(tT), m, H, ptr(off, a), ptr(out), len(out))


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


_NOISE_Z = {}


def synth_noise(db, H, n, edges, seed=7):
    # the white noise and its spectrum depend only on the length: every
    # channel and tier of a note asks for the same one
    key = (seed, H, n)
    if key not in _NOISE_Z:
        _NOISE_Z.clear()
        wn = np.random.default_rng(seed).standard_normal(n + NOISE_N)
        f, _, Z = stft(wn, SR, window="hann", nperseg=NOISE_N, noverlap=NOISE_N - H, boundary="even", padded=True)
        _NOISE_Z[key] = (f, Z)
    f, Z = _NOISE_Z[key]
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

_fast = fastlib.lib


def keyframes(vals: np.ndarray, tol: np.ndarray, max_span=64):
    """Indices to keep so linear interpolation stays within tol on every
    column. vals: (L, C)."""
    L = len(vals)
    if L <= 2:
        return np.arange(L)
    if _fast:
        vals = np.ascontiguousarray(vals, dtype=float)
        tol = np.ascontiguousarray(np.broadcast_to(tol, vals.shape[1:]), dtype=float)
        keep = np.empty(L, dtype=np.int64)
        n = _fast.keyframes(vals.ctypes.data, L, vals.shape[1], tol.ctypes.data, max_span, keep.ctypes.data)
        return keep[:n].copy()
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

_LZ_FILTERS = [{"id": lzma.FILTER_LZMA2, "preset": 9 | lzma.PRESET_EXTREME}]
_LZ: dict = {}


def lz_bytes(b: bytes) -> bytes:
    """A stream packed. The last few are kept: a stream is sized while it is
    built and packed again when the file is written, and both tiers of a
    bake share most of theirs."""
    if not b:
        return b""
    b = bytes(b)
    z = _LZ.get(b)
    if z is None:
        if len(_LZ) >= 64:
            _LZ.clear()
        # Preset 9 on its own sets up a 64 MB dictionary and ~670 MB of
        # tables for every stream, most of them a few KB. A dictionary just
        # as long as the stream gives the same bytes without that.
        d = 4096
        while d < len(b):
            d *= 2
        z = _LZ[b] = lzma.compress(b, format=lzma.FORMAT_RAW, filters=[dict(_LZ_FILTERS[0], dict_size=d)])
    return z


def _lz(b: bytes) -> int:
    return len(lz_bytes(b))


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


def _ints(a) -> bytes:
    """Zigzag varints of an int array, the bytes _varint would write."""
    a = np.asarray(a, dtype=np.int64).ravel()
    z = (a << 1) ^ (a >> 63)
    if not len(z) or z.max() < 128:
        return z.astype(np.uint8).tobytes()
    n = np.ones(len(z), dtype=np.int64)     # bytes each value takes
    s = 7
    while True:
        more = z >= (1 << s)
        if not more.any():
            break
        n += more
        s += 7
    pos = np.cumsum(n) - n
    out = np.zeros(int(n.sum()), dtype=np.uint8)
    for j in range(int(n.max())):
        m = n > j
        out[pos[m] + j] = ((z[m] >> (7 * j)) & 0x7F) | ((n[m] > j + 1) << 7)
    return out.tobytes()


def _deltas(a):
    """a[0], then the steps; along the first axis."""
    a = np.asarray(a, dtype=np.int64)
    return np.concatenate([a[:1], np.diff(a, axis=0)])


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
    if len(strong):
        # every candidate at once. The sum is Python's own (compensated, in
        # track order), so the winner is the one the loop over candidates picked.
        h = np.maximum(1, np.round(fms[None, :] / grid[:, None]))
        ok = (h <= 10) & (np.abs(np.log2(fms[None, :] / (h * grid[:, None]))) < 0.004)
        tot, comp = np.zeros(len(grid)), np.zeros(len(grid))
        for j in range(len(strong)):
            v = np.where(ok[:, j], ens[j], 0.0)
            t = tot + v
            comp += np.where(np.abs(tot) >= np.abs(v), (tot - t) + v, (v - t) + tot)
            tot = t
        sc = np.where(comp != 0, tot + comp, tot)
        best = grid[int(np.argmax(sc))]
    num = np.zeros(n_frames)
    den = np.zeros(n_frames)
    for t in tracks:
        h = max(1, round(np.median(t.f) / best))
        if h > 10:
            continue
        dev = np.log2(t.f / (h * best))
        ok = np.abs(dev) < 0.03
        w = 10 ** (t.a / 20) * ok
        num[t.start : t.start + len(t.f)] += w * np.log2(t.f / h)
        den[t.start : t.start + len(t.f)] += w
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
    if _fast:
        c, r, p = (np.ascontiguousarray(v, dtype=float) for v in (cents, ref, ph))
        ks = np.ascontiguousarray(keys, dtype=np.int64)
        if not _fast.steer_keys(c.ctypes.data, r.ctypes.data, p.ctypes.data, ks.ctypes.data, len(ks), ki0, phi0, H,
                                q, gain, clip, k, np.log(2) / 1200, qc.ctypes.data):
            return qc
        qc = np.round(cents[keys] / q).astype(np.int64)
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
    hdr, dts, dfs, das = bytearray(), [], [], []
    dec, anchors = [], []
    prev_start = 0
    f0_bytes = 0
    f0q = None
    fs, ts, nfr = bytearray(), bytearray(), 0
    if tier.harmonic_lock and ch.info.get("f0"):
        nfr = max(t.start + len(t.f) for t in ch.tracks) + 1
        memo = getattr(ch, "memo", None)    # the same for every tier of one analysis
        if memo is None or memo.get("f0k") != (ch.info["f0"], nfr):
            f0t = estimate_f0_track(ch.tracks, ch.info["f0"], nfr)
            if memo is not None:
                memo["f0k"], memo["f0t"] = (ch.info["f0"], nfr), f0t
        f0t = f0t if memo is None else memo["f0t"]
        c0 = 1200 * np.log2(f0t / 20.0)
        k0 = keyframes(c0[:, None], np.array([tier.f0_cents]))
        q0 = np.round(c0[k0] / tier.f0_cents).astype(np.int64)
        fs += _ints(np.stack([_deltas(k0), _deltas(q0)], axis=1))
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
        dts.append(np.diff(keys)); dfs.append(np.diff(qc)); das.append(np.diff(qa))
        L = len(tr.f)
        kv = np.stack([qc * tier.f_cents, qa * tier.a_db], axis=1).astype(float)
        full = expand(keys, kv, L)
        ph = np.zeros(L)
        ph[anchor] = qph / (1 << tier.phase_bits) * TWO_PI
        dec.append(Track(tr.start, ref * 2 ** (full[:, 0] / 1200), full[:, 1], ph))
        anchors.append(anchor)
    dts, dfs, das = (_ints(np.concatenate(v)) if v else b"" for v in (dts, dfs, das))
    # noise
    nd = ch.noise_db
    nkeys = keyframes(nd, np.full(nd.shape[1], tier.noise_tol))
    qn = np.round(np.maximum(nd[nkeys], -200) / tier.noise_q).astype(np.int64)
    nstream = _ints(qn[0]) + _ints(np.concatenate([np.diff(nkeys)[:, None], np.diff(qn, axis=0)], axis=1))
    noise_dec = expand(nkeys, qn.astype(float) * tier.noise_q, len(nd))
    tns_bytes = 0
    tns_dec = None
    if ch.tns is not None:
        tk = keyframes(ch.tns[:, None], np.array([1.5]))
        qt = np.round(ch.tns[tk] / 1.5).astype(np.int64)
        ts += _ints(np.stack([_deltas(tk), _deltas(qt)], axis=1))
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
                  {"anchors": anchors, "n_tracks": len(dec), "n_keys": int(sum(len(t.f) for t in dec)),
                   "streams": {"hdr": bytes(hdr), "dt": bytes(dts), "df": bytes(dfs), "da": bytes(das),
                               "noise": bytes(nstream), "tns": bytes(ts), "f0": bytes(fs)},
                   "lock": f0q is not None, "f0_frames": nfr, "noise_frames": len(nd),
                   "tns_len": 0 if ch.tns is None else len(ch.tns)})
    return out, sizes


# ------------------------------------------------- transform-coded residual

_MDCT = {}


def _mdct(M):
    if M not in _MDCT:
        n = np.arange(2 * M)
        _MDCT[M] = (np.cos(np.pi / M * (n[:, None] + 0.5 + M / 2) * (np.arange(M)[None, :] + 0.5)),
                    np.sin(np.pi * (n + 0.5) / (2 * M)))
    return _MDCT[M]




def _xf_edges(K, nbands):
    return np.unique(np.concatenate([[0], np.round(np.geomspace(2, K, nbands + 1)).astype(int)]))


def xform_decode(sc, q, n, M, K, nbands, snr, noise_hz, dead):
    """The signal from what the stream holds. sc: (frames, bands) scale
    codes in 1.5 dB steps, `dead` marking bands that carry nothing.
    q: (frames, K) coefficient codes."""
    B, w = _mdct(M)
    B = B[:, :K]
    edges = _xf_edges(K, nbands)
    wid = np.diff(edges)
    F = sc.shape[0]
    live = sc != dead
    rms = 10 ** (sc * 1.5 / 20) * live
    step = np.repeat(np.maximum(rms, 1e-30) * 10 ** (-snr / 20) * np.sqrt(12), wid, axis=1)
    noisy = (edges[:-1] * SR / (2 * M) >= noise_hz) if noise_hz > 0 else np.zeros(len(wid), bool)
    coded = np.repeat(live & ~noisy[None, :], wid, axis=1)
    Xd = q * step
    lack = np.maximum(rms**2 * wid - np.add.reduceat(Xd**2, edges[:-1], axis=1), 0)
    nzero = np.add.reduceat((q == 0).astype(float), edges[:-1], axis=1)
    fill = np.repeat(np.sqrt(lack / np.maximum(nzero, 1)), wid, axis=1)
    fill = np.where(coded, np.minimum(fill, step / np.sqrt(12)), fill)    # a coded zero was under half a step: never louder than that
    Xd = Xd + (q == 0) * fill * np.random.default_rng(11).standard_normal(Xd.shape)
    yf = (Xd @ B.T) * w * (2 / M)
    out = np.zeros((F + 1) * M)
    for i in range(F):
        out[i * M : i * M + 2 * M] += yf[i]
    return out[M : M + n]


def xform_code(e, tier, M=None, snr=None, fmax=None):
    """What the partials miss, as quantized MDCT coefficients: a scale per
    band and frame, coefficients rounded to a step set by the SNR target.
    Coefficients that round to nothing are refilled with noise so each band
    keeps its energy. Returns (decoded signal, bytes, stream)."""
    M = M or tier.xf_M
    snr = tier.xf_snr if snr is None else snr
    K = M if fmax is None else max(4, int(np.ceil(fmax * 2 * M / SR)))    # bins kept
    noise_hz = tier.xf_noise_hz if fmax is None else 0.0
    B, w = _mdct(M)
    B = B[:, :K]
    F = int(np.ceil(len(e) / M)) + 1
    buf = np.zeros((F + 1) * M)
    buf[M : M + len(e)] = e
    X = (np.lib.stride_tricks.sliding_window_view(buf, 2 * M)[::M] * w) @ B
    edges = _xf_edges(K, tier.xf_bands)
    wid = np.diff(edges)
    sdb = 10 * np.log10(np.add.reduceat(X**2, edges[:-1], axis=1) / wid + 1e-30)
    live = sdb > sdb.max() + tier.xf_floor
    qs = np.round(sdb / 1.5).astype(np.int64)
    dead = int(qs[live].min() - 1) if live.any() else 0
    sc = np.where(live, qs, dead)
    rms = 10 ** (qs * 1.5 / 20) * live
    step = np.repeat(np.maximum(rms, 1e-30) * 10 ** (-snr / 20) * np.sqrt(12), wid, axis=1)
    noisy = (edges[:-1] * SR / (2 * M) >= noise_hz) if noise_hz > 0 else np.zeros(len(wid), bool)
    q = np.where(np.repeat(live & ~noisy[None, :], wid, axis=1), np.round(X / step), 0).astype(np.int64)
    d = sc.copy()
    d[1:] -= sc[:-1]
    stream = {"n": len(e), "M": M, "K": K, "nbands": tier.xf_bands, "snr": snr, "noise_hz": noise_hz, "dead": dead,
              "frames": F, "sc": _ints(d), "q": _ints(q)}
    y = xform_decode(sc, q, len(e), M, K, tier.xf_bands, snr, noise_hz, dead)
    return y, _lz(stream["sc"]) + _lz(stream["q"]), stream


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
        _ANALYSIS[key] = (tr, synth_tracks(tr, n, H, mode="phase"), {})
    tracks, sines, memo = _ANALYSIS[key]
    tracks = [Track(t.start, t.f.copy(), t.a.copy(), t.ph.copy()) for t in tracks]
    resid = x - sines
    nH = tier.noise_H
    edges = erb_edges(tier.noise_bands)
    ndb = _band_db(resid, nH, edges)
    if tier.noise_smooth > 1:
        # the running mean can come out a hair under zero where silence follows sound
        ndb = 10 * np.log10(np.maximum(uniform_filter1d(10 ** (ndb / 10), tier.noise_smooth, axis=0, mode="nearest"), 0.0) + 1e-20)
    # under the floor is silence, not floor-level hiss: the amp's gain and
    # compressor lift a constant floor into an audible bed under the decay
    ndb = np.where(ndb < _band_db(x, nH, edges).max() + tier.noise_floor, -200.0, ndb)
    ch = Channel(n, H, tracks, ndb, nH)
    ch.memo = memo
    # 1 ms residual envelope over the onset and the 200 ms after it
    s0 = max(0, on - 10 * TNS_BLOCK)
    m = min(len(x) - s0, int(0.2 * SR)) // TNS_BLOCK
    ch.tns = block_db(resid[s0 : s0 + m * TNS_BLOCK]) if m > 2 else None
    ch.tns_start = s0
    if tier.pcm_ms > 0:
        ch.junction = on + int(tier.pcm_ms * SR / 1000)
        ch.pcm = x[: ch.junction + int(0.004 * SR)].astype(np.float32)
    snr = 10 * np.log10((x**2).sum() / max((resid**2).sum(), 1e-20))
    ch.info = {"f0": f0 if pitched else None, "N": N, "onset": on, "sine_snr_db": float(snr), "raw_tracks": len(tracks)}
    return ch


def render(ch: Channel, tier: Tier, edges=None, det=None) -> np.ndarray:
    """det: the partials already synthesized (compile_tiers hands them back)."""
    edges = erb_edges(tier.noise_bands) if edges is None else edges
    anchors = ch.info.get("anchors")
    y = synth_tracks(ch.tracks, ch.n, ch.H, mode="integrate", anchors=anchors, gate_from=0) if det is None else det.copy()
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


def _add_layers(x, ch, dec, sizes, tier, det=None):
    """The transform-coded residual layers of a tier, onto a quantized channel.
    Returns the partials as the decoder will synthesize them."""
    j = min(ch.n, ch.info["onset"] + int(tier.xf_ms * SR / 1000))
    L = min(ch.n, j + int(0.004 * SR))
    if det is None:
        det = synth_tracks(dec.tracks, ch.n, ch.H, mode="integrate", anchors=dec.info["anchors"], gate_from=0)
    dec.xres, sizes["xform"], dec.info["xf"] = xform_code(x[:L] - det[:L], tier)
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
        dec.xlf, sizes["xform_lf"], dec.info["xlf"] = xform_code(left, tier, M=tier.xf_lf_M, snr=tier.xf_lf_snr, fmax=tier.xf_lf_hz)
        dec.info["lf_hz"] = tier.xf_lf_hz
        edges = erb_edges(tier.noise_bands)
        dec.noise_db = dec.noise_db.copy()
        dec.noise_db[:, np.sqrt(edges[:-1] * edges[1:]) < tier.xf_lf_hz] = -200.0
    return det


def compile_channel(x, pitched, f0, tier):
    ch = analyse(x, pitched, f0, tier)
    dec, sizes = quantize(ch, tier)
    if tier.xf_ms > 0:
        _add_layers(x, ch, dec, sizes, tier)
    return ch, dec, sizes


_LAYER_FIELDS = ("name", "xf_ms", "xf_snr", "xf_M", "xf_bands", "xf_floor", "xf_noise_hz", "xf_lf_hz", "xf_lf_snr", "xf_lf_M")


def compile_tiers(x, pitched, f0, plain: Tier, layered: Tier):
    """A channel at two tiers that differ only in their residual layers:
    one analysis, one quantization, the layers added to a copy. Returns
    (plain channel, layered channel, the partials both synthesize)."""
    a, b = dataclasses.asdict(plain), dataclasses.asdict(layered)
    assert plain.xf_ms == 0 and layered.xf_ms > 0 and all(a[k] == b[k] for k in a if k not in _LAYER_FIELDS)
    ch = analyse(x, pitched, f0, plain)
    dec, sizes = quantize(ch, plain)
    det = synth_tracks(dec.tracks, ch.n, ch.H, mode="integrate", anchors=dec.info["anchors"], gate_from=0)
    lay = copy.copy(dec)
    lay.info = dict(dec.info)
    _add_layers(x, ch, lay, dict(sizes), layered, det)
    return dec, lay, det

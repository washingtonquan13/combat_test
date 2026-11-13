"""The sine layer's hot paths, faster, the same numbers (owner: agent S).

Each function here gives what the legacy pinst_codec code it stands for gives,
bit for bit (sines_check.py in the scratch tests that on the bench notes):

  find_tracks(x, N, hop, first)    pc.track_peaks(pc.find_peaks_frames(x, N, hop, fmax=SR/2), first_frame=first)
  quantize(tracks, H, f0, tier)    pc.quantize(ch, tier)'s streams, track count and sine sizes
  render(code, n, fallback)        pc.synth_tracks(analysis.tracks_of(code), n, H, "integrate", anchors 0)

pc.SR is set per note: everything here reads it when called, never at import.

How:
  find_tracks  the spectra in big batches into reused buffers (a 2-D rfft gives
               every row the same bits at any batch size; numpy's abs, log10,
               angle and exp give each element the same bits wherever it sits);
               no frame before `first` (the tracker never reads them); the
               peak test and parabola in C (native/sines.c, plain arithmetic);
               the peaks straight into the tracker's flat arrays.
  quantize     the sine part of pc.quantize only: no decoded tracks, noise,
               TNS or PCM (encode_sines reads none of them).
  render       the streams' varints read with numpy, every track's keys
               interpolated in one np.interp (keys offset per track: the same
               differences, so the same bits), into fastlib's st_tracks.
"""
from __future__ import annotations

import ctypes
import os

import numpy as np
from scipy.fft import rfft as _rfft
from scipy.ndimage import uniform_filter1d
from scipy.signal import get_window

import fastlib
import pinst_codec as pc


def _load():
    try:
        lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "native", "sines.dll"))
    except OSError:
        return None
    d, p, i64 = ctypes.c_double, ctypes.c_void_p, ctypes.c_int64
    lib.pk_scale.restype = None
    lib.pk_scale.argtypes = [p, i64, d]
    lib.pk_rows.restype = i64
    lib.pk_rows.argtypes = [p, i64, i64, i64, i64, d, d, d, d, d, p, i64, p, p, p, p, p, p]
    return lib


_lib = _load()
_WIN: dict = {}
ROWS = 1 << 15      # spectra per batch, in doubles: cache-sized (any size gives the same bits)


def _window(N):
    if N not in _WIN:
        w = get_window("blackmanharris", N, fftbins=True)
        _WIN[N] = (w, w.sum())
    return _WIN[N]


def _peaks(x, N, H, first, max_peaks=100, rel_db=-80.0, abs_db=-110.0, prom_db=9.0, fmax=None):
    """find_peaks_frames' peaks of frames first.. as flat arrays (f, amp, ph) and
    per-frame cuts over all frames (the ones before first empty). fmax: default
    Nyquist at the note's rate (pc.SR is set per note, so read here, not at import)."""
    if fmax is None:
        fmax = pc.SR / 2
    Z = 2 * N
    w, wsum = _window(N)
    F = 1 + len(x) // H
    nb = Z // 2 + 1
    cuts = np.zeros(F + 1, dtype=np.int64)
    first = min(max(first, 0), F)
    if first >= F:
        return np.zeros(0), np.zeros(0), np.zeros(0), cuts
    xp = np.concatenate([np.zeros(N // 2), x, np.zeros(N)])
    view = np.lib.stride_tricks.sliding_window_view(xp, N)[::H]
    rows = max(4, ROWS // Z)
    buf = np.zeros((rows, Z))
    db = np.empty((rows, nb))
    cap = rows * (nb // 2 + 1)
    ofi = np.empty(cap, dtype=np.int64)
    op, of, oam = (np.empty(cap) for _ in range(3))
    oxk, oxn = np.empty(cap, dtype=complex), np.empty(cap, dtype=complex)
    kmax = int(fmax * Z / pc.SR)
    size = max(9, Z // 128)
    h = N // 2
    parts = []
    for f0 in range(first, F, rows):
        m = min(rows, F - f0)
        seg = view[f0 : f0 + m]
        b = buf[:m]
        np.multiply(seg[:, h:], w[h:], out=b[:, : N - h])
        np.multiply(seg[:, :h], w[:h], out=b[:, Z - h :])
        X = np.ascontiguousarray(_rfft(b, axis=1), dtype=complex)
        d = db[:m]
        np.abs(X, out=d)
        _lib.pk_scale(d.ctypes.data, m * nb, float(wsum))
        np.log10(d, out=d)
        n = int(_lib.pk_rows(d.ctypes.data, m, nb, size, kmax, rel_db, abs_db, prom_db, float(pc.SR), float(Z),
                             X.ctypes.data, f0, ofi.ctypes.data, op.ctypes.data, of.ctypes.data, oam.ctypes.data,
                             oxk.ctypes.data, oxn.ctypes.data))
        if n < 0:
            raise MemoryError("pk_rows")
        if n:
            parts.append((ofi[:n].copy(), op[:n].copy(), of[:n].copy(), oam[:n].copy(), oxk[:n].copy(), oxn[:n].copy()))
    if not parts:
        return np.zeros(0), np.zeros(0), np.zeros(0), cuts
    fi, p, f, amp, xk, xn = (np.concatenate([q[i] for q in parts]) for i in range(6))
    ak = np.angle(xk)               # phases only where there is a peak (elementwise: same bits)
    dd = np.angle(np.exp(1j * (np.angle(xn) - ak)))
    ph = ak + np.abs(p) * dd
    n = len(fi)
    cnt = np.bincount(fi, minlength=F)
    c = np.zeros(F + 1, dtype=np.int64)
    np.cumsum(cnt, out=c[1:])
    over = np.flatnonzero(cnt > max_peaks)
    if len(over):
        sel = []
        prev = 0
        for i in over:
            s0, s1 = int(c[i]), int(c[i + 1])
            sel.append(np.arange(prev, s0))
            sel.append(s0 + np.argsort(amp[s0:s1])[-max_peaks:])
            prev = s1
        sel.append(np.arange(prev, n))
        sel = np.concatenate(sel)
        f, amp, ph = f[sel], amp[sel], ph[sel]
        cnt = np.minimum(cnt, max_peaks)
    np.cumsum(cnt, out=cuts[1:])
    return (np.ascontiguousarray(f, dtype=float), np.ascontiguousarray(amp, dtype=float),
            np.ascontiguousarray(ph, dtype=float), cuts)


def find_tracks(x, N, H, first, tol_oct=0.025, min_len=5):
    if _lib is None or fastlib.lib is None:
        return pc.track_peaks(pc.find_peaks_frames(x, N, H, fmax=pc.SR / 2), first_frame=first)
    fc, ac, phc, cuts = _peaks(x, N, H, first)
    F = len(cuts) - 1
    total = int(cuts[-1])
    ids, src, start = (np.empty(max(1, total), dtype=np.int64) for _ in range(3))
    born = fastlib.lib.track_assign(fc.ctypes.data, cuts.ctypes.data, F, first, tol_oct,
                                    ids.ctypes.data, src.ctypes.data, start.ctypes.data)
    assert born >= 0
    if not born:
        return []
    m = int(cuts[-1] - cuts[min(max(first, 0), F)])
    ids, src, start = ids[:m], src[:m], start[:born]
    return pc._cut_tracks(ids, fc[src], ac[src], phc[src], start, born, min_len)


# ---------------------------------------------------------------- quantize

def _median(a):
    """np.median of a 1-D float array without NaN: the middle value, or the
    mean of the two middle ones ((a + b) / 2, as np.mean of two gives)."""
    n = len(a)
    h = n // 2
    if n % 2:
        return float(np.partition(a, h)[h])
    p = np.partition(a, [h - 1, h])
    return float((p[h - 1] + p[h]) / 2.0)


def _f0_track(tracks, meds, f0_nominal, n_frames):
    """pc.estimate_f0_track, each track's median frequency given (meds)."""
    order = sorted(range(len(tracks)), key=lambda i: -(10 ** (tracks[i].a / 10)).sum())[:12]
    strong = [tracks[i] for i in order]
    grid = f0_nominal * 2 ** (np.linspace(-3, 3, 1201) / 12)
    best = f0_nominal
    fms = np.array([meds[i] for i in order])
    ens = np.array([(10 ** (t.a / 10)).sum() for t in strong])
    if len(strong):
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
    for t, m in zip(tracks, meds):
        h = max(1, round(m / best))
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


def quantize(tracks, H, f0, tier):
    """pc.quantize(Channel(.., H, tracks, ..., info={"f0": f0}), tier)'s sine part:
    (info: streams hdr dt df da f0, n_tracks, lock, f0_frames; sizes: track_hdr
    track_dt track_df track_da f0). The decoded tracks, noise, TNS and PCM are
    not made; every number that goes into a stream is made as it makes it.
    None for a tier with a verbatim attack (not the sine layer's)."""
    if tier.pcm_ms > 0:
        return None
    TWO_PI = pc.TWO_PI
    top = max([t.a.max() for t in tracks], default=-200)
    hdr, dts, dfs, das = bytearray(), [], [], []
    prev_start = 0
    f0_bytes = 0
    f0q = None
    fs, nfr = bytearray(), 0
    n_tracks = 0
    lock = tier.harmonic_lock and f0 and tracks
    if lock:
        nfr = max(t.start + len(t.f) for t in tracks) + 1
        f0t = _f0_track(tracks, [_median(t.f) for t in tracks], f0, nfr)
        c0 = 1200 * np.log2(f0t / 20.0)
        k0 = pc.keyframes(c0[:, None], np.array([tier.f0_cents]))
        q0 = np.round(c0[k0] / tier.f0_cents).astype(np.int64)
        fs += pc._ints(np.stack([pc._deltas(k0), pc._deltas(q0)], axis=1))
        f0_bytes = pc._lz(bytes(fs))
        f0q = 20.0 * 2 ** (pc.expand(k0, (q0 * tier.f0_cents).astype(float)[:, None], nfr)[:, 0] / 1200)
    tol = np.array([tier.f_tol, tier.a_tol])
    one = 1 << tier.phase_bits
    floor = max(top + tier.cull_db, tier.floor_db)
    for tr in sorted(tracks, key=lambda t: t.start):
        if tr.a.max() < floor:
            continue
        if tr.start + len(tr.f) <= 0:
            continue
        if f0q is not None:
            ref = f0q[tr.start : tr.start + len(tr.f)]
            hh = max(1, int(round(_median(tr.f / ref))))
            ref = hh * ref
        else:
            hh, ref = 0, np.full(len(tr.f), 20.0)
        cents = 1200 * np.log2(tr.f / ref)
        vals = np.stack([cents, tr.a], axis=1)
        keys = pc.keyframes(vals, tol)
        anchor = 0                                  # min(max(0, jf - start), L - 1), jf = 0
        if keys[0] != 0:
            keys = np.union1d(keys, [anchor])
        qph = int(np.round((tr.ph[anchor] % TWO_PI) / TWO_PI * one)) % one
        qc = pc.steer_keys(cents, ref, tr.ph, keys, 0, qph / one * TWO_PI, H, tier.f_cents, tier.steer, tier.f_tol)
        qa = np.round(tr.a[keys] / tier.a_db).astype(np.int64)
        pc._varint(tr.start - prev_start, hdr); prev_start = tr.start
        pc._varint(len(keys), hdr)
        if f0q is not None:
            pc._varint(hh, hdr)
        pc._varint(qc[0], hdr); pc._varint(qa[0], hdr); hdr.append(qph)
        dts.append(np.diff(keys)); dfs.append(np.diff(qc)); das.append(np.diff(qa))
        n_tracks += 1
    dts, dfs, das = (pc._ints(np.concatenate(v)) if v else b"" for v in (dts, dfs, das))
    sizes = {"track_hdr": pc._lz(bytes(hdr)), "track_dt": pc._lz(bytes(dts)), "track_df": pc._lz(bytes(dfs)),
             "track_da": pc._lz(bytes(das)), "f0": f0_bytes}
    info = {"n_tracks": n_tracks, "lock": f0q is not None, "f0_frames": nfr,
            "streams": {"hdr": bytes(hdr), "dt": bytes(dts), "df": bytes(dfs), "da": bytes(das), "f0": bytes(fs)}}
    return info, sizes


# ------------------------------------------------------------------ render

def _tokens(b):
    """Every varint in b, unsigned (no zigzag), as int64; None if one runs past
    the end or past 56 bits."""
    a = np.frombuffer(bytes(b), dtype=np.uint8)
    if not len(a):
        return np.zeros(0, dtype=np.int64)
    end = a < 128
    if not end[-1]:
        return None
    tid = np.zeros(len(a), dtype=np.int64)
    np.cumsum(end[:-1], out=tid[1:])
    st = np.flatnonzero(np.concatenate([[True], end[:-1]]))
    pos = np.arange(len(a)) - st[tid]
    if pos.max() > 7:
        return None
    v = (a & 0x7F).astype(np.int64) << (7 * pos)
    return np.add.reduceat(v, st)


def _zz(u):
    return (u >> 1) ^ -(u & 1)


def _tracks_flat(code):
    """analysis.tracks_of(code), as the flat arrays synth_tracks hands st_tracks
    (f, a, ph, lens, starts), or None when the streams are not what this reads."""
    I, S = code.ints, code.streams
    ntr, lock, pbits = int(I["n_tracks"]), int(I["lock"]), int(I["pbits"])
    if pbits > 7 or ntr <= 0:
        return None
    f_c, a_d, f0_c = I["f_c"] / 1000, I["a_d"] / 1000, I["f0_c"] / 1000
    nf = 6 if lock else 5
    hu = _tokens(S["hdr"])
    if hu is None or len(hu) != nf * ntr:
        return None
    hu = hu.reshape(ntr, nf)
    hz = _zz(hu)
    starts = np.cumsum(hz[:, 0])
    nk = hz[:, 1]
    hh = hz[:, 2] if lock else None
    qc0, qa0, qph = hz[:, nf - 3], hz[:, nf - 2], hu[:, nf - 1]
    if (nk < 1).any() or (qph >= 128).any():
        return None
    nd = int((nk - 1).sum())
    dts, dfs, das = (_tokens(S[k]) for k in ("dt", "df", "da"))
    if any(t is None or len(t) != nd for t in (dts, dfs, das)):
        return None
    dts, dfs, das = _zz(dts), _zz(dfs), _zz(das)
    # every track's key list: 0, then its steps; qc and qa: the first, then theirs
    kfirst = np.cumsum(nk) - nk                     # where each track's keys start in the flat key arrays
    tr_of = np.repeat(np.arange(ntr), nk)
    is0 = np.zeros(int(nk.sum()), dtype=bool)
    is0[kfirst] = True
    kd = np.zeros(len(is0), dtype=np.int64)
    cd = np.zeros(len(is0), dtype=np.int64)
    ad = np.zeros(len(is0), dtype=np.int64)
    kd[~is0], cd[~is0], ad[~is0] = dts, dfs, das
    cd[is0], ad[is0] = qc0, qa0

    def seg_cumsum(d):
        c = np.cumsum(d)
        return c - (c[kfirst] - d[kfirst])[tr_of]
    keys, qc, qa = seg_cumsum(kd), seg_cumsum(cd), seg_cumsum(ad)
    if (kd[~is0] <= 0).any():
        return None                                 # keys must rise (np.interp's own requirement)
    lens = keys[kfirst + nk - 1] + 1
    off = np.cumsum(lens) - lens                    # each track's first frame in the flat frame arrays
    tot = int(lens.sum())
    fr_tr = np.repeat(np.arange(ntr), lens)
    xi = np.arange(tot)                             # off + arange(L): np.interp sees the same differences
    xp = keys + off[tr_of]
    fc = np.interp(xi, xp, (qc * f_c).astype(float))
    fa = np.interp(xi, xp, (qa * a_d).astype(float))
    if lock:
        k0, q0 = _pairs_np(S["f0"])
        if k0 is None:
            return None
        nfr = int(I["f0_frames"])
        f0q = 20.0 * 2 ** (pc.expand(k0, (q0 * f0_c).astype(float)[:, None], nfr)[:, 0] / 1200)
        idx = starts[fr_tr] + (xi - off[fr_tr])
        if len(idx) and (idx.min() < 0 or idx.max() >= nfr):
            return None
        ref = hh[fr_tr] * f0q[idx]
    else:
        ref = np.full(tot, 20.0)
    f = ref * 2 ** (fc / 1200)
    ph = np.zeros(tot)
    ph[off] = qph / (1 << pbits) * pc.TWO_PI
    return f, fa, ph, lens.astype(np.int64), starts.astype(np.int64)


def _pairs_np(b):
    """pinst_file._pairs: (keys, values), each the running sum of its varints."""
    u = _tokens(b)
    if u is None or len(u) % 2:
        return None, None
    z = _zz(u).reshape(-1, 2)
    return np.cumsum(z[:, 0]), np.cumsum(z[:, 1])


def render(code, n, fallback):
    """The samples analysis.render_sines plays for code (fallback(code, n): the
    legacy path, when this cannot read the streams or has no C)."""
    flat = None if fastlib.lib is None else _tracks_flat(code)
    if flat is None:
        return fallback(code, n)
    f, a, ph, lens, starts = (np.ascontiguousarray(v) for v in flat)
    f, a, ph = (np.ascontiguousarray(v, dtype=float) for v in (f, a, ph))
    H = int(code.ints["H"])
    anc = np.zeros(len(lens), dtype=np.int64)
    out = np.zeros(n + 4 * H)
    assert fastlib.lib.st_tracks(f.ctypes.data, a.ctypes.data, ph.ctypes.data, lens.ctypes.data, starts.ctypes.data,
                                 anc.ctypes.data, len(lens), H, 1, pc.TWO_PI, float(pc.SR), out.ctypes.data, len(out))
    return out[:n]

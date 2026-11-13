"""PINST5 stage: step sizes (owner: agent C).

quantize(X, Xref, M, seed, dial, top, heard) -> LayerCode or None (nothing to store)
dequantize(L) -> (frames, K) coefficients

One dial sets every step.

* Tonal bands keep the wave-0 step: the band's level less `dial` dB.
* A band's own noise hides error under it, so a noise-like band may be coded
  as coarse as `dial` * NOISE_FRAC dB under its level. How noise-like a band
  is: the flatness of its time-smoothed power (geometric over arithmetic mean)
  divided by the flatness white noise measures in the same band. Every dB a
  band sits under noise's flatness gives TONE_SLOPE dB of SNR back, up to the
  dial; a band with fewer than MIN_WID coefficients is too narrow to judge
  and counts as tonal. The measure is taken on the note itself (Xref), not on
  what the sines left, so a band is tonal when the note is tonal there.
  Only bands near their frame's loudest go coarser: a band `dial` dB or more
  under its frame's loudest keeps the dial, rising linearly to the full drop
  at the loudest. A quiet noise band between loud partials keeps its step.
* A band's level for the step is the quieter of its own and the level heard
  there (the source, every channel summed; for a mid/side pair heard_ms_db
  holds the mid + side error under the quieter of left and right, MS_SLACK
  dB over it at most): where the remainder stands over
  the source (the sines overshoot it before an attack), its error is put
  under the source, which keeps that error out of the quiet. Setting every
  step under the source alone was measured and costs 15-30 % more at the same
  accuracy (wave 1 merge).
* The quiet floor is FLOOR_DB under the note's own loudest band (per
  coefficient, top); under that a band stores nothing, at any dial.
* Stereo is chosen per note, not per band (encode._stereo: mid/side as
  summed, mid/side under heard_ms_db, or left/right, each measured). A
  per-band choice was built and measured in wave 1 (it saved at most 0.1 kB
  a note and its shared block plan cost up to 2.2 kB), so it is not used.
* Narrow bands (NARROW_WID coefficients or fewer, the lowest ones) near the
  note's loudest take the step whose actual error meets the dial
  (_narrow_dq), not the one their level stands for.

Each band-frame's step is stored as `dq`: how many 1.5 dB steps its SNR sits
under the dial, so the decoder needs no measure of its own. A band-frame whose
SNR reaches 0 dB codes no coefficients and is refilled from the hash at its own
energy. A coefficient that rounds to zero is refilled from the hash so each
band keeps its energy, never louder than half a step.
"""
from __future__ import annotations

import numpy as np
from scipy.ndimage import convolve1d

import contract as C
import memo
import pinst_codec as pc

NBANDS = 18
NOISE_FRAC = 0.5        # a pure-noise band is coded dial * this under its level
TONE_SLOPE = 3.0        # dB of SNR back per dB a band's flatness sits under noise's
MIN_WID = 8             # bands narrower than this count as tonal
GATE = 1.0              # a band dial * this under its frame's loudest keeps the dial
FLOOR_DB = 80.0         # no band this far under the note's loudest (per coefficient): unheard at any dial
HEARD_FLOOR_DB = 0.0    # _code: heard pulls the error no lower than this under FLOOR_DB's level
SPAN = 2048             # samples each side the band power is smoothed over before flatness
HEARD = 1024            # samples a band's level is averaged over for the frame gate
NARROW_WID = 2          # bands this narrow get the step whose actual error meets the dial
NARROW_TRY = 2          # ... from this many 1.5 dB steps either side of their own
NARROW_SLACK = -3.0     # ... aiming this many dB off the error their own step stands for
NARROW_DB = 20.0        # ... when within this of the note's loudest band (per coefficient)
MS_SLACK = 8.0         # dB mid + side error may stand over the quieter of left and right
_SQ3 = np.sqrt(3.0)
_NOISE = {}
_HASH = {}      # seed -> pc.hash_uniform(seed, 0, n) * _SQ3 for the longest n asked: a counter hash, so any shorter run is its start
_BSNR = memo.Memo(16, 64 << 20)
_HEARD = memo.Memo(16, 64 << 20)


def _hash3(seed, count):
    """pc.hash_uniform(seed, 0, count) * sqrt 3 (read-only)."""
    h = _HASH.get(seed)
    if h is None or len(h) < count:
        have = 0 if h is None else len(h)
        tail = pc.hash_uniform(seed, have, count - have) * _SQ3
        h = tail if h is None else np.concatenate([h, tail])
        h.setflags(write=False)
        _HASH[seed] = h
        if len(_HASH) > 16:
            del _HASH[next(iter(_HASH))]
    return h[:count]


def edges(K, nbands=NBANDS):
    return pc._xf_edges(K, nbands)


_COLS = {}      # band widths -> the band of each coefficient


def _rep(a, wid):
    """np.repeat(a, wid, axis=1) (each band's value over its coefficients), as
    a gather: the same array, made faster."""
    k = (wid.dtype.str, wid.tobytes())
    idx = _COLS.get(k)
    if idx is None:
        idx = _COLS[k] = np.repeat(np.arange(len(wid)), wid)
    return a[:, idx]


def _smooth(P, S):
    if S <= 1:
        return P
    g = np.hanning(S + 2)[1:-1]
    return convolve1d(P, g / g.sum(), axis=0, mode="constant")


def _flatness(X, M, ed):
    """(frames, bands) geometric over arithmetic mean of the time-smoothed power."""
    P = _smooth(X ** 2, 2 * max(1, SPAN // M) + 1) + 1e-30
    wid = np.diff(ed)
    am = np.add.reduceat(P, ed[:-1], axis=1) / wid
    gm = np.exp(np.add.reduceat(np.log(P), ed[:-1], axis=1) / wid)
    return gm / am


def _noise_flatness(M, K):
    """Per band, the flatness white noise measures here (median over frames)."""
    if (M, K) not in _NOISE:
        import transform
        x = np.random.default_rng(12345).standard_normal(max(16 * SPAN, 64 * M))
        X = transform.forward(x, M)[:, :K]
        f = _flatness(X, M, edges(K))
        S = max(1, SPAN // M)
        _NOISE[(M, K)] = np.median(f[2 * S + 2 : -2 * S - 2], axis=0)
    return _NOISE[(M, K)]


def tonality(Xref, M):
    """(frames, bands) flatness over white noise's, clipped to (1e-6, 1]: 1 is
    noise, small is tonal. Narrow bands are 1e-6 (tonal)."""
    F, K = Xref.shape
    ed = edges(K)
    eta = np.clip(_flatness(Xref, M, ed) / _noise_flatness(M, K), 1e-6, 1.0)
    eta[:, np.diff(ed) < MIN_WID] = 1e-6
    return eta


def band_snr(Xref, M, snr):
    """(frames, bands) SNR, dB, each band-frame is coded to (before the floor).
    Read-only: the same Xref again (another coding of the note) shares it."""
    hit, bs = _BSNR.get((Xref,), (M, snr))
    if not hit:
        bs = memo.frozen(_band_snr(Xref, M, snr))
        _BSNR.put((Xref,), (M, snr), bs, bs.nbytes)
    return bs


def _band_snr(Xref, M, snr):
    F, K = Xref.shape
    ed = edges(K)
    bs = np.minimum(snr, snr * NOISE_FRAC - TONE_SLOPE * 10 * np.log10(tonality(Xref, M)))
    P = _smooth(np.add.reduceat(Xref ** 2, ed[:-1], axis=1), HEARD // M)
    lvl = 10 * np.log10(P + 1e-30)
    near = np.clip((lvl - lvl.max(axis=1, keepdims=True)) / (GATE * snr) + 1, 0, 1)
    return snr - (snr - bs) * near


def top_db(Xnote):
    """The note's loudest band (per coefficient, dB) at this block length."""
    return float(pc.band_power_db(Xnote, NBANDS).max())


def _code(X, M, seed, snr, bs, floor, hdb):
    """One layer from coefficients X, each band-frame's error put bs dB (SNR)
    under the quieter of X's own level and hdb, the level heard there (source
    band power per coefficient, dB). hdb pulls the error no lower than floor
    (the note's unheard level): where the heard level falls away (one channel
    silent in a band, a band the source has nothing in that the remainder
    does, heard_ms_db's room where left or right is silent), the step would
    otherwise follow it to nothing (steps 10^-14 of the band's level, codes
    past pack's 31 bits)."""
    F, K = X.shape
    wid = np.diff(edges(K))
    sdb = pc.band_power_db(X, NBANDS)
    live = sdb > floor
    if not live.any():
        return None
    qs = np.round(sdb / 1.5).astype(np.int64)
    dead = int(qs[live].min() - 1)
    sc = np.where(live, qs, dead)
    over = np.minimum(hdb - qs * 1.5, 0)            # where X is louder than what is heard
    over = np.maximum(over, np.minimum(floor - HEARD_FLOOR_DB + bs - qs * 1.5, 0))     # heard pulls the error no lower than floor
    dq = np.where(live, np.round((snr - bs + over) / 1.5), 0).astype(np.int64)
    dq = _narrow_dq(X, sc, live, wid, snr, dq, seed, floor + FLOOR_DB)
    fill = _rep(snr - 1.5 * dq <= 0, wid)
    step = _steps(sc, live, wid, snr, dq)
    q = np.where(_rep(live, wid) & ~fill, np.round(X / step), 0).astype(np.int64)
    return C.LayerCode(M, K, NBANDS, snr, dead, F, seed, sc, q, dq)


def _decoded(X, sc, live, wid, snr, dq, r):
    """What dequantize makes of X coded at these steps (r: the hash, times sqrt 3)."""
    ed = np.concatenate([[0], np.cumsum(wid)])
    sb = _band_steps(sc, live, snr, dq)
    step = _rep(sb, wid)
    q = np.where(_rep(live & (snr - 1.5 * dq > 0), wid), np.round(X / step), 0)
    Xd = q * step
    rms = 10 ** (sc * 1.5 / 20) * live
    lack = np.maximum(rms**2 * wid - np.add.reduceat(Xd**2, ed[:-1], axis=1), 0)
    z = q == 0
    nzero = np.add.reduceat(z.astype(float), ed[:-1], axis=1)
    return Xd + z * _rep(_band_fill(lack, nzero, live, sb), wid) * r


def _band_fill(lack, nzero, live, sb):
    """Per band the fill level: what the zeros make up of the band's missing
    power, no more than a step's rounding error where the band is live. Per
    band then spread (elementwise, so the same as spreading first)."""
    fb = np.sqrt(lack / np.maximum(nzero, 1))
    return np.where(live, np.minimum(fb, sb / np.sqrt(12)), fb)


def _narrow_dq(X, sc, live, wid, snr, dq, seed, top):
    """Narrow bands (NARROW_WID coefficients or fewer) hold too few
    coefficients for rounding error to average out: one coefficient rounds to
    anywhere from 0 to half a step, so the band's SNR is set by where the
    coefficient falls between two codes, not by the step, and whole-note SNR
    moves with the grid. Each narrow band-frame within NARROW_DB of the note's
    loudest tries the steps up to NARROW_TRY 1.5 dB steps either side of its
    own and keeps the one whose actual error, as the decoder makes it (fill
    included), lands nearest (in dB) to NARROW_SLACK dB under the error its
    own step stands for (a twelfth of a step squared per coefficient); ties go
    to the step nearer its own, then the coarser. Quiet narrow bands keep their
    step: a varying dq costs bytes, and there they are not heard."""
    narrow = wid <= NARROW_WID
    if not narrow.any():
        return dq
    nb = int(np.flatnonzero(narrow)[-1]) + 1        # the bands up to the last narrow one
    k = int(wid[:nb].sum())
    F, K = X.shape
    Xn, scn, lvn, wn, d0 = X[:, :k], sc[:, :nb], live[:, :nb], wid[:nb], dq[:, :nb]
    coded = lvn & (snr - 1.5 * d0 > 0) & narrow[None, :nb] & (scn * 1.5 > top - NARROW_DB)
    if not coded.any():
        return dq
    ed = np.concatenate([[0], np.cumsum(wn)])
    r = _hash3(seed, F * K).reshape(F, K)[:, :k]
    want = _steps(scn, lvn, wn, snr, d0)[:, ed[:-1]] ** 2 / 12 * wn * 10 ** (NARROW_SLACK / 10)
    best, bdist = d0.copy(), np.full((F, nb), np.inf)
    for c in sorted(range(-NARROW_TRY, NARROW_TRY + 1), key=lambda c: (abs(c), -c)):
        d = d0 + c
        err = np.add.reduceat((Xn - _decoded(Xn, scn, lvn, wn, snr, d, r)) ** 2, ed[:-1], axis=1)
        dist = np.abs(np.log((err + 1e-300) / want))
        take = coded & (snr - 1.5 * d > 0) & (dist < bdist - 1e-9)
        best = np.where(take, d, best)
        bdist = np.where(take, dist, bdist)
    out = dq.copy()
    out[:, :nb] = np.where(coded, best, d0)
    return out


def quantize(X: np.ndarray, Xref: np.ndarray, M: int, seed: int, dial: float, top: float,
             heard: np.ndarray, tight: np.ndarray | None = None) -> C.LayerCode | None:
    """Xref: the mid on X's own grid (same frames). top: top_db of the whole mid.
    heard: (frames, bands) the level, dB per coefficient on X's grid, each
    step is set under (heard_db, or heard_ms_db for a mid/side pair).
    tight: (frames,) or None, the least SNR (dB) each frame's bands are coded
    to (encode.py's peak rounds; 0 leaves the frame as band_snr has it)."""
    snr = round(dial * 100) / 100
    bs = band_snr(Xref, M, snr)
    if tight is not None:
        bs = np.maximum(bs, tight[:, None])
    return _code(X, M, seed, snr, bs, top - FLOOR_DB, heard)


def _memo_heard(f, Xs):
    Xs = list(Xs)
    hit, h = _HEARD.get(Xs, f.__name__)
    if not hit:
        h = memo.frozen(f(*Xs))
        _HEARD.put(Xs, f.__name__, h, h.nbytes)
    return h


def heard_db(Xs) -> np.ndarray:
    """(frames, bands) dB per coefficient of the summed power of the channels'
    coefficients. Read-only (shared with the same Xs again)."""
    return _memo_heard(_heard_db, Xs)


def heard_ms_db(Xm, Xs) -> np.ndarray:
    return _memo_heard(_heard_ms_db, (Xm, Xs))


def _heard_db(*Xs) -> np.ndarray:
    return 10 * np.log10(sum(10 ** (pc.band_power_db(X, NBANDS) / 10) for X in Xs) + 1e-30)


def _heard_ms_db(Xm, Xs) -> np.ndarray:
    """heard for a mid/side pair (coefficients on one grid): the level H each
    of mid and side is coded under so that their errors, which add in both
    left (M + S) and right (M - S), stay under the quieter of left and right
    (plus MS_SLACK dB): min(PM, H) + min(PS, H) <= min(PL, PR). The summed
    level alone lets a band one side has dipped out of carry the other side's
    error, heard as noise in the dip and as pre-echo before the hit that
    ends it."""
    p = lambda X: 10 ** (pc.band_power_db(X, NBANDS) / 10)
    pm, ps = p(Xm), p(Xs)
    room = np.minimum(p(Xm + Xs), p(Xm - Xs)) * 10 ** (MS_SLACK / 10)
    lo = np.minimum(pm, ps)
    H = np.where(2 * lo >= room, room / 2, room - lo)     # both under H, or only the louder
    return 10 * np.log10(H + 1e-30)


def _band_steps(sc, live, snr, dq):
    rms = 10 ** (sc * 1.5 / 20) * live
    return np.maximum(rms, 1e-30) * 10 ** (-(snr - 1.5 * dq) / 20) * np.sqrt(12)


def _steps(sc, live, wid, snr, dq):
    return _rep(_band_steps(sc, live, snr, dq), wid)


def live_mask(L: C.LayerCode) -> np.ndarray:
    """(frames, K): the coefficients the file stores."""
    return _rep(L.sc != L.dead, np.diff(edges(L.K, L.nbands)))


def coded_mask(L: C.LayerCode) -> np.ndarray:
    """(frames, K): the coefficients with a code; live bands whose SNR reaches
    0 dB are filled from the hash and store none."""
    ok = (L.sc != L.dead) & (L.snr - 1.5 * L.dq > 0)
    return _rep(ok, np.diff(edges(L.K, L.nbands)))


def dequantize(L: C.LayerCode) -> np.ndarray:
    ed = edges(L.K, L.nbands)
    wid = np.diff(ed)
    live = L.sc != L.dead
    rms = 10 ** (L.sc * 1.5 / 20) * live
    sb = _band_steps(L.sc, live, L.snr, L.dq)
    Xd = L.q * _rep(sb, wid)
    lack = np.maximum(rms**2 * wid - np.add.reduceat(Xd**2, ed[:-1], axis=1), 0)
    z = L.q == 0
    nzero = np.add.reduceat(z.astype(float), ed[:-1], axis=1)
    r = _hash3(L.seed, L.frames * L.K).reshape(L.frames, L.K)
    return Xd + z * _rep(_band_fill(lack, nzero, live, sb), wid) * r

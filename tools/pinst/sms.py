"""The generators-only encoder (SMS_PLAN.md): a note channel is the sum of
generators, each tried in the standard's order on what the ones before it
left, taking only what it explains.

Every generator is a module with:

    RANDOM: bool                          True only for noise (seeded render)
    analyse(left, sr, hint) -> settings   what it explains of `left`
    render(settings, n, sr, seed=0) -> np.ndarray of n samples
    pack(settings) -> bytes               its stream, compressed, for sizes

and optionally options(left, sr, hint) -> [settings], several ways to
explain `left`, which run() judges after the generators that follow (_chain).

`hint` is a dict of starting hints that are not instrument knowledge:
"f0" (the file name's pitch or None) and "ref" (the mid channel when this is
the side). A generator may ignore any of them. Generators never read the
source except through `left`.

The deterministic generators come first; noise is last and takes whatever
is left, so it is never subtracted.
"""
from __future__ import annotations

import numpy as np

import need_map as nm
import pinst_codec as pc
import report_card as rc
import gen_noise
import gen_partials

import gen_modes  # noqa: E402
import gen_pulses_mp  # noqa: E402
GENERATORS = [gen_partials, gen_modes, gen_pulses_mp, gen_noise]


class Onset:
    """The note's onset sample, coded once for the note. No deterministic
    generator sounds before it: a frame-based track fades in over the hop
    before its first frame, which lands before the hit (tom4: partials 37 dB
    over the source there), and noise, given what is left, would copy that
    back. Noise is not gated: before the onset it models the source's own
    floor from what is left, which then is the source."""
    RANDOM = False
    __name__ = "onset"

    def __init__(self, sample):
        self.sample = int(sample)

    def pack(self, _s=None):
        out = bytearray()
        pc._varint(self.sample, out)
        return bytes(out)


def _gate(y, on):
    if on > 0:
        y = y.copy()
        y[:on] = 0.0
    return y


def _misses(x, parts, det, sr, ref):
    """Missed band-frames over the whole note on both of the card's grids,
    with the chain's own noise at the card's seeds."""
    noises = noise_renders(parts, len(x), sr, nm.SEEDS)
    m = 0
    for edges in (None, rc.shifted_edges()):
        c = rc.card(x, det, noises, sr, ref=ref, edges=edges)
        m += int(((c["kind"] >= 0) & c["audible"]).sum())
    return m


def _chain(x, sr, hint, ref, gens, parts, det, left, judge):
    """The generators in order on what the ones before left. A generator with
    options(left, sr, hint) offers several settings; while `judge`, each is
    finished by the rest of the chain and the one with the fewest misses
    (_misses) is kept, ties keeping the earlier. Only the first generator
    that offers candidates is judged that way; later ones take their first."""
    n = len(x)
    on = parts[0][0].sample
    for i, g in enumerate(gens):
        h = {**hint, "src": x, "det": det.copy()}
        if hasattr(g, "options"):
            cands = g.options(left, sr, h)
        else:
            cands = [g.analyse(left, sr, h)]
        if judge and len(cands) > 1:
            best = None
            for s in cands:
                d, l = det, left
                if not g.RANDOM:
                    y = _gate(g.render(s, n, sr), on)
                    d, l = det + y, left - y
                r = _chain(x, sr, hint, ref, gens[i + 1:], parts + [(g, s)], d, l, False)
                m = _misses(x, r[0], r[1], sr, ref)
                if best is None or m < best[0]:
                    best = (m, r)
            return best[1]
        s = cands[0]
        parts = parts + [(g, s)]
        if not g.RANDOM:
            y = _gate(g.render(s, n, sr), on)
            det = det + y
            left = left - y
    return parts, det, left


def run(x, sr, hint):
    """Returns (parts, det, left): parts = [(module, settings)], det = the sum
    of the deterministic renders, left = x - det (what the noise was given).
    parts[0] is the note's Onset."""
    n = len(x)
    pc.SR = sr
    x = np.asarray(x, dtype=float)
    on = Onset(pc.onset_sample(x))
    ref = None
    if hint.get("ref") is not None:
        pr, _ = nm.band_stats([np.asarray(hint["ref"], dtype=float)], sr, pc.erb_edges(nm.MODEL.noise_bands))
        ref = float(pr.max())
    return _chain(x, sr, hint, ref, GENERATORS, [(on, None)], np.zeros(n), x.copy(), True)


def _onset(parts):
    return parts[0][0].sample if parts and isinstance(parts[0][0], Onset) else 0


def loop_index(ls, le, length):
    """The note sample each of `length` played samples reads, looped as
    sfizz plays loop_continuous: up to loop_end inclusive, then loop_start."""
    p = np.arange(length)
    span = le - ls + 1
    return np.where(p <= le, p, ls + (p - le - 1) % span)


def render(parts, n, sr, seed, idx=None):
    """The n-sample render, or played along idx (loop_index): each
    generator's render_at reads its levels and frequencies at idx while its
    oscillators and noise reads run on through idx's jumps, so a loop jumps
    the parameters back and nothing else."""
    on = _onset(parts)
    y = np.zeros(n if idx is None else len(idx))
    for g, s in parts:
        if isinstance(g, Onset):
            continue
        if idx is None:
            r = g.render(s, n, sr, seed)
            y += r if g.RANDOM else _gate(r, on)
        else:
            r = g.render_at(s, n, sr, seed, idx)
            y += r if g.RANDOM else np.where(idx < on, 0.0, r)
    return y


def noise_renders(parts, n, sr, seeds):
    """The random generators' output, one per seed (for the report card)."""
    out = []
    for sd in seeds:
        y = np.zeros(n)
        for g, s in parts:
            if getattr(g, "RANDOM", False):
                y += g.render(s, n, sr, sd)
        out.append(y)
    return out


def size(parts):
    return {g.__name__: len(g.pack(s)) for g, s in parts}

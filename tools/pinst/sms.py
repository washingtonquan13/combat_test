"""The generators-only encoder (SMS_PLAN.md): a note channel is the sum of
generators, each tried in the standard's order on what the ones before it
left, taking only what it explains.

Every generator is a module with:

    RANDOM: bool                          True only for noise (seeded render)
    analyse(left, sr, hint) -> settings   what it explains of `left`
    render(settings, n, sr, seed=0) -> np.ndarray of n samples
    pack(settings) -> bytes               its stream, compressed, for sizes

`hint` is a dict of starting hints that are not instrument knowledge:
"f0" (the file name's pitch or None) and "ref" (the mid channel when this is
the side). A generator may ignore any of them. Generators never read the
source except through `left`.

The deterministic generators come first; noise is last and takes whatever
is left, so it is never subtracted.
"""
from __future__ import annotations

import numpy as np

import pinst_codec as pc
import gen_noise
import gen_partials

import gen_modes  # noqa: E402
GENERATORS = [gen_partials, gen_modes, gen_noise]


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


def run(x, sr, hint):
    """Returns (parts, det, left): parts = [(module, settings)], det = the sum
    of the deterministic renders, left = x - det (what the noise was given).
    parts[0] is the note's Onset."""
    n = len(x)
    pc.SR = sr
    on = Onset(pc.onset_sample(np.asarray(x, dtype=float)))
    left = np.asarray(x, dtype=float).copy()
    det = np.zeros(n)
    parts = [(on, None)]
    for g in GENERATORS:
        s = g.analyse(left, sr, {**hint, "src": x, "det": det.copy()})
        parts.append((g, s))
        if not g.RANDOM:
            y = _gate(g.render(s, n, sr), on.sample)
            det += y
            left -= y
    return parts, det, left


def _onset(parts):
    return parts[0][0].sample if parts and isinstance(parts[0][0], Onset) else 0


def render(parts, n, sr, seed):
    on = _onset(parts)
    y = np.zeros(n)
    for g, s in parts:
        if isinstance(g, Onset):
            continue
        r = g.render(s, n, sr, seed)
        y += r if g.RANDOM else _gate(r, on)
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

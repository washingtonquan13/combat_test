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

import gen_noise
import gen_partials

GENERATORS = [gen_partials, gen_noise]


def run(x, sr, hint):
    """Returns (parts, det, left): parts = [(module, settings)], det = the sum
    of the deterministic renders, left = x - det (what the noise was given)."""
    n = len(x)
    left = np.asarray(x, dtype=float).copy()
    det = np.zeros(n)
    parts = []
    for g in GENERATORS:
        s = g.analyse(left, sr, hint)
        parts.append((g, s))
        if not g.RANDOM:
            y = g.render(s, n, sr)
            det += y
            left -= y
    return parts, det, left


def render(parts, n, sr, seed):
    y = np.zeros(n)
    for g, s in parts:
        y += g.render(s, n, sr, seed)
    return y


def noise_renders(parts, n, sr, seeds):
    """The random generators' output, one per seed (for the report card)."""
    out = []
    for sd in seeds:
        y = np.zeros(n)
        for g, s in parts:
            if g.RANDOM:
                y += g.render(s, n, sr, sd)
        out.append(y)
    return out


def size(parts):
    return {g.__name__: len(g.pack(s)) for g, s in parts}

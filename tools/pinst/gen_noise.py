"""Generator 4: band noise (stage 0 form: 40 ERB bands, 512-sample hop,
5-frame power smoothing, the players' hash noise).

Stage 2 replaces the envelope with a level per band every 128 samples."""
from __future__ import annotations

import numpy as np
from scipy.ndimage import uniform_filter1d

import need_map as nm
import pinst_codec as pc

RANDOM = True
TIER = nm.MODEL


def analyse(left, sr, hint):
    pc.SR = sr
    t = TIER
    edges = pc.erb_edges(t.noise_bands)
    ndb = pc._band_db(left, t.noise_H, edges)
    if t.noise_smooth > 1:
        ndb = 10 * np.log10(np.maximum(uniform_filter1d(10 ** (ndb / 10), t.noise_smooth, axis=0, mode="nearest"), 0.0) + 1e-20)
    ndb = np.where(ndb < ndb.max() + t.noise_floor, -200.0, ndb)
    stream, db = pc.quantize_noise(ndb, t)
    return {"db": db, "stream": stream, "edges": edges}


def render(s, n, sr, seed=0):
    pc.SR = sr
    return pc.hash_noise(s["db"], n, s["edges"], seed)


def pack(s):
    return pc.lz_bytes(s["stream"])

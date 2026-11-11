"""Generator 1: partials (stage 0 form, PINST3's tracker and coder).

Stage 3 replaces this with partials that follow pitch from the audio."""
from __future__ import annotations

import need_map as nm
import pinst_codec as pc

RANDOM = False
TIER = nm.MODEL


def analyse(left, sr, hint):
    pc.SR = sr
    f0 = hint.get("f0")
    ch = pc.analyse(left, f0 is not None, f0, TIER)
    ch.tns = None
    dec, _ = pc.quantize(ch, TIER)
    return dec


def render(dec, n, sr, seed=0):
    pc.SR = sr
    return pc.synth_tracks(dec.tracks, n, dec.H, mode="integrate", anchors=dec.info["anchors"], gate_from=0)


def pack(dec):
    st = dec.info["streams"]
    return b"".join(pc.lz_bytes(st[k]) for k in ("hdr", "dt", "df", "da", "f0"))

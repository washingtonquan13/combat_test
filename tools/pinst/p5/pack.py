"""PINST5 stage: the file (owner: agent D).

pack(NoteCode) -> bytes;  unpack(bytes) -> NoteCode

Layout (frozen only at the end of the plan):
    "PIN5", varints: version, sample rate, n, stereo, channel count
    then sections, each: 4-byte tag, varint payload length, payload
      SINE  varint channel, the SineCode ints (analysis.INT_KEYS), then each
            stream (analysis.STREAM_KEYS) as varint length + LZMA; dt df da
            are stored in frame order (pinst_file._reorder), which packs smaller
      LAYR  varint channel, M, K, nbands, snr*100, dead, frames, seed, then
            the scale codes (deltas over frames) and the live coefficients,
            each as varint length + LZMA
A reader skips tags it does not know.
"""
from __future__ import annotations

import numpy as np

import analysis
import contract as C
import pinst_codec as pc
import pinst_file as pf
import quant


def _put(out, *vals):
    for v in vals:
        pc._varint(int(v), out)


def _stream(out, b):
    z = pc.lz_bytes(b) if b else b""
    _put(out, len(z))
    out += z


def _section(out, tag, payload):
    out += tag
    _put(out, len(payload))
    out += payload


def pack(note: C.NoteCode) -> bytes:
    out = bytearray(C.MAGIC)
    _put(out, C.VERSION, note.sr, note.n, note.stereo, len(note.channels))
    for ci, ch in enumerate(note.channels):
        if ch.sines is not None:
            I, S = ch.sines.ints, ch.sines.streams
            p = bytearray()
            _put(p, ci, *(I[k] for k in analysis.INT_KEYS))
            dt, df, da = pf._reorder(S["hdr"], S["dt"], S["df"], S["da"], I["lock"], I["n_tracks"], to_frames=True)
            for b in (S["hdr"], dt, df, da, S["f0"]):
                _stream(p, b)
            _section(out, b"SINE", p)
        for L in ch.layers:
            p = bytearray()
            _put(p, ci, L.M, L.K, L.nbands, round(L.snr * 100), L.dead, L.frames, L.seed)
            d = L.sc.copy()
            d[1:] -= L.sc[:-1]
            _stream(p, pc._ints(d))
            _stream(p, pc._ints(L.q[quant.live_mask(L)]))
            _section(out, b"LAYR", p)
    return bytes(out)


def unpack(data: bytes) -> C.NoteCode:
    assert data[:4] == C.MAGIC, "not a PINST5 file"
    c = pf.Cur(data)
    c.i = 4
    ver, sr, n, stereo, nch = (c.v() for _ in range(5))
    assert ver == C.VERSION, f"PINST5 version {ver}"
    note = C.NoteCode(sr, n, stereo, [C.ChannelCode() for _ in range(nch)])
    while c.left():
        tag = bytes(c.take(4))
        body = pf.Cur(bytes(c.take(c.v())))
        if tag == b"SINE":
            ci = body.v()
            I = {k: body.v() for k in analysis.INT_KEYS}
            hdr, dt, df, da, f0 = (pf._unlz(bytes(body.take(body.v()))) for _ in range(5))
            dt, df, da = pf._reorder(hdr, dt, df, da, I["lock"], I["n_tracks"], to_frames=False)
            note.channels[ci].sines = C.SineCode(I, dict(zip(analysis.STREAM_KEYS, (hdr, dt, df, da, f0))))
        elif tag == b"LAYR":
            ci, M, K, nb, snr, dead, F, seed = (body.v() for _ in range(8))
            nbx = len(quant.edges(K, nb)) - 1
            sc = np.cumsum(pf._ints(pf._unlz(bytes(body.take(body.v()))), F * nbx).reshape(F, nbx), axis=0)
            L = C.LayerCode(M, K, nb, snr / 100, dead, F, seed, sc, np.zeros((F, K), dtype=np.int64))
            live = quant.live_mask(L)
            L.q[live] = pf._ints(pf._unlz(bytes(body.take(body.v()))), int(live.sum()))
            note.channels[ci].layers.append(L)
    return note

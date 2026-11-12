"""The generators-only note file (SMS_PLAN.md), PINST4.

    "PINST4"  varint sr, n, channel count
    per channel: varint length, then the channel (length 0: silent)

A channel: varint onset sample, varint noise seed, then one varint length
and its bytes per generator, in sms.GENERATORS order (length 0: the
generator is not used). Each generator's bytes are its own pack(); its
unpack() reads them back. Every number a generator needs that is not in
its bytes is one of its module constants, the same for every note.

Two channels are mid and side (pinst_encode.channels_of): left = mid + side,
right = mid - side. One channel is mono.

All varints are pinst_codec._varint's (zigzag).
"""
from __future__ import annotations

import numpy as np

import pinst_codec as pc
import sms

MAGIC = b"PINST4"


def pack(sr, n, channels):
    """channels: per channel (parts from sms.run, seed), or None for silence."""
    out = bytearray(MAGIC)
    for v in (sr, n, len(channels)):
        pc._varint(v, out)
    for ch in channels:
        b = bytearray()
        if ch is not None:
            parts, seed = ch
            by = {g.__name__: (g, s) for g, s in parts}
            pc._varint(sms._onset(parts), b)
            pc._varint(seed, b)
            for g in sms.GENERATORS:
                z = g.pack(by[g.__name__][1]) if g.__name__ in by else b""
                pc._varint(len(z), b)
                b += z
        pc._varint(len(b), out)
        out += b
    return bytes(out)


class _Cur:
    def __init__(self, b, i=0):
        self.b, self.i = b, i

    def v(self):
        x = s = 0
        while True:
            c = self.b[self.i]
            self.i += 1
            x |= (c & 0x7F) << s
            s += 7
            if not c & 0x80:
                return (x >> 1) ^ -(x & 1)

    def take(self, k):
        self.i += k
        return self.b[self.i - k : self.i]


def unpack(data):
    """-> (sr, n, channels), channels as pack() takes them."""
    assert data[:6] == MAGIC, data[:6]
    c = _Cur(data, 6)
    sr, n, nch = c.v(), c.v(), c.v()
    chans = []
    for _ in range(nch):
        b = c.take(c.v())
        if not b:
            chans.append(None)
            continue
        cc = _Cur(b)
        parts = [(sms.Onset(cc.v()), None)]
        seed = cc.v()
        for g in sms.GENERATORS:
            z = bytes(cc.take(cc.v()))
            if z:
                parts.append((g, g.unpack(z)))
        assert cc.i == len(b)
        chans.append((parts, seed))
    assert c.i == len(data)
    return sr, n, chans


def render(data, loop=None, length=None):
    """A note file -> (samples (n, channels) as the source was laid out, sr).
    loop=(loop_start, loop_end) plays it looped for `length` samples, as a
    player must (sms.render with sms.loop_index)."""
    sr, n, chans = unpack(data)
    pc.SR = sr
    idx = None if loop is None else sms.loop_index(loop[0], loop[1], length)
    m = n if idx is None else len(idx)
    ys = [np.zeros(m) if ch is None else sms.render(ch[0], n, sr, ch[1], idx) for ch in chans]
    if len(ys) == 1:
        return ys[0][:, None], sr
    return np.stack([ys[0] + ys[1], ys[0] - ys[1]], axis=1), sr

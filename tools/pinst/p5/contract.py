"""PINST5: what the stage files hand each other (AGENT_PLAN.md, wave 0).

Owned by the integrator. A stage that needs a change here says so in its
report and does not make it.

Encoder, per channel (encode.py):

    sines = analysis.encode_sines(x, f0)            -> SineCode or None
    det   = analysis.render_sines(sines, n)         (decoded from the code itself)
    e     = x - det
    for M, w, s in blocks.plan(e, ref):             (pieces that sum to 1 over time, w zero before s)
        X  = transform.forward(e * w, M, s)         (frames, M) coefficients, grid from sample s
        Xr = transform.forward(ref, M, s)[:frames]  the mid on X's grid (zero-padded to X's frames)
        top = quant.top_db(transform.forward(ref, M))   the whole mid's loudest band: the floor
        heard = quant.heard_db([every channel on X's grid])   the source level the steps sit under
        L  = quant.quantize(X, Xr, M, seed, DIAL, top, heard) -> LayerCode or None;  L.start = s
    bytes = pack.pack(NoteCode)

Decoder (decode.py), the one source F ports to C:

    note = pack.unpack(bytes)
    per channel: analysis.render_sines(...) + sum(transform.inverse(quant.dequantize(L), n, L.M, L.start))
    stereo == 1: left = mid + side, right = mid - side
    stereo == 2: the two channels are left and right as they are (wave 2: chosen per note)

Every stage keeps both halves of its own work (encode and decode) in its one
file, so the encoder always subtracts exactly what the decoder plays.
"""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
LEGACY = os.path.dirname(HERE)          # tools/pinst: pinst_codec, pinst_file, read-only
if LEGACY not in sys.path:
    sys.path.insert(0, LEGACY)

import pinst_codec as pc        # noqa: E402

MAGIC = b"PIN5"
VERSION = 1         # 1: wave 1 (range-coded LAYR with dq)
DIAL = 25.0         # the one quality setting: dB of signal over quantization error per band


def set_rate(sr: int):
    """pc.SR is a module global the legacy helpers read; every note sets it."""
    pc.SR = int(sr)


@dataclass
class SineCode:
    """The sine layer of one channel, as analysis.py stores it. ints: small
    integers the decoder needs; streams: byte strings pack.py compresses."""
    ints: dict
    streams: dict


@dataclass
class LayerCode:
    """One MDCT layer of one channel. sc: (frames, bands) scale codes, 1.5 dB
    steps, `dead` where a band carries nothing. q: (frames, K) coefficient
    codes, zero outside live bands. seed: the hash that fills zeros.
    dq: (frames, bands) how many 1.5 dB steps each band's SNR sits under snr
    (quant.py sets it; 0 everywhere is wave 0's step)."""
    M: int
    K: int
    nbands: int
    snr: float
    dead: int
    frames: int
    seed: int
    sc: np.ndarray
    q: np.ndarray
    dq: np.ndarray
    start: int = 0                  # the sample the layer's grid starts on; it plays nothing before


@dataclass
class ChannelCode:
    sines: SineCode | None = None
    layers: list = field(default_factory=list)


@dataclass
class NoteCode:
    sr: int
    n: int
    stereo: int                     # 0 mono, 1 mid/side, 2 left/right
    channels: list                  # ChannelCode, mid first

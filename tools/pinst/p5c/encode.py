"""PINST5 encoder, the C port: one note -> bytes. Same call as frozen p5/encode.py
(2f6c9a8); the work is in p5c.dll (encode.c, built by build.bat p5c.dll).

  python -I -B encode.py in.wav out.pinst5 [f0_hz]

LZMA is the one thing the DLL does not do: it calls back into
pinst_codec.lz_bytes, imported from this repository's tools/pinst (the file
the frozen reference holds unchanged). DIAL is p5/contract.py's, also from
this repository. P5C_DLL in the environment names another build of the DLL
(e.g. one built with P5_SINE_RENDER_EXACT); unset, it is p5c.dll beside this file.
"""
from __future__ import annotations

import ctypes as ct
import importlib.util
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PINST = os.path.dirname(HERE)           # tools/pinst: pinst_codec
if PINST not in sys.path:
    sys.path.append(PINST)
import pinst_codec as pc  # noqa: E402


def _load_contract():
    spec = importlib.util.spec_from_file_location("p5_contract", os.path.join(PINST, "p5", "contract.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["p5_contract"] = mod        # its dataclasses look themselves up there
    spec.loader.exec_module(mod)
    return mod


C = _load_contract()

i64, f64 = ct.c_int64, ct.c_double


class _Buf(ct.Structure):
    _fields_ = [("p", ct.POINTER(ct.c_uint8)), ("n", i64)]


class _Debug(ct.Structure):
    _fields_ = [("ncand", ct.c_int), ("k", ct.c_int), ("rounds", ct.c_int), ("n", i64), ("nout", i64),
                ("cand", _Buf * 3), ("ycand", ct.POINTER(f64) * 3), ("y", ct.POINTER(f64)),
                ("layers_packed", i64), ("layers_coded", i64)]


_LZ = ct.CFUNCTYPE(i64, ct.c_void_p, ct.POINTER(ct.c_uint8), i64, ct.POINTER(ct.c_uint8), i64)


@_LZ
def _lz_cb(ctx, inp, n, out, cap):
    try:
        z = pc.lz_bytes(ct.string_at(inp, n))
        if out and cap >= len(z):
            ct.memmove(out, z, len(z))
        return len(z)
    except BaseException:       # noqa: BLE001 - an exception must not cross the C frames
        return -1


_lib = ct.CDLL(os.environ.get("P5C_DLL") or os.path.join(HERE, "p5c.dll"))
_ARGS = [ct.POINTER(f64), i64, i64, i64, f64, f64, _LZ, ct.c_void_p, ct.POINTER(_Buf)]
_lib.p5c_encode_note.restype = ct.c_int
_lib.p5c_encode_note.argtypes = _ARGS
_lib.p5c_encode_debug.restype = ct.c_int
_lib.p5c_encode_debug.argtypes = _ARGS + [ct.POINTER(_Debug)]
_lib.p5c_buf_free.argtypes = [ct.POINTER(_Buf)]
_lib.p5c_debug_free.argtypes = [ct.POINTER(_Debug)]
_lib.p5c_sine_render_fast.restype = ct.c_int
FAST_RENDER = bool(_lib.p5c_sine_render_fast())


def _args(x, sr, f0, dial):
    x = np.ascontiguousarray(x, dtype=np.float64)
    if x.ndim == 1:
        x = x[:, None]
    hint = float("nan") if f0 is None else float(f0)
    return x, (x.ctypes.data_as(ct.POINTER(f64)), x.shape[0], x.shape[1], int(sr), hint, float(dial), _lz_cb, None)


def encode_note(x: np.ndarray, sr: int, f0: float | None, dial: float = C.DIAL) -> bytes:
    """x: (n, 1 or 2) float. f0: a pitch hint in Hz, or None."""
    x, a = _args(x, sr, f0, dial)
    out = _Buf()
    rc = _lib.p5c_encode_note(*a, ct.byref(out))
    if rc != 0:
        raise RuntimeError(f"p5c_encode_note failed: {rc}")
    try:
        return ct.string_at(out.p, out.n)
    finally:
        _lib.p5c_buf_free(ct.byref(out))


def encode_debug(x: np.ndarray, sr: int, f0: float | None, dial: float = C.DIAL):
    """-> (bytes, {k, rounds, cands: [bytes], ycands: [(n, nout) array], y: (n, nout)}),
    the y's being the encoder's in-memory decodes (tests)."""
    x, a = _args(x, sr, f0, dial)
    out, d = _Buf(), _Debug()
    rc = _lib.p5c_encode_debug(*a, ct.byref(out), ct.byref(d))
    if rc != 0:
        raise RuntimeError(f"p5c_encode_debug failed: {rc}")
    try:
        shp = (d.n, d.nout)
        arr = lambda p: np.ctypeslib.as_array(p, shape=shp).copy()  # noqa: E731
        info = {"k": d.k, "rounds": d.rounds, "ncand": d.ncand,
                "layers_packed": d.layers_packed, "layers_coded": d.layers_coded,
                "cands": [ct.string_at(d.cand[i].p, d.cand[i].n) for i in range(d.ncand)],
                "ycands": [arr(d.ycand[i]) for i in range(d.ncand)], "y": arr(d.y)}
        return ct.string_at(out.p, out.n), info
    finally:
        _lib.p5c_buf_free(ct.byref(out))
        _lib.p5c_debug_free(ct.byref(d))


if __name__ == "__main__":
    import soundfile as sf
    x, sr = sf.read(sys.argv[1], always_2d=True)
    data = encode_note(x, sr, float(sys.argv[3]) if len(sys.argv) > 3 else None)
    open(sys.argv[2], "wb").write(data)

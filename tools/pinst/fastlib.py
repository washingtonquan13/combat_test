"""native/pinst_fast.dll (native/build.bat makes it): inner loops of the
baker in C, the same numbers many times faster. `lib` is None when the DLL
is not built, and every caller then runs its numpy version."""
import ctypes
import os


def _load():
    try:
        lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "native", "pinst_fast.dll"))
    except OSError:
        return None
    d, p, i64, i = ctypes.c_double, ctypes.c_void_p, ctypes.c_int64, ctypes.c_int
    for name, res, args in (
        ("comp_env", None, [p, p, i64, d, d]),
        ("disto_stages", None, [p, p, i64, i, d, d, d, d, d, d, p, p]),
        ("disto_os", None, [p, p, i64, p, p, i, d, d, d, d, d, d, p]),
        ("np_sum", d, [p, i64]),
        ("keyframes", i64, [p, i64, i, p, i64, p]),
        ("steer_keys", i, [p, p, p, p, i64, i64, d, d, d, d, d, d, d, p]),
    ):
        f = getattr(lib, name)
        f.restype, f.argtypes = res, args
    return lib


lib = _load()

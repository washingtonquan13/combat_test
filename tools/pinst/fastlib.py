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
        ("st_phase", None, [p, p, p, p, i64, i, p, p, p, p]),
        ("st_acc", None, [p, p, p, p, i64, i, p, p, i64]),
        ("mr_absdiff", d, [p, i64, d, p, p, d]), ("mr_logmag", None, [p, i64, d, p]),
        ("comp_stereo", None, [p, p, i64, d, d, d, d]), ("metric_exp", None, [p, i64]),
        ("st_tracks", i, [p, p, p, p, p, p, i64, i, i, d, d, p, i64]),
        ("track_assign", i64, [p, p, i64, i64, d, p, p, p]),
        ("mel_rows", d, [p, i64, i64, d, i, p, p, p, p, p, p, p]),
    ):
        f = getattr(lib, name)
        f.restype, f.argtypes = res, args
    return lib


lib = _load()


_keep = []


def recycle_big_arrays():
    """Make numpy take its big arrays from memfast.c, which keeps freed ones
    for the next asker instead of handing them back to Windows. Same numbers;
    a long-running baker stops paying for fresh pages. Returns whether it is on."""
    if lib is None or _keep:
        return bool(_keep)
    try:
        import numpy as np
        from numpy._core import multiarray as ma
        api = ctypes.pythonapi
        api.PyCapsule_GetPointer.restype, api.PyCapsule_GetPointer.argtypes = ctypes.c_void_p, [ctypes.py_object, ctypes.c_char_p]
        api.PyCapsule_New.restype, api.PyCapsule_New.argtypes = ctypes.py_object, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p]
        table = ctypes.cast(api.PyCapsule_GetPointer(ma._ARRAY_API, None), ctypes.POINTER(ctypes.c_void_p))
        set_handler = ctypes.PYFUNCTYPE(ctypes.py_object, ctypes.py_object)(table[304])     # PyDataMem_SetHandler
        name = b"mem_handler"
        cap = api.PyCapsule_New(ctypes.addressof(ctypes.c_char.in_dll(lib, "mem_handler")), name, None)
        _keep.extend([name, cap, set_handler(cap)])
        assert ma.get_handler_name() == "pinst_recycle"
    except Exception:
        return False
    return True

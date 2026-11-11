"""Compare the native renderer with the Python block player.

  python -I tools/pinst/native_check.py FILES_DIR PINST_RENDER_EXE

FILES_DIR holds <note>/<tier>.pinst as pinst_file.py writes them. Each note
is stored unpacked, rendered by both, and the largest sample difference and
the native render time are printed.
"""
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pinst_file as pf  # noqa: E402
import pinst_stream as ps  # noqa: E402


def check(job):
    path, exe = job
    data = open(path, "rb").read()
    stored = path[:-6] + "_stored.pinst"
    open(stored, "wb").write(pf.repack(data, False))
    raw = stored[:-6] + ".f64"
    msg = subprocess.run([exe, stored, raw, "5"], capture_output=True, text=True)
    if msg.returncode:
        return path, None, msg.stderr.strip()
    y = np.fromfile(raw, dtype=np.float64).reshape(-1, 2)
    v = ps.Voice(data)
    ref = v.render(v.n)
    return path, float(np.abs(y - ref).max()), msg.stdout.strip()


if __name__ == "__main__":
    os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
    from concurrent.futures import ProcessPoolExecutor
    root, exe = sys.argv[1], sys.argv[2]
    jobs = [(os.path.join(root, d, f), exe) for d in sorted(os.listdir(root))
            for f in ("mid.pinst", "body.pinst") if os.path.exists(os.path.join(root, d, f))]
    with ProcessPoolExecutor(4) as ex:
        for path, diff, msg in ex.map(check, jobs):
            name = os.path.relpath(path, root).replace("\\", "/")
            print(f"{name:32s} {'FAILED' if diff is None else f'{diff:.1e}'}   {msg}")

"""The reference renders a native player must match (SMS_PLAN.md stage 8).

    python -I tools/pinst/make_reference.py [OUT]
    python -I tools/pinst/make_reference.py --check DIR [OUT]

Renders every note in reference/notes/ with sms_file.render (the Python
reference), and the looped notes in LOOPS a second time, played looped as a
player must loop them: loop_end inclusive, then loop_start; levels and
frequencies jump back, oscillator phases and noise reads run on (sms.render).

OUT (default reference/render, not in git) gets per render a raw file of
little-endian float32 frames, channels interleaved, left then right for a
stereo note: <note>.f32, and <note>.loop.f32 for the looped play. index.json
lists them: note file, sr, channels, frames, loop, peak.

--check DIR reads a native player's renders from DIR, the same names and
layout, and prints per render the largest difference as dB under the
reference's peak. Every render must be at least TOL_DB under (float32 output
and per-sample phase rounding sit far below that).
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sms_file  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
NOTES = os.path.join(HERE, "reference", "notes")
TOL_DB = 80.0
# note -> (loop_start, loop_end), the SFZ's own (HamOrg (Free Version).sfz);
# played to loop_end, then the loop LOOP_TIMES more times
LOOPS = {"hamorg_drawbar_1-01": (19913, 55157), "hamorg_drawbar_5-57": (96192, 125786)}
LOOP_TIMES = 3


def renders():
    for f in sorted(os.listdir(NOTES)):
        if not f.endswith(".pinst"):
            continue
        name = f[:-6]
        data = open(os.path.join(NOTES, f), "rb").read()
        yield name, f, None, data
        if name in LOOPS:
            yield name + ".loop", f, LOOPS[name], data


def main():
    args = sys.argv[1:]
    check = None
    if args and args[0] == "--check":
        check, args = args[1], args[2:]
    out = args[0] if args else os.path.join(HERE, "reference", "render")
    os.makedirs(out, exist_ok=True)
    index, bad = [], 0
    for name, f, loop, data in renders():
        if loop is None:
            y, sr = sms_file.render(data)
        else:
            ls, le = loop
            y, sr = sms_file.render(data, loop, le + 1 + LOOP_TIMES * (le - ls + 1))
        y = y.astype("<f4")
        peak = float(np.abs(y).max())
        y.tofile(os.path.join(out, name + ".f32"))
        index.append({"render": name + ".f32", "note": f, "sr": sr, "channels": y.shape[1],
                      "frames": len(y), "loop": loop, "peak": peak})
        if check is None:
            print(f"{name:28s} {y.shape[1]} ch {len(y):8d} frames  peak {peak:.3f}", flush=True)
            continue
        p = os.path.join(check, name + ".f32")
        if not os.path.exists(p):
            print(f"{name:28s} MISSING", flush=True)
            bad += 1
            continue
        z = np.fromfile(p, "<f4")
        if z.size != y.size:
            print(f"{name:28s} WRONG LENGTH {z.size // y.shape[1]} frames, want {len(y)}", flush=True)
            bad += 1
            continue
        err = float(np.abs(z.reshape(y.shape).astype(float) - y).max())
        db = 20 * np.log10(max(err, 1e-30) / max(peak, 1e-30))
        ok = db <= -TOL_DB
        bad += not ok
        print(f"{name:28s} {db:7.1f} dB under peak  {'ok' if ok else 'FAIL'}", flush=True)
    with open(os.path.join(out, "index.json"), "w", encoding="utf-8") as fh:
        json.dump(index, fh, indent=1)
    if check is not None:
        print(f"{len(index) - bad}/{len(index)} within {TOL_DB:.0f} dB")
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

"""Bake every sample an SFZ uses into .pinst5 notes, skipping what is unchanged,
and write the same SFZ pointing at them.

  python -I -B bake.py FILE.sfz OUT_ROOT [--lib DIR] [--pitch name|key|none]
      [--every N] [--jobs N] [--only TEXT] [--files LIST] [--dial D] [--force]
      [--no-sfz]

Same shape as tools/pinst/bake_library.py (read for the full story): OUT_ROOT
mirrors the library folder (--lib, default the folder above the SFZ's own);
every note lands at its sample's path with .pinst5 for the extension; the SFZ
and its #includes are read as sfizz reads them (inventory.Scan) and rewritten
under OUT_ROOT naming a note wherever one exists. --pitch is only a hint to
encode.encode_note (name: from the file name; key: from pitch_keycenter; none).
--jobs defaults to 2.

Skipping: OUT_ROOT/bake.manifest.jsonl holds one row per baked sample (last
row wins): source path, source size and mtime, pitch hint, encoder version,
bytes. A sample is skipped when its note exists and its row matches all of
those. The encoder version is a hash of every p5 stage source (every .py here
except bake.py and bench.py, plus native/*.c), the legacy modules the stages
import (pinst_codec.py, fastlib.py), contract.VERSION and the dial; change
any of them and the whole library bakes again. --force bakes everything.
"""
from __future__ import annotations

import os

for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import collections
import glob
import hashlib
import json
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LEGACY = os.path.dirname(HERE)
for _p in (HERE, LEGACY):
    if _p not in sys.path:      # python -I leaves the script's folder out
        sys.path.insert(0, _p)

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402

import inventory  # noqa: E402

EXT = ".pinst5"
MANIFEST = "bake.manifest.jsonl"
NOT_ENCODER = {"bake.py", "bench.py"}


def encoder_version(dial: float) -> str:
    import contract
    h = hashlib.sha1()
    files = sorted(p for p in glob.glob(os.path.join(HERE, "*.py")) if os.path.basename(p) not in NOT_ENCODER)
    files += sorted(glob.glob(os.path.join(HERE, "native", "*.c")) + glob.glob(os.path.join(HERE, "native", "*.h")))
    files += [os.path.join(LEGACY, n) for n in ("pinst_codec.py", "fastlib.py")]
    for p in files:
        if os.path.exists(p):
            h.update(os.path.basename(p).encode())
            h.update(open(p, "rb").read())
    h.update(f"|v{contract.VERSION}|dial{dial!r}".encode())
    return h.hexdigest()[:16]


def do_file(job):
    written, src, dst, hz, dial = job
    import contract
    import encode
    t0 = time.time()
    x, sr = sf.read(src, always_2d=True)
    if len(x) < 4096:   # a stub is padded with silence, as bake_library does
        x = np.concatenate([x, np.zeros((4096 - len(x), x.shape[1]))])
    nm = inventory.note_of(src)
    f0 = hz if hz != "name" else (inventory.note_hz(nm) if nm else None)
    data = encode.encode_note(x, sr, f0, dial)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst + ".part", "wb") as f:
        f.write(data)
    os.replace(dst + ".part", dst)      # a stopped run never leaves half a note behind
    st = os.stat(src)
    return {"sample": written, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "hz": hz if isinstance(hz, str) else (None if hz is None else round(hz, 4)),
            "seconds": round(len(x) / sr, 3), "sr": sr, "channels": x.shape[1], "note": nm, "wav_bytes": st.st_size,
            "bytes": len(data), "bake_s": round(time.time() - t0, 2)}


def main():
    from concurrent.futures import ProcessPoolExecutor, as_completed
    import contract
    sfz, root = sys.argv[1], sys.argv[2]
    arg = lambda k: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else None
    every, only = int(arg("--every") or 1), arg("--only")
    listed = None
    if arg("--files"):
        listed = {os.path.normcase(os.path.abspath(l.strip())) for l in open(arg("--files"), encoding="utf-8") if l.strip()}
    pitch = arg("--pitch") or "name"
    assert pitch in ("name", "key", "none"), pitch
    dial = float(arg("--dial") or contract.DIAL)
    force = "--force" in sys.argv
    ver = encoder_version(dial)
    scan = inventory.Scan(sfz)
    lib = os.path.abspath(arg("--lib") or os.path.dirname(os.path.dirname(os.path.abspath(sfz))))
    mirror = lambda full: os.path.normpath(os.path.join(root, os.path.relpath(full, lib)))
    for full in scan.files + [f for _, f, _ in scan.regions]:
        assert not os.path.relpath(full, lib).startswith(".."), f"{full} is outside {lib}"
    note_path = lambda full: os.path.splitext(mirror(full))[0] + EXT
    os.makedirs(root, exist_ok=True)
    seen, keys = {}, {}
    for w, full, k in scan.regions:     # a file once, by the name it is first written as
        if os.path.normcase(full) not in keys:
            seen[w if w not in seen else os.path.relpath(full, lib)] = full
        keys.setdefault(os.path.normcase(full), k)

    def hz_of(full):
        if pitch == "none":
            return None
        if pitch == "name" or inventory.note_of(full):
            return "name"
        k = keys.get(os.path.normcase(full))
        return None if k is None else 440.0 * 2 ** ((k - 69) / 12)

    mpath = os.path.join(root, MANIFEST)
    rows = {}
    if os.path.exists(mpath):
        for l in open(mpath, encoding="utf-8"):
            if l.strip():
                r = json.loads(l)
                rows[r["sample"]] = r
    jobs, dsts, skipped = [], {}, 0
    for i, (w, src) in enumerate(sorted(seen.items())):
        dst = note_path(src)
        first = dsts.setdefault(os.path.normcase(dst), w)    # two spellings of one file bake once
        if not os.path.exists(src):
            print(f"MISSING {w}", flush=True)
            continue
        if i % every or first != w or (only and only not in w):
            continue
        if listed is not None and os.path.normcase(os.path.abspath(src)) not in listed:
            continue
        hz = hz_of(src)
        r = rows.get(w)
        if not force and r and os.path.exists(dst) and r.get("ver") == ver:
            st = os.stat(src)
            hz_now = hz if isinstance(hz, str) else (None if hz is None else round(hz, 4))
            if r["size"] == st.st_size and r["mtime_ns"] == st.st_mtime_ns and r.get("hz") == hz_now:
                skipped += 1
                continue
        jobs.append((w, src, dst, hz, dial))
    jobs.sort(key=lambda j: -os.path.getsize(j[1]))     # longest first
    print(f"encoder {ver}: {len(jobs)} files to bake, {skipped} unchanged", flush=True)
    t0, n, bad = time.time(), 0, 0
    workers = int(arg("--jobs") or 2)
    if jobs:
        with ProcessPoolExecutor(workers) as ex, open(mpath, "a", encoding="utf-8") as lf:
            futs = {ex.submit(do_file, j): j[0] for j in jobs}
            for fut in as_completed(futs):
                n += 1
                try:
                    row = fut.result()
                except Exception as e:      # one bad file must not cost the run; it stays undone and is retried
                    bad += 1
                    print(f"FAILED {futs[fut]}: {e!r}", flush=True)
                    continue
                row["ver"] = ver
                lf.write(json.dumps(row) + "\n")
                lf.flush()
                if n % 50 == 0 or n == len(jobs):
                    print(f"{n}/{len(jobs)}  {time.time() - t0:.0f} s", flush=True)
    if bad:
        print(f"{bad} files failed")

    if "--no-sfz" not in sys.argv:
        # the SFZ last, naming a note only where the note is there
        for path in scan.files:
            lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
            at = collections.defaultdict(list)
            for ln, a, b, w, full, op in scan.sites[path]:
                at[ln, a, b].append((full, op))
            for (ln, a, b), uses in sorted(at.items(), key=lambda t: (t[0][0], -t[0][1])):
                if any(full is None or not os.path.exists(note_path(full)) for full, _ in uses):
                    continue
                new = os.path.splitext(lines[ln][a:b])[0] + EXT
                loops = {inventory.wav_loop(full) if op is not None and "loop_mode" not in op else None for full, op in uses}
                assert len(loops) == 1, (path, ln, "one site, notes with different loops")
                loop = loops.pop()
                if loop:
                    assert all("loop_start" not in op and "loop_end" not in op for _, op in uses), (path, ln)
                    new += " loop_mode=loop_continuous loop_start=%d loop_end=%d" % loop
                lines[ln] = lines[ln][:a] + new + lines[ln][b:]
            os.makedirs(os.path.dirname(mirror(path)), exist_ok=True)
            with open(mirror(path), "w", encoding="utf-8", newline="") as f:
                f.write("\n".join(lines))
    print(f"total {time.time() - t0:.1f} s")


if __name__ == "__main__":
    main()

"""Bake every sample an SFZ uses into .pinst notes, and write the same SFZ
pointing at them.

  python -I tools/pinst/bake_library.py FILE.sfz OUT_ROOT [--every N] [--jobs N] [--only TEXT]

FILE.sfz sits in LIB/Programs and names its samples relative to itself; the
notes land at the same relative paths under OUT_ROOT with .pinst in place of
the extension, and OUT_ROOT/Programs gets the SFZ once the bake is over,
naming a note wherever one was baked (so a part bake still loads). The SFZ
must give each sample= a line of its own, as ours do. Whole files are baked, so
offsets in the SFZ mean what they meant.

A file keeps its channel count (sfizz treats mono and stereo regions
differently): a stereo file whose side is under -40 dB keeps a silent second
channel. Each file is baked at the mid and body tiers and the chooser from
run_prototype keeps one, judged through the amp.

Rows go to OUT_ROOT/bake.jsonl as files finish; files already there are
skipped, so a stopped run carries on. --every N bakes each Nth file, for a
quick projection.
"""
from __future__ import annotations

import os

for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import json
import re
import sys
import time

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import amp  # noqa: E402
import inventory  # noqa: E402
import pinst_codec as pc  # noqa: E402
import pinst_file as pf  # noqa: E402
import run_prototype as rp  # noqa: E402


def bake(x, f0, tier):
    """x: (n, 1 or 2). Returns file bytes and the offline render, same shape."""
    if x.shape[1] == 1:
        sigs = [x[:, 0]]
    else:
        M, S = 0.5 * (x[:, 0] + x[:, 1]), 0.5 * (x[:, 0] - x[:, 1])
        side_db = 20 * np.log10(np.sqrt((S**2).mean()) / max(np.sqrt((M**2).mean()), 1e-12) + 1e-12)
        sigs = [M, S if side_db >= -40 else np.zeros_like(S)]
    chans, ys = [], []
    for i, sig in enumerate(sigs):
        live = bool(np.any(sig))
        _, dec, _ = pc.compile_channel(sig, live and f0 is not None, f0 if live else None, tier)
        chans.append(dec)
        ys.append(pc.render(dec, tier))
    y = ys[0][:, None] if len(ys) == 1 else np.stack([ys[0] + ys[1], ys[0] - ys[1]], axis=1)
    return pf.pack(chans, tier), y


def do_file(job):
    written, src, dst = job
    t0 = time.time()
    x, sr = sf.read(src, always_2d=True)
    assert sr == pc.SR, src
    nm = inventory.note_of(src)
    f0 = rp.note_hz(nm) if nm else None
    two = lambda a: a if a.shape[1] == 2 else np.repeat(a, 2, axis=1)
    quiet = not np.any(x)
    ref = None if quiet else amp.amp_cab(two(x))
    out = {}
    for tier in rp.TIERS:
        if tier.name not in ("mid", "body"):
            continue
        data, y = bake(x, f0, tier)
        out[tier.name] = (data, {"bytes": len(data)} if quiet else
                          {"bytes": len(data), **rp.score(two(x), two(y)), "amp": rp.score(ref, amp.amp_cab(two(y)))})
        if quiet:
            break
    pick = "mid"
    if "body" in out and not quiet:
        m, b = out["mid"][1]["amp"], out["body"][1]["amp"]
        gain = max(m["mrstft_db"] - b["mrstft_db"], 2 * (m["mel_db"] - b["mel_db"]))
        pick = "body" if gain >= rp.AUTO_GAIN_DB else "mid"
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst + ".part", "wb") as f:
        f.write(out[pick][0])
    os.replace(dst + ".part", dst)      # a stopped run never leaves half a note behind
    return {"sample": written, "seconds": round(len(x) / pc.SR, 3), "channels": x.shape[1], "note": nm,
            "wav_bytes": os.path.getsize(src), "picked": pick, "bytes": len(out[pick][0]),
            "tiers": {k: v[1] for k, v in out.items()}, "bake_s": round(time.time() - t0, 2)}


def main():
    from concurrent.futures import ProcessPoolExecutor, as_completed
    sfz, root = sys.argv[1], sys.argv[2]
    arg = lambda k: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else None
    every, only = int(arg("--every") or 1), arg("--only")
    text, seen = inventory.samples(sfz)
    prog = os.path.join(root, "Programs")
    os.makedirs(prog, exist_ok=True)
    note_path = lambda w: os.path.normpath(os.path.join(prog, os.path.splitext(w.replace(inventory.BS, "/"))[0] + ".pinst"))
    log = os.path.join(root, "bake.jsonl")
    done = set()
    if os.path.exists(log):
        done = {json.loads(l)["sample"] for l in open(log, encoding="utf-8") if l.strip()}
    jobs, dsts = [], {}
    for i, (w, src) in enumerate(sorted(seen.items())):
        dst = note_path(w)
        first = dsts.setdefault(os.path.normcase(dst), w)    # two spellings of one file bake once
        if not os.path.exists(src):
            print(f"MISSING {w}", flush=True)
            continue
        if i % every or w in done or first != w or (only and only not in w):
            continue
        jobs.append((w, src, dst))
    # longest first, so the tail of the run is not one long note on one core
    jobs.sort(key=lambda j: -os.path.getsize(j[1]))
    print(f"{len(jobs)} files to bake, {len(done)} already done", flush=True)
    t0, n, bad = time.time(), 0, 0
    workers = int(arg("--jobs") or max(1, (os.cpu_count() or 4) - 2))
    with ProcessPoolExecutor(workers) as ex, open(log, "a", encoding="utf-8") as lf:
        futs = {ex.submit(do_file, j): j[0] for j in jobs}
        for fut in as_completed(futs):
            n += 1
            try:
                row = fut.result()
            except Exception as e:      # one bad file must not cost the run; it stays undone and is retried
                bad += 1
                print(f"FAILED {futs[fut]}: {e!r}", flush=True)
                continue
            lf.write(json.dumps(row) + "\n")
            lf.flush()
            if n % 50 == 0 or n == len(jobs):
                print(f"{n}/{len(jobs)}  {time.time() - t0:.0f} s", flush=True)
    if bad:
        print(f"{bad} files failed")

    # the SFZ last, naming a note only where the note is there: a part bake
    # (--every, --only, a stopped run) leaves the rest on their original files
    def name(m):
        w = m.group(1)
        if w.startswith("*") or not os.path.exists(note_path(w)):
            return m.group(0)
        return "sample=" + os.path.splitext(w)[0] + ".pinst"
    with open(os.path.join(prog, os.path.basename(sfz)), "w", encoding="utf-8", newline="") as f:
        f.write(re.sub(r"^sample=(.+?)[ \t]*$", name, text, flags=re.M))
    print(f"total {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()

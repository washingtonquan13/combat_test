"""Bake every sample an SFZ uses into .pinst notes, and write the same SFZ
pointing at them.

  python -I tools/pinst/bake_library.py FILE.sfz OUT_ROOT [--lib DIR]
      [--pitch name|key|none] [--every N] [--jobs N] [--only TEXT]

OUT_ROOT mirrors the library folder LIB (--lib, default the folder above the
SFZ's own): every note lands at its sample's path under OUT_ROOT with .pinst
in place of the extension, and once the bake is over every SFZ file read
(FILE.sfz and whatever it #includes) is written at its own path there,
naming a note wherever one was baked (so a part bake still loads). The SFZ is
read as sfizz reads it (inventory.Scan: #define, #include, default_path).
Whole files are baked, so offsets in the SFZ mean what they meant; a WAV's
own loop, which the note does not carry, is written into the region as
opcodes when the region sets none.

--pitch says where a note's pitch comes from, which sets the analysis window
(below 200 Hz a longer one): name (the default) from the file name, as
METAL-GTX names its notes; key from the region's pitch_keycenter, the name
where there is one; none for drums.

A file keeps its channel count (sfizz treats mono and stereo regions
differently): a stereo file whose side is under -40 dB keeps a silent second
channel. Every file goes through the one encoder (sms.run, the generators
only, written as PINST4 by sms_file) at the file's own sample rate: no
tiers, nothing chosen per file.

Rows go to OUT_ROOT/bake.jsonl as files finish; files already there are
skipped, so a stopped run carries on. --every N bakes each Nth file, for a
quick projection.
"""
from __future__ import annotations

import os

for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import collections
import json
import sys
import time

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inventory  # noqa: E402
import pinst_codec as pc  # noqa: E402
import pinst_encode as pe  # noqa: E402
import sms  # noqa: E402
import sms_file  # noqa: E402
import fastlib  # noqa: E402

fastlib.recycle_big_arrays()


def do_file(job):
    written, src, dst, hz = job
    t0 = time.time()
    x, sr = sf.read(src, always_2d=True)
    if len(x) < 4096:   # a stub (a library's 24-frame silence.wav) is padded with silence to the analysis windows
        x = np.concatenate([x, np.zeros((4096 - len(x), x.shape[1]))])
    pc.SR = sr          # the note is coded at its own rate
    nm = inventory.note_of(src)
    f0 = hz if hz != "name" else (inventory.note_hz(nm) if nm else None)
    sigs = pe.channels_of(x)
    chans, sizes = [], []
    for i, sig in enumerate(sigs):
        if not np.any(sig):
            chans.append(None)
            sizes.append({})
            continue
        parts, _, _ = sms.run(sig, sr, {"f0": f0, "ref": sigs[0] if i else None})
        chans.append((parts, 7 + 100 * i))
        sizes.append(sms.size(parts))
    data = sms_file.pack(sr, len(x), chans)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst + ".part", "wb") as f:
        f.write(data)
    os.replace(dst + ".part", dst)      # a stopped run never leaves half a note behind
    return {"sample": written, "seconds": round(len(x) / sr, 3), "sr": sr, "channels": x.shape[1], "note": nm,
            "wav_bytes": os.path.getsize(src), "bytes": len(data), "gen_bytes": sizes,
            "bake_s": round(time.time() - t0, 2)}


def core_masks():
    """One affinity mask per physical core (Windows), or [] when unknown."""
    if os.name != "nt":
        return []
    import ctypes

    class Info(ctypes.Structure):
        _fields_ = [("mask", ctypes.c_size_t), ("rel", ctypes.c_int), ("pad", ctypes.c_ulonglong * 2)]
    k = ctypes.WinDLL("kernel32")
    size = ctypes.c_ulong(0)
    k.GetLogicalProcessorInformation(None, ctypes.byref(size))
    buf = (Info * (size.value // ctypes.sizeof(Info)))()
    if not k.GetLogicalProcessorInformation(buf, ctypes.byref(size)):
        return []
    return [i.mask for i in buf if i.rel == 0]


def pin_worker(masks, counter):
    """Each worker keeps to one core of its own. Left to the scheduler, two
    workers now and then share a core's two threads while another core idles."""
    import ctypes
    with counter.get_lock():
        i = counter.value
        counter.value += 1
    mask = masks[i % len(masks)]
    k = ctypes.WinDLL("kernel32")
    k.GetCurrentProcess.restype = ctypes.c_void_p
    k.SetProcessAffinityMask.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    k.SetProcessAffinityMask(k.GetCurrentProcess(), mask)


def main():
    from concurrent.futures import ProcessPoolExecutor, as_completed
    sfz, root = sys.argv[1], sys.argv[2]
    arg = lambda k: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else None
    every, only = int(arg("--every") or 1), arg("--only")
    pitch = arg("--pitch") or "name"
    assert pitch in ("name", "key", "none"), pitch
    scan = inventory.Scan(sfz)
    lib = os.path.abspath(arg("--lib") or os.path.dirname(os.path.dirname(os.path.abspath(sfz))))
    mirror = lambda full: os.path.normpath(os.path.join(root, os.path.relpath(full, lib)))
    for full in scan.files + [f for _, f, _ in scan.regions]:
        assert not os.path.relpath(full, lib).startswith(".."), f"{full} is outside {lib}"
    note_path = lambda full: os.path.splitext(mirror(full))[0] + ".pinst"
    os.makedirs(root, exist_ok=True)
    seen, keys = {}, {}
    for w, full, k in scan.regions:     # a file once, by the name it is first written as
        if os.path.normcase(full) not in keys:
            # two files written alike (default_path): the second by its path in the library
            seen[w if w not in seen else os.path.relpath(full, lib)] = full
        keys.setdefault(os.path.normcase(full), k)

    def hz_of(full):
        if pitch == "none":
            return None
        if pitch == "name" or inventory.note_of(full):
            return "name"
        k = keys.get(os.path.normcase(full))
        return None if k is None else 440.0 * 2 ** ((k - 69) / 12)
    log = os.path.join(root, "bake.jsonl")
    done = set()
    if os.path.exists(log):
        done = {json.loads(l)["sample"] for l in open(log, encoding="utf-8") if l.strip()}
    jobs, dsts = [], {}
    for i, (w, src) in enumerate(sorted(seen.items())):
        dst = note_path(src)
        first = dsts.setdefault(os.path.normcase(dst), w)    # two spellings of one file bake once
        if not os.path.exists(src):
            print(f"MISSING {w}", flush=True)
            continue
        if i % every or w in done or first != w or (only and only not in w):
            continue
        jobs.append((w, src, dst, hz_of(src)))
    # longest first, so the tail of the run is not one long note on one core
    jobs.sort(key=lambda j: -os.path.getsize(j[1]))
    print(f"{len(jobs)} files to bake, {len(done)} already done", flush=True)
    t0, n, bad = time.time(), 0, 0
    import multiprocessing
    masks = core_masks()
    # a worker per core: the second thread of a core adds nothing here
    workers = int(arg("--jobs") or len(masks) or max(1, (os.cpu_count() or 4) // 2))
    pin = dict(initializer=pin_worker, initargs=(masks, multiprocessing.Value("i", 0))) if masks else {}
    with ProcessPoolExecutor(workers, **pin) as ex, open(log, "a", encoding="utf-8") as lf:
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
    for path in scan.files:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
        # a file included more than once (Salamander's region.txt, once per
        # velocity layer) has each sample= site once per inclusion, each a
        # different note: the text is rewritten once, when every one is there
        at = collections.defaultdict(list)
        for ln, a, b, w, full, op in scan.sites[path]:
            at[ln, a, b].append((full, op))
        for (ln, a, b), uses in sorted(at.items(), key=lambda t: (t[0][0], -t[0][1])):
            if any(full is None or not os.path.exists(note_path(full)) for full, _ in uses):
                continue
            new = os.path.splitext(lines[ln][a:b])[0] + ".pinst"
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
    print(f"total {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()

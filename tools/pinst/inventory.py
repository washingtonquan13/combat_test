"""Which sample files an SFZ uses, and how much audio that is.

  python -I tools/pinst/inventory.py FILE.sfz
"""
import collections
import os
import re
import sys

import soundfile as sf

BS = chr(92)
NOTE_RE = re.compile(r"([a-g]#?-?\d)_")


def samples(sfz_path):
    """Unique sample paths as written in the file, and their full paths."""
    s = open(sfz_path, encoding="utf-8", errors="replace").read()
    seen = {}
    for m in re.finditer(r"^sample=(.+)$", s, re.M):
        w = m.group(1).strip()
        if w.startswith("*") or w in seen:
            continue
        seen[w] = os.path.normpath(os.path.join(os.path.dirname(sfz_path), w.replace(BS, "/")))
    return s, seen


def note_of(path):
    m = NOTE_RE.match(os.path.basename(path).lower())
    return m.group(1) if m else None


if __name__ == "__main__":
    s, seen = samples(sys.argv[1])
    print(len(re.findall(r"^sample=", s, re.M)), "regions,", len(seen), "files")
    ops = collections.Counter(re.findall(r"^(offset\w*|end|loop_\w+|direction|pitch_keycenter)=(\S+)", s, re.M))
    print([o for o in ops.most_common(400) if o[0][0] != "pitch_keycenter"][:30])
    by = collections.defaultdict(lambda: [0, 0, 0.0, set(), 0])
    for w, f in seen.items():
        if not os.path.exists(f):
            print("missing", w)
            continue
        i = sf.info(f)
        b = by[os.path.relpath(os.path.dirname(f), os.path.dirname(os.path.dirname(sys.argv[1])))]
        b[0] += 1
        b[1] += os.path.getsize(f)
        b[2] += i.frames / i.samplerate
        b[3].add((i.samplerate, i.channels, i.subtype))
        b[4] += note_of(f) is not None
    T = [0, 0, 0.0]
    for d, b in sorted(by.items()):
        print(f"{d:40s} {b[0]:5d} files {b[1] / 1e6:8.1f} MB {b[2]:7.0f} s  pitched names {b[4]:4d}  {sorted(b[3])}")
        for k in range(3):
            T[k] += b[k]
    print(f"total {T[0]} files, {T[1] / 1e6:.0f} MB, {T[2]:.0f} s")

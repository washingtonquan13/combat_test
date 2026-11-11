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


NAME_RE = re.compile(r"([a-g])([#b]?)(-?\d+)$")
TOKEN_RE = re.compile(r"<(\w+)>|([A-Za-z0-9_$]+)=")
INCLUDE_RE = re.compile(r'#include\s+"([^"]*)"')
STEP = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}


def key_number(v):
    """pitch_keycenter as sfizz reads it: a MIDI number or a name, c4 = 60."""
    v = v.strip().lower()
    if v.lstrip("-").isdigit():
        return int(v)
    m = NAME_RE.match(v)
    if not m:
        return None
    return 12 * (int(m.group(3)) + 1) + STEP[m.group(1)] + {"#": 1, "b": -1, "": 0}[m.group(2)]


class Scan:
    """An SFZ as sfizz reads it: #define and #include followed, default_path
    honoured, opcodes inherited global > master > group > region.

    files: every SFZ file read, root first. regions: (written, full path,
    pitch_keycenter or None) per region with a sample. sites: per file, where
    each sample= value sits in the original text, [line, start, end, written,
    full path, the region's opcodes or None outside a region], so a copy can
    name other files without disturbing anything else."""

    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.base = os.path.dirname(self.root)
        self.files, self.regions, self.sites, self.defines = [], [], {}, {}
        self.scope = {"global": {}, "master": {}, "group": {}, "region": None}
        self.control, self.where, self.pending = {}, "global", []
        self._file(self.root)
        self._end_region()

    def _file(self, path):
        path = os.path.normpath(path)
        if path not in self.sites:
            self.files.append(path)
            self.sites[path] = []
        text = open(path, encoding="utf-8", errors="replace").read()
        comment = False
        for ln, line in enumerate(text.split(chr(10))):
            raw = line
            if comment:     # inside /* */
                if "*/" not in line:
                    continue
                line, comment = " " * (line.index("*/") + 2) + line[line.index("*/") + 2:], False
            if "/*" in line:
                i = line.index("/*")
                if "*/" in line[i:]:
                    j = line.index("*/", i) + 2
                    line = line[:i] + " " * (j - i) + line[j:]
                else:
                    line, comment = line[:i], True
            if "//" in line:
                line = line[: line.index("//")]
            st = line.strip()
            if st.startswith("#define"):
                parts = st.split(None, 2)
                self.defines[parts[1]] = parts[2].strip() if len(parts) > 2 else ""
                continue
            # an #include can sit anywhere on a line (Salamander: <group> #include "a" lovel=1 #include "b"):
            # the text on each side is read in order around it, the rest blanked so columns stay put
            at = 0
            for m in INCLUDE_RE.finditer(line):
                self._line(path, ln, raw, " " * at + line[at:m.start()] + " " * (len(line) - m.start()))
                inc = self._subst(m.group(1)).replace(BS, "/")
                cand = [os.path.join(self.base, inc), os.path.join(os.path.dirname(path), inc)]
                self._file(next((c for c in cand if os.path.exists(c)), cand[0]))
                at = m.end()
            self._line(path, ln, raw, " " * at + line[at:])

    def _subst(self, s):
        for k in sorted(self.defines, key=len, reverse=True):
            s = s.replace(k, self.defines[k])
        return s

    def _line(self, path, ln, raw, line):
        toks = list(TOKEN_RE.finditer(line))
        for i, m in enumerate(toks):
            if m.group(1):
                self._header(m.group(1).lower())
                continue
            end = toks[i + 1].start() if i + 1 < len(toks) else len(line)
            op, val = self._subst(m.group(2)), line[m.end():end].strip()
            v = self._subst(val)
            # the copy swaps the written extension for .pinst, so a define may
            # name the extension (sample=x.$EXT) but nothing that moves the stem
            if op == "sample" and "$" in val and self._subst(os.path.splitext(val)[0]) != os.path.splitext(v)[0]:
                raise ValueError(f"{path}:{ln + 1}: a sample named through a #define")
            if self.where == "control":
                self.control[op] = v
            elif self.where in self.scope and self.scope[self.where] is not None:
                self.scope[self.where][op] = v
            if op == "sample" and self.where != "control":
                full = None
                if not v.startswith("*"):
                    rel = (self.control.get("default_path", "") + v).replace(BS, "/")
                    full = os.path.normpath(os.path.join(self.base, rel))
                s = m.end() + (len(line[m.end():end]) - len(line[m.end():end].lstrip()))
                site = [ln, s, s + len(val), v, full, None]
                self.sites[path].append(site)
                self.pending.append(site)

    def _header(self, h):
        self._end_region()
        self.pending = []
        self.where = h
        if h == "control":
            self.control = {}
        elif h == "global":
            self.scope.update(**{"global": {}, "master": {}, "group": {}})
        elif h == "master":
            self.scope.update(master={}, group={})
        elif h == "group":
            self.scope["group"] = {}
        elif h == "region":
            self.scope["region"] = {}

    def _end_region(self):
        r = self.scope["region"]
        if r is None:
            return
        op = {**self.scope["global"], **self.scope["master"], **self.scope["group"], **r}
        for site in self.pending:      # a sample= written inside a region: that region's opcodes
            site[5] = op
        self.pending = []
        w = op.get("sample")
        if w and not w.startswith("*"):
            rel = (self.control.get("default_path", "") + w).replace(BS, "/")
            k = op.get("pitch_keycenter", op.get("key"))     # key= sets the centre too
            self.regions.append((w, os.path.normpath(os.path.join(self.base, rel)), key_number(k) if k else None))
        self.scope["region"] = None


def wav_loop(path):
    """(start, end) of a WAV's first smpl loop, end inclusive, or None.
    sfizz loops a region on these when the SFZ sets no loop_mode."""
    import struct
    with open(path, "rb") as f:
        if f.read(12)[8:12] != b"WAVE":
            return None
        while True:
            c = f.read(8)
            if len(c) < 8:
                return None
            n = struct.unpack("<I", c[4:])[0]
            if c[:4] == b"smpl":
                d = f.read(n)
                if n < 60 or struct.unpack("<I", d[28:32])[0] == 0:
                    return None
                return struct.unpack("<II", d[44:52])
            f.seek(n + (n & 1), 1)


def note_of(path):
    m = NOTE_RE.match(os.path.basename(path).lower())
    return m.group(1) if m else None


NAMES = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}


def note_hz(nm):
    """'d#4' -> Hz (A4 = 440)."""
    m = re.fullmatch(r"([a-g])(#?)(-?\d)", nm)
    midi = 12 * (int(m.group(3)) + 1) + NAMES[m.group(1)] + (1 if m.group(2) else 0)
    return 440 * 2 ** ((midi - 69) / 12)


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

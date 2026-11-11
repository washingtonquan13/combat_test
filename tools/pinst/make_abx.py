"""Blind ABX MP3s from a finished run. Each trial is one file: A (original),
B (baked), then X, which is A or B at random. The answers go to key.json,
which the listener opens only after writing their guesses down.

  python -I tools/pinst/make_abx.py OUT_DIR TIER [NOTE ...]

Guitar notes use the amp_ renders (how the game plays them)."""
import json
import os
import random
import sys

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_prototype import write_mp3  # noqa: E402
import pinst_codec as pc  # noqa: E402


def main():
    out, tier, names = sys.argv[1], sys.argv[2], sys.argv[3:]
    if not names:
        names = sorted(d for d in os.listdir(out) if os.path.isdir(os.path.join(out, d)))
    abx = os.path.join(out, f"abx_{tier}")
    os.makedirs(abx, exist_ok=True)
    rng = random.Random()
    key = {}
    gap = lambda s: np.zeros((int(s * pc.SR), 2))
    for i, n in enumerate(names, 1):
        nd = os.path.join(out, n)
        pre = "amp_" if os.path.exists(os.path.join(nd, "amp_orig.wav")) else ""
        a, _ = sf.read(os.path.join(nd, pre + "orig.wav"), always_2d=True)
        b, _ = sf.read(os.path.join(nd, f"{pre}{tier}.wav"), always_2d=True)
        m = min(len(a), len(b))
        a, b = a[:m], b[:m]
        x_is = rng.choice("AB")
        x = a if x_is == "A" else b
        trial = f"trial_{i:02d}.mp3"
        write_mp3(os.path.join(abx, trial), np.concatenate([a, gap(0.8), b, gap(1.5), x]))
        key[trial] = {"note": n, "X": x_is}
    json.dump(key, open(os.path.join(abx, "key.json"), "w"), indent=1)
    print(f"{len(key)} trials in {abx}")


if __name__ == "__main__":
    main()

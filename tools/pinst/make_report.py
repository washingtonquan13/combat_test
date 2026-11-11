"""Turn OUT_DIR/results.json into OUT_DIR/report.md: bytes per note by tier
and codec, the ratio to the source WAV on disk, raw and through-amp
distances, and a projection to the libraries the game ships.

  python -I tools/pinst/make_report.py OUT_DIR"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_prototype import NOTES, TIERS, CODECS  # noqa: E402

# GB on disk, measured 2026-11-10 (find -iname '*.wav').
LIBS = {"gtr": ("metal-gtx", 2.88), "drum": ("sm-drums", 3.66)}
BUDGET_MB = 256


def main():
    out = sys.argv[1]
    rows = json.load(open(os.path.join(out, "results.json")))
    paths = {n: p for n, p, *_ in NOTES}
    keys = [t.name for t in TIERS] + [c[0] for c in CODECS]
    L = ["# .pinst prototype results", "",
         "Sizes in KB. Distances in dB, lower is closer: mrstft = multi-resolution spectral, "
         "mel = 64-band mel. Not a perceptual score; the reels decide.", ""]
    sums = {k: {"gtr": [0, 0], "drum": [0, 0]} for k in keys}   # [bytes, wav bytes]
    for kind, title in (("gtr", "Guitar DI (amp = through the head + cab chain)"), ("drum", "Drums")):
        L += [f"## {title}", "", "| note | s | wav KB | " + " | ".join(keys) + " |",
              "|---|---|---|" + "---|" * len(keys)]
        for r in rows:
            if r["kind"] != kind:
                continue
            wav = os.path.getsize(paths[r["name"]])
            cells = []
            for k in keys:
                v = r["tiers"].get(k) or r["codecs"][k]
                sums[k][kind][0] += v["bytes"]
                sums[k][kind][1] += wav
                c = f"{v['bytes']/1024:.1f} / {v['mrstft_db']:.1f} / {v['mel_db']:.2f}"
                if "amp" in v:
                    c += f"<br>amp {v['amp']['mrstft_db']:.1f} / {v['amp']['mel_db']:.2f}"
                cells.append(c)
            L.append(f"| {r['name']} | {r['seconds']} | {wav/1024:.0f} | " + " | ".join(cells) + " |")
        L += ["", "Cell: KB / mrstft / mel.", ""]
    L += ["## Projection", "",
          "Each format's total bytes over these notes, divided by the same notes' WAV bytes on disk, "
          "applied to the whole library. Assumes these notes are typical of their library.", "",
          "| format | " + " | ".join(f"{LIBS[k][0]} ({LIBS[k][1]} GB)" for k in LIBS) + " | both | vs 256 MB |",
          "|---|" + "---|" * (len(LIBS) + 2)]
    for k in keys:
        mb = []
        for kind, (_, gb) in LIBS.items():
            b, w = sums[k][kind]
            mb.append(gb * 1024 * b / w if w else 0)
        tot = sum(mb)
        L.append(f"| {k} | " + " | ".join(f"{m:.0f} MB (1:{(LIBS[kd][1]*1024)/m:.0f})" if m else "-"
                                         for m, kd in zip(mb, LIBS)) + f" | {tot:.0f} MB | {tot/BUDGET_MB:.2f}x |")
    L.append("")
    open(os.path.join(out, "report.md"), "w", encoding="utf-8").write("\n".join(L))
    print("\n".join(L[-len(keys) - 3:]))


if __name__ == "__main__":
    main()

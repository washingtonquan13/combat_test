"""Phase 3a of COMPRESSION_PLAN.md (option 2): pick the districts.

    python -I tools/blockout/parish_districts.py <segment dir> [--area 2.5] [--whole] [--png out.png]

A district grows from a seed point over whole blocks, nearest first, through
neighbouring blocks only (so it never jumps the river), until it reaches
--area km2. Blocks of irregular patches, blocks over 0.2 km2 (yards, parks,
industry) and blocks another district already took are skipped.

The seeds are neighbourhoods, not score peaks: the raw download has no place
names, and the score surface outside the core is flat enough that its peaks
land on motel strips and a naval base. SEEDS is the one list a person may
want to edit. --whole adds WHOLE_SEEDS, the rest of the parish (Gentilly,
the Lower Ninth, New Orleans East, lower Algiers), for a map of all of it.

Writes <segment dir>/districts.json: per district its name, seed, blocks,
area, and wikidata landmarks; plus the gate below.

Gate 3a: every seed grows a district of one part, the required five are
present, and the total area is 20-35 km2 (scaled by the seed count with
--whole).
"""
import argparse
import heapq
import json
import os
import sys

import numpy as np
import shapely
from shapely.geometry import Point, Polygon

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compress import Frame  # noqa: E402

# name, lat, lon
SEEDS = [
    ("French Quarter", 29.9574, -90.0629),
    ("CBD", 29.9488, -90.0705),
    ("Marigny and Bywater", 29.9640, -90.0480),
    ("Garden District", 29.9286, -90.0846),
    ("Uptown and Audubon", 29.9370, -90.1170),
    ("Carrollton and Riverbend", 29.9500, -90.1310),
    ("Mid-City", 29.9740, -90.0990),
    ("Bayou St. John", 29.9800, -90.0850),
    ("Lakeview", 30.0060, -90.1120),
    ("Algiers Point", 29.9530, -90.0520),
    ("Holy Cross", 29.9600, -90.0180),
]
# The rest of Orleans Parish: with --whole, these grow after SEEDS, and
# over irregular patches too, since the East's suburbs are all curved
# streets.
WHOLE_SEEDS = [
    ("Gentilly", 30.0000, -90.0550),
    ("Lower Ninth Ward", 29.9720, -90.0030),
    ("Lake Forest", 30.0400, -89.9750),
    ("Village de l'Est", 30.0470, -89.9350),
    ("Lower Algiers", 29.9180, -90.0100),
]
REQUIRED = ("French Quarter", "CBD", "Marigny and Bywater", "Garden District", "Mid-City")
BLOCK_MAX = 2e5  # m2: bigger blocks are yards, parks, industry
TOUCH = 20.0  # m: blocks this close are neighbours (across one street)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("segment")
    ap.add_argument("--area", type=float, default=2.5, help="km2 per district")
    ap.add_argument("--whole", action="store_true", help="seed the rest of the parish too (WHOLE_SEEDS)")
    ap.add_argument("--png")
    a = ap.parse_args()
    seeds = SEEDS + (WHOLE_SEEDS if a.whole else [])
    seg = json.load(open(os.path.join(a.segment, "segment.json"), encoding="utf-8"))
    fr = Frame(*seg["frame"])
    B, P = seg["blocks"], seg["patches"]
    irr = {p["id"] for p in P if p["irregular"]}
    poly = [Polygon(b["ring"]) for b in B]
    area = np.array([p.area for p in poly])
    cen = np.array([p.centroid.coords[0] for p in poly])
    small = area < BLOCK_MAX
    regular = np.array([b["patch"] not in irr for b in B])
    tree = shapely.STRtree(poly)
    nbr = [[] for _ in B]
    ii, jj = tree.query([p.buffer(TOUCH) for p in poly], predicate="intersects")
    for i, j in zip(ii, jj):
        if i != j:
            nbr[i].append(int(j))

    taken = np.zeros(len(B), bool)
    out = []
    for k, (name, lat, lon) in enumerate(seeds):
        ok = small & (regular | (k >= len(SEEDS)))
        x, z = fr.xz([lon], [lat])
        s = np.array([float(x[0]), float(z[0])])
        d = np.hypot(*(cen - s).T)
        start = [int(b) for b in np.argsort(d)[:50] if ok[b] and not taken[b]]
        mem, acc = [], 0.0
        if start:
            h, seen = [(d[start[0]], start[0])], {start[0]}
            while h and acc < a.area * 1e6:
                _, b = heapq.heappop(h)
                mem.append(b)
                acc += area[b]
                taken[b] = True
                for n in nbr[b]:
                    if n not in seen and ok[n] and not taken[n]:
                        seen.add(n)
                        heapq.heappush(h, (d[n], n))
        u = shapely.union_all([poly[b] for b in mem]).buffer(TOUCH / 2).buffer(-TOUCH / 2) if mem else Polygon()
        wd = sorted({l[0] for b in mem for l in B[b]["landmarks"] if l[0] and l[1] == "wikidata"})
        out.append({"name": name, "seed": [lat, lon], "seed_xz": [round(float(v), 1) for v in s],
                    "blocks": mem, "area_km2": round(u.area / 1e6, 3), "parts": len(shapely.get_parts(u)),
                    "wikidata": wd})
        print("%-26s %.2f km2  parts %d  %d blocks  %s" % (name, u.area / 1e6, len(shapely.get_parts(u)), len(mem),
                                                          "; ".join(wd[:4])))
    total = sum(o["area_km2"] for o in out)
    names = {o["name"] for o in out if o["blocks"]}
    gate = {"districts": len(out), "total_km2": round(total, 2),
            "missing_required": [r for r in REQUIRED if r not in names],
            "split": [o["name"] for o in out if o["parts"] != 1]}
    gate["pass"] = not gate["missing_required"] and not gate["split"] and 20.0 <= total * len(SEEDS) / len(seeds) <= 35.0
    print("gate", json.dumps(gate))
    with open(os.path.join(a.segment, "districts.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"frame": seg["frame"], "area_km2": a.area, "districts": out, "gate": gate}, f, indent=1)
    if a.png:
        png(a.png, poly, B, out, irr)
    sys.exit(0 if gate["pass"] else 1)


def png(path, poly, B, out, irr):
    from PIL import Image, ImageDraw, ImageFont
    allc = np.vstack([np.asarray(poly[b].exterior.coords) for o in out for b in o["blocks"]])
    lo, hi = allc.min(0) - 2500, allc.max(0) + 2500
    ppm = 1600.0 / (hi - lo).max()
    W, H = (np.ceil((hi - lo) * ppm)).astype(int)
    im = Image.new("RGB", (int(W), int(H)), (246, 244, 238))
    dr = ImageDraw.Draw(im)
    px = lambda q: [((x - lo[0]) * ppm, (z - lo[1]) * ppm) for x, z in q]
    owner = {b: k for k, o in enumerate(out) for b in o["blocks"]}
    pal = [(214, 96, 77), (67, 147, 195), (90, 174, 97), (153, 112, 171), (241, 163, 64), (53, 151, 143),
           (191, 129, 45), (128, 205, 193), (197, 27, 125), (116, 173, 209), (140, 81, 10), (77, 146, 33)]
    for i, p in enumerate(poly):
        c = np.asarray(p.exterior.coords)
        if ((c < lo) | (c > hi)).any():
            continue
        k = owner.get(i)
        fill = pal[k % len(pal)] if k is not None else ((222, 214, 200) if B[i]["patch"] in irr else (206, 202, 194))
        dr.polygon(px(c), fill=fill)
    font = ImageFont.load_default(size=22) if hasattr(ImageFont, "load_default") else None
    for o in out:
        x, z = (np.array(o["seed_xz"]) - lo) * ppm
        dr.text((x - 40, z - 10), o["name"], fill=(20, 20, 20), font=font)
    im.save(path)
    print("wrote", path, im.size)


main()

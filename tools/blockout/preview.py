"""Before/after top-down preview of a compression: two panels at one scale.

    python -I tools/blockout/preview.py <before raw dir> <after raw dir> <out.png> [--px-per-m 1.0]

Left is the source, with every way the compression deleted drawn red; right
is the result. Both read features.json + bld_*.json in osm_city's frame
(the "origin" of a frame.json next to the dirs, else the before bbox centre).
"""
import glob, json, math, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compress import Frame

SKIP = {"footway", "path", "cycleway", "steps", "pedestrian", "track", "bridleway", "corridor", "proposed", "construction"}
WIDTH = {"motorway": 5, "trunk": 5, "primary": 4, "secondary": 3, "tertiary": 3, "residential": 2, "unclassified": 2, "service": 1}
BG, BLD, ROAD, RAIL, WATER, GONE = (246, 244, 238), (206, 199, 186), (60, 64, 72), (120, 90, 140), (160, 196, 222), (220, 40, 40)
PAD = 40


def load(d):
    els = []
    for f in [os.path.join(d, "features.json")] + sorted(glob.glob(os.path.join(d, "bld_*.json"))):
        if os.path.exists(f):
            els += json.load(open(f, encoding="utf-8"))["elements"]
    return els


def shapes(els, fr):
    out = []
    for el in els:
        if el["type"] != "way":
            continue
        g = [q for q in el.get("geometry") or [] if q]
        if len(g) < 2:
            continue
        t = el.get("tags", {})
        x, z = fr.xz([q["lon"] for q in g], [q["lat"] for q in g])
        if t.get("building"):
            kind = "bld"
        elif t.get("highway") and t["highway"] not in SKIP:
            kind = "road"
        elif t.get("railway") in ("rail", "light_rail", "tram"):
            kind = "rail"
        elif t.get("natural") == "water" or t.get("waterway") or t.get("landuse") == "basin":
            kind = "water"
        else:
            continue
        out.append((kind, el["id"], t.get("highway", ""), np.c_[x, z]))
    return out


def panel(sh, gone, ppm, bounds, title, font):
    x0, z0, x1, z1 = bounds
    W, H = int((x1 - x0) * ppm) + 2 * PAD, int((z1 - z0) * ppm) + 2 * PAD + 30
    im = Image.new("RGB", (W, H), BG)
    dr = ImageDraw.Draw(im, "RGBA")
    px = lambda p: [(PAD + (a - x0) * ppm, PAD + 30 + (b - z0) * ppm) for a, b in p]
    order = {"water": 0, "bld": 1, "rail": 2, "road": 3}
    for kind, wid, hw, p in sorted(sh, key=lambda s: (order[s[0]], s[1] in gone)):
        red = wid in gone
        if kind in ("water", "bld") and len(p) > 2:
            dr.polygon(px(p), fill=(*GONE, 150) if red else (WATER if kind == "water" else BLD))
        else:
            w = max(1, round(WIDTH.get(hw, 2) * ppm)) if kind == "road" else max(1, round(ppm))
            dr.line(px(p), fill=GONE if red else (RAIL if kind == "rail" else ROAD), width=w + (1 if red else 0))
    dr.text((PAD, 8), title, fill=(30, 30, 30), font=font)
    # 100 m scale bar
    y = H - PAD // 2
    dr.line([(PAD, y), (PAD + 100 * ppm, y)], fill=(30, 30, 30), width=3)
    dr.text((PAD + 100 * ppm + 6, y - 8), "100 m", fill=(30, 30, 30), font=font)
    return im


def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    ppm = float(sys.argv[sys.argv.index("--px-per-m") + 1]) if "--px-per-m" in sys.argv else 1.0
    if len(a) < 3:
        sys.exit(__doc__)
    before, after, out = a[0], a[1], a[2]
    fj = os.path.join(os.path.dirname(os.path.normpath(before)), "frame.json")
    fr = Frame(*json.load(open(fj))["origin"]) if os.path.exists(fj) else None
    eb, ea = load(before), load(after)
    if fr is None:
        lat = [q["lat"] for e in eb for q in (e.get("geometry") or []) if q]
        lon = [q["lon"] for e in eb for q in (e.get("geometry") or []) if q]
        fr = Frame((min(lat) + max(lat)) / 2, (min(lon) + max(lon)) / 2)
    sb, sa = shapes(eb, fr), shapes(ea, fr)
    gone = {s[1] for s in sb} - {s[1] for s in sa}
    def bnd(sh):
        p = np.vstack([s[3] for s in sh if s[0] != "water"])
        return (*p.min(0), *p.max(0))
    bb, ba = bnd(sb), bnd(sa)
    font = ImageFont.load_default(size=18) if hasattr(ImageFont, "load_default") else None
    road_len = lambda sh: sum(np.hypot(*np.diff(s[3], axis=0).T).sum() for s in sh if s[0] == "road")
    L = panel(sb, gone, ppm, bb, "before  %.0f x %.0f m, %d ways deleted (red)" % (bb[2] - bb[0], bb[3] - bb[1], len(gone)), font)
    R = panel(sa, set(), ppm, ba, "after  %.0f x %.0f m, road length %.0f%%" % (ba[2] - ba[0], ba[3] - ba[1], 100 * road_len(sa) / max(1, road_len(sb))), font)
    im = Image.new("RGB", (L.width + R.width + 20, max(L.height, R.height)), (255, 255, 255))
    im.paste(L, (0, 0)); im.paste(R, (L.width + 20, 0))
    im.save(out)
    print("wrote", out, im.size)


main()

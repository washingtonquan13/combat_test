"""Phase 3 layout of COMPRESSION_PLAN.md (option 2): place the districts.

    python -I tools/blockout/parish_layout.py <segment dir> [--rho 1.75] [--png out.png]

Reads parish_districts.py's districts.json. Every district keeps its shape
and moves by one translation: its centroid goes to
centre + c * (centroid - centre), so the bearings between districts stay
true and only their distances shrink. A pair that ends up closer than
GAP_MIN (or than it truly was, if that is less) is pushed apart along the
line joining them. c is found by bisection so the footprint, the convex
hull of the placed districts (rubble inside it, fog outside), is
A = (total district area) * (1 + rho).

Neighbours are the Delaunay edges between the placed centroids, dropping
any edge that runs through a third district or is longer than EDGE_MAX
times the shortest edge of either end. Each neighbour pair gets a ribbon
(parish_ribbon.py).

Writes <segment dir>/layout.json: c, the footprint, and per district its
translation; the neighbour edges.
"""
import argparse
import json
import os
import sys

import numpy as np
import shapely
import shapely.affinity
from shapely.geometry import LineString, Polygon

GAP_MIN = 120.0  # m: closest two districts may come, unless they were truly closer
CLOSE = 10.0  # m: closing radius that turns a district's blocks into one area
EDGE_MAX = 1.8  # an edge this many times the shortest at either end is not a neighbour
PUSH_ROUNDS = 400


def district_polys(seg, dist):
    B = seg["blocks"]
    out = []
    for d in dist["districts"]:
        u = shapely.union_all([Polygon(B[b]["ring"]) for b in d["blocks"]])
        out.append(u.buffer(CLOSE).buffer(-CLOSE))
    return out


def clusters(polys):
    """Districts truly closer than GAP_MIN move as one: their shared streets are real."""
    root = list(range(len(polys)))
    def find(i):
        while root[i] != i:
            root[i] = root[root[i]]
            i = root[i]
        return i
    for i in range(len(polys)):
        for j in range(i + 1, len(polys)):
            if polys[i].distance(polys[j]) < GAP_MIN:
                root[find(i)] = find(j)
    ids = sorted({find(i) for i in range(len(polys))})
    return [ids.index(find(i)) for i in range(len(polys))]


def place(cpolys, ccen, centre, c):
    """Cluster translations for scale c, then pushed apart until no two
    clusters are closer than GAP_MIN."""
    t = (centre + c * (ccen - centre)) - ccen
    for _ in range(PUSH_ROUNDS):
        moved = False
        placed = [shapely.affinity.translate(p, *v) for p, v in zip(cpolys, t)]
        for i in range(len(cpolys)):
            for j in range(i + 1, len(cpolys)):
                d = placed[i].distance(placed[j])
                if d < GAP_MIN - 0.5:
                    v = (ccen[j] + t[j]) - (ccen[i] + t[i])
                    v = v / max(np.hypot(*v), 1e-9)
                    step = (GAP_MIN - d) / 2 + 1.0
                    t[i] -= v * step
                    t[j] += v * step
                    moved = True
        if not moved:
            break
    return t


def footprint(polys, t):
    return shapely.convex_hull(shapely.union_all([shapely.affinity.translate(p, *v) for p, v in zip(polys, t)])).area


def neighbours(polys, cen, t, cl):
    """Delaunay edges between districts of different clusters, pruned, then
    the shortest pruned edges put back until every cluster is reachable."""
    pc = cen + t
    tri = shapely.delaunay_triangles(shapely.MultiPoint(pc), only_edges=True)
    placed = [shapely.affinity.translate(p, *v) for p, v in zip(polys, t)]
    edges = set()
    for e in shapely.get_parts(tri):
        a, b = np.asarray(e.coords)
        i = int(np.argmin(np.hypot(*(pc - a).T)))
        j = int(np.argmin(np.hypot(*(pc - b).T)))
        if cl[i] != cl[j]:
            edges.add((min(i, j), max(i, j)))
    L = {e: float(np.hypot(*(pc[e[0]] - pc[e[1]]))) for e in edges}
    short = np.full(len(polys), np.inf)
    for (i, j), l in L.items():
        short[i] = min(short[i], l)
        short[j] = min(short[j], l)
    keep, spare = [], []
    for (i, j), l in sorted(L.items(), key=lambda kv: kv[1]):
        line = LineString([pc[i], pc[j]])
        through = any(k not in (i, j) and line.intersects(placed[k]) for k in range(len(polys)))
        (spare if through or l > EDGE_MAX * min(short[i], short[j]) else keep).append((i, j, l, through))
    comp = list(range(max(cl) + 1))
    def find(i):
        while comp[i] != i:
            i = comp[i]
        return i
    for i, j, _, _ in keep:
        comp[find(cl[i])] = find(cl[j])
    for i, j, l, through in sorted(spare, key=lambda e: (e[3], e[2])):
        if find(cl[i]) != find(cl[j]):
            comp[find(cl[i])] = find(cl[j])
            keep.append((i, j, l, through))
    return [(i, j, l) for i, j, l, _ in sorted(keep, key=lambda e: (e[0], e[1]))]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("segment")
    ap.add_argument("--rho", type=float, default=1.75)
    ap.add_argument("--png")
    a = ap.parse_args()
    seg = json.load(open(os.path.join(a.segment, "segment.json"), encoding="utf-8"))
    dist = json.load(open(os.path.join(a.segment, "districts.json"), encoding="utf-8"))
    polys = district_polys(seg, dist)
    names = [d["name"] for d in dist["districts"]]
    area = np.array([p.area for p in polys])
    cen = np.array([p.centroid.coords[0] for p in polys])
    centre = (cen * area[:, None]).sum(0) / area.sum()
    A = area.sum() * (1 + a.rho)
    cl = clusters(polys)
    cpolys = [shapely.union_all([p for p, k in zip(polys, cl) if k == q]) for q in range(max(cl) + 1)]
    ccen = np.array([p.centroid.coords[0] for p in cpolys])
    for q in range(max(cl) + 1):
        if cl.count(q) > 1:
            print("cluster: " + ", ".join(n for n, k in zip(names, cl) if k == q))
    true_fp = footprint(polys, np.zeros_like(cen))
    print("districts %.2f km2, target footprint A %.2f km2, true footprint %.2f km2"
          % (area.sum() / 1e6, A / 1e6, true_fp / 1e6))
    if true_fp <= A:
        c, t = 1.0, np.zeros_like(cen)
    else:
        lo, hi = 0.05, 1.0
        for _ in range(30):
            c = (lo + hi) / 2
            if footprint(cpolys, place(cpolys, ccen, centre, c)) > A:
                hi = c
            else:
                lo = c
        c = lo
        t = place(cpolys, ccen, centre, c)[cl]
    fp = footprint(polys, t)
    print("c %.4f, footprint %.2f km2 (%.1f%% of A)" % (c, fp / 1e6, 100 * fp / A))
    edges = neighbours(polys, cen, t, cl)
    placed = [shapely.affinity.translate(p, *v) for p, v in zip(polys, t)]
    for i, j, l in edges:
        print("  %-26s - %-26s centres %5.0f m, gap %4.0f m (true %4.0f m)"
              % (names[i], names[j], l, placed[i].distance(placed[j]), polys[i].distance(polys[j])))
    gate = {"c": round(c, 4), "footprint_km2": round(fp / 1e6, 3), "target_km2": round(A / 1e6, 3),
            "within_5pct": bool(abs(fp / A - 1) <= 0.05 or c == 1.0), "edges": len(edges)}
    print("layout", json.dumps(gate))
    with open(os.path.join(a.segment, "layout.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"frame": seg["frame"], "rho": a.rho, "centre": centre.round(2).tolist(), "gate": gate,
                   "districts": [{"name": n, "centroid": cen[k].round(2).tolist(), "t": t[k].round(3).tolist(), "cluster": cl[k]}
                                 for k, n in enumerate(names)],
                   "edges": [{"a": names[i], "b": names[j], "centres_m": round(l, 1),
                              "gap_m": round(placed[i].distance(placed[j]), 1),
                              "true_gap_m": round(polys[i].distance(polys[j]), 1)} for i, j, l in edges]},
                  f, indent=1)
    if a.png:
        png(a.png, polys, placed, names, edges, cen + t)
    sys.exit(0 if gate["within_5pct"] else 1)


def png(path, polys, placed, names, edges, pc):
    from PIL import Image, ImageDraw, ImageFont
    allc = np.vstack([np.asarray(p.exterior.coords) for p in list(polys) + list(placed)])
    lo, hi = allc.min(0) - 800, allc.max(0) + 800
    ppm = 1400.0 / (hi - lo).max()
    W, H = np.ceil((hi - lo) * ppm).astype(int)
    im = Image.new("RGB", (int(W), int(H)), (246, 244, 238))
    dr = ImageDraw.Draw(im, "RGBA")
    px = lambda q: [((x - lo[0]) * ppm, (z - lo[1]) * ppm) for x, z in np.asarray(q)]
    for p in polys:
        for g in shapely.get_parts(p):
            dr.polygon(px(g.exterior.coords), outline=(150, 150, 150, 255))
    for i, j, _ in edges:
        dr.line(px([pc[i], pc[j]]), fill=(200, 60, 40, 255), width=3)
    for p in placed:
        for g in shapely.get_parts(p):
            dr.polygon(px(g.exterior.coords), fill=(67, 147, 195, 140))
    font = ImageFont.load_default(size=20) if hasattr(ImageFont, "load_default") else None
    for n, q in zip(names, pc):
        x, z = px([q])[0]
        dr.text((x - 50, z - 10), n, fill=(20, 20, 20), font=font)
    im.save(path)
    print("wrote", path, im.size)


main()

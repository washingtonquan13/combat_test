"""Phase 1 of COMPRESSION_PLAN.md: split a city download into patches (runs
of blocks sharing one street grid) and score them by what is worth keeping.

    python -I tools/blockout/parish_segment.py <raw dir> <out dir>

<raw dir> is what fetch_osm_city.py downloaded (bld_*.json, features.json,
boundary.json). <out dir> gets:

  segment.json   the frame, every block (ring, bearing, spread, patch,
      score, protected, arterial, landmarks), every patch (blocks,
      bearing, irregular, area, score) and the gate numbers below.
  segment.png    patches in colour by bearing, irregular ones grey, hard
      boundaries black, landmarks red.

A block is a face of the street graph. Its bearing is the length-weighted
mode of its edge directions mod 90, so a square grid at any rotation has
one bearing. Blocks grow into patches while their bearings agree within
GRID_TOL, and never across a hard boundary (a primary or bigger road, rail,
a canal, water, a levee): those are where the seams go later. A block
whose own edges disagree by more than IRREGULAR (a curvilinear suburb)
grows only with other such blocks and is never thinned.

Gate (printed, and in segment.json): share of street length inside
regular patches, the share of wikidata items that landed protected, and
the patch under each of a few named places, so a misread district shows.
"""
import argparse
import glob
import json
import math
import os
import sys
import time
from collections import defaultdict, deque

import numpy as np
import shapely
from shapely.geometry import LineString, Polygon

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compress import Frame  # noqa: E402

GRID_TOL = 7.0  # degrees two blocks' grids may differ by and still be one patch
CORE_R = 8000.0  # metres around Jackson Square: the old city, where thinning happens
IRREGULAR = 15.0  # a block whose own edges spread wider than this has no grid
MIN_PATCH = 40_000.0  # 4 ha: smaller patches merge into a neighbour
MIN_BLOCK = 200.0  # m2: slivers between carriageways are not blocks
HARD_ROADS = ("motorway", "trunk", "primary", "motorway_link", "trunk_link", "primary_link")
STREETS = HARD_ROADS + ("secondary", "tertiary", "secondary_link", "tertiary_link",
                        "residential", "unclassified", "living_street", "pedestrian")
ARTERIAL = ("motorway", "trunk", "primary", "secondary")
TALL = 40.0  # m: a building this tall is a landmark
PARK_MIN = 10_000.0  # m2: a park or stadium this big is a landmark
# Footprint percentile that makes a building a landmark. At the top 1%
# (1383 m2 in the parish) every corner pharmacy qualifies, and Uptown has
# one in nearly every row; the top 0.1% is hospitals, malls, terminals.
BIG_PCT = 99.9

# A few places a reader knows, to check the segmentation against.
PLACES = {
    "Jackson Square": (29.95745, -90.06296),
    "Superdome": (29.95112, -90.08122),
    "Lafayette Square": (29.94860, -90.07084),
    "Washington Square": (29.96526, -90.05722),
    "Audubon Park": (29.92569, -90.12497),
    "City Park": (29.99341, -90.09809),
    "Lower Garden District": (29.93530, -90.07330),
    "Mid-City (Canal/Carrollton)": (29.97370, -90.10030),
}


def log(msg, t0=time.time()):
    print("%6.1fs %s" % (time.time() - t0, msg), flush=True)


def bearing_mode(coords):
    """Length-weighted mode of edge directions mod 90 and their spread.
    Directions are doubled twice (x4) so 0/90/180/270 agree, averaged as
    vectors around the histogram peak."""
    d = np.diff(coords, axis=0)
    ln = np.hypot(d[:, 0], d[:, 1])
    ok = ln > 0.5
    if not ok.any():
        return 0.0, 90.0
    d, ln = d[ok], ln[ok]
    a = np.degrees(np.arctan2(d[:, 1], d[:, 0])) % 90.0
    hist = np.zeros(90)
    np.add.at(hist, a.astype(int) % 90, ln)
    k = np.array([1, 2, 3, 2, 1], float)
    sm = sum(np.roll(hist, i - 2) * k[i] for i in range(5))
    peak = float(np.argmax(sm)) + 0.5
    off = (a - peak + 45.0) % 90.0 - 45.0
    near = np.abs(off) < 10.0
    mode = (peak + np.average(off[near], weights=ln[near])) % 90.0 if near.any() else peak
    off = (a - mode + 45.0) % 90.0 - 45.0
    spread = float(np.sqrt(np.average(off ** 2, weights=ln)))
    return float(mode), spread


def adiff(a, b):
    return abs((a - b + 45.0) % 90.0 - 45.0)


def load(raw):
    rel = json.load(open(os.path.join(raw, "boundary.json"), encoding="utf-8"))["elements"][0]
    pts = [p for m in rel["members"] if m["type"] == "way" for p in m.get("geometry") or [] if p]
    s, w = min(p["lat"] for p in pts), min(p["lon"] for p in pts)
    n, e = max(p["lat"] for p in pts), max(p["lon"] for p in pts)
    frame = Frame.of_bbox(s, w, n, e)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from osm_city import _join, _area
    ways = [m for m in rel["members"] if m["type"] == "way"]
    outer = _join([m["geometry"] for m in ways if m.get("role") != "inner"])[0]
    inner = _join([m["geometry"] for m in ways if m.get("role") == "inner"])[0]

    def ring(g):
        g = [p for p in g if p]
        x, z = frame.xz([p["lon"] for p in g], [p["lat"] for p in g])
        return list(zip(x.tolist(), z.tolist()))

    region = shapely.make_valid(_area([ring(r) for r in outer], [ring(r) for r in inner]))
    feats = json.load(open(os.path.join(raw, "features.json"), encoding="utf-8"))["elements"]
    return frame, (s, w, n, e), region, feats, ring, _join, _area


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("out")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    frame, bbox, region, feats, ring, _join, _area = load(args.raw)
    log("region %.1f km2, %d features" % (region.area / 1e6, len(feats)))

    # --- Lines: streets, hard boundaries, water ---------------------------
    streets, hard, art = [], [], []
    water = []
    landmarks = []  # (point, name, why)
    for el in feats:
        t = el.get("tags", {})
        if el["type"] == "way" and "geometry" in el:
            g = ring(el["geometry"])
            if len(g) < 2:
                continue
            closed = len(g) > 3 and g[0] == g[-1]
            hw = t.get("highway")
            if hw in STREETS and not closed and t.get("area") != "yes":
                ln = LineString(g)
                streets.append((ln, hw, el["id"]))
                if hw in HARD_ROADS:
                    hard.append(ln)
                if hw in ARTERIAL:
                    art.append(ln)
            elif t.get("railway") == "rail" and t.get("service") is None:
                hard.append(LineString(g))
            elif t.get("waterway") in ("canal", "river") and t.get("tunnel", "no") == "no":
                hard.append(LineString(g))
            elif t.get("man_made") == "dyke" and not closed:
                hard.append(LineString(g))
            if closed and (t.get("natural") == "water" or t.get("waterway") == "riverbank"):
                water.append(Polygon(g))
            poly = Polygon(g) if closed and len(g) > 3 else None
        elif el["type"] == "relation":
            outers = [m["geometry"] for m in el.get("members", []) if m.get("role") == "outer" and "geometry" in m]
            inners = [m["geometry"] for m in el.get("members", []) if m.get("role") == "inner" and "geometry" in m]
            if not outers:
                continue
            poly = _area([ring(r) for r in _join(outers)[0]], [ring(r) for r in _join(inners)[0]])
            if poly is None:
                continue
            poly = shapely.make_valid(poly)
            if t.get("natural") == "water" or t.get("waterway") == "riverbank":
                water.append(poly)
        else:
            continue
        why = None
        if "wikidata" in t:
            why = "wikidata"
        elif "historic" in t or "tourism" in t:
            why = "historic" if "historic" in t else "tourism"
        elif poly is not None and not poly.is_empty and (
                (t.get("leisure") in ("park", "stadium") and poly.area > PARK_MIN) or t.get("landuse") == "cemetery"):
            why = t.get("leisure") or "cemetery"
        if why and not (t.get("highway") or t.get("waterway") or t.get("railway")):
            geom = poly if poly is not None and not poly.is_empty else LineString(ring(el["geometry"])) if "geometry" in el else None
            if geom is not None and not geom.is_empty:
                landmarks.append((geom.representative_point(), t.get("name"), why, "wikidata" in t))
    log("streets %d (%.0f km), hard lines %d, water polys %d, feature landmarks %d"
        % (len(streets), sum(s[0].length for s in streets) / 1000, len(hard), len(water), len(landmarks)))

    # Buildings: landmarks by tag, height, or footprint; named ones score filler.
    bld_pts, bld_named = [], []
    areas = []
    blds = []
    for path in sorted(glob.glob(os.path.join(args.raw, "bld_*.json"))):
        for el in json.load(open(path, encoding="utf-8"))["elements"]:
            if el["type"] != "way" or "geometry" not in el:
                continue
            g = ring(el["geometry"])
            if len(g) < 4:
                continue
            p = Polygon(g)
            t = el.get("tags", {})
            try:
                h = float(str(t.get("height", "0")).split()[0])
            except ValueError:
                h = 0.0
            blds.append((p, t, h))
            areas.append(abs(p.area))
    big = np.percentile(areas, BIG_PCT)
    for p, t, h in blds:
        c = p.representative_point() if p.is_valid else p.centroid
        why = ("wikidata" if "wikidata" in t else "historic" if "historic" in t else
               "tourism" if "tourism" in t else "tall" if h >= TALL else "big" if abs(p.area) >= big else None)
        if why:
            landmarks.append((c, t.get("name"), why, "wikidata" in t))
        if "name" in t:
            bld_named.append(c)
        bld_pts.append(c)
    log("buildings %d (top-%g%% footprint %.0f m2), landmarks now %d" % (len(blds), 100 - BIG_PCT, big, len(landmarks)))
    del blds

    # --- Blocks: faces of the street + hard-line graph --------------------
    edge_lines = [s[0] for s in streets] + hard + [region.boundary]
    noded = shapely.union_all(shapely.line_merge(shapely.MultiLineString(
        [l for g in edge_lines for l in (getattr(g, "geoms", None) or [g]) if l.length > 0])))
    log("noded")
    faces = list(shapely.get_parts(shapely.polygonize(list(shapely.get_parts(noded)))))
    faces = np.array(faces, dtype=object)
    water = shapely.make_valid(np.array([w for w in water if w is not None and not w.is_empty], dtype=object))
    water = shapely.buffer(water[shapely.area(water) > 0], 0)
    water_u = shapely.union_all(water) if len(water) else Polygon()
    shapely.prepare(region)
    # A face is a block when most of its area is dry and in the parish: one
    # sample point would drop a park whenever it fell in the park's lagoon.
    fa = shapely.area(faces)
    keep = fa > MIN_BLOCK
    inside = shapely.contains(region, faces)
    edge = keep & ~inside & shapely.intersects(region, faces)
    inside[edge] = shapely.area(shapely.intersection(faces[edge], region)) > 0.5 * fa[edge]
    keep &= inside
    wet = np.zeros(len(faces))
    fi, wi = shapely.STRtree(water).query(faces, predicate="intersects")
    m = keep[fi]
    np.add.at(wet, fi[m], shapely.area(shapely.intersection(faces[fi[m]], water[wi[m]])))
    keep &= wet <= 0.5 * fa
    faces = faces[keep]
    log("blocks %d (of %d faces)" % (len(faces), len(keep)))

    n = len(faces)
    bear = np.zeros(n)
    spread = np.zeros(n)
    for i, f in enumerate(faces):
        bear[i], spread[i] = bearing_mode(np.asarray(f.exterior.coords))
    irregular = spread > IRREGULAR

    # --- Adjacency, with which shared edges are hard ----------------------
    hard_tree = shapely.STRtree(np.array(hard, dtype=object))
    tree = shapely.STRtree(faces)
    pa, pb = tree.query(faces, predicate="touches")
    m = pa < pb
    pa, pb = pa[m], pb[m]
    shared = shapely.intersection(shapely.boundary(faces[pa]), shapely.boundary(faces[pb]))
    slen = shapely.length(shared)
    m = slen > 1.0
    pa, pb, shared, slen = pa[m], pb[m], shared[m], slen[m]
    # The share of each edge lying on a hard line, from 9 points along it:
    # an index query per point, not an overlay against one giant buffer.
    fr = np.linspace(0.05, 0.95, 9)
    pts = shapely.line_interpolate_point(np.repeat(shared, len(fr)), np.tile(fr, len(shared)), normalized=True)
    near = np.zeros(len(pts), bool)
    near[np.unique(hard_tree.query(pts, predicate="dwithin", distance=2.0)[0])] = True
    is_hard = near.reshape(-1, len(fr)).mean(axis=1) > 0.5
    log("adjacent pairs %d, %d across hard lines" % (len(pa), int(is_hard.sum())))
    nbrs = defaultdict(list)
    for a, b, L, h in zip(pa.tolist(), pb.tolist(), slen.tolist(), is_hard.tolist()):
        nbrs[a].append((b, L, h))
        nbrs[b].append((a, L, h))

    # --- Grow patches: biggest regular block first ------------------------
    area = shapely.area(faces)
    patch = -np.ones(n, int)
    pbear = []
    pirr = []
    for seed in np.argsort(-area - irregular * 1e12):
        if patch[seed] >= 0:
            continue
        pid = len(pbear)
        patch[seed] = pid
        irr = bool(irregular[seed])
        # Running circular mean of 4*bearing, weighted by area.
        cx = area[seed] * math.cos(math.radians(4 * bear[seed]))
        cz = area[seed] * math.sin(math.radians(4 * bear[seed]))
        q = deque([seed])
        while q:
            i = q.popleft()
            mean = (math.degrees(math.atan2(cz, cx)) / 4) % 90
            for j, L, h in nbrs[i]:
                if patch[j] >= 0 or h or bool(irregular[j]) != irr:
                    continue
                if not irr and adiff(bear[j], mean) > GRID_TOL:
                    continue
                patch[j] = pid
                cx += area[j] * math.cos(math.radians(4 * bear[j]))
                cz += area[j] * math.sin(math.radians(4 * bear[j]))
                q.append(j)
        pbear.append((math.degrees(math.atan2(cz, cx)) / 4) % 90)
        pirr.append(irr)
    log("patches grown %d" % len(pbear))

    # --- Merge small patches into the neighbour they share most with ------
    def patch_areas():
        return np.bincount(patch, weights=area, minlength=len(pbear))

    for _ in range(6):
        pa_ = patch_areas()
        small = [p for p in range(len(pbear)) if 0 < pa_[p] < MIN_PATCH]
        if not small:
            break
        moved = 0
        for p in sorted(small, key=lambda p: pa_[p]):
            members = np.nonzero(patch == p)[0]
            if not len(members):
                continue
            score = defaultdict(float)
            for i in members:
                for j, L, h in nbrs[i]:
                    q = patch[j]
                    if q != p:
                        # Prefer a soft border, then a matching grid.
                        score[q] += L * (0.1 if h else 1.0) * (2.0 if adiff(pbear[q], pbear[p]) < GRID_TOL else 1.0)
            if not score:
                continue
            tgt = max(score, key=score.get)
            patch[members] = tgt
            moved += 1
        if not moved:
            break
    # Renumber.
    used, patch = np.unique(patch, return_inverse=True)
    pbear = [pbear[u] for u in used]
    pirr = [pirr[u] for u in used]
    npatch = len(used)
    pa_ = np.bincount(patch, weights=area, minlength=npatch)
    # A merged patch's grid: recompute from its blocks; irregular if spread wide.
    for p in range(npatch):
        mem = patch == p
        w = area[mem]
        c = np.sum(w * np.cos(np.radians(4 * bear[mem])))
        s_ = np.sum(w * np.sin(np.radians(4 * bear[mem])))
        pbear[p] = (math.degrees(math.atan2(s_, c)) / 4) % 90
        off = np.array([adiff(b, pbear[p]) for b in bear[mem]])
        pirr[p] = bool(np.average(irregular[mem], weights=w) > 0.5 or np.sqrt(np.average(off ** 2, weights=w)) > IRREGULAR)
    log("patches after merge %d (%d irregular)" % (npatch, sum(pirr)))

    # --- Scores ------------------------------------------------------------
    lm_pts = np.array([l[0] for l in landmarks], dtype=object)
    li, bi = tree.query(lm_pts, predicate="within")
    lm_block = -np.ones(len(landmarks), int)
    lm_block[li] = bi
    # A landmark on a street or a park edge: nearest block within 30 m.
    miss = np.nonzero(lm_block < 0)[0]
    if len(miss):
        ii, bb = tree.query_nearest(lm_pts[miss], max_distance=30.0, return_distance=False)
        lm_block[miss[ii]] = bb
    named_n = np.zeros(n)
    if bld_named:
        ii, bb = tree.query(np.array(bld_named, dtype=object), predicate="within")
        np.add.at(named_n, bb, 1)
    bld_n = np.zeros(n)
    ii, bb = tree.query(np.array(bld_pts, dtype=object), predicate="within")
    np.add.at(bld_n, bb, 1)
    WEIGHT = {"wikidata": 10.0, "historic": 6.0, "tourism": 4.0, "stadium": 8.0, "park": 4.0,
              "cemetery": 4.0, "tall": 5.0, "big": 2.0}
    bscore = named_n * 0.5 + bld_n * 0.01
    protected = np.zeros(n, bool)
    blm = defaultdict(list)
    for k, (pt, name, why, wd) in enumerate(landmarks):
        b = lm_block[k]
        if b >= 0:
            bscore[b] += WEIGHT.get(why, 2.0)
            protected[b] = True
            blm[int(b)].append([name, why])
    # A block an arterial runs through (not along its edge), such as a median
    # polygon, is flagged apart from the landmarks: a strip the arterial
    # crosses square-on only shortens it, so thinning may still take that
    # row; what it must never do is run a band along it.
    art_u = shapely.union_all(np.array(art, dtype=object))
    arterial = shapely.length(shapely.intersection(faces, art_u)) > 20.0
    pscore = np.bincount(patch, weights=bscore, minlength=npatch) / np.maximum(pa_, 1.0) * 1e4
    log("landmarks placed %d/%d; protected blocks %d" % (int((lm_block >= 0).sum()), len(landmarks), int(protected.sum())))

    # --- Gate ---------------------------------------------------------------
    # Only what lies in the parish counts: the raw download is a bbox and
    # carries Jefferson Parish's streets and landmarks too.
    street_u = shapely.intersection(np.array([s[0] for s in streets], dtype=object), region)
    reg_buf = shapely.buffer(shapely.union_all(faces[~np.array(pirr)[patch]]), 3.0)
    jx, jz = frame.xz(PLACES["Jackson Square"][1], PLACES["Jackson Square"][0])
    core = shapely.intersection(region, shapely.buffer(shapely.points(float(jx), float(jz)), CORE_R))

    def share(area):
        on = shapely.intersection(street_u, area)
        return float(np.sum(shapely.length(shapely.intersection(on, reg_buf)))) / max(1.0, float(np.sum(shapely.length(on))))
    tot = float(np.sum(shapely.length(street_u)))
    shapely.prepare(region)
    wd = [k for k, l in enumerate(landmarks) if l[3] and region.contains(l[0])]
    wd_prot = sum(1 for k in wd if lm_block[k] >= 0)
    for k in wd:
        if lm_block[k] < 0:
            log("  wikidata item not on any block: %s" % (landmarks[k][1],))
    places = {}
    for name, (lat, lon) in PLACES.items():
        x, z = frame.xz(lon, lat)
        pt = shapely.points(float(x), float(z))
        hit = tree.query(pt, predicate="within")
        if not len(hit):
            hit = tree.query_nearest(pt, max_distance=60.0)
        if len(hit):
            p = int(patch[hit[0]])
            places[name] = {"patch": p, "bearing": round(pbear[p], 1), "irregular": pirr[p],
                            "patch_km2": round(pa_[p] / 1e6, 3), "blocks": int((patch == p).sum())}
        else:
            places[name] = None
    gate = {"street_km": round(tot / 1000, 1),
            "street_share_in_regular_patches": round(share(region), 3),
            "core_street_share_in_regular_patches": round(share(core), 3),
            "wikidata_items": len(wd), "wikidata_protected_share": round(wd_prot / max(1, len(wd)), 3),
            "patches": npatch, "irregular_patches": int(sum(pirr)), "blocks": n, "places": places}
    log("gate " + json.dumps(gate, indent=1))

    out = {
        "frame": [frame.lat0, frame.lon0], "bbox": list(bbox),
        "params": {"GRID_TOL": GRID_TOL, "IRREGULAR": IRREGULAR, "MIN_PATCH": MIN_PATCH},
        "gate": gate,
        "patches": [{"id": p, "bearing": round(pbear[p], 2), "irregular": pirr[p], "area": round(float(pa_[p]), 1),
                     "score": round(float(pscore[p]), 3), "blocks": np.nonzero(patch == p)[0].tolist()}
                    for p in range(npatch)],
        "blocks": [{"ring": np.round(np.asarray(f.exterior.coords), 2).tolist(), "bearing": round(bear[i], 2),
                    "spread": round(spread[i], 2), "patch": int(patch[i]), "score": round(float(bscore[i]), 2),
                    "protected": bool(protected[i]), "arterial": bool(arterial[i]), "landmarks": blm.get(i, [])}
                   for i, f in enumerate(faces)],
    }
    with open(os.path.join(args.out, "segment.json"), "w", encoding="utf-8") as f:
        json.dump(out, f)
    draw(os.path.join(args.out, "segment.png"), faces, patch, pbear, pirr, hard, landmarks, lm_block, frame)
    log("wrote %s" % args.out)


def draw(path, faces, patch, pbear, pirr, hard, landmarks, lm_block, frame, px=4096):
    from PIL import Image, ImageDraw
    import colorsys
    b = shapely.total_bounds(faces)
    sc = px / max(b[2] - b[0], b[3] - b[1])
    W, H = int((b[2] - b[0]) * sc) + 1, int((b[3] - b[1]) * sc) + 1
    img = Image.new("RGB", (W, H), (245, 243, 238))
    d = ImageDraw.Draw(img)

    def P(cs):
        return [((x - b[0]) * sc, (z - b[1]) * sc) for x, z in cs]

    rng = np.random.default_rng(7)
    lum = rng.uniform(0.45, 0.7, len(pbear))
    for i, f in enumerate(faces):
        p = patch[i]
        if pirr[p]:
            col = tuple(int(v * 255) for v in colorsys.hls_to_rgb(0, lum[p] + 0.15, 0))
        else:
            col = tuple(int(v * 255) for v in colorsys.hls_to_rgb(pbear[p] / 90.0, lum[p], 0.55))
        d.polygon(P(f.exterior.coords), fill=col)
    # Patch borders.
    for i, f in enumerate(faces):
        d.line(P(f.exterior.coords), fill=(255, 255, 255), width=1)
    for g in shapely.get_parts(np.array(hard, dtype=object)):
        d.line(P(g.coords), fill=(20, 20, 20), width=2)
    for k, (pt, name, why, wd) in enumerate(landmarks):
        if why in ("wikidata", "historic", "tourism", "stadium"):
            x, z = P([(pt.x, pt.y)])[0]
            d.ellipse([x - 2, z - 2, x + 2, z + 2], fill=(200, 20, 20))
    img.save(path)


if __name__ == "__main__":
    main()

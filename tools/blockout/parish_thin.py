"""Phase 2 of COMPRESSION_PLAN.md (the go/no-go): thin one patch by taking
whole rows of blocks out of its street grid, and check that the result is
exact.

    python -I tools/blockout/parish_thin.py <segment dir> <raw dir> <patch id> <out dir>
        [--keep 0.6] [--family DEG]

<segment dir> is parish_segment.py's output, <raw dir> the download it
read. <out dir> gets:

  orig/      the raw download clipped to the patch (plus a margin), the
      uncompressed reference build's input.
  thin/      orig/ with the chosen rows cut out by compress.py.
  cuts.json, frame.json   what compress.py was run with.
  thin.json  the rows, the bands, and the gate below.

A row is the strip between two neighbouring streets of one family (the
streets running one way through the grid). Taking a row out means one
compress.py band: it deletes the street between the row and the next one
(and so one street of the family), and the cross streets close up across
it. That is exact only when the band's two edges run in the row's gaps and
the cross streets meet it square-on, so the band is fitted per run of
removed rows: its angle is the one that leaves the most room between the
streets it keeps and the ones it deletes, and each edge sits where it cuts
the fewest buildings.

A row is eligible when no protected block (a landmark) touches it, no
hard way (a primary road or bigger, rail, water) runs along it, every
street crossing it does so within CROSS_MAX of square, a band can be
fitted at all, and it does not touch the patch's own edge (the seams need
real streets there). Of eligible rows the lowest scored go first, never
more than 2 of any 3 in a row, until the removed width reaches
(1 - keep) of the patch's extent across the family.

Gate (the plan's go/no-go, all in thin.json):
  chords      cross-street joins whose bearing turns more than CHORD_DEG
              with a jog longer than JOG_MIN: must be 0.
  dead ends   street nodes of degree 1 inside the patch, after vs before:
              no new ones.
  landmarks   every protected block moved by one rigid translation.
  decks       no bridge or elevated way touched by a band.
"""
import argparse
import glob
import json
import math
import os
import sys
from collections import defaultdict

import numpy as np
import shapely
from shapely.geometry import LineString, Polygon

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compress  # noqa: E402
from compress import Cuts, Frame  # noqa: E402

MARGIN = 40.0  # m: clip margin around the patch
BOUNDARY = 25.0  # m: the fog wall's offset from the patch
FAMILY_MIN = 300.0  # m: a street this long inside the patch defines a grid line
FAMILY_TOL = 15.0  # deg: mean deviation from the family bearing that still counts
CROSS_MAX = 10.0  # deg: a street crossing a removed row must be this close to square
EDGE_CLEAR = 3.0  # m: a band edge stays this far from the streets either side of it
CHORD_DEG = 3.0
JOG_MIN = 2.0  # m
SKIP = ("service", "footway", "path", "cycleway", "steps", "track", "bridleway", "corridor",
        "construction", "proposed", "pedestrian")
HARD_HW = ("motorway", "trunk", "primary", "motorway_link", "trunk_link", "primary_link")


def log(msg):
    print(msg, flush=True)


def xz_of(fr, geom):
    pts = [(i, q) for i, q in enumerate(geom) if q]
    if not pts:
        return [], np.zeros((0, 2))
    x, z = fr.xz(np.array([q["lon"] for _, q in pts]), np.array([q["lat"] for _, q in pts]))
    return [i for i, _ in pts], np.c_[x, z]


def is_street(t):
    return t.get("highway") and t["highway"] not in SKIP and t.get("area") != "yes"


def is_deck(t):
    try:
        layer = int(str(t.get("layer", "0")).split(";")[0])
    except ValueError:
        layer = 0
    return t.get("bridge") not in (None, "no") or layer > 0


# --- clip ---------------------------------------------------------------------
def clip_way(el, fr, C):
    """The parts of a way inside C, as ways. An open way keeps each run of
    nodes inside plus one node beyond each end, so a street leaving the
    clip still reaches its edge; a ring is kept whole if its centroid is
    inside, else dropped."""
    geom = el.get("geometry") or []
    idx, xz = xz_of(fr, geom)
    if len(idx) < 2:
        return []
    closed = len(geom) > 3 and geom[0] == geom[-1]
    if closed:
        ring = xz[:-1] if len(xz) > 3 else xz
        return [el] if C.contains(shapely.Point(ring.mean(0))) else []
    inside = shapely.contains_xy(C, xz[:, 0], xz[:, 1])
    if inside.all():
        return [el]
    out, j, k = [], 0, 0
    while j < len(idx):
        if not inside[j]:
            j += 1
            continue
        k = j
        while k + 1 < len(idx) and inside[k + 1]:
            k += 1
        lo, hi = max(0, j - 1), min(len(idx) - 1, k + 1)
        if hi > lo:
            sel = idx[lo:hi + 1]
            e = dict(el)
            e["geometry"] = [geom[i] for i in sel]
            if el.get("nodes") and len(el["nodes"]) == len(geom):
                e["nodes"] = [el["nodes"][i] for i in sel]
            if out:
                e["id"] = -(abs(el["id"]) * 100 + len(out))
            e["bounds"] = compress._bounds(e["geometry"])
            out.append(e)
        j = k + 1
    return out


def clip_relation(el, fr, C):
    pts = [q for m in el.get("members", []) for q in (m.get("geometry") or []) if q]
    if not pts:
        return []
    _, xz = xz_of(fr, pts)
    return [el] if shapely.contains_xy(C, xz[:, 0], xz[:, 1]).all() else []


def clip_raw(raw, out, fr, C):
    os.makedirs(out, exist_ok=True)
    counts = {}
    for path in sorted(glob.glob(os.path.join(raw, "*.json"))):
        name = os.path.basename(path)
        if name == "boundary.json":
            continue
        data = json.load(open(path, encoding="utf-8"))
        els = []
        for el in data.get("elements", []):
            t = el.get("type")
            if t == "way":
                els += clip_way(el, fr, C)
            elif t == "relation":
                els += clip_relation(el, fr, C)
            elif t == "node" and "lat" in el:
                x, z = fr.xz(el["lon"], el["lat"])
                if C.contains(shapely.Point(x, z)):
                    els.append(el)
        if els or not name.startswith("bld_"):
            data["elements"] = els
            compress.write_file(os.path.join(out, name), data)
            counts[name] = len(els)
    return counts


def write_boundary(path, fr, ring_xz):
    lon, lat = fr.lonlat(ring_xz[:, 0], ring_xz[:, 1])
    geom = [{"lat": float(round(a, compress.DP)), "lon": float(round(o, compress.DP))} for a, o in zip(lat, lon)]
    if geom[0] != geom[-1]:
        geom.append(dict(geom[0]))
    rel = {"type": "relation", "id": -1, "tags": {"boundary": "administrative", "name": "patch"},
           "members": [{"type": "way", "ref": -1, "role": "outer", "geometry": geom}]}
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"elements": [rel]}, f)


# --- grid lines -------------------------------------------------------------------
def grid_lines(feats, fr, P, family):
    """The streets of one family inside P: name -> densified points."""
    Pb = P.buffer(5.0)
    shapely.prepare(Pb)
    parts = defaultdict(list)
    for el in feats:
        t = el.get("tags", {})
        if el["type"] != "way" or not is_street(t):
            continue
        _, xz = xz_of(fr, el.get("geometry") or [])
        if len(xz) < 2:
            continue
        for part in shapely.get_parts(shapely.intersection(LineString(xz), Pb)):
            if part.geom_type == "LineString" and part.length > 1:
                parts[t.get("name") or "#%d" % el["id"]].append(np.asarray(part.coords))
    lines = {}
    for name, ps in parts.items():
        d = np.vstack([np.diff(q, axis=0) for q in ps])
        L = np.hypot(d[:, 0], d[:, 1])
        if L.sum() < FAMILY_MIN:
            continue
        a = np.degrees(np.arctan2(d[:, 1], d[:, 0]))
        off = (a - family + 90) % 180 - 90
        if np.average(np.abs(off), weights=L) > FAMILY_TOL:
            continue
        lines[name] = np.vstack([np.asarray(LineString(q).segmentize(5.0).coords) for q in ps])
    return lines


def straightness(lines):
    """Length-weighted mean straightness residual of a family (m)."""
    res = []
    for pts in lines.values():
        c = pts - pts.mean(0)
        _, _, vt = np.linalg.svd(c, full_matrices=False)
        r = c @ np.array([-vt[0][1], vt[0][0]])
        res.append((np.ptp(r), np.ptp(c @ vt[0])))
    if not res:
        return float("inf")
    r = np.array(res)
    return float(np.average(r[:, 0], weights=r[:, 1]))


def across(angle):
    a = math.radians(angle + 90.0)
    return np.array([math.cos(a), math.sin(a)])


def along(g, n):
    """Length of g running within 45 deg of perpendicular to n (m)."""
    tot = 0.0
    for part in shapely.get_parts(g):
        if part.geom_type != "LineString":
            continue
        d = np.diff(np.asarray(part.coords), axis=0)
        L = np.hypot(d[:, 0], d[:, 1])
        tot += float(L[np.abs(d @ n) < 0.7071 * np.maximum(L, 1e-9)].sum())
    return tot


# --- bands --------------------------------------------------------------------
def fit_band(keep_lo, gone, keep_hi, bld_edges, family):
    """A band deleting every line in `gone` and none of keep_lo/keep_hi:
    (angle, a, b, slack) or None. The angle is searched near the family's;
    each edge goes where the fewest building outlines cross it."""
    best = None
    for da in np.arange(-4.0, 4.01, 0.25):
        ang = family + da
        n = across(ang)
        lo_max = (keep_lo @ n).max() + EDGE_CLEAR
        g = np.vstack(gone) @ n
        hi_min = (keep_hi @ n).min() - EDGE_CLEAR
        a_rng = (lo_max, g.min() - EDGE_CLEAR)
        b_rng = (g.max() + EDGE_CLEAR, hi_min)
        slack = min(a_rng[1] - a_rng[0], b_rng[1] - b_rng[0])
        if slack <= 0:
            continue
        if best is None or slack > best[3]:
            best = (ang, a_rng, b_rng, slack)
    if best is None:
        return None
    ang, a_rng, b_rng, slack = best
    n = across(ang)
    lo, hi = bld_edges(n)  # per building: min and max u

    def place(r):
        cand = np.linspace(r[0], r[1], max(2, int(r[1] - r[0]) + 1))
        cost = [int(((lo < u) & (hi > u)).sum()) for u in cand]
        k = int(np.argmin(cost))
        return float(cand[k]), cost[k]

    a, ca = place(a_rng)
    b, cb = place(b_rng)
    return {"angle": float(ang), "a": a, "b": b, "slack": float(slack), "cut_buildings": ca + cb}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("segment")
    ap.add_argument("raw")
    ap.add_argument("patch", type=int)
    ap.add_argument("out")
    ap.add_argument("--keep", type=float, default=0.6)
    ap.add_argument("--family", type=float, help="bearing of the family whose rows go (default: the straighter)")
    a = ap.parse_args()
    if not 0.0 < a.keep <= 1.0:
        sys.exit("parish_thin: keep must be in (0, 1]")
    seg = json.load(open(os.path.join(a.segment, "segment.json"), encoding="utf-8"))
    fr = Frame(*seg["frame"])
    patch = seg["patches"][a.patch]
    if patch["irregular"]:
        sys.exit("parish_thin: patch %d is irregular; those are never thinned" % a.patch)
    B = seg["blocks"]
    bidx = patch["blocks"]
    blocks = np.array([Polygon(B[i]["ring"]) for i in bidx], dtype=object)
    P = shapely.union_all(blocks).buffer(1.0).buffer(-1.0)
    C = P.buffer(MARGIN)
    log("patch %d: %d blocks, %.2f km2, bearing %.1f" % (a.patch, len(bidx), P.area / 1e6, patch["bearing"]))

    # Clip.
    orig = os.path.join(a.out, "orig")
    counts = clip_raw(a.raw, orig, fr, C)
    ring = np.asarray(P.buffer(BOUNDARY).exterior.segmentize(25.0).coords)
    write_boundary(os.path.join(orig, "boundary.json"), fr, ring)
    log("clipped: %s" % ", ".join("%s %d" % kv for kv in counts.items() if kv[1]))

    feats = json.load(open(os.path.join(orig, "features.json"), encoding="utf-8"))["elements"]
    blds = []
    for path in sorted(glob.glob(os.path.join(orig, "bld_*.json"))):
        for el in json.load(open(path, encoding="utf-8"))["elements"]:
            if el["type"] == "way" and el.get("geometry"):
                _, xz = xz_of(fr, el["geometry"])
                if len(xz) >= 3:
                    blds.append(xz)

    # Family: the straighter of the two.
    fams = [a.family] if a.family is not None else [patch["bearing"], (patch["bearing"] + 90.0) % 180.0]
    scored = []
    for f in fams:
        ln = grid_lines(feats, fr, P, f)
        scored.append((straightness(ln), f, ln))
        log("family %.1f: %d lines, straightness residual %.1f m (length-weighted)" % (f, len(ln), scored[-1][0]))
    resid, family, lines = min(scored, key=lambda s: s[0])
    n0 = across(family)
    order = sorted(lines, key=lambda k: float(np.median(lines[k] @ n0)))
    L = [lines[k] for k in order]
    U = [float(np.median(p @ n0)) for p in L]
    log("family %.1f chosen: %d lines from %s to %s" % (family, len(L), order[0], order[-1]))

    def bld_edges(n):
        lo = np.array([(q @ n).min() for q in blds])
        hi = np.array([(q @ n).max() for q in blds])
        return lo, hi

    # Rows: row k lies between line k and k+1 and its band deletes line k+1.
    prot = [Polygon(B[i]["ring"]) for i in bidx if B[i]["protected"]]
    prot_u = shapely.union_all(np.array(prot, dtype=object)) if prot else None
    hard = []
    for el in feats:
        t = el.get("tags", {})
        if el["type"] != "way":
            continue
        if t.get("highway") in HARD_HW or t.get("railway") == "rail" or t.get("waterway") in ("canal", "river"):
            _, xz = xz_of(fr, el.get("geometry") or [])
            if len(xz) > 1:
                hard.append(LineString(xz))
    hard_u = shapely.union_all(np.array(hard, dtype=object)) if hard else None
    streets = []
    for el in feats:
        t = el.get("tags", {})
        if el["type"] == "way" and is_street(t):
            _, xz = xz_of(fr, el.get("geometry") or [])
            if len(xz) > 1:
                streets.append((LineString(xz), t.get("name") or "", t["highway"]))
    s_geom = np.array([s[0] for s in streets], dtype=object)
    s_tree = shapely.STRtree(s_geom)
    bscore = {i: B[i]["score"] for i in bidx}
    b_tree = shapely.STRtree(blocks)

    rows = []
    for k in range(len(L) - 2):  # row k deletes line k+1, keeps lines k and k+2
        r = {"k": k, "lo": order[k], "gone": order[k + 1], "hi": order[k + 2], "why": []}
        band = fit_band(L[k], [L[k + 1]], L[k + 2], bld_edges, family)
        if band is None:
            r["why"].append("no straight band fits between the bent streets")
            rows.append(r)
            continue
        r.update(band)
        n = across(band["angle"])
        # Band region inside the patch, for the checks.
        big = 1e5
        d = np.array([n[1], -n[0]])
        quad = Polygon([band["a"] * n - big * d, band["a"] * n + big * d, band["b"] * n + big * d, band["b"] * n - big * d])
        region = shapely.intersection(quad, C)
        r["region"] = region
        if k == 0 or k == len(L) - 3:
            r["why"].append("touches the patch edge")
        if prot_u is not None and shapely.intersection(region, prot_u).area > 1.0:
            r["why"].append("protected block")
        if hard_u is not None and along(shapely.intersection(region, hard_u), n) > 20.0:
            r["why"].append("hard way runs along it")
        worst = 0.0
        for j in s_tree.query(region, predicate="intersects"):
            g, name, cls = streets[j]
            if name == r["gone"]:
                continue
            for part in shapely.get_parts(shapely.intersection(g, region)):
                if part.geom_type != "LineString" or part.length < 3.0:
                    continue
                c = np.asarray(part.coords) @ n
                if c.min() > band["a"] + 0.5 or c.max() < band["b"] - 0.5:
                    continue  # does not cross the band; the dead-end check sees it
                c = np.asarray(part.coords)
                v = c[-1] - c[0]
                off = math.degrees(math.acos(min(1.0, abs(v @ n) / max(1e-9, np.hypot(*v)))))
                worst = max(worst, off)
        r["cross_worst"] = round(worst, 1)
        if worst > CROSS_MAX:
            r["why"].append("a street crosses %.0f deg off square" % worst)
        hit = b_tree.query(region, predicate="intersects")
        r["score"] = float(sum(bscore[bidx[i]] * shapely.intersection(blocks[i], region).area / blocks[i].area for i in hit))
        rows.append(r)

    extent = U[-1] - U[0]
    target = (1.0 - a.keep) * extent
    eligible = sorted([r for r in rows if not r["why"]], key=lambda r: r["score"])
    chosen = set()
    removed = 0.0
    for r in eligible:
        if removed >= target:
            break
        k = r["k"]
        if any({k + d, k + d + 1, k + d + 2} - {k} <= chosen for d in (-2, -1, 0)):
            continue  # would make 3 consecutive removed rows
        # Neighbouring removed rows share a gap: refit them as one band.
        chosen.add(k)
        removed += r["b"] - r["a"]
    log("rows: %d, eligible %d, chosen %d; removing %.0f of %.0f m (target %.0f)"
        % (len(rows), len(eligible), len(chosen), removed, extent, target))
    for r in rows:
        log("  row %2d %-24s %s %s" % (r["k"], r["gone"][:24], "CUT " if r["k"] in chosen else "    ",
                                       "; ".join(r["why"]) or "ok (score %.1f, cross %.1f deg, slack %.0f m, %d buildings cut)"
                                       % (r["score"], r["cross_worst"], r["slack"], r["cut_buildings"])))

    # Runs of adjacent chosen rows become one band.
    runs, cur = [], []
    for k in sorted(chosen):
        if cur and k != cur[-1] + 1:
            runs.append(cur)
            cur = []
        cur.append(k)
    if cur:
        runs.append(cur)
    bands = []
    for run in runs:
        k0, k1 = run[0], run[-1]
        band = fit_band(L[k0], [L[k] for k in range(k0 + 1, k1 + 2)], L[k1 + 2], bld_edges, family)
        if band is None:
            log("run %s: no single band fits; dropped" % run)
            continue
        band["rows"] = run
        band["gone"] = [order[k] for k in range(k0 + 1, k1 + 2)]
        bands.append(band)
    if not bands:
        sys.exit("parish_thin: nothing to cut")
    # compress.py applies bands in order, each in the map the earlier ones
    # left: cutting the farthest first leaves the nearer ones where they were.
    bands.sort(key=lambda b: -b["a"])
    specs = []
    for b in bands:
        n = across(b["angle"])
        mid = (b["a"] + b["b"]) / 2
        cen = mid * n
        specs.append({"name": "/".join(g[:14] for g in b["gone"]), "centre": [round(float(cen[0]), 3), round(float(cen[1]), 3)],
                      "angle": round(b["angle"], 4), "width": round(b["b"] - b["a"], 3), "keep": 0.0})
    xs, zs = np.asarray(C.exterior.coords).T
    w, s_ = fr.lonlat(xs.min(), zs.max())
    e, n_ = fr.lonlat(xs.max(), zs.min())
    with open(os.path.join(a.out, "frame.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"origin": [fr.lat0, fr.lon0], "bbox": [float(s_), float(w), float(n_), float(e)]}, f)
    with open(os.path.join(a.out, "cuts.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"frame": os.path.abspath(os.path.join(a.out, "frame.json")), "cuts": specs}, f, indent=1)
    cuts = Cuts(specs)

    # compress.py does the moving; its report goes to thin/compress.json.
    thin = os.path.join(a.out, "thin")
    import subprocess
    rc = subprocess.run([sys.executable, "-I", os.path.join(HERE, "compress.py"), os.path.join(a.out, "cuts.json"),
                         orig, thin, "--lidar", ""], capture_output=True, text=True)
    if rc.returncode:
        sys.exit("parish_thin: compress.py failed:\n" + rc.stdout + rc.stderr)
    keep, wx, wz, _, _, _ = cuts.line(ring[:, 0], ring[:, 1], "closed")
    write_boundary(os.path.join(thin, "boundary.json"), fr, np.c_[wx[keep], wz[keep]])

    gate = check(feats, os.path.join(thin, "features.json"), fr, cuts, P, [B[i] for i in bidx if B[i]["protected"]])
    gate["removed_m"] = round(sum(b["b"] - b["a"] for b in bands), 1)
    gate["extent_m"] = round(extent, 1)
    gate["keep_across"] = round(1 - gate["removed_m"] / extent, 3)
    gate["buildings_cut"] = sum(b["cut_buildings"] for b in bands)
    gate["pass"] = gate["chords"] == 0 and gate["new_dead_ends"] <= 0 and gate["landmarks_bent"] == 0 and gate["decks_touched"] == 0
    log("gate " + json.dumps({k: v for k, v in gate.items() if k not in ("chord_list",)}, indent=1))
    for c in gate["chord_list"][:15]:
        log("  chord %-28s turn %5.1f deg, jog %5.1f m" % (c[0][:28], c[1], c[2]))
    with open(os.path.join(a.out, "thin.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"patch": a.patch, "family": family, "straightness_m": resid, "keep": a.keep,
                   "rows": [{k: v for k, v in r.items() if k != "region"} for r in rows],
                   "bands": bands, "cuts": specs, "gate": gate}, f, indent=1)


def degree1(feats, fr, P):
    """Street nodes of degree 1 inside P (away from the clip edge)."""
    deg = defaultdict(int)
    pos = {}
    for el in feats:
        t = el.get("tags", {})
        if el["type"] != "way" or not is_street(t) or not el.get("nodes"):
            continue
        geom = el.get("geometry") or []
        nodes = el["nodes"]
        if len(nodes) != len(geom):
            continue
        for j, nd in enumerate(nodes):
            deg[nd] += (j > 0) + (j < len(nodes) - 1)
            if geom[j]:
                pos[nd] = geom[j]
    ends = [nd for nd, d in deg.items() if d == 1 and nd in pos]
    if not ends:
        return set()
    x, z = fr.xz(np.array([pos[n]["lon"] for n in ends]), np.array([pos[n]["lat"] for n in ends]))
    return {n for n, ok in zip(ends, shapely.contains_xy(P, x, z)) if ok}


def check(feats, thin_path, fr, cuts, P, prot_blocks):
    # Chords: every street whose nodes a band deleted, rejoined across it.
    chords = []
    decks = 0
    for el in feats:
        t = el.get("tags", {})
        if el["type"] != "way":
            continue
        _, xz = xz_of(fr, el.get("geometry") or [])
        if len(xz) < 2:
            continue
        keep, px, pz, _, deleted_by, _ = cuts.line(xz[:, 0], xz[:, 1], "open")
        if keep.all():
            continue
        if is_deck(t):
            decks += 1
        if not is_street(t):
            continue
        kept = np.flatnonzero(keep)
        for i, j in zip(kept, kept[1:]):
            if j == i + 1:
                continue
            new = np.array([px[j] - px[i], pz[j] - pz[i]])
            jog_len = float(np.hypot(*new))
            if jog_len < JOG_MIN:
                continue
            # The street's own direction either side of the gap.
            v0 = xz[i] - xz[max(0, i - 1)] if i > 0 else xz[j] - xz[i]
            v1 = xz[min(len(xz) - 1, j + 1)] - xz[j] if j < len(xz) - 1 else v0
            ref = v0 / max(1e-9, np.hypot(*v0)) + v1 / max(1e-9, np.hypot(*v1))
            turn = math.degrees(math.acos(min(1.0, abs(new @ ref) / max(1e-9, np.hypot(*ref) * jog_len))))
            if turn > CHORD_DEG:
                jog = jog_len * math.sin(math.radians(turn))
                if jog > JOG_MIN:
                    chords.append((t.get("name") or t["highway"], round(turn, 1), round(jog, 1)))
    # Dead ends inside the patch, before and after (the thinned patch is
    # P moved through the cuts).
    before = degree1(feats, fr, P)
    pr = np.asarray(P.exterior.coords)
    k, wx, wz, _, _, _ = cuts.line(pr[:, 0], pr[:, 1], "closed")
    Pn = Polygon(np.c_[wx[k], wz[k]]).buffer(0)
    after = degree1(json.load(open(thin_path, encoding="utf-8"))["elements"], fr, Pn)
    # Landmarks: one translation per protected block.
    bent = []
    for b in prot_blocks:
        r = np.asarray(b["ring"])
        k, wx, wz, _, _, _ = cuts.line(r[:, 0], r[:, 1], "closed")
        d = np.c_[wx - r[:, 0], wz - r[:, 1]]
        if not k.all() or np.ptp(d[:, 0]) > 0.01 or np.ptp(d[:, 1]) > 0.01:
            bent.append([n for n, _ in b["landmarks"]][:2])
    chords.sort(key=lambda c: -c[2])
    return {"chords": len(chords), "max_jog_m": chords[0][2] if chords else 0.0, "chord_list": chords,
            "dead_ends_before": len(before), "dead_ends_after": len(after), "new_dead_ends": len(after) - len(before),
            "landmarks": len(prot_blocks), "landmarks_bent": len(bent), "bent": bent[:10], "decks_touched": decks}


if __name__ == "__main__":
    main()

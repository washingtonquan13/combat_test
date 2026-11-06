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
  chords      streets rejoined across a band whose moved far part misses
              the near node by more than JOG_MIN: must be 0.
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
JOG_MIN = 1.0  # m: a rejoined street this far off its own line is a chord
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
RENAME_TOL = 25.0  # deg: a street renamed where it runs straight on


def line_key(t, el):
    """A street's line identity: its stroke (see strokes), else its name."""
    return t.get("_line") or t.get("name") or "#%d" % el["id"]


def strokes(feats):
    """Tag every named street with the stroke it belongs to, in "_line":
    where one name's way ends and another name's way begins at the same
    node, running straight on, they are one street renamed (Melpomene
    becomes Martin Luther King Jr Boulevard) and form one grid line."""
    ends = defaultdict(list)  # node -> (name, unit direction leaving the node)
    for el in feats:
        t = el.get("tags", {})
        g = [q for q in el.get("geometry") or [] if q]
        if el["type"] != "way" or not is_street(t) or not t.get("name") or is_deck(t) or len(g) < 2:
            continue
        for a, b in ((g[0], g[1]), (g[-1], g[-2])):
            d = np.array([b["lon"] - a["lon"], (b["lat"] - a["lat"]) / math.cos(math.radians(a["lat"]))])
            ends[(round(a["lat"], 7), round(a["lon"], 7))].append((t["name"], d / max(np.hypot(*d), 1e-12)))
    parent = {}
    def root(x):
        while parent.get(x, x) != x:
            x = parent[x]
        return x
    cos_tol = math.cos(math.radians(180.0 - RENAME_TOL))
    for es in ends.values():
        names = defaultdict(list)
        for nm, d in es:
            names[nm].append(d)
        # Only names that end here can be renamed here; a name that carries
        # on through is a cross street. Of those, a pair leaving in opposite
        # directions runs straight on; join it only if it is the one pair.
        once = [(nm, ds[0]) for nm, ds in names.items() if len(ds) == 1]
        straight = [(a, b) for i, (a, da) in enumerate(once) for b, db in once[i + 1:] if float(da @ db) <= cos_tol]
        if len(straight) != 1:
            continue
        a, b = straight[0]
        ra, rb = root(a), root(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)
    groups = defaultdict(set)
    for nm in list(parent):
        groups[root(nm)].add(nm)
    label = {}
    for r, ms in groups.items():
        ms.add(r)
        for nm in ms:
            label[nm] = " / ".join(sorted(ms))
    for el in feats:
        t = el.get("tags", {})
        if el["type"] == "way" and t.get("name") in label:
            t["_line"] = label[t["name"]]
    return sorted(set(label.values()))


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
                parts[line_key(t, el)].append(np.asarray(part.coords))
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


# --- curve bands ----------------------------------------------------------------
STEP = 2.0  # m: edge table spacing along the band
PAIR_NAMED, PAIR_UNNAMED = 40.0, 15.0  # m: how far apart in s one street's two crossings may be
STRAIN_MAX = 0.15  # change in shift per metre along the band, inside the patch (a fan stretches the far blocks)
CUT_MAX = 2  # buildings an edge may cut
GAP_MAX = 40.0  # m: a gap in an edge street this short is an intersection, not an end
HELD_MAX = 10.0  # m: edge inside the patch with no street under it


def family_parts(feats, fr, C, name, family):
    """The runs of the named street that go with the family: every node the
    clip kept, not just those inside C, so the edge covers the whole street
    and none of the deleted one survives past it."""
    out = []
    for el in feats:
        t = el.get("tags", {})
        if el["type"] != "way" or not is_street(t) or line_key(t, el) != name:
            continue
        _, xz = xz_of(fr, el.get("geometry") or [])
        if len(xz) < 2:
            continue
        v = np.diff(xz, axis=0)
        off = (np.degrees(np.arctan2(v[:, 1], v[:, 0])) - family + 90) % 180 - 90
        ok = np.abs(off) < 30
        i = 0
        while i < len(ok):
            if not ok[i]:
                i += 1
                continue
            j = i
            while j + 1 < len(ok) and ok[j + 1]:
                j += 1
            q = xz[i:j + 2]
            if LineString(q).length >= 1:
                out.append(q)
            i = j + 1
    return out


def real(parts, t, S):
    """Where along S an edge street actually exists: inside some part's s
    range, or in a gap under GAP_MAX between two parts (an intersection
    where the street jinks). Past the ends the envelope is only held."""
    m = np.zeros(len(S), bool)
    for q in parts:
        s = q @ t
        m |= (S >= s.min()) & (S <= s.max())
    idx = np.flatnonzero(m)
    for i, j in zip(idx[:-1], idx[1:]):
        if j > i + 1 and S[j] - S[i] <= GAP_MAX:
            m[i:j] = True
    return m


def envelope(parts, t, n, S):
    """u of the parts' highest-u point at each s, interpolated across gaps
    and held past the ends; None if a part doubles back along s."""
    u = np.full(len(S), -np.inf)
    for q in parts:
        s, w = q @ t, q @ n
        if np.all(np.diff(s) < 0):
            s, w = s[::-1], w[::-1]
        if np.any(np.diff(s) <= 0):
            return None
        m = (S >= s[0]) & (S <= s[-1])
        u[m] = np.maximum(u[m], np.interp(S[m], s, w))
    ok = np.isfinite(u)
    if not ok.any():
        return None
    return np.interp(S, S[ok], u[ok])


def crossings(g, curve):
    """Points where line g crosses the curve (a LineString)."""
    out = []
    for p in shapely.get_parts(shapely.intersection(g, curve)):
        if p.is_empty:
            continue
        if p.geom_type == "Point":
            out.append(np.array(p.coords[0]))
        elif p.geom_type == "LineString":
            out.append(np.asarray(p.coords).mean(0))
    return out


def ray(g, pb, t, n):
    """The cross street g past its far crossing pb, as (u, s) with u rising:
    followed from pb while it keeps moving away from the band."""
    part = min(shapely.get_parts(g), key=lambda p: p.distance(shapely.Point(pb)))
    q = np.asarray(part.segmentize(5.0).coords)
    i = int(np.argmin(np.hypot(*(q - pb).T)))
    u = q @ n
    step = 1 if (i + 1 < len(q) and u[i + 1] > u[i]) or i == 0 else -1
    if i + step < 0 or i + step >= len(q) or u[i + step] <= u[i]:
        step = -step
    out = [(float(pb @ n), float(pb @ t))]
    k = i + step
    while 0 <= k < len(q) and u[k] > out[-1][0] + 0.01:
        out.append((float(u[k]), float(q[k] @ t)))
        k += step
    return out


def curve_row(k, names, feats, fr, C, family, cross, S0, Pin, span=1):
    """Row k as a curve band: near edge = line k, far edge = line k+span,
    which goes with any between. Returns (spec, info) or (None, reason)."""
    t = np.array([math.cos(math.radians(family)), math.sin(math.radians(family))])
    n = across(family)
    pk = family_parts(feats, fr, C, names[k], family)
    pf = family_parts(feats, fr, C, names[k + span], family)
    if not pk or not pf:
        return None, "street not found in the clip"
    S = np.unique(np.concatenate([S0] + [q @ t for q in pk + pf]))
    S = S[np.concatenate([[True], np.diff(S) > 0.05])]
    near, far = envelope(pk, t, n, S), envelope(pf, t, n, S)
    if near is None or far is None:
        return None, "a street doubles back along the band"
    if np.any(far - near < 1.0):
        return None, "the two streets meet"
    nc = LineString(np.outer(S, t) + np.outer(near, n))
    fc = LineString(np.outer(S, t) + np.outer(far, n))
    held = 0.0
    for parts, c in ((pk, nc), (pf, fc)):
        q = np.asarray(c.coords)
        fake = ~real(parts, t, S) & shapely.contains_xy(Pin, q[:, 0], q[:, 1])
        held = max(held, float(np.diff(S)[fake[1:] & fake[:-1]].sum()))
    if held > HELD_MAX:
        return None, "an edge street ends inside the patch (%.0f m held)" % held
    samples, unpaired = [], []
    for key, g in cross:
        if key in names[k:k + span + 1]:
            continue
        a = crossings(g, nc)
        b = crossings(g, fc)
        if not a or not b:
            continue  # ends in the row: nothing to pair
        lim = PAIR_UNNAMED if key.startswith("#") else PAIR_NAMED
        sa = np.array([p @ t for p in a])
        for pb in b:
            j = int(np.argmin(np.abs(sa - pb @ t)))
            if abs(sa[j] - pb @ t) > lim:
                unpaired.append(key)
                continue
            d = a[j] - pb
            samples.append((float(pb @ t), float(d[0]), float(d[1]), bool(Pin.contains(shapely.Point(pb))),
                            ray(g, pb, t, n)))
    if not samples:
        return None, "no cross street pairs"
    samples.sort()
    merged = []
    for s_, dx, dz, ins, ln in samples:
        if merged and s_ - merged[-1][0][-1] < 1.0:
            for lst, v in zip(merged[-1], (s_, dx, dz, ins, ln)):
                lst.append(v)
        else:
            merged.append(([s_], [dx], [dz], [ins], [ln]))
    sh = np.array([[np.mean(m[0]), np.mean(m[1]), np.mean(m[2])] for m in merged])
    rays = [m[4][0] for m in merged]
    ins = np.array([all(m[3]) for m in merged])
    strain = 0.0
    if len(sh) > 1:
        st = np.hypot(np.diff(sh[:, 1]), np.diff(sh[:, 2])) / np.maximum(np.diff(sh[:, 0]), 1e-6)
        both = ins[:-1] & ins[1:]
        strain = float(st[both].max()) if both.any() else 0.0
    region = shapely.intersection(Polygon(np.r_[np.asarray(nc.coords), np.asarray(fc.coords)[::-1]]).buffer(0), C)
    spec = {"name": "%s row" % names[k + span][:24],
            "curve": {"angle": round(family, 4), "s": [round(float(v), 3) for v in S],
                      "near": [round(float(v), 3) for v in near], "far": [round(float(v), 3) for v in far],
                      "shift": [[round(float(v), 3) for v in r] for r in sh],
                      "rays": [[[round(float(v), 2) for v in p] for p in r] for r in rays]}}
    info = {"region": region, "strain": round(strain, 4), "unpaired": sorted(set(unpaired)), "samples": len(sh),
            "near_line": nc}
    return spec, info


def curve_main(a, fr, P, C, feats, blds, B, bidx, blocks, patch):
    """Rows as curve bands, for both families; the one removing more wins.
    Returns (family, extent, specs far first, bands, rows)."""
    hard, decks, cross_named, cross_ways, hw_of = [], [], defaultdict(list), [], defaultdict(set)
    for el in feats:
        t = el.get("tags", {})
        if el["type"] != "way":
            continue
        _, xz = xz_of(fr, el.get("geometry") or [])
        if len(xz) < 2:
            continue
        g = LineString(xz)
        if t.get("highway") in HARD_HW or t.get("railway") == "rail" or t.get("waterway") in ("canal", "river"):
            hard.append(g)
        if is_deck(t):
            decks.append(g)
        if is_street(t):
            if t.get("name"):
                cross_named[line_key(t, el)].append(g)
                hw_of[line_key(t, el)].add(t["highway"])
            else:
                cross_ways.append(("#%d" % el["id"], g))
    cross = [(k, shapely.line_merge(shapely.union_all(np.array(v, dtype=object)))) for k, v in cross_named.items()]
    cross += cross_ways
    hard_u = shapely.union_all(np.array(hard, dtype=object)) if hard else None
    deck_u = shapely.union_all(np.array(decks, dtype=object)) if decks else None
    prot = [Polygon(B[i]["ring"]) for i in bidx if B[i]["protected"]]
    prot_u = shapely.union_all(np.array(prot, dtype=object)) if prot else None
    bscore = {i: B[i]["score"] for i in bidx}
    b_tree = shapely.STRtree(blocks)
    bld_polys = np.array([Polygon(q) for q in blds if len(q) >= 4], dtype=object)
    bld_tree = shapely.STRtree(bld_polys)
    Pin = P.buffer(-5.0)

    results = []
    for family in ([a.family] if a.family is not None else [patch["bearing"], (patch["bearing"] + 90.0) % 180.0]):
        lines = grid_lines(feats, fr, P, family)
        n = across(family)
        t = np.array([math.cos(math.radians(family)), math.sin(math.radians(family))])
        order = sorted(lines, key=lambda k: float(np.median(lines[k] @ n)))
        if len(order) < 4:
            log("family %.1f: %d lines, too few" % (family, len(order)))
            continue
        extent = float(np.median(lines[order[-1]] @ n) - np.median(lines[order[0]] @ n))
        cs = np.asarray(C.exterior.coords) @ t
        S0 = np.arange(cs.min() - STEP, cs.max() + STEP, STEP)
        rows = []
        for k in range(len(order) - 2):
            r = {"k": k, "near": order[k], "gone": order[k + 1], "why": []}
            spec, info = curve_row(k, order, feats, fr, C, family, cross, S0, Pin)
            if spec is None:
                r["why"].append(info)
                rows.append(r)
                continue
            region = info["region"]
            band = compress.CurveBand(spec)
            if k == 0 or k == len(order) - 3:
                r["why"].append("touches the patch edge")
            if prot_u is not None and shapely.intersection(region, prot_u).area > 1.0:
                r["why"].append("protected block")
            if hw_of[order[k + 1]] & set(HARD_HW):
                r["why"].append("the deleted street is a hard way")
            elif hard_u is not None and along(shapely.intersection(region, hard_u), n) > 20.0:
                r["why"].append("hard way runs along it")
            if deck_u is not None and shapely.intersection(region, deck_u).length > 1.0:
                r["why"].append("a deck crosses it")
            if info["unpaired"]:
                r["why"].append("unpaired crossing: " + ", ".join(x[:16] for x in info["unpaired"][:3]))
            if info["strain"] > STRAIN_MAX:
                r["why"].append("strain %.3f" % info["strain"])
            cut = 0
            for j in bld_tree.query(region, predicate="intersects"):
                q = np.asarray(bld_polys[j].exterior.coords)
                sd = band.side(q[:, 0], q[:, 1])
                if sd.min() != sd.max() and Pin.contains(bld_polys[j].centroid):
                    cut += 1
            if cut > CUT_MAX:
                r["why"].append("%d buildings cut" % cut)
            pts = np.asarray(info["near_line"].coords)
            inside = shapely.contains_xy(Pin, pts[:, 0], pts[:, 1])
            w = np.array(spec["curve"]["far"]) - np.array(spec["curve"]["near"])
            r["width"] = float(np.median(w[inside] if inside.any() else w))
            hit = b_tree.query(region, predicate="intersects")
            r["score"] = float(sum(bscore[bidx[i]] * shapely.intersection(blocks[i], region).area / blocks[i].area for i in hit))
            r.update(strain=info["strain"], samples=info["samples"], cut_buildings=cut, spec=spec,
                     near_med=float(np.median(spec["curve"]["near"])))
            rows.append(r)
        target = (1.0 - a.keep) * extent
        eligible = sorted([r for r in rows if not r["why"]], key=lambda r: r["score"])
        chosen, removed = set(), 0.0
        for r in eligible:
            if removed >= target:
                break
            k = r["k"]
            if any({k + d, k + d + 1, k + d + 2} - {k} <= chosen for d in (-2, -1, 0)):
                continue  # would make 3 consecutive removed rows
            chosen.add(k)
            removed += r["width"]
        log("family %.1f: %d lines, %d rows, eligible %d, chosen %d; removing %.0f of %.0f m (target %.0f)"
            % (family, len(order), len(rows), len(eligible), len(chosen), removed, extent, target))
        for r in rows:
            log("  row %2d %-24s %s %s" % (r["k"], r["gone"][:24], "CUT " if r["k"] in chosen else "    ",
                                           "; ".join(r["why"]) or "ok (score %.1f, width %.0f, strain %.3f, %d pairs, %d cut)"
                                           % (r["score"], r["width"], r["strain"], r["samples"], r["cut_buildings"])))
        results.append((removed, family, extent, rows, chosen, order, S0))
    if not results:
        sys.exit("parish_thin: no family has rows")
    removed, family, extent, rows, chosen, order, S0 = max(results, key=lambda x: x[0])
    if not chosen:
        sys.exit("parish_thin: nothing to cut")
    log("family %.1f chosen" % family)
    # Two neighbouring rows are one band from the first's near street to the
    # second's far one: two bands sharing an edge would each claim the
    # street on it, and the shift across both is measured in one go.
    by_k = {r["k"]: r for r in rows}
    specs, bands = [], []
    for k in sorted(chosen):
        if k - 1 in chosen:
            continue
        run = [k] + ([k + 1] if k + 1 in chosen else [])
        if len(run) == 2:
            spec, info = curve_row(k, order, feats, fr, C, family, cross, S0, Pin, span=2)
            why = info if spec is None else "; ".join(
                (["unpaired " + ", ".join(info["unpaired"])] if info["unpaired"] else [])
                + (["strain %.3f" % info["strain"]] if info["strain"] > STRAIN_MAX else []))
            if why:
                # The pair does not hold as one band: keep the cheaper row.
                drop = max(run, key=lambda j: by_k[j]["score"])
                log("  rows %d+%d do not join (%s): row %d stays" % (k, k + 1, why, drop))
                run.remove(drop)
            else:
                strain = info["strain"]
                log("  rows %d+%d as one band: strain %.3f, %d pairs" % (k, k + 1, strain, info["samples"]))
        if len(run) == 1:
            spec, strain = by_k[run[0]]["spec"], by_k[run[0]]["strain"]
        specs.append(spec)
        bands.append({"rows": run, "gone": [by_k[j]["gone"] for j in run], "width": sum(by_k[j]["width"] for j in run),
                      "cut_buildings": sum(by_k[j]["cut_buildings"] for j in run), "strain": strain})
    return family, extent, specs, bands, [{k: v for k, v in r.items() if k != "spec"} for r in rows]


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


def straight_main(a, fr, P, C, feats, blds, B, bidx, blocks, patch):
    """Rows as straight compress.py bands (the first phase 2 attempt)."""
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
        band["width"] = band["b"] - band["a"]
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
    return family, extent, specs, bands, [{k: v for k, v in r.items() if k != "region"} for r in rows]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("segment")
    ap.add_argument("raw")
    ap.add_argument("patch", type=int)
    ap.add_argument("out")
    ap.add_argument("--keep", type=float, default=0.6)
    ap.add_argument("--mode", choices=("curve", "straight"), default="curve")
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
    renamed = strokes(feats)
    if renamed:
        log("renamed streets joined: " + "; ".join(renamed))
    blds = []
    for path in sorted(glob.glob(os.path.join(orig, "bld_*.json"))):
        for el in json.load(open(path, encoding="utf-8"))["elements"]:
            if el["type"] == "way" and el.get("geometry"):
                _, xz = xz_of(fr, el["geometry"])
                if len(xz) >= 3:
                    blds.append(xz)

    if a.mode == "curve":
        family, extent, specs, bands, rows = curve_main(a, fr, P, C, feats, blds, B, bidx, blocks, patch)
    else:
        family, extent, specs, bands, rows = straight_main(a, fr, P, C, feats, blds, B, bidx, blocks, patch)
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

    gate = check(feats, thin, fr, cuts, P, [B[i] for i in bidx if B[i]["protected"]], orig)
    gate["removed_m"] = round(sum(b["width"] for b in bands), 1)
    gate["extent_m"] = round(extent, 1)
    gate["keep_across"] = round(1 - gate["removed_m"] / extent, 3)
    gate["buildings_cut"] = sum(b["cut_buildings"] for b in bands)
    gate["pass"] = gate["chords"] == 0 and gate["new_dead_ends"] <= 0 and gate["landmarks_bent"] == 0 and gate["decks_touched"] == 0 and gate["new_overlaps"] == 0
    log("gate " + json.dumps({k: v for k, v in gate.items() if k not in ("chord_list",)}, indent=1))
    for c in gate["chord_list"][:15]:
        log("  chord %-28s length %5.1f m, jog %5.1f m" % (c[0][:28], c[1], c[2]))
    with open(os.path.join(a.out, "thin.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"patch": a.patch, "mode": a.mode, "family": family, "keep": a.keep,
                   "rows": [{k: v for k, v in r.items() if k not in ("region", "spec")} for r in rows],
                   "bands": bands, "gate": gate}, f, indent=1)


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


def check(feats, thin_dir, fr, cuts, P, prot_blocks, orig_dir):
    # Chords: a street rejoined across a band is exact when its far part,
    # moved, still points straight at the near node it now meets. The jog
    # is how far off that line the near node is.
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
            # The far part is the one that moved more.
            mi, mj = (np.hypot(px[q] - xz[q, 0], pz[q] - xz[q, 1]) for q in (i, j))
            near, far, prev = (i, j, j - 1) if mj >= mi else (j, i, i + 1)
            v = xz[far] - xz[prev]
            L = float(np.hypot(*v))
            if L < 0.5:
                continue
            w = np.array([px[near] - px[far], pz[near] - pz[far]])
            jog = abs(w[0] * v[1] - w[1] * v[0]) / L
            if jog > JOG_MIN:
                chords.append((t.get("name") or t["highway"], round(float(np.hypot(*w)), 1), round(jog, 1)))
    # Dead ends inside the patch, before and after (the thinned patch is
    # P moved through the cuts).
    before = degree1(feats, fr, P)
    pr = np.asarray(P.exterior.coords)
    k, wx, wz, _, _, _ = cuts.line(pr[:, 0], pr[:, 1], "closed")
    Pn = Polygon(np.c_[wx[k], wz[k]]).buffer(0)
    after = degree1(json.load(open(os.path.join(thin_dir, "features.json"), encoding="utf-8"))["elements"], fr, Pn)
    # Landmarks: no protected block loses ground; how far each is stretched.
    bent, stretch = [], 0.0
    for b in prot_blocks:
        r = np.asarray(b["ring"])
        k, wx, wz, _, _, _ = cuts.line(r[:, 0], r[:, 1], "closed")
        d = np.c_[wx - r[:, 0], wz - r[:, 1]]
        if not k.all():
            bent.append([n for n, _ in b["landmarks"]][:2])
        stretch = max(stretch, float(np.hypot(np.ptp(d[:, 0]), np.ptp(d[:, 1]))))
    # Buildings that overlap after and did not before.
    def polys(d):
        out = {}
        for path in sorted(glob.glob(os.path.join(d, "bld_*.json"))):
            for el in json.load(open(path, encoding="utf-8"))["elements"]:
                if el["type"] == "way" and el.get("geometry"):
                    _, xz = xz_of(fr, el["geometry"])
                    if len(xz) >= 4:
                        out[el["id"]] = Polygon(xz).buffer(0)
        return out
    pa, pb = polys(thin_dir), polys(orig_dir)
    ids = list(pa)
    geo = np.array([pa[i] for i in ids], dtype=object)
    tree = shapely.STRtree(geo)
    overlaps = 0
    for x, y in zip(*tree.query(geo, predicate="intersects")):
        if x >= y:
            continue
        if shapely.intersection(geo[x], geo[y]).area <= 1.0:
            continue
        o0, o1 = pb.get(ids[x]), pb.get(ids[y])
        if o0 is not None and o1 is not None and shapely.intersection(o0, o1).area > 1.0:
            continue
        overlaps += 1
    chords.sort(key=lambda c: -c[2])
    return {"chords": len(chords), "max_jog_m": chords[0][2] if chords else 0.0, "chord_list": chords,
            "dead_ends_before": len(before), "dead_ends_after": len(after), "new_dead_ends": len(after) - len(before),
            "landmarks": len(prot_blocks), "landmarks_bent": len(bent), "bent": bent[:10],
            "landmark_stretch_m": round(stretch, 2), "new_overlaps": overlaps, "decks_touched": decks}

if __name__ == "__main__":
    main()

"""The elevated-road deck set and its fallback heights, for decks_seed.py.

    import bridges
    ways, others, rails = bridges.read(raw, meta)
    pos, height, fall, couple_nodes, coupled = bridges.solve(ways, others, rails)

read() takes the roads from <raw dir>/features.json in city.json's frame;
solve() gives every road a height. decks_seed.py keeps the ways solve()
raises as the deck set, and uses solve()'s height wherever LiDAR has too
few returns to measure a deck; decks_mesh.py draws the decks from the
seeded decks.json. Nothing here draws.

OSM has no heights for bridges, only a layer, so the solve makes them up:
  - a bridge over a road or railway of a lower layer, and every motorway
    or trunk bridge, stands LAYER_HEIGHT per layer; a bridge over only
    water or ground stands LOW_HEIGHT; a few named bridges stand taller;
  - ways meet where their nodes have the same coordinates, and an
    intersection with a surface street is pinned to the ground;
  - nothing climbs steeper than GRADE: a bridge too close to a pinned
    intersection is lowered, and the roads leading off a bridge ramp down
    to the ground at GRADE;
  - where a road joins a bridge or expressway it stays level until it has
    left the other road's footprint;
  - a bridge clears every road and railway it crosses by CLEAR, not just
    where the centre lines cross but all the way across its footprint.
    heights.py solves every road's height at once against all of these
    rules; where they contradict each other it steepens the roads that
    cause it up to GRADE_MAX and only then gives up clearance, and says
    where;
  - roads side by side, the same kind of structure, are tied to one height
    where they overlap, so a ramp leaving a motorway peels away from it
    at its own level instead of crossing through it.
Heights here are real metres.

Map data (c) OpenStreetMap contributors, ODbL.
"""

import heapq
import json
import math
import os
import sys

import numpy as np
import shapely
import shapely.ops
from shapely.geometry import LineString, Polygon

sys.path.insert(0, os.path.dirname(__file__))
import heights  # noqa: E402
from osm_city import road_class, ROAD_WIDTHS, RAIL_WIDTH, MEDIAN  # noqa: E402

LAYER_HEIGHT = 10.0
LOW_HEIGHT = 6.0
## A few ways are tagged layer 4 or 5 to sort them against rail yards and
## tunnels; no interchange here stacks more than three decks.
MAX_LAYER = 3
## Named bridges much taller than an overpass: the river and ship-canal
## crossings. Matched against name and bridge:name.
NAMED_HEIGHTS = {"Crescent City Connection": 45.0, "High Rise Bridge": 38.0}
## How far a deck stands over a road it crosses: a lorry's height under a
## deck THICK deep, and a margin.
CLEAR = 7.0
## A bridge clears a road this far past where its footprint ends along the
## road: about a lane's width.
CLEAR_PAD = 2.0
## A junction's level zone ends here at the longest, however shallow the
## angle two roads merge at.
FLAT_MAX = 80.0
## The one step: two decks this far apart in height or more are divided,
## less are one surface (decks_seed.py's joins and twins, decks_mesh.py's
## rails and welds).
STEP_MAX = 0.4
## They are side by side, not crossing, when their directions are within
## this cosine of each other (about 30 degrees).
SPLIT_COS = 0.87
## Rise over run, real metres: an 8% grade, an expressway ramp's.
GRADE = 0.08
## Where the rules above contradict each other (OSM maps some ramps shorter
## than they are), the roads that cause it may climb this steeply, and only
## then does a crossing give up clearance.
GRADE_MAX = 0.12
## Ways are cut into pieces no longer than this many metres, so a ramp's
## profile can curve.
STEP = 5.0
## A ramp comes down this far short of a street intersection it lands on,
## so its foot can round off onto the level before the intersection.
FOOT = 20.0
## Rounds of smoothing on the solved heights: each rounds a ramp's top and
## foot by about STEP * sqrt(rounds) metres.
SMOOTH = 80
## Parts of a way lower than this are left to the flat street on the
## ground, except on a bridge.
MIN_HEIGHT = 0.25
## Decks run on this far past the map's boundary, into the fog.
RUNOUT = 60.0
## Classes that never meet a street at grade, so their junctions are not
## pinned to the ground and their bridges stand a full layer.
EXPRESS = ("motorway", "motorway_link", "trunk", "trunk_link")


def read(raw, meta):
    """The roads of <raw>/features.json in meta's frame: the ways that can
    be decks (each with its OSM way id, "osm", and its OSM node ids,
    "nodes", one per point), every road and railway for crossings, and the
    railways on the ground."""
    lat0, lon0 = meta["origin"]
    m_lat = 111_320.0
    m_lon = 111_320.0 * math.cos(math.radians(lat0))
    feats = json.load(open(os.path.join(raw, "features.json"), encoding="utf-8"))["elements"]

    ways, others = [], []  # roads that can be decks; every road and rail, for crossings
    rails = []  # railways on the ground, which bridges clear
    for el in feats:
        tags = el.get("tags", {})
        nodes = [n for n, g in zip(el.get("nodes") or [], el.get("geometry") or []) if g]
        geom = [g for g in el.get("geometry") or [] if g]
        if el["type"] != "way" or len(geom) < 2:
            continue
        hw, rail = tags.get("highway"), tags.get("railway") == "rail"
        if not (hw or rail):
            continue
        if hw and (tags.get("building", "no") != "no" or tags.get("area") == "yes"):
            # An enclosed skywalk is a building, drawn with the others; a
            # plaza's outline is not a road down its middle.
            continue
        keys = [(round(g["lat"], 7), round(g["lon"], 7)) for g in geom]
        pts = np.array([((g["lon"] - lon0) * m_lon, -(g["lat"] - lat0) * m_lat) for g in geom])
        bridge = tags.get("bridge", "no") != "no"
        try:
            layer = int(tags.get("layer", "1" if bridge else "0"))
        except ValueError:
            layer = 1 if bridge else 0
        others.append((LineString(pts), set(keys), layer, ROAD_WIDTHS.get(hw, RAIL_WIDTH if rail else 0.0), bridge))
        if rail and not hw and not bridge:
            rails.append(pts)
        if ROAD_WIDTHS.get(hw, 0.0) <= 0:
            continue
        named = 0.0
        for name, h in NAMED_HEIGHTS.items():
            if name in tags.get("name", "") or name in tags.get("bridge:name", ""):
                named = h
        ways.append({"keys": keys, "pts": pts, "cls": hw, "width": ROAD_WIDTHS[road_class(tags)],
                     "bridge": bridge, "layer": max(1, layer), "named": named, "osm": el.get("id"), "raw_layer": layer,
                     "name": tags.get("name", ""), "ref": tags.get("ref", ""),
                     "nodes": nodes if len(nodes) == len(geom) else [None] * len(geom),
                     "oneway": tags.get("oneway") in ("yes", "1", "true", "-1") or hw == "motorway"})
    print("bridges: %d roads, %d bridges" % (len(ways), sum(w["bridge"] for w in ways)), flush=True)
    return ways, others, rails


def solve(ways, others, rails):
    """Every road's height, solved at once (see the module's docstring). The
    ways gain "ids" (indices into pos, nodes added along them included) and
    "level". Returns pos, the height of each, how steeply each node's roads
    fall away from it, the nodes ways tied side by side share, and the
    pairs of ways tied side by side (indices into ways)."""
    node_id, pos, uses = {}, [], {}
    for w in ways:
        ids = []
        for k, p in zip(w["keys"], w["pts"]):
            if k not in node_id:
                node_id[k] = len(pos)
                pos.append(p)
            ids.append(node_id[k])
        w["ids"] = ids
        for i in set(ids):
            uses.setdefault(i, []).append(w)
    _level_junctions(ways, uses, pos)
    _densify(ways, uses, pos)
    rungs, coupled, couple_nodes = _couple(ways, pos)
    pos = np.array(pos)
    n = len(pos)
    adj = [[] for _ in range(n)]
    street_ways = [0] * n
    for w in ways:
        street = not w["bridge"] and w["cls"] not in EXPRESS
        for a, b, level in zip(w["ids"], w["ids"][1:], w["level"]):
            d = 0.0 if level else float(np.hypot(*(pos[a] - pos[b])))
            adj[a].append((b, d))
            adj[b].append((a, d))
        if street:
            for i in set(w["ids"]):
                street_ways[i] += 1
    # An intersection a surface street runs through is on the ground.
    pinned = [i for i in range(n) if street_ways[i] and len({b for b, _ in adj[i]}) >= 3]
    ea, eb, ew = [], [], []
    for i in range(n):
        for j, d in adj[i]:
            if i < j:
                ea.append(i); eb.append(j); ew.append(1.0 / max(d, 1.0))
    ea, eb, ew = np.array(ea, int), np.array(eb, int), np.array(ew)
    den = np.bincount(ea, ew, n) + np.bincount(eb, ew, n)
    free = (den > 0)
    free[pinned] = False
    # How high each node could stand on its own roads alone, before any
    # rung ties it to a road beside it.
    adj0 = [list(a) for a in adj]
    foot0 = np.maximum(0.0, _dijkstra(adj0, {i: 0.0 for i in pinned}, n) - FOOT) * GRADE
    # Rungs only now: counted as arms above, they would pin the end of
    # every bridge running beside another to the ground.
    for a, b in rungs:
        adj[a].append((b, 0.0))
        adj[b].append((a, 0.0))

    foot = np.maximum(0.0, _dijkstra(adj, {i: 0.0 for i in pinned}, n) - FOOT) * GRADE

    others_tree = shapely.STRtree([o[0] for o in others])
    wanted = {}
    for w in ways:
        if not w["bridge"]:
            continue
        line, keys = LineString(w["pts"]), set(w["keys"])
        over = any(others[j][2] < w["layer"] and not (others[j][1] & keys)
                   for j in others_tree.query(line, predicate="intersects"))
        if w["named"]:
            t = w["named"]
        elif over or w["cls"] in EXPRESS or w["layer"] > 1:
            t = min(w["layer"], MAX_LAYER) * LAYER_HEIGHT
        else:
            t = LOW_HEIGHT
        for i in w["ids"]:
            wanted[i] = max(wanted.get(i, 0.0), t)

    crossings = _crossings(ways, rails, pos)
    both = sum(1 for up, lo, _, _ in crossings if lo[3] >= 0 and _key(up[3], lo[3]) in coupled)
    print("bridges: %d rungs over %d pairs of roads side by side; %d of them also cross" % (len(rungs), len(coupled), both), flush=True)
    cum = [np.concatenate([[0.0], np.cumsum(np.hypot(*(pos[w["ids"]][1:] - pos[w["ids"]][:-1]).T))]) for w in ways]
    # Two bridges of one layer crossing: the one that would stand higher
    # with no crossing at all goes over.
    order = np.maximum(0.0, -_dijkstra(adj, {i: -min(t, foot[i]) / GRADE for i, t in wanted.items()}, n) * GRADE)
    pairs = heights.pairs_for(crossings, lambda side, xy, reach: _stretch(side, xy, reach, ways, cum, pos)[0], pos, order, CLEAR_PAD,
                              lambda up, lo: (ways[up[3]]["osm"], ways[lo[3]]["osm"] if lo[3] >= 0 else "rail"))
    # A street under a bridge's edge is cleared too, where the bridge alone
    # would clear it, so a ramp tied beside it cannot pull it down onto
    # the street: the tie gives way first.
    own = np.maximum(0.0, -_dijkstra(adj0, {i: -min(t, foot0[i]) / GRADE for i, t in wanted.items()}, n) * GRADE)
    under = _under(ways, pos, own)
    print("bridges: %d streets under a bridge's edge, %d node pairs" % (len(under), sum(len(pp) for _, pp in under)), flush=True)
    pairs += under
    height, clear, cap = heights.solve(adj, pinned, wanted, pairs, n, GRADE, GRADE_MAX, CLEAR, FOOT, SMOOTH,
                                       log=lambda m: print("bridges: " + m, flush=True), ties=rungs)
    height[height < 0.05] = 0.0
    bad = 0
    for up, lo, xy, sin in crossings:
        hu, hl = _at(up, xy, height, pos), _at(lo, xy, height, pos)
        if abs(hu - hl) < CLEAR - 0.5:
            bad += 1
    steep = max((abs(height[a] - height[b]) / max(float(np.hypot(*(pos[a] - pos[b]))), 1e-9)
                 for a, b in zip(ea, eb) if float(np.hypot(*(pos[a] - pos[b]))) > 1.0), default=0.0)
    print("bridges: %d of %d crossings short of clearance at the crossing point; steepest grade %.3f"
          % (bad, len(crossings), steep), flush=True)
    print("bridges: %d pinned, %d raised nodes, highest %.0f m" % (len(pinned), int((height > MIN_HEIGHT).sum()), height.max()), flush=True)
    # How steeply each node's roads fall away from it, for its discs.
    fall = np.zeros(n)
    for i in range(n):
        for j, d in adj[i]:
            if d > 0:
                fall[i] = max(fall[i], (height[i] - height[j]) / d)
    return pos, height, fall, couple_nodes, coupled


def _dijkstra(adj, sources, n):
    """Shortest distance from the nearest source, each starting at its own
    value; inf where none reaches."""
    dist = np.full(n, np.inf)
    heap = [(d, i) for i, d in sources.items()]
    for d, i in heap:
        dist[i] = min(dist[i], d)
    heapq.heapify(heap)
    while heap:
        d, i = heapq.heappop(heap)
        if d > dist[i]:
            continue
        for j, step in adj[i]:
            if d + step < dist[j]:
                dist[j] = d + step
                heapq.heappush(heap, (d + step, j))
    return dist


def _level_junctions(ways, uses, pos):
    """Splits each way where it leaves the footprint of a bridge or
    expressway it joins, and marks the edges inside as level (w["level"]):
    the solve gives them no length, so the two decks are flush there. New
    nodes are appended to pos."""
    for w in ways:
        line = LineString(w["pts"])
        cum = np.concatenate([[0.0], np.cumsum(np.hypot(*(w["pts"][1:] - w["pts"][:-1]).T))])
        zones = []
        for k, i in enumerate(w["ids"]):
            meet = [o for o in uses.get(i, ()) if o is not w
                    and (o["bridge"] or o["cls"] in EXPRESS or w["bridge"] or w["cls"] in EXPRESS)]
            if not meet:
                continue
            near = shapely.buffer(shapely.points(pos[i]), FLAT_MAX + max(o["width"] for o in meet))
            foot = shapely.union_all([shapely.buffer(shapely.intersection(LineString(o["pts"]), near), (o["width"] + w["width"]) / 2)
                                      for o in meet])
            lo = hi = cum[k]
            # Forward and back from the node, to where the centre line first
            # leaves the footprint.
            if cum[k] < cum[-1]:
                part = shapely.ops.substring(line, cum[k], min(cum[-1], cum[k] + FLAT_MAX))
                out = part.difference(foot)
                hi = cum[k] + (part.length if out.is_empty else
                               min(part.project(shapely.points(g.coords[0])) for g in getattr(out, "geoms", [out])))
            if cum[k] > 0:
                part = shapely.ops.substring(line, max(0.0, cum[k] - FLAT_MAX), cum[k])
                out = part.difference(foot)
                lo = cum[k] - (part.length if out.is_empty else
                               part.length - max(part.project(shapely.points(g.coords[-1])) for g in getattr(out, "geoms", [out])))
            if hi - lo > 1e-6:
                zones.append((lo, hi))
        if not zones:
            w["level"] = [False] * (len(w["ids"]) - 1)
            continue
        known = {round(c, 3) for c in cum}
        cuts = sorted({round(c, 3) for z in zones for c in z if 0 < c < cum[-1]} - known)
        pts, ids, at = [], [], []
        for k in range(len(w["pts"])):
            if k:
                for c in cuts:
                    if cum[k - 1] < c < cum[k]:
                        f = (c - cum[k - 1]) / (cum[k] - cum[k - 1])
                        pts.append(w["pts"][k - 1] + (w["pts"][k] - w["pts"][k - 1]) * f)
                        ids.append(len(pos))
                        pos.append(pts[-1])
                        at.append(c)
            pts.append(w["pts"][k])
            ids.append(w["ids"][k])
            at.append(cum[k])
        mids = [(a + b) / 2 for a, b in zip(at, at[1:])]
        w["pts"], w["ids"] = np.array(pts), ids
        w["level"] = [any(lo - 1e-3 <= m <= hi + 1e-3 for lo, hi in zones) for m in mids]


def _key(a, b):
    return (a, b) if a < b else (b, a)


def _couple(ways, pos):
    """Ties decks that run side by side over the same ground to one height:
    each node of one, within the two half widths of the other's centre line
    and heading its way, gets a node right beside it on the other, and a
    rung of no length between the two. Two bridges on one OSM layer, or two
    roads on the ground, or the two carriageways of a divided road (see
    _twins), are tied wherever they run so; others only along the run from
    a node they share, where one leaves the other. Roads that cross, and
    roads heading opposite ways other than twins, are not tied. New nodes are
    appended to pos. Returns the rungs, the pairs of ways tied, and the
    nodes they share."""
    cand = [wi for wi, w in enumerate(ways) if w["bridge"] or w["cls"] in EXPRESS]
    lines = [LineString(ways[wi]["pts"]) for wi in cand]
    tree = shapely.STRtree(lines)
    cums = {wi: np.concatenate([[0.0], np.cumsum(np.hypot(*(ways[wi]["pts"][1:] - ways[wi]["pts"][:-1]).T))]) for wi in cand}
    inserts = {}  # id(way) -> (way, [(metres along it, node beside)])
    pairs, shared_nodes = set(), set()
    for x, wi in enumerate(cand):
        w = ways[wi]
        for y in tree.query(lines[x], predicate="dwithin", distance=w["width"] + 20.0):
            oi = cand[y]
            if oi <= wi:
                continue
            o = ways[oi]
            shared = set(w["ids"]) & set(o["ids"])
            twin = _twins(w, o)
            same = (w["bridge"] and o["bridge"] and w["raw_layer"] == o["raw_layer"]) or not (w["bridge"] or o["bridge"]) or twin
            if not (same or shared):
                continue
            meet = [np.asarray(pos[i]) for i in shared]
            hit = shapely.intersection(lines[x], lines[y])
            if any(min((float(np.hypot(*(np.array(q.coords[0]) - m))) for m in meet), default=1e9) > 1.0
                   for q in shapely.get_parts(hit) if q.geom_type == "Point"):
                continue  # they cross, which the heights clear instead
            found = []
            for A, B, lb, cb in ((w, o, lines[y], cums[oi]), (o, w, lines[x], cums[wi])):
                ids, pts = A["ids"], A["pts"]
                near = {}
                for k, i in enumerate(ids):
                    if i in shared:
                        continue
                    q = shapely.points(pts[k])
                    # Twins read as one road across a median as wide as
                    # osm_city.py closes up on the ground.
                    if shapely.distance(lb, q) >= (A["width"] + B["width"]) / 2 + (2 * MEDIAN if twin else 0.5):
                        continue
                    da = pts[min(k + 1, len(pts) - 1)] - pts[max(k - 1, 0)]
                    t = float(shapely.line_locate_point(lb, q))
                    m = int(np.clip(np.searchsorted(cb, t), 1, len(cb) - 1))
                    db = B["pts"][m] - B["pts"][m - 1]
                    along = float(da @ db)
                    if (abs(along) if twin else along) < SPLIT_COS * float(np.hypot(*da) * np.hypot(*db)):
                        continue  # heading another way, or the opposite one
                    near[k] = t
                if not same:
                    # Only the run beside the node they share.
                    keep = set()
                    for k0 in [k for k, i in enumerate(ids) if i in shared]:
                        for step in (-1, 1):
                            k = k0 + step
                            while k in near:
                                keep.add(k)
                                k += step
                    near = {k: t for k, t in near.items() if k in keep}
                found.append((B, [(t, ids[k]) for k, t in near.items()]))
            if any(f for _, f in found):
                pairs.add(_key(wi, oi))
                shared_nodes |= shared
                for B, f in found:
                    inserts.setdefault(id(B), (B, []))[1].extend(f)
    rungs = set()
    for B, f in inserts.values():
        cum = np.concatenate([[0.0], np.cumsum(np.hypot(*(B["pts"][1:] - B["pts"][:-1]).T))])
        f.sort()
        made, add = [], []  # nodes added to B: (metres along, node), and where they go
        for t, other in f:
            k = int(np.argmin(np.abs(cum - t)))
            if abs(cum[k] - t) < 0.3:
                j = B["ids"][k]
            elif made and abs(made[-1][0] - t) < 0.3:
                j = made[-1][1]
            else:
                j = len(pos)
                m = int(np.clip(np.searchsorted(cum, t), 1, len(cum) - 1))
                u = (t - cum[m - 1]) / max(cum[m] - cum[m - 1], 1e-9)
                pos.append(B["pts"][m - 1] + (B["pts"][m] - B["pts"][m - 1]) * u)
                made.append((t, j))
                add.append((j, m))
            if j != other:
                rungs.add(_key(j, other))
        if not add:
            continue
        add_at = {}
        for j, m in add:
            add_at.setdefault(m, []).append(j)
        pts, ids, level = [B["pts"][0]], [B["ids"][0]], []
        for m in range(1, len(B["ids"])):
            for j in add_at.get(m, ()):
                pts.append(np.asarray(pos[j]))
                ids.append(j)
                level.append(B["level"][m - 1])
            pts.append(B["pts"][m])
            ids.append(B["ids"][m])
            level.append(B["level"][m - 1])
        B["pts"], B["ids"], B["level"] = np.array(pts), ids, level
    return sorted(rungs), pairs, shared_nodes


def _twins(w, o):
    """Whether two ways are the two carriageways of one divided road: one
    class of main road, each one way, sharing a name or a route number.
    They run opposite ways and OSM may give them different layers, but
    they are one road and are tied wherever they run side by side. Ramps
    and links are never twins."""
    if w["cls"] != o["cls"] or w["cls"].endswith("_link") or not (w["oneway"] and o["oneway"]):
        return False
    return bool(w["name"] and w["name"] == o["name"]) or bool(w["ref"] and set(w["ref"].split(";")) & set(o["ref"].split(";")))


def _densify(ways, uses, pos):
    """Cuts every edge longer than STEP on the elevated ways and the roads
    meeting them into equal pieces, so their heights can curve, and every
    edge of another road under an elevated one's footprint, so a deck over
    it has nodes below to clear. New nodes are appended to pos."""
    near, high = set(), []
    for w in ways:
        if w["bridge"] or w["cls"] in EXPRESS:
            high.append(shapely.buffer(LineString(w["pts"]), w["width"] / 2))
            for i in w["ids"]:
                for o in uses.get(i, ()):
                    near.add(id(o))
    tree = shapely.STRtree(high)
    for w in ways:
        whole = id(w) in near
        if not whole and not len(tree.query(shapely.buffer(LineString(w["pts"]), w["width"] / 2), predicate="intersects")):
            continue
        pts, ids, level = [w["pts"][0]], [w["ids"][0]], []
        for k in range(1, len(w["ids"])):
            a, b = w["pts"][k - 1], w["pts"][k]
            parts = 1
            if whole or len(tree.query(shapely.buffer(LineString([a, b]), w["width"] / 2), predicate="intersects")):
                parts = max(1, int(math.ceil(float(np.hypot(*(b - a))) / STEP)))
            for m in range(1, parts):
                pts.append(a + (b - a) * (m / parts))
                ids.append(len(pos))
                pos.append(pts[-1])
                level.append(w["level"][k - 1])
            pts.append(b)
            ids.append(w["ids"][k])
            level.append(w["level"][k - 1])
        w["pts"], w["ids"], w["level"] = np.array(pts), ids, level


def _crossings(ways, rails, pos):
    """Every point where a bridge's centre line crosses another road or a
    railway sharing no node with it, as (upper, lower, point, sine of the
    angle between them). Each side is (node a, node b, layer, way, segment,
    width); a railway's nodes and way are -1, for the ground. The upper is
    the bridge of the higher layer, or of a road not a bridge; two bridges
    of one layer are sorted by height as the solve goes."""
    segs, info = [], []
    for wi, w in enumerate(ways):
        for k, (a, b) in enumerate(zip(w["ids"], w["ids"][1:])):
            segs.append(LineString([pos[a], pos[b]]))
            info.append((a, b, w["layer"] if w["bridge"] else -99, wi, k, w["width"]))
    for p in rails:
        for a, b in zip(p, p[1:]):
            segs.append(LineString([a, b]))
            info.append((-1, -1, -99, -1, -1, RAIL_WIDTH))
    tree = shapely.STRtree(segs)
    mine = [i for i, f in enumerate(info) if f[2] != -99]
    left, right = tree.query([segs[i] for i in mine], predicate="intersects")
    out = []
    for li, j in zip(left, right):
        i = mine[li]
        a, b = info[i], info[j]
        if i == j or (b[2] != -99 and j < i) or ({a[0], a[1]} & {b[0], b[1]} - {-1}):
            continue
        x = shapely.intersection(segs[i], segs[j])
        if x.geom_type != "Point":
            continue
        da, db = (np.asarray(segs[k].coords[1]) - np.asarray(segs[k].coords[0]) for k in (i, j))
        sin = abs(float(da[0] * db[1] - da[1] * db[0])) / max(float(np.hypot(*da) * np.hypot(*db)), 1e-9)
        if b[2] > a[2]:
            a, b = b, a
        out.append((a, b, (x.x, x.y), sin))
    print("bridges: %d crossings under bridges" % len(out), flush=True)
    return out


def _under(ways, pos, own):
    """Clearance pairs, as heights.pairs_for gives them, for the streets
    under a bridge's footprint, which _crossings misses where they pass
    under its edge without crossing its centre line: each node of the
    bridge whose deck reaches over the street with each node of the street
    near it, wherever the bridge on its own (own: heights with no ties and
    no crossings) stands CLEAR over the street. A street sharing a node
    with the bridge meets it rather than passing under."""
    streets = [w for w in ways if not w["bridge"] and w["cls"] not in EXPRESS]
    feet = [shapely.buffer(LineString(w["pts"]), w["width"] / 2) for w in streets]
    tree = shapely.STRtree(feet)
    out = []
    for b in ways:
        if not b["bridge"]:
            continue
        deck = shapely.buffer(LineString(b["pts"]), b["width"] / 2)
        bi = np.asarray(b["ids"])
        for si in tree.query(deck, predicate="intersects"):
            s = streets[si]
            if set(b["ids"]) & set(s["ids"]):
                continue
            over = shapely.intersection(deck, feet[si])
            if over.area < 1.0:
                continue
            sj = np.asarray(s["ids"])
            ui = bi[shapely.distance(over, shapely.points(pos[bi])) <= b["width"] / 2 + CLEAR_PAD]
            li = sj[shapely.distance(over, shapely.points(pos[sj])) <= s["width"] / 2 + CLEAR_PAD]
            r = (b["width"] + s["width"]) / 2 + CLEAR_PAD + STEP / 2
            pp = [(int(j), int(i)) for i in ui for j in li
                  if own[i] - own[j] >= CLEAR - 1e-6 and float(np.hypot(*(pos[i] - pos[j]))) <= r]
            if pp:
                out.append(((b["osm"], s["osm"]), pp))
    return out


def _stretch(side, xy, reach, ways, cum, pos):
    """The part of a crossing's way within reach of the crossing point,
    along the way: its nodes, from the last before it to the first after,
    and the distances along the way of its two ends and the nodes between."""
    a, _, _, wi, k, _ = side
    c = cum[wi]
    s = c[k] + float(np.hypot(xy[0] - pos[a][0], xy[1] - pos[a][1]))
    lo, hi = max(0.0, s - reach), min(float(c[-1]), s + reach)
    first = max(0, int(np.searchsorted(c, lo, side="right")) - 1)
    last = min(len(c) - 1, int(np.searchsorted(c, hi, side="left")))
    return ways[wi]["ids"][first:last + 1], np.concatenate([[lo, hi], c[(c > lo) & (c < hi)]])


def _at(seg, xy, height, pos):
    """A segment's solved height at a point on it; a railway's is 0."""
    a, b = seg[0], seg[1]
    if a < 0:
        return 0.0
    d = float(np.hypot(*(pos[b] - pos[a])))
    f = 0.0 if d < 1e-9 else float(np.hypot(xy[0] - pos[a][0], xy[1] - pos[a][1])) / d
    return float(height[a] * (1 - f) + height[b] * f)


def _region(rings):
    """The boundary rings back as one area: a point is inside when it is
    inside an odd number of them."""
    region = Polygon()
    for r in rings:
        region = shapely.symmetric_difference(region, shapely.make_valid(Polygon(r)))
    return region



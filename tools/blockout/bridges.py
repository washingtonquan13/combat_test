"""Walkable elevated roads for a city made by osm_city.py: bridge decks,
the ramps that lead up to them, their rails and their piers.

    python -I tools/blockout/bridges.py <raw dir> <out dir>

osm_city.py runs this after writing city.json; run it alone to rebuild only
the decks. It reads the roads from <raw dir>/features.json and the tile
grid and boundary from <out dir>/city.json, writes tiles/d_X_Z.bin in the
same format as the other tile files, and adds "decks" to city.json's tiles.

OSM has no heights for bridges, only a layer, so heights are made up:
  - a bridge over a road or railway of a lower layer, and every motorway
    or trunk bridge, stands LAYER_HEIGHT per layer; a bridge over only
    water or ground stands LOW_HEIGHT; a few named bridges stand taller;
  - ways meet where their nodes have the same coordinates, and an
    intersection with a surface street is pinned to the ground;
  - nothing climbs steeper than GRADE: a bridge too close to a pinned
    intersection is lowered, and the roads leading off a bridge ramp down
    to the ground at GRADE, which is what makes it walkable;
  - where a road joins a bridge or expressway it stays level until it has
    left the other road's footprint, so a ramp meets a wide deck flush
    instead of climbing into its edge;
  - a bridge clears every road and railway it crosses by CLEAR, not just
    where the centre lines cross but all the way across its footprint.
    heights.py solves every road's height at once against all of these
    rules; where they contradict each other it steepens the roads that
    cause it up to GRADE_MAX and only then gives up clearance, and says
    where;
  - roads side by side, the same kind of structure, are tied to one height
    where they overlap, so a ramp leaving a motorway peels away from it
    at its own level instead of crossing through it;
  - roads are drawn wider than they are, so a ramp running beside a
    motorway overlaps it; where two roads overlap side by side, less than
    CLEAR apart in height, each deck stops at the line midway between
    their centre lines, so neither's edge stands in the other's lane.
    Where they are STEP_MAX apart that line is walled, like two
    carriageways with a barrier between; nearer, it is open, a lip the
    avatar rides over. A gap narrower than GAP_FILL between two decks
    less than STEP_MAX apart is filled; wider or further apart, the decks
    keep their rails. A road passing CLEAR over one beside it is on a
    structure there, so it gets piers and a deep side, not an embankment;
  - each segment of a deck slopes evenly from the line across its start
    to the line across its end, mitred at bends, so the segments either
    side of a bend meet at one height all the way across;
  - where a way ends a disc fills the gap to the ways meeting it, sloping
    down from the node as steeply as the steepest of them, so it never
    stands above the road it fills in for.
Heights here are real metres; build_osm_city.gd scales them by --vscale
like everything else.

Kinds: deck 0, deck side 1, pier 2, rail 3.

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
from osm_city import road_class, ROAD_WIDTHS, RAIL_WIDTH, _bytes, _empty, _facing, _walls, _write  # noqa: E402

## Overlays beside a deck snap to this many metres, since GEOS's floating
## overlay cannot always place thin wedges cut against a far-off plane.
GRID = 0.001
## A split deck drops what is narrower than this many metres.
SLIVER = 0.5
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
## less are one surface. It decides all of it: the line between two roads
## side by side is walled from here, a rail stands at a deck's edge where
## the deck past it is this far below or more, and the median between two
## roads tied flush is filled where they are nearer than this.
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
## A junction's level stretch eases back into a way's grade over this many
## times its own length.
LEVEL_SPAN = 3.0
## Decks sit this far above the height solved for them, so a ramp's foot
## does not z-fight the street it leaves.
LIFT = 0.15
## A deck's depth, under its road surface; below this it is a pier or air.
THICK = 1.5
## Parts of a way lower than this are left to the flat street on the
## ground, except on a bridge.
MIN_HEIGHT = 0.25
RAIL_HEIGHT = 2.0
RAIL_THICK = 0.4
## Rails only where the deck is this high, and not where another deck
## carries on past the edge: one less than STEP_MAX below, or up to
## RAIL_JOIN above, a wall faced, not a fall.
RAIL_MIN = 1.0
RAIL_JOIN = 2.0
## Rails are tested this often along a deck edge, so one starts and stops
## within this of where the deck beside it does.
RAIL_STEP = 0.5
## Where two edges of decks meet within this, a rail runs on round the
## corner as one piece.
RAIL_WELD = 0.05
## and where they miss each other by less than this, still.
RAIL_GAP = 1.0
PIER_MIN = 5.0
## Gaps between decks narrower than this, the avatar's width, are filled
## where the decks either side of them stand less than STEP_MAX apart.
GAP_FILL = 1.0
PIER_STEP = 40.0
PIER_DEPTH = 2.5
## Piers stay this far clear of the roads and railways under a deck.
PIER_CLEAR = 2.0
## Classes that never meet a street at grade, so their junctions are not
## pinned to the ground and their bridges stand a full layer.
EXPRESS = ("motorway", "motorway_link", "trunk", "trunk_link")
DECK, SIDE, PIER, RAIL = range(4)


def main():
    raw, out = sys.argv[1], sys.argv[2]
    meta_path = os.path.join(out, "city.json")
    meta = json.load(open(meta_path, encoding="utf-8"))
    lat0, lon0 = meta["origin"]
    m_lat = 111_320.0
    m_lon = 111_320.0 * math.cos(math.radians(lat0))
    feats = json.load(open(os.path.join(raw, "features.json"), encoding="utf-8"))["elements"]

    ways, others = [], []  # roads that can be decks; every road and rail, for crossings
    rails = []  # railways on the ground, which bridges clear
    for el in feats:
        tags = el.get("tags", {})
        geom = [g for g in el.get("geometry") or [] if g]
        if el["type"] != "way" or len(geom) < 2:
            continue
        hw, rail = tags.get("highway"), tags.get("railway") == "rail"
        if not (hw or rail):
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
                     "bridge": bridge, "layer": max(1, layer), "named": named, "osm": el.get("id"), "raw_layer": layer})
    print("bridges: %d roads, %d bridges" % (len(ways), sum(w["bridge"] for w in ways)), flush=True)

    # --- Heights -----------------------------------------------------------
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

    # --- Geometry ----------------------------------------------------------
    region = _region(meta["boundary"])
    shapely.prepare(region)
    segs = []  # (x0, z0, x1, z1, y0, y1) of every deck segment's centre line
    quads = []  # its footprint, for finding where decks meet
    ribbons = []
    reach = _junctions(ways)
    for wi, w in enumerate(ways):
        h = height[w["ids"]] + LIFT
        p = w["pts"]
        keep = np.hypot(*(p[1:] - p[:-1]).T) > 0.05
        keep = np.concatenate([[True], keep])
        p, h, ids = _level(p[keep], h[keep], np.asarray(w["ids"])[keep], wi, reach, couple_nodes)
        keep = np.concatenate([[True], np.hypot(*(p[1:] - p[:-1]).T) > 0.05])
        p, h, ids = p[keep], h[keep], ids[keep]
        if len(p) < 2:
            continue
        # A bridge is always a deck: osm_city.py leaves it off the ground,
        # so one held down by the streets beside it would be a gap.
        high = (np.maximum(h[:-1], h[1:]) > MIN_HEIGHT + LIFT) | w["bridge"]
        mid = (p[:-1] + p[1:]) / 2
        high &= shapely.contains_xy(region, mid[:, 0], mid[:, 1])
        if not high.any():
            continue
        off = _offsets(p, w["width"] / 2)
        ribbons.append((wi, w, p, h, ids, off, high))
        for i in np.flatnonzero(high):
            segs.append((p[i][0], p[i][1], p[i + 1][0], p[i + 1][1], h[i], h[i + 1]))
            quads.append(shapely.convex_hull(shapely.multipoints([p[i] + off[i], p[i + 1] + off[i + 1], p[i + 1] - off[i + 1], p[i] - off[i]])))
    segs = np.array(segs)
    tree = shapely.STRtree(quads)

    # Every road's segments, on the ground or not, for the decks beside them.
    lane_info, ends, widths = [], [], []
    for wi, w in enumerate(ways):
        keep = np.concatenate([[True], np.hypot(*(w["pts"][1:] - w["pts"][:-1]).T) > 0.05])
        p, h, _ = _level(w["pts"][keep], height[w["ids"]][keep] + LIFT, np.asarray(w["ids"])[keep], wi, reach)
        for i in range(len(p) - 1):
            lane_info.append((wi, p[i], p[i + 1], h[i], h[i + 1], w["bridge"]))
            ends.append((p[i], p[i + 1]))
            widths.append(w["width"] / 2)
    lanes = shapely.buffer(shapely.linestrings(np.array(ends)), np.array(widths), cap_style="flat")
    lane_tree = shapely.STRtree(lanes)
    split = 0

    # Roads and railways on the ground, which piers keep off.
    ground = [shapely.buffer(o[0], o[3] / 2 + PIER_CLEAR) for o in others if not o[4] and o[3] > 0]
    ground_tree = shapely.STRtree(ground)

    corner, tile = meta["corner"], meta["tile"]
    nx, nz = int(round(meta["extent"][0] / tile)), int(round(meta["extent"][1] / tile))
    buckets = {}

    def put(x, z, part):
        key = (min(nx - 1, max(0, int((x - corner[0]) // tile))), min(nz - 1, max(0, int((z - corner[1]) // tile))))
        buckets.setdefault(key, []).append(part)

    # Every deck edge a rail may stand on, and every junction disc, gathered
    # first: a rail is laid along the outline of all the decks together,
    # not one segment's side at a time, so it turns corners unbroken.
    rail_edges, discs = [], []
    for wi, w, p, h, ids, off, high in ribbons:
        cut_at = {}
        raised = np.zeros(len(high), bool)  # on a structure, not an embankment
        for i in np.flatnonzero(high):
            a, b = p[i], p[i + 1]
            la, lb, ra, rb = a + off[i], b + off[i + 1], a - off[i], b - off[i + 1]
            ya, yb = h[i], h[i + 1]
            cx, cz = (a + b) / 2
            foot = shapely.make_valid(Polygon([la, lb, rb, ra]))
            cut, dividers, aloft = _beside(wi, a, b, ya, yb, foot, lanes, lane_info, lane_tree)
            cut_at[i] = cut
            raised[i] = w["bridge"] or aloft
            if cut is None:
                put(cx, cz, _quad([la, lb, rb, ra], [ya, yb, yb, ya], [0, 1, 0], DECK))
                edges = [(la, lb, ya, yb, off[i] + off[i + 1]), (rb, ra, yb, ya, -(off[i] + off[i + 1]))]
            else:
                split += 1
                # Thin only across the road counts as a sliver: run on its
                # own, a segment shorter than SLIVER, as one a node tied
                # beside another road leaves, would go whole, a slit
                # across the deck. So the test runs on it drawn SLIVER on
                # past both ends, and what passes is clipped back to it.
                on = (b - a) / max(float(np.hypot(*(b - a))), 1e-9) * SLIVER
                ext = shapely.make_valid(Polygon([la - on, lb + on, rb + on, ra - on]))
                deck = _and(foot, _solid(_area(shapely.difference(ext, cut, grid_size=GRID))))
                y = _between(la, ra, lb, rb, ya, yb)
                put(cx, cz, _top(deck, y))
                edges = _edges(deck, [(la, lb), (ra, rb)] + dividers, y)
                # The rail goes round the whole of what is left, the cut too:
                # where a road beside this one takes over, the cut edge has
                # that road's deck past it and _rails drops it there, but
                # where the two part, the cut is the open inside of the V.
                rail_edges += _edges(deck, None, y)
            for s0, s1, y0, y1, side in edges:
                bottom = (max(0.0, y0 - THICK), max(0.0, y1 - THICK)) if raised[i] else (0.0, 0.0)
                put(cx, cz, _quad([s0, s1, s1, s0], [bottom[0], bottom[1], y1, y0], [side[0], 0, side[1]], SIDE))
                if cut is None:
                    rail_edges.append((s0, s1, y0, y1, side))
        # A disc where a way ends, so ways meeting at an angle leave no gap.
        # It falls away from the node as steeply as the roads leaving it,
        # which keeps it under them all, showing only in the gaps.
        for i in (0, len(p) - 1):
            k = min(i, len(high) - 1)
            if high[k]:
                disc = shapely.buffer(shapely.points(p[i]), w["width"] / 2, quad_segs=3)
                if cut_at.get(k) is not None:
                    disc = shapely.difference(disc, cut_at[k])
                c, top, slope = p[i], h[i], fall[ids[i]]
                cone = lambda q, c=c, top=top, slope=slope: top - slope * np.hypot(q[..., 0] - c[0], q[..., 1] - c[1])
                put(c[0], c[1], _top(disc, cone))
                discs.append((c, w["width"] / 2, top, slope))
                rail_edges += _edges(disc, None, cone)
        if raised.any():
            for c, d, y in _along(p, h, raised, PIER_STEP):
                if y - THICK < PIER_MIN:
                    continue
                across = np.array([-d[1], d[0]]) * min(w["width"] * 0.35, 5.0)
                along = d * PIER_DEPTH / 2
                pier = Polygon([c + across + along, c - across + along, c - across - along, c + across - along])
                if len(ground_tree.query(pier, predicate="intersects")):
                    continue
                put(c[0], c[1], _walls(pier, 0.0, y - THICK, PIER, 0))

    # The road surface exactly as drawn, for the rails to read.
    drawn = [part[0][part[1] == DECK] for parts in buckets.values() for part in parts if len(part[0])]
    drawn = np.concatenate(drawn).astype(float)
    drawn = drawn[np.abs(np.cross(drawn[:, 1] - drawn[:, 0], drawn[:, 2] - drawn[:, 0])[:, 1]) > 1e-9]
    # OSM draws each road its own width, so two decks side by side at one
    # height, twin carriageways tied flush or a ramp beside a motorway, can
    # leave a slit between them, its rail coming and going wherever the
    # slit narrows. A gap narrower than GAP_FILL is deck too, where the
    # decks either side of it are less than STEP_MAX apart.
    filled, kept_open = _fill_gaps(drawn)
    for at, part in filled:
        put(at[0], at[1], part)
        drawn = np.concatenate([drawn, part[0].astype(float)])
    print("bridges: %d gaps between decks filled, %d left open between decks STEP_MAX apart" % (len(filled), kept_open), flush=True)
    for at, part in _rails(rail_edges, drawn):
        put(at[0], at[1], part)

    total = 0
    tiles = {(t["x"], t["z"]): t for t in meta["tiles"]}
    for t in meta["tiles"]:
        t.pop("decks", None)
    for (tx, tz), parts in sorted(buckets.items()):
        parts = [q for q in parts if len(q[0])]
        if not parts:
            continue
        fname = "d_%d_%d.bin" % (tx, tz)
        total += _write(os.path.join(out, "tiles", fname), parts)
        tiles.setdefault((tx, tz), {"x": tx, "z": tz})["decks"] = fname
    meta["tiles"] = sorted(tiles.values(), key=lambda t: (t["z"], t["x"]))
    with open(meta_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent=1)
    print("bridges: %d deck segments (%d split beside another road), %d triangles in %d tiles" % (len(segs), split, total, len(buckets)), flush=True)


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


def _fill_gaps(drawn):
    """The gaps narrower than GAP_FILL between decks less than STEP_MAX
    apart across them, as (where, part), each at the height of the deck
    nearest each of its corners; and how many gaps were left open, the
    decks either side of them apart."""
    flat = shapely.polygons(drawn[:, :, [0, 2]])
    tree = shapely.STRtree(flat)
    whole = shapely.union_all(flat, grid_size=GRID)
    r = GAP_FILL / 2
    closed = shapely.buffer(shapely.buffer(whole, r, quad_segs=2), -r, quad_segs=2)
    gaps = shapely.get_parts(_area(shapely.difference(closed, whole, grid_size=GRID)))

    def on(t, q):
        """The height of triangle t's plane over the points q."""
        m = np.array([[t[1, 0] - t[0, 0], t[2, 0] - t[0, 0]], [t[1, 2] - t[0, 2], t[2, 2] - t[0, 2]]])
        try:
            u, v = np.linalg.solve(m, (q - t[0, [0, 2]]).T)
        except np.linalg.LinAlgError:
            return np.full(len(q), np.nan)
        return t[0, 1] + u * (t[1, 1] - t[0, 1]) + v * (t[2, 1] - t[0, 1])

    out, kept_open = [], 0
    for g in gaps:
        if g.area < 1e-3:
            continue
        rim = shapely.get_coordinates(shapely.segmentize(g.exterior, 0.25))
        # Every deck within a gap's width of each point of its rim: the
        # one it borders and the one across it.
        level = True
        for q in rim:
            hs = [on(drawn[ti], q[None])[0] for ti in tree.query(shapely.points(q), predicate="dwithin", distance=GAP_FILL + 0.05)]
            hs = [x for x in hs if np.isfinite(x)]
            if hs and max(hs) - min(hs) >= STEP_MAX:
                level = False
                break
        if not level:
            kept_open += 1
            continue

        def y(c, g=g):
            pts = c.reshape(-1, 2)
            near = tree.nearest(shapely.points(pts))
            return np.array([on(drawn[ti], p[None])[0] for ti, p in zip(near, pts)]).reshape(c.shape[:-1])
        c = np.array(g.centroid.coords[0])
        out.append((c, _top(g, y)))
    return out, kept_open


def _key(a, b):
    return (a, b) if a < b else (b, a)


def _couple(ways, pos):
    """Ties decks that run side by side over the same ground to one height:
    each node of one, within the two half widths of the other's centre line
    and heading its way, gets a node right beside it on the other, and a
    rung of no length between the two. Two bridges on one OSM layer, or two
    roads on the ground, are tied wherever they run so; others only along
    the run from a node they share, where one leaves the other. Roads that
    cross, and roads heading opposite ways, are not tied. New nodes are
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
            same = (w["bridge"] and o["bridge"] and w["raw_layer"] == o["raw_layer"]) or not (w["bridge"] or o["bridge"])
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
                    if shapely.distance(lb, q) >= (A["width"] + B["width"]) / 2 + 0.5:
                        continue
                    da = pts[min(k + 1, len(pts) - 1)] - pts[max(k - 1, 0)]
                    t = float(shapely.line_locate_point(lb, q))
                    m = int(np.clip(np.searchsorted(cb, t), 1, len(cb) - 1))
                    db = B["pts"][m] - B["pts"][m - 1]
                    if float(da @ db) < SPLIT_COS * float(np.hypot(*da) * np.hypot(*db)):
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


def _densify(ways, uses, pos):
    """Cuts every edge longer than STEP on the elevated ways and the roads
    meeting them into equal pieces, so their heights can curve. New nodes
    are appended to pos."""
    near = set()
    for w in ways:
        if w["bridge"] or w["cls"] in EXPRESS:
            for i in w["ids"]:
                for o in uses.get(i, ()):
                    near.add(id(o))
    for w in ways:
        if id(w) not in near:
            continue
        pts, ids, level = [w["pts"][0]], [w["ids"][0]], []
        for k in range(1, len(w["ids"])):
            a, b = w["pts"][k - 1], w["pts"][k]
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


def _junctions(ways):
    """Per node where three or more arms of road meet, how far out it
    stays level along each way: as far as the widest other road there
    reaches, so a ramp comes level with the road it joins at that road's
    edge, not under it at its centre line a step below. Ways ending in
    each other end to end are one road carrying on, and stay as solved."""
    arms, wide = {}, {}
    for wi, w in enumerate(ways):
        last = len(w["ids"]) - 1
        for k, i in enumerate(w["ids"]):
            arms[i] = arms.get(i, 0) + (1 if k in (0, last) else 2)
            wide.setdefault(i, []).append((wi, w["width"] / 2))
    return {i: wide[i] for i in arms if arms[i] >= 3}


def _level(p, h, ids, wi, reach, coupled=()):
    """A way's points and heights with each junction on it held level out
    to the other roads' edges: within r of the node its height, beyond
    that the solved profile stretched back over LEVEL_SPAN times r, so the
    grade there rises by at most LEVEL_SPAN / (LEVEL_SPAN - 1). Points
    added for this get node id -1."""
    s = np.concatenate([[0.0], np.cumsum(np.hypot(*(p[1:] - p[:-1]).T))])
    at = [k for k, i in enumerate(ids) if i in reach]
    if not at or len(p) < 2:
        return p, h, ids
    warps = []
    for n, k in enumerate(at):
        # Roads tied side by side take one radius there, their own too, so
        # both are drawn level over the same stretch and stay flush.
        r = max((half for wj, half in reach[ids[k]] if wj != wi or ids[k] in coupled), default=0.0)
        if r <= 0.0:
            continue
        for side in (-1, 1):
            if (side < 0 and k == 0) or (side > 0 and k == len(p) - 1):
                continue
            nxt = at[n + side] if 0 <= n + side < len(at) else (0 if side < 0 else len(p) - 1)
            room = abs(s[nxt] - s[k]) / (2.0 if nxt in at else 1.0)
            span = min(LEVEL_SPAN * r, room)
            warps.append((s[k], side, span / LEVEL_SPAN, span))
    if not warps:
        return p, h, ids
    extra = [c + side * d for c, side, r, span in warps for d in (r, span)]
    new_s = np.unique(np.concatenate([s, np.clip(extra, 0.0, s[-1])]))
    src = new_s.copy()
    for c, side, r, span in warps:
        d = (new_s - c) * side
        inside = (d >= 0) & (d <= span)
        src[inside] = c + side * np.maximum(0.0, d[inside] - r) * span / (span - r)
    out_p = np.stack([np.interp(new_s, s, p[:, 0]), np.interp(new_s, s, p[:, 1])], axis=1)
    out_ids = np.full(len(new_s), -1)
    out_ids[np.searchsorted(new_s, s)] = ids
    return out_p, np.interp(src, s, h), out_ids


def _beside(wi, a, b, ya, yb, foot, lanes, info, tree):
    """What a deck segment a-b gives up to the roads beside it: where one
    overlaps its footprint side by side, the part of that road's footprint
    nearer its centre line than this one's, wherever the two stand less
    than CLEAR apart in height; the lines dividing them, as point pairs,
    where they stand STEP_MAX apart somewhere; and whether it passes
    CLEAR over a road beside it, and so stands on piers there. None and
    no lines when no road takes any of it."""
    da = (b - a) / max(float(np.hypot(*(b - a))), 1e-9)
    cuts, dividers, aloft = [], [], False
    for j in tree.query(foot, predicate="intersects"):
        wj, c, d, yc, yd, _ = info[j]
        if wj == wi:
            continue
        db = (d - c) / max(float(np.hypot(*(d - c))), 1e-9)
        if abs(float(da @ db)) < SPLIT_COS or shapely.crosses(LineString([a, b]), LineString([c, d])):
            continue  # crossing, which the heights already clear
        over = _and(foot, lanes[j])
        if over.area < 1.0:
            continue
        m = np.array(over.centroid.coords[0])
        qa, _ = _closest(a, b, m)
        qb, _ = _closest(c, d, m)
        # Nearer the other's centre line than this one's: where the
        # distances to the two lines, |na . (p - a)| and |nb . (p - c)|,
        # compare that way, a double wedge between the two lines bisecting
        # their angle (a strip's half when they are parallel).
        na, nb = np.array([-da[1], da[0]]), np.array([-db[1], db[0]])
        if np.hypot(*(qb - qa)) < 1e-6:
            continue  # one on top of the other
        g1, g2 = (na - nb, nb @ c - na @ a), (na + nb, -nb @ c - na @ a)
        lane, at, big = lanes[j], (a + b) / 2, 2.0 * float(np.hypot(*(b - a)) + np.hypot(*(d - c)) + 100.0)
        nearer = _or(
            _and(_and(lane, _half(*g1, at, big)), _half(*g2, at, big)),
            _and(_and(lane, _half(-g1[0], -g1[1], at, big)), _half(-g2[0], -g2[1], at, big)))
        # Each one's height runs linearly along its segment and stays at its
        # end heights past them, as the deck does round a bend; so the
        # height between them is linear over each pair of those pieces.
        cut, apart = Polygon(), False
        for sa, fa, ra in _pieces(a, b, ya, yb, at, big):
            for sb, fb, rb in _pieces(c, d, yc, yd, at, big):
                where = _and(sa, sb)
                if where.is_empty:
                    continue
                g, r0 = fa - fb, ra - rb
                # Where this one rises CLEAR above the other it passes over
                # it, on a structure whatever OSM says; where it is CLEAR
                # below, under it. Neither gives anything up there; nearer
                # than that each keeps its own side of the line between
                # them, which is a divider once they are STEP_MAX apart.
                if _and(_and(over, where), _half(g, r0 - CLEAR, at, big)).area >= 1.0:
                    aloft = True
                mine = _and(nearer, _and(where, _and(_half(-g, CLEAR - r0, at, big), _half(g, r0 + CLEAR, at, big))))
                cut = _or(cut, mine)
                apart = apart or not _and(mine, _or(_half(g, r0 - STEP_MAX, at, big), _half(-g, -r0 - STEP_MAX, at, big))).is_empty
        if not cut.is_empty:
            cuts.append(cut)
        if apart:
            dividers += [_line(*g) for g in (g1, g2) if np.hypot(*g[0]) > 1e-9]
    return (shapely.union_all(cuts, grid_size=GRID) if cuts else None), dividers, aloft


def _pieces(a, b, ya, yb, at, big):
    """A segment's height over the plane in three pieces, before a, along
    a-b and past b, as (where, gradient, height at the origin)."""
    t = b - a
    g = (yb - ya) * t / max(float(t @ t), 1e-9)
    flat = np.zeros(2)
    return [(_half(-t, t @ a, at, big), flat, ya),
            (_and(_half(t, -(t @ a), at, big), _half(-t, t @ b, at, big)), g, ya - g @ a),
            (_half(t, -(t @ b), at, big), flat, yb)]


def _line(g, g0):
    """Two points on the line g . p + g0 = 0, a unit apart."""
    n = g / float(np.hypot(*g))
    o = -g0 / float(np.hypot(*g)) * n
    return o, o + np.array([-n[1], n[0]])


def _half(g, g0, at, big):
    """The half plane where g . p + g0 >= 0, as far as big from at: the
    whole of that square when g is zero and g0 is not negative, and
    nothing when it is. Kept local, since overlays of planes far bigger
    than what they cut lose precision."""
    box = Polygon([at + (-big, -big), at + (big, -big), at + (big, big), at + (-big, big)])
    size = float(np.hypot(*g))
    if size < 1e-12:
        return box if g0 >= 0 else Polygon()
    n = g / size
    # How far at stands inside the half plane; the box reaches at most
    # big * sqrt 2 from at, so past 1.5 big it is all in or all out.
    s = n @ at + g0 / size
    if s >= 1.5 * big:
        return box
    if s <= -1.5 * big:
        return Polygon()
    o = at - s * n
    t = np.array([-n[1], n[0]]) * 3 * big
    return _and(box, Polygon([o - t, o + t, o + t + n * 3 * big, o - t + n * 3 * big]))


def _and(p, q):
    """The area p and q share, any edges or points they touch at dropped."""
    return _area(shapely.intersection(p, q, grid_size=GRID))


def _or(p, q):
    """The area of p and q together."""
    return _area(shapely.union(p, q, grid_size=GRID))


def _solid(g):
    """g without the parts of it under SLIVER wide: what a cut leaves
    where its line runs a hair off a deck's edge, which would stand up as
    a stub of wall and rail with no deck to walk to. Mitred, so straight
    edges come back where they were."""
    kept = shapely.buffer(shapely.buffer(g, -SLIVER / 2, join_style="mitre"), SLIVER / 2, join_style="mitre")
    # On the grid the overlay works to, which a mitre's spikes can be
    # invalid against.
    return _and(g, shapely.set_precision(shapely.make_valid(kept), GRID))


def _area(g):
    """The polygons in g, as one geometry."""
    parts = [q for q in shapely.get_parts(g) if q.geom_type in ("Polygon", "MultiPolygon")]
    return shapely.union_all(parts, grid_size=GRID) if parts else Polygon()


def _closest(a, b, m):
    """The point on segment a-b nearest m, and how far along it is."""
    d = b - a
    t = float(np.clip((m - a) @ d / max(float(d @ d), 1e-9), 0.0, 1.0))
    return a + d * t, t


def _between(la, ra, lb, rb, ya, yb):
    """Height over a segment's mitred quad: ya all along its end la-ra and
    yb all along lb-rb, by how far a point lies between the two. The next
    segment shares that end, so the two meet at one height across a bend;
    going by distance along the centre line instead puts the mitre's
    corners at different heights in each, a lip on a grade."""
    def toward(e0, e1, far):
        n = np.array([e1[1] - e0[1], e0[0] - e1[0]])
        n /= max(float(np.hypot(*n)), 1e-9)
        return (n if (far - e0) @ n > 0 else -n), e0
    (na, oa), (nb, ob) = toward(la, ra, lb), toward(lb, rb, la)
    def y(q):
        sa, sb = np.maximum((q - oa) @ na, 0.0), np.maximum((q - ob) @ nb, 0.0)
        return ya + (yb - ya) * sa / np.maximum(sa + sb, 1e-9)
    return y


def _top(deck, y):
    """A deck's road surface over the polygon deck, y giving the height at
    each point."""
    parts = [g for g in shapely.get_parts(deck) if g.geom_type == "Polygon"]
    if not parts:
        return _empty()
    deck = shapely.multipolygons(parts)
    tris = shapely.get_parts(shapely.constrained_delaunay_triangles(deck))
    if len(tris) == 0:
        return _empty()
    c = shapely.get_coordinates(tris).reshape(-1, 4, 2)[:, :3]
    pos = np.stack([c[:, :, 0], y(c), c[:, :, 1]], axis=2).astype(np.float32)
    return _facing(pos, np.array([0.0, 1.0, 0.0])), _bytes(len(pos), DECK), _bytes(len(pos), 0)


def _edges(deck, sides, y):
    """The sides of a split deck segment as (s0, s1, y0, y1, outward):
    with sides None, every edge of its outline.
    the edges of its outline along its own sides or a line dividing it from
    a road beside it. Where the cut ends because the two come level, the
    road runs on into the other, and an edge there is open."""
    out = []
    for poly in shapely.get_parts(shapely.orient_polygons(deck)):
        if poly.geom_type != "Polygon":
            continue
        for r in [poly.exterior] + list(poly.interiors):
            q = np.asarray(r.coords)
            for s0, s1 in zip(q[:-1], q[1:]):
                if np.hypot(*(s1 - s0)) < 1e-6 or sides is not None and not any(_on(s0, *e) and _on(s1, *e) for e in sides):
                    continue
                y0, y1 = (float(y(s)) for s in (s0, s1))
                # Outlines run counter-clockwise in (x, z), so outside is
                # to the right.
                out.append((s0, s1, y0, y1, np.array([s1[1] - s0[1], -(s1[0] - s0[0])])))
    return out


def _on(q, e0, e1):
    """Whether q lies on the line through e0 and e1."""
    d = e1 - e0
    return abs(float(d[0] * (q[1] - e0[1]) - d[1] * (q[0] - e0[0]))) <= 1e-3 * max(float(np.hypot(*d)), 1e-9)


def _region(rings):
    """The boundary rings back as one area: a point is inside when it is
    inside an odd number of them."""
    region = Polygon()
    for r in rings:
        region = shapely.symmetric_difference(region, shapely.make_valid(Polygon(r)))
    return region


def _offsets(p, half):
    """Per vertex, the offset from the centre line to the left edge of a
    ribbon half wide, mitred at bends."""
    d = p[1:] - p[:-1]
    d /= np.hypot(*d.T)[:, None]
    nrm = np.stack([-d[:, 1], d[:, 0]], axis=1)
    m = np.concatenate([nrm[:1], nrm[:-1] + nrm[1:], nrm[-1:]])
    m /= np.maximum(np.hypot(*m.T), 1e-9)[:, None]
    ref = np.concatenate([nrm[:1], nrm])
    cos = np.maximum(0.5, (m * ref).sum(axis=1))
    return m * (half / cos)[:, None]


def _quad(xz, y, normal, kind, fan=False):
    """A polygon of points xz at heights y as triangles facing normal: a
    quad split in two, or with fan a convex polygon fanned from its first
    corner."""
    pts = np.array([[q[0], yy, q[1]] for q, yy in zip(xz, y)], dtype=np.float32)
    tris = np.stack([np.stack([pts[0], pts[i], pts[i + 1]]) for i in range(1, len(pts) - 1)])
    keep = np.linalg.norm(np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]), axis=1) > 1e-6
    tris = tris[keep]
    if not len(tris):
        return _empty()
    return _facing(tris, np.array(normal, dtype=np.float64)), _bytes(len(tris), kind), _bytes(len(tris), 0)


def _rails(edges, deck):
    """Rails along the outline of every deck, as (where, part): the edges
    (s0, s1, y0, y1, outward) chained end to end into lines wherever they
    meet, so a rail runs round a bend or on into the next segment as one
    mitred piece; broken only where the deck is low, or where the ground
    just past the edge is another deck at about the same height, so the
    road carries on there. Each piece is capped at its ends.

    deck is every road-surface triangle as drawn: the test is asked of the
    surface itself, never of the footprint a segment or disc started from,
    since cutting one road where another runs beside it leaves holes that
    footprint still covers, and a rail left out there leaves an open V."""
    lines = _chain(edges)
    if not lines:
        return []
    tree = shapely.STRtree(shapely.polygons(deck[:, :, [0, 2]]))

    def deck_near(pts, y):
        """Per point, whether some deck there carries on from height y."""
        hit = np.zeros(len(pts), bool)
        pairs = tree.query(shapely.points(pts), predicate="intersects")
        for pi, ti in zip(*pairs):
            if hit[pi]:
                continue
            t = deck[ti]
            m = np.array([[t[1, 0] - t[0, 0], t[2, 0] - t[0, 0]], [t[1, 2] - t[0, 2], t[2, 2] - t[0, 2]]])
            try:
                u, v = np.linalg.solve(m, pts[pi] - t[0, [0, 2]])
            except np.linalg.LinAlgError:
                continue
            there = t[0, 1] + u * (t[1, 1] - t[0, 1]) + v * (t[2, 1] - t[0, 1])
            hit[pi] = -STEP_MAX < there - y[pi] < RAIL_JOIN
        return hit

    # Sample every line finely at once: a sample keeps its rail where the
    # deck is high enough and neither the ground just past the edge nor a
    # step beyond it is another deck at the same height.
    samples = []
    for li, (pts, ys, outs) in enumerate(lines):
        cum = np.concatenate([[0.0], np.cumsum(np.hypot(*(pts[1:] - pts[:-1]).T))])
        k = max(1, int(math.ceil(cum[-1] / RAIL_STEP)))
        t = (np.arange(k) + 0.5) / k * cum[-1]
        seg = np.clip(np.searchsorted(cum, t, side="right") - 1, 0, len(pts) - 2)
        f = ((t - cum[seg]) / np.maximum(cum[seg + 1] - cum[seg], 1e-9))[:, None]
        samples.append((cum, k, pts[seg] + (pts[seg + 1] - pts[seg]) * f, ys[seg] + (ys[seg + 1] - ys[seg]) * f[:, 0], outs[seg]))
    mid = np.concatenate([s[2] for s in samples])
    y = np.concatenate([s[3] for s in samples])
    out = np.concatenate([s[4] for s in samples])
    n05, n08 = deck_near(mid + out * 0.05, y), deck_near(mid + out * 0.8, y)
    keep = (y > RAIL_MIN + LIFT) & ~n05 & ~n08

    parts, at = [], 0
    for (pts, ys, outs), (cum, k, _, _, _) in zip(lines, samples):
        mask = keep[at:at + k]
        at += k
        closed = len(pts) > 2 and np.hypot(*(pts[-1] - pts[0])) < RAIL_WELD
        if closed and mask.all():
            parts.append(((pts[0][0], pts[0][1]), _ribbon(pts, ys, outs, closed=True)))
            continue
        for r0, r1 in _runs(mask):
            t0, t1 = r0 / k * cum[-1], (r1 + 1) / k * cum[-1]
            if t1 - t0 < RAIL_STEP * 1.5:
                continue  # a speck where two decks only just part
            p, yy, oo = _slice(pts, ys, outs, cum, t0, t1)
            parts.append(((p[0][0], p[0][1]), _ribbon(p, yy, oo)))
    return parts


def _chain(edges):
    """The edges joined end to end into lines, each (points, heights,
    outward per piece), turned so outside is on the right. An edge's end
    joins the start of the one carrying on most nearly straight from it
    within RAIL_GAP at the same height, each start taken once, nearest
    first; so the edges of two ways meeting, which miss each other by the
    width of their mitres, still make one rail, and at a fork the rail
    follows the straighter way."""
    e = []
    for s0, s1, y0, y1, side in edges:
        s0, s1 = np.asarray(s0, float), np.asarray(s1, float)
        d = s1 - s0
        if float(np.hypot(*d)) < 1e-6:
            continue
        if float(side[0] * d[1] - side[1] * d[0]) < 0:  # outside on the left
            s0, s1, y0, y1 = s1, s0, y1, y0
            d = -d
        d = d / float(np.hypot(*d))
        e.append((s0, s1, float(y0), float(y1), np.array([d[1], -d[0]]), d))
    if not e:
        return []

    starts = {}
    for j, (s0, _, _, _, _, _) in enumerate(e):
        starts.setdefault((int(s0[0] // RAIL_GAP), int(s0[1] // RAIL_GAP)), []).append(j)
    pairs = []
    for i, (_, s1, _, y1, _, di) in enumerate(e):
        cx, cz = int(s1[0] // RAIL_GAP), int(s1[1] // RAIL_GAP)
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                for j in starts.get((cx + dx, cz + dz), ()):
                    if j == i:
                        continue
                    s0, _, y0, _, _, dj = e[j]
                    gap = float(np.hypot(*(s0 - s1)))
                    turn = float(di @ dj)
                    if gap < RAIL_GAP and abs(y0 - y1) < 0.3 and turn > 0.5:
                        pairs.append((round(gap / RAIL_WELD), -turn, i, j))
    pairs.sort()
    nxt, has_prev = [-1] * len(e), [False] * len(e)
    for _, _, i, j in pairs:
        if nxt[i] == -1 and not has_prev[j]:
            nxt[i], has_prev[j] = j, True

    lines, used = [], [False] * len(e)

    def walk(i):
        order = []
        while i != -1 and not used[i]:
            used[i] = True
            order.append(i)
            i = nxt[i]
        pts, ys, outs = [e[order[0]][0]], [e[order[0]][2]], []
        for j in order:
            s0, s1, y0, y1, n, _ = e[j]
            if np.hypot(*(s0 - pts[-1])) > 1e-6:  # bridge the gap
                g = s0 - pts[-1]
                g = g / float(np.hypot(*g))
                pts.append(s0)
                ys.append(y0)
                outs.append(np.array([g[1], -g[0]]))
            pts.append(s1)
            ys.append(y1)
            outs.append(n)
        if nxt[order[-1]] == order[0] and np.hypot(*(pts[0] - pts[-1])) > 1e-6:
            g = pts[0] - pts[-1]
            g = g / float(np.hypot(*g))
            pts.append(pts[0])
            ys.append(ys[0])
            outs.append(np.array([g[1], -g[0]]))
        return np.array(pts), np.array(ys), np.array(outs)

    for i in range(len(e)):
        if not has_prev[i] and not used[i]:
            lines.append(walk(i))
    for i in range(len(e)):
        if not used[i]:
            lines.append(walk(i))  # a closed loop
    return lines


def _slice(pts, ys, outs, cum, t0, t1):
    """The part of a line from distance t0 to t1 along it."""
    i0 = int(np.clip(np.searchsorted(cum, t0, side="right") - 1, 0, len(pts) - 2))
    i1 = int(np.clip(np.searchsorted(cum, t1, side="left") - 1, 0, len(pts) - 2))

    def at(t, i):
        f = (t - cum[i]) / max(cum[i + 1] - cum[i], 1e-9)
        return pts[i] + (pts[i + 1] - pts[i]) * f, ys[i] + (ys[i + 1] - ys[i]) * f

    a, ya = at(t0, i0)
    b, yb = at(t1, i1)
    p = [a] + [pts[j] for j in range(i0 + 1, i1 + 1)] + [b]
    yy = [ya] + [ys[j] for j in range(i0 + 1, i1 + 1)] + [yb]
    return np.array(p), np.array(yy), outs[i0:i1 + 1]


def _ribbon(p, y, outs, closed=False):
    """A rail standing on line p at heights y, outside on outs per piece:
    its outer face on the line, its inner face RAIL_THICK in, mitred at
    every bend so the two meet the next piece flush, with a top and, unless
    closed, an end cap at each end."""
    if closed:
        p, y = p[:-1], y[:-1]
        prev, cur = np.roll(outs, 1, axis=0), outs
    else:
        prev = np.concatenate([outs[:1], outs])
        cur = np.concatenate([outs, outs[-1:]])
    m = prev + cur
    m /= np.maximum(np.hypot(*m.T), 1e-9)[:, None]
    m /= np.maximum(0.5, (m * cur).sum(axis=1))[:, None]
    q = p - m * RAIL_THICK
    top = y + RAIL_HEIGHT
    tris = []
    n = len(p)
    for i in range(n if closed else n - 1):
        j = (i + 1) % n
        o = outs[i]
        tris.append(_quad([p[i], p[j], p[j], p[i]], [y[i], y[j], top[j], top[i]], [o[0], 0, o[1]], RAIL))
        tris.append(_quad([q[j], q[i], q[i], q[j]], [y[j], y[i], top[i], top[j]], [-o[0], 0, -o[1]], RAIL))
        tris.append(_quad([p[i], p[j], q[j], q[i]], [top[i], top[j], top[j], top[i]], [0, 1, 0], RAIL))
    if not closed:
        for i, s in ((0, -1.0), (n - 1, 1.0)):
            d = p[1] - p[0] if i == 0 else p[-1] - p[-2]
            d = d / max(float(np.hypot(*d)), 1e-9) * s
            tris.append(_quad([p[i], q[i], q[i], p[i]], [y[i], y[i], top[i], top[i]], [d[0], 0, d[1]], RAIL))
    tris = [t for t in tris if len(t[0])]
    if not tris:
        return _empty()
    return tuple(np.concatenate([t[k] for t in tris]) for k in range(3))


def _runs(mask):
    """(first, last) of each run of True in mask."""
    runs, start = [], None
    for i, v in enumerate(mask):
        if v and start is None:
            start = i
        elif not v and start is not None:
            runs.append((start, i - 1))
            start = None
    if start is not None:
        runs.append((start, len(mask) - 1))
    return runs


def _along(p, h, high, step):
    """Points every step along the high segments of a polyline: (centre,
    direction, height)."""
    out, carry = [], step / 2
    for i in range(len(p) - 1):
        d = p[i + 1] - p[i]
        length = float(np.hypot(*d))
        if not high[i]:
            carry = step / 2
            continue
        s = carry
        while s < length:
            u = s / length
            out.append((p[i] + d * u, d / length, h[i] + (h[i + 1] - h[i]) * u))
            s += step
        carry = s - length
    return out


if __name__ == "__main__":
    main()

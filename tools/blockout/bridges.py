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
from osm_city import road_class, ROAD_WIDTHS, RAIL_WIDTH, MEDIAN, _bytes, _empty, _facing, _walls, _write  # noqa: E402

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
## Two decks this far apart in height or more pass over and under each
## other; nearer, side by side they divide the ground between them. Below
## CLEAR, so a pair the solve holds at exactly CLEAR is never cut piece by
## piece on rounding.
CLEAR_SPLIT = CLEAR - 0.5
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
## Whether deck carries on past an edge is asked of the ground this far
## out past it: past the GRID decks are cut to, so a deck cut from another
## finds it, and short of any gap the eye could see.
RAIL_PROBE = 0.005
## Where two edges of decks meet within this, a rail runs on round the
## corner as one piece, at any turn short of a hairpin;
RAIL_WELD = 0.05
## and where they miss each other by less than this, still, carrying on
## within 60 degrees, unless the link would stand on deck RAIL_OPEN out
## past it.
RAIL_GAP = 1.0
RAIL_OPEN = 0.05
## A rail shorter than this all told is a speck, where an edge only just
## leaves the deck beside it, and is left out.
RAIL_SPECK = 0.1
## Sides of the disc where a way ends, even, so a corner falls on each
## side of the road.
DISC_SIDES = 24
PIER_MIN = 5.0
## Gaps between decks narrower than this, the avatar's width, are filled
## where the decks either side of them stand less than STEP_MAX apart.
GAP_FILL = 1.0
## They are looked for a slab this many metres deep at a time, among the
## decks within GAP_PAD of it: past STEP_MAX and the rise of a ramp across
## a gap, and well short of a deck crossing over another.
GAP_SLAB = 2.0
GAP_PAD = 1.0
## A hole in the decks smaller across than this is filled like a gap,
## where the decks round it are level: a slot a split leaves inside a deck,
## too small to be anything but a pit with a rail round it.
HOLE_FILL = 4.0
PIER_STEP = 40.0
PIER_DEPTH = 2.5
## Piers stay this far clear of the roads and railways under a deck.
PIER_CLEAR = 2.0
## A pier the spacing puts in a road moves along the deck by these, nearest
## first, to the first clear spot, so a long span keeps its support.
PIER_SLIDE = (5.0, 10.0, 15.0)
## Decks run on this far past the map's boundary, into the fog.
RUNOUT = 60.0
## Classes that never meet a street at grade, so their junctions are not
## pinned to the ground and their bridges stand a full layer.
EXPRESS = ("motorway", "motorway_link", "trunk", "trunk_link")
DECK, SIDE, PIER, RAIL = range(4)


def main():
    raw, out = sys.argv[1], sys.argv[2]
    meta_path = os.path.join(out, "city.json")
    meta = json.load(open(meta_path, encoding="utf-8"))
    ways, others, rails = read(raw, meta)
    pos, height, fall, couple_nodes, _ = solve(ways, others, rails)
    draw(meta, meta_path, out, ways, others, height, fall, couple_nodes)


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


def draw(meta, meta_path, out, ways, others, height, fall, couple_nodes):
    """The decks, their sides, piers and rails at the solved heights, written
    to <out>/tiles/d_X_Z.bin, and city.json's tiles updated."""
    # Decks run on past the boundary into the fog that hides it, so none
    # ends in plain sight at the edge of the map.
    region = shapely.buffer(_region(meta["boundary"]), RUNOUT)
    shapely.prepare(region)
    segs = 0  # deck segments drawn
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
        segs += int(high.sum())

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
    piers = moved = blocked = 0
    for wi, w, p, h, ids, off, high in ribbons:
        cut_at = {}
        raised = np.zeros(len(high), bool)  # on a structure, not an embankment
        for i in np.flatnonzero(high):
            a, b = p[i], p[i + 1]
            la, lb, ra, rb = a + off[i], b + off[i + 1], a - off[i], b - off[i + 1]
            ya, yb = h[i], h[i + 1]
            cx, cz = (a + b) / 2
            foot = shapely.make_valid(Polygon([la, lb, rb, ra]))
            # Thin only across the road counts as a sliver: run on its
            # own, a segment shorter than SLIVER, as one a node tied
            # beside another road leaves, would go whole, a slit across
            # the deck. So it is judged drawn SLIVER on past both ends,
            # and what passes is clipped back to it.
            on = (b - a) / max(float(np.hypot(*(b - a))), 1e-9) * SLIVER
            ext = shapely.make_valid(Polygon([la - on, lb + on, rb + on, ra - on]))
            cut, dividers, aloft = _beside(wi, a, b, ya, yb, foot, ext, lanes, lane_info, lane_tree)
            cut_at[i] = cut
            raised[i] = w["bridge"] or aloft
            if cut is None:
                put(cx, cz, _quad([la, lb, rb, ra], [ya, yb, yb, ya], [0, 1, 0], DECK))
                edges = [(la, lb, ya, yb, off[i] + off[i + 1]), (rb, ra, yb, ya, -(off[i] + off[i + 1]))]
            else:
                split += 1
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
                disc = _disc(p[i], off[i])
                if cut_at.get(k) is not None:
                    disc = shapely.difference(disc, cut_at[k])
                c, top, slope = p[i], h[i], fall[ids[i]]
                cone = lambda q, c=c, top=top, slope=slope: top - slope * np.hypot(q[..., 0] - c[0], q[..., 1] - c[1])
                put(c[0], c[1], _top(disc, cone))
                discs.append((c, w["width"] / 2, top, slope))
                rail_edges += _edges(disc, None, cone)
        if raised.any():
            cum = np.concatenate([[0.0], np.cumsum(np.hypot(*(p[1:] - p[:-1]).T))])
            for at in _along(cum, raised, PIER_STEP):
                spot = _spot(p, h, cum, raised, at)
                if spot[2] - THICK < PIER_MIN:
                    continue
                for shift in (0.0,) + tuple(x for m in PIER_SLIDE for x in (-m, m)):
                    spot = _spot(p, h, cum, raised, at + shift)
                    if spot is None or spot[2] - THICK < PIER_MIN:
                        continue
                    c, d, y = spot
                    across = np.array([-d[1], d[0]]) * min(w["width"] * 0.35, 5.0)
                    along = d * PIER_DEPTH / 2
                    pier = Polygon([c + across + along, c - across + along, c - across - along, c + across - along])
                    if _blocked(pier, c, y - THICK, wi, ground_tree, lane_info, lane_tree):
                        continue
                    put(c[0], c[1], _walls(pier, 0.0, y - THICK, PIER, 0))
                    piers += 1
                    moved += shift != 0.0
                    break
                else:
                    blocked += 1

    print("bridges: %d piers (%d moved along their deck clear of a road), %d spots with no clear place for one" % (piers, moved, blocked), flush=True)
    # The road surface exactly as drawn, for the gap fill and rails to read.
    drawn = [part[0][part[1] == DECK] for parts in buckets.values() for part in parts if len(part[0])]
    drawn = np.concatenate(drawn).astype(float)
    drawn = drawn[np.abs(np.cross(drawn[:, 1] - drawn[:, 0], drawn[:, 2] - drawn[:, 0])[:, 1]) > 1e-9]
    _finish(drawn, rail_edges, put)

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
    print("bridges: %d deck segments (%d split beside another road), %d triangles in %d tiles" % (segs, split, total, len(buckets)), flush=True)


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


def _finish(drawn, rail_edges, put):
    """The gaps between decks filled and the rails laid, each part handed to
    put(x, z, part): drawn is every road-surface triangle as drawn,
    rail_edges every deck edge a rail may stand on."""
    # OSM draws each road its own width, so two decks side by side at one
    # height, twin carriageways tied flush or a ramp beside a motorway, can
    # leave a slit between them, its rail coming and going wherever the
    # slit narrows. A gap narrower than GAP_FILL is deck too, where the
    # decks either side of it are less than STEP_MAX apart.
    filled, kept_open = _fill_gaps(drawn)
    rail_edges = list(rail_edges)
    for at, part, patch, y in filled:
        put(at[0], at[1], part)
        # A patch's own outline takes a rail where it is open: across the
        # mouth of a V it closes, or where it stops short of a step.
        rail_edges += _edges(patch, None, y)
    if filled:
        drawn = np.concatenate([drawn] + [part[0].astype(float) for _, part, _, _ in filled])
    print("bridges: %d patches fill gaps between decks, %d gaps left open in whole or part between decks STEP_MAX apart" % (len(filled), kept_open), flush=True)
    for at, part in _rails(rail_edges, drawn):
        put(at[0], at[1], part)


def _fill_gaps(drawn):
    """The gaps narrower than GAP_FILL between decks, filled where the
    decks either side are less than STEP_MAX apart across them, as (where,
    part, polygon, height): each patch at the height of the deck nearest
    each of its corners; and how many gaps were left open in whole or in
    part, the decks either side of them apart. A gap is judged along its
    rim, so one running from between decks level to between decks apart
    is filled as far as GAP_FILL short of where they part.

    Gaps are found a slab of height at a time, among the decks near that
    height alone: seen from above, a slit between two decks over a road
    is no gap at all, the road below covering it, and a deck far below
    is not across a gap from the one above it."""
    out, kept_open = [], 0
    ys = drawn[:, :, 1]
    for k in range(int(np.floor(ys.min() / GAP_SLAB)), int(np.floor(ys.max() / GAP_SLAB)) + 1):
        found, n = _fill_slab(drawn, k * GAP_SLAB, (k + 1) * GAP_SLAB)
        out += found
        kept_open += n
    return out, kept_open


def _fill_slab(drawn, lo, hi):
    """_fill_gaps for the gaps whose height is from lo to hi: found among the
    decks within GAP_PAD of it, and only where no deck within twice that
    covers them, so where a slab cuts a ramp the ramp's other side still
    counts."""
    idx, flat = _slab(drawn, lo - GAP_PAD, hi + GAP_PAD)
    if not len(flat):
        return [], 0
    _, cover = _slab(drawn, lo - 2 * GAP_PAD, hi + 2 * GAP_PAD)
    tree = shapely.STRtree(flat)
    r = GAP_FILL / 2
    whole = shapely.union_all(flat, grid_size=GRID)
    closed = shapely.buffer(shapely.buffer(whole, r, quad_segs=2), -r, quad_segs=2)
    # A hole the decks close round is a gap however wide, up to HOLE_FILL:
    # past GAP_FILL across, the closing leaves it open, ringed in rail.
    # Judged on what the closing leaves, so a slot's wide end counts alone.
    holes = [Polygon(h) for part in shapely.get_parts(closed) for h in part.interiors]
    holes = [h for h in holes if 2 * shapely.minimum_bounding_radius(h) < HOLE_FILL]
    if holes:
        closed = shapely.union_all([closed] + holes, grid_size=GRID)
    gaps = shapely.get_parts(_area(shapely.difference(closed, shapely.union_all(cover, grid_size=GRID), grid_size=GRID)))

    def on(t, q):
        """The height of triangle t's plane over the points q."""
        m = np.array([[t[1, 0] - t[0, 0], t[2, 0] - t[0, 0]], [t[1, 2] - t[0, 2], t[2, 2] - t[0, 2]]])
        try:
            u, v = np.linalg.solve(m, (q - t[0, [0, 2]]).T)
        except np.linalg.LinAlgError:
            return np.full(len(q), np.nan)
        return t[0, 1] + u * (t[1, 1] - t[0, 1]) + v * (t[2, 1] - t[0, 1])

    def y(c):
        pts = c.reshape(-1, 2)
        near = tree.nearest(shapely.points(pts))
        return np.array([on(drawn[idx[ti]], p[None])[0] for ti, p in zip(near, pts)]).reshape(c.shape[:-1])

    def own(g):
        """The part of gap g whose nearest deck is from lo to hi: a gap can run
        from between decks in this slab on to between decks above or below
        it, and judged whole by one point it is skipped here and cut short
        as apart there. Split along the rim, each stretch going with the
        deck nearest it."""
        pts = np.concatenate([shapely.get_coordinates(shapely.segmentize(r, 0.25))[:-1] for r in [g.exterior, *g.interiors]])
        hs = y(pts)
        mine = (hs >= lo) & (hs < hi)
        if mine.all() or not mine.any():
            return g if mine.all() else None
        cells = shapely.voronoi_polygons(shapely.multipoints(pts), extend_to=g, ordered=True)
        return _area(shapely.intersection(g, shapely.union_all(shapely.get_parts(cells)[mine], grid_size=GRID), grid_size=GRID))

    out, kept_open = [], 0
    for whole_gap in gaps:
        if whole_gap.area < 1e-3:
            continue
        # Each part of a gap once, in the slab of the deck nearest it.
        mine = own(whole_gap)
        for g in shapely.get_parts(mine) if mine is not None else []:
            if g.area < 1e-3:
                continue
            kept_open += _fill_gap(g, drawn, idx, tree, on, y, out)
    return out, kept_open


def _fill_gap(g, drawn, idx, tree, on, y, out):
    """One gap of _fill_slab filled into out, short of where the decks either
    side of it are apart: 1 if that kept it open in whole or in part, else 0."""
    rim = shapely.get_coordinates(shapely.segmentize(g.exterior, 0.25))
    # Every deck within a gap's width of each point of its rim: the
    # one it borders and the one across it.
    apart = []
    for q in rim:
        hs = [on(drawn[idx[ti]], q[None])[0] for ti in tree.query(shapely.points(q), predicate="dwithin", distance=GAP_FILL + 0.05)]
        hs = [x for x in hs if np.isfinite(x)]
        if hs and max(hs) - min(hs) >= STEP_MAX:
            apart.append(q)
    if apart:
        g = _area(shapely.difference(g, shapely.buffer(shapely.multipoints(apart), GAP_FILL, quad_segs=4), grid_size=GRID))
    for patch in shapely.get_parts(g):
        if patch.area < 1e-3:
            continue
        c = np.array(patch.centroid.coords[0])
        out.append((c, _top(patch, y), patch, y))
    return 1 if apart else 0


def _slab(drawn, lo, hi):
    """The parts of the triangles drawn between heights lo and hi, seen from
    above: which triangle each is of, and its polygon."""
    ymin, ymax = drawn[:, :, 1].min(axis=1), drawn[:, :, 1].max(axis=1)
    inside = np.flatnonzero((ymin >= lo) & (ymax <= hi))
    idx, polys = list(inside), list(shapely.polygons(drawn[inside][:, :, [0, 2]]))
    for ti in np.flatnonzero((ymax > lo) & (ymin < hi) & ~((ymin >= lo) & (ymax <= hi))):
        pts = list(drawn[ti])
        for side in (lambda p: p[1] - lo, lambda p: hi - p[1]):
            cut = []
            for a, b in zip(pts[-1:] + pts[:-1], pts):
                fa, fb = side(a), side(b)
                if (fa >= 0) != (fb >= 0):
                    cut.append(a + (b - a) * (fa / (fa - fb)))
                if fb >= 0:
                    cut.append(b)
            pts = cut
        if len(pts) >= 3:
            poly = shapely.polygons(np.array(pts)[:, [0, 2]])
            if poly.area > 1e-6:
                idx.append(ti)
                polys.append(poly)
    return np.array(idx, dtype=int), np.array(polys, dtype=object)


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


def _beside(wi, a, b, ya, yb, foot, ext, lanes, info, tree):
    """What a deck segment a-b gives up to the roads beside it: where one
    overlaps its footprint side by side, the part of that road's footprint
    nearer its centre line than this one's, wherever the two stand less
    than CLEAR_SPLIT apart in height; the lines dividing them, as point
    pairs, where they stand STEP_MAX apart somewhere; and whether it passes
    CLEAR_SPLIT over a road beside it, and so stands on piers there. None and
    no lines when no road takes any of it. How much a road beside it
    overlaps is judged over ext, the segment drawn SLIVER on past its ends."""
    da = (b - a) / max(float(np.hypot(*(b - a))), 1e-9)
    cuts, dividers, aloft = [], [], False
    near, total = [], {}
    for j in tree.query(foot, predicate="intersects"):
        wj, c, d, yc, yd, _ = info[j]
        if wj == wi:
            continue
        db = (d - c) / max(float(np.hypot(*(d - c))), 1e-9)
        if abs(float(da @ db)) < SPLIT_COS or shapely.crosses(LineString([a, b]), LineString([c, d])):
            continue  # crossing, which the heights already clear
        over = _and(foot, lanes[j])
        if over.area < 1e-3:
            continue
        near.append((j, over))
        total[wj] = total.get(wj, 0.0) + _and(ext, lanes[j]).area
    for j, over in near:
        wj, c, d, yc, yd, _ = info[j]
        # A road beside this one counts by all it overlaps here, never piece
        # by piece: a piece of it whose joint falls by this one's can
        # overlap only a corner, which left standing is a tooth. And over
        # ext, not the footprint alone: a short segment between longer ones
        # overlaps a road beside them all as little as its length, and
        # left whole it stands out past their cut, a tooth in the rail.
        if total[wj] < 1.0:
            continue
        db = (d - c) / max(float(np.hypot(*(d - c))), 1e-9)
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
                # Where this one rises CLEAR_SPLIT above the other it passes
                # over it, on a structure whatever OSM says; where it is
                # CLEAR_SPLIT below, under it. Neither gives anything up there; nearer
                # than that each keeps its own side of the line between
                # them, which is a divider once they are STEP_MAX apart.
                if _and(_and(over, where), _half(g, r0 - CLEAR_SPLIT, at, big)).area >= 1.0:
                    aloft = True
                mine = _and(nearer, _and(where, _and(_half(-g, CLEAR_SPLIT - r0, at, big), _half(g, r0 + CLEAR_SPLIT, at, big))))
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
            q = _despike(np.asarray(r.coords)[:-1])
            if len(q) < 3:
                continue
            q = np.concatenate([q, q[:1]])
            for s0, s1 in zip(q[:-1], q[1:]):
                if np.hypot(*(s1 - s0)) < 1e-6 or sides is not None and not any(_on(s0, *e) and _on(s1, *e) for e in sides):
                    continue
                y0, y1 = (float(y(s)) for s in (s0, s1))
                # Outlines run counter-clockwise in (x, z), so outside is
                # to the right.
                out.append((s0, s1, y0, y1, np.array([s1[1] - s0[1], -(s1[0] - s0[0])])))
    return out


def _despike(q):
    """Ring q (unclosed) without the parts of it with no width: a corner
    its outline doubles straight back from, within GRID of the way it came,
    as cutting decks on a grid leaves, encloses no deck, and a rail laid on
    both its sides would stand as a box in the open."""
    q = list(q)
    k = 0
    while len(q) >= 3 and k < len(q):
        a, b, c = q[k - 1], q[k], q[(k + 1) % len(q)]
        ab, bc = b - a, c - b
        lab, lbc = float(np.hypot(*ab)), float(np.hypot(*bc))
        if lab < 1e-6 or lbc < 1e-6:
            del q[k]
            k = max(0, k - 1)
            continue
        off = abs(float(ab[0] * bc[1] - ab[1] * bc[0])) / max(lab, lbc)
        if float(ab @ bc) < 0 and off <= GRID:
            del q[k]
            k = max(0, k - 1)
            continue
        k += 1
    return np.array(q)


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


def _disc(c, off):
    """The disc where a way ends at c, its sides at c + off and c - off: a
    DISC_SIDES-gon with a corner on each side, so its outline leaves the
    road's sides exactly where they end, never a chord short of them."""
    r = float(np.hypot(*off))
    a = math.atan2(float(off[1]), float(off[0])) + np.arange(DISC_SIDES) * (2 * math.pi / DISC_SIDES)
    return Polygon(np.asarray(c, float) + r * np.stack([np.cos(a), np.sin(a)], axis=1))


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
    """Rails along the outline of every deck, as (where, part). Of each edge
    (s0, s1, y0, y1, outward) a rail keeps what stands high enough and
    open: where the ground RAIL_PROBE past it is no deck carrying on from
    it, one less than STEP_MAX below or up to RAIL_JOIN above, a wall
    faced, not a fall. What is kept is chained end to end into lines
    wherever pieces meet, so a rail runs round a bend or on into the next
    segment as one mitred piece, capped at its ends.

    deck is every road-surface triangle as drawn: the test is asked of the
    surface itself, never of the footprint a segment or disc started from,
    since cutting one road where another runs beside it leaves holes that
    footprint still covers, and a rail left out there leaves an open V.
    Each edge is clipped against each triangle exactly, so a rail stops
    where the deck beside it starts, and only what is kept is ever
    chained: no link between pieces stands where the rail was dropped."""
    e = []
    for s0, s1, y0, y1, side in edges:
        s0, s1 = np.asarray(s0, float), np.asarray(s1, float)
        d = s1 - s0
        if float(np.hypot(*d)) < 1e-6:
            continue
        if float(side[0] * d[1] - side[1] * d[0]) < 0:  # outside on the left
            s0, s1, y0, y1 = s1, s0, y1, y0
        e.append((s0[0], s0[1], s1[0], s1[1], float(y0), float(y1)))
    if not e:
        return []
    e = np.array(e)
    a, d, ya, rise = e[:, 0:2], e[:, 2:4] - e[:, 0:2], e[:, 4], e[:, 5] - e[:, 4]
    length = np.hypot(*d.T)
    tiny = 2 * GRID  # the most two decks cut from each other miss by

    # The stretch of each edge high enough for a rail, as t from 0 to 1.
    floor = RAIL_MIN + LIFT
    lo, hi = np.zeros(len(e)), np.ones(len(e))
    up, down = rise > 0, rise < 0
    t = (floor - ya) / np.where(up | down, rise, 1.0)
    lo[up] = np.maximum(0.0, t[up])
    hi[down] = np.minimum(1.0, t[down])
    hi[~up & ~down & (ya <= floor)] = 0.0
    sel = np.flatnonzero((hi - lo) * length > tiny)
    a, d, ya, rise, length, lo, hi = (x[sel] for x in (a, d, ya, rise, length, lo, hi))

    # Each edge's probe, RAIL_PROBE outside it, clipped to every triangle
    # it crosses: the stretch of it inside the triangle, t0 + t * b >= 0
    # for each side, where the triangle also stands within the band.
    v, h0, g = _plane(deck)
    tree = shapely.STRtree(shapely.polygons(v))
    p0 = a + np.stack([d[:, 1], -d[:, 0]], axis=1) / length[:, None] * RAIL_PROBE
    ei, ti = tree.query(shapely.linestrings(np.stack([p0, p0 + d], axis=1)), predicate="intersects")
    cross = lambda p, q: p[:, 0] * q[:, 1] - p[:, 1] * q[:, 0]
    P, D, V = p0[ei], d[ei], v[ti]
    c0, c1 = np.zeros(len(ei)), np.ones(len(ei))

    def within(t0, b):
        t = -t0 / np.where(b == 0, 1.0, b)
        c0[:] = np.where(b > 0, np.maximum(c0, t), c0)
        c1[:] = np.where(b < 0, np.minimum(c1, t), np.where((b == 0) & (t0 < 0), -1.0, c1))

    for k in range(3):
        side = V[:, (k + 1) % 3] - V[:, k]
        within(cross(side, P - V[:, k]), cross(side, D))
    rel0 = h0[ti] + ((P - V[:, 0]) * g[ti]).sum(axis=1) - ya[ei]
    rel1 = (D * g[ti]).sum(axis=1) - rise[ei]
    within(rel0 + STEP_MAX, rel1)
    within(RAIL_JOIN - rel0, -rel1)
    hit = c1 > c0
    ei, c0, c1 = ei[hit], c0[hit], c1[hit]
    order = np.lexsort((c0, ei))
    ei, c0, c1 = ei[order], c0[order], c1[order]
    bounds = np.searchsorted(ei, np.arange(len(sel) + 1))

    # What of each edge no deck carries on past.
    pieces = []
    for k in range(len(sel)):
        at, stretches = lo[k], []
        for t0, t1 in zip(c0[bounds[k]:bounds[k + 1]], c1[bounds[k]:bounds[k + 1]]):
            if t0 > at:
                stretches.append((at, min(t0, hi[k])))
            at = max(at, t1)
            if at >= hi[k]:
                break
        if at < hi[k]:
            stretches.append((at, hi[k]))
        for t0, t1 in stretches:
            if (t1 - t0) * length[k] > tiny:
                pieces.append((a[k] + d[k] * t0, a[k] + d[k] * t1, ya[k] + rise[k] * t0, ya[k] + rise[k] * t1))
    if not pieces:
        return []

    def carried(q, y):
        """Per point q, whether deck there carries on from height y."""
        out = np.zeros(len(q), bool)
        qi, qt = tree.query(shapely.points(q), predicate="intersects")
        rel = h0[qt] + ((q[qi] - v[qt, 0]) * g[qt]).sum(axis=1) - y[qi]
        out[qi[(-STEP_MAX < rel) & (rel < RAIL_JOIN)]] = True
        return out

    parts = []
    for pts, ys, outs, closed in _chain(pieces, carried):
        if float(np.hypot(*(pts[1:] - pts[:-1]).T).sum()) < RAIL_SPECK:
            continue
        pts, ys, outs = _smooth(pts, ys, closed)
        parts.append(((pts[0][0], pts[0][1]), _ribbon(pts, ys, outs, closed)))
    return parts


def _plane(t):
    """Per triangle of t (n, 3, 3): its corners in plan (n, 3, 2), turned
    counter-clockwise; the height at the first; and its plane's gradient in
    plan (n, 2)."""
    v = t[:, :, [0, 2]].copy()
    e1, e2 = v[:, 1] - v[:, 0], v[:, 2] - v[:, 0]
    det = e1[:, 0] * e2[:, 1] - e1[:, 1] * e2[:, 0]
    r1, r2 = t[:, 1, 1] - t[:, 0, 1], t[:, 2, 1] - t[:, 0, 1]
    with np.errstate(divide="ignore", invalid="ignore"):
        g = np.stack([(r1 * e2[:, 1] - r2 * e1[:, 1]) / det, (r2 * e1[:, 0] - r1 * e2[:, 0]) / det], axis=1)
    cw = det < 0
    v[cw] = v[cw][:, [0, 2, 1]]
    return v, t[:, 0, 1].copy(), np.nan_to_num(g)


def _chain(pieces, carried):
    """The pieces (s0, s1, y0, y1), outside on the right, joined end to end
    into lines, each (points, heights, outward per piece, closed). A
    piece's end joins the start of the one carrying on most nearly straight
    from it at the same height, each start taken once, nearest first: one
    within RAIL_WELD round any corner short of a hairpin; one within
    RAIL_GAP carrying on ahead within 60 degrees, so the edges of two ways
    meeting, which miss each other by the width of their mitres, still
    make one rail, but only where the link stands clear of deck, carried
    (points, heights) false RAIL_OPEN out past it, and so runs along the
    edge of the road, not across it. At a fork the rail follows the
    straighter way."""
    s0 = np.array([q[0] for q in pieces])
    s1 = np.array([q[1] for q in pieces])
    y0 = np.array([q[2] for q in pieces])
    y1 = np.array([q[3] for q in pieces])
    di = s1 - s0
    di /= np.hypot(*di.T)[:, None]
    n = len(pieces)

    starts = {}
    for j in range(n):
        starts.setdefault((int(s0[j][0] // RAIL_GAP), int(s0[j][1] // RAIL_GAP)), []).append(j)
    pairs, maybe = [], []
    for i in range(n):
        cx, cz = int(s1[i][0] // RAIL_GAP), int(s1[i][1] // RAIL_GAP)
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                for j in starts.get((cx + dx, cz + dz), ()):
                    if j == i or abs(y0[j] - y1[i]) >= 0.3:
                        continue
                    g = s0[j] - s1[i]
                    gap = float(np.hypot(*g))
                    turn = float(di[i] @ di[j])
                    if gap < RAIL_WELD:
                        if turn > -0.5:
                            pairs.append((round(gap / RAIL_WELD), -turn, i, j))
                    elif gap < RAIL_GAP and turn > 0.5 and float(g @ (di[i] + di[j])) > 0:
                        maybe.append((round(gap / RAIL_WELD), -turn, i, j))
    if maybe:
        q, y = [], []
        for _, _, i, j in maybe:
            m = di[i] + di[j]
            out = np.array([m[1], -m[0]]) / float(np.hypot(*m)) * RAIL_OPEN
            for f in (0.25, 0.5, 0.75):
                q.append(s1[i] + (s0[j] - s1[i]) * f + out)
                y.append(y1[i] + (y0[j] - y1[i]) * f)
        on = carried(np.array(q), np.array(y)).reshape(-1, 3).any(axis=1)
        pairs += [pair for pair, o in zip(maybe, on) if not o]
    pairs.sort()
    nxt, has_prev = [-1] * n, [False] * n
    for _, _, i, j in pairs:
        if nxt[i] == -1 and not has_prev[j]:
            nxt[i], has_prev[j] = j, True

    lines, used = [], [False] * n

    def link(a, b):
        g = (b - a) / float(np.hypot(*(b - a)))
        return np.array([g[1], -g[0]])

    def walk(i):
        order = []
        while i != -1 and not used[i]:
            used[i] = True
            order.append(i)
            i = nxt[i]
        pts, ys, outs = [s0[order[0]]], [y0[order[0]]], []
        for j in order:
            if np.hypot(*(s0[j] - pts[-1])) > 1e-6:  # bridge the gap
                outs.append(link(pts[-1], s0[j]))
                pts.append(s0[j])
                ys.append(y0[j])
            pts.append(s1[j])
            ys.append(y1[j])
            outs.append(np.array([di[j][1], -di[j][0]]))
        closed = nxt[order[-1]] == order[0]
        if closed and np.hypot(*(pts[0] - pts[-1])) > 1e-6:
            outs.append(link(pts[-1], pts[0]))
            pts.append(pts[0])
            ys.append(ys[0])
        return np.array(pts), np.array(ys), np.array(outs), closed

    for i in range(n):
        if not has_prev[i] and not used[i]:
            lines.append(walk(i))
    for i in range(n):
        if not used[i]:
            lines.append(walk(i))  # a closed loop
    return lines


def _smooth(p, y, closed):
    """Line p at heights y with no piece shorter than RAIL_THICK, and its
    outward per piece: a rail cannot follow a jog finer than it is thick,
    where two ways meet with their sides a little apart, without its inner
    face folding back over itself, so of the corners either side of each
    such piece the one standing least out of line goes, until none is left
    or the line is one piece."""
    p, y = [np.asarray(q, float) for q in p], list(y)
    if closed:
        p, y = p[:-1], y[:-1]

    def bend(i):
        a, b, c = p[i - 1], p[i], p[(i + 1) % len(p)]
        ac = c - a
        return abs(float(ac[0] * (b - a)[1] - ac[1] * (b - a)[0])) / max(float(np.hypot(*ac)), 1e-9)

    while len(p) > (3 if closed else 2):
        n = len(p)
        short = [i for i in range(n if closed else n - 1) if np.hypot(*(p[(i + 1) % n] - p[i])) < RAIL_THICK]
        ends = {(i + k) % n for i in short for k in (0, 1)}
        if not closed:
            ends -= {0, n - 1}
        if not ends:
            break
        k = min(ends, key=bend)
        del p[k], y[k]
    if closed:
        p, y = p + p[:1], y + y[:1]
    p, y = np.array(p), np.array(y)
    d = p[1:] - p[:-1]
    d /= np.maximum(np.hypot(*d.T), 1e-9)[:, None]
    return p, y, np.stack([d[:, 1], -d[:, 0]], axis=1)


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


def _along(cum, high, step):
    """Distances along a polyline, its nodes at cum, every step along each
    run of its high segments, the first step / 2 into the run."""
    out = []
    for r0, r1 in _runs(high):
        out += list(np.arange(cum[r0] + step / 2, cum[r1 + 1], step))
    return out


def _spot(p, h, cum, high, s):
    """(centre, direction, height) at distance s along a polyline, its
    nodes at cum, or None off its high segments."""
    i = int(np.searchsorted(cum, s, side="right")) - 1
    if i < 0 or i >= len(p) - 1 or not high[i]:
        return None
    d = p[i + 1] - p[i]
    length = cum[i + 1] - cum[i]
    u = (s - cum[i]) / length
    return p[i] + d * u, d / length, h[i] + (h[i + 1] - h[i]) * u


def _blocked(pier, c, top, wi, ground_tree, info, tree):
    """Whether a pier of way wi's deck, its footprint centred at c, standing
    up to top, would stand in a road or railway on the ground or come down
    through another road's deck lower than its top, or PIER_CLEAR from
    either."""
    if len(ground_tree.query(pier, predicate="intersects")):
        return True
    for j in tree.query(shapely.buffer(pier, PIER_CLEAR), predicate="intersects"):
        o, a, b, ya, yb, _ = info[j]
        if o == wi:
            continue
        ab = b - a
        t = min(1.0, max(0.0, float(np.dot(c - a, ab)) / max(float(np.dot(ab, ab)), 1e-9)))
        if ya + (yb - ya) * t < top:
            return True
    return False


if __name__ == "__main__":
    main()

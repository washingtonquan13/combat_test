"""Elevated decks drawn from decks.json: one swept ribbon per run of decks.

    python -I tools/blockout/decks_mesh.py <raw dir> <out dir>

Reads <out dir>/decks.json (decks_seed.py, then hand edits) for the decks
and their heights, <raw dir>/features.json for the roads and railways on
the ground that piers keep off, and <out dir>/city.json for the tile grid
and boundary. Writes tiles/d_X_Z.bin in the same format as the other tile
files and adds "decks" to city.json's tiles. Nothing here decides a
height: every height is the record's, and a wrong one is fixed in
decks.json, not here.

  - Ways that continue one another (a record's "continues") are one chain,
    drawn as one ribbon; where two meet, their shared node takes the mean
    of their heights.
  - The centre line is a Catmull-Rom spline through the chain's nodes,
    chordal (knots spaced by the distance between nodes, so dense OSM
    nodes do not kink it), heights carried by the same spline. It is
    sampled at every node and at most STEP apart between them.
  - The profile at each sample: the deck top width/2 either side of the
    centre, a rail RAIL_HEIGHT tall and RAIL_THICK deep on each edge, the
    side down THICK (to the ground for a way that is not a bridge, an
    embankment) and the underside. Width changes between ways taper over
    TAPER, and the inside of a bend is held to BEND of its radius so the
    edge never folds back on itself.
  - Twins (a record's "twin_of") are one profile of their combined width:
    where a twin runs alongside, the deck runs on to the line midway
    between the two centre lines and meets the twin's there, with no rail
    and no side between, always at the mean of the two heights: the
    surface slopes across from one carriageway's height to the other's
    (crossfall), never a step. twin_of says the two are one road;
    decks_seed.py keeps only pairs LiDAR measures within TWIN_STEP.
  - Rails stand only on an edge with no other deck beside it, and only
    along a run of edge that somewhere stands RAIL_DROP above the ground: an edge
    with a deck at COVER outward, STEP_MAX below to RAIL_JOIN above it,
    is a deck going on, not a drop. Where an edge goes under or comes out
    of another deck, the rail ends at the point found by bisection to
    RAIL_TO.
  - A deck is drawn where it stands above MIN_HEIGHT, or is a bridge, and
    inside the map boundary plus RUNOUT. Where it comes down to the
    ground, or is cut at the map's edge, or simply ends, its last profile
    is at the ground: a ramp toe, never a mid-air end. Where it ends on
    another deck (a merge or split), it stops at the last profile that
    lies wholly on the other deck.
  - Piers stand every PIER_STEP along a bridge where its underside is
    above PIER_MIN, slid along the deck up to PIER_SLIDE clear of the
    roads and railways below.

Heights here are real metres; build_osm_city.gd scales them by --vscale
like everything else. Kinds: deck 0, deck side 1, pier 2, rail 3.

Map data (c) OpenStreetMap contributors, ODbL.
"""

import json
import math
import os
import sys

import numpy as np
import shapely
from shapely.geometry import Polygon

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bridges  # noqa: E402
from bridges import MIN_HEIGHT, RUNOUT, STEP_MAX  # noqa: E402
from osm_city import MEDIAN, _bytes, _empty, _facing, _walls, _write  # noqa: E402

DECK, SIDE, PIER, RAIL = range(4)
# Samples along the centre line at most this far apart.
STEP = 5.0
# A deck's top stands this far above its height, clear of the ground road.
LIFT = 0.15
# A structure's depth below its deck top.
THICK = 1.5
RAIL_HEIGHT = 2.0
RAIL_THICK = 0.4
# An edge is carried by another deck found this far outward, from STEP_MAX
# below the edge to RAIL_JOIN above it.
COVER = (0.05, 0.3, 0.4, 0.8)
RAIL_JOIN = 2.0
# A rail run whose edge nowhere stands this far above the ground is not
# drawn: a deck that low (a bridge a hand's height over a canal, a ramp's
# toe) is a kerb's step off, and a 2 m wall along it walls the street in.
RAIL_DROP = 1.0
# Where a rail starts or ends inside a segment, found to within this.
RAIL_TO = 0.15
# Each edge segment is probed for a deck beside it this far apart.
PROBE = 0.25
# A free end comes down to the ground over this run, or longer where its
# height would make that steeper than TOE_GRADE.
TOE_RUN = 5.0
TOE_GRADE = 0.4
# The toe's run is lengthened in steps of this until it keeps TOE_GRADE.
TOE_STEP = 0.5
# A sample's direction is the chord this far either side of it.
TANGENT = 2.5
# Width changes between continuing ways spread over this distance.
TAPER = 20.0
# The inside edge of a bend stays within this fraction of its radius.
BEND = 0.9
BEND_SPAN = 10.0
# Two twins' centre lines are side by side when their offset is this
# close to square to the deck and they run this close to parallel.
TWIN_SQUARE = 0.95
TWIN_PARALLEL = 0.9
# Two decks that are not twins meet at a seam when their edges come this
# close: a crack an avatar could not cross is no place for two rails.
NEAR_GAP = 2.0
# Two decks do not meet across a third whose centre line passes within this
# of the line between their centres, at a height within RAIL_JOIN of theirs:
# a ramp leaving between a twin pair takes the twins' seam apart there.
BETWEEN = 1.0
# Seamed edges this close in height meet at their mean, no step drawn. A
# step any lower would need a rail (it drops more than STEP_MAX) standing
# within reach of the deck in front of it, a rail in the road.
WELD = 0.5
# Where a twin seam drawn as crossfall comes to a stretch that is a step
# (a toe, or a deck that is not its twin), the two edges part gradually:
# each leans from the mean back to its own height over the run in which
# the step between them grows at FADE_GRADE, at least FADE_MIN, so no
# edge leaves the mean by more than a kerb at once.
FADE_GRADE = 0.1
FADE_MIN = 5.0
# Where the two decks of a seam hover about WELD apart, a step is drawn only
# where they part by more than WELD + WELD_HYST somewhere along it, and a
# weld between two steps only where they come within WELD - WELD_HYST.
WELD_HYST = 0.15
# Seam samples of the two decks of a pair closer than this along are one
# point of their shared seam.
KNOT_SNAP = 0.5
# Seam points of a pair further apart than this along are separate seams.
KNOT_GAP = 2 * STEP + 1.0
# An edge with no deck beside it within STEP_MAX, but one less than MEET
# below, comes down onto that deck: a drop that small is too high to leave
# open and too low for a rail, which would stand in the road below it.
# MEET is past the 0.5 m a rail needs clear in front of it by the length of
# a rail face's slope along a 5 m segment.
MEET = 0.7
# Where an edge brought down onto a deck goes on to a drop, it climbs back
# to its own height over this distance: a step, not a stretch of edge too
# high to leave open and too low for a rail.
CUT = 0.4
PIER_MIN = 5.0
PIER_STEP = 40.0
PIER_DEPTH = 2.5
# Piers keep this far from a road or railway on the ground or below.
PIER_CLEAR = 2.0
# Distances along the deck a pier may slide to find a clear spot.
PIER_SLIDE = (5.0, 10.0, 15.0)


def main():
    raw, out = sys.argv[1], sys.argv[2]
    if os.path.basename(os.path.normpath(out)) == "new_orleans":
        sys.exit("decks_mesh: refusing to write into data/blockouts/new_orleans")
    meta_path = os.path.join(out, "city.json")
    meta = json.load(open(meta_path, encoding="utf-8"))
    decks = json.load(open(os.path.join(out, "decks.json"), encoding="utf-8"))["decks"]
    ways, others, _ = bridges.read(raw, meta)
    draw(meta, meta_path, out, decks, ways, others)


# ---------------------------------------------------------------- chains

def _records(decks):
    """Each record's centre line (n, 2), heights (n,), and its fields, with
    nodes closer than 5 cm to the one before dropped."""
    recs = []
    for d in decks:
        p = np.array([(n["x"], n["z"]) for n in d["nodes"]], float)
        h = np.array([n["h"] for n in d["nodes"]], float)
        keep = np.concatenate([[True], np.hypot(*(p[1:] - p[:-1]).T) > 0.05])
        p, h = p[keep], h[keep]
        if len(p) < 2:
            continue
        length = d["nodes"][-1]["s"]
        ends = set()
        for rel in d.get("merges", []) + d.get("splits", []):
            ends.add(0 if rel["at_s"] < length / 2 else 1)
        recs.append({"way": d["way"], "p": p, "h": h, "width": float(d["width"]), "bridge": bool(d["bridge"]),
                     "twins": list(d.get("twin_of") or []), "continues": [c["way"] for c in d.get("continues", [])],
                     "joined": ends})
    return recs


def _chains(recs):
    """Records joined end to end where they continue one another: lists of
    (record index, reversed), each chain's records in order."""
    by_way = {}
    for i, r in enumerate(recs):
        by_way.setdefault(r["way"], []).append(i)
    link = {}
    for i, r in enumerate(recs):
        for e in (0, 1):
            q = r["p"][-1 if e else 0]
            best = None
            for way in r["continues"]:
                for j in by_way.get(way, []):
                    if j == i:
                        continue
                    for f in (0, 1):
                        dist = float(np.hypot(*(recs[j]["p"][-1 if f else 0] - q)))
                        if dist < 1.0 and (best is None or dist < best[0]):
                            best = (dist, j, f)
            if best is not None:
                link[(i, e)] = (best[1], best[2])
    # Only links both ends agree on.
    link = {k: v for k, v in link.items() if link.get(v) == k}
    seen, chains = set(), []

    def walk(i, enter):
        chain = []
        while i not in seen:
            seen.add(i)
            chain.append((i, enter == 1))
            nxt = link.get((i, 1 - enter))
            if nxt is None:
                break
            i, enter = nxt
        return chain

    for i in range(len(recs)):
        for e in (0, 1):
            if i not in seen and (i, e) not in link:
                chains.append(walk(i, e))
    for i in range(len(recs)):
        if i not in seen:
            chains.append(walk(i, 0))
    return chains, link


def _catmull_rom(p, h):
    """Samples along the chordal Catmull-Rom spline through points p (n, 2)
    with heights h: every node, and between nodes at most STEP apart.
    Returns the sample points, heights, and for each sample the node
    segment it lies on."""
    q = np.column_stack([p, h])
    n = len(q)
    ext = np.concatenate([[2 * q[0] - q[1]], q, [2 * q[-1] - q[-2]]])
    gap = np.maximum(np.hypot(*(ext[1:, :2] - ext[:-1, :2]).T), 1e-3)
    knots = np.concatenate([[0.0], np.cumsum(gap)])
    pts, seg = [], []
    for i in range(n - 1):
        t0, t1, t2, t3 = knots[i:i + 4]
        p0, p1, p2, p3 = ext[i:i + 4]
        m = max(1, int(math.ceil(gap[i + 1] / STEP)))
        t = t1 + (t2 - t1) * np.arange(m) / m
        t = t[:, None]
        a1 = ((t1 - t) * p0 + (t - t0) * p1) / (t1 - t0)
        a2 = ((t2 - t) * p1 + (t - t1) * p2) / (t2 - t1)
        a3 = ((t3 - t) * p2 + (t - t2) * p3) / (t3 - t2)
        b1 = ((t2 - t) * a1 + (t - t0) * a2) / (t2 - t0)
        b2 = ((t3 - t) * a2 + (t - t1) * a3) / (t3 - t1)
        c = ((t2 - t) * b1 + (t - t1) * b2) / (t2 - t1)
        c[0] = q[i]
        pts.append(c)
        seg += [i] * m
    pts.append(q[-1:])
    seg.append(n - 2)
    pts = np.concatenate(pts)
    return pts[:, :2], np.maximum(pts[:, 2], 0.0), np.array(seg)


def _chain_samples(recs, chain):
    """One chain's centre line sampled: points, heights, and per sample the
    record it belongs to (the record of the segment after it, the last
    sample that of the one before)."""
    P, H, R = [], [], []
    for i, rev in chain:
        p, h = recs[i]["p"], recs[i]["h"]
        if rev:
            p, h = p[::-1], h[::-1]
        if P:
            # The node the two share takes the mean of their heights.
            H[-1] = (H[-1] + h[0]) / 2
            p, h = p[1:], h[1:]
            R[-1] = i
        P += list(p)
        H += list(h)
        R += [i] * len(p)
    P, H, R = np.array(P), np.array(H), np.array(R)
    keep = np.concatenate([[True], np.hypot(*(P[1:] - P[:-1]).T) > 0.05])
    P, H, R = P[keep], H[keep], R[keep]
    if len(P) < 2:
        return None
    c, h, seg = _catmull_rom(P, H)
    rec = R[seg]
    rec[-1] = R[-2]
    return c, h, rec


def _pair_heights(recs, chain_samples):
    """Per chain sample, the highest height of a twin beside it (a record
    in its twin_of whose chain runs alongside within the two half widths
    and the median, near parallel), or 0 where none is."""
    lines, owner = [], []
    for ci, smp in enumerate(chain_samples):
        if smp is not None:
            lines.append(shapely.linestrings(smp[0]))
            owner.append(ci)
    tree = shapely.STRtree(lines)
    widest = max(r["width"] for r in recs)
    out = []
    for ci, smp in enumerate(chain_samples):
        if smp is None:
            out.append(None)
            continue
        c, h, rec = smp
        ph = np.zeros(len(c))
        twin_ways = [set(recs[r]["twins"]) for r in rec]
        if not any(twin_ways):
            out.append(ph)
            continue
        d = _tangents(c, np.concatenate([[0.0], np.cumsum(np.hypot(*(c[1:] - c[:-1]).T))]))
        w = np.array([recs[r]["width"] for r in rec])
        pts = shapely.points(c)
        for lj in tree.query(shapely.buffer(shapely.linestrings(c), widest + 2 * MEDIAN)):
            cj = owner[lj]
            if cj == ci:
                continue
            oc, oh, orec = chain_samples[cj]
            cum = np.concatenate([[0.0], np.cumsum(np.hypot(*(oc[1:] - oc[:-1]).T))])
            t = shapely.line_locate_point(lines[lj], pts)
            k = np.clip(np.searchsorted(cum, t, side="right") - 1, 0, len(cum) - 2)
            u = np.clip((t - cum[k]) / np.maximum(cum[k + 1] - cum[k], 1e-9), 0, 1)
            q = oc[k] + (oc[k + 1] - oc[k]) * u[:, None]
            qh = oh[k] + (oh[k + 1] - oh[k]) * u
            qd = oc[k + 1] - oc[k]
            qd /= np.maximum(np.hypot(*qd.T), 1e-9)[:, None]
            qway = [recs[r]["way"] for r in orec[k]]
            qw = np.array([recs[r]["width"] for r in orec[k]])
            twin = np.array([qway[i] in twin_ways[i] for i in range(len(c))])
            sep = np.hypot(*(q - c).T)
            ok = twin & (sep <= (w + qw) / 2 + 2 * MEDIAN) & (np.abs((d * qd).sum(axis=1)) > TWIN_PARALLEL)
            ok &= (t > 1e-6) & (t < cum[-1] - 1e-6)
            ph = np.where(ok, np.maximum(ph, qh), ph)
        out.append(ph)
    return out


def _tangents(c, s):
    """Unit directions along the centre line c (samples at distances s),
    each the chord from TANGENT behind to TANGENT ahead, so a node a hand's
    breadth off the line beside it does not swing the deck's edges."""
    lo = _at(c, s, np.maximum(s - TANGENT, s[0]))
    hi = _at(c, s, np.minimum(s + TANGENT, s[-1]))
    d = hi - lo
    return d / np.maximum(np.hypot(*d.T), 1e-9)[:, None]


def _at(c, s, x):
    """Points at distances x along the polyline c, its samples at s."""
    i = np.clip(np.searchsorted(s, x, side="right") - 1, 0, len(s) - 2)
    u = np.clip((x - s[i]) / np.maximum(s[i + 1] - s[i], 1e-9), 0.0, 1.0)
    return c[i] + (c[i + 1] - c[i]) * u[:, None]


def _taper(s, w):
    """Widths w per segment (between samples at s) as each sample's width,
    averaged over TAPER around it."""
    seg = np.diff(s)
    area = np.concatenate([[0.0], np.cumsum(seg * w)])

    def integral(x):
        x = np.clip(x, s[0], s[-1])
        i = np.clip(np.searchsorted(s, x, side="right") - 1, 0, len(seg) - 1)
        return area[i] + (x - s[i]) * w[i]

    lo, hi = np.clip(s - TAPER / 2, s[0], s[-1]), np.clip(s + TAPER / 2, s[0], s[-1])
    return np.where(hi - lo > 1e-6, (integral(hi) - integral(lo)) / np.maximum(hi - lo, 1e-6), w[np.minimum(np.arange(len(s)), len(seg) - 1)])


# ---------------------------------------------------------------- geometry

def _tris(quads, normal):
    """Quads (n, 4, 3) as triangles facing normal (n, 3)."""
    t = np.concatenate([quads[:, [0, 1, 2]], quads[:, [0, 2, 3]]]).astype(np.float32)
    nrm = np.concatenate([normal, normal]).astype(np.float64)
    area = np.linalg.norm(np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]), axis=1)
    keep = area > 1e-6
    return _facing(t[keep], nrm[keep])


def _xyz(xz, y):
    return np.stack([xz[..., 0], y, xz[..., 1]], axis=-1)


class Piece:
    """A run of one chain's samples drawn as one deck."""

    # Every per-sample array, and every per-side per-sample array: anything
    # that inserts or drops samples goes through these lists, so no array
    # is left a different length from the rest.
    SAMPLE = ("c", "h", "rec", "d", "w", "n", "toe")
    SIDE = ("edge", "ey", "seam", "weld", "mid", "twin_h", "fade", "partner")

    def __init__(self, chain_id, c, h, rec, d, w, struct, free):
        self.chain = chain_id
        self.c, self.h, self.rec, self.d, self.w = c, h, rec, d, w
        self.struct = struct  # per segment: a bridge, so a structure, not an embankment
        self.free = free  # per end: a free end (dropped to ground), not one on another deck
        self.n = (np.stack([-d[:, 1], d[:, 0]], axis=1))
        self.edge = [None, None]  # left, right: edge points (m, 2)
        self.ey = [None, None]  # edge heights
        self.seam = [np.zeros(len(c), bool), np.zeros(len(c), bool)]
        self.weld = [np.zeros(len(c), bool), np.zeros(len(c), bool)]
        self.mid = [np.zeros((len(c), 2)), np.zeros((len(c), 2))]  # the midline point towards a twin
        self.twin_h = [h.copy(), h.copy()]  # the mean of the two heights there
        self.fade = [np.zeros(len(c)), np.zeros(len(c))]  # an unwelded twin edge's lean towards the mean, 0..1
        self.toe = np.zeros(len(c), bool)  # brought down towards a free end by _toes, not measured
        self.partner = [np.full(len(c), -1), np.full(len(c), -1)]  # the piece a seam sample meets

    @property
    def y(self):
        return self.h + LIFT


def draw(meta, meta_path, out, decks, ways, others):
    recs, pieces, tree = build(meta, decks)

    corner, tile = meta["corner"], meta["tile"]
    nx, nz = int(round(meta["extent"][0] / tile)), int(round(meta["extent"][1] / tile))
    buckets = {}

    def put(x, z, part):
        key = (min(nx - 1, max(0, int((x - corner[0]) // tile))), min(nz - 1, max(0, int((z - corner[1]) // tile))))
        buckets.setdefault(key, []).append(part)

    def put_each(tris, kind):
        if not len(tris):
            return
        cen = tris.mean(axis=1)
        tx = np.clip(((cen[:, 0] - corner[0]) // tile).astype(int), 0, nx - 1)
        tz = np.clip(((cen[:, 2] - corner[1]) // tile).astype(int), 0, nz - 1)
        for key in set(zip(tx.tolist(), tz.tolist())):
            m = (tx == key[0]) & (tz == key[1])
            buckets.setdefault(key, []).append((tris[m], _bytes(int(m.sum()), kind), _bytes(int(m.sum()), 0)))

    runs = 0
    for pc in pieces:
        for kind, tris in _profile(pc):
            put_each(tris, kind)
        for side in (0, 1):
            rails = _rail_runs(pc, side, tree)
            runs += len(rails)
            for pts, ys, inward in rails:
                put_each(_rail(pts, ys, inward, side), RAIL)
    print("decks_mesh: %d rail runs" % runs, flush=True)

    piers, moved, blocked = _piers(pieces, recs, ways, others, put)
    print("decks_mesh: %d piers (%d moved along their deck clear of a road), %d spots with no clear place for one" % (piers, moved, blocked), flush=True)

    total = 0
    tiles = {(t["x"], t["z"]): t for t in meta["tiles"]}
    for t in meta["tiles"]:
        t.pop("decks", None)
    # Deck tiles of an earlier run that this one leaves empty go too.
    for name in os.listdir(os.path.join(out, "tiles")):
        if name.startswith("d_") and name.endswith(".bin"):
            os.remove(os.path.join(out, "tiles", name))
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
    print("decks_mesh: %d triangles in %d tiles" % (total, len(buckets)), flush=True)


def build(meta, decks):
    """The decks as pieces, their edges found and ends trimmed, and the
    tree of their tops."""
    region = shapely.buffer(bridges._region(meta["boundary"]), RUNOUT)
    shapely.prepare(region)
    recs = _records(decks)
    chains, link = _chains(recs)

    # Each chain sampled, and cut into pieces where it is drawn.
    pieces = []
    chain_samples = [_chain_samples(recs, chain) for chain in chains]
    pair_h = _pair_heights(recs, chain_samples)
    for ci, chain in enumerate(chains):
        smp = chain_samples[ci]
        if smp is None:
            continue
        c, h, rec = smp
        first, last = chain[0], chain[-1]
        # A chain end is on another deck where its record merges or splits there.
        end0 = (1 if first[1] else 0) in recs[first[0]]["joined"]
        end1 = (0 if last[1] else 1) in recs[last[0]]["joined"]
        bridge = np.array([recs[r]["bridge"] for r in rec[:-1]])
        mid = (c[:-1] + c[1:]) / 2
        # A twin is drawn wherever its pair is: the two are one surface,
        # and one carriageway dipping to the ground beside the other is a
        # crossfall, not a ramp toe.
        hp = np.maximum(h, pair_h[ci])
        high = ((np.maximum(hp[:-1], hp[1:]) > MIN_HEIGHT) | bridge) & shapely.contains_xy(region, mid[:, 0], mid[:, 1])
        s = np.concatenate([[0.0], np.cumsum(np.hypot(*(c[1:] - c[:-1]).T))])
        d = _tangents(c, s)
        w = _taper(s, np.array([recs[r]["width"] for r in rec[:-1]]))
        for r0, r1 in _runs(high):
            a, b = r0, r1 + 1
            free = (not (a == 0 and end0), not (b == len(c) - 1 and end1))
            hh = _toes(s[a:b + 1] - s[a], h[a:b + 1], free)
            pieces.append(Piece(ci, c[a:b + 1], hh, rec[a:b + 1], d[a:b + 1], w[a:b + 1], bridge[a:b], free))
            pieces[-1].toe = hh < h[a:b + 1] - 1e-6
    print("decks_mesh: %d records in %d chains, %d pieces, %d samples" % (
        len(recs), len(chains), len(pieces), sum(len(pc.c) for pc in pieces)), flush=True)

    info = _twin_seams(recs, pieces)
    _pair_seams(pieces, info)
    for pc in pieces:
        _edges(pc)
    tree = _Tops(pieces)
    trimmed = 0
    for _ in range(2):
        for pc in pieces:
            trimmed += _trim(pc, tree)
        tree = _Tops(pieces)
    print("decks_mesh: %d deck ends trimmed back onto the deck they join" % trimmed, flush=True)
    for npass in range(2):
        met = cut = 0
        for pc in pieces:
            m, c_ = _meet(pc, tree)
            met += m
            cut += c_
        tree = _Tops(pieces)
        print("decks_mesh: pass %d: %d edge samples brought down onto a deck less than %.1f m below, %d steps cut sharp" % (npass + 1, met, MEET, cut), flush=True)
    return recs, pieces, tree


def _meet(pc, tree):
    """Each edge sample with no deck beside it from STEP_MAX below to
    RAIL_JOIN above, but one less than MEET below, comes down onto that
    deck. Where the edge goes on to a drop, the step is made at once: the
    segment is cut where the deck below falls away past MEET (by bisection,
    to RAIL_TO) and the cut doubled, one copy down on the deck, one at the
    edge's own height, so no stretch of edge passes through heights a rail
    cannot serve. Returns (samples moved, cuts made)."""

    def probe(pts, ys, outward):
        carried = np.zeros(len(pts), bool)
        drop = np.full(len(pts), -np.inf)
        for t in COVER:
            pi, rel = tree.rels(pc, pts + outward * t, ys)
            carried[pi[(rel > -STEP_MAX) & (rel < RAIL_JOIN)]] = True
            band = (rel > -MEET) & (rel <= -STEP_MAX)
            np.maximum.at(drop, pi[band], rel[band])
        return ~carried & np.isfinite(drop), drop, carried

    moved = cuts = 0
    for side in (0, 1):
        # A deck less than MEET below can lie beside the edge between two
        # samples that do not see it (one carried, one over a drop, the deck
        # climbing past it; or both carried, by decks that stop short of the
        # middle): each such stretch gets a sample at each end.
        e, ey = pc.edge[side], pc.ey[side]
        out, so = _outward(pc, side), _seg_out(pc, side)
        need, _, carried = probe(e, ey, out)
        state = np.where(carried, 0, np.where(need, 1, 2))
        found = []
        for k in np.flatnonzero((state[:-1] != state[1:]) | ((state[:-1] == 0) & (state[1:] == 0))):
            n_ = int(math.ceil(float(np.hypot(*(e[k + 1] - e[k]))) / RAIL_TO))
            if n_ < 2:
                continue
            f = (np.arange(n_) + 0.5) / n_
            pts = e[k] + (e[k + 1] - e[k]) * f[:, None]
            ys = ey[k] + (ey[k + 1] - ey[k]) * f
            nd = probe(pts, ys, np.repeat(so[k][None], n_, axis=0))[0]
            if not nd.any():
                continue
            ends = np.flatnonzero(np.diff(np.concatenate([[0], nd.astype(int), [0]])))
            at = sorted({int(i) for i in ends[0::2]} | {int(i) - 1 for i in ends[1::2]})
            found.append((k, f[at].tolist(), ys[at].tolist()))
        for k, fracs, ys in sorted(found, key=lambda t: -t[0]):
            _cut(pc, k, fracs, side, ys)
        e, ey = pc.edge[side], pc.ey[side]
        out, so = _outward(pc, side), _seg_out(pc, side)
        need, drop, carried = probe(e, ey, out)
        for end in (0, 1):
            if pc.free[end]:
                need[0 if end == 0 else -1] = False
        if not need.any():
            continue
        # Cuts: (segment, fraction, depth there, whether the low copy comes first).
        inserts = []
        for k in np.flatnonzero(need[:-1] != need[1:]):
            m, o = (k, k + 1) if need[k] else (k + 1, k)
            if carried[o]:
                continue
            lo, hi = 0.0, 1.0  # fraction from m towards o
            length = float(np.hypot(*(e[o] - e[m])))
            dep = drop[m]
            for _ in range(int(math.ceil(math.log2(max(1.0, length / RAIL_TO))))):
                t = (lo + hi) / 2
                pt = e[m] + (e[o] - e[m]) * t
                yt = ey[m] + (ey[o] - ey[m]) * t
                nd, dr, _ = probe(pt[None], np.array([yt]), so[k][None])
                if nd[0]:
                    lo, dep = t, float(dr[0])
                else:
                    hi = t
            # Cut just past the last point that comes down, so the copy at
            # the edge's own height is one that needs no deck under it.
            # The edge climbs off the deck below over CUT, so the rail's
            # first face, standing on that climb, is no wider than its cap.
            y_cut = ey[m] + (ey[o] - ey[m]) * hi
            f_low = max(0.0, hi - CUT / max(length, 1e-9))
            if f_low <= 0.0:
                # The sample brought down is within CUT: the climb starts there.
                inserts.append((k, [hi if m == k else 1.0 - hi], [y_cut]))
            elif m == k:
                inserts.append((k, [f_low, hi], [y_cut + dep - (ey[o] - ey[m]) * (hi - f_low), y_cut]))
            else:
                inserts.append((k, [1.0 - hi, 1.0 - f_low], [y_cut, y_cut + dep - (ey[o] - ey[m]) * (hi - f_low)]))
        ey[need] += drop[need]
        moved += int(need.sum())
        for k, fracs, ys in sorted(inserts, key=lambda t: -t[0]):
            _cut(pc, k, fracs, side, ys)
            cuts += 1
    return moved, cuts


def _cut(pc, k, fracs, side, ys):
    """Samples inserted at increasing fractions fracs of segment k,
    everything interpolated, side's edge at heights ys."""
    def lerp(a, f):
        return a[k] + (a[k + 1] - a[k]) * f

    def ins(a, f=None, v=None):
        new = [lerp(a, x) if v is None else v for x in fracs]
        return np.concatenate([a[:k + 1], np.array(new), a[k + 1:]])

    for name in ("c", "h", "w"):
        setattr(pc, name, ins(getattr(pc, name)))
    pc.rec = ins(pc.rec, v=pc.rec[k])
    pc.toe = ins(pc.toe, v=bool(pc.toe[k] or pc.toe[k + 1]))
    pc.d = np.concatenate([pc.d[:k + 1], np.array([_unit(lerp(pc.d, x)) for x in fracs]), pc.d[k + 1:]])
    pc.n = np.concatenate([pc.n[:k + 1], np.array([_unit(lerp(pc.n, x)) for x in fracs]), pc.n[k + 1:]])
    pc.struct = np.concatenate([pc.struct[:k + 1], [pc.struct[k]] * len(fracs), pc.struct[k + 1:]])
    for s_ in (0, 1):
        for name in ("edge", "ey", "mid", "twin_h", "fade"):
            getattr(pc, name)[s_] = ins(getattr(pc, name)[s_])
        for name in ("seam", "weld"):
            a = getattr(pc, name)
            a[s_] = ins(a[s_], v=bool(a[s_][k] and a[s_][k + 1]))
        p_ = pc.partner[s_]
        pc.partner[s_] = ins(p_, v=p_[k] if p_[k] == p_[k + 1] else -1)
    pc.ey[side][k + 1:k + 1 + len(fracs)] = ys


def _toes(s, h, free):
    """Heights h at distances s along a piece, brought down to the ground
    at each free end: scaled down to 0 at the end over the shortest run of
    at least TOE_RUN on which the scaled profile is nowhere steeper than
    TOE_GRADE (the deck behind the end may still be climbing, so the end's
    own height over TOE_GRADE is not enough), or half the piece if that is
    shorter, so no end stands in mid-air and none drops off a cliff."""
    h = h.copy()
    for end in (0, 1):
        if not free[end]:
            continue
        dist = s if end == 0 else s[-1] - s
        order = np.argsort(dist)
        ds, hs = dist[order], h[order]
        cap = s[-1] / 2
        run = min(max(TOE_RUN, float(hs[0]) / TOE_GRADE), cap)
        while run < cap:
            g = hs * np.clip(ds / run, 0.0, 1.0)
            step = np.diff(ds)
            # Only the scaled stretch is the toe's to keep: beyond the run
            # the deck is as measured, and its own grade there is not one
            # a longer toe could change.
            ok = (step > 1e-6) & (ds[:-1] < run)
            if not ok.any() or float(np.max(np.abs(np.diff(g)[ok]) / step[ok])) <= TOE_GRADE + 1e-6:
                break
            run = min(run + TOE_STEP, cap)
        h *= np.clip(dist / max(run, 1e-6), 0.0, 1.0)
    return h


def _twin_seams(recs, pieces):
    """Where another deck runs alongside, the side towards it ends at the
    line midway between the two centre lines, so the two meet with no crack
    between them: always for a twin (decks.json twin_of, one road), and for
    any other deck whose edge comes within NEAR_GAP of this one's and whose
    height is less than RAIL_JOIN away. A twin's seam always meets at the
    mean of the two heights, one surface with crossfall: twin_of is the
    record saying the two are one road, of their measured heights, so not
    where either is a toe coming down to the ground. Any other pair meets
    at the mean within WELD of each other in height; further apart the seam
    is a step. Only finds each seam sample's partner, midline point and the
    partner's height there: what the seam is, welded or a step, is decided
    once per pair by _pair_seams. Returns per piece and side the partner's
    heights and whether it is a twin there."""
    lines = [shapely.linestrings(pc.c) for pc in pieces]
    tree = shapely.STRtree(lines)
    reach = max(float(pc.w.max()) for pc in pieces) + 2 * MEDIAN
    info = []
    for pi, pc in enumerate(pieces):
        best = [np.full(len(pc.c), np.inf), np.full(len(pc.c), np.inf)]
        mids = [np.zeros((len(pc.c), 2)), np.zeros((len(pc.c), 2))]
        mh = [np.zeros(len(pc.c)), np.zeros(len(pc.c))]
        tw = [np.zeros(len(pc.c), bool), np.zeros(len(pc.c), bool)]
        rt = [np.zeros(len(pc.c), bool), np.zeros(len(pc.c), bool)]
        bp = [np.full(len(pc.c), -1), np.full(len(pc.c), -1)]
        qs = [np.zeros((len(pc.c), 2)), np.zeros((len(pc.c), 2))]
        own = np.array([recs[r]["way"] for r in pc.rec])
        twin_ways = [set(recs[r]["twins"]) for r in pc.rec]
        pts = shapely.points(pc.c)
        for pj in tree.query(shapely.buffer(lines[pi], reach)):
            if pj == pi:
                continue
            other = pieces[pj]
            s = shapely.line_locate_point(lines[pj], pts)
            q = shapely.get_coordinates(shapely.line_interpolate_point(lines[pj], s))
            cum = np.concatenate([[0.0], np.cumsum(np.hypot(*(other.c[1:] - other.c[:-1]).T))])
            k = np.clip(np.searchsorted(cum, s, side="right") - 1, 0, len(cum) - 2)
            u = np.clip((s - cum[k]) / np.maximum(cum[k + 1] - cum[k], 1e-9), 0, 1)
            qh = other.h[k] + (other.h[k + 1] - other.h[k]) * u
            qw = other.w[k] + (other.w[k + 1] - other.w[k]) * u
            qd = other.d[k] + (other.d[k + 1] - other.d[k]) * u[:, None]
            qd /= np.maximum(np.hypot(*qd.T), 1e-9)[:, None]
            qway = np.array([recs[r]["way"] for r in other.rec[k]])
            twin = np.array([qway[i] in twin_ways[i] for i in range(len(qway))])
            # A toe's height is drawn, not measured: twin_of says nothing
            # about it, and beside one the seam is any other deck's.
            ttoe = pc.toe | other.toe[k] | other.toe[k + 1]
            off = q - pc.c
            sep = np.hypot(*off.T)
            across = (off * pc.n).sum(axis=1)
            near = (sep <= (pc.w + qw) / 2 + NEAR_GAP) & (np.abs(qh - pc.h) < RAIL_JOIN)
            ok = (twin & (sep <= (pc.w + qw) / 2 + 2 * MEDIAN)) | (near & (qway != own))
            # Side by side, not one over the other: each centre line lies
            # off the other deck. Where a ramp runs onto a deck, each keeps
            # its width and the one carries the other's edge.
            ok &= sep > np.minimum(pc.w, qw) / 2
            ok &= np.abs(across) > TWIN_SQUARE * sep
            ok &= np.abs((pc.d * qd).sum(axis=1)) > TWIN_PARALLEL
            # Not past either end of the other's drawn deck.
            ok &= (s > 1e-6) & (s < cum[-1] - 1e-6)
            for side, sel in ((0, ok & (across > 0)), (1, ok & (across < 0))):
                take = sel & (sep < best[side])
                best[side][take] = sep[take]
                mids[side][take] = (pc.c[take] + q[take]) / 2
                mh[side][take] = qh[take]
                tw[side][take] = twin[take] & ~ttoe[take]
                rt[side][take] = twin[take]
                bp[side][take] = pj
                qs[side][take] = q[take]
        sides = []
        for side in (0, 1):
            _across_third(pieces, lines, tree, pi, pc, best[side], qs[side], mh[side], bp[side])
            _lone(best[side], mids[side], mh[side], tw[side], rt[side], bp[side])
            m = np.isfinite(best[side])
            pc.seam[side] = m
            pc.mid[side] = mids[side]
            pc.partner[side] = np.where(m, bp[side], -1)
            pc.twin_h[side] = np.where(m, (pc.h + mh[side]) / 2, pc.h)
            pc.weld[side] = np.zeros(len(pc.c), bool)
            pc.fade[side] = np.zeros(len(pc.c))
            sides.append({"mh": mh[side], "tw": tw[side], "rt": rt[side]})
        info.append(sides)
    return info


def _across_third(pieces, lines, tree, pi, pc, best, q, mh, bp):
    """No seam across a third deck: where the line from a sample to its
    partner's centre line passes within BETWEEN of another deck's centre
    line at a height within RAIL_JOIN of the two, the two decks are not
    side by side there, the third is between them. Not where that is the
    third's own end, within half its width of it: a deck that starts or
    ends in the gap (a ramp leaving at a split mouth) has its end on the
    seam, it does not run between the two, and with the seam dropped there
    the rail drawn along either deck stands with deck on both sides of it."""
    i = np.flatnonzero(np.isfinite(best))
    if not len(i):
        return
    segs = shapely.linestrings(np.stack([pc.c[i], q[i]], axis=1))
    si, pk = tree.query(segs, predicate="dwithin", distance=BETWEEN)
    keep = (pk != pi) & (pk != bp[i[si]])
    si, pk = si[keep], pk[keep]
    if not len(si):
        return
    mid = shapely.points((pc.c[i[si]] + q[i[si]]) / 2)
    hit = np.zeros(len(si), bool)
    for n_, (a, k) in enumerate(zip(i[si], pk)):
        o = pieces[k]
        s = float(shapely.line_locate_point(lines[k], mid[n_]))
        cum = np.concatenate([[0.0], np.cumsum(np.hypot(*(o.c[1:] - o.c[:-1]).T))])
        inside = o.w[0] / 2 < s < cum[-1] - o.w[-1] / 2
        hit[n_] = inside and abs(float(np.interp(s, cum, o.h)) - (pc.h[a] + mh[a]) / 2) < RAIL_JOIN
    drop = np.unique(i[si[hit]])
    best[drop] = np.inf
    bp[drop] = -1


def _lone(best, mids, mh, tw, rt, bp):
    """A seam is a stretch, not a point. Where the side-by-side tests sit
    at their thresholds (two decks parting at a shallow angle) they can
    pass and fail by turns, and each lone sample the other way swings the
    edge between the midline and its own edge, a spike no rail can follow.
    A lone unseamed sample between two seamed with the same deck is seamed
    with it, from the two beside it; then a lone seamed sample is not."""
    n = len(best)
    if n < 3:
        return
    m = np.isfinite(best)
    j = np.flatnonzero(~m[1:-1] & m[:-2] & m[2:] & (bp[:-2] == bp[2:])) + 1
    best[j] = (best[j - 1] + best[j + 1]) / 2
    mids[j] = (mids[j - 1] + mids[j + 1]) / 2
    mh[j] = (mh[j - 1] + mh[j + 1]) / 2
    tw[j] = tw[j - 1] & tw[j + 1]
    rt[j] = rt[j - 1] & rt[j + 1]
    bp[j] = bp[j - 1]
    m = np.isfinite(best)
    prev = np.concatenate([[False], m[:-1]])
    nxt = np.concatenate([m[1:], [False]])
    j = np.flatnonzero(m & ~prev & ~nxt)
    best[j] = np.inf
    tw[j] = rt[j] = False
    bp[j] = -1


def _pair_seams(pieces, info):
    """Each pair of decks seamed together is decided once, for both. Their
    seam is one polyline of shared points: every seam sample of either deck
    is a point of the other's edge too, inserted where it falls part way
    along a segment of the other (an edge ending part way along another's
    segment, or two edges each straight between their own samples, leave a
    crack or a T in the mesh that sparkles). Each point lies on the midline
    at the mean of the two heights, two points of the two decks closer than
    KNOT_SNAP along are one, and each point is welded or a step for both
    decks alike. Where the seam goes from welded to a step, a point is
    added twice at the same place on both decks, where the two part by
    WELD, the first welded and the second stepped, so the step rises from
    nothing to its height in no distance (half of WELD on each side, a
    kerb). Twins weld wherever neither is a toe (crossfall), leaning off
    towards a stretch that is a step over FADE_GRADE, at least FADE_MIN;
    any other pair welds within WELD of each other in height, with
    WELD_HYST either way so a seam whose heights hover about WELD does not
    flick between a weld and a step every few metres."""
    lines = [shapely.linestrings(pc.c) for pc in pieces]
    cums = [_cum(pc.c) for pc in pieces]
    specs = [{} for _ in pieces]
    stats = {"welded": 0, "stepped": 0, "toes": 0, "crossfall": 0, "faded": 0, "inserted": 0, "one_sided": 0}
    done = set()
    for a, pa in enumerate(pieces):
        for sa in (0, 1):
            for b in np.unique(pa.partner[sa][pa.partner[sa] >= 0]).tolist():
                pb = pieces[b]
                count = [int((pb.partner[x] == a).sum()) for x in (0, 1)]
                sb = int(np.argmax(count)) if max(count) else None
                key = frozenset([(a, sa), (b, sb)]) if sb is not None else (a, sa, b)
                if key in done:
                    continue
                done.add(key)
                _pair(pieces, info, lines, cums, specs, (a, sa), (b, sb), stats)
    for pi, pc in enumerate(pieces):
        if specs[pi]:
            _resample(pc, specs[pi])
    print("decks_mesh: seams at %d points (%d added so both decks share them; %d pairs one-sided), %d of them steps "
          "of more than %.1f m (%d between twins, at a toe); %d twin points further apart than that drawn as "
          "crossfall, %d leaning off it towards a step" % (
              stats["welded"] + stats["stepped"] + stats["faded"], stats["inserted"], stats["one_sided"],
              stats["stepped"], WELD, stats["toes"], stats["crossfall"], stats["faded"]), flush=True)


def _cum(c):
    return np.concatenate([[0.0], np.cumsum(np.hypot(*(c[1:] - c[:-1]).T))])


def _pair(pieces, info, lines, cums, specs, A, B, stats):
    """One pair's seam (see _pair_seams), written into specs: per piece,
    {(sample, fraction along the segment after it, order): {side: fields}}."""
    (a, sa), (b, sb) = A, B
    pa, pb = pieces[a], pieces[b]
    # The seam's points in one order for both decks: each deck's own
    # samples in its own order, the two lists merged by where each falls
    # along A. A point is placed on the other deck no further back than the
    # one before it, nor further on than the one after, so the two edges
    # pass through the same points in the same order (ordered by where each
    # projects, a deck meeting the other at an angle puts two points in
    # opposite orders on the two, and its edge zigzags back across the
    # other's).
    ia = np.flatnonzero(pa.partner[sa] == b)
    va = shapely.line_locate_point(lines[b], shapely.points(pa.c[ia]))
    ka = [{"u": cums[a][i], "v": float(va[n_]), "ia": int(i), "ib": None, "P": pa.mid[sa][i],
           "ha": pa.h[i], "hb": info[a][sa]["mh"][i], "tw": bool(info[a][sa]["tw"][i]),
           "rt": bool(info[a][sa]["rt"][i])} for n_, i in enumerate(ia)]
    kb = []
    if sb is None:
        stats["one_sided"] += 1
    else:
        ib = np.flatnonzero(pb.partner[sb] == a)
        ub = shapely.line_locate_point(lines[a], shapely.points(pb.c[ib]))
        kb = [{"u": float(ub[n_]), "v": cums[b][j], "ia": None, "ib": int(j), "P": pb.mid[sb][j],
               "ha": info[b][sb]["mh"][j], "hb": pb.h[j], "tw": bool(info[b][sb]["tw"][j]),
               "rt": bool(info[b][sb]["rt"][j])} for n_, j in enumerate(ib)]
    vdir = 1.0
    if len(ka) > 1:
        vdir = 1.0 if ka[-1]["v"] >= ka[0]["v"] else -1.0
    elif len(kb) > 1:
        vdir = 1.0 if kb[-1]["u"] >= kb[0]["u"] else -1.0
    if vdir < 0:
        kb.reverse()
    knots, i_, j_ = [], 0, 0
    while i_ < len(ka) or j_ < len(kb):
        if j_ == len(kb) or (i_ < len(ka) and ka[i_]["u"] <= kb[j_]["u"]):
            knots.append(ka[i_])
            i_ += 1
        else:
            knots.append(kb[j_])
            j_ += 1
    for own, free in (("ia", "u"), ("ib", "v")):
        sgn = 1.0 if free == "u" else vdir
        fixed = [n_ for n_, k in enumerate(knots) if k[own] is not None]
        for n_, k in enumerate(knots):
            if k[own] is not None:
                continue
            lo = [knots[m][free] for m in fixed if m < n_]
            hi = [knots[m][free] for m in fixed if m > n_]
            x = k[free] * sgn
            if lo:
                x = max(x, lo[-1] * sgn)
            if hi:
                x = min(x, hi[0] * sgn)
            k[free] = x * sgn
    merged = []
    for k in knots:
        m = merged[-1] if merged else None
        if m is not None and abs(k["u"] - m["u"]) < KNOT_SNAP and (m["ia"] is None) != (k["ia"] is None)                 and (m["ia"] is None or m["ib"] is None) and (k["ia"] is None or k["ib"] is None):
            ka_, kb_ = (m, k) if m["ia"] is not None else (k, m)
            merged[-1] = {"u": ka_["u"], "v": kb_["v"], "ia": ka_["ia"], "ib": kb_["ib"],
                          "P": (ka_["P"] + kb_["P"]) / 2, "ha": (ka_["ha"] + kb_["ha"]) / 2,
                          "hb": (ka_["hb"] + kb_["hb"]) / 2, "tw": ka_["tw"] and kb_["tw"], "rt": ka_["rt"] or kb_["rt"]}
        else:
            merged.append(k)
    knots = merged
    if not knots:
        return
    # Where each knot sits on each piece: an existing sample, or a segment
    # and the fraction along it; None where that piece has no seam with the
    # other on that segment to put it in.
    for k in knots:
        k["pa"] = (k["ia"], 0.0) if k["ia"] is not None else _slot(pa, sa, b, cums[a], k["u"])
        k["pb"] = None if sb is None else ((k["ib"], 0.0) if k["ib"] is not None else _slot(pb, sb, a, cums[b], k["v"]))
    # Two points of the seam closer than KNOT_SNAP on the ground, or the
    # second behind the first along either deck in the order that deck
    # takes them (two samples of a deck at one corner, each with its own
    # midline point, paired the other way round with the other deck's), are
    # put at one place: else the seam steps back between them, and its two
    # decks fold over each other there, a hairline that sparkles.
    for key, pc in (("pa", pa), ("pb", pb)):
        for _ in range(2):
            on = sorted((k for k in knots if k[key] is not None), key=lambda k: k[key][0] + k[key][1])
            for p, q in zip(on[:-1], on[1:]):
                step = q["P"] - p["P"]
                if float(np.hypot(*step)) < KNOT_SNAP or float(step @ pc.d[p[key][0]]) < 0.0:
                    mid = (p["P"] + q["P"]) / 2
                    p["P"], q["P"] = mid, mid.copy()
    u = np.array([k["u"] for k in knots])
    dh = np.abs(np.array([k["ha"] - k["hb"] for k in knots]))
    tw = np.array([k["tw"] for k in knots])
    run = np.concatenate([[0], np.cumsum(np.diff(u) > KNOT_GAP)])
    high = dh > WELD
    for r0, r1 in _runs(high):
        if dh[r0:r1 + 1].max() <= WELD + WELD_HYST:
            high[r0:r1 + 1] = False
    for r0, r1 in _runs(~high):
        inside = r0 > 0 and r1 < len(high) - 1 and run[r0 - 1] == run[r0] and run[r1] == run[r1 + 1] \
            and high[r0 - 1] and high[r1 + 1]
        if inside and dh[r0:r1 + 1].min() >= WELD - WELD_HYST:
            high[r0:r1 + 1] = True
    near = ~high
    cross = tw & ~near
    hard = ~near & ~tw
    fade = np.ones(len(u))
    if hard.any():
        dist = np.min(np.abs(u[:, None] - u[hard][None, :]), axis=1)
        fade = np.clip(dist / np.maximum(FADE_MIN, dh / FADE_GRADE), 0.0, 1.0)
    weld = near | (cross & (fade >= 1.0))
    lean = np.where(cross & (fade < 1.0), fade, 0.0)
    stats["welded"] += int(weld.sum())
    stats["stepped"] += int((~weld & ~cross).sum())
    stats["toes"] += int((~weld & ~cross & np.array([k["rt"] for k in knots])).sum())
    stats["faded"] += int((cross & (fade < 1.0)).sum())
    stats["crossfall"] += int((cross & (fade >= 1.0)).sum())
    pts = []  # (knot fields, welded, lean, order)
    for n_, k in enumerate(knots):
        pts.append((k, bool(weld[n_]), float(lean[n_]), 0))
        m = n_ + 1
        if m == len(knots) or run[m] != run[n_] or weld[n_] == weld[m] or lean[n_] > 0.0 or lean[m] > 0.0:
            continue
        # The weld ends where the two part by WELD, both decks at one place.
        w_, s_ = (n_, m) if weld[n_] else (m, n_)
        span = dh[s_] - dh[w_]
        f = float(np.clip((WELD - dh[w_]) / span, 0.05, 0.95)) if span > 1e-9 else 0.5
        if w_ == m:
            f = 1.0 - f
        q = {key: k[key] + (knots[m][key] - k[key]) * f for key in ("u", "v", "P", "ha", "hb")}
        q["pa"] = _between(k["pa"], knots[m]["pa"], pa, sa, b, cums[a], q["u"])
        q["pb"] = _between(k["pb"], knots[m]["pb"], pb, sb, a, cums[b], q["v"]) if sb is not None else None
        pts.append((q, bool(weld[n_]), 0.0, 1))
        pts.append((q, bool(weld[m]), 0.0, 2))
    # The two copies of a doubled point go in the order each piece runs.
    for k, wl, ln, order in pts:
        fields = {"seam": True, "weld": wl, "mid": k["P"], "twin_h": (k["ha"] + k["hb"]) / 2, "fade": ln}
        for pi, slot, side, other, flip in ((a, k["pa"], sa, b, False), (b, k["pb"], sb, a, vdir < 0)):
            if slot is None:
                continue
            j, f = slot
            o = 3 - order if (flip and order) else order
            specs[pi].setdefault((int(j), float(f), o), {})[side] = dict(fields, partner=other)
            if f > 0.0 and order < 2:
                stats["inserted"] += 1


def _slot(pc, side, other, cum, x):
    """Where distance x along pc's centre line falls: (segment, fraction),
    if a sample at either end of that segment is seamed with other on this
    side, else None."""
    if not (1e-6 < x < cum[-1] - 1e-6):
        return None
    k = int(np.clip(np.searchsorted(cum, x, side="right") - 1, 0, len(cum) - 2))
    if pc.partner[side][k] != other and pc.partner[side][k + 1] != other:
        return None
    f = (x - cum[k]) / max(cum[k + 1] - cum[k], 1e-9)
    return k, float(np.clip(f, 1e-3, 1.0 - 1e-3))


def _between(p, q, pc, side, other, cum, x):
    """The slot of a point between two knots with slots p and q, or None if
    either has none."""
    if p is None or q is None:
        return None
    return _slot(pc, side, other, cum, x)


def _resample(pc, spec):
    """The piece resampled: every existing sample, plus each (sample,
    fraction, order) in spec inserted along the segment after it,
    everything interpolated, then each entry's per-side fields set. The
    entries at existing samples are set first, so a point added on one side
    takes its other side from the seam as decided there, not as it was
    before any pair was decided."""
    n = len(pc.c)
    for (j0, f0, o0), sides in spec.items():
        if f0 == 0.0 and o0 == 0:
            for sd, fields in sides.items():
                for name, val in fields.items():
                    getattr(pc, name)[sd][j0] = val
    keys = sorted(set(spec) | {(j, 0.0, 0) for j in range(n)})
    j = np.array([k_[0] for k_ in keys])
    f = np.array([k_[1] for k_ in keys])
    k = np.minimum(j + 1, n - 1)

    def at(v):
        ff = f.reshape((-1,) + (1,) * (v.ndim - 1))
        return v[j] + (v[k] - v[j]) * ff

    u = j + f
    seg = np.minimum(np.floor(np.minimum(u[:-1], u[1:])).astype(int), len(pc.struct) - 1)
    d = at(pc.d)
    pc.d = d / np.maximum(np.hypot(*d.T), 1e-9)[:, None]
    pc.n = np.stack([-pc.d[:, 1], pc.d[:, 0]], axis=1)
    pc.c, pc.h, pc.w = at(pc.c), at(pc.h), at(pc.w)
    pc.rec = pc.rec[j]
    pc.toe = np.where(f > 0.0, pc.toe[j] | pc.toe[k], pc.toe[j])
    pc.struct = pc.struct[seg]
    for sd in (0, 1):
        # Each side's own decided points: the samples, and what spec puts on
        # this side. A point spec puts only on the other side lies between
        # two of them and is read off the line between those two (the
        # partner's edge runs straight between the same two points), welded
        # as the one before it is (a weld ends at its own doubled point).
        own = np.array([f[i] == 0.0 or sd in spec.get(key, {}) for i, key in enumerate(keys)])
        oi = np.flatnonzero(own)
        prev = oi[np.clip(np.searchsorted(oi, np.arange(len(keys)), side="right") - 1, 0, len(oi) - 1)]
        nxt = oi[np.clip(np.searchsorted(oi, np.arange(len(keys)), side="left"), 0, len(oi) - 1)]
        span = u[nxt] - u[prev]
        t = np.where(span > 1e-12, (u - u[prev]) / np.where(span > 1e-12, span, 1.0), 0.0)
        src = {name: getattr(pc, name)[sd] for name in ("seam", "weld", "mid", "twin_h", "fade", "partner")}
        vals = {name: v[j] for name, v in src.items()}
        for idx, key in enumerate(keys):
            for name, val in spec.get(key, {}).get(sd, {}).items():
                vals[name][idx] = val
        for name in ("mid", "twin_h", "fade"):
            v = vals[name]
            tt = t.reshape((-1,) + (1,) * (v.ndim - 1))
            v[~own] = (v[prev] + (v[nxt] - v[prev]) * tt)[~own]
        vals["seam"][~own] = (vals["seam"][prev] & vals["seam"][nxt])[~own]
        vals["weld"][~own] = vals["weld"][prev][~own] & vals["seam"][~own]
        same = vals["partner"][prev] == vals["partner"][nxt]
        vals["partner"][~own] = np.where(same, vals["partner"][prev], -1)[~own]
        for name, v in vals.items():
            getattr(pc, name)[sd] = v
        for name in ("edge", "ey"):
            arr = getattr(pc, name)
            if arr[sd] is not None:
                arr[sd] = at(arr[sd])


def _edges(pc):
    """Each side's edge points and heights."""
    c, d, n, w = pc.c, pc.d, pc.n, pc.w
    # Curvature at each sample, signed, positive turning left: the turn of
    # the direction across BEND_SPAN, over that distance.
    s = np.concatenate([[0.0], np.cumsum(np.hypot(*(c[1:] - c[:-1]).T))])
    a = np.unwrap(np.arctan2(d[:, 1], d[:, 0]))
    lo, hi = np.maximum(s - BEND_SPAN / 2, s[0]), np.minimum(s + BEND_SPAN / 2, s[-1])
    turn = (np.interp(hi, s, a) - np.interp(lo, s, a)) / np.maximum(hi - lo, 1e-6)
    for side, sign in ((0, 1.0), (1, -1.0)):
        half = w / 2
        inside = turn * sign > 0
        half = np.where(inside, np.minimum(half, BEND / np.maximum(np.abs(turn), 1e-9)), half)
        e = c + n * (sign * half)[:, None]
        ey = pc.y.copy()
        s = pc.seam[side]
        e[s] = pc.mid[side][s]
        wl = pc.weld[side]
        ey[wl] = pc.twin_h[side][wl] + LIFT
        fd = pc.fade[side]
        ey += fd * (pc.twin_h[side] - pc.h)
        # A dropped end stays at the ground across the whole profile.
        if pc.free[0]:
            ey[0] = pc.y[0]
        if pc.free[1]:
            ey[-1] = pc.y[-1]
        pc.edge[side], pc.ey[side] = e, ey


class _Tops:
    """Every piece's deck top, for asking what deck lies beside an edge."""

    def __init__(self, pieces):
        tris, owner = [], []
        for pi, pc in enumerate(pieces):
            t = _top_tris(pc)
            tris.append(t)
            owner.append(np.full(len(t), pi))
        self.tris = np.concatenate(tris).astype(float)
        self.owner = np.concatenate(owner)
        self.tree = shapely.STRtree(shapely.polygons(self.tris[:, :, [0, 2]]))
        self.index = {id(pc): pi for pi, pc in enumerate(pieces)}

    def carried(self, pc, pts, y):
        """Per point (n, 2) at height y: whether another piece's deck top
        lies over it STEP_MAX below to RAIL_JOIN above y."""
        out = np.zeros(len(pts), bool)
        pi, rel = self.rels(pc, pts, y)
        hit = (rel > -STEP_MAX) & (rel < RAIL_JOIN)
        out[pi[hit]] = True
        return out

    def rels(self, pc, pts, y):
        """Every other piece's deck top over points (n, 2): (point index,
        its height relative to y)."""
        if not len(pts):
            return np.zeros(0, int), np.zeros(0)
        pi, ti = self.tree.query(shapely.points(pts), predicate="intersects")
        keep = self.owner[ti] != self.index[id(pc)]
        pi, ti = pi[keep], ti[keep]
        t = self.tris[ti]
        q = pts[pi]
        a = t[:, 0, [0, 2]]
        e1, e2, r = t[:, 1, [0, 2]] - a, t[:, 2, [0, 2]] - a, q - a
        det = e1[:, 0] * e2[:, 1] - e1[:, 1] * e2[:, 0]
        ok = np.abs(det) > 1e-12
        det = np.where(ok, det, 1.0)
        u = (r[:, 0] * e2[:, 1] - r[:, 1] * e2[:, 0]) / det
        v = (e1[:, 0] * r[:, 1] - e1[:, 1] * r[:, 0]) / det
        ys = t[:, 0, 1] + u * (t[:, 1, 1] - t[:, 0, 1]) + v * (t[:, 2, 1] - t[:, 0, 1])
        return pi[ok], (ys - y[pi])[ok]

    def covered(self, pc, e, ey, outward):
        """Per edge point: carried at any of the COVER distances outward."""
        res = np.zeros(len(e), bool)
        for t in COVER:
            res |= self.carried(pc, e + outward * t, ey)
        return res


def _top_tris(pc):
    """The deck top as triangles (n, 3, 3): each half from the centre line
    to its edge, quad by quad."""
    cy = _xyz(pc.c, pc.y)
    L = _xyz(pc.edge[0], pc.ey[0])
    R = _xyz(pc.edge[1], pc.ey[1])
    q1 = np.stack([L[:-1], L[1:], cy[1:], cy[:-1]], axis=1)
    q2 = np.stack([cy[:-1], cy[1:], R[1:], R[:-1]], axis=1)
    quads = np.concatenate([q1, q2])
    up = np.tile([0.0, 1.0, 0.0], (len(quads), 1))
    return _tris(quads, up)


def _seg_out(pc, side):
    """Per segment of one side's edge, the unit vector square to it, away
    from the deck: the way off the deck across that stretch of edge, which
    where the edge runs onto a seam or across a merge is not the way
    square to the centre line."""
    e = pc.edge[side]
    seg = e[1:] - e[:-1]
    out = np.stack([-seg[:, 1], seg[:, 0]], axis=1) * (1.0 if side == 0 else -1.0)
    length = np.hypot(*out.T)
    away = (e[1:] + e[:-1]) / 2 - (pc.c[1:] + pc.c[:-1]) / 2
    out *= np.where((out * away).sum(axis=1) < 0, -1.0, 1.0)[:, None]
    fallback = (pc.n[1:] + pc.n[:-1]) * (0.5 if side == 0 else -0.5)
    out = np.where((length > 1e-6)[:, None], out / np.maximum(length, 1e-9)[:, None], fallback)
    return out / np.maximum(np.hypot(*out.T), 1e-9)[:, None]


def _outward(pc, side):
    """Per sample, the unit vector outward from the deck at that edge: the
    mean of the two segments' either side of it."""
    so = _seg_out(pc, side)
    out = np.zeros((len(pc.c), 2))
    out[:-1] += so
    out[1:] += so
    length = np.hypot(*out.T)
    fallback = pc.n * (1.0 if side == 0 else -1.0)
    return np.where((length > 1e-6)[:, None], out / np.maximum(length, 1e-9)[:, None], fallback)


def _trim(pc, tree):
    """Where a piece ends on another deck, drop the samples past the last
    one wholly on that deck: its section across, edge to edge, over
    another deck's top every PROBE, and each edge either on a seam or with
    deck beside it. Decks on both sides is not enough: a deck running in
    the slot between two others is bordered all along and on neither, and
    an end cut where it is only bordered faces the open slot. Returns the
    number of ends trimmed."""
    if len(pc.c) < 3:
        return 0
    trimmed = 0
    cov = np.ones(len(pc.c), bool)
    width = np.hypot(*(pc.edge[1] - pc.edge[0]).T)
    m = max(2, int(math.ceil(float(width.max()) / PROBE)))
    for f in (np.arange(1, m) / m):
        for side in (0, 1):
            pts = pc.c + (pc.edge[side] - pc.c) * f
            ys = pc.y + (pc.ey[side] - pc.y) * f
            cov &= tree.carried(pc, pts, ys)
    cov &= tree.carried(pc, pc.c, pc.y)
    for side in (0, 1):
        cov &= tree.covered(pc, pc.edge[side], pc.ey[side], _outward(pc, side)) | pc.seam[side]
    keep = np.ones(len(pc.c), bool)
    for end in (0, 1):
        if pc.free[end]:
            continue
        idx = np.arange(len(pc.c))[::-1] if end == 1 else np.arange(len(pc.c))
        j = None
        for k in idx:
            if not cov[k]:
                break
            j = k
        if j is None or j == idx[0]:
            continue
        if end == 1:
            keep[j + 1:] = False
        else:
            keep[:j] = False
        trimmed += 1
    if keep.all() or keep.sum() < 2:
        return 0
    seg_keep = keep[:-1] & keep[1:]
    for name in Piece.SAMPLE:
        setattr(pc, name, getattr(pc, name)[keep])
    pc.struct = pc.struct[seg_keep]
    for name in Piece.SIDE:
        arr = getattr(pc, name)
        for side in (0, 1):
            arr[side] = arr[side][keep]
    return trimmed


def _profile(pc):
    """The deck top, sides, underside and end walls: (kind, triangles)."""
    out = [(DECK, _top_tris(pc))]
    cy = pc.y.copy()
    seg_st = pc.struct
    for side in (0, 1):
        e, ey = pc.edge[side], pc.ey[side]
        sign = 1.0 if side == 0 else -1.0
        # Each segment's side down to its own bottom: THICK under a structure,
        # the ground under an embankment.
        b0 = np.where(seg_st, np.maximum(0.0, ey[:-1] - THICK), 0.0)
        b1 = np.where(seg_st, np.maximum(0.0, ey[1:] - THICK), 0.0)
        seam = pc.seam[side][:-1] & pc.seam[side][1:]
        weld = pc.weld[side][:-1] & pc.weld[side][1:]
        draw = ~(seam & weld)
        quads = np.stack([_xyz(e[:-1], b0), _xyz(e[1:], b1), _xyz(e[1:], ey[1:]), _xyz(e[:-1], ey[:-1])], axis=1)[draw]
        seg = e[1:] - e[:-1]
        nrm = np.stack([-seg[:, 1], np.zeros(len(seg)), seg[:, 0]], axis=1) * sign
        out.append((SIDE, _tris(quads, nrm[draw])))
    # Underside of each structure segment, each half.
    if seg_st.any():
        L, R = pc.edge[0], pc.edge[1]
        bl = np.maximum(0.0, pc.ey[0] - THICK)
        br = np.maximum(0.0, pc.ey[1] - THICK)
        bc = np.maximum(0.0, cy - THICK)
        q1 = np.stack([_xyz(L[:-1], bl[:-1]), _xyz(L[1:], bl[1:]), _xyz(pc.c[1:], bc[1:]), _xyz(pc.c[:-1], bc[:-1])], axis=1)
        q2 = np.stack([_xyz(pc.c[:-1], bc[:-1]), _xyz(pc.c[1:], bc[1:]), _xyz(R[1:], br[1:]), _xyz(R[:-1], br[:-1])], axis=1)
        quads = np.concatenate([q1[seg_st], q2[seg_st]])
        down = np.tile([0.0, -1.0, 0.0], (len(quads), 1))
        out.append((SIDE, _tris(quads, down)))
    # End walls: across each end from the deck top down to its bottom.
    walls = []
    for end in (0, 1):
        k = 0 if end == 0 else len(pc.c) - 1
        st = seg_st[0] if end == 0 else seg_st[-1]
        along = pc.d[k] * (-1.0 if end == 0 else 1.0)
        for a, ya, b, yb in ((pc.edge[0][k], pc.ey[0][k], pc.c[k], cy[k]), (pc.c[k], cy[k], pc.edge[1][k], pc.ey[1][k])):
            ba = max(0.0, ya - THICK) if st else 0.0
            bb = max(0.0, yb - THICK) if st else 0.0
            if max(ya - ba, yb - bb) < 1e-3:
                continue
            walls.append((np.array([_xyz(a, ba), _xyz(b, bb), _xyz(b, yb), _xyz(a, ya)]), [along[0], 0.0, along[1]]))
    # Where a structure meets an embankment, the embankment's end below the
    # structure's underside.
    for k in np.flatnonzero(seg_st[:-1] != seg_st[1:]) + 1:
        toward = pc.d[k] * (1.0 if seg_st[k] else -1.0)
        for a, ya, b, yb in ((pc.edge[0][k], pc.ey[0][k], pc.c[k], cy[k]), (pc.c[k], cy[k], pc.edge[1][k], pc.ey[1][k])):
            ta, tb = max(0.0, ya - THICK), max(0.0, yb - THICK)
            if max(ta, tb) < 1e-3:
                continue
            walls.append((np.array([_xyz(a, 0.0), _xyz(b, 0.0), _xyz(b, tb), _xyz(a, ta)]), [toward[0], 0.0, toward[1]]))
    if walls:
        quads = np.stack([w_[0] for w_ in walls])
        nrm = np.array([w_[1] for w_ in walls])
        out.append((SIDE, _tris(quads, nrm)))
    return out


def _rail_runs(pc, side, tree):
    """The rails along one side: runs of (points, heights, inward unit
    vectors), each over the stretch of edge with no other deck beside it.
    A segment whose two ends both have deck beside them is also probed
    every PROBE along its length, square to it, so an open stretch between
    them (a notch's apex, a hole where a seam changes partner) gets its
    rail too."""
    e, ey = pc.edge[side], pc.ey[side]
    if len(e) < 2:
        return []
    outward = _outward(pc, side)
    cov = tree.covered(pc, e, ey, outward)
    # The rail's inner face stands RAIL_THICK in from the edge, square to
    # it: per segment its own inward normal, at a sample the mitre of the
    # two either side (lengthened so each face keeps its thickness, to at
    # most twice). Not towards the centre line: where an edge runs across
    # the deck, as it does from a seam back out to its own edge, that
    # direction lies along the edge and the rail top would be a sliver.
    seg_in = -_seg_out(pc, side)
    inward = -outward
    sq = np.full(len(e), 1.0)
    sq[:-1] = np.minimum(sq[:-1], (inward[:-1] * seg_in).sum(axis=1))
    sq[1:] = np.minimum(sq[1:], (inward[1:] * seg_in).sum(axis=1))
    inward = inward / np.maximum(sq, 0.5)[:, None]
    # Per segment: the uncovered part [t0, t1], or None.
    nseg = len(e) - 1
    seg_out = []
    for k in range(nseg):
        a, b = cov[k], cov[k + 1]
        if not a and not b:
            seg_out.append((0.0, 1.0))
        elif a and b:
            seg_out.append("inner")
        else:
            seg_out.append("split")
    _inner_holes(pc, side, tree, e, ey, seg_out)
    split = [k for k in range(nseg) if seg_out[k] == "split"]
    if split:
        lo = np.zeros(len(split))
        hi = np.ones(len(split))
        ks = np.array(split)
        a_cov = cov[ks]
        length = np.hypot(*(e[ks + 1] - e[ks]).T)
        seg_dir = e[ks + 1] - e[ks]
        seg_out_n = _seg_out(pc, side)[ks]
        iters = int(math.ceil(math.log2(max(1.0, float(length.max()) / RAIL_TO)))) if len(length) else 0
        for _ in range(iters):
            t = (lo + hi) / 2
            pts = e[ks] + seg_dir * t[:, None]
            ys = ey[ks] + (ey[ks + 1] - ey[ks]) * t
            c = np.zeros(len(ks), bool)
            for dist in COVER:
                c |= tree.carried(pc, pts + seg_out_n * dist, ys)
            # Move the bound on the side that matches.
            same_as_a = c == a_cov
            lo = np.where(same_as_a, t, lo)
            hi = np.where(same_as_a, hi, t)
        for j, k in enumerate(split):
            # The rail runs to the far end of the bracket, so no open edge is
            # left unrailed between the bracket's ends.
            seg_out[k] = (hi[j], 1.0) if a_cov[j] else (0.0, hi[j])
    runs, cur = [], None
    for k in range(nseg):
        iv = seg_out[k]
        if iv is None:
            if cur:
                runs.append(cur)
            cur = None
            continue
        t0, t1 = iv
        p0 = e[k] + (e[k + 1] - e[k]) * t0
        p1 = e[k] + (e[k + 1] - e[k]) * t1
        y0 = ey[k] + (ey[k + 1] - ey[k]) * t0
        y1 = ey[k] + (ey[k + 1] - ey[k]) * t1
        i0 = inward[k] if t0 == 0.0 else seg_in[k]
        i1 = inward[k + 1] if t1 == 1.0 else seg_in[k]
        if cur is not None and t0 == 0.0:
            cur[0].append(p1)
            cur[1].append(y1)
            cur[2].append(i1)
        else:
            if cur:
                runs.append(cur)
            cur = [[p0, p1], [y0, y1], [i0, i1]]
        if t1 < 1.0:
            runs.append(cur)
            cur = None
    if cur:
        runs.append(cur)
    return [(np.array(p), np.array(y), np.array(i)) for p, y, i in runs if max(y) >= RAIL_DROP]


def _inner_holes(pc, side, tree, e, ey, seg_out):
    """For each segment marked "inner" (deck beside both ends): probe it
    every PROBE, square to the segment; where any probe is open, the open
    stretch from the first open probe to the last, each bound found by
    bisection to RAIL_TO and taken at its carried side, so the rail closes
    the hole; else None."""
    so = _seg_out(pc, side)
    ks = [k for k in range(len(seg_out)) if seg_out[k] == "inner"]
    for k in ks:
        seg_out[k] = None
    if not ks:
        return
    ks = np.array(ks)
    lens = np.hypot(*(e[ks + 1] - e[ks]).T)
    n = np.ceil(lens / PROBE).astype(int)
    m = n >= 2
    ks, n = ks[m], n[m]
    if not len(ks):
        return

    def open_at(k, f):
        pts = e[k] + (e[k + 1] - e[k]) * f[:, None]
        ys = ey[k] + (ey[k + 1] - ey[k]) * f
        c = np.zeros(len(k), bool)
        for dist in COVER:
            c |= tree.carried(pc, pts + so[k] * dist, ys)
        return ~c

    K = np.repeat(ks, n - 1)
    N = np.repeat(n, n - 1)
    J = np.arange(len(K)) - np.repeat(np.cumsum(n - 1) - (n - 1), n - 1) + 1
    op = open_at(K, J / N)
    if not op.any():
        return
    hk, first, last, nn = [], [], [], []
    for k in np.unique(K[op]):
        j = J[(K == k) & op]
        hk.append(k)
        first.append(j.min())
        last.append(j.max())
        nn.append(N[K == k][0])
    hk, nn = np.array(hk), np.array(nn, float)
    first, last = np.array(first, float), np.array(last, float)
    # Start: covered at lo, open at hi.  End: open at lo, covered at hi.
    slo, shi = (first - 1) / nn, first / nn
    elo, ehi = last / nn, (last + 1) / nn
    iters = int(math.ceil(math.log2(max(1.0, PROBE / RAIL_TO)))) + 1
    for _ in range(iters):
        t = (slo + shi) / 2
        o = open_at(hk, t)
        shi = np.where(o, t, shi)
        slo = np.where(o, slo, t)
        t = (elo + ehi) / 2
        o = open_at(hk, t)
        elo = np.where(o, t, elo)
        ehi = np.where(o, ehi, t)
    for i, k in enumerate(hk):
        seg_out[k] = (float(slo[i]), float(ehi[i]))


def _unit(v):
    return v / max(float(np.hypot(*v)), 1e-9)


def _rail(p, y, inward, side):
    """A rail along edge points p at deck heights y: outer face, inner face
    RAIL_THICK inward, top, and a cap at each end."""
    inner = p + inward * RAIL_THICK
    top = y + RAIL_HEIGHT
    o0, o1 = _xyz(p, y), _xyz(p, top)
    i0, i1 = _xyz(inner, y), _xyz(inner, top)
    out_n = np.concatenate([-inward[:-1] - inward[1:]]) / 2
    out_n3 = np.stack([out_n[:, 0], np.zeros(len(out_n)), out_n[:, 1]], axis=1)
    faces = [
        (np.stack([o0[:-1], o0[1:], o1[1:], o1[:-1]], axis=1), out_n3),
        (np.stack([i0[:-1], i0[1:], i1[1:], i1[:-1]], axis=1), -out_n3),
        (np.stack([o1[:-1], o1[1:], i1[1:], i1[:-1]], axis=1), np.tile([0.0, 1.0, 0.0], (len(p) - 1, 1))),
    ]
    d0, d1 = p[0] - p[1], p[-1] - p[-2]
    faces.append((np.array([[o0[0], i0[0], i1[0], o1[0]]]), np.array([[d0[0], 0.0, d0[1]]])))
    faces.append((np.array([[o0[-1], i0[-1], i1[-1], o1[-1]]]), np.array([[d1[0], 0.0, d1[1]]])))
    return np.concatenate([_tris(q, n) for q, n in faces])


# ---------------------------------------------------------------- piers

def _piers(pieces, recs, ways, others, put):
    """Piers under every structure, PIER_STEP apart, as bridges.py placed them."""
    deck_ways = {r["way"] for r in recs}
    lane_info, ends, widths = [], [], []
    for pi, pc in enumerate(pieces):
        y = pc.y
        for i in range(len(pc.c) - 1):
            lane_info.append((recs[pc.rec[i]]["way"], pc.c[i], pc.c[i + 1], y[i], y[i + 1], recs[pc.rec[i]]["bridge"]))
            ends.append((pc.c[i], pc.c[i + 1]))
            widths.append(pc.w[i] / 2)
    for w in ways:
        if w["osm"] in deck_ways:
            continue
        p = w["pts"]
        keep = np.concatenate([[True], np.hypot(*(p[1:] - p[:-1]).T) > 0.05])
        p = p[keep]
        for i in range(len(p) - 1):
            lane_info.append((w["osm"], p[i], p[i + 1], LIFT, LIFT, w["bridge"]))
            ends.append((p[i], p[i + 1]))
            widths.append(w["width"] / 2)
    lanes = shapely.buffer(shapely.linestrings(np.array(ends)), np.array(widths), cap_style="flat")
    lane_tree = shapely.STRtree(lanes)
    ground = [shapely.buffer(o[0], o[3] / 2 + PIER_CLEAR) for o in others if not o[4] and o[3] > 0]
    ground_tree = shapely.STRtree(ground)

    piers = moved = blocked = 0
    for pc in pieces:
        raised = pc.struct
        if not raised.any():
            continue
        p, h = pc.c, pc.y
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
                i = int(np.searchsorted(cum, at + shift, side="right")) - 1
                wid = pc.w[min(max(i, 0), len(pc.w) - 1)]
                wi = recs[pc.rec[min(max(i, 0), len(pc.rec) - 1)]]["way"]
                across = np.array([-d[1], d[0]]) * min(wid * 0.35, 5.0)
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
    return piers, moved, blocked


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

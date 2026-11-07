"""Authored elevated decks: one record per elevated way, its heights measured.

    python -I tools/blockout/decks_seed.py <raw dir> <out dir> [--from lidar|solver]
        [--lidar <lidar_decks.npz>: default <raw dir>/lidar_decks.npz if there is one,
                 else data/blockouts/new_orleans_lidar/lidar_decks.npz]
        [--plot name,x,z,r ... --png-dir <dir>]

Writes <out>/decks.json, the records the deck mesher draws from and the
place hand edits live, and <out>/decks_report.json, the lists to edit: the
crossings short of clearance, the stretches steeper than GRADE_MAX, the
joins two records disagree on, the twins LiDAR did not confirm, the nodes
moved onto the measured deck.

The deck set is what bridges.py raises: every way the height solve
(bridges.solve) puts above MIN_HEIGHT, and every bridge, inside the map
boundary plus RUNOUT. A record is the stretch of its way from the first
raised segment to the last, so a ramp's record ends at its toe on the
ground. Its nodes are the solve's (OSM nodes, "id", plus the nodes the
solve adds every STEP metres and beside other roads, "id": null).

Heights ("h", metres above the local ground, the frame bridges.py draws in;
"hs" is the solve's height for comparison):
  - lidar: at each node, the class-17 (bridge deck) returns within half the
    road's width of the centre line and ALONG metres along it, split into
    layers wherever their heights part by LAYER_GAP; each layer of at least
    MIN_RETURNS returns offers its 20th percentile (under cars, signs and
    canopy), less the median class-2 (ground) height within GROUND_R.
    LiDAR sees only the top deck, so where the solve puts another deck over
    a node (by more than UNDER), the returns on that deck's footprint are
    not the node's, nor is a layer at the height that deck measures there.
    Which layer each node takes is chosen along the whole way at once
    (_choose), as the profile that stays within GRADE_MAX, skipping a node
    rather than jumping to another deck;
  - interp: a node with no layer chosen between two that have one, less than
    INTERP_MAX apart along the way (a deck hidden under one crossing it), on
    the straight line between them;
  - solver: anything else: the solve's height, moved by the offset (h - hs)
    the measured nodes put on the solve, spread over the solver nodes as
    the smoothest offset that meets every measured node (_anchor): along a
    run, the straight line between the offsets either side, carried on past
    the last; through joins into the records sharing a node. The solve's
    profile keeps its shape but meets the deck LiDAR measured, rather than
    jumping from one to the other at the seam. Never below the ground.
LiDAR heights are smoothed over SMOOTH_R along the way, and only among
themselves. The grade is not enforced: where a node needs more than
GRADE_MAX to reach the next, the pair is listed (report "steep", "seam"
where one end is the solve's); so is a node two records share at heights
more than STEP_MAX apart (report "joins").

x, z: the OSM line, except where it runs off the deck LiDAR sees (no
class-17 within ON_DECK of it but a run of deck within one road width
beside it, nearer this way's line than any other deck's): there the node
moves onto the deck. Nodes shared with another road never move, and a move
tapers out over TAPER towards them, so junctions stay joined.

Relations:
  - twin_of: the ways bridges._couple ties side by side that bridges._twins
    calls one divided road, kept only where LiDAR measures the two within
    TWIN_STEP of each other over TWIN_AGREE of the length both are measured
    side by side (with --from solver, kept as seeded). TWIN_STEP is wider
    than a step: two carriageways of one road differ by their crossfall
    and superelevation (0.3 to 1.2 m measured), and decks_mesh.py draws a
    kept pair as one surface sloping across between their heights. A list: OSM cuts a
    carriageway into several ways.
  - merges / splits: where a way's end lands on another deck way that
    carries on through the node: "into"/"from" the way, "at_s" along this
    one, "into_s"/"from_s" along that one, "over" how far back from the
    join the two run within their half widths (the gore), at most FLAT_MAX.
    A way ending at the end of a way that carries it on is "continues",
    where the two put the shared node within STEP_MAX of each other; one
    further apart is a join (report "joins"), not a continuation: one of
    them measured the wrong deck, and drawn as one deck it is a cliff.
  - source: "lidar" when at least half the record's nodes are lidar or
    interp, else "solver"; "hand" for a record edited by hand. A re-seed
    keeps every "hand" record as it is and replaces only the rest, and the
    report is computed with those hand heights, so it lists what is drawn.
  - "fills" (optional, top level): hand-placed seeds {id, x, z, note} for
    junction holes no gore closes; decks_mesh fills the enclosed hole that
    contains each seed. A re-seed keeps them as they are.

LiDAR: U.S. Geological Survey 3D Elevation Program, public domain.
Map data (c) OpenStreetMap contributors, ODbL.
"""
import argparse
import json
import os
import sys

import numpy as np
import shapely
from shapely.geometry import LineString

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bridges  # noqa: E402
from bridges import CLEAR, FLAT_MAX, GRADE_MAX, MIN_HEIGHT, RUNOUT, STEP_MAX  # noqa: E402
from osm_city import MEDIAN  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIDAR = os.path.join(ROOT, "data", "blockouts", "new_orleans_lidar", "lidar_decks.npz")
ALONG = 5.0  # a node's returns: this far along the way either side
MIN_RETURNS = 20  # fewer deck returns than this is no measurement
PERCENTILE = 20.0
LAYER_GAP = 1.5  # returns this far apart in height are two decks, not one
GROUND_R = 15.0  # local ground: median class 2 within this
GROUND_MIN = 5  # ground returns needed; short of it the radius doubles
GROUND_R_MAX = 120.0
INTERP_MAX = 60.0
SMOOTH_R = 5.0
SKIP = 3.0  # _choose: what leaving a measured node unchosen costs, in metres
STEEP_COST = 20.0  # _choose: per metre of rise past GRADE_MAX
REACH = 40  # _choose: how many measured nodes one step may pass over
STEEP_DS = 2.0  # grades are read over pairs of nodes at least this far apart
ON_DECK = 1.5  # a node is on the deck with ON_DECK_N returns this near its line
ON_DECK_N = 10
BIN = 1.0  # deck runs beside the line, in bins this wide
BIN_N = 3
TAPER = 20.0
TWIN_AGREE = 0.8
TWIN_STEP = 1.5
UNDER = 2.0  # a deck the solve puts this much above a node is over it
EDGE = 0.5
CELL = 8.0


class Grid:
    """Points bucketed in CELL squares; near() returns the indices of those
    within a square of half side r round a point (a superset of the disc)."""

    def __init__(self, x, z, cell=CELL):
        self.cell = cell
        ix, iz = np.floor(x / cell).astype(np.int64), np.floor(z / cell).astype(np.int64)
        self.ox, self.oz = (int(ix.min()), int(iz.min())) if len(x) else (0, 0)
        ix, iz = ix - self.ox, iz - self.oz
        self.nx, self.nz = (int(ix.max()) + 1, int(iz.max()) + 1) if len(x) else (0, 0)
        key = ix * self.nz + iz
        order = np.argsort(key, kind="stable")
        self.key, self.idx = key[order], order

    def near(self, x, z, r):
        i0, i1 = int(np.floor((x - r) / self.cell)) - self.ox, int(np.floor((x + r) / self.cell)) - self.ox
        j0, j1 = int(np.floor((z - r) / self.cell)) - self.oz, int(np.floor((z + r) / self.cell)) - self.oz
        i0, i1, j0, j1 = max(i0, 0), min(i1, self.nx - 1), max(j0, 0), min(j1, self.nz - 1)
        out = []
        for i in range(i0, i1 + 1):
            a = np.searchsorted(self.key, i * self.nz + j0)
            b = np.searchsorted(self.key, i * self.nz + j1, side="right")
            if b > a:
                out.append(self.idx[a:b])
        return np.concatenate(out) if out else np.zeros(0, np.int64)


class Lidar:
    def __init__(self, path, city, bounds):
        import lidar_fetch
        x, z, h, c, self.meta = lidar_fetch.load(path, city)
        x0, z0, x1, z1 = bounds
        m = (x > x0) & (x < x1) & (z > z0) & (z < z1)
        x, z, h, c = x[m], z[m], h[m].astype(np.float64), c[m]
        d, g = c == 17, c == 2
        self.dx, self.dz, self.dh = x[d], z[d], h[d]
        self.gx, self.gz, self.gh = x[g], z[g], h[g]
        self.deck, self.ground = Grid(self.dx, self.dz), Grid(self.gx, self.gz)
        self.ground_all = float(np.median(self.gh)) if len(self.gh) else 0.0
        self._segs = {}  # id(line) -> its vertices and per-segment boxes (_near_part)
        print("decks: lidar %d deck returns, %d ground in the map (ground median %.2f m)"
              % (len(self.dx), len(self.gx), self.ground_all), flush=True)

    def band(self, p, t, half_across, along=ALONG, under=()):
        """Deck returns within along of p along t and half_across across it,
        less those on the decks over it (under: (line, half width) each):
        (across offset, height)."""
        r = float(np.hypot(along, half_across))
        i = self.deck.near(p[0], p[1], r)
        if not len(i):
            return np.zeros(0), np.zeros(0)
        vx, vz = self.dx[i] - p[0], self.dz[i] - p[1]
        a, c = vx * t[0] + vz * t[1], -vx * t[1] + vz * t[0]
        m = (np.abs(a) <= along) & (np.abs(c) <= half_across)
        if under and m.any():
            # Only the returns still in the band are tested, each against
            # only the stretch of the line that can come within half of
            # it: a line's distance to a point is the least of its
            # segments', so dropping segments that cannot be the nearest
            # leaves every distance as it was.
            sel = np.flatnonzero(m)
            pts = shapely.points(self.dx[i[sel]], self.dz[i[sel]])
            keep = np.ones(len(sel), bool)
            for line, half in under:
                part = self._near_part(line, p, r + half + 1.0)
                if part is not None:
                    keep &= shapely.distance(part, pts) > half
            m[sel] = keep
        return c[m], self.dh[i][m]

    def _near_part(self, line, p, reach):
        """The segments of line whose bounding boxes come within reach of
        p, as one geometry (None where there are none): every segment
        that can be the nearest to a point within reach - half of p."""
        seg = self._segs.get(id(line))
        if seg is None:
            xy = shapely.get_coordinates(line)
            a, b = xy[:-1], xy[1:]
            seg = (xy, np.minimum(a, b), np.maximum(a, b), line)  # line kept so its id stays its own
            self._segs[id(line)] = seg
        xy, lo, hi, _ = seg
        gx = np.maximum(np.maximum(lo[:, 0] - p[0], p[0] - hi[:, 0]), 0.0)
        gz = np.maximum(np.maximum(lo[:, 1] - p[1], p[1] - hi[:, 1]), 0.0)
        k = np.flatnonzero(gx * gx + gz * gz <= reach * reach)
        if not len(k):
            return None
        if k[-1] - k[0] + 1 == len(k):
            return shapely.linestrings(xy[k[0]:k[-1] + 2])
        cut = np.flatnonzero(np.diff(k) > 1) + 1
        return shapely.multilinestrings([shapely.linestrings(xy[g[0]:g[-1] + 2]) for g in np.split(k, cut)])

    def ground_at(self, p):
        r = GROUND_R
        while r <= GROUND_R_MAX:
            i = self.ground.near(p[0], p[1], r)
            if len(i):
                d = np.hypot(self.gx[i] - p[0], self.gz[i] - p[1]) <= r
                if d.sum() >= GROUND_MIN:
                    return float(np.median(self.gh[i][d]))
            r *= 2
        return self.ground_all


def layers(h):
    """The heights h split where they part by LAYER_GAP; each layer of at
    least MIN_RETURNS as (PERCENTILE height, count)."""
    if len(h) < MIN_RETURNS:
        return []
    h = np.sort(h)
    cuts = np.flatnonzero(np.diff(h) > LAYER_GAP) + 1
    return [(float(np.percentile(g, PERCENTILE)), len(g)) for g in np.split(h, cuts) if len(g) >= MIN_RETURNS]


def tangents(p):
    d = np.zeros_like(p)
    d[1:-1] = p[2:] - p[:-2]
    d[0], d[-1] = p[1] - p[0], p[-1] - p[-2]
    n = np.hypot(d[:, 0], d[:, 1])
    return d / np.maximum(n, 1e-9)[:, None]


def cumlen(p):
    return np.concatenate([[0.0], np.cumsum(np.hypot(*(p[1:] - p[:-1]).T))])


def _choose(s, cands):
    """Which candidate height each node takes (None for none): the path
    through the nodes' candidates that costs least, where a step costs the
    height it climbs, STEEP_COST per metre of that past GRADE_MAX over its
    length, and SKIP per measured node it passes over unchosen."""
    meas = [k for k, c in enumerate(cands) if c]
    if not meas:
        return [None] * len(s)
    states = [(m, j, cands[k][j]) for m, k in enumerate(meas) for j in range(len(cands[k]))]
    sm = np.array([s[meas[m]] for m, _, _ in states])
    hm = np.array([h for _, _, h in states])
    mm = np.array([m for m, _, _ in states])
    nm = len(meas)
    best = np.full(len(states), np.inf)
    back = np.full(len(states), -1)
    first = np.searchsorted(mm, np.arange(nm))
    for x in range(len(states)):
        m = mm[x]
        best[x] = SKIP * m
        lo = first[max(0, m - REACH)]
        hi = first[m]
        if hi > lo:
            ds = np.maximum(sm[x] - sm[lo:hi], 1e-3)
            dh = np.abs(hm[x] - hm[lo:hi])
            cost = best[lo:hi] + dh + STEEP_COST * np.maximum(0.0, dh - GRADE_MAX * ds) + SKIP * (m - mm[lo:hi] - 1)
            j = int(np.argmin(cost))
            if cost[j] < best[x]:
                best[x], back[x] = cost[j], lo + j
    total = best + SKIP * (nm - 1 - mm)
    x = int(np.argmin(total))
    out = [None] * len(s)
    while x >= 0:
        out[meas[mm[x]]] = float(hm[x])
        x = int(back[x])
    return out


def _runs(mask):
    out, k = [], 0
    while k < len(mask):
        if mask[k]:
            e = k
            while e + 1 < len(mask) and mask[e + 1]:
                e += 1
            out.append((k, e))
            k = e + 1
        else:
            k += 1
    return out


def _over_it(r, p, deck_tree, deck_lines, deck_hs, recs):
    """Per node, the decks over it: those the solve puts more than UNDER
    above the node, where their footprint comes within reach of its band,
    each as (deck index, line, half width + EDGE, where along it)."""
    out = [()] * len(p)
    reach = r["width"] / 2 + ALONG
    for k in range(len(p)):
        q = shapely.points(p[k])
        got = []
        for j in deck_tree.query(q, predicate="dwithin", distance=reach + 15.0):
            b = recs[j]
            if b is r:
                continue
            line = deck_lines[j]
            if shapely.distance(line, q) > reach + b["width"] / 2:
                continue
            t = float(shapely.line_locate_point(line, q))
            if float(np.interp(t, b["s0"], deck_hs[j])) > r["hs"][k] + UNDER:
                got.append((int(j), line, b["width"] / 2 + EDGE, t))
        out[k] = tuple(got)
    return out


def _shift(lidar, p, t, width, pinned, own_line, deck_tree, deck_lines, wi_of_line, wi, over):
    """Per node, how far across (along the left normal) the measured deck
    lies off the OSM line, 0 where the line is on it; a run of nodes must
    agree (a running median of 5), and it tapers to 0 over TAPER towards
    the pinned nodes."""
    n = len(p)
    raw = np.zeros(n)
    for k in range(n):
        if pinned[k]:
            continue
        c, _ = lidar.band(p[k], t[k], width, under=over[k])
        if not len(c) or (np.abs(c) <= ON_DECK).sum() >= ON_DECK_N:
            continue
        nb = int(np.ceil(width / BIN))
        cnt = np.bincount(np.clip(np.floor(c / BIN).astype(int) + nb, 0, 2 * nb - 1), minlength=2 * nb)
        occ = cnt >= BIN_N
        for i in range(1, 2 * nb - 1):  # a one-bin hole is still deck
            if not occ[i] and occ[i - 1] and occ[i + 1]:
                occ[i] = True
        best = None
        for a, b in _runs(occ):
            lo, hi = (a - nb) * BIN, (b + 1 - nb) * BIN
            if hi - lo < min(4.0, width / 2):
                continue
            near = lo if lo > 0 else (hi if hi < 0 else 0.0)
            if best is None or abs(near) < abs(best[0]):
                best = (near, lo, hi)
        if best is None:
            continue
        near, lo, hi = best
        half = min(width / 2, (hi - lo) / 2)
        off = near + half if near > 0 else near - half
        q = p[k] + off * np.array([-t[k][1], t[k][0]])
        qp = shapely.points(q)
        mine = shapely.distance(own_line, qp)
        others = [j for j in deck_tree.query(qp, predicate="dwithin", distance=mine) if wi_of_line[j] != wi]
        if any(shapely.distance(deck_lines[j], qp) < mine for j in others):
            continue
        raw[k] = off
    med = np.array([np.median(raw[max(0, k - 2):k + 3]) for k in range(n)])
    s = cumlen(p)
    pins = s[pinned]
    if len(pins):
        d = np.min(np.abs(s[:, None] - pins[None, :]), axis=1)
        med *= np.clip(d / TAPER, 0.0, 1.0)
    return med


def measure(lidar, recs, deck_tree, deck_lines, wi_of_line, shared):
    """Moves each record's nodes onto the measured deck and measures them;
    fills rec["h"], rec["src"], rec["cands"] (relative), rec["shift"].

    LiDAR sees the top deck. Where the solve puts another deck over a node
    (where the node lies once moved onto its deck), the returns on that deck's footprint are dropped from the node's band,
    and so is any layer left at the height that deck measures there (its
    deck reaching past its footprint): the deck over a node is never the
    node's own."""
    deck_hs = [r["hs"] for r in recs]
    for r in recs:
        r["s0"] = cumlen(r["p"])
    for r in recs:
        p = r["p"]
        t = tangents(p)
        own = LineString(p)
        pinned = np.array([i in shared for i in r["ids"]])
        over = _over_it(r, p, deck_tree, deck_lines, deck_hs, recs)
        masks = [tuple((line, half) for _, line, half, _ in o) for o in over]
        off = _shift(lidar, p, t, r["width"], pinned, own, deck_tree, deck_lines, wi_of_line, r["wi"], masks)
        p = p + off[:, None] * np.stack([-t[:, 1], t[:, 0]], axis=1)
        if off.any():
            # Measured where it now lies: a node moved towards another deck
            # can come under it.
            over = _over_it(r, p, deck_tree, deck_lines, deck_hs, recs)
            masks = [tuple((line, half) for _, line, half, _ in o) for o in over]
        r["p"], r["shift"], r["over"] = p, off, over
        t = tangents(p)
        cands = []
        for k in range(len(p)):
            _, hh = lidar.band(p[k], t[k], r["width"] / 2, under=masks[k])
            ls = layers(hh)
            g = lidar.ground_at(p[k]) if ls else 0.0
            cands.append([v - g for v, _ in ls])
        r["cands"] = cands
        r["first"] = np.array([np.nan if v is None else v for v in _choose(cumlen(p), cands)])
    for r in recs:
        for k, o in enumerate(r["over"]):
            for j, _, _, t in o:
                b = recs[j]
                hb = float(np.interp(t, b["s0"], b["first"]))
                if not np.isnan(hb):
                    r["cands"][k] = [v for v in r["cands"][k] if abs(v - hb) > LAYER_GAP]
    for r in recs:
        p, cands = r["p"], r["cands"]
        s = cumlen(p)
        chosen = _choose(s, cands)
        h = np.array(r["hs"], float)
        src = ["solver"] * len(p)
        got = [k for k, v in enumerate(chosen) if v is not None]
        for k in got:
            h[k], src[k] = chosen[k], "lidar"
        for a, b in zip(got, got[1:]):
            if b - a > 1 and s[b] - s[a] <= INTERP_MAX:
                for k in range(a + 1, b):
                    f = (s[k] - s[a]) / max(s[b] - s[a], 1e-9)
                    h[k], src[k] = chosen[a] + (chosen[b] - chosen[a]) * f, "interp"
        lid = np.array([x == "lidar" for x in src])
        sm = h.copy()
        for a, b in _runs(lid):
            for k in range(a, b + 1):
                j = np.arange(a, b + 1)
                w = np.maximum(0.0, 1.0 - np.abs(s[j] - s[k]) / SMOOTH_R)
                sm[k] = float((w * h[j]).sum() / w.sum())
        r["h"], r["src"] = sm, src
    _anchor(recs)


def _anchor(recs):
    """The solver nodes' heights moved onto the measured ones. Over the deck
    nodes as one graph (records joined at the nodes they share, each pair of
    neighbours along a record an edge weighted 1 / its length), the offset
    h - hs is fixed at every measured node, 0 at every node the solve
    leaves on the ground (off a bridge), and harmonic at every other solver
    node: on the straight line along s between the measured nodes either
    side of a run, the one offset carried on where a run has measured nodes
    on one side only, through the joins into the records it shares nodes
    with. A solver node with no measured node anywhere on its connected
    decks keeps the solve's height. Heights never go below the ground."""
    key, fixed, c0 = {}, [], []
    vid = []
    for r in recs:
        vs = []
        for k, i in enumerate(r["ids"]):
            if i not in key:
                key[i] = len(key)
                fixed.append(False)
                c0.append(0.0)
            v = key[i]
            if r["src"][k] != "solver" and not fixed[v]:
                fixed[v], c0[v] = True, float(r["h"][k] - r["hs"][k])
            elif r["hs"][k] <= MIN_HEIGHT and not r["bridge"]:
                fixed[v] = True  # the solve's ground: offset 0, unless measured
            vs.append(v)
        vid.append(vs)
    n = len(key)
    fixed, c0 = np.array(fixed), np.array(c0)
    nbr = [dict() for _ in range(n)]
    for r, vs in zip(recs, vid):
        s = cumlen(r["p"])
        for k in range(len(vs) - 1):
            a, b = vs[k], vs[k + 1]
            if a != b:
                w = 1.0 / max(s[k + 1] - s[k], 1e-3)
                nbr[a][b] = nbr[a].get(b, 0.0) + w
                nbr[b][a] = nbr[b].get(a, 0.0) + w
    comp = np.full(n, -1)
    for v0 in range(n):  # components; one with no measured node keeps hs
        if comp[v0] >= 0:
            continue
        comp[v0], stack, members = v0, [v0], [v0]
        while stack:
            v = stack.pop()
            for u in nbr[v]:
                if comp[u] < 0:
                    comp[u] = v0
                    stack.append(u)
                    members.append(u)
        if not fixed[members].any():
            fixed[members] = True
    free = np.flatnonzero(~fixed)
    c = c0.copy()
    if len(free):
        # The system is sparse (a node's row holds its few neighbours), so
        # it is solved as one: the same entries, summed in the same order.
        from scipy.sparse import csc_matrix
        from scipy.sparse.linalg import spsolve
        at = {int(v): m for m, v in enumerate(free)}
        diag, rhs = np.zeros(len(free)), np.zeros(len(free))
        rows, cols, vals = [], [], []
        for m, v in enumerate(free):
            for u, w in nbr[v].items():
                diag[m] += w
                if u in at:
                    rows.append(m)
                    cols.append(at[u])
                    vals.append(-w)
                else:
                    rhs[m] += w * c0[u]
        idx = np.arange(len(free))
        A = csc_matrix((np.concatenate([diag, vals]), (np.concatenate([idx, rows]).astype(np.int64),
                                                     np.concatenate([idx, cols]).astype(np.int64))),
                       shape=(len(free), len(free)))
        c[free] = spsolve(A, rhs)
    for r, vs in zip(recs, vid):
        for k, v in enumerate(vs):
            if r["src"][k] == "solver":
                r["h"][k] = max(0.0, float(r["hs"][k] + c[v]))


def steep(r):
    """Pairs of nodes, at least STEEP_DS apart, between which the record
    climbs faster than GRADE_MAX."""
    s, h, out = cumlen(r["p"]), r["h"], []
    k = 0
    while k < len(s) - 1:
        j = int(np.searchsorted(s, s[k] + STEEP_DS))
        if j >= len(s):
            break
        g = abs(h[j] - h[k]) / (s[j] - s[k])
        if g > GRADE_MAX:
            out.append({"way": r["way"], "s0": round(float(s[k]), 1), "s1": round(float(s[j]), 1),
                        "x": round(float(r["p"][k][0]), 1), "z": round(float(r["p"][k][1]), 1),
                        "h0": round(float(h[k]), 2), "h1": round(float(h[j]), 2), "grade": round(float(g), 3),
                        "src": [r["src"][k], r["src"][j]], "seam": (r["src"][k] == "solver") != (r["src"][j] == "solver")})
        k = j
    return out


def joins(recs):
    """Nodes two records share that they put more than STEP_MAX apart in
    height: one of them measured the wrong deck, or none."""
    at = {}
    for r in recs:
        for k, i in enumerate(r["ids"]):
            at.setdefault(i, []).append((r, k))
    out = []
    for i, u in at.items():
        hs = [float(r["h"][k]) for r, k in u]
        if len(u) > 1 and max(hs) - min(hs) > STEP_MAX:
            r, k = u[0]
            out.append({"x": round(float(r["p"][k][0]), 1), "z": round(float(r["p"][k][1]), 1),
                        "spread": round(max(hs) - min(hs), 2),
                        "ways": [{"way": r2["way"], "h": round(float(r2["h"][k2]), 2), "src": r2["src"][k2]} for r2, k2 in u]})
    out.sort(key=lambda j: -j["spread"])
    return out


def _dir(p, k, step):
    """Unit direction from node k a little way along the record (step +1 or -1)."""
    s = cumlen(p)
    j = k
    while 0 <= j + step < len(p) and abs(s[j] - s[k]) < 10.0:
        j += step
    d = p[j] - p[k]
    return d / max(float(np.hypot(*d)), 1e-9)


def _over(r, k, step, line, half):
    """How far from node k along r (step +1 or -1) r stays within half of line."""
    s = cumlen(r["p"])
    j = k
    while 0 <= j + step < len(r["p"]) and abs(s[j + step] - s[k]) <= FLAT_MAX:
        if shapely.distance(line, shapely.points(r["p"][j + step])) > half:
            break
        j += step
    return float(abs(s[j] - s[k]))


def relations(recs):
    """merges / splits / continues from the nodes records share; continues
    only where the two records agree on the shared node (see the module
    docstring)."""
    at = {}
    for ri, r in enumerate(recs):
        for k, i in enumerate(r["ids"]):
            at.setdefault(i, []).append((ri, k))
    lines = [LineString(r["p"]) for r in recs]
    for r in recs:
        r["merges"], r["splits"], r["continues"] = [], [], []

    def level(ra, ka, rb, kb):
        return abs(float(recs[ra]["h"][ka]) - float(recs[rb]["h"][kb])) <= STEP_MAX
    for i, users in at.items():
        if len(users) < 2 or not any(k in (0, len(recs[ri]["ids"]) - 1) for ri, k in users):
            continue
        arms = []  # (record, node, direction away, is an end)
        for ri, k in users:
            last = len(recs[ri]["ids"]) - 1
            if k > 0:
                arms.append((ri, k, _dir(recs[ri]["p"], k, -1), k == last))
            if k < last:
                arms.append((ri, k, _dir(recs[ri]["p"], k, 1), k == 0))
        if len(arms) == 2:
            (ra, ka, _, ea), (rb, kb, _, eb) = arms
            if ra != rb and ea and eb and level(ra, ka, rb, kb):
                recs[ra]["continues"].append({"way": recs[rb]["way"], "at_s": round(float(cumlen(recs[ra]["p"])[ka]), 1)})
                recs[rb]["continues"].append({"way": recs[ra]["way"], "at_s": round(float(cumlen(recs[rb]["p"])[kb]), 1)})
            continue
        through = [(a, b) for a in range(len(arms)) for b in range(a + 1, len(arms))
                   if arms[a][0] == arms[b][0] and not arms[a][3]]
        pairs = through or [(a, b) for a in range(len(arms)) for b in range(a + 1, len(arms)) if arms[a][0] != arms[b][0]]
        if not pairs:
            continue
        ta, tb = max(pairs, key=lambda q: -float(arms[q[0]][2] @ arms[q[1]][2]))
        if arms[ta][0] != arms[tb][0] and level(arms[ta][0], arms[ta][1], arms[tb][0], arms[tb][1]):
            for x, y in ((ta, tb), (tb, ta)):
                ri, k = arms[x][0], arms[x][1]
                recs[ri]["continues"].append({"way": recs[arms[y][0]]["way"], "at_s": round(float(cumlen(recs[ri]["p"])[k]), 1)})
        for x, (ri, k, d, end) in enumerate(arms):
            if x in (ta, tb) or not end or ri in (arms[ta][0], arms[tb][0]):
                continue
            tx = max((ta, tb), key=lambda q: -float(d @ arms[q][2]))
            ti, tk = arms[tx][0], arms[tx][1]
            half = (recs[ri]["width"] + recs[ti]["width"]) / 2
            step = -1 if k else 1
            entry = {"at_s": round(float(cumlen(recs[ri]["p"])[k]), 1),
                     "over": round(_over(recs[ri], k, step, lines[ti], half), 1)}
            s_t = round(float(cumlen(recs[ti]["p"])[tk]), 1)
            if k:
                recs[ri]["merges"].append({"into": recs[ti]["way"], **entry, "into_s": s_t})
            else:
                recs[ri]["splits"].append({"from": recs[ti]["way"], **entry, "from_s": s_t})


def twins(recs, coupled, ways, by_wi, measured):
    """twin_of per record, and the check of every seeded pair."""
    checks = []
    for r in recs:
        r["twin_of"] = []
    for a, b in sorted(coupled):
        if a not in by_wi or b not in by_wi or not bridges._twins(ways[a], ways[b]):
            continue
        ra, rb = by_wi[a], by_wi[b]
        if not measured:
            ra["twin_of"].append(rb["way"])
            rb["twin_of"].append(ra["way"])
            checks.append({"ways": [ra["way"], rb["way"]], "shared": None, "agree": None, "kept": True})
            continue
        shared = agree = 0.0
        for A, B in ((ra, rb), (rb, ra)):
            lb, sb = LineString(B["p"]), cumlen(B["p"])
            sa = cumlen(A["p"])
            wgt = np.gradient(sa) if len(sa) > 1 else np.ones(1)
            half = (A["width"] + B["width"]) / 2 + 2 * MEDIAN
            for k in range(len(A["p"])):
                q = shapely.points(A["p"][k])
                if A["src"][k] != "lidar" or shapely.distance(lb, q) > half:
                    continue
                t = float(shapely.line_locate_point(lb, q))
                m = int(np.clip(np.searchsorted(sb, t), 1, len(sb) - 1))
                if B["src"][m - 1] != "lidar" or B["src"][m] != "lidar":
                    continue
                f = (t - sb[m - 1]) / max(sb[m] - sb[m - 1], 1e-9)
                hb = B["h"][m - 1] + (B["h"][m] - B["h"][m - 1]) * f
                shared += wgt[k]
                agree += wgt[k] * (abs(A["h"][k] - hb) < TWIN_STEP)
        kept = shared > 0 and agree >= TWIN_AGREE * shared
        if kept:
            ra["twin_of"].append(rb["way"])
            rb["twin_of"].append(ra["way"])
        checks.append({"ways": [ra["way"], rb["way"]], "shared": round(float(shared), 1),
                       "agree": round(float(agree / shared), 3) if shared else None, "kept": bool(kept)})
    return checks


def clearance(recs, ways, deck_wi, rails):
    """Every crossing of a record's centre line with another record or with
    a road or railway on the ground, where the two stand less than CLEAR
    apart."""
    segs, info = [], []
    for ri, r in enumerate(recs):
        for k in range(len(r["p"]) - 1):
            segs.append(LineString(r["p"][k:k + 2]))
            info.append((ri, k))
    for wi, w in enumerate(ways):
        if wi in deck_wi or w["width"] <= 0:
            continue
        for k in range(len(w["pts"]) - 1):
            segs.append(LineString(w["pts"][k:k + 2]))
            info.append((-1 - wi, k))
    for r in recs:  # a deck way's stretches on the ground, outside its record
        for q in r["rest"]:
            for k in range(len(q) - 1):
                segs.append(LineString(q[k:k + 2]))
                info.append((-1 - r["wi"], k))
    for p in rails:
        for k in range(len(p) - 1):
            segs.append(LineString(p[k:k + 2]))
            info.append((None, k))
    tree = shapely.STRtree(segs)
    nrec = sum(len(r["p"]) - 1 for r in recs)
    if not nrec:
        return []  # a map with no decks
    left, right = tree.query(segs[:nrec], predicate="intersects")
    cums = [cumlen(r["p"]) for r in recs]
    out = []

    def h_at(ri, k, pt):
        r = recs[ri]
        a, b = r["p"][k], r["p"][k + 1]
        f = float(np.hypot(*(pt - a)) / max(np.hypot(*(b - a)), 1e-9))
        return float(r["h"][k] + (r["h"][k + 1] - r["h"][k]) * f), r["src"][k] if f < 0.5 else r["src"][k + 1]

    for i, j in zip(left, right):
        ri, k = info[i]
        rj, kj = info[j]
        if i == j or (rj is not None and rj >= 0 and (rj < ri or (rj == ri))):
            continue
        x = shapely.intersection(segs[i], segs[j])
        if x.geom_type != "Point":
            continue
        pt = np.array([x.x, x.y])
        ends = [np.asarray(c) for c in segs[i].coords] + [np.asarray(c) for c in segs[j].coords]
        if any(float(np.hypot(*(pt - e))) < 0.5 for e in ends[:2]) and any(float(np.hypot(*(pt - e))) < 0.5 for e in ends[2:]):
            continue  # they meet at a node
        ha, sa = h_at(ri, k, pt)
        if rj is not None and rj >= 0:
            hb, sb = h_at(rj, kj, pt)
            other = {"way": recs[rj]["way"], "name": recs[rj]["name"], "deck": True}
        elif rj is None:
            hb, sb, other = 0.0, "ground", {"way": None, "name": "railway", "deck": False}
        else:
            w = ways[-1 - rj]
            hb, sb, other = 0.0, "ground", {"way": w["osm"], "name": w["name"], "deck": False}
        if max(ha, hb) <= MIN_HEIGHT or abs(ha - hb) >= CLEAR:
            continue
        up, lo = ({"way": recs[ri]["way"], "name": recs[ri]["name"], "h": ha, "src": sa}, dict(other, h=hb, src=sb))
        if hb > ha:
            up, lo = lo, up
        da = segs[i].coords[1][0] - segs[i].coords[0][0], segs[i].coords[1][1] - segs[i].coords[0][1]
        db = segs[j].coords[1][0] - segs[j].coords[0][0], segs[j].coords[1][1] - segs[j].coords[0][1]
        sin = abs(da[0] * db[1] - da[1] * db[0]) / max(float(np.hypot(*da) * np.hypot(*db)), 1e-9)
        out.append({"x": round(float(pt[0]), 1), "z": round(float(pt[1]), 1), "clear": round(abs(ha - hb), 2),
                    "upper": {k2: (round(v, 2) if isinstance(v, float) else v) for k2, v in up.items()},
                    "lower": {k2: (round(v, 2) if isinstance(v, float) else v) for k2, v in lo.items()},
                    "sin": round(sin, 2)})
    out.sort(key=lambda c: c["clear"])
    return out


def _record_json(r):
    head = {k: r[k] for k in ("way", "name", "class", "width", "bridge", "layer", "source")}
    rel = {k: r[k] for k in ("twin_of", "merges", "splits", "continues")}
    rel["twin_of"] = rel["twin_of"] or None
    lines = ["  {" + json.dumps(head)[1:-1] + ","]
    lines.append('   "nodes": [')
    nodes = r["nodes"]
    for k, n in enumerate(nodes):
        lines.append("    " + json.dumps(n) + ("," if k < len(nodes) - 1 else ""))
    lines.append("   ],")
    extra = {k: v for k, v in r.items() if k not in head and k not in rel and k != "nodes"}
    tail = dict(rel, **extra)
    lines.append("   " + json.dumps(tail)[1:-1] + "}")
    return "\n".join(lines)


def write_decks(path, meta, records, fills=()):
    body = ",\n".join(_record_json(r) for r in records)
    tail = ""
    if fills:
        tail = ',\n "fills": [\n' + ",\n".join("  " + json.dumps(f) for f in fills) + "\n ]"
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("{" + json.dumps(meta)[1:-1] + ',\n "decks": [\n' + body + "\n ]" + tail + "}\n")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("raw")
    p.add_argument("out")
    p.add_argument("--from", dest="src", choices=("lidar", "solver"), default="lidar")
    p.add_argument("--lidar", help="lidar_decks.npz; default the raw dir's own (compress.py writes one), else the parish's")
    p.add_argument("--plot", action="append", default=[], help="name,x,z,r: height profiles near a spot")
    p.add_argument("--png-dir")
    a = p.parse_args()
    if a.lidar is None:
        own = os.path.join(a.raw, "lidar_decks.npz")
        a.lidar = own if os.path.exists(own) else LIDAR
    if os.path.normcase(os.path.abspath(a.out)) == os.path.normcase(os.path.join(ROOT, "data", "blockouts", "new_orleans")):
        sys.exit("decks: never write into data/blockouts/new_orleans")
    meta = json.load(open(os.path.join(a.out, "city.json"), encoding="utf-8"))
    ways, others, rails = bridges.read(a.raw, meta)
    osm_node = {}
    for w in ways:  # bridges.solve numbers nodes in this order
        for key, nid in zip(w["keys"], w["nodes"]):
            if key not in osm_node:
                osm_node[key] = (len(osm_node), nid)
    osm_of = {i: nid for i, nid in osm_node.values()}
    pos, height, _, _, coupled = bridges.solve(ways, others, rails)

    region = shapely.buffer(bridges._region(meta["boundary"]), RUNOUT)
    shapely.prepare(region)
    recs = []
    for wi, w in enumerate(ways):
        pts, ids = w["pts"], list(w["ids"])
        keep = np.concatenate([[True], np.hypot(*(pts[1:] - pts[:-1]).T) > 0.05])
        pts, ids = pts[keep], [i for i, k in zip(ids, keep) if k]
        if len(pts) < 2:
            continue
        hs = height[ids]
        high = (np.maximum(hs[:-1], hs[1:]) > MIN_HEIGHT) | w["bridge"]
        mid = (pts[:-1] + pts[1:]) / 2
        high &= shapely.contains_xy(region, mid[:, 0], mid[:, 1])
        if not high.any():
            continue
        recs.append({"wi": wi, "way": w["osm"], "name": w["name"], "class": w["cls"], "width": w["width"],
                     "bridge": w["bridge"], "layer": w["raw_layer"], "p": pts.astype(float), "ids": ids,
                     "hs": hs.astype(float), "high": high})
    deck_wi = {r["wi"] for r in recs}
    used = {}
    for w in ways:
        for i in set(w["ids"]):
            used[i] = used.get(i, 0) + 1
    shared = {i for i, c in used.items() if c > 1}
    print("decks: %d ways in the deck set (%d bridges), %d nodes" % (len(recs), sum(r["bridge"] for r in recs),
                                                                    sum(len(r["p"]) for r in recs)), flush=True)

    measured = a.src == "lidar" and bool(recs)  # a map with no decks has nothing to measure
    if measured:
        lo = np.min([r["p"].min(0) for r in recs], axis=0) - 200
        hi = np.max([r["p"].max(0) for r in recs], axis=0) + 200
        lidar = Lidar(a.lidar, meta, (lo[0], lo[1], hi[0], hi[1]))
        deck_lines = [LineString(r["p"]) for r in recs]
        tree = shapely.STRtree(deck_lines)
        measure(lidar, recs, tree, deck_lines, [r["wi"] for r in recs], shared)
    else:
        for r in recs:
            r["h"], r["src"], r["cands"], r["shift"] = r["hs"].copy(), ["solver"] * len(r["p"]), [[] for _ in r["p"]], np.zeros(len(r["p"]))

    # Crop each record to its raised stretch, measured where measured.
    for r in recs:
        h, p = r["h"], r["p"]
        mid = (p[:-1] + p[1:]) / 2
        high = ((np.maximum(h[:-1], h[1:]) > MIN_HEIGHT) | r["bridge"]) & shapely.contains_xy(region, mid[:, 0], mid[:, 1])
        if not high.any():
            high = r["high"]
        k0, k1 = int(np.flatnonzero(high)[0]), int(np.flatnonzero(high)[-1]) + 1
        r["full_s"] = cumlen(p)
        r["crop"] = (k0, k1)
        r["rest"] = [q for q in (p[:k0 + 1], p[k1:]) if len(q) > 1]
        for key in ("p", "h", "hs", "shift"):
            r[key] = r[key][k0:k1 + 1]
        for key in ("ids", "src", "cands"):
            r[key] = r[key][k0:k1 + 1]
    by_wi = {r["wi"]: r for r in recs}
    checks = twins(recs, coupled, ways, by_wi, measured)
    relations(recs)
    # The report lists what is drawn: a hand record's heights stand in for
    # the seed's on the same line, so a crossing fixed by hand is not
    # listed again on the next seed.
    path = os.path.join(a.out, "decks.json")
    old = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    for r in recs:
        d = next((d for d in old.get("decks", []) if d["way"] == r["way"] and d.get("source") == "hand"), None)
        if d and len(d["nodes"]) == len(r["p"]) and np.allclose([[n["x"], n["z"]] for n in d["nodes"]], r["p"], atol=0.05):
            r["h"] = np.array([n["h"] for n in d["nodes"]], float)
            r["src"] = [n["src"] for n in d["nodes"]]
    steeps = [x for r in recs for x in steep(r)]
    joined = joins(recs)
    clear = clearance(recs, ways, deck_wi, rails)

    records = []
    for r in recs:
        s = cumlen(r["p"])
        nodes = []
        for k in range(len(r["p"])):
            nid = osm_of.get(r["ids"][k])
            nodes.append({"id": nid, "x": round(float(r["p"][k][0]), 2), "z": round(float(r["p"][k][1]), 2),
                          "s": round(float(s[k]), 2), "h": round(float(r["h"][k]), 2), "src": r["src"][k],
                          "hs": round(float(r["hs"][k]), 2)})
        good = sum(x in ("lidar", "interp") for x in r["src"])
        records.append({"way": r["way"], "name": r["name"], "class": r["class"], "width": r["width"],
                        "bridge": r["bridge"], "layer": r["layer"], "source": "lidar" if 2 * good >= len(nodes) else "solver",
                        "nodes": nodes, "twin_of": r["twin_of"], "merges": r["merges"], "splits": r["splits"],
                        "continues": r["continues"]})
        r["record"] = records[-1]

    path = os.path.join(a.out, "decks.json")
    kept, fills = 0, []
    if os.path.exists(path):
        old = json.load(open(path, encoding="utf-8"))
        hand = {d["way"]: d for d in old.get("decks", []) if d.get("source") == "hand"}
        kept = len(hand)
        records = [hand.pop(d["way"], d) for d in records] + sorted(hand.values(), key=lambda d: d["way"])
        fills = old.get("fills", [])
    write_decks(path, {"format": 1, "origin": meta["origin"], "seeded_from": a.src,
                       "lidar": os.path.basename(a.lidar) if measured else None}, records, fills)

    srcs = {}
    for r in recs:
        for x in r["src"]:
            srcs[x] = srcs.get(x, 0) + 1
    shifted = [(r["way"], float(np.abs(r["shift"]).max())) for r in recs if np.abs(r["shift"]).max() > 0]
    report = {
        "nodes": srcs,
        "records": {"lidar": sum(d["source"] == "lidar" for d in records), "solver": sum(d["source"] == "solver" for d in records),
                    "hand": sum(d["source"] == "hand" for d in records)},
        "clearance": clear,
        "steep": steeps,
        "joins": joined,
        "twins": checks,
        "shifted": [{"way": w, "most": round(m, 2), "nodes": int((np.abs(by_way["shift"]) > 0).sum())}
                    for (w, m), by_way in zip(shifted, [r for r in recs if np.abs(r["shift"]).max() > 0])],
        "merges": sum(len(d["merges"]) for d in records), "splits": sum(len(d["splits"]) for d in records),
        "continues": sum(len(d["continues"]) for d in records),
    }
    with open(os.path.join(a.out, "decks_report.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(report, f, indent=1)
    print("decks: nodes by source %s; records %s; %d hand records kept"
          % (json.dumps(srcs), json.dumps(report["records"]), kept), flush=True)
    print("decks: %d nodes moved onto the measured deck on %d ways (most %.1f m)"
          % (sum(x["nodes"] for x in report["shifted"]), len(shifted), max((m for _, m in shifted), default=0.0)), flush=True)
    print("decks: twins %d seeded, %d kept; merges %d, splits %d, continues %d"
          % (len(checks), sum(c["kept"] for c in checks), report["merges"], report["splits"], report["continues"]), flush=True)
    print("decks: %d stretches steeper than %.2f (%d of them where LiDAR hands over to the solve); "
          "%d shared nodes with heights more than %.1f m apart; %d crossings under %.1f m clearance"
          % (len(steeps), GRADE_MAX, sum(x["seam"] for x in steeps), len(joined), STEP_MAX, len(clear), CLEAR), flush=True)
    for c in clear:
        print("decks:   clear %5.2f m at (%7.1f, %7.1f): %s %s (%.1f %s) over %s %s (%.1f %s)"
              % (c["clear"], c["x"], c["z"], c["upper"]["way"], c["upper"]["name"][:24], c["upper"]["h"], c["upper"]["src"],
                 c["lower"]["way"], c["lower"]["name"][:24], c["lower"]["h"], c["lower"]["src"]), flush=True)
    if a.plot:
        plot(a.plot, a.png_dir, recs, clear, steeps)


def plot(spots, png_dir, recs, clear, steeps):
    """Per spot, a map of the records near it and each one's height profile:
    LiDAR layers offered (grey), chosen (orange), the solve (green), the
    record's h (blue), steep pairs (red) and short crossings (purple)."""
    from PIL import Image, ImageDraw
    os.makedirs(png_dir, exist_ok=True)
    pal = [(31, 119, 180), (214, 39, 40), (44, 160, 44), (148, 103, 189), (140, 86, 75), (227, 119, 194),
           (127, 127, 127), (188, 189, 34), (23, 190, 207), (255, 127, 14)]
    for spot in spots:
        name, sx, sz, rad = spot.split(",")
        sx, sz, rad = float(sx), float(sz), float(rad)
        near = []
        for r in recs:
            d = np.hypot(r["p"][:, 0] - sx, r["p"][:, 1] - sz)
            if (d <= rad).any():
                near.append((r, d <= rad * 1.3))
        near.sort(key=lambda q: -q[1].sum())
        near = near[:12]
        W, mapH, ph = 1400, 520, 230
        im = Image.new("RGB", (W, mapH + ph * len(near) + 10), (255, 255, 255))
        dr = ImageDraw.Draw(im)
        side = mapH - 20
        mp = Image.new("RGB", (side, side), (255, 255, 255))
        dm = ImageDraw.Draw(mp)
        k = side / (2 * rad * 1.3)

        def tm(x, z):
            return (x - sx + rad * 1.3) * k, (z - sz + rad * 1.3) * k
        dr.text((8, 8), "%s (%.0f, %.0f) r %.0f m: deck records, numbered as the panels below" % (name, sx, sz, rad), fill=(0, 0, 0))
        for n, (r, m) in enumerate(near):
            col = pal[n % len(pal)]
            pts = [tm(*q) for q in r["p"]]
            dm.line(pts, fill=col, width=3)
            mid = pts[len(pts) // 2]
            sel = np.flatnonzero(m)
            if len(sel):
                mid = pts[sel[len(sel) // 2]]
            dm.text((mid[0] + 4, mid[1] - 6), str(n), fill=col)
        for c in clear:
            if abs(c["x"] - sx) < rad * 1.3 and abs(c["z"] - sz) < rad * 1.3:
                X, Z = tm(c["x"], c["z"])
                dm.ellipse((X - 5, Z - 5, X + 5, Z + 5), outline=(128, 0, 160), width=2)
        dm.rectangle((0, 0, side - 1, side - 1), outline=(200, 200, 200))
        im.paste(mp, ((W - side) // 2, 10))
        for n, (r, m) in enumerate(near):
            y0 = mapH + n * ph
            s = cumlen(r["p"])
            sel = np.flatnonzero(m)
            a, b = max(0, sel[0] - 3), min(len(s) - 1, sel[-1] + 3)
            s0, s1 = s[a], max(s[b], s[a] + 1)
            hs_all = [v for c in r["cands"][a:b + 1] for v in c] + list(r["h"][a:b + 1]) + list(r["hs"][a:b + 1])
            hmin, hmax = min(0.0, min(hs_all)) - 1, max(hs_all) + 2
            L, R, T, B = 70, W - 20, y0 + 22, y0 + ph - 18

            def tp(sv, hv):
                return L + (sv - s0) / (s1 - s0) * (R - L), B - (hv - hmin) / (hmax - hmin) * (B - T)
            dr.rectangle((L, T, R, B), outline=(180, 180, 180))
            for hv in range(int(np.ceil(hmin)), int(hmax) + 1):
                if hv % 5 == 0:
                    X0, Y = tp(s0, hv)
                    dr.line((L, Y, R, Y), fill=(235, 235, 235))
                    dr.text((L - 30, Y - 6), "%d" % hv, fill=(90, 90, 90))
            src = {}
            for x in r["src"][a:b + 1]:
                src[x] = src.get(x, 0) + 1
            dr.text((L, y0 + 4), "%d: way %s %s (%s, w %.0f%s)  s %.0f-%.0f m  nodes %s  twin_of %s"
                    % (n, r["way"], r["name"][:34], r["class"], r["width"], ", bridge" if r["bridge"] else "", s0, s1,
                       json.dumps(src), r["twin_of"] or "-"), fill=pal[n % len(pal)])
            for kk in range(a, b + 1):
                for v in r["cands"][kk]:
                    X, Y = tp(s[kk], v)
                    dr.ellipse((X - 2, Y - 2, X + 2, Y + 2), fill=(170, 170, 170))
            dr.line([tp(s[kk], r["hs"][kk]) for kk in range(a, b + 1)], fill=(40, 170, 40), width=2)
            dr.line([tp(s[kk], r["h"][kk]) for kk in range(a, b + 1)], fill=(30, 80, 220), width=2)
            for kk in range(a, b + 1):
                if r["src"][kk] == "lidar":
                    X, Y = tp(s[kk], r["h"][kk])
                    dr.ellipse((X - 2, Y - 2, X + 2, Y + 2), fill=(240, 120, 20))
                elif r["src"][kk] == "interp":
                    X, Y = tp(s[kk], r["h"][kk])
                    dr.rectangle((X - 2, Y - 2, X + 2, Y + 2), outline=(240, 120, 20))
            for st in steeps:
                if st["way"] == r["way"] and s0 <= st["s0"] <= s1:
                    X0, Y0 = tp(st["s0"], st["h0"])
                    X1, Y1 = tp(st["s1"], st["h1"])
                    dr.line((X0, Y0, X1, Y1), fill=(220, 0, 0), width=4)
            for c in clear:
                for side in ("upper", "lower"):
                    if c[side]["way"] == r["way"]:
                        j = int(np.argmin(np.hypot(r["p"][:, 0] - c["x"], r["p"][:, 1] - c["z"])))
                        if a <= j <= b:
                            X, Y = tp(s[j], c[side]["h"])
                            dr.ellipse((X - 5, Y - 5, X + 5, Y + 5), outline=(128, 0, 160), width=2)
                            dr.text((X + 6, Y - 14), "%.1f" % c["clear"], fill=(128, 0, 160))
            dr.text((R - 520, B + 2), "grey: LiDAR layers  orange: chosen  green: solve  blue: h  red: steep  purple: short crossing",
                    fill=(90, 90, 90))
        im.save(os.path.join(png_dir, name + ".png"))
        print("decks: plot %s: %d records" % (name, len(near)), flush=True)


if __name__ == "__main__":
    main()

"""Phase 3b of COMPRESSION_PLAN.md (option 2): one ribbon between two
districts, assembled with them into a raw dir the city pipeline builds.

    python -I tools/blockout/parish_ribbon.py <segment dir> <raw dir> <district A> <district B> <out dir>
        [--identity]

Reads parish_districts.py's districts.json and parish_layout.py's
layout.json. <out dir> gets raw/ (features.json, bld_*.json, coast.json,
boundary.json, the map as osm_city.py reads it) and ribbon.json (the
road, the cross-blocks taken out, the gate). --identity writes the same
ground unmoved and uncut, the reference for preview.py.

The ribbon is the best real road between the two districts (a shortest
path, cheaper on bigger roads) and the blocks fronting it, at most DEPTH
deep. Points are placed by a frame along the road: s the distance along a
smoothed copy of it, u the signed distance across.

  - The two districts move rigidly by their layout translations.
  - A ribbon point at s <= s_a (still beside district A) moves with A; one
    at s >= s_b with B. In between the road is laid on a new centre line
    (bend()): the real road's own curvature, scaled along its length by a
    few percent and plus the smallest smooth correction that lands it on
    B's end with the real direction there, so the seams are the real
    streets, moved, and the road keeps its own bends.
  - Whole cross-blocks come out first, as much as makes the road's shape
    span the new chord. A cross-block is the ground between two through
    streets i and j (cross streets meeting the road from both sides): at
    each u it runs from street i to street j, so i stays, j goes, and
    everything past j at that u closes up onto i. The lowest scored go
    first, never 3 in a row, and none holding a landmark, a deck, a
    boulevard's median or cutting more than CUT_MAX buildings.
  - Buildings move rigidly (turned with the road) by the move at their
    centroid; area features are clipped to each region and their outlines
    moved point by point.
  - Everything else is rubble: dropped. The fog wall wraps what is left.

Gate 3b (in ribbon.json): 0 chords where cross-blocks closed up, 0 new
dead ends inside the ribbon, the seams agree to SEAM_TOL, no new building
overlaps, the new centre line's tightest radius at least RADIUS_MIN for
the road's class and FOLD times the ribbon's depth (tighter folds the
inner side), and the stretch along the road at the ribbon's edge at most
BEND_MAX.
"""
import argparse
import glob
import heapq
import json
import math
import os
import sys
from collections import defaultdict

import numpy as np
import shapely
from shapely.geometry import LineString, Point, Polygon

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compress  # noqa: E402
from compress import Frame  # noqa: E402
from parish_thin import SKIP, is_deck, is_street, write_boundary, xz_of  # noqa: E402

CLOSE = 10.0  # m: closing radius turning blocks into one area (as parish_layout)
EDGE = 12.0  # m: a district's area reaches this far past its blocks, over its edge streets
FRONT = 25.0  # m: a block this close to the road fronts it
DEPTH = 160.0  # m: frontage deeper than this is cut off (parks, yards)
CORRIDOR = 14.0  # m: the road's own strip
SMOOTH = 120.0  # m: moving-average window of the frame
DEV_MAX = 15.0  # m: the road may stray this far from its frame
STEP = 2.0  # m: frame sampling
DENSE = 8.0  # m: ways and outlines in the ribbon are cut to segments this long before bending
ATTACH = 30.0  # m: past the last ribbon ground beside a district, the ribbon starts to move on its own
TOL = 0.5  # m: a cross street's own points sit on its curve, so i keeps (s <= s_i + TOL) and j goes
STRAIN_MAX = 0.1  # change in a cross-block's length per metre across
CUT_MAX = 2
SLACK = 1.02  # remaining road length over the new chord, at least
FOLD = 1.5
BEND_MAX = STRAIN_MAX  # stretch along the road at the ribbon's edge, |e| + u * |dk|: the same budget as a cross-block
BASIS = 8  # cosines in the bend correction
E_MAX = 0.05  # most the road may be scaled along its length
UMAX_HINT = [0.0]  # the ribbon's half-width, set once known (bend() prices stretch at the edge)
MEDIAN = 40.0  # m: a cross-block shorter than this is the median of a boulevard
RADIUS_MIN = {"primary": 60.0, "trunk": 60.0, "secondary": 60.0, "tertiary": 30.0}
SEAM_TOL = 0.05  # m
JOG_MIN = 1.0  # m
COST = {"trunk": 1.0, "primary": 1.0, "secondary": 1.15, "tertiary": 1.3, "primary_link": 1.5,
        "secondary_link": 1.5, "tertiary_link": 1.5, "residential": 1.7, "unclassified": 1.7,
        "living_street": 2.0}
TURN = 150.0  # m of cost per radian a path turns past BEND_FREE
BEND_FREE = 0.35  # rad: a turn this small is the road curving, free
BRIDGE_MAX = 400.0  # m: a bridge this short (a canal) carries a ribbon; longer ones are expressways
NO_ROAD = "parish_ribbon: no road joins the two districts"


def log(msg):
    print(msg, flush=True)


class Ids:
    """Fresh negative ids for the nodes and ways this script makes."""
    def __init__(self):
        self.n = -9_000_000_000

    def __call__(self):
        self.n -= 1
        return self.n


# --- frame ----------------------------------------------------------------------
class Frame1D:
    """A smooth centre line sampled every STEP m: s along, u across (left
    of the direction of travel is +u)."""
    def __init__(self, pts):
        L = LineString(pts)
        s = np.arange(0.0, L.length + STEP / 2, STEP)
        self.p = np.array([L.interpolate(v).coords[0] for v in s])
        self.s = s
        self.line = LineString(self.p)
        d = np.gradient(self.p, axis=0)
        d /= np.hypot(*d.T)[:, None]
        self.t = d
        self.n = np.c_[-d[:, 1], d[:, 0]]

    def at(self, s):
        s = np.clip(s, 0, self.s[-1])
        p = np.c_[np.interp(s, self.s, self.p[:, 0]), np.interp(s, self.s, self.p[:, 1])]
        n = np.c_[np.interp(s, self.s, self.n[:, 0]), np.interp(s, self.s, self.n[:, 1])]
        n /= np.hypot(*n.T)[:, None]
        return p, n

    def su(self, xz):
        xz = np.atleast_2d(xz)
        s = shapely.line_locate_point(self.line, shapely.points(xz))
        p, n = self.at(s)
        return s, ((xz - p) * n).sum(1)

    def radius(self):
        return min_radius(self.p)


def min_radius(p):
    a, b, c = p[:-2], p[1:-1], p[2:]
    ab, bc, ca = (np.hypot(*(b - a).T), np.hypot(*(c - b).T), np.hypot(*(a - c).T))
    cross = np.abs((b - a)[:, 0] * (c - a)[:, 1] - (b - a)[:, 1] * (c - a)[:, 0])
    with np.errstate(divide="ignore", invalid="ignore"):
        r = ab * bc * ca / (2 * cross)
    r = r[np.isfinite(r)]
    return float(r.min()) if len(r) else float("inf")


def smooth(pts, window):
    L = LineString(pts)
    s = np.arange(0.0, L.length + STEP / 2, STEP)
    p = np.array([L.interpolate(v).coords[0] for v in s])
    k = max(1, int(window / STEP) // 2)
    for _ in range(2):
        pad = np.r_[2 * p[0] - p[k:0:-1], p, 2 * p[-1] - p[-2:-k - 2:-1]]
        c = np.cumsum(np.r_[np.zeros((1, 2)), pad], axis=0)
        p = (c[2 * k + 1:] - c[:-2 * k - 1]) / (2 * k + 1)
    return p


# --- road ------------------------------------------------------------------------
def best_road(feats, fr, DA, DB, box):
    """Cheapest path from district A's area to B's: COST per metre plus TURN
    per radian of every turn past BEND_FREE, so it follows one street rather
    than zigzagging over the grid. Returns (node ids, xz, way ids along it)."""
    adj = defaultdict(list)
    pos = {}
    for el in feats:
        t = el.get("tags", {})
        if el["type"] != "way" or not is_street(t) or t["highway"] not in COST:
            continue
        geom, nodes = el.get("geometry") or [], el.get("nodes") or []
        if len(nodes) != len(geom) or len(nodes) < 2 or not all(geom):
            continue
        idx, xz = xz_of(fr, geom)
        if not shapely.intersects(box, LineString(xz)):
            continue
        if is_deck(t) and LineString(xz).length > BRIDGE_MAX:
            continue
        w = COST[t["highway"]]
        oneway = t.get("oneway") in ("yes", "1", "true")
        for k in range(len(nodes) - 1):
            a, b = nodes[k], nodes[k + 1]
            pos[a], pos[b] = xz[k], xz[k + 1]
            c = w * float(np.hypot(*(xz[k + 1] - xz[k])))
            adj[a].append((b, c, el["id"]))
            if not oneway:
                adj[b].append((a, c, el["id"]))
    ids = list(pos)
    P = np.array([pos[i] for i in ids])
    inA = shapely.contains_xy(DA, P[:, 0], P[:, 1])
    inB = set(np.array(ids)[shapely.contains_xy(DB, P[:, 0], P[:, 1])].tolist())

    def turn(p, a, b):
        if p is None:
            return 0.0
        u, v = pos[a] - pos[p], pos[b] - pos[a]
        nu, nv = np.hypot(*u), np.hypot(*v)
        if nu < 1e-6 or nv < 1e-6:
            return 0.0
        ang = math.acos(max(-1.0, min(1.0, float(u @ v) / (nu * nv))))
        return TURN * max(0.0, ang - BEND_FREE)
    dist, prev, h = {}, {}, []
    for i, ok in zip(ids, inA):
        if ok:
            dist[(i, None)] = 0.0
            heapq.heappush(h, (0.0, i, None))
    end = None
    while h:
        d, a, p = heapq.heappop(h)
        if d > dist.get((a, p), math.inf):
            continue
        if a in inB:
            end = (a, p)
            break
        for b, c, wid in adj[a]:
            if b == p:
                continue
            nd = d + c + turn(p, a, b)
            if nd < dist.get((b, a), math.inf):
                dist[(b, a)] = nd
                prev[(b, a)] = ((a, p), wid)
                heapq.heappush(h, (nd, b, a))
    if end is None:
        sys.exit(NO_ROAD)
    seq, ways = [end], []
    while seq[-1] in prev:
        st, wid = prev[seq[-1]]
        seq.append(st)
        ways.append(wid)
    seq = [st[0] for st in reversed(seq)]
    ways.reverse()
    return seq, np.array([pos[i] for i in seq]), ways


# --- cross streets -----------------------------------------------------------------
def through_streets(feats, fr, F, road_nodes, road_ways, R):
    """Junctions on the road where a street crosses it from both sides.
    Each: (s at the road, side curves [(|u| array, s array)] for u<0 and u>0, name)."""
    on_road = set(road_nodes)
    out = defaultdict(lambda: {"sides": {-1: [], 1: []}, "names": set()})
    for el in feats:
        t = el.get("tags", {})
        if el["type"] != "way" or not is_street(t) or el["id"] in road_ways:
            continue
        nodes, geom = el.get("nodes") or [], el.get("geometry") or []
        if len(nodes) != len(geom) or not on_road.intersection(nodes):
            continue
        for k, nd in enumerate(nodes):
            if nd not in on_road:
                continue
            for half in (geom[k::-1], geom[k:]):
                if len(half) < 2 or not all(half):
                    continue
                _, xz = xz_of(fr, half)
                line = shapely.intersection(LineString(xz), R)
                part = next((g for g in shapely.get_parts(line) if g.geom_type == "LineString"
                             and Point(xz[0]).distance(g) < 0.5), None)
                if part is None:
                    continue
                q = np.asarray(part.coords)
                if np.hypot(*(q[0] - xz[0])) > np.hypot(*(q[-1] - xz[0])):
                    q = q[::-1]
                s, u = F.su(q)
                if abs(u[-1]) < 5.0:
                    continue
                out[nd]["sides"][1 if u[-1] > 0 else -1].append((s, u))
                out[nd]["names"].add(t.get("name") or t["highway"])
    res = []
    for nd, v in out.items():
        sides = {}
        for sd, lst in v["sides"].items():
            if len(lst) != 1:
                break
            s, u = lst[0]
            au = np.abs(u)
            if np.any(np.diff(au) <= 0):
                break
            sides[sd] = (au, s)
        if len(sides) == 2:
            res.append({"node": nd, "names": sorted(v["names"]), "sides": sides})
    return res


def s_on(street, u):
    """s of a through street at each u (held past its ends)."""
    u = np.asarray(u, float)
    out = np.empty_like(u)
    for sd in (-1, 1):
        au, s = street["sides"][sd]
        m = (u < 0) if sd < 0 else (u >= 0)
        out[m] = np.interp(np.abs(u[m]), au, s)
    return out


# --- the map ---------------------------------------------------------------------------
class RibbonMap:
    def __init__(self, F, tA, tB, s_a, s_b, cuts, mid):
        self.F, self.tA, self.tB, self.s_a, self.s_b = F, np.asarray(tA), np.asarray(tB), s_a, s_b
        self.cuts = cuts  # [(street i, street j)]
        self.mid = mid  # the bent centre line: (s' from s_a, points, normals)
        self.R = sum(float(s_on(j, [0.0])[0] - s_on(i, [0.0])[0]) for i, j in cuts)

    def removed(self, s, u):
        """(cumulative removed length at each point, deleted mask)."""
        R = np.zeros(len(s))
        dead = np.zeros(len(s), bool)
        for i, j in self.cuts:
            si, sj = s_on(i, u), s_on(j, u)
            R += np.clip(s - TOL - si, 0.0, sj - si)
            dead |= (s > si + TOL) & (s <= sj + TOL)
        return R, dead

    def target(self, sp, s_true):
        """Centre point and normal of the new line at s' (s_true: the
        source s for the two end stretches)."""
        p = np.empty((len(sp), 2))
        n = np.empty((len(sp), 2))
        a = sp <= self.s_a
        b = sp >= self.s_a + self.mid[0][-1]
        m = ~a & ~b
        if a.any():
            pa, na = self.F.at(sp[a])
            p[a], n[a] = pa + self.tA, na
        if b.any():
            pb, nb = self.F.at(s_true[b])
            p[b], n[b] = pb + self.tB, nb
        if m.any():
            q = sp[m] - self.s_a
            ms, mp, mn = self.mid
            p[m] = np.c_[np.interp(q, ms, mp[:, 0]), np.interp(q, ms, mp[:, 1])]
            nn = np.c_[np.interp(q, ms, mn[:, 0]), np.interp(q, ms, mn[:, 1])]
            n[m] = nn / np.hypot(*nn.T)[:, None]
        return p, n

    def __call__(self, xz):
        """New positions, deleted mask, and the turn (radians) at each point."""
        xz = np.atleast_2d(np.asarray(xz, float))
        s, u = self.F.su(xz)
        R, dead = self.removed(s, u)
        sp = s - R
        # Past s_b the source s is what places a point on B's stretch.
        p, n = self.target(sp, np.where(sp >= self.s_a + self.mid[0][-1], s, s))
        p0, n0 = self.F.at(s)
        new = xz + (p + u[:, None] * n) - (p0 + u[:, None] * n0)
        turn = np.arctan2(n[:, 1], n[:, 0]) - np.arctan2(n0[:, 1], n0[:, 0])
        return new, dead, (turn + np.pi) % (2 * np.pi) - np.pi


def bend(F, s_a, s_b, cuts, P0, P1, th1):
    """The new centre line between the two attach points: the real road's
    own shape (cut-out blocks dropped), scaled along its length by 1 + e,
    plus the smallest smooth curvature correction dk(s) (least squares
    over BASIS cosines) that lands it on P1 heading th1. Whole blocks
    rarely take out exactly the right length; the rest is cheaper spread
    evenly (e) than bent in (an S-wiggle). e is chosen to minimise the
    stretch along the road at the ribbon's edge, |e| + u * |dk|.
    Returns (arclength samples of the source, new points, normals,
    tightest radius, dk samples, e)."""
    th = np.unwrap(np.arctan2(F.t[:, 1], F.t[:, 0]))
    kap = np.gradient(th, F.s)
    s = np.arange(s_a, s_b, STEP / 4)
    s = np.r_[s, s_b]
    R = np.zeros(len(s))
    dead = np.zeros(len(s), bool)
    for i, j in cuts:
        si, sj = float(s_on(i, [0.0])[0]), float(s_on(j, [0.0])[0])
        R += np.clip(s - TOL - si, 0.0, sj - si)
        dead |= (s > si + TOL) & (s <= sj + TOL)
    sp_k, s_k = (s - s_a - R)[~dead], s[~dead]
    L = float(sp_k[-1])
    ss = np.r_[np.arange(0.0, L, STEP), L]
    k0 = np.interp(np.interp(ss, sp_k, s_k), F.s, kap)
    t = ss / L
    ds0 = np.diff(ss)
    th0 = float(np.interp(s_a, F.s, th))
    nat = th0 + float(np.sum((k0[1:] + k0[:-1]) / 2 * ds0))
    th1 = th1 + 2 * np.pi * round((nat - th1) / (2 * np.pi))
    phi = np.array([np.cos(m * np.pi * t) for m in range(BASIS)])

    def solve(e):
        ds = ds0 * (1 + e)

        def run(x):
            dk = x @ phi
            kk = k0 / (1 + e) + dk
            h = th0 + np.r_[0.0, np.cumsum((kk[1:] + kk[:-1]) / 2 * ds)]
            c, sn = np.cos(h), np.sin(h)
            p = P0 + np.c_[np.r_[0.0, np.cumsum((c[1:] + c[:-1]) / 2 * ds)],
                           np.r_[0.0, np.cumsum((sn[1:] + sn[:-1]) / 2 * ds)]]
            return h, p, dk

        def err(x):
            h, p, _ = run(x)
            return np.r_[(h[-1] - th1) * L, p[-1] - P1]
        x = np.zeros(BASIS)
        for _ in range(40):
            r = err(x)
            if np.abs(r).max() < 1e-4:
                break
            J = np.empty((3, BASIS))
            for q in range(BASIS):
                dx = np.zeros(BASIS)
                dx[q] = 1e-7
                J[:, q] = (err(x + dx) - r) / 1e-7
            x = x - np.linalg.pinv(J) @ r
        h, p, dk = run(x)
        return np.abs(err(x)).max() <= 0.01, h, p, dk

    def cost(e):
        ok, _, _, dk = solve(e)
        return abs(e) + UMAX_HINT[0] * float(np.abs(dk).max()) if ok else math.inf
    es = np.linspace(-E_MAX, E_MAX, 33)
    e = float(es[int(np.argmin([cost(v) for v in es]))])
    lo, hi = e - 2 * E_MAX / 32, e + 2 * E_MAX / 32
    for _ in range(30):
        m1, m2 = lo + (hi - lo) / 3, hi - (hi - lo) / 3
        if cost(m1) < cost(m2):
            hi = m2
        else:
            lo = m1
    e = (lo + hi) / 2
    ok, h, p, dk = solve(e)
    if not ok:
        return None
    return ss, p, np.c_[-np.sin(h), np.cos(h)], min_radius(p), dk, e


# --- assembling ---------------------------------------------------------------------
class Assembler:
    """Classifies points into A, B, ribbon (R), deleted (D) or rubble (X)
    and moves them."""
    def __init__(self, fr, DA, DB, R, tA, tB, rmap, ids):
        self.fr, self.DA, self.DB, self.R = fr, DA, DB, R
        self.tA, self.tB, self.rmap, self.ids = np.asarray(tA), np.asarray(tB), rmap, ids
        self.regions = {"A": DA, "B": DB, "R": R}
        self.seam = 0.0
        self.joins = []

    def classify(self, xz):
        c = np.full(len(xz), "X")
        inR = shapely.contains_xy(self.R, xz[:, 0], xz[:, 1])
        c[inR] = "R"
        c[shapely.contains_xy(self.DB, xz[:, 0], xz[:, 1])] = "B"
        c[shapely.contains_xy(self.DA, xz[:, 0], xz[:, 1])] = "A"
        new = xz.copy()
        for cls in "AB":
            if (c == cls).any():
                new[c == cls] = self.move_one(cls, xz[c == cls])
        r = c == "R"
        if r.any():
            nr, dead, _ = self.rmap(xz[r])
            new[r] = nr
            cc = c[r]
            cc[dead] = "D"
            c[r] = cc
        return c, new

    def move_one(self, cls, xz):
        if cls == "A":
            return xz + self.tA
        if cls == "B":
            return xz + self.tB
        return self.rmap(xz)[0]

    def lonlat(self, xz):
        lon, lat = self.fr.lonlat(xz[:, 0], xz[:, 1])
        return [{"lat": float(round(a, compress.DP)), "lon": float(round(o, compress.DP))} for a, o in zip(lat, lon)]

    def densify(self, xz, nodes):
        out_p, out_n = [xz[0]], [nodes[0]]
        for k in range(1, len(xz)):
            d = float(np.hypot(*(xz[k] - xz[k - 1])))
            m = int(d // DENSE)
            for q in range(1, m + 1):
                out_p.append(xz[k - 1] + (xz[k] - xz[k - 1]) * q / (m + 1))
                out_n.append(self.ids())
            out_p.append(xz[k])
            out_n.append(nodes[k])
        return np.array(out_p), out_n

    def way(self, el, dense):
        """The way's pieces, moved. A run of deleted points between kept
        ones closes up (the jog is recorded); a piece leaving the kept
        ground ends on its edge."""
        geom = el.get("geometry") or []
        idx, xz = xz_of(self.fr, geom)
        if len(idx) < 2:
            return []
        nodes = el.get("nodes") or []
        nodes = [nodes[i] for i in idx] if len(nodes) == len(geom) else [self.ids() for _ in idx]
        if dense:
            xz, nodes = self.densify(xz, nodes)
        c, new = self.classify(xz)
        if (c == "X").all():
            return []
        # Close up deleted runs bounded by kept points; others become rubble.
        k = 0
        keep = c != "X"
        while k < len(c):
            if c[k] != "D":
                k += 1
                continue
            j = k
            while j + 1 < len(c) and c[j + 1] == "D":
                j += 1
            if k > 0 and j + 1 < len(c) and c[k - 1] not in "XD" and c[j + 1] not in "XD":
                keep[k:j + 1] = False
                self.joins.append((el, k - 1, j + 1, xz, new))
            else:
                c[k:j + 1] = "X"
                keep[k:j + 1] = False
            k = j + 1
        pieces, cur = [], None
        for k in range(len(c)):
            if c[k] == "X":
                if cur is not None:
                    q = self.edge_point(c[cur[-1][2]], xz[cur[-1][2]], xz[k])
                    if q is not None:
                        cur.append((q, self.ids(), None))
                    pieces.append(cur)
                    cur = None
                continue
            if not keep[k]:
                continue
            if cur is None:
                cur = []
                if k > 0 and c[k - 1] == "X":
                    q = self.edge_point(c[k], xz[k], xz[k - 1])
                    if q is not None:
                        cur.append((q, self.ids(), None))
            elif cur[-1][2] is not None and c[cur[-1][2]] != c[k] and {c[cur[-1][2]], c[k]} <= set("ABR"):
                self.seam_check(c[cur[-1][2]], c[k], xz[cur[-1][2]], xz[k])
            cur.append((new[k], nodes[k], k))
        if cur is not None:
            pieces.append(cur)
        out = []
        for n, pc in enumerate(pieces):
            if len(pc) < 2:
                continue
            e = dict(el)
            e["geometry"] = self.lonlat(np.array([p for p, _, _ in pc]))
            e["nodes"] = [nd for _, nd, _ in pc]
            if n:
                e["id"] = self.ids()
            e["bounds"] = compress._bounds(e["geometry"])
            out.append(e)
        return out

    def edge_point(self, cls, p, q):
        """Where p (kept, class cls) to q (rubble) leaves cls's ground, moved."""
        hit = shapely.intersection(LineString([p, q]), self.regions[cls].boundary)
        pts = [np.asarray(g.coords[0]) for g in shapely.get_parts(hit) if not g.is_empty]
        if not pts:
            return None
        e = min(pts, key=lambda v: np.hypot(*(v - p)))
        return self.move_one(cls, e[None])[0]

    def seam_check(self, ca, cb, p, q):
        """Two regions' moves where a way crosses from one to the other."""
        reg = self.regions[cb] if ca == "R" else self.regions[ca]
        hit = shapely.intersection(LineString([p, q]), reg.boundary)
        for g in shapely.get_parts(hit):
            if g.is_empty:
                continue
            e = np.asarray(g.coords[0])[None]
            d = self.move_one(ca, e)[0] - self.move_one(cb, e)[0]
            self.seam = max(self.seam, float(np.hypot(*d)))

    def building(self, el):
        """Moved rigidly by the move at its centroid, or None."""
        geoms = [el.get("geometry")] if el["type"] == "way" else [m.get("geometry") for m in el.get("members", [])]
        rings = []
        for g in geoms:
            if not g:
                rings.append(None)
                continue
            _, xz = xz_of(self.fr, g)
            rings.append(xz)
        allp = np.vstack([r for r in rings if r is not None and len(r)]) if any(r is not None and len(r) for r in rings) else None
        if allp is None:
            return None
        cen = allp.mean(0)[None]
        c, new = self.classify(cen)
        if c[0] in "XD":
            return None
        if c[0] == "R":
            _, _, turn = self.rmap(cen)
            a = float(turn[0])
        else:
            a = 0.0
        rot = np.array([[math.cos(a), -math.sin(a)], [math.sin(a), math.cos(a)]])
        e = dict(el)
        moved = [None if r is None else (r - cen) @ rot.T + new for r in rings]
        if el["type"] == "way":
            e["geometry"] = self.lonlat(moved[0])
            e["bounds"] = compress._bounds(e["geometry"])
        else:
            e["members"] = [dict(m, geometry=self.lonlat(r)) if r is not None else m
                            for m, r in zip(el["members"], moved)]
        return e

    def area(self, el, poly):
        """An area feature clipped to each region, outlines moved, as
        multipolygon relations of closed rings."""
        out = []
        taken = Polygon()
        for cls in ("A", "B", "R"):
            reg = self.regions[cls].difference(taken)
            taken = taken.union(self.regions[cls])
            piece = shapely.intersection(poly, reg)
            for g in shapely.get_parts(piece):
                if g.geom_type != "Polygon" or g.area < 1.0:
                    continue
                g = shapely.segmentize(g, DENSE) if cls == "R" else g
                rings = [np.asarray(g.exterior.coords)] + [np.asarray(r.coords) for r in g.interiors]
                moved = [self.move_one(cls, r) for r in rings]
                mp = Polygon(moved[0], moved[1:]).buffer(0)
                for h in shapely.get_parts(mp):
                    if h.geom_type != "Polygon" or h.area < 1.0:
                        continue
                    members = [{"type": "way", "ref": self.ids(), "role": role,
                                "geometry": self.lonlat(np.asarray(r.coords))}
                               for role, r in [("outer", h.exterior)] + [("inner", r) for r in h.interiors]]
                    rel = {"type": "relation", "id": self.ids(), "tags": dict(el.get("tags", {}), type="multipolygon"),
                           "members": members}
                    rel["bounds"] = compress._bounds([q for m in members for q in m["geometry"]])
                    out.append(rel)
        return out


def area_poly(el, fr):
    """The polygon of a closed way or a multipolygon relation, else None."""
    if el["type"] == "way":
        g = el.get("geometry") or []
        if len(g) < 4 or g[0] != g[-1] or not all(g):
            return None
        _, xz = xz_of(fr, g)
        p = Polygon(xz).buffer(0)
        return p if not p.is_empty else None
    lines = {"outer": [], "inner": []}
    for m in el.get("members", []):
        g = [q for q in (m.get("geometry") or []) if q]
        if len(g) >= 2 and m.get("role") in lines:
            _, xz = xz_of(fr, g)
            lines[m["role"]].append(LineString(xz))
    if not lines["outer"]:
        return None
    outer = shapely.union_all(shapely.get_parts(shapely.polygonize(lines["outer"])))
    if outer.is_empty:
        return None
    if lines["inner"]:
        inner = shapely.union_all(shapely.get_parts(shapely.polygonize(lines["inner"])))
        outer = outer.difference(inner)
    return outer.buffer(0)


def is_area(el):
    t = el.get("tags", {})
    if el["type"] == "relation":
        return t.get("type") == "multipolygon"
    g = el.get("geometry") or []
    return (len(g) >= 4 and g[0] == g[-1] and not (t.get("highway") and t.get("area") != "yes")
            and not t.get("railway") and not t.get("waterway") and t.get("natural") != "coastline")


# --- gate ----------------------------------------------------------------------------
def dead_ends(feats, fr, inner):
    deg, pos = defaultdict(int), {}
    for el in feats:
        t = el.get("tags", {})
        if el["type"] != "way" or not is_street(t):
            continue
        nodes, geom = el.get("nodes") or [], el.get("geometry") or []
        if len(nodes) != len(geom):
            continue
        for j, nd in enumerate(nodes):
            deg[nd] += (j > 0) + (j < len(nodes) - 1)
            if geom[j]:
                pos[nd] = geom[j]
    ends = [n for n, d in deg.items() if d == 1 and n in pos]
    if not ends:
        return set()
    x, z = fr.xz(np.array([pos[n]["lon"] for n in ends]), np.array([pos[n]["lat"] for n in ends]))
    return {n for n, ok in zip(ends, shapely.contains_xy(inner, x, z)) if ok}


def chords(joins):
    out = []
    for el, i, j, xz, new in joins:
        t = el.get("tags", {})
        if not is_street(t):
            continue
        # The far part moved more; its own direction should point at the near node.
        mi, mj = (np.hypot(*(new[q] - xz[q])) for q in (i, j))
        near, far, nxt = (i, j, min(j + 1, len(xz) - 1)) if mj >= mi else (j, i, max(i - 1, 0))
        v = new[nxt] - new[far]
        L = float(np.hypot(*v))
        if L < 0.5:
            continue
        w = new[near] - new[far]
        jog = abs(w[0] * v[1] - w[1] * v[0]) / L
        if jog > JOG_MIN:
            out.append((t.get("name") or t["highway"], round(float(np.hypot(*w)), 1), round(float(jog), 1)))
    return out


def overlaps(blds_new, blds_old, fr):
    def polys(lst):
        out = {}
        for el in lst:
            if el["type"] == "way" and el.get("geometry"):
                _, xz = xz_of(fr, el["geometry"])
                if len(xz) >= 4:
                    out[el["id"]] = Polygon(xz).buffer(0)
        return out
    pa, pb = polys(blds_new), polys(blds_old)
    ids = list(pa)
    geo = np.array([pa[i] for i in ids], dtype=object)
    if not len(geo):
        return []
    tree = shapely.STRtree(geo)
    out = []
    for x, y in zip(*tree.query(geo, predicate="intersects")):
        if x >= y:
            continue
        ov = shapely.intersection(geo[x], geo[y]).area
        if ov <= 1.0:
            continue
        o0, o1 = pb.get(ids[x]), pb.get(ids[y])
        if o0 is not None and o1 is not None and shapely.intersection(o0, o1).area > 1.0:
            continue
        out.append((ids[x], ids[y], round(float(ov), 1),
                    [round(float(v), 1) for v in (o0 or geo[x]).centroid.coords[0]],
                    [round(float(v), 1) for v in (o1 or geo[y]).centroid.coords[0]]))
    return out


# --- main --------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("segment")
    ap.add_argument("raw")
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("out")
    ap.add_argument("--identity", action="store_true", help="the same ground, unmoved and uncut")
    a = ap.parse_args()
    seg = json.load(open(os.path.join(a.segment, "segment.json"), encoding="utf-8"))
    dist = {d["name"]: d for d in json.load(open(os.path.join(a.segment, "districts.json"), encoding="utf-8"))["districts"]}
    lay = {d["name"]: d for d in json.load(open(os.path.join(a.segment, "layout.json"), encoding="utf-8"))["districts"]}
    for n in (a.a, a.b):
        if n not in dist:
            sys.exit("parish_ribbon: no district %r (have: %s)" % (n, ", ".join(dist)))
    fr = Frame(*seg["frame"])
    B = seg["blocks"]
    owner = {b: n for n, d in dist.items() for b in d["blocks"]}

    def dpoly(n):
        u = shapely.union_all([Polygon(B[b]["ring"]) for b in dist[n]["blocks"]])
        return u.buffer(CLOSE).buffer(-CLOSE)
    PA, PB = dpoly(a.a), dpoly(a.b)
    DA, DB = PA.buffer(EDGE), PB.buffer(EDGE)
    other_names = [n for n in dist if n not in (a.a, a.b)]
    others = [dpoly(n) for n in other_names]
    tA, tB = (np.zeros(2), np.zeros(2)) if a.identity else (np.array(lay[a.a]["t"]), np.array(lay[a.b]["t"]))

    log("loading features")
    raw_feats = json.load(open(os.path.join(a.raw, "features.json"), encoding="utf-8"))
    feats = raw_feats["elements"]
    box = shapely.union_all([DA, DB]).envelope.buffer(1500.0)
    seq, path, road_ways = best_road(feats, fr, DA, DB, box)
    inA = shapely.contains_xy(DA, path[:, 0], path[:, 1])
    inB = shapely.contains_xy(DB, path[:, 0], path[:, 1])
    k0 = int(np.flatnonzero(inA).max())
    k1 = k0 + int(np.flatnonzero(inB[k0:]).min())
    mid = LineString(path[k0:k1 + 1])
    names = []
    for el in feats:
        if el["type"] == "way" and el["id"] in set(road_ways[k0:k1]):
            nm = el.get("tags", {}).get("name") or el["tags"]["highway"]
            if nm not in names:
                names.append(nm)
    road_cls = sorted({el["tags"]["highway"] for el in feats if el["type"] == "way" and el["id"] in set(road_ways[k0:k1])},
                      key=lambda h: COST.get(h, 9))[0]
    log("road: %s (%s), %.0f m between the districts" % (" / ".join(names), road_cls, mid.length))
    through = [n for n, o in zip(other_names, others) if mid.intersects(o)]
    if through:
        sys.exit("parish_ribbon: the road runs through %s" % ", ".join(through))

    # Frontage.
    seg_tree = shapely.STRtree([Polygon(b["ring"]) for b in B])
    front = [i for i in seg_tree.query(mid.buffer(FRONT), predicate="intersects") if i not in owner]
    band = mid.buffer(DEPTH)
    R = shapely.union_all([shapely.intersection(Polygon(B[i]["ring"]), band) for i in front] + [mid.buffer(CORRIDOR)])
    R = R.buffer(CLOSE).buffer(-CLOSE).difference(DA).difference(DB)
    R = max(shapely.get_parts(R), key=lambda g: g.area)
    log("frontage: %d blocks, %.2f km2" % (len(front), R.area / 1e6))

    # Frame: the road from a little inside A to a little inside B, smoothed.
    ext0 = max(0, k0 - 1)
    ext1 = min(len(path) - 1, k1 + 1)
    fpts = path[ext0:ext1 + 1]
    F = Frame1D(smooth(fpts, SMOOTH))
    dev = float(max(F.line.distance(Point(p)) for p in LineString(fpts).segmentize(5.0).coords))
    umax = float(np.abs(F.su(np.asarray(R.exterior.segmentize(5.0).coords))[1]).max())
    rF = F.radius()
    log("frame: %.0f m, road strays %.1f m, tightest radius %.0f m, ribbon reaches %.0f m across"
        % (F.s[-1], dev, rF, umax))
    if dev > DEV_MAX:
        sys.exit("parish_ribbon: the road strays %.0f m from a smooth line (max %.0f); it turns corners" % (dev, DEV_MAX))
    if rF < umax:
        sys.exit("parish_ribbon: the road bends tighter (%.0f m) than the ribbon is deep (%.0f m)" % (rF, umax))

    # Where the ribbon is still beside a district.
    rb = np.asarray(R.exterior.segmentize(5.0).coords)
    rs, _ = F.su(rb)
    near_a = rs[shapely.dwithin(shapely.points(rb), DA, 1.0)]
    near_b = rs[shapely.dwithin(shapely.points(rb), DB, 1.0)]
    s_a = float(near_a.max()) + ATTACH if len(near_a) else 0.0
    s_b = float(near_b.min()) - ATTACH if len(near_b) else float(F.s[-1])
    if s_b <= s_a:
        sys.exit("parish_ribbon: the ribbon is beside one district or the other all the way (s_a %.0f, s_b %.0f)" % (s_a, s_b))

    # Cross-blocks.
    on_road = seq[k0:k1 + 1]
    streets = through_streets(feats, fr, F, on_road, set(road_ways), R)
    for st in streets:
        st["s"] = float(s_on(st, [0.0])[0])
    streets.sort(key=lambda st: st["s"])
    streets = [st for st in streets if s_a < st["s"] < s_b]
    decks = [LineString(xz_of(fr, el["geometry"])[1]) for el in feats
             if el["type"] == "way" and is_deck(el.get("tags", {})) and len(el.get("geometry") or []) >= 2
             and all(el["geometry"])]
    deck_u = shapely.union_all(decks) if decks else None
    prot = shapely.union_all([Polygon(b["ring"]) for b in B if b["protected"]])
    log("loading buildings")
    bld_files = {}
    for path_ in sorted(glob.glob(os.path.join(a.raw, "bld_*.json"))):
        bld_files[os.path.basename(path_)] = json.load(open(path_, encoding="utf-8"))
    keepbox = shapely.union_all([DA, DB, R]).envelope
    kb = keepbox.bounds
    lo_lon, lo_lat = fr.lonlat(kb[0], kb[3])
    hi_lon, hi_lat = fr.lonlat(kb[2], kb[1])

    def in_box(el):
        bd = el.get("bounds")
        return not bd or not (bd["maxlat"] < lo_lat or bd["minlat"] > hi_lat or bd["maxlon"] < lo_lon or bd["minlon"] > hi_lon)
    bld_polys = []
    for d in bld_files.values():
        for el in d["elements"]:
            if el["type"] == "way" and el.get("geometry") and in_box(el) and all(el["geometry"]):
                _, xz = xz_of(fr, el["geometry"])
                if len(xz) >= 4:
                    bld_polys.append(Polygon(xz).buffer(0))
    btree = shapely.STRtree(bld_polys)
    uu = np.linspace(-umax, umax, 81)
    rows = []
    for k in range(len(streets) - 1):
        i, j = streets[k], streets[k + 1]
        si, sj = s_on(i, uu), s_on(j, uu)
        r = {"k": k, "keep": "/".join(i["names"])[:30], "gone": "/".join(j["names"])[:30],
             "length": round(float(sj[40] - si[40]), 1), "why": []}
        dl = sj - si
        if r["length"] < MEDIAN:
            r["why"].append("median")
        if k + 2 < len(streets) and streets[k + 2]["names"] == j["names"] and streets[k + 2]["s"] - j["s"] < MEDIAN:
            r["why"].append("half a boulevard")
        if np.any(dl <= 1.0):
            r["why"].append("the streets meet")
            rows.append(r)
            continue
        strain = float(np.abs(np.diff(dl) / np.diff(uu)).max())
        if strain > STRAIN_MAX:
            r["why"].append("strain %.2f" % strain)
        pi, _ = F.at(si)
        pj, _ = F.at(sj)
        ni = F.at(si)[1]
        nj = F.at(sj)[1]
        ring = np.r_[pi + uu[:, None] * ni, (pj + uu[:, None] * nj)[::-1]]
        poly = shapely.intersection(Polygon(ring).buffer(0), R)
        r["poly"] = poly
        if shapely.intersection(poly, prot).area > 1.0:
            r["why"].append("landmark")
        if deck_u is not None and shapely.intersects(poly, deck_u):
            r["why"].append("deck")
        cut = 0
        for q in btree.query(poly, predicate="intersects"):
            c = np.asarray(bld_polys[q].exterior.coords)
            cs, cu = F.su(c)
            a1 = cs - s_on(i, cu)
            a2 = cs - s_on(j, cu)
            if (a1.min() < -TOL < a1.max()) or (a2.min() < -TOL < a2.max()):
                if (np.abs(cu) < umax).all():
                    cut += 1
        if cut > CUT_MAX:
            r["why"].append("%d buildings cut" % cut)
        r["cut"] = cut
        hit = seg_tree.query(poly, predicate="intersects")
        r["score"] = float(sum(B[h]["score"] * shapely.intersection(Polygon(B[h]["ring"]), poly).area
                               / max(Polygon(B[h]["ring"]).area, 1.0) for h in hit))
        rows.append(r)

    # Length to take out: as much as makes the road's own shape span the
    # new chord, so the bend only has to turn it, not squeeze it.
    P0 = F.at(np.array([s_a]))[0][0] + tA
    P1 = F.at(np.array([s_b]))[0][0] + tB
    th1 = float(np.arctan2(*F.at(np.array([s_b]))[1][0][::-1]) - np.pi / 2)
    chord = float(np.hypot(*(P1 - P0)))
    chord0 = float(np.hypot(*(F.at(np.array([s_b]))[0][0] - F.at(np.array([s_a]))[0][0])))
    M = s_b - s_a
    chosen, removed = [], 0.0
    target = M * (1 - chord / chord0)
    if not a.identity:
        if M < chord * SLACK:
            sys.exit("parish_ribbon: the road (%.0f m) is shorter than its new chord (%.0f m); it would stretch" % (M, chord))
        for r in sorted([r for r in rows if not r["why"]], key=lambda r: r["score"]):
            k = r["k"]
            ks = {c["k"] for c in chosen}
            if any({k + d, k + d + 1, k + d + 2} - {k} <= ks for d in (-2, -1, 0)):
                continue
            if removed + r["length"] > target + r["length"] / 2 or M - (removed + r["length"]) < chord * SLACK:
                continue
            chosen.append(r)
            removed += r["length"]
    cuts = [(streets[r["k"]], streets[r["k"] + 1]) for r in sorted(chosen, key=lambda r: r["k"])]
    log("middle: %.0f m of road, chord %.0f m (true %.0f m), take out %.0f m; %d of %d cross-blocks eligible, %d taken out, %.0f m"
        % (M, chord, chord0, target, sum(1 for r in rows if not r["why"]), len(rows), len(cuts), removed))
    for r in rows:
        log("  %2d %-30s %s %6.1f m  %s" % (r["k"], r["gone"], "CUT" if r in chosen else "   ", r["length"],
                                           "; ".join(r["why"]) or "score %.1f, %d cut" % (r["score"], r.get("cut", 0))))
    UMAX_HINT[0] = umax
    hm = bend(F, s_a, s_b, cuts, P0, P1, th1)
    if hm is None:
        sys.exit("parish_ribbon: no bend lands the road on B")
    stretch = abs(hm[5]) + float(umax * np.abs(hm[4]).max())
    rmap = RibbonMap(F, tA, tB, s_a, s_b, cuts, hm[:3])
    new_len = float(np.hypot(*np.diff(hm[1], axis=0).T).sum())
    log("new centre line: %.0f m (scaled %+.3f), tightest radius %.0f m, edge stretched by %.3f"
        % (new_len, hm[5], hm[3], stretch))

    # Assemble.
    ids = Ids()
    asm = Assembler(fr, DA, DB, R, tA, tB, rmap, ids)
    out_raw = os.path.join(a.out, "raw")
    os.makedirs(out_raw, exist_ok=True)
    new_feats, dropped_rel = [], 0
    rb_ = R.bounds
    for el in feats:
        if not in_box(el):
            continue
        if is_area(el):
            poly = area_poly(el, fr)
            if poly is None or poly.is_empty:
                dropped_rel += el["type"] == "relation"
                continue
            new_feats += asm.area(el, poly)
        elif el["type"] == "way":
            new_feats += asm.way(el, dense=True)
    raw_feats["elements"] = new_feats
    compress.write_file(os.path.join(out_raw, "features.json"), raw_feats)
    coast = json.load(open(os.path.join(a.raw, "coast.json"), encoding="utf-8"))
    coast["elements"] = [w for el in coast["elements"] if el["type"] == "way" and in_box(el) for w in asm.way(el, dense=True)]
    compress.write_file(os.path.join(out_raw, "coast.json"), coast)
    old_blds, new_blds = [], []
    for name, d in bld_files.items():
        els = []
        for el in d["elements"]:
            if not in_box(el):
                continue
            e = asm.building(el)
            if e is not None:
                els.append(e)
                old_blds.append(el)
        if els:
            d = dict(d, elements=els)
            compress.write_file(os.path.join(out_raw, name), d)
            new_blds += els
    kept_R = R
    for i, j in cuts:
        si, sj = s_on(i, uu), s_on(j, uu)
        pi, ni = F.at(si)
        pj, nj = F.at(sj)
        kept_R = kept_R.difference(Polygon(np.r_[pi + uu[:, None] * ni, (pj + uu[:, None] * nj)[::-1]]).buffer(0.5))
    mapped = [Polygon(np.asarray(DA.exterior.coords) + tA),
              Polygon(np.asarray(DB.exterior.coords) + tB)]
    for g in shapely.get_parts(kept_R):
        mapped.append(Polygon(rmap(np.asarray(shapely.segmentize(g, DENSE).exterior.coords))[0]).buffer(0))
    ground = shapely.union_all(mapped).buffer(CLOSE).buffer(-CLOSE)
    parts = shapely.get_parts(ground)
    outline = max(parts, key=lambda g: g.area).buffer(25.0)
    write_boundary(os.path.join(out_raw, "boundary.json"), fr, np.asarray(outline.exterior.segmentize(25.0).coords))

    # Gate.
    inner_src = R.buffer(-8.0)
    # The pieces either side of a cut meet again once mapped, but kept_R
    # was cut 0.5 m wide each side: close that slit before shrinking, or the
    # shrink opens a gap exactly where a cut could leave a dead end.
    inner_new = shapely.union_all([Polygon(rmap(np.asarray(shapely.segmentize(g, DENSE).exterior.coords))[0]).buffer(0)
                                   for g in shapely.get_parts(kept_R)]).buffer(2.0).buffer(-2.0).buffer(-8.0)
    inner_new = inner_new.difference(Polygon(np.asarray(DA.exterior.coords) + tA)).difference(Polygon(np.asarray(DB.exterior.coords) + tB))
    before = dead_ends(feats, fr, inner_src)
    after = dead_ends(new_feats, fr, inner_new)
    ch = chords(asm.joins)
    ov = overlaps(new_blds, old_blds, fr)
    for o in ov[:10]:
        (sa, sb), (ua, ub) = F.su(np.array([o[3], o[4]]))
        ca = asm.classify(np.array([o[3], o[4]]))[0]
        log("  overlap %.1f m2: source s %.0f/%.0f u %.0f/%.0f, %s" % (o[2], sa, sb, ua, ub, "".join(ca)))
    # The real road's own curvature is never a fault (identity passes); only
    # curvature the bend adds is held to the class minimum and the fold.
    rmin = min(max(RADIUS_MIN.get(road_cls.replace("_link", ""), 15.0), FOLD * umax), 0.9 * rF)
    gate = {"road": names, "class": road_cls, "road_m": round(M, 1), "chord_m": round(chord, 1),
            "removed_m": round(removed, 1), "cross_blocks_out": len(cuts), "new_line_m": round(new_len, 1), "scale_e": round(float(hm[5]), 4),
            "radius_m": round(float(hm[3]), 1), "bend_stretch": round(stretch, 4), "radius_min_m": round(rmin, 1), "depth_m": round(umax, 1),
            "chords": len(ch), "chord_list": ch[:20], "joins": len(asm.joins),
            "dead_ends_before": len(before), "dead_ends_after": len(after), "new_dead_ends": len(after - before),
            "new_dead_end_ids": sorted(after - before)[:20],
            "seam_mismatch_m": round(asm.seam, 4), "new_overlaps": len(ov), "overlap_list": ov[:20],
            "ground_parts": len(parts), "relations_dropped": dropped_rel}
    gate["pass"] = bool(gate["chords"] == 0 and gate["new_dead_ends"] == 0 and gate["seam_mismatch_m"] <= SEAM_TOL
                        and gate["new_overlaps"] == 0 and gate["radius_m"] >= rmin and stretch <= BEND_MAX and gate["ground_parts"] == 1)
    log("gate " + json.dumps({k: v for k, v in gate.items() if k not in ("chord_list", "new_dead_end_ids", "overlap_list")}))
    for c in ch[:10]:
        log("  chord %-28s length %5.1f m, jog %5.1f m" % c)
    with open(os.path.join(a.out, "ribbon.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"a": a.a, "b": a.b, "identity": a.identity, "tA": tA.tolist(), "tB": tB.tolist(),
                   "s_a": s_a, "s_b": s_b, "rows": [{k: v for k, v in r.items() if k != "poly"} for r in rows],
                   "gate": gate}, f, indent=1)
    xs, zs = np.asarray(outline.exterior.coords).T
    w, s_ = fr.lonlat(xs.min(), zs.max())
    e, n_ = fr.lonlat(xs.max(), zs.min())
    with open(os.path.join(a.out, "frame.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"origin": [fr.lat0, fr.lon0], "bbox": [float(s_), float(w), float(n_), float(e)]}, f)
    sys.exit(0 if gate["pass"] or a.identity else 1)


if __name__ == "__main__":
    main()

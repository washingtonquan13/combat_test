"""Compress a city the SMT way: cut the filler out between the districts
and close the gap, so the arrangement and the landmarks stay and the walk
between them shortens.

    python -I tools/blockout/compress.py <cuts.json> <raw dir> <out raw dir>
        [--lidar <lidar_decks.npz>] [--decks <decks.json> --decks-out <out dir>]
        [--water-seeds "LAT,LON;LAT,LON"] [--mark name=x,z ...]

<cuts.json> names the frame the cuts are measured in and the bands to cut:

    {"frame": "data/blockouts/nola_spline/city.json",
     "bbox": [S, W, N, E],                      optional; the frame's own bbox
     "cuts": [{"name": "Poydras corridor", "centre": [-250, 1574],
               "angle": 110, "width": 400, "keep": 0.0},
              {"name": "Mid-City", "axis": "z", "from": 300, "to": 700}]}

A band is a strip of the map: "centre" a point on its centre line,
"angle" the direction that line runs (degrees from east towards south,
so 0 is an east-west line and 90 a north-south one), "width" across it,
all in metres of the frame (x east, z south from the frame's origin, the
way city.json and decks.json measure). "axis" "x" with "from"/"to" is a
north-south strip between those x, "axis" "z" an east-west one. Cut
across the street grid, not across the map: a band whose line runs with
the local cross streets takes a run of blocks out and the through streets
meet again on the line; a band askew to the grid shears every street that
crosses it sideways by the band's width times the skew. "keep" is what
fraction of the width survives: 0 (the default) deletes it, 0.3 squeezes
it to 30%, 1 changes nothing. Bands apply in order, each measured in the map as the earlier
ones left it. Everything past a band slides in by what the band lost, so
a cut is a pure shift elsewhere: a district that no band touches keeps its
shape to the centimetre.

What goes in is what fetch_osm_city.py downloaded; what comes out is
another raw dir that the rest of the pipeline reads unchanged:

  bld_*.json, features.json, coast.json   every lat/lon moved through the
      cuts. A road's nodes inside a deleted band go: a road crossing the
      band becomes a straight chord between its last node on each side,
      and one that ends inside it keeps its end node, which the cut puts on
      the line, so the next road along, starting from that same node on
      the other side, meets it there. A building wholly inside vanishes;
      one straddling the line loses the vertices inside and keeps the
      rest. A multipolygon member keeps its end nodes the same way, so the
      ring still joins. Ways left with one point and rings with fewer than
      three are dropped.
  boundary.json   the map rectangle (cuts.json's bbox) moved through the
      cuts, as a boundary relation, so osm_city.py needs no --bbox and the
      fog wall follows the new edge.
  lidar_decks.npz   the LiDAR returns inside the bbox, moved the same way,
      the returns in a deleted band dropped (--lidar; decks_seed.py uses a
      raw dir's own npz when there is one).
  compress.json   the cuts, the new frame, and the report below.

--decks carries data/blockouts/<name>/decks.json's hand records and fills
into --decks-out/decks.json for decks_seed.py to keep, moved into the new
frame. Only a record no band touches comes across: one with nodes in a
band, or nodes on both sides of one, is dropped with a warning and left to
the seed, because its lengths and the at_s of its relations would be wrong.

The report says, per band, which roads cross it and which vanish, how many
buildings go, how many street ends meet on the line and which major ones
are left loose, and for the elevated records what the cut leaves: the
drop across each chord and the step in height where two ends meet on the
line, so a cliff in an expressway is visible before the build. Street ends
that one street ran between through the band (its deleted nodes connect
them) are snapped onto one point when they land within 80 m of each other
on the line, so a street a few degrees off the cut's direction, whose two
halves the shear would part, meets itself again; the report counts those.
It also counts the streets chorded across the band and lists the longest:
a street crossing at a shallow angle (an expressway running nearly along
the band) leaves a chord along the seam far longer than the band is wide,
with no ground truth under it, so decks_seed.py has to solve its height
there. --mark points (a door, a spawn) and --water-seeds are printed where
they land.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LIDAR = os.path.join(ROOT, "data", "blockouts", "new_orleans_lidar", "lidar_decks.npz")
M_LAT = 111_320.0
DP = 7  # OSM's own lat/lon precision
LIDAR_MARGIN = 300.0
SNAP = 80.0  # metres: ends of one street this far apart on the line are joined
ROADS = ("motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link", "trunk_link",
         "primary_link", "residential", "unclassified", "living_street", "pedestrian", "service")
MAJOR = set(ROADS[:8]) | {"rail"}


class Frame:
    """Map metres <-> lon/lat exactly as osm_city.py does it."""

    def __init__(self, lat0, lon0):
        self.lat0, self.lon0 = lat0, lon0
        self.m_lon = M_LAT * math.cos(math.radians(lat0))

    def xz(self, lon, lat):
        return (np.asarray(lon, float) - self.lon0) * self.m_lon, -(np.asarray(lat, float) - self.lat0) * M_LAT

    def lonlat(self, x, z):
        return self.lon0 + np.asarray(x, float) / self.m_lon, self.lat0 - np.asarray(z, float) / M_LAT

    @staticmethod
    def of_bbox(s, w, n, e):
        return Frame((s + n) / 2, (w + e) / 2)


class Band:
    """One strip: u = x*c + z*s is the distance across it, the band is
    a <= u < b, and the cut slides everything past b back by what it lost."""

    def __init__(self, spec):
        self.name = spec.get("name", "")
        self.keep = float(spec.get("keep", 0.0))
        if "axis" in spec:
            if spec["axis"] not in ("x", "z"):
                raise SystemExit("compress: axis must be x or z in %r" % spec)
            self.c, self.s = (1.0, 0.0) if spec["axis"] == "x" else (0.0, 1.0)
            self.a, self.b = float(spec["from"]), float(spec["to"])
            self.desc = "%s %g..%g" % (spec["axis"], self.a, self.b)
        else:
            across = math.radians(float(spec["angle"]) + 90.0)
            self.c, self.s = math.cos(across), math.sin(across)
            cx, cz = spec["centre"]
            u0 = cx * self.c + cz * self.s
            w = float(spec["width"])
            self.a, self.b = u0 - w / 2, u0 + w / 2
            self.desc = "line at %g deg through (%g, %g), %g m wide" % (spec["angle"], cx, cz, w)
        if not self.b > self.a or not 0.0 <= self.keep <= 1.0:
            raise SystemExit("compress: bad band %r" % spec)
        if not self.name:
            self.name = self.desc

    def u(self, x, z):
        return np.asarray(x, float) * self.c + np.asarray(z, float) * self.s

    def side(self, x, z):
        u = self.u(x, z)
        return np.where(u < self.a, -1, np.where(u < self.b, 0, 1))

    def deletes(self, x, z):
        u = self.u(x, z)
        return (u >= self.a) & (u < self.b) if self.keep == 0.0 else np.zeros(u.shape, bool)

    def warp(self, x, z):
        x, z = np.asarray(x, float), np.asarray(z, float)
        u = self.u(x, z)
        lost = (self.b - self.a) * (1.0 - self.keep)
        du = np.where(u < self.a, 0.0, np.where(u < self.b, (u - self.a) * (self.keep - 1.0), -lost))
        return x + du * self.c, z + du * self.s



def survivors(gone, mode):
    """Which points of a line survive its deleted nodes. "closed": every
    deleted node goes and the ring closes across the gap. "open": a run of
    deleted nodes between kept ones goes (the line becomes a chord across
    the band), but a run at either end keeps the line's own end node, which
    the warp puts on the cut line: a street that ends inside the band ends
    on the line, and the next street along, which starts at that same node
    from the other side, meets it there exactly. Returns the keep mask and
    (end, anchor) index pairs."""
    keep = ~gone
    ends = []
    if mode == "closed" or not gone.any() or gone.all():
        return keep, ends
    kept = np.flatnonzero(keep)
    first, last = kept[0], kept[-1]
    if first > 0:
        keep[0] = True
        ends.append((0, first))
    if last < len(gone) - 1:
        keep[len(gone) - 1] = True
        ends.append((len(gone) - 1, last))
    return keep, ends


class Cuts:
    def __init__(self, spec):
        self.bands = [Band(s) for s in spec]
        if not self.bands:
            raise SystemExit("compress: no cuts")

    def deleted(self, x, z):
        """Points inside a band that keeps nothing, at the stage it applies."""
        x, z = np.array(x, float, ndmin=1), np.array(z, float, ndmin=1)
        gone = np.zeros(x.shape, bool)
        for band in self.bands:
            gone |= band.deletes(x, z)
            x, z = band.warp(x, z)
        return gone

    def warp(self, x, z):
        for band in self.bands:
            x, z = band.warp(x, z)
        return x, z

    def line(self, x, z, mode):
        """A polyline through the cuts, band by band. Returns the keep
        mask, the moved points, each point's side of each band at that
        band's stage (0 once it is gone), the band that deleted each point
        (-1 if none), and the ends made on a line as (index, band index,
        side, anchor index, fraction along anchor->end)."""
        px, pz = np.array(x, float), np.array(z, float)
        n = len(px)
        keep = np.ones(n, bool)
        sides = np.zeros((n, len(self.bands)), int)
        deleted_by = np.full(n, -1)
        ends = []
        for bi, band in enumerate(self.bands):
            alive = np.flatnonzero(keep)
            if alive.size == 0:
                break
            s = band.side(px[alive], pz[alive])
            sides[alive, bi] = s
            gone = band.deletes(px[alive], pz[alive])
            k2, e2 = survivors(gone, mode)
            for j, anchor in e2:
                ends.append((alive[j], bi, int(s[anchor]), alive[anchor]))
            dead = alive[~k2]
            keep[dead] = False
            deleted_by[dead] = bi
            alive = np.flatnonzero(keep)
            px[alive], pz[alive] = band.warp(px[alive], pz[alive])
        ends = [e for e in ends if keep[e[0]]]
        return keep, px, pz, sides, deleted_by, ends


# --- geometry ---------------------------------------------------------------
class End:
    """A road's end on a cut line: the side its kept part is on, its class
    and name, its moved position, its node id, and the point written."""

    __slots__ = ("side", "cls", "name", "x", "z", "node", "point")

    def __init__(self, side, cls, name, x, z, node, point):
        self.side, self.cls, self.name, self.x, self.z, self.node, self.point = side, cls, name, x, z, node, point


class Mover:
    """Moves raw OSM geometry through the cuts and counts what it did."""

    def __init__(self, frame, cuts):
        self.frame, self.cuts = frame, cuts
        self.crossed = {}  # (band index, class) -> ways with nodes on both sides
        self.removed = {}  # (band index, class) -> ways wholly inside
        self.ends = {}  # band index -> [End] roads ending on the cut line
        self.chords = {}  # band index -> [(length, class, name)] roads chorded across the band
        self.buildings = {"kept": 0, "clipped": 0, "removed": 0}
        self.members_dropped = 0
        self.parent = {}  # node id -> node id: roads joined through deleted nodes

    def points(self, geom, mode, cls=None, name=None, nodes=None):
        """A list of {lat, lon} (None for a point outside the download)
        moved through the cuts: the moved points and which input points
        survived. A road (cls given) also records its ends on the cut
        lines, and every segment of it that touches a deleted band joins
        its two nodes in self.parent, so snap() can tell which ends were
        one street through the band."""
        idx = [i for i, g in enumerate(geom) if g]
        if not idx:
            return [], np.zeros(len(geom), bool)
        lon = np.array([geom[i]["lon"] for i in idx])
        lat = np.array([geom[i]["lat"] for i in idx])
        x, z = self.frame.xz(lon, lat)
        keep, wx, wz, sides, deleted_by, ends = self.cuts.line(x, z, mode)
        ids = [nodes[i] for i in idx] if nodes and len(nodes) == len(geom) else None
        if cls is not None:
            self._count(cls, sides, deleted_by, keep)
            for j in range(len(idx)):  # a deleted run between kept nodes leaves a chord along the seam
                if keep[j] or (j and not keep[j - 1]):
                    continue
                k = j
                while k < len(idx) and not keep[k]:
                    k += 1
                if j > 0 and k < len(idx):
                    self.chords.setdefault(int(deleted_by[j]), []).append(
                        (float(math.hypot(wx[k] - wx[j - 1], wz[k] - wz[j - 1])), cls, name))
            if ids:
                inside = np.zeros(len(idx), bool)
                for bi, band in enumerate(self.cuts.bands):
                    if band.keep == 0.0:
                        inside |= sides[:, bi] == 0
                for j in np.flatnonzero(inside[:-1] | inside[1:]):
                    self._union(ids[j], ids[j + 1])
        lon, lat = self.frame.lonlat(wx, wz)
        lon, lat = np.round(lon, DP), np.round(lat, DP)
        out, survived = [], np.zeros(len(geom), bool)
        made = {}
        last = None
        for j, i in enumerate(idx):
            if not keep[j]:
                continue
            p = (lat[j], lon[j])
            if p != last:  # consecutive duplicates, from a squeezed band, merge
                out.append({"lat": float(p[0]), "lon": float(p[1])})
                survived[i] = True
            made[j] = out[-1]
            last = p
        if cls is not None:
            for j, bi, side, _ in ends:
                self.ends.setdefault(bi, []).append(
                    End(side, cls, name, float(wx[j]), float(wz[j]), ids[j] if ids else None, made[j]))
        return out, survived

    def _find(self, n):
        p = self.parent.setdefault(n, n)
        while p != n:
            self.parent[n] = self.parent[p]
            n, p = p, self.parent[p]
        return n

    def _union(self, a, b):
        ra, rb = self._find(a), self._find(b)
        if ra != rb:
            self.parent[ra] = rb

    def snap(self, bi):
        """Join the ends on band bi's line. Two ends that one street ran
        between through the band (its deleted nodes connect them), one from
        each side, with the same name or both unnamed and of one class, and
        within SNAP m along the line, are moved onto their midpoint, every
        end at either node with them. Returns (on the line, met at a shared
        node, snapped, the longest snap, the loose ends)."""
        ends = self.ends.get(bi, [])
        near = [e for e in ends if e.side == -1 and e.node is not None]
        far = [e for e in ends if e.side == 1 and e.node is not None]
        cands = []
        for e in near:
            for f in far:
                if e.node != f.node and self._find(e.node) != self._find(f.node):
                    continue
                if (e.name or f.name) and e.name != f.name:
                    continue
                if not e.name and e.cls != f.cls:
                    continue
                d = math.hypot(e.x - f.x, e.z - f.z)
                if d < SNAP:
                    cands.append((d, e, f))
        cands.sort(key=lambda c: c[0])
        target, taken, shared, snapped, longest = {}, set(), 0, 0, 0.0
        for d, e, f in cands:
            if e.node in taken or f.node in taken:
                continue
            taken.add(e.node)
            taken.add(f.node)
            if e.node == f.node or d < 0.01:
                shared += 1
                continue
            snapped += 1
            longest = max(longest, d)
            mid = ((e.x + f.x) / 2, (e.z + f.z) / 2)
            target[e.node] = target[f.node] = mid
        for e in ends:
            if e.node in target:
                e.x, e.z = target[e.node]
                lon, lat = self.frame.lonlat(e.x, e.z)
                e.point["lon"], e.point["lat"] = float(np.round(lon, DP)), float(np.round(lat, DP))
        loose = [e for e in ends if e.node not in taken]
        return len(ends), shared, snapped, longest, loose

    def way(self, el):
        """A way element moved; None when nothing of it is left."""
        geom = el.get("geometry") or []
        if not geom:
            return el
        closed = len(geom) > 3 and geom[0] == geom[-1]
        tags = el.get("tags", {})
        cls = tags.get("highway") or ("rail" if tags.get("railway") == "rail" else None)
        pts, survived = self.points(geom, "closed" if closed else "open", cls, tags.get("name"), el.get("nodes"))
        if "building" in tags and closed:
            self.buildings["kept" if survived.all() else "removed" if not pts else "clipped"] += 1
        if closed and pts and pts[0] != pts[-1]:
            pts.append(dict(pts[0]))  # a ring whose closing vertex went
        if (closed and len(pts) < 4) or len(pts) < 2:
            return None
        out = dict(el)
        out["geometry"] = pts
        if el.get("nodes") and len(el["nodes"]) == len(geom):
            out["nodes"] = [n for n, s in zip(el["nodes"], survived) if s]
        if "bounds" in el:
            out["bounds"] = _bounds(pts)
        return out

    def relation(self, el):
        members = []
        for m in el.get("members", []):
            if not m.get("geometry"):
                members.append(m)
                continue
            pts, _ = self.points(m["geometry"], "open")
            if len(pts) < 2:
                self.members_dropped += 1
                continue
            mm = dict(m)
            mm["geometry"] = pts
            members.append(mm)
        if not any(m.get("geometry") for m in members):
            return None
        out = dict(el)
        out["members"] = members
        if "bounds" in el:
            out["bounds"] = _bounds([p for m in members for p in m.get("geometry") or []])
        return out

    def node(self, el):
        x, z = self.frame.xz(el["lon"], el["lat"])
        x, z = self.cuts.warp(x, z)
        lon, lat = self.frame.lonlat(x, z)
        out = dict(el)
        out["lon"], out["lat"] = float(np.round(lon, DP)), float(np.round(lat, DP))
        return out

    def _count(self, cls, sides, deleted_by, keep):
        for bi in range(sides.shape[1]):
            col = sides[:, bi]
            key = (bi, cls)
            if (col == -1).any() and (col == 1).any():
                self.crossed[key] = self.crossed.get(key, 0) + 1
            elif not keep.any() and (deleted_by == bi).all():
                self.removed[key] = self.removed.get(key, 0) + 1


def _bounds(pts):
    return {"minlat": min(p["lat"] for p in pts), "minlon": min(p["lon"] for p in pts),
            "maxlat": max(p["lat"] for p in pts), "maxlon": max(p["lon"] for p in pts)}


def move_file(src, mover):
    """The file's elements moved, held for snap() before they are written."""
    data = json.load(open(src, encoding="utf-8"))
    out = []
    n0 = len(data.get("elements", []))
    for el in data.get("elements", []):
        t = el.get("type")
        moved = mover.way(el) if t == "way" else mover.relation(el) if t == "relation" \
            else mover.node(el) if t == "node" and "lat" in el else el
        if moved is not None:
            out.append(moved)
    data["elements"] = out
    return data, n0, len(out)


def write_file(dst, data):
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, separators=(",", ":"))


def pair_ends(ends):
    """Deck ends on the near side (-1) matched to the nearest unclaimed end
    on the far side (1) within SNAP m: (near, far or None, distance) for
    every near end, then the far ends left over."""
    near = [e for e in ends if e[0] == -1]
    far = [e for e in ends if e[0] == 1]
    taken = set()
    pairs = []
    for e in near:
        best, bd = None, SNAP
        for j, f in enumerate(far):
            if j in taken:
                continue
            d = math.hypot(e[3] - f[3], e[4] - f[4])
            if d < bd:
                best, bd = j, d
        if best is not None:
            taken.add(best)
        pairs.append((e, far[best] if best is not None else None, bd))
    return pairs, [f for j, f in enumerate(far) if j not in taken]


# --- the new frame ------------------------------------------------------------
def boundary(frame, cuts, bbox):
    """The bbox rectangle moved through the cuts, as the points of one
    closed boundary way, and the bbox osm_city.py will derive from it."""
    s, w, n, e = bbox
    x0, z0 = frame.xz(w, n)
    x1, z1 = frame.xz(e, s)
    corners = [(x0, z0), (x1, z0), (x1, z1), (x0, z1)]
    pts = []
    for (ax, az), (bx, bz) in zip(corners, corners[1:] + corners[:1]):
        steps = max(1, int(math.hypot(bx - ax, bz - az) // 50.0))
        for t in np.arange(steps) / steps:
            pts.append((ax + (bx - ax) * t, az + (bz - az) * t))
    x, z = np.array(pts).T
    keep, wx, wz, _, _, _ = cuts.line(x, z, "closed")
    lon, lat = frame.lonlat(wx[keep], wz[keep])
    lon, lat = np.round(lon, DP), np.round(lat, DP)
    geom, last = [], None
    for la, lo in zip(lat, lon):
        p = {"lat": float(la), "lon": float(lo)}
        if p != last:
            geom.append(p)
        last = p
    geom.append(dict(geom[0]))
    s2, w2 = min(p["lat"] for p in geom), min(p["lon"] for p in geom)
    n2, e2 = max(p["lat"] for p in geom), max(p["lon"] for p in geom)
    rel = {"type": "relation", "id": -1, "tags": {"boundary": "administrative", "name": "compressed map"},
           "members": [{"type": "way", "ref": -1, "role": "outer", "geometry": geom}]}
    return {"elements": [rel]}, (s2, w2, n2, e2)


def to_new(frame, new, x, z):
    """Moved frame metres -> new-frame metres."""
    lon, lat = frame.lonlat(x, z)
    return new.xz(lon, lat)


# --- lidar ------------------------------------------------------------------
def move_lidar(path, dst, frame, cuts, new, bbox):
    d = np.load(path)
    meta = json.loads(str(d["meta"]))
    src = Frame(*meta["origin"])
    lon, lat = src.lonlat(d["x"].astype(np.float64), d["z"].astype(np.float64))
    x, z = frame.xz(lon, lat)
    s, w, n, e = bbox
    x0, z0 = frame.xz(w, n)
    x1, z1 = frame.xz(e, s)
    keep = (x >= x0 - LIDAR_MARGIN) & (x <= x1 + LIDAR_MARGIN) & (z >= z0 - LIDAR_MARGIN) & (z <= z1 + LIDAR_MARGIN)
    x, z, h, c = x[keep], z[keep], d["h"][keep], d["cls"][keep]
    gone = cuts.deleted(x, z)
    x, z, h, c = x[~gone], z[~gone], h[~gone], c[~gone]
    x, z = to_new(frame, new, *cuts.warp(x, z))
    meta["origin"] = [new.lat0, new.lon0]
    meta["compressed"] = {"from": os.path.basename(path), "in_bbox": int(keep.sum()), "dropped_in_cuts": int(gone.sum())}
    np.savez_compressed(dst, x=x.astype(np.float32), z=z.astype(np.float32), h=h, cls=c, meta=json.dumps(meta))
    return int(len(d["x"])), int(keep.sum()), int(gone.sum())


# --- decks ------------------------------------------------------------------
def move_decks(path, dst, frame, cuts, new, log):
    d = json.load(open(path, encoding="utf-8"))
    if [round(v, 6) for v in d["origin"]] != [round(frame.lat0, 6), round(frame.lon0, 6)]:
        raise SystemExit("compress: %s is in frame %s, the cuts in %s" % (path, d["origin"], [frame.lat0, frame.lon0]))
    kept, dropped = [], []
    for r in d.get("decks", []):
        if r.get("source") != "hand":
            continue
        x = np.array([n["x"] for n in r["nodes"]])
        z = np.array([n["z"] for n in r["nodes"]])
        keep, wx, wz, sides, _, _ = cuts.line(x, z, "open")
        if not keep.all() or (sides != sides[0]).any():
            dropped.append(r)
            continue
        nx, nz = to_new(frame, new, wx, wz)
        rr = dict(r)
        rr["nodes"] = [dict(n, x=round(float(a), 2), z=round(float(b), 2)) for n, a, b in zip(r["nodes"], nx, nz)]
        kept.append(rr)
    fills, fills_dropped = [], 0
    for f in d.get("fills", []):
        if cuts.deleted(f["x"], f["z"])[0]:
            fills_dropped += 1
            continue
        nx, nz = to_new(frame, new, *cuts.warp(f["x"], f["z"]))
        fills.append(dict(f, x=round(float(nx), 1), z=round(float(nz), 1)))
    for r in dropped:
        log("  hand record %d (%s %s) touches a cut: dropped, the seed decides it" % (r["way"], r["class"], r["name"] or "unnamed"))
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"format": 1, "origin": [new.lat0, new.lon0], "seeded_from": "compress",
                   "lidar": None, "decks": kept, "fills": fills}, f, indent=1)
    return len(kept), len(dropped), len(fills), fills_dropped


def deck_cliffs(path, cuts):
    """What the cuts do to the elevated records, as the seed will see them
    (its own ways survive the cuts the same way): records crossing a
    deleted band, with the drop between their two sides over the chord
    that is left; and records ending inside one, on the line now, with
    their height where they meet it."""
    d = json.load(open(path, encoding="utf-8"))
    chords, ends = [], {}
    for r in d.get("decks", []):
        x = np.array([n["x"] for n in r["nodes"]])
        z = np.array([n["z"] for n in r["nodes"]])
        h = np.array([n["h"] for n in r["nodes"]])
        keep, wx, wz, _, deleted_by, rends = cuts.line(x, z, "open")
        if keep.all() or not keep.any():
            continue
        label = "%s %d %s" % (r["class"], r["way"], (r["name"] or "")[:24])
        for j, bi, side, _ in rends:
            ends.setdefault(bi, []).append((side, r["class"], label, float(wx[j]), float(wz[j]), float(h[j])))
        moved = {j for j, _, _, _ in rends}
        ks = np.flatnonzero(keep)
        for i, k in zip(ks, ks[1:]):
            if k - i > 1 and i not in moved and k not in moved:
                span = math.hypot(wx[k] - wx[i], wz[k] - wz[i])
                drop = abs(h[k] - h[i])
                chords.append((label, float(h[i]), float(h[k]), span, 100.0 * drop / span if span > 0.5 else float("inf")))
    return chords, ends


# --- main -------------------------------------------------------------------
def main():
    global SNAP
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cuts")
    ap.add_argument("raw")
    ap.add_argument("out")
    ap.add_argument("--lidar", default=LIDAR, help="lidar_decks.npz to move; '' for none")
    ap.add_argument("--decks", help="decks.json whose hand records and fills to carry over")
    ap.add_argument("--decks-out", help="the blockout dir to write the carried decks.json into")
    ap.add_argument("--water-seeds", default="")
    ap.add_argument("--mark", action="append", default=[], help="name=x,z in the frame, reported where it lands")
    ap.add_argument("--snap", type=float, default=SNAP, help="metres: join the ends of one street this far apart on the line (default %g)" % SNAP)
    a = ap.parse_args()
    SNAP = a.snap
    if os.path.normcase(os.path.abspath(a.out)) == os.path.normcase(os.path.abspath(a.raw)):
        sys.exit("compress: out must not be the raw dir")
    spec = json.load(open(a.cuts, encoding="utf-8"))
    city = json.load(open(os.path.join(ROOT, spec["frame"]) if not os.path.isabs(spec["frame"]) else spec["frame"], encoding="utf-8"))
    frame = Frame(*city["origin"])
    bbox = tuple(spec.get("bbox") or city["bbox"])
    cuts = Cuts(spec["cuts"])
    lines = []

    def log(msg):
        print(msg, flush=True)
        lines.append(msg)

    os.makedirs(a.out, exist_ok=True)
    bnd, nbbox = boundary(frame, cuts, bbox)
    new = Frame.of_bbox(*nbbox)
    with open(os.path.join(a.out, "boundary.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(bnd, f)
    for band in cuts.bands:
        log("cut %-28s %s  %s" % (band.name, band.desc, "deleted" if band.keep == 0 else "kept %.0f%%" % (100 * band.keep)))
    log("bbox %s -> %s" % (list(bbox), [round(v, 6) for v in nbbox]))
    log("origin %s -> %s" % (city["origin"], [round(new.lat0, 6), round(new.lon0, 6)]))
    w0 = frame.xz(bbox[3], bbox[0])[0] - frame.xz(bbox[1], bbox[2])[0]
    w1 = new.xz(nbbox[3], nbbox[0])[0] - new.xz(nbbox[1], nbbox[2])[0]
    h0 = frame.xz(bbox[3], bbox[0])[1] - frame.xz(bbox[1], bbox[2])[1]
    h1 = new.xz(nbbox[3], nbbox[0])[1] - new.xz(nbbox[1], nbbox[2])[1]
    log("map %.0f x %.0f m -> %.0f x %.0f m" % (w0, h0, w1, h1))

    mover = Mover(frame, cuts)
    moved = []
    for name in sorted(os.listdir(a.raw)):
        if not name.endswith(".json") or name == "boundary.json":
            continue
        data, n0, n1 = move_file(os.path.join(a.raw, name), mover)
        moved.append((name, data))
        log("%-18s %7d elements -> %7d" % (name, n0, n1))
    joins = {bi: mover.snap(bi) for bi, band in enumerate(cuts.bands) if band.keep == 0.0}
    for name, data in moved:
        write_file(os.path.join(a.out, name), data)
    log("buildings: %d kept, %d clipped, %d removed; %d multipolygon members dropped"
        % (mover.buildings["kept"], mover.buildings["clipped"], mover.buildings["removed"], mover.members_dropped))
    order = list(ROADS) + ["rail"]
    rank = lambda c: order.index(c) if c in order else 99
    fmt = lambda d: ", ".join("%s %d" % (c, d[c]) for c in sorted(d, key=rank))
    for bi, band in enumerate(cuts.bands):
        cr = {c: n for (b, c), n in mover.crossed.items() if b == bi and c}
        rm = {c: n for (b, c), n in mover.removed.items() if b == bi and c}
        log("band %s: crossing: %s" % (band.name, fmt(cr) or "nothing"))
        log("band %s: removed: %s" % (band.name, fmt(rm) or "nothing"))
        if band.keep != 0.0:
            continue
        total, shared, snapped, longest, loose = joins[bi]
        log("band %s: %d street ends on the line, %d met at a shared node, %d snapped together (longest %.0f m), %d left loose"
            % (band.name, total, shared, snapped, longest, len(loose)))
        for e in sorted(loose, key=lambda e: (rank(e.cls), e.x)):
            if e.cls in MAJOR:
                log("  loose %-14s %-24s %s side at (%.0f, %.0f)" % (e.cls, (e.name or "")[:24], "near" if e.side == -1 else "far", e.x, e.z))
        chords = sorted(mover.chords.get(bi, []), reverse=True)
        width = band.b - band.a
        shallow = [c for c in chords if c[0] > width]
        log("band %s: %d streets chorded across it along the line, %d of them by more than the band's width "
            "(a street crossing at a shallow angle: its chord runs along the seam with nothing under it)"
            % (band.name, len(chords), len(shallow)))
        for length, cls, nm in [c for c in chords if c[1] in MAJOR][:8]:
            log("  chord %5.0f m  %-14s %s" % (length, cls, (nm or "")[:24]))

    if a.decks:
        chords, dends = deck_cliffs(a.decks, cuts)
        if chords:
            log("elevated records crossing a deleted band (height each side, chord left, grade):")
            for label, h0_, h1_, span, grade in sorted(chords, key=lambda c: -c[4]):
                log("  %-44s %5.1f -> %5.1f m over %6.1f m  %s" % (label, h0_, h1_, span,
                    "%.0f%%" % grade if grade != float("inf") else "a wall"))
        for bi, band in enumerate(cuts.bands):
            if bi not in dends:
                continue
            pairs, far_left = pair_ends(dends[bi])
            log("band %s: elevated ends on the line (near -> far, height step where they meet):" % band.name)
            for e, f, d in sorted(pairs, key=lambda p: -abs(p[0][5] - p[1][5]) if p[1] else 0):
                if f is None:
                    log("  %-44s %5.1f m  ends in the air, nothing across" % (e[2], e[5]))
                else:
                    log("  %-44s %5.1f -> %5.1f m  step %4.1f m, %2.0f m apart  -> %s" % (e[2], e[5], f[5], f[5] - e[5], d, f[2]))
            for f in far_left:
                log("  %-44s %5.1f m  starts in the air, nothing across" % (f[2], f[5]))
        if a.decks_out:
            kept, dropped, fills, fd = move_decks(a.decks, os.path.join(a.decks_out, "decks.json"), frame, cuts, new, log)
            log("hand records: %d carried, %d dropped; fills: %d carried, %d dropped" % (kept, dropped, fills, fd))
    if a.lidar:
        total, inside, gone = move_lidar(a.lidar, os.path.join(a.out, "lidar_decks.npz"), frame, cuts, new, bbox)
        log("lidar: %d returns, %d in the bbox, %d dropped in cuts -> %s" % (total, inside, gone, os.path.join(a.out, "lidar_decks.npz")))

    seeds = []
    for seed in filter(None, a.water_seeds.split(";")):
        lat, lon = (float(v) for v in seed.split(","))
        x, z = frame.xz(lon, lat)
        if cuts.deleted(x, z)[0]:
            log("water seed %s is inside a deleted band: choose another" % seed)
            continue
        lon2, lat2 = frame.lonlat(*cuts.warp(x, z))
        seeds.append("%.6f,%.6f" % (lat2, lon2))
    marks = {}
    for m in a.mark:
        name, xz = m.split("=")
        x, z = (float(v) for v in xz.split(","))
        if cuts.deleted(x, z)[0]:
            log("mark %s (%g, %g) is inside a deleted band" % (name, x, z))
            continue
        nx, nz = to_new(frame, new, *cuts.warp(x, z))
        marks[name] = [round(float(nx), 1), round(float(nz), 1)]
        log("mark %s (%g, %g) -> (%.1f, %.1f)" % (name, x, z, nx, nz))
    cmd = "python -I tools/blockout/osm_city.py %s data/blockouts/<name>" % a.out
    if seeds:
        cmd += ' --water-seeds "%s"' % ";".join(seeds)
    log("next: " + cmd + "  (no --bbox: boundary.json is the map)")
    with open(os.path.join(a.out, "compress.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"frame": spec["frame"], "bbox": list(bbox), "cuts": spec["cuts"], "new_bbox": list(nbbox),
                   "new_origin": [new.lat0, new.lon0], "water_seeds": seeds, "marks": marks, "report": lines}, f, indent=1)


if __name__ == "__main__":
    main()

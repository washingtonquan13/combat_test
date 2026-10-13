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
crosses it sideways by the band's width times the skew. A band with "curve" instead has a street's own shape for
each edge, for grids whose streets bend or fan:

    {"name": "Laurel row", "curve": {"angle": 176.7,
     "s": [...], "near": [...], "far": [...], "shift": [[s, dx, dz], ...], "rays": [[[u, s], ...], ...]}}

"angle" is the band's rough direction; s is the distance along it
(x*cos(angle) + z*sin(angle)) and u the distance across, measured as for a
straight band. "near" and "far" are the u of the band's two edges at each
s (held flat past the ends), so the band is the ground between two
streets: the near street stays and the far one goes with the row between
them. Everything past the far edge moves by "shift" at its own s, linear
between the samples and held past the ends: each sample is a cross street,
moved from where it crosses the far edge onto where it crosses the near
one, so it closes up across the gap with no chord, and the ground between
two cross streets takes the small difference between their shifts.
"rays" (optional), one per shift sample, is that cross street past the
far edge as (u, s) with u rising, as far as it runs: a point takes the
shift of where it sits between the two rays either side of it at its own
u, so a cross street that leans or bends moves as one piece however far
it runs; past a ray's end its place is kept between its neighbours that
run on and its shift blends into theirs, so the shift never jumps where a
street stops. Curve
bands of one angle are all measured in the source map and their shifts
add (order does not matter); any other mix applies in order as below.
Ground past the far edge is not cut, so a building is moved whole by the
shift at its centre instead of point by point (only with curve bands).
"keep" is what
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
TEE = 1.0  # metres: a loose end this close to another road is spliced into it
TOUCH = 1.5  # metres: buildings this close move as one block under a curve cut
RIGID_TOL = 1.0  # metres: a block whose best rigid move misses the warp by more follows the warp
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



class CurveBand:
    """A band between two streets: see the module doc. Deletes what lies
    between the edges (a point on the near edge stays, one on the far edge
    goes), moves what lies past the far edge by the shift at its s, and
    puts a kept end inside onto the near edge, at the s its shift gives it
    when it is nearer the far edge, so an end that met a far street meets
    the near one."""

    EPS = 0.3  # m: a point this close to an edge is on it

    def __init__(self, spec):
        c = spec["curve"]
        self.name = spec.get("name", "")
        self.keep = 0.0
        ang = math.radians(float(c["angle"]))
        self.tx, self.tz = math.cos(ang), math.sin(ang)
        self.c, self.s = math.cos(ang + math.pi / 2), math.sin(ang + math.pi / 2)
        self.S = np.asarray(c["s"], float)
        self.near = np.asarray(c["near"], float)
        self.far = np.asarray(c["far"], float)
        sh = np.asarray(c["shift"], float).reshape(-1, 3)
        o = np.argsort(sh[:, 0])
        sh = sh[o]
        self.ss, self.dx, self.dz = sh[:, 0], sh[:, 1], sh[:, 2]
        rays = c.get("rays")
        if rays is not None and len(rays) != len(o):
            raise SystemExit("compress: curve band %r has %d rays for %d shifts" % (self.name, len(rays), len(o)))
        self.rays = [np.asarray(rays[i], float).reshape(-1, 2) for i in o] if rays is not None else None
        if self.rays:
            self._ray_table()
        if len(self.S) < 2 or np.any(np.diff(self.S) <= 0) or len(self.near) != len(self.S) \
                or len(self.far) != len(self.S) or not len(self.ss) or np.any(self.far <= self.near):
            raise SystemExit("compress: bad curve band %r" % self.name)
        self.a, self.b = float(np.median(self.near)), float(np.median(self.far))
        self.desc = "curve at %g deg, %d shift samples, %.0f m wide (median)" % (float(c["angle"]), len(self.ss), self.b - self.a)
        if not self.name:
            self.name = self.desc

    def _ray_table(self):
        """Every ray's s and shift at every u any ray has a vertex at (self.U;
        self.RS, self.DX, self.DZ). Past its end a ray goes on as a ghost
        that keeps its place between the two rays either side of it that
        still run (the same fraction of the way from one to the other), or
        its distance from the one ray on its side, or its s when none runs;
        its shift blends into what its neighbours give at that place over as
        far as it is from the nearer of them (a street ending on another
        hands over at once). So the shift never jumps where a street stops."""
        self.U = np.unique(np.concatenate([r[:, 0] for r in self.rays]))
        n = len(self.rays)
        end = np.array([r[-1, 0] for r in self.rays])
        RS = np.array([np.interp(self.U, r[:, 0], r[:, 1]) for r in self.rays]).T  # rows u, columns rays
        DX = np.tile(self.dx, (len(self.U), 1))
        DZ = np.tile(self.dz, (len(self.U), 1))
        for i in np.argsort(-end, kind="stable"):
            past = self.U > end[i]
            if not past.any():
                continue
            se = self.rays[i][-1, 1]
            run = [j for j in range(n) if end[j] > end[i]]  # placed already: they end later
            at = {j: float(np.interp(end[i], self.U, RS[:, j])) for j in run}
            lo = max((j for j in run if at[j] <= se), key=lambda j: at[j], default=None)
            hi = min((j for j in run if at[j] > se), key=lambda j: at[j], default=None)
            if lo is not None and hi is not None:
                f = (se - at[lo]) / (at[hi] - at[lo])
                RS[past, i] = RS[past, lo] + f * (RS[past, hi] - RS[past, lo])
                nx = DX[past, lo] + f * (DX[past, hi] - DX[past, lo])
                nz = DZ[past, lo] + f * (DZ[past, hi] - DZ[past, lo])
                gap = min(se - at[lo], at[hi] - se)
            elif lo is not None or hi is not None:
                j = lo if lo is not None else hi
                RS[past, i] = RS[past, j] + (se - at[j])
                nx, nz, gap = DX[past, j], DZ[past, j], abs(se - at[j])
            else:
                RS[past, i] = se
                continue
            w = np.clip((self.U[past] - end[i]) / max(gap, 1e-6), 0.0, 1.0)
            DX[past, i] = self.dx[i] + w * (nx - self.dx[i])
            DZ[past, i] = self.dz[i] + w * (nz - self.dz[i])
        self.RS, self.DX, self.DZ = RS, DX, DZ

    def _su(self, x, z):
        x, z = np.asarray(x, float), np.asarray(z, float)
        return x * self.tx + z * self.tz, x * self.c + z * self.s

    def side(self, x, z):
        s, u = self._su(x, z)
        un, uf = np.interp(s, self.S, self.near), np.interp(s, self.S, self.far)
        return np.where(u <= un + self.EPS, -1, np.where(u < uf + self.EPS, 0, 1))

    def deletes(self, x, z):
        return self.side(x, z) == 0

    def shift(self, x, z):
        s, u = self._su(x, z)
        if not self.rays:
            return np.interp(s, self.ss, self.dx), np.interp(s, self.ss, self.dz)
        # With rays: the two cross streets (or their ghosts) either side of
        # the point at its own u, and the point's place between them.
        shape = s.shape
        s, u = s.reshape(-1), u.reshape(-1)
        j = np.clip(np.searchsorted(self.U, u), 1, max(len(self.U) - 1, 1))
        if len(self.U) > 1:
            t = np.clip((u - self.U[j - 1]) / (self.U[j] - self.U[j - 1]), 0.0, 1.0)[:, None]
            row = lambda T: (T[j - 1] + t * (T[j] - T[j - 1])).T
        else:
            row = lambda T: np.repeat(T[:1].T, s.size, axis=1)
        R, DX, DZ = row(self.RS), row(self.DX), row(self.DZ)
        Rl = np.where(R <= s, R, -np.inf)
        Rh = np.where(R > s, R, np.inf)
        lo, hi = Rl.argmax(0), Rh.argmin(0)
        cols = np.arange(s.size)
        has_lo, has_hi = np.isfinite(Rl[lo, cols]), np.isfinite(Rh[hi, cols])
        lo = np.where(has_lo, lo, hi)
        hi = np.where(has_hi, hi, lo)
        rl, rh = R[lo, cols], R[hi, cols]
        f = np.where(rh > rl, (s - rl) / np.where(rh > rl, rh - rl, 1.0), 0.0)
        dx = DX[lo, cols] + f * (DX[hi, cols] - DX[lo, cols])
        dz = DZ[lo, cols] + f * (DZ[hi, cols] - DZ[lo, cols])
        return dx.reshape(shape), dz.reshape(shape)

    def warp(self, x, z):
        x, z = np.asarray(x, float), np.asarray(z, float)
        s, u = self._su(x, z)
        un, uf = np.interp(s, self.S, self.near), np.interp(s, self.S, self.far)
        dx, dz = self.shift(x, z)
        side = np.where(u <= un + self.EPS, -1, np.where(u < uf + self.EPS, 0, 1))
        ix, iz = self.inside(s, u) if self.rays else self.across(x, z, s, u, un, uf, dx, dz)
        return (np.where(side == 1, x + dx, np.where(side == 0, ix, x)),
                np.where(side == 1, z + dz, np.where(side == 0, iz, z)))

    def across(self, x, z, s, u, un, uf, dx, dz):
        """Inside, without rays: onto the near edge, carried along by the
        shift if nearer the far one."""
        late = (u - un) > (uf - u)
        ix, iz = x + np.where(late, dx, 0.0), z + np.where(late, dz, 0.0)
        s2, u2 = self._su(ix, iz)
        drop = u2 - np.interp(s2, self.S, self.near)
        return ix - drop * self.c, iz - drop * self.s

    def inside(self, s, u):
        """Inside, with rays: each shift sample is a cross street running
        straight from its far crossing b (on the far edge at its s) to its
        near crossing a = b + shift. A point goes to the near edge where it
        sits between the two either side of it at its own u, so a street
        ending inside meets its cross street's near crossing exactly."""
        shape = s.shape
        s, u = s.reshape(-1), u.reshape(-1)
        bs = self.ss
        bu = np.interp(bs, self.S, self.far)
        as_ = bs + self.dx * self.tx + self.dz * self.tz
        au = bu + self.dx * self.c + self.dz * self.s
        w = np.clip((u[None, :] - au[:, None]) / np.maximum(bu - au, 1e-6)[:, None], 0.0, 1.0)
        R = as_[:, None] + w * (bs - as_)[:, None]  # chord s at each point's u
        Rl = np.where(R <= s, R, -np.inf)
        Rh = np.where(R > s, R, np.inf)
        lo, hi = Rl.argmax(0), Rh.argmin(0)
        cols = np.arange(s.size)
        has_lo, has_hi = np.isfinite(Rl[lo, cols]), np.isfinite(Rh[hi, cols])
        lo, hi = np.where(has_lo, lo, hi), np.where(has_hi, hi, lo)
        rl, rh = R[lo, cols], R[hi, cols]
        f = np.where(rh > rl, (s - rl) / np.where(rh > rl, rh - rl, 1.0), 0.0)
        st = as_[lo] + f * (as_[hi] - as_[lo]) + np.where(has_lo & has_hi, 0.0, s - rl)
        ut = np.interp(st, self.S, self.near)
        ix = st * self.tx + ut * self.c
        iz = st * self.tz + ut * self.s
        return ix.reshape(shape), iz.reshape(shape)


def make_band(spec):
    return CurveBand(spec) if "curve" in spec else Band(spec)


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
        self.bands = [make_band(s) for s in spec]
        self.rigid = any(isinstance(b, CurveBand) for b in self.bands)
        # Curve bands of one family side by side are all measured in the
        # source map and their moves add: band order then changes nothing,
        # and a cross street leans through each band as it really does.
        self.parallel = all(isinstance(b, CurveBand) for b in self.bands) and \
            len({round(b.tx, 9) for b in self.bands}) == 1
        if not self.bands:
            raise SystemExit("compress: no cuts")

    def deleted(self, x, z):
        """Points inside a band that keeps nothing, at the stage it applies."""
        x, z = np.array(x, float, ndmin=1), np.array(z, float, ndmin=1)
        gone = np.zeros(x.shape, bool)
        for band in self.bands:
            gone |= band.deletes(x, z)
            if not self.parallel:
                x, z = band.warp(x, z)
        return gone

    def warp(self, x, z):
        if self.parallel:
            x, z = np.asarray(x, float), np.asarray(z, float)
            ox, oz = x.copy(), z.copy()
            for band in self.bands:
                wx, wz = band.warp(x, z)
                ox, oz = ox + (wx - x), oz + (wz - z)
            return ox, oz
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
            if not self.parallel:
                px[alive], pz[alive] = band.warp(px[alive], pz[alive])
        if self.parallel:
            alive = np.flatnonzero(keep)
            px[alive], pz[alive] = self.warp(px[alive], pz[alive])
        ends = [e for e in ends if keep[e[0]]]
        if self.parallel:
            # An end inside goes where its own line leaves the band on the
            # anchor's side, then moves as that spot does: on the near
            # edge it stays, just past the far one it takes its cross
            # street's shift, so either way it meets the street it left.
            x0, z0 = np.asarray(x, float), np.asarray(z, float)
            for e, bi, side, anchor in ends:
                band = self.bands[bi]
                step = 1 if e > anchor else -1
                k = anchor
                while k != e and band.side(x0[k + step], z0[k + step]) == side:
                    k += step
                if k == e:
                    continue
                lo, hi = 0.0, 1.0  # fraction from node k to k+step still on the anchor's side
                for _ in range(40):
                    m = (lo + hi) / 2
                    if band.side(x0[k] + m * (x0[k + step] - x0[k]), z0[k] + m * (z0[k + step] - z0[k])) == side:
                        lo = m
                    else:
                        hi = m
                qx = np.array([x0[k] + lo * (x0[k + step] - x0[k])])
                qz = np.array([z0[k] + lo * (z0[k + step] - z0[k])])
                wx, wz = self.warp(qx, qz)
                px[e], pz[e] = wx[0], wz[0]
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
        self.blocks = {}  # building way id -> (cos, sin, cx, cz, tx, tz): its block's rigid move
        self.block_stats = {"blocks": 0, "rigid": 0, "warped": 0, "worst_m": 0.0}

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

    def tee(self, moved, loose):
        """Loose ends that landed on another road join it: a street that
        met the deleted one at a T meets the road the cut closed onto, so
        its end node is put on that road's line and spliced into its nodes.
        Returns the ends joined."""
        segs = []  # (way element, segment index, ax, az, bx, bz)
        for _, data in moved:
            for el in data["elements"]:
                if el.get("type") != "way" or el.get("tags", {}).get("highway") not in ROADS:
                    continue
                g, nodes = el.get("geometry") or [], el.get("nodes") or []
                if len(g) < 2 or len(nodes) != len(g) or not all(g):
                    continue
                x, z = self.frame.xz([q["lon"] for q in g], [q["lat"] for q in g])
                for i in range(len(g) - 1):
                    segs.append((el, i, x[i], z[i], x[i + 1], z[i + 1]))
        if not segs or not loose:
            return []
        A = np.array([q[2:4] for q in segs])
        D = np.array([q[4:6] for q in segs]) - A
        L2 = np.maximum((D ** 2).sum(1), 1e-12)
        splice, joined = {}, []
        for e in loose:
            if e.node is None:
                continue
            t = np.clip(((e.x - A[:, 0]) * D[:, 0] + (e.z - A[:, 1]) * D[:, 1]) / L2, 0.0, 1.0)
            q = A + D * t[:, None]
            d = np.hypot(q[:, 0] - e.x, q[:, 1] - e.z)
            for j in np.argsort(d)[:8]:
                if d[j] > TEE:
                    break
                el, i = segs[j][0], segs[j][1]
                if e.node in el["nodes"] or not 0.0 < t[j] < 1.0:
                    continue  # its own road, or a vertex: that node already is a junction
                e.x, e.z = float(q[j, 0]), float(q[j, 1])
                lon, lat = self.frame.lonlat(e.x, e.z)
                e.point["lon"], e.point["lat"] = float(np.round(lon, DP)), float(np.round(lat, DP))
                splice.setdefault(id(el), (el, []))[1].append((i, float(t[j]), e))
                joined.append(e)
                break
        for el, ins in splice.values():
            for i, _, e in sorted(ins, key=lambda r: (r[0], r[1]), reverse=True):
                el["nodes"].insert(i + 1, e.node)
                el["geometry"].insert(i + 1, dict(e.point))
        return joined

    def way(self, el):
        """A way element moved; None when nothing of it is left."""
        geom = el.get("geometry") or []
        if not geom:
            return el
        closed = len(geom) > 3 and geom[0] == geom[-1]
        tags = el.get("tags", {})
        cls = tags.get("highway") or ("rail" if tags.get("railway") == "rail" else None)
        pts, survived = self.points(geom, "closed" if closed else "open", cls, tags.get("name"), el.get("nodes"))
        if self.cuts.rigid and "building" in tags and closed and survived.all() and el.get("id") in self.blocks:
            pts = self.rigid(geom, self.blocks[el["id"]])
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

    def rigid(self, geom, move):
        """A ring moved by its block's rotation and translation."""
        c, sn, cx, cz, tx, tz = move
        lon = np.array([g["lon"] for g in geom])
        lat = np.array([g["lat"] for g in geom])
        x, z = self.frame.xz(lon, lat)
        x, z = x - cx, z - cz
        lon, lat = self.frame.lonlat(c * x - sn * z + tx, sn * x + c * z + tz)
        lon, lat = np.round(lon, DP), np.round(lat, DP)
        return [{"lat": float(a), "lon": float(o)} for a, o in zip(lat, lon)]

    def plan_blocks(self, raw):
        """Under curve cuts the shift varies from place to place, so each
        building moving by its own centre's shift would pull touching
        neighbours into each other. Buildings within TOUCH m of each other
        form a block, and a block moves as one: the rotation and
        translation that best fit the warp over all its kept corners. A
        block that fit misses by more than RIGID_TOL m is left out, and
        its buildings follow the warp corner by corner, which is
        continuous, so they still cannot tear apart."""
        import shapely
        rings, ids = [], []
        for name in sorted(os.listdir(raw)):
            if not name.endswith(".json") or name == "boundary.json":
                continue
            for el in json.load(open(os.path.join(raw, name), encoding="utf-8")).get("elements", []):
                g = el.get("geometry") or []
                if el.get("type") != "way" or "building" not in el.get("tags", {}) or len(g) < 4                         or g[0] != g[-1] or not all(g):
                    continue
                x, z = self.frame.xz(np.array([q["lon"] for q in g]), np.array([q["lat"] for q in g]))
                keep = self.cuts.line(x, z, "closed")[0]
                if keep.all():
                    rings.append(np.c_[x, z][:-1])
                    ids.append(el["id"])
        if not rings:
            return
        polys = np.array([shapely.Polygon(r).buffer(0) for r in rings], dtype=object)
        a, b = shapely.STRtree(polys).query(polys, predicate="dwithin", distance=TOUCH)
        root = list(range(len(rings)))
        def find(i):
            while root[i] != i:
                root[i] = root[root[i]]
                i = root[i]
            return i
        for i, j in zip(a, b):
            root[find(i)] = find(j)
        groups = {}
        for i in range(len(rings)):
            groups.setdefault(find(i), []).append(i)
        for members in groups.values():
            P = np.vstack([rings[i] for i in members])
            wx, wz = self.cuts.warp(P[:, 0], P[:, 1])
            W = np.c_[wx, wz]
            pc, wc = P.mean(0), W.mean(0)
            A, B = P - pc, W - wc
            th = math.atan2((A[:, 0] * B[:, 1] - A[:, 1] * B[:, 0]).sum(), (A * B).sum())
            c, sn = math.cos(th), math.sin(th)
            miss = np.hypot(c * A[:, 0] - sn * A[:, 1] - B[:, 0], sn * A[:, 0] + c * A[:, 1] - B[:, 1]).max()
            self.block_stats["blocks"] += 1
            self.block_stats["worst_m"] = max(self.block_stats["worst_m"], float(miss)) if miss <= RIGID_TOL                 else self.block_stats["worst_m"]
            if miss > RIGID_TOL:
                self.block_stats["warped"] += 1
                continue
            self.block_stats["rigid"] += 1
            for i in members:
                self.blocks[ids[i]] = (c, sn, float(pc[0]), float(pc[1]), float(wc[0]), float(wc[1]))

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
    if cuts.rigid:
        mover.plan_blocks(a.raw)
        st = mover.block_stats
        log("building blocks: %d, %d moved rigidly (worst fit %.2f m), %d follow the warp (fit off by more than %g m)"
            % (st["blocks"], st["rigid"], st["worst_m"], st["warped"], RIGID_TOL))
    moved = []
    for name in sorted(os.listdir(a.raw)):
        if not name.endswith(".json") or name == "boundary.json":
            continue
        data, n0, n1 = move_file(os.path.join(a.raw, name), mover)
        moved.append((name, data))
        log("%-18s %7d elements -> %7d" % (name, n0, n1))
    joins = {bi: mover.snap(bi) for bi, band in enumerate(cuts.bands) if band.keep == 0.0}
    teed = {id(e) for e in mover.tee(moved, [e for j in joins.values() for e in j[4]])}
    joins = {bi: (*j[:4], [e for e in j[4] if id(e) not in teed], sum(id(e) in teed for e in j[4])) for bi, j in joins.items()}
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
        total, shared, snapped, longest, loose, nteed = joins[bi]
        log("band %s: %d street ends on the line, %d met at a shared node, %d snapped together (longest %.0f m), "
            "%d joined the road the cut closed onto, %d left loose" % (band.name, total, shared, snapped, longest, nteed, len(loose)))
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

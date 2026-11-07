"""Continuous warp of COMPRESSION_PLAN.md: the whole city into one rounded rectangle.

    python -I tools/blockout/parish_warp.py <segment dir> [--raw <raw dir> --out <out raw dir>]
        [--area 100] [--aniso 2] [--dmin 0.75] [--png out.png]

The source is a rounded rectangle around parish_districts.py's districts
(plus MARGIN, clipped to the download); the target is the same outline
scaled to --area km2 about its centre. A triangle mesh on a grid of H m
covers it; triangles whose centroid lies outside the outline are dead, and
the live ones' outer vertices are pinned onto the target outline. A
weighted as-rigid-as-possible solve (local/global, CG) then moves the mesh
so that:

  - every district triangle keeps its true shape at one shared scale D
    (weight W_STIFF, ramping down to 1 over RAMP m outside a district);
  - every other triangle takes whatever it needs within bounds: neither
    axis grows, neither shrinks below MIN_SCALE, and no squeeze is more
    than ANISO one way than the other. Triangles that break a bound get
    their weight raised (BOOST) until they keep it.

D starts at 1; if the gates fail there, DMIN (--dmin) is tried and then D
is bisected between them, so the districts stay as close to true size as
the area allows. A map much smaller than its source (the whole parish into
100 km2) needs a lower --dmin.

The map is piecewise affine over the mesh, so it is one continuous,
one-to-one deformation whenever no triangle flips: streets stay joined,
nothing tears, and there are no seams. Outside the rectangle points move
with the nearest edge point, so osm_city.py's clip to boundary.json cuts
whole features.

With --raw/--out every lat/lon of the raw dir goes through the map (the
compress.py Mover: buildings that fit a rigid move to within 1 m keep
their shape exactly), the LiDAR with them, and boundary.json is the
rounded rectangle. Writes warp.json (the gates, marks) to --out, and
water_seeds.json: a point inside each piece of the water the map's edge
cuts open (WATER_SEEDS, flooded in the source, where the whole of it is
known), carried through the warp for osm_city.py.

With --raw, the streets that run straight in the source (Lines) are held
straight: each pulls its samples onto its own best-fit line, refitted every
iteration, so a straight street may move and turn but not bow. Streets
that truly curve are left to the warp.

Gates: no flipped triangle; district scale within 1 +- DIST_TOL over 95% of
district area; nowhere scaled below MIN_SCALE; nowhere stretched more than
ANISO times one way than the other; with --raw, LINE_SHARE of the straight
streets' length bowing no more than LINE_TOL.
"""
import argparse
import json
import math
import os
import sys
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import scipy.sparse as sp
from scipy.sparse import csgraph
import shapely
from shapely.geometry import Polygon

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compress  # noqa: E402
from compress import DP, LIDAR, LIDAR_MARGIN, Frame, Mover, move_file, write_file  # noqa: E402
import osm_city  # noqa: E402

H = 100.0  # m: mesh spacing
MARGIN = 1500.0  # m: source rectangle past the districts' bounds
RAMP = 500.0  # m: weight blends from W_STIFF to 1 over this far outside a district
W_STIFF = 100.0  # weight of a district triangle against a soft one
DMIN = 0.75  # smallest scale the districts may take when the map cannot fit them at 1
D_STEPS = 5  # bisection steps for that scale
AIM = 1.05  # the solve aims this far inside the bounds, since it lands on what it aims at
BOOST = 1.5  # weight factor, per iteration, on a triangle breaking the bounds
BOOST_MAX = 1e4
CORNER = 0.2  # corner radius, as a fraction of the target's short side
CLOSE = 10.0  # m: closing radius that turns a district's blocks into one area
ITERS = 120
CG_ITERS = 400
PIN = 1e3  # weight pulling an edge vertex onto the rounded rectangle
DIST_TOL = 0.05
MIN_SCALE = 0.35
ANISO = 2.0
LINE_CLASSES = ("motorway", "trunk", "primary", "secondary", "tertiary", "residential", "unclassified", "living_street")
TURN = 8.0  # degrees: a way turning more than this starts a new piece; ends straighter than this continue a stroke
LINE_MIN = 400.0  # m: shortest stroke kept straight (shorter ones cannot bend at the mesh's scale)
LINE_DEV = 4.0  # m: farthest a source point may lie off its stroke's line for the stroke to count as straight
LINE_STEP = 25.0  # m: sample spacing along a stroke
LINE_W = 1.0  # weight of a sample, per m of stroke and per m of mesh spacing, pulling it onto its stroke's line
LINE_TOL = 5.0  # m: gate, farthest a warped straight stroke may bow
LINE_SHARE = 0.99  # gate: share of straight-stroke length that must stay within LINE_TOL
MARKS = {"Jackson Square": (29.9574, -90.0630), "Congo Square": (29.9606, -90.0681),
         "St Louis Cathedral": (29.9580, -90.0637), "Washington Square": (29.9644, -90.0566),
         "Lafayette Square": (29.9488, -90.0705)}

# One point inside each water body big enough for an edge to cut it open,
# anywhere in the download (README.md lists the parish's): the river at the
# French Quarter, the middle of the lake, the Rigolets, Lake Borgne.
WATER_SEEDS = {"Mississippi River": (29.9545, -90.0585), "Lake Pontchartrain": (30.15, -90.05),
               "The Rigolets": (30.165, -89.70), "Lake Borgne": (30.0777, -89.6828)}
SEED_INSET = 30.0  # m: seeds stay this far inside the source outline, clear of its edge
SEED_MIN = 100.0  # m2: smaller slivers of cut water are left dry


THREADS = max(1, min(8, os.cpu_count() or 1))  # per-triangle work is split over this many threads
_pool = None


def _threads():
    global _pool
    if _pool is None:
        _pool = ThreadPoolExecutor(THREADS)
    return _pool


def _chunked(f, J):
    """f over a stack of 2x2 matrices, the stack split across threads.
    numpy's linalg loops release the GIL and solve each matrix on its own,
    so the result is the same bits as f(J) in one call."""
    if THREADS == 1 or len(J) < 4096:
        return f(J)
    parts = list(_threads().map(f, np.array_split(J, THREADS)))
    if isinstance(parts[0], tuple):
        return tuple(np.concatenate(p) for p in zip(*parts))
    return np.concatenate(parts)


def svd(J, compute_uv=True):
    return _chunked(lambda j: np.linalg.svd(j, compute_uv=compute_uv), J)


class Outline:
    """A rounded rectangle: centre c, half sizes a, b, corner radius r."""

    def __init__(self, c, a, b, r):
        self.c, self.a, self.b, self.r = np.asarray(c, float), a, b, r

    def area(self):
        return 4 * self.a * self.b - (4 - math.pi) * self.r ** 2

    def inset(self, d):
        return Outline(self.c, self.a - d, self.b - d, max(self.r - d, 0.0))

    def contains(self, p):
        q = p - self.c
        ia, ib = self.a - self.r, self.b - self.r
        k = np.c_[np.clip(q[:, 0], -ia, ia), np.clip(q[:, 1], -ib, ib)]
        return np.hypot(*(q - k).T) <= self.r

    def project(self, p):
        """Nearest point of the outline to each point of p (n, 2)."""
        q = p - self.c
        ia, ib = self.a - self.r, self.b - self.r
        k = np.c_[np.clip(q[:, 0], -ia, ia), np.clip(q[:, 1], -ib, ib)]
        d = q - k
        n = np.hypot(d[:, 0], d[:, 1])
        out = k + self.r * d / np.maximum(n, 1e-12)[:, None]
        box = n < 1e-9  # inside the inner box: straight onto the nearer side
        if box.any():
            qb = q[box]
            side_x = self.a - np.abs(qb[:, 0]) < self.b - np.abs(qb[:, 1])
            ob = qb.copy()
            ob[side_x, 0] = np.sign(qb[side_x, 0]) * self.a
            ob[~side_x, 1] = np.sign(qb[~side_x, 1]) * self.b
            out[box] = ob
        return out + self.c

    def ring(self, step=50.0):
        pts = []
        ia, ib = self.a - self.r, self.b - self.r
        for cx, cz, a0 in ((ia, -ib, -90), (ia, ib, 0), (-ia, ib, 90), (-ia, -ib, 180)):
            n = max(4, int(self.r * math.pi / 2 / step))
            for t in np.linspace(a0, a0 + 90, n + 1)[:-1]:
                pts.append((cx + self.r * math.cos(math.radians(t)), cz + self.r * math.sin(math.radians(t))))
            ex, ez = cx + self.r * math.cos(math.radians(a0 + 90)), cz + self.r * math.sin(math.radians(a0 + 90))
            nx_, nz_ = [(ia, ib), (-ia, ib), (-ia, -ib), (ia, -ib)][[-90, 0, 90, 180].index(a0)]
            m = max(1, int(math.hypot(nx_ - cx, nz_ - cz) / step))
            for t in np.linspace(0, 1, m + 1)[:-1]:
                pts.append((ex + (nx_ - cx) * t, ez + (nz_ - cz) * t))
        return np.array(pts) + self.c


class Mesh:
    """A grid of vertices over the source rectangle, two triangles a cell."""

    def __init__(self, x0, z0, x1, z1):
        self.nx = int(math.ceil((x1 - x0) / H)) + 1
        self.nz = int(math.ceil((z1 - z0) / H)) + 1
        self.x0, self.z0 = x0, z0
        self.hx = (x1 - x0) / (self.nx - 1)
        self.hz = (z1 - z0) / (self.nz - 1)
        gx, gz = np.meshgrid(x0 + self.hx * np.arange(self.nx), z0 + self.hz * np.arange(self.nz))
        self.P = np.c_[gx.ravel(), gz.ravel()]
        v = lambda i, j: j * self.nx + i
        i, j = np.meshgrid(np.arange(self.nx - 1), np.arange(self.nz - 1))
        i, j = i.ravel(), j.ravel()
        lower = np.c_[v(i, j), v(i + 1, j), v(i, j + 1)]
        upper = np.c_[v(i + 1, j + 1), v(i, j + 1), v(i + 1, j)]
        self.T = np.vstack([lower, upper])  # triangle k and k + ncell share cell k
        self.ncell = len(lower)
        e = np.zeros((self.nz, self.nx), bool)
        e[0, :] = e[-1, :] = e[:, 0] = e[:, -1] = True
        self.edge = e.ravel()
        p = self.P[self.T]
        E = np.stack([p[:, 1] - p[:, 0], p[:, 2] - p[:, 0]], axis=2)  # columns
        Ei = np.linalg.inv(E)
        self.g = np.stack([-(Ei[:, 0] + Ei[:, 1]), Ei[:, 0], Ei[:, 1]], axis=1)  # (T, 3, 2)
        self.area = 0.5 * np.abs(np.linalg.det(E))
        self.cen = p.mean(1)

    def clip(self, src):
        """Keep the triangles inside the source outline src: live, the ones
        the solve moves; ring, their vertices on or past src, which slide
        onto the target outline; dead, vertices no live triangle uses."""
        self.src = src
        self.live = src.contains(self.cen)
        used = np.zeros(len(self.P), bool)
        used[self.T[self.live].ravel()] = True
        self.ring = used & (~src.inset(1e-6).contains(self.P) | self.edge)
        self.dead = ~used

    def jac(self, Q, sl=slice(None)):
        # the einsum "tik,tij->tkj" written out: the same products summed in
        # the same order, so the same bits, at half the time
        q, g = Q[self.T[sl]], self.g[sl]
        return q[:, 0, :, None] * g[:, 0, None, :] + q[:, 1, :, None] * g[:, 1, None, :] \
            + q[:, 2, :, None] * g[:, 2, None, :]

    def locate(self, x, z):
        """Triangle and barycentric weights (three arrays) of points inside
        the rectangle. Called once per OSM way, so it is kept to a few array
        operations: the cost is per call, not per point."""
        u = (x - self.x0) / self.hx
        v = (z - self.z0) / self.hz
        i = np.minimum(np.maximum(np.floor(u).astype(int), 0), self.nx - 2)
        j = np.minimum(np.maximum(np.floor(v).astype(int), 0), self.nz - 2)
        fu, fv = u - i, v - j
        cell = j * (self.nx - 1) + i
        s = fu + fv
        up = s > 1
        t = np.where(up, cell + self.ncell, cell)
        return t, np.where(up, s - 1, 1 - fu - fv), np.where(up, 1 - fu, fu), np.where(up, 1 - fv, fv)


class Warp:
    """compress.Cuts' interface for one continuous map, so Mover can use it."""

    bands = []
    parallel = False
    rigid = True

    def __init__(self, mesh, Q, s_edge):
        self.m, self.Q, self.s_edge = mesh, Q, s_edge
        self.inner = mesh.src.inset(1.5 * H)  # every point inside lies in a live triangle
        self.lo = mesh.P.min(0)
        self.hi = mesh.P.max(0)
        # Outline.contains' constants, and each triangle's corners per axis,
        # so warp() is a handful of array operations per call
        o = self.inner
        self._c0, self._c1, self._ia, self._ib, self._r = o.c[0], o.c[1], o.a - o.r, o.b - o.r, o.r
        QT = Q[mesh.T]
        self._qx = [np.ascontiguousarray(QT[:, i, 0]) for i in range(3)]
        self._qz = [np.ascontiguousarray(QT[:, i, 1]) for i in range(3)]

    def warp(self, x, z):
        """Inside the source outline, the mesh; past it, a point moves with
        the nearest point just inside, at the uniform scale s_edge.

        The same arithmetic as Outline.contains/project and an einsum over
        the barycentric weights, column by column, in the same order: it is
        called once per OSM way, hundreds of thousands of times, so the
        per-call overhead is what it costs."""
        x, z = np.array(x, float, ndmin=1), np.array(z, float, ndmin=1)
        qx, qz = x - self._c0, z - self._c1
        dx = qx - np.minimum(np.maximum(qx, -self._ia), self._ia)
        dz = qz - np.minimum(np.maximum(qz, -self._ib), self._ib)
        out = ~(np.hypot(dx, dz) <= self._r)
        if out.any():
            bp = self.inner.project(np.c_[x[out], z[out]])
            bx, bz = x.copy(), z.copy()
            bx[out], bz[out] = bp[:, 0], bp[:, 1]
        else:
            bx, bz = x, z
        t, w0, w1, w2 = self.m.locate(bx, bz)
        X, Z = self._qx, self._qz
        wx = w0 * X[0][t] + w1 * X[1][t] + w2 * X[2][t]
        wz = w0 * Z[0][t] + w1 * Z[1][t] + w2 * Z[2][t]
        wx += self.s_edge * (x - bx)
        wz += self.s_edge * (z - bz)
        return wx, wz

    def deleted(self, x, z):
        return np.zeros(np.shape(np.array(x, ndmin=1)), bool)

    def line(self, x, z, mode):
        wx, wz = self.warp(x, z)
        n = len(wx)
        return np.ones(n, bool), wx, wz, np.zeros((n, 0), int), np.full(n, -1), []


def stiffness(mesh, districts):
    d = shapely.distance(shapely.points(mesh.cen), districts)
    t = np.clip(d / RAMP, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    return W_STIFF + (1.0 - W_STIFF) * t, d


def measure(mesh, Q, did, names, D, lines=None):
    """The gates for one solve: (gate dict, per district (name, scale, worst shape distortion))."""
    J = mesh.jac(Q)
    S = svd(J, compute_uv=False)
    det = np.linalg.det(J)
    inside = did >= 0
    shape = S[:, 0] / np.maximum(S[:, 1], 1e-12) - 1  # 0 for an undistorted triangle
    dmiss = shape[inside]
    order = np.argsort(dmiss)
    cum = np.cumsum(mesh.area[inside][order]) / mesh.area[inside].sum()
    d95 = float(dmiss[order][np.searchsorted(cum, 0.95)])
    per = []
    for k_, nm in enumerate(names):
        m = did == k_
        if m.any():
            per.append((nm, float((mesh.area[m] * np.sqrt(np.clip(det[m], 0, None))).sum() / mesh.area[m].sum()),
                        float(shape[m].max())))
    soft = ~inside & mesh.live
    gate = {"district_scale": round(D, 3), "flipped": int((det[mesh.live] <= 0).sum()),
            "district_shape_95": round(d95, 4), "district_shape_max": round(float(dmiss.max()), 4),
            "district_scale_min": round(min(p_[1] for p_ in per), 3),
            "min_scale": round(float(S[soft, 1].min()), 3),
            "max_aniso": round(float((S[soft, 0] / np.maximum(S[soft, 1], 1e-12)).max()), 3)}
    if lines is not None:
        gate["lines"] = lines.gate(Q)
    gate["pass"] = gate["flipped"] == 0 and d95 <= DIST_TOL and gate["min_scale"] >= MIN_SCALE         and gate["max_aniso"] <= ANISO and (lines is None or gate["lines"]["straight_share"] >= LINE_SHARE)
    return gate, per


def _summer(idx, nbins, vals=None, cols=None):
    """A CSR matrix whose product with v is np.bincount(idx, v, nbins) to the
    bit: row b holds the entries with idx == b in their input order, and
    scipy's row loop adds them in that order from 0, as bincount does.
    vals/cols replace the 1s and the entry numbers (a weight folded in)."""
    order = np.argsort(idx, kind="stable")
    indptr = np.r_[0, np.cumsum(np.bincount(idx, minlength=nbins))]
    data = np.ones(len(idx)) if vals is None else vals[order]
    return sp.csr_matrix((data, order if cols is None else cols[order], indptr),
                         shape=(nbins, len(idx) if cols is None else int(cols.max()) + 1))


def solve(mesh, out, did, w, D, Q0, log, iters=ITERS, lines=None, line_w=LINE_W):
    """The local/global ARAP solve. Same arithmetic, in the same order, as
    the plain numpy version it replaced (bincounts, einsums, CG), so the
    same bits: the per-triangle local step runs in THREADS slices, and the
    sums run as sparse products whose row loops add in bincount's order."""
    n = len(mesh.P)
    nt = len(mesh.T)
    wa = w * mesh.area * mesh.live
    rows = np.repeat(mesh.T, 3, axis=1).ravel()
    cols = np.tile(mesh.T, (1, 3)).ravel()
    gg = np.einsum("tik,tjk->tij", mesh.g, mesh.g)
    key, inv = np.unique(rows.astype(np.int64) * n + cols, return_inverse=True)
    kr, kc = key // n, key % n
    dg = kr == kc
    kv = np.bincount(inv, (wa[:, None, None] * gg).ravel())
    pin = np.where(mesh.ring | mesh.dead, PIN * kv[dg].mean(), 0.0)
    boost = np.ones(nt)
    # kv = bincount(inv, (wb * gg).ravel()) as G @ wb: entry e of the
    # stiffness is gg[e] times its triangle's weight wb[e // 9]
    G = _summer(inv, len(key), vals=gg.ravel(), cols=np.arange(9 * nt) // 9)
    # b = bincount(T.ravel(), contrib[..., k].ravel()) as ST @ contrib
    ST = _summer(mesh.T.ravel(), n)
    # K as a CSR matrix with the same entries in the same order (rows from
    # the sorted keys, columns ascending in a row)
    indptr = np.r_[0, np.cumsum(np.bincount(kr, minlength=n))].astype(np.int32)
    kc32 = kc.astype(np.int32)
    A = None
    if lines is not None and line_w > 0:
        # each sample pulls toward the nearest point of its stroke's current
        # line: a constant extra stiffness B^T W B, and a target refit per
        # iteration
        lw = line_w * H * lines.w
        LB = (lines.B.T @ sp.diags(lw) @ lines.B).tocsr()
        LBd = LB.diagonal()
    else:
        lines = None

    def K(x):
        return A @ x + pin[:, None] * x

    wb = np.empty(nt)
    contrib = np.empty((nt, 3, 2))
    step = -(-nt // THREADS)
    slices = [slice(s, min(s + step, nt)) for s in range(0, nt, step)]
    live, dist = mesh.live, did >= 0

    Jall = np.empty((nt, 2, 2))
    Uall, Sall, Vall = np.empty((nt, 2, 2)), np.empty((nt, 2)), np.empty((nt, 2, 2))
    det = None

    def local_svd(sl):
        Jall[sl] = J = mesh.jac(Q, sl)
        Uall[sl], Sall[sl], Vall[sl] = np.linalg.svd(J)

    def local(sl):
        """The local step for triangles sl: each triangle's best rotation
        and bounded scale, its boost, and its pull on its corners."""
        U, S, Vt = Uall[sl], Sall[sl], Vall[sl]
        # U @ Vt is a rotation or a reflection, det +-1 to rounding, so its
        # sign is the sign of det U * det Vt (the rotation itself is not used)
        bad = (U[:, 0, 0] * U[:, 1, 1] - U[:, 0, 1] * U[:, 1, 0]) \
            * (Vt[:, 0, 0] * Vt[:, 1, 1] - Vt[:, 0, 1] * Vt[:, 1, 0]) < 0
        U[bad, :, 1] *= -1
        # a district keeps its shape exactly, at the one scale D; ground
        # between districts takes whatever squeeze it is given, within the
        # gate's bounds
        Sb = np.clip(S, MIN_SCALE * AIM, 1.0)
        Sb[:, 1] = np.maximum(Sb[:, 1], Sb[:, 0] * AIM / ANISO)
        Sb[dist[sl]] = D
        # a triangle that breaks the bounds (folded, squeezed past the floor,
        # stretched past ANISO) counts for more next time, so the squeeze it
        # cannot take moves to ground that can
        worse = live[sl] & ((det[sl] <= 0) | (S[:, 1] < MIN_SCALE) | (S[:, 0] > ANISO * S[:, 1]))
        bo = boost[sl]
        boost[sl] = bo = np.where(worse, np.minimum(bo * BOOST, BOOST_MAX), bo)
        wb[sl] = wbs = wa[sl] * bo
        # the einsums "tij,tj,tjk->tik" and "tkj,tij->tik" written out, same
        # products in the same order
        M = (U[:, :, 0, None] * Sb[:, 0, None, None]) * Vt[:, 0, None, :] \
            + (U[:, :, 1, None] * Sb[:, 1, None, None]) * Vt[:, 1, None, :]
        g = mesh.g[sl]
        contrib[sl] = wbs[:, None, None] * (M[:, None, :, 0] * g[:, :, 0, None] + M[:, None, :, 1] * g[:, :, 1, None])

    Q = Q0.copy()
    for it in range(iters):
        # the svds in threads (numpy's loop releases the GIL); det holds the
        # GIL, so it runs once over the whole stack between the two rounds
        for f in (local_svd, local):
            if len(slices) > 1:
                list(_threads().map(f, slices))
            else:
                f(slices[0])
            if f is local_svd:
                det = np.linalg.det(Jall)
        kv = G @ wb
        A = sp.csr_matrix((kv, kc32, indptr), shape=(n, n))
        diag = np.bincount(kr[dg], kv[dg], minlength=n) + pin
        b = ST @ contrib.reshape(-1, 2)
        if lines is not None:
            A = A + LB
            diag = diag + LBd
            b += lines.B.T @ (lw[:, None] * lines.fit(lines.B @ Q)[0])
        tgt = out.project(Q[mesh.ring])
        b[mesh.ring] += pin[mesh.ring, None] * tgt
        b[mesh.dead] += pin[mesh.dead, None] * Q0[mesh.dead]
        r = b - K(Q)
        z = r / diag[:, None]
        p = z.copy()
        rz = (r * z).sum(0)
        b2 = np.sqrt((b * b).sum(0))
        for _ in range(CG_ITERS):
            Ap = K(p)
            alpha = rz / np.maximum((p * Ap).sum(0), 1e-30)
            Q += alpha * p
            r -= alpha * Ap
            if (np.sqrt((r * r).sum(0)) < 1e-7 * b2).all():
                break
            z = r / diag[:, None]
            rz2 = (r * z).sum(0)
            p = z + (rz2 / np.maximum(rz, 1e-30)) * p
            rz = rz2
        if it == iters - 1:
            log("  %d iterations, edge off outline %.2f m" % (iters, float(np.hypot(*(Q[mesh.ring] - tgt).T).max())))
    Q[mesh.ring] = out.project(Q[mesh.ring])
    return Q


class Lines:
    """The source-straight streets as solve() constraints. A stroke is a
    chain of road pieces that continue straight on through their junctions
    (a piece is a way split where it turns more than TURN); a stroke is
    kept if it runs at least LINE_MIN and no point of it is more than
    LINE_DEV off its best-fit line. Streets that truly curve are not kept,
    so the warp leaves them free. Each stroke is sampled every LINE_STEP m;
    a sample is its triangle's barycentric row of B."""

    def __init__(self, raw, fr, mesh, inner):
        d = json.load(open(os.path.join(raw, "features.json"), encoding="utf-8"))
        ways = [e for e in d["elements"] if e["type"] == "way" and e.get("tags", {}).get("highway") in LINE_CLASSES
                and len(e.get("nodes", ())) == len(e.get("geometry", ())) >= 2 and all(e["geometry"])]  # None: past the download
        n_of = np.array([len(w["nodes"]) for w in ways])
        wid = np.repeat(np.arange(len(ways)), n_of)
        nid = np.fromiter((v for w in ways for v in w["nodes"]), np.int64, n_of.sum())
        ll = np.fromiter((c for w in ways for g in w["geometry"] for c in (g["lon"], g["lat"])), float, 2 * n_of.sum())
        x, z = fr.xz(ll[0::2], ll[1::2])
        P = np.c_[x, z]
        start = np.r_[0, np.cumsum(n_of)[:-1]]
        last = start + n_of - 1
        # segment k joins point k to k + 1 within a way
        sk = np.setdiff1d(np.arange(len(P) - 1), last)
        dv = P[sk + 1] - P[sk]
        ang = np.arctan2(dv[:, 1], dv[:, 0])
        # a vertex where the way turns more than TURN starts a new piece
        same = wid[sk[1:]] == wid[sk[:-1]]
        turn = np.abs(np.angle(np.exp(1j * (ang[1:][same] - ang[:-1][same]))))
        cut = np.zeros(len(P), bool)
        cut[sk[1:][same][turn > math.radians(TURN)]] = True
        # piece of each segment: new at every way start and every cut vertex
        brk = np.zeros(len(P), bool)
        brk[start] = True
        brk |= cut
        piece_pt = np.cumsum(brk) - 1  # piece a point starts or continues
        seg_piece = piece_pt[sk]
        npc = int(piece_pt.max()) + 1
        # each piece's two ends: node id and outward direction
        first = np.full(npc, len(P))
        np.minimum.at(first, seg_piece, sk)
        lastp = np.zeros(npc, int)
        np.maximum.at(lastp, seg_piece, sk)
        e_node = np.r_[nid[first], nid[lastp + 1]]
        e_dir = np.r_[ang[np.searchsorted(sk, first)] + math.pi, ang[np.searchsorted(sk, lastp)]]
        e_pc = np.r_[np.arange(npc), np.arange(npc)]
        # pairs of ends at one node pointing straight away from each other,
        # each end with its best partner, kept when the choice is mutual
        o = np.argsort(e_node, kind="stable")
        en, ed = e_node[o], e_dir[o]
        best = np.full(len(o), -1)
        bdev = np.full(len(o), np.inf)
        for s in range(1, 8):
            i = np.arange(len(o) - s)
            j = i + s
            m = en[i] == en[j]
            if not m.any():
                break
            i, j = i[m], j[m]
            dev = np.abs(np.angle(np.exp(1j * (ed[i] - ed[j] - math.pi))))
            for a_, b_ in ((i, j), (j, i)):
                better = dev < bdev[a_]
                # several candidates for one end in one pass cannot happen:
                # a_ values are distinct for a fixed shift s
                bdev[a_[better]] = dev[better]
                best[a_[better]] = b_[better]
        ok = (best >= 0) & (bdev < math.radians(TURN))
        mutual = ok & (best[np.where(ok, best, 0)] == np.arange(len(o))) & (np.arange(len(o)) < np.where(ok, best, -1))
        pa, pb = e_pc[o[mutual]], e_pc[o[best[mutual]]]
        g = sp.coo_matrix((np.ones(len(pa)), (pa, pb)), shape=(npc, npc))
        _, comp = csgraph.connected_components(g, directed=False)
        # the straightness test on every point of each stroke
        sc = comp[seg_piece]
        X = np.r_[P[sk], P[sk + 1]]
        C = np.r_[sc, sc]
        nc = int(comp.max()) + 1
        cnt = np.bincount(C, minlength=nc)
        mx = np.bincount(C, X[:, 0], nc) / np.maximum(cnt, 1)
        mz = np.bincount(C, X[:, 1], nc) / np.maximum(cnt, 1)
        dx_, dz_ = X[:, 0] - mx[C], X[:, 1] - mz[C]
        cxx = np.bincount(C, dx_ * dx_, nc)
        czz = np.bincount(C, dz_ * dz_, nc)
        cxz = np.bincount(C, dx_ * dz_, nc)
        th = 0.5 * np.arctan2(2 * cxz, cxx - czz)
        ux, uz = np.cos(th), np.sin(th)
        along = dx_ * ux[C] + dz_ * uz[C]
        perp = np.abs(-dx_ * uz[C] + dz_ * ux[C])
        dev = np.zeros(nc)
        np.maximum.at(dev, C, perp)
        amin = np.full(nc, np.inf)
        amax = np.full(nc, -np.inf)
        np.minimum.at(amin, C, along)
        np.maximum.at(amax, C, along)
        span = amax - amin
        keep = (span >= LINE_MIN) & (dev <= LINE_DEV)
        # samples every LINE_STEP m along each kept segment
        sm = keep[sc]
        a0, a1, s_c = P[sk[sm]], P[sk[sm] + 1], sc[sm]
        L = np.hypot(*(a1 - a0).T)
        k = np.maximum(1, np.ceil(L / LINE_STEP).astype(int))
        rep = np.repeat(np.arange(len(L)), k)
        t = (np.arange(k.sum()) - np.repeat(np.cumsum(k) - k, k) + 0.5) / k[rep]
        S = a0[rep] + t[:, None] * (a1 - a0)[rep]
        sw = (L / k)[rep]
        sid = s_c[rep]
        live = inner.contains(S)
        S, sw, sid = S[live], sw[live], sid[live]
        _, sid = np.unique(sid, return_inverse=True)
        self.src, self.w, self.sid, self.n = S, sw, sid, int(sid.max()) + 1 if len(sid) else 0
        self.src_dev = dev[keep]
        self.length_km = float(sw.sum() / 1000)
        t_, w0, w1, w2 = mesh.locate(S[:, 0], S[:, 1])
        T = mesh.T[t_]
        r = np.repeat(np.arange(len(S)), 3)
        self.B = sp.csr_matrix((np.c_[w0, w1, w2].ravel(), (r, T.ravel())), shape=(len(S), len(mesh.P)))

    def fit(self, L):
        """Each stroke's best-fit line through its samples L: the nearest
        point of it to each sample, and each sample's distance off it."""
        n, sid, w = self.n, self.sid, self.w
        ws = np.bincount(sid, w, n)
        mx = np.bincount(sid, w * L[:, 0], n) / ws
        mz = np.bincount(sid, w * L[:, 1], n) / ws
        dx, dz = L[:, 0] - mx[sid], L[:, 1] - mz[sid]
        th = 0.5 * np.arctan2(2 * np.bincount(sid, w * dx * dz, n),
                              np.bincount(sid, w * dx * dx, n) - np.bincount(sid, w * dz * dz, n))
        ux, uz = np.cos(th)[sid], np.sin(th)[sid]
        a = dx * ux + dz * uz
        tgt = np.c_[mx[sid] + a * ux, mz[sid] + a * uz]
        return tgt, np.abs(-dx * uz + dz * ux)

    def gate(self, Q):
        """Per stroke, the farthest its warped samples lie off a straight
        line: the share of stroke length within LINE_TOL, and the worst."""
        _, off = self.fit(self.B @ Q)
        worst = np.zeros(self.n)
        np.maximum.at(worst, self.sid, off)
        ln = np.bincount(self.sid, self.w, self.n)
        return {"strokes": self.n, "km": round(self.length_km, 1),
                "straight_share": round(float(ln[worst <= LINE_TOL].sum() / ln.sum()), 4),
                "worst_m": round(float(worst.max()), 2), "p95_m": round(float(np.percentile(worst, 95)), 2)}


def district_union(seg, dist):
    B = seg["blocks"]
    polys = []
    for d in dist["districts"]:
        u = shapely.union_all([Polygon(B[b]["ring"]) for b in d["blocks"]])
        polys.append(u.buffer(CLOSE).buffer(-CLOSE))
    return polys


def main():
    global ANISO
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("segment")
    ap.add_argument("--raw")
    ap.add_argument("--out")
    ap.add_argument("--area", type=float, default=100.0, help="km2 of the rounded rectangle")
    ap.add_argument("--lidar", default=LIDAR)
    ap.add_argument("--png")
    ap.add_argument("--line-w", type=float, default=LINE_W, help="pull of the source-straight streets onto straight lines (0: off)")
    ap.add_argument("--dmin", type=float, default=DMIN, help="smallest district scale tried when 1 fails")
    ap.add_argument("--aniso", type=float, default=ANISO, help="most a squeezed triangle may stretch one way more than the other")
    a = ap.parse_args()
    ANISO = a.aniso
    lines = []

    def log(msg):
        print(msg, flush=True)
        lines.append(msg)

    seg = json.load(open(os.path.join(a.segment, "segment.json"), encoding="utf-8"))
    dist = json.load(open(os.path.join(a.segment, "districts.json"), encoding="utf-8"))
    fr = Frame(*seg["frame"])
    polys = district_union(seg, dist)
    names = [d["name"] for d in dist["districts"]]
    dunion = shapely.union_all(polys)
    shapely.prepare(dunion)
    s, w, n, e = seg["bbox"]
    bx0, bz0 = fr.xz(w, n)
    bx1, bz1 = fr.xz(e, s)
    lo = np.array(dunion.bounds[:2]) - MARGIN
    hi = np.array(dunion.bounds[2:]) + MARGIN
    x0, z0 = max(lo[0], float(bx0)), max(lo[1], float(bz0))
    x1, z1 = min(hi[0], float(bx1)), min(hi[1], float(bz1))
    mesh = Mesh(x0, z0, x1, z1)
    A_src = (x1 - x0) * (z1 - z0)
    A = a.area * 1e6
    W0, H0 = x1 - x0, z1 - z0
    k = math.sqrt(A / (W0 * H0 - (4 - math.pi) * (CORNER * min(W0, H0) / 2) ** 2))
    c = np.array([(x0 + x1) / 2, (z0 + z1) / 2])
    out = Outline(c, k * W0 / 2, k * H0 / 2, k * CORNER * min(W0, H0) / 2)
    log("source %.0f x %.0f m (%.1f km2), %d vertices; target %.0f x %.0f m rounded r %.0f (%.1f km2)"
        % (W0, H0, A_src / 1e6, len(mesh.P), 2 * out.a, 2 * out.b, out.r, out.area() / 1e6))
    wt, dd = stiffness(mesh, dunion)
    did = np.full(len(mesh.T), -1)
    for k_, p in enumerate(polys):
        did[shapely.contains_xy(p, mesh.cen[:, 0], mesh.cen[:, 1])] = k_
    src_outline = Outline(c, W0 / 2, H0 / 2, CORNER * min(W0, H0) / 2)
    mesh.clip(src_outline)
    Q0 = c + k * (mesh.P - c)
    strokes = None
    if a.raw:
        strokes = Lines(a.raw, fr, mesh, mesh.src.inset(1.5 * H))
        log("straight streets: %d strokes, %.1f km sampled" % (strokes.n, strokes.length_km))
    log("districts %.2f km2; searching the largest district scale that fits" % (dunion.area / 1e6))
    Q = solve(mesh, out, did, wt, 1.0, Q0, log, lines=strokes, line_w=a.line_w)
    gate, per = measure(mesh, Q, did, names, 1.0, strokes)
    log("  scale 1.000: %s" % json.dumps(gate))
    if not gate["pass"]:
        lo_d, hi_d, best = a.dmin, 1.0, None
        Qd = solve(mesh, out, did, wt, a.dmin, Q0, log, lines=strokes, line_w=a.line_w)
        g, pr = measure(mesh, Qd, did, names, a.dmin, strokes)
        log("  scale %.3f: %s" % (a.dmin, json.dumps(g)))
        if g["pass"]:
            best = (Qd, g, pr)
            for _ in range(D_STEPS):
                mid = (lo_d + hi_d) / 2
                Qm = solve(mesh, out, did, wt, mid, Q0, log, lines=strokes, line_w=a.line_w)
                g, pr = measure(mesh, Qm, did, names, mid, strokes)
                log("  scale %.3f: %s" % (mid, json.dumps(g)))
                if g["pass"]:
                    lo_d, best = mid, (Qm, g, pr)
                else:
                    hi_d = mid
            Q, gate, per = best
        else:
            Q, gate, per = Qd, g, pr
    J = mesh.jac(Q)
    S = svd(J, compute_uv=False)
    for nm, sm, mx in per:
        log("  %-26s scale %.3f, worst shape distortion %.3f" % (nm, sm, mx))
    gate["area_km2"] = round(out.area() / 1e6, 2)
    log("gate " + json.dumps(gate))
    warp = Warp(mesh, Q, k)
    marks = {}
    for nm, (lat, lon) in MARKS.items():
        x, z = fr.xz(lon, lat)
        wx, wz = warp.warp(x, z)
        marks[nm] = [float(np.round(v, DP)) for v in fr.lonlat(wx[0], wz[0])[::-1]]
    if a.png:
        png(a.png, mesh, Q, polys, out, warp, S)
    if a.raw and a.out:
        write_raw(a, fr, warp, out, log)
        water_seeds(a, seg, fr, warp, Polygon(src_outline.ring()), log)
        with open(os.path.join(a.out, "warp.json"), "w", encoding="utf-8", newline="\n") as f:
            json.dump({"segment": a.segment, "source_rect": [x0, z0, x1, z1], "outline": [c.tolist(), out.a, out.b, out.r],
                       "gate": gate, "marks_latlon": marks, "report": lines}, f, indent=1)
    sys.exit(0 if gate["pass"] else 1)


def write_raw(a, fr, warp, out, log):
    if os.path.normcase(os.path.abspath(a.out)) == os.path.normcase(os.path.abspath(a.raw)):
        sys.exit("parish_warp: out must not be the raw dir")
    os.makedirs(a.out, exist_ok=True)
    ring = out.ring()
    lon, lat = fr.lonlat(ring[:, 0], ring[:, 1])
    geom = [{"lat": float(round(la, DP)), "lon": float(round(lo, DP))} for la, lo in zip(lat, lon)]
    geom.append(dict(geom[0]))
    rel = {"type": "relation", "id": -1, "tags": {"boundary": "administrative", "name": "warped map"},
           "members": [{"type": "way", "ref": -1, "role": "outer", "geometry": geom}]}
    with open(os.path.join(a.out, "boundary.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"elements": [rel]}, f)
    nb = (min(lat), min(lon), max(lat), max(lon))
    new = Frame.of_bbox(*nb)
    mover = Mover(fr, warp)
    mover.plan_blocks(a.raw)
    st = mover.block_stats
    log("building blocks: %d, %d moved rigidly, %d follow the warp" % (st["blocks"], st["rigid"], st["warped"]))
    for name in sorted(os.listdir(a.raw)):
        if not name.endswith(".json") or name in ("boundary.json", "water_seeds.json"):
            continue
        data, n0, n1 = move_file(os.path.join(a.raw, name), mover)
        write_file(os.path.join(a.out, name), data)
        log("%-18s %7d elements -> %7d" % (name, n0, n1))
    if a.lidar:
        d = np.load(a.lidar)
        meta = json.loads(str(d["meta"]))
        src = Frame(*meta["origin"])
        lo_, la_ = src.lonlat(d["x"].astype(np.float64), d["z"].astype(np.float64))
        x, z = fr.xz(lo_, la_)
        keep = (x >= warp.lo[0] - LIDAR_MARGIN) & (x <= warp.hi[0] + LIDAR_MARGIN) \
            & (z >= warp.lo[1] - LIDAR_MARGIN) & (z <= warp.hi[1] + LIDAR_MARGIN)
        wx, wz = warp.warp(x[keep], z[keep])
        nx_, nz_ = new.xz(*fr.lonlat(wx, wz))
        meta["origin"] = [new.lat0, new.lon0]
        meta["warped"] = {"from": os.path.basename(a.lidar), "kept": int(keep.sum())}
        np.savez_compressed(os.path.join(a.out, "lidar_decks.npz"), x=nx_.astype(np.float32), z=nz_.astype(np.float32),
                            h=d["h"][keep], cls=d["cls"][keep], meta=json.dumps(meta))
        log("lidar: %d of %d returns kept" % (int(keep.sum()), len(d["x"])))
    log("next: python -I tools/blockout/osm_city.py %s data/blockouts/<name>" % a.out)


def water_seeds(a, seg, fr, warp, outline, log):
    """Writes <out>/water_seeds.json. The water the edge cuts open is
    flooded in the source, over the whole download, from WATER_SEEDS; each
    piece of it inside the map then gives one seed, warped. A seed far out
    in the lake would be pinned to the map's edge by the warp, so the
    seeds are chosen after the cut, not carried from before it."""
    feats = []
    for name in ("features.json", "coast.json"):
        path = os.path.join(a.raw, name)
        if os.path.exists(path):
            feats += json.load(open(path, encoding="utf-8"))["elements"]

    def line(chain):
        g = [p for p in chain if p]
        x, z = fr.xz(np.array([p["lon"] for p in g]), np.array([p["lat"] for p in g]))
        return shapely.LineString(np.c_[x, z]) if len(g) > 1 else None

    shores = []
    for name in dict.fromkeys(nm for _, nm in osm_city.cut_water(feats)):
        rings, cut = osm_city._join([c for c, nm in osm_city.cut_water(feats) if nm == name])
        shores += [ln for ln in map(line, rings + cut) if ln is not None]
    s, w, n, e = seg["bbox"]
    (x0, x1), (z0, z1) = zip(fr.xz(w, n), fr.xz(e, s))
    download = shapely.box(min(x0, x1), min(z0, z1), max(x0, x1), max(z0, z1))
    sx, sz = fr.xz(np.array([lon for _, lon in WATER_SEEDS.values()]), np.array([lat for lat, _ in WATER_SEEDS.values()]))
    wet = osm_city._flood(shores, download, list(shapely.points(np.c_[sx, sz])))
    parts = [p for p in shapely.get_parts(shapely.intersection(wet, shapely.buffer(outline, -SEED_INSET))) if p.area >= SEED_MIN]
    at = shapely.get_coordinates(shapely.point_on_surface(parts)) if parts else np.empty((0, 2))
    wx, wz = warp.warp(at[:, 0], at[:, 1])
    lon, lat = fr.lonlat(wx, wz)
    seeds = [[round(float(la), DP), round(float(lo), DP)] for la, lo in zip(lat, lon)]
    log("water seeds: %.1f km2 of cut water in the source (%s), %d piece%s on the map"
        % (wet.area / 1e6, ", ".join(WATER_SEEDS), len(seeds), "" if len(seeds) == 1 else "s"))
    with open(os.path.join(a.out, "water_seeds.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"seeds": seeds}, f, indent=1)


def png(path, mesh, Q, polys, out, warp, S):
    from PIL import Image, ImageDraw
    allp = np.vstack([mesh.P, Q])
    lo, hi = allp.min(0) - 300, allp.max(0) + 300
    ppm = 1000.0 / (hi - lo).max()
    Wd = int((hi[0] - lo[0]) * ppm)
    Hd = int((hi[1] - lo[1]) * ppm)
    im = Image.new("RGB", (2 * Wd + 20, Hd), (246, 244, 238))
    dr = ImageDraw.Draw(im, "RGBA")
    px = lambda q, off=0: [((x - lo[0]) * ppm + off, (z - lo[1]) * ppm) for x, z in np.asarray(q)]
    lin = np.sqrt(np.clip(np.linalg.det(mesh.jac(Q)), 0, None))
    for t in range(0, len(mesh.T)):
        v = lin[t]
        col = (int(255 * min(1, v)), int(160 + 95 * min(1, v)), 255 - int(200 * min(1, v)))
        dr.polygon(px(Q[mesh.T[t]], Wd + 20), fill=col)
    for p in polys:
        for g in shapely.get_parts(p):
            r = np.asarray(g.exterior.coords)
            dr.polygon(px(r), fill=(67, 147, 195, 160))
            wx, wz = warp.warp(r[:, 0], r[:, 1])
            dr.polygon(px(np.c_[wx, wz], Wd + 20), outline=(20, 20, 20, 255))
    step = max(1, mesh.nx // 30)
    G = Q.reshape(mesh.nz, mesh.nx, 2)
    P = mesh.P.reshape(mesh.nz, mesh.nx, 2)
    for i in range(0, mesh.nx, step):
        dr.line(px(P[:, i]), fill=(120, 120, 120, 120))
        dr.line(px(G[:, i], Wd + 20), fill=(60, 60, 60, 160))
    for j in range(0, mesh.nz, step):
        dr.line(px(P[j]), fill=(120, 120, 120, 120))
        dr.line(px(G[j], Wd + 20), fill=(60, 60, 60, 160))
    dr.polygon(px(out.ring(), Wd + 20), outline=(200, 30, 30, 255))
    im.save(path)
    print("wrote", path, im.size)


if __name__ == "__main__":
    main()

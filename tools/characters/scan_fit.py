"""Fitting a head scan to an MPFB head, for the tools that take things from it:
bake_scan_detail.py (its fine detail, as a normal map) and bake_scan_parts.py
(its shapes, as MakeHuman targets).

An MPFB head here is Z up and faces -Y, in metres. Landmarks are found on the
head itself (nose tip, crown, the ear's widest point) and everything else is
placed from them, scaled by the head's size, so any MPFB head fits: the hero's
numbers (nose tip to crown 0.159 m) are the unit.
"""
import bpy
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

HERO_HEAD = 0.159


def load_scan(path):
    """Imports a scan's .glb and keeps its one mesh, transform applied."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    scan = None
    for o in new:
        if o.type == 'MESH' and scan is None:
            scan = o
        else:
            bpy.data.objects.remove(o, do_unlink=True)
    scan.data.transform(scan.matrix_world)
    scan.parent = None
    scan.matrix_world = Matrix()
    return scan


def _nose_and_crown(v, zlo, zhi, xtol):
    c = v[(np.abs(v[:, 0]) < xtol) & (v[:, 2] > zlo) & (v[:, 2] < zhi)]
    return c[np.argmin(c[:, 1])], v[np.argmax(v[:, 2])]


class Head:
    """An MPFB head: the vertices (all of a mesh's; `use` picks those that are
    skin, not helpers), its neighbours and its landmarks."""

    def __init__(self, mesh, use=None):
        self.v = np.array([x.co for x in mesh.vertices])
        self.n = np.array([x.normal for x in mesh.vertices])
        self.use = np.ones(len(self.v), bool) if use is None else use
        self.nbr = [[] for _ in self.v]
        for e in mesh.edges:
            a, b = e.vertices
            self.nbr[a].append(b)
            self.nbr[b].append(a)
        v = self.v[self.use]
        crown_z = v[:, 2].max()
        self.nose, self.crown = _nose_and_crown(v, crown_z - 0.234, crown_z - 0.084, 0.01)
        self.k = (self.crown[2] - self.nose[2]) / HERO_HEAD
        z = self.v[:, 2]
        self.head = np.where(self.use & (z > self.at(0, 0, -0.105)[2]))[0]
        # 0 at the neck, 1 on the head: where the scan stops being trusted.
        self.zramp = np.clip((z - self.at(0, 0, -0.125)[2]) / (0.04 * self.k), 0, 1)
        side = v[(v[:, 2] > self.at(0, 0, -0.025)[2]) & (v[:, 2] < self.at(0, 0, 0.075)[2])]
        self.ear = side[np.argmax(np.abs(side[:, 0]))]
        self.ear = np.array([abs(self.ear[0]), self.ear[1], self.ear[2]])

    def at(self, x, y, z):
        """A point placed from the nose tip, in hero metres (y backwards)."""
        return self.nose + np.array([x, y, z]) * self.k

    def falloff(self, centre, r0, r1):
        """1 within r0 of centre, 0 past r1 (hero metres), smooth between."""
        d = np.linalg.norm(self.v - centre, axis=1)
        t = np.clip((d - r0 * self.k) / ((r1 - r0) * self.k), 0, 1)
        return 1 - t * t * (3 - 2 * t)

    def keep_away(self, centre, r0, r1):
        """0 within r0 of centre, 1 past r1 (hero metres), linear between."""
        d = np.linalg.norm(self.v - centre, axis=1)
        return np.clip((d - r0 * self.k) / ((r1 - r0) * self.k), 0, 1)

    def eyes(self):
        """0 on the eyes and lids (the scan's are shut), 1 away from them."""
        m = np.ones(len(self.v))
        for sx in (-1, 1):
            m *= self.keep_away(self.at(sx * 0.031, 0.0416, 0.045), 0.019, 0.027)
        return m

    def smooth(self, f, w, passes):
        """Averages f over neighbours, on the head where w > 0."""
        for _ in range(passes):
            g = f.copy()
            for i in self.head:
                if self.nbr[i]:
                    g[i] = f[self.nbr[i]].mean(0) if f.ndim > 1 else f[self.nbr[i]].mean()
            f = np.where(w[:, None] > 0, g, f) if f.ndim > 1 else np.where(w > 0, g, f)
        return f


def align(scan, head, iterations=40, nose_width=0.2):
    """Moves the scan onto the head: nose and crown, then similarity ICP. The
    scan must be Z up and face -Y; its nose tip is its most forward point
    within nose_width (its own units) of x = 0."""
    sv = np.array([v.co for v in scan.data.vertices])
    s_nose, s_crown = _nose_and_crown(sv, -1e9, 1e9, nose_width)
    s = (head.crown[2] - head.nose[2]) / (s_crown[2] - s_nose[2])
    R = np.eye(3)
    t = head.nose - s * s_nose
    P = head.v[head.head]
    polys = [tuple(p.vertices) for p in scan.data.polygons]
    for it in range(iterations):
        tree = BVHTree.FromPolygons([Vector(s * R @ x + t) for x in sv], polys)
        Q, d = [], []
        for p in P:
            hit = tree.find_nearest(Vector(p))
            Q.append(hit[0] if hit[0] is not None else Vector(p))
            d.append(hit[3] if hit[0] is not None else 1e9)
        Q, d = np.array(Q), np.array(d)
        keep = d < np.quantile(d, 0.75)
        A, B = Q[keep], P[keep]
        ma, mb = A.mean(0), B.mean(0)
        A0, B0 = A - ma, B - mb
        U, S_, Vt = np.linalg.svd(B0.T @ A0)
        D = np.eye(3)
        D[2, 2] = np.sign(np.linalg.det(U @ Vt))
        Ri = U @ D @ Vt
        si = (S_ * np.diag(D)).sum() / (A0 ** 2).sum()
        ti = mb - si * Ri @ ma
        s, R, t = si * s, Ri @ R, si * Ri @ t + ti
        if it % 10 == 0 or it == iterations - 1:
            print("ICP", it, "median mm", round(float(np.median(d)) * 1000, 2), "scale", round(s, 5))
    M = np.eye(4)
    M[:3, :3] = s * R
    M[:3, 3] = t
    scan.data.transform(Matrix(M.tolist()))
    scan.data.update()


def wrap(scan, head, rounds=((0.015, 8), (0.008, 4), (0.004, 2))):
    """The head's vertices moved onto the scan: each round projects them onto
    its nearest surface (if near enough and facing the same way), smooths the
    moves over neighbours and fades them out down the neck. Returns the moved
    vertices and which ones found the scan in the first round."""
    tree = BVHTree.FromObject(scan, bpy.context.evaluated_depsgraph_get())
    cur = head.v.copy()
    good = np.zeros(len(cur))
    for rnd, (limit, passes) in enumerate(rounds):
        off = np.zeros_like(cur)
        g = np.zeros(len(cur))
        for i in head.head:
            hit = tree.find_nearest(Vector(cur[i]))
            if hit[0] is None:
                continue
            if hit[3] < limit * head.k and np.dot(head.n[i], np.array(hit[1])) > 0.6:
                off[i] = np.array(hit[0]) - cur[i]
                g[i] = 1
        off = head.smooth(off * g[:, None], head.zramp, passes) \
            / np.maximum(head.smooth(g, head.zramp, passes), 1e-3)[:, None]
        cur = cur + off * head.zramp[:, None]
        if rnd == 0:
            good = g
        print("WRAP round", rnd, "projected", int(g[head.head].sum()), "of", len(head.head))
    return cur, good

"""Grows a hairstyle on a character's head by rule, from a style file alone:
no MakeHuman hair, no shell, no scan.

A style (tools/characters/hairstyles/<name>.json) says what a hairdresser
would: where the hairline runs, where the parting is, how long the hair is
over each part of the head, which way it is combed, how much it lifts, falls,
waves and clumps, whether it is tied (a bun), and which loose strands escape.
From that this grows

1. guides: a few hundred strands, rooted over the scalp inside the hairline,
   each grown step by step along the style's comb (or towards the tie),
   bending under gravity and pushed out of the head, so the hair lies on
   the skull with the style's volume;
2. children: tens of thousands of strands between the guides, each
   interpolated from the guides nearest its root on the same side of the
   parting, gathering into its guide's lock towards the tip (clumps), with
   its own wave, frizz and length.

Positions are world space, metres, the character facing -Y with Z up as
bake_character.py makes it. Angles on the head are degrees: azimuth round
the head from the front (+ to the character's left, +X), elevation up from
the centre of the sphere that fits the skull. Directions in a style are in
the head's frame: x to the character's left, y forward, z up.

A style file:

    hairline   {"raise": deg, "fade": deg}  the hairline moved up (or down),
               and how far above it, round the back and sides, the hair is
               cut shorter and shorter towards it (clippered)
    density    child strands; guides  guide strands
    points     points per strand
    base       the parameters everywhere, before sections
    base_weight  how much the base holds against a section at its centre
                 (1); lower lets sections carry the style
    sections   [{"at": [az, el], "reach": deg, "side": -1|1 (optional), ...}]
               each overrides the base near "at", fading out over reach
    parting    {"from": [az, el], "to": [az, el]}: the head is cut in two
               sides by the great circle through these; strands never mix
               across it
    tie        {"at": [x, y, z] head radii from the skull's centre,
                "radius": m, "turns": n}: hair with flow "tie" is drawn
               there and wound into a bun
    strays     [{"at", "reach", "share", ...}]: that share of the roots near
               "at" are loose strands, grown with these parameters

Parameters (base, sections, strays):

    length     m
    flow       "comb" (along comb) or "tie"
    comb       [x, y, z] the way the hair is combed, head frame
    lift       how far it rises off the scalp at the root (0 flat)
    gravity    how much it falls once off the scalp (0..1)
    stiffness  how fast it turns towards where it is drawn (0..1 per step)
    volume     m it stands off the head at most
    hug        how hard it is held down to that (0 free, 1 pinned): tied or
               slicked hair lies on the skull until it leaves for the tie
    clump      how far children gather into their guide's lock at the tip
    wave       m of wave across the strand; wavelength m
    frizz      m of random wander at the tips
"""
import json
import math

import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

PARAMS = ("length", "hug", "lift", "gravity", "stiffness", "volume", "clump", "wave", "wavelength", "frizz")
DEFAULTS = {"length": 0.05, "hug": 0.0, "flow": "comb", "comb": [0, 0, -1], "lift": 0.2, "gravity": 0.3,
            "stiffness": 0.25, "volume": 0.006, "clump": 0.5, "wave": 0.0, "wavelength": 0.03,
            "frizz": 0.001}
# Where hair stops on an average head, as elevation by |azimuth|: high over
# the forehead, dipping at the temples, down in front of the ear (sideburn),
# up over it, and low at the nape.
HAIRLINE = [(0, 34), (20, 33), (38, 27), (52, 18), (62, 8), (72, -4), (78, -14), (84, -12),
            (90, -3), (100, -2), (112, -6), (125, -14), (140, -30), (160, -40), (180, -43)]


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def unit(v):
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, 1e-12)


class Head:
    """A character's head: its skin as a BVH to grow against, and the frame
    a style is written in (the sphere that fits the skull)."""

    def __init__(self, body, eyes):
        mw = body.matrix_world
        V = np.array([mw @ v.co for v in body.data.vertices])
        body.data.calc_loop_triangles()
        T = np.array([t.vertices[:] for t in body.data.loop_triangles])
        E = np.array([eyes.matrix_world @ v.co for v in eyes.data.vertices])
        self.eye_z = float(E[:, 2].mean())
        self.eye_y = float(E[:, 1].mean())
        # the head: everything above the jaw, near the eyes
        head = (V[:, 2] > self.eye_z - 0.12) & (np.abs(V[:, 0]) < 0.14) & (np.abs(V[:, 1] - self.eye_y) < 0.3)
        tri = head[T].all(1)
        self.V, self.T = V, T[tri]
        skull = V[head & (V[:, 2] > self.eye_z + 0.02)]
        A = np.column_stack([2 * skull, np.ones(len(skull))])
        sol = np.linalg.lstsq(A, (skull ** 2).sum(1), rcond=None)[0]
        self.c = sol[:3]
        self.R = float(math.sqrt(sol[3] + (self.c ** 2).sum()))
        self.bvh = BVHTree.FromPolygons([Vector(v) for v in V], [list(t) for t in self.T])
        print("HEAD centre", np.round(self.c, 4), "radius", round(self.R, 4), "eyes z", round(self.eye_z, 4))

    # head frame (x left, y forward, z up) <-> world (X, -Y, Z)
    @staticmethod
    def to_world(d):
        d = np.asarray(d, float)
        return d * np.array([1.0, -1.0, 1.0])

    def angles(self, P):
        d = (P - self.c) * np.array([1.0, -1.0, 1.0])
        az = np.degrees(np.arctan2(d[..., 0], d[..., 1]))
        el = np.degrees(np.arcsin(np.clip(d[..., 2] / np.linalg.norm(d, axis=-1), -1, 1)))
        return az, el

    def nearest(self, p):
        loc, n, _, dist = self.bvh.find_nearest(Vector(p))
        return np.array(loc), np.array(n)


def hairline(az, raise_deg=0.0):
    a, e = np.array(HAIRLINE, float).T
    return np.interp(np.abs(az), a, e) + raise_deg


def direction_on_sphere(az, el):
    az, el = np.radians(az), np.radians(el)
    return np.array([np.sin(az) * np.cos(el), np.cos(az) * np.cos(el), np.sin(el)])


def angle_between(az, el, at):
    """Degrees between the head directions (az, el) and at = [az, el]."""
    a = direction_on_sphere(az, el)
    b = direction_on_sphere(*at)
    return np.degrees(np.arccos(np.clip(np.einsum("i...,i->...", a, b), -1, 1)))


class Style:
    def __init__(self, path):
        with open(path, encoding="utf-8") as f:
            self.d = json.load(f)
        self.base = dict(DEFAULTS, **self.d.get("base", {}))

    def side(self, az, el):
        """-1 or 1 by the parting's great circle; 0 everywhere without one."""
        part = self.d.get("parting")
        if not part:
            return np.zeros(np.shape(az), int)
        n = np.cross(direction_on_sphere(*part["from"]), direction_on_sphere(*part["to"]))
        return np.where(np.einsum("i...,i->...", direction_on_sphere(az, el), n) >= 0, 1, -1)

    def params(self, az, el, side, sections=None):
        """The style's parameters at each root, the base blended with every
        section by how near the root is to it."""
        sections = self.d.get("sections", []) if sections is None else sections
        n = len(az)
        weights = [np.full(n, self.d.get("base_weight", 0.35))]
        values = [self.base]
        for s in sections:
            w = np.exp(-(angle_between(az, el, s["at"]) / s.get("reach", 20)) ** 2)
            if "side" in s:
                w = w * (side == s["side"])
            weights.append(w)
            values.append(dict(self.base, **{k: v for k, v in s.items() if k not in ("at", "reach", "side")}))
        W = np.array(weights)
        W = W / W.sum(0)
        out = {k: sum(W[i] * values[i][k] for i in range(len(values))) for k in PARAMS}
        comb = sum(W[i][:, None] * np.array(values[i]["comb"], float) for i in range(len(values)))
        out["comb"] = unit(comb)
        tie = sum(W[i] * (values[i]["flow"] == "tie") for i in range(len(values)))
        out["tie"] = tie > 0.5
        return out


def sample_roots(head, style, count, rng):
    """count roots over the scalp, area-weighted, inside the hairline (which
    thins out over a few degrees, as real hairlines do)."""
    V, T = head.V, head.T
    a, b, c = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
    cross = np.cross(b - a, c - a)
    area = 0.5 * np.linalg.norm(cross, axis=1)
    raise_deg = style.d.get("hairline", {}).get("raise", 0.0)
    az, el = head.angles((a + b + c) / 3)
    near = el > hairline(az, raise_deg) - 4
    p = area * near
    p /= p.sum()
    out, normals, edge = [], [], []
    while sum(len(o) for o in out) < count:
        k = count * 2
        t = rng.choice(len(T), k, p=p)
        u, v = rng.random(k), rng.random(k)
        flip = u + v > 1
        u[flip], v[flip] = 1 - u[flip], 1 - v[flip]
        P = a[t] + (b[t] - a[t]) * u[:, None] + (c[t] - a[t]) * v[:, None]
        paz, pel = head.angles(P)
        line = hairline(paz, raise_deg)
        jag = 1.5 * np.sin(np.radians(paz) * 37) + 1.0 * np.sin(np.radians(paz) * 91 + 1)
        keep = rng.random(k) < smoothstep(line - 1.5, line + 2.5, pel + jag)
        out.append(P[keep])
        normals.append(unit(cross[t][keep]))
        fade = style.d.get("hairline", {}).get("fade", 0.0) * smoothstep(60, 120, np.abs(paz))
        edge.append(smoothstep(line + 4 + fade, line - 1, pel + jag)[keep])
    P = np.concatenate(out)[:count]
    N = np.concatenate(normals)[:count]
    # face normals of an outward head point outward; make sure
    N = np.where(((N * (P - head.c)).sum(1) < 0)[:, None], -N, N)
    return P, N, np.concatenate(edge)[:count]


def poisson(P, spacing):
    """Indices of a subset of P no two closer than spacing (greedy on a grid)."""
    cell = spacing / math.sqrt(3)
    grid = {}
    keep = []
    for i in np.random.default_rng(3).permutation(len(P)):
        key = tuple((P[i] // cell).astype(int))
        ok = True
        for dx in (-2, -1, 0, 1, 2):
            for dy in (-2, -1, 0, 1, 2):
                for dz in (-2, -1, 0, 1, 2):
                    j = grid.get((key[0] + dx, key[1] + dy, key[2] + dz))
                    if j is not None and np.linalg.norm(P[j] - P[i]) < spacing:
                        ok = False
                        break
                if not ok:
                    break
            if not ok:
                break
        if ok:
            grid[key] = i
            keep.append(i)
    return np.array(keep)


def tangent(v, n):
    return v - n * (v @ n)


def grow_guide(head, root, normal, prm, tie, rng, step=0.0025):
    """One guide: from root along the style, pushed out of the head."""
    down = np.array([0.0, 0, -1])
    comb = Head.to_world(prm["comb"])
    t0 = tangent(comb, normal)
    if np.linalg.norm(t0) < 1e-6:
        t0 = tangent(down, normal)
    d = unit(unit(t0) + normal * prm["lift"])
    p = root + normal * 0.0008
    pts = [root.copy(), p.copy()]
    s = 0.0
    layer = rng.random()
    standoff = 0.0012 + prm["volume"] * (0.25 + 0.75 * layer)
    length = prm["length"] * rng.uniform(0.9, 1.05)
    while s < length:
        q, nq = head.nearest(p)
        off = p - q
        dist = float(off @ nq)
        if prm["tie"] and tie is not None:
            want = tie["at"] - p
            if np.linalg.norm(want) < tie["radius"] * 0.9:
                break
        else:
            want = comb
        if dist < 0.02:
            want = tangent(want, nq) + nq * 0.15 * prm["lift"]
        g = prm["gravity"] * smoothstep(0.0, 0.04, s)
        target = unit(unit(want) * (1 - g) + down * g)
        d = unit(d + (target - d) * prm["stiffness"])
        p = p + d * step
        q, nq = head.nearest(p)
        dist = float((p - q) @ nq)
        need = standoff * smoothstep(0.0, 0.025, s + 0.004)
        if dist < need:
            p = p + nq * (need - dist)
            d = unit(d - nq * min(0.0, float(d @ nq)))
        elif prm["hug"] > 0:
            free = 1.0
            if prm["tie"] and tie is not None:
                free = smoothstep(tie["radius"] * 2.6, tie["radius"] * 1.5, float(np.linalg.norm(tie["at"] - p)))
            pull = (dist - need) * prm["hug"] * (1 - free)
            p = p - nq * pull
            d = unit(d - nq * max(0.0, float(d @ nq)) * prm["hug"] * (1 - free))
        pts.append(p.copy())
        s += step
    return np.array(pts)


def bun_coil(start, tie, rest, u, phase, rng):
    """The rest of a tied strand, wound round the bun: a rope coiled round
    the tie's axis, the strand twisting round the rope."""
    axis = tie["axis"]
    e1 = unit(np.cross(axis, np.array([0.0, 0, 1])))
    e2 = np.cross(axis, e1)
    R = tie["radius"]
    rel = start - tie["at"]
    phi0 = math.atan2(rel @ e2, rel @ e1)
    turns = tie.get("turns", 1.4)
    n = max(8, int(rest / 0.0025))
    t = np.linspace(0, 1, n)[1:]
    phi = phi0 + t * turns * 2 * math.pi
    rope_r = R * (0.75 - 0.35 * t)
    centre = tie["at"] + axis * R * 0.45
    rope = centre + rope_r[:, None] * (np.cos(phi)[:, None] * e1 + np.sin(phi)[:, None] * e2)
    psi = phase + phi * 3.0
    tube = R * 0.42 * u * (0.7 + 0.3 * t)
    radial = np.cos(phi)[:, None] * e1 + np.sin(phi)[:, None] * e2
    pts = rope + tube[:, None] * (np.cos(psi)[:, None] * radial + np.sin(psi)[:, None] * axis)
    # lead in from where the strand reached the tie
    lead = np.clip(t / 0.12, 0, 1)[:, None]
    return start + (pts - start) * lead


def resample(curve, m):
    seg = np.linalg.norm(np.diff(curve, axis=0), axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)])
    t = np.linspace(0, cum[-1], m)
    return np.column_stack([np.interp(t, cum, curve[:, i]) for i in range(3)]), cum[-1]


def grow(head, style, seed=1):
    """The style on this head: (strands [n, m, 3], radius [n, m])."""
    rng = np.random.default_rng(seed)
    d = style.d
    m = d.get("points", 32)
    count = d.get("density", 30000)
    P, N, edge = sample_roots(head, style, count, rng)
    az, el = head.angles(P)
    side = style.side(az, el)
    prm = style.params(az, el, side)
    group = side.copy()
    # strays: loose strands, their own group
    stray_prm = []
    for k, s in enumerate(d.get("strays", [])):
        near = np.exp(-(angle_between(az, el, s["at"]) / s.get("reach", 10)) ** 2)
        pick = rng.random(len(P)) < near * s.get("share", 0.05)
        group[pick] = 10 + k
        sp = dict(style.base, **{kk: v for kk, v in s.items() if kk not in ("at", "reach", "share")})
        for key in PARAMS:
            prm[key][pick] = sp[key]
        prm["comb"][pick] = unit(np.array(sp["comb"], float))
        prm["tie"][pick] = sp["flow"] == "tie"
    tie = None
    if "tie" in d:
        t = d["tie"]
        at = head.c + Head.to_world(np.array(t["at"], float)) * head.R
        q, nq = head.nearest(at)
        tie = dict(t, at=q + nq * t["radius"] * 0.6, axis=nq)
    # guides: spread over each group
    gi = []
    for g in np.unique(group):
        idx = np.where(group == g)[0]
        spacing = d.get("guide_spacing", 0.006) * (0.6 if g >= 10 else 1.0)
        gi.extend(idx[poisson(P[idx], spacing)])
    gi = np.array(gi)
    print("ROOTS", len(P), "GUIDES", len(gi), "groups", {int(g): int((group[gi] == g).sum()) for g in np.unique(group)})
    G = np.zeros((len(gi), m, 3))
    for j, i in enumerate(gi):
        one = {k: (v[i] if not isinstance(v, np.ndarray) or v.ndim == 1 else v[i]) for k, v in prm.items()}
        curve = grow_guide(head, P[i], N[i], one, tie, rng)
        if one["tie"] and tie is not None:
            done = np.linalg.norm(np.diff(curve, axis=0), axis=1).sum()
            rest = max(0.02, one["length"] * 1.0 - done) + 0.12
            curve = np.concatenate([curve, bun_coil(curve[-1], tie, rest, rng.random() ** 0.5, rng.random() * 6.28, rng)])
        G[j], _ = resample(curve, m)
    # waves on the guides, so locks wave together
    t = np.linspace(0, 1, m)
    for j, i in enumerate(gi):
        if prm["wave"][i] <= 0:
            continue
        along = unit(np.gradient(G[j], axis=0))
        across = unit(np.cross(along, N[i]))
        arc = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(G[j], axis=0), axis=1))])
        ph = rng.random() * 6.28
        G[j] += across * (prm["wave"][i] * smoothstep(0.0, 0.3, t) * np.sin(arc / prm["wavelength"][i] * 6.28 + ph))[:, None]
    # children from the three nearest guides of their own group
    S = np.zeros((len(P), m, 3))
    radius = np.zeros((len(P), m))
    for g in np.unique(group):
        idx = np.where(group == g)[0]
        gj = np.where(group[gi] == g)[0]
        kd = KDTree(len(gj))
        for a, j in enumerate(gj):
            kd.insert(Vector(G[j, 0]), a)
        kd.balance()
        for i in idx:
            near = kd.find_n(Vector(P[i]), min(3, len(gj)))
            js = np.array([gj[a] for _, a, _ in near])
            w = 1.0 / (np.array([dd for _, _, dd in near]) + 1e-4)
            w /= w.sum()
            shape = (w[:, None, None] * (G[js] - G[js, :1])).sum(0)
            lf = rng.uniform(0.8, 1.0) * (1 - 0.7 * edge[i])
            tt = t * lf
            shape = np.column_stack([np.interp(tt, t, shape[:, k]) for k in range(3)])
            child = P[i] + shape
            lock = G[js[0]] - G[js[0], 0] + P[i]
            lock = np.column_stack([np.interp(tt, t, lock[:, k]) for k in range(3)])
            towards = G[js[0]]
            towards = np.column_stack([np.interp(tt, t, towards[:, k]) for k in range(3)])
            c = prm["clump"][i] * tt ** 0.8
            child = child + (towards - child) * c[:, None] * 0.85
            fr = prm["frizz"][i] * tt ** 2
            child += rng.normal(0, 1, (m, 3)).cumsum(0) / math.sqrt(m) * fr[:, None]
            S[i] = child
            radius[i] = 0.0001 * (1 - 0.6 * t) * (1 - 0.4 * edge[i])
    # push children out of the head
    for i in range(len(P)):
        for k in range(1, m):
            q, nq = head.nearest(S[i, k])
            dist = float((S[i, k] - q) @ nq)
            if dist < 0.0006:
                S[i, k:] += nq * (0.0006 - dist)
    return S, radius, G

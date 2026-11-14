"""Grows a hairstyle on a character's head by rule, from a style file alone:
no MakeHuman hair, no shell, no scan.

A style (tools/characters/hairstyles/<name>.json) says what a hairdresser
would: where the hairline runs, which way the hair is combed over each part
of the head and where it parts, how long it is there and how much it lifts,
lies, falls, waves and clumps, whether it is tied into a bun, and which locks
are left out of it. From that this grows

1. a flow: the way hair runs over the scalp, everywhere, made from the
   style's few combing strokes, the crown's whorl (hair grows away from it)
   and, for tied hair, the tie it is drawn to. A parting is a cut in it:
   strokes reach only their own side, and hair beside the cut is pushed
   away from it, so the two sides part along a line;
2. guides: a few hundred strands rooted over the scalp, each leaving the
   skin at its lift angle and grown step by step along the flow, held to
   its layer over the head (or falling free under gravity where it leaves
   it), colliding with the skin and ears;
3. children: tens of thousands of strands between the guides, each made
   from the guides nearest its root on its own side of the parting,
   gathering into its guide's lock (and a finer lock within that) towards
   the tip;
4. for tied hair, the bun: every tied strand is gathered at the tie, then
   wound with the rest into one rope that coils round the tie from its
   centre outwards, twisting as it goes, its thinning end tucked under.

The hairline is drawn round the head's own ears, found on its mesh: a front
line, the temples (receding on a man), a sideburn, an arc over each ear and
the nape. Hair thins out over its last few millimetres.

Positions are world space, metres, the character facing -Y with Z up as
bake_character.py makes it. Angles on the head are degrees: azimuth round
the head from the front (+ to the character's left, +X), elevation up from
the centre of the sphere that fits the skull. Directions in a style are in
the head's frame: x to the character's left, y forward, z up.

A style file:

    density, guides_spacing, points   child strands, guide spacing (m), points per strand
    hairline   {"front": el, "temple": deg receded, "sideburn": deg below the
                ear's top, "nape": el, "fade": deg}; fade clippers the hair
               shorter towards the hairline round the back and sides
    whorl      [az, el]: the crown, where hair grows away from
    parting    {"from": [az, el], "toward": [az, el], "stop": 0..1, "width": deg}:
               a cut along the great circle from "from" towards "toward",
               stopping that far along; side 1 is the character's left of it
    flow       [{"at": [az, el], "reach": deg, "dir": [x, y, z], "side": 1|-1}]
               combing strokes
    tie        {"at": [az, el], "rope": m, "turns": n, "twist": turns per m}
    base       parameters everywhere; a value may be a profile by elevation,
               [[el, v], ...]
    sections   [{"at": [az, el], "reach": deg, "side": ..., params}] override
               the base near "at"
    locks      [{"at": [az, el], "strands": n, "dir": [x, y, z], params}]
               the n roots nearest "at", left out as one lock
    baby_hairs share of the strands at the very hairline that are short and
               loose instead of combed with the rest

Parameters:

    length     m
    lift       degrees the hair leaves the skin at
    volume     m it stands off the head at most (its layer)
    hug        how hard it is held to its layer (0 falls free, 1 lies there)
    gravity    how much it falls where it is free (0..1)
    stiffness  how fast it turns to where it is drawn (0..1 per step)
    clump      how far children gather into their guide's lock at the tip
    clump2     and into their finer lock
    wave       m across; wavelength m
    frizz      m of random wander at the tips
"""
import json
import math

import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

PARAMS = ("length", "lift", "volume", "hug", "gravity", "stiffness", "clump", "clump2", "wave", "wavelength",
          "frizz")
DEFAULTS = {"length": 0.05, "lift": 15.0, "volume": 0.006, "hug": 0.6, "gravity": 0.4, "stiffness": 0.3,
            "clump": 0.4, "clump2": 0.3, "wave": 0.0, "wavelength": 0.04, "frizz": 0.0008}
DOWN = np.array([0.0, 0.0, -1.0])
FLIP = np.array([1.0, -1.0, 1.0])  # head frame <-> world


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def unit(v):
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, 1e-12)


def direction(az, el):
    """Head-frame unit vector(s) for azimuth, elevation in degrees."""
    az, el = np.radians(az), np.radians(el)
    return np.stack([np.sin(az) * np.cos(el), np.cos(az) * np.cos(el), np.sin(el)], -1)


def degrees_between(u, at):
    return np.degrees(np.arccos(np.clip(u @ direction(*at), -1, 1)))


class Head:
    """A character's head: its skin as a BVH to grow against, the sphere
    that fits its skull (the frame a style is written in) and its ears."""

    def __init__(self, body, eyes):
        mw = body.matrix_world
        V = np.array([mw @ v.co for v in body.data.vertices])
        body.data.calc_loop_triangles()
        T = np.array([t.vertices[:] for t in body.data.loop_triangles])
        E = np.array([eyes.matrix_world @ v.co for v in eyes.data.vertices])
        self.eye_z = float(E[:, 2].mean())
        eye_y = float(E[:, 1].mean())
        head = (V[:, 2] > self.eye_z - 0.13) & (np.abs(V[:, 0]) < 0.14) & (np.abs(V[:, 1] - eye_y) < 0.3)
        self.V, self.T = V, T[head[T].all(1)]
        skull = V[head & (V[:, 2] > self.eye_z + 0.02)]
        A = np.column_stack([2 * skull, np.ones(len(skull))])
        sol = np.linalg.lstsq(A, (skull ** 2).sum(1), rcond=None)[0]
        self.c = sol[:3]
        self.R = float(math.sqrt(sol[3] + (self.c ** 2).sum()))
        self.bvh = BVHTree.FromPolygons([Vector(v) for v in V], [list(t) for t in self.T])
        self._ears(V[np.unique(self.T)])
        print("HEAD centre", np.round(self.c, 4), "radius", round(self.R, 4), "ear az %.0f..%.0f top el %.0f"
              % (self.ear_front, self.ear_back, self.ear_top))

    def _ears(self, V):
        """The ears: what sticks out sideways from the skull below the eyes'
        height, as azimuths (front, back) and the elevation of their top."""
        V = V[V[:, 0] > 0]
        skull_x = V[np.abs(V[:, 2] - (self.eye_z + 0.035)) < 0.005, 0].max()
        low = (V[:, 2] < self.eye_z + 0.03) & (V[:, 2] > self.eye_z - 0.09)
        ear = V[low & (V[:, 0] > skull_x + 0.004)]
        az, el = self.angles(ear)
        self.ear_front, self.ear_back, self.ear_top = float(az.min()) - 4, float(az.max()) + 4, float(el.max()) + 2
        self.ear_at = [float(az.mean()), float(el.min() + el.max()) / 2]

    def frame(self, P):
        """Head-frame unit directions of world points from the skull's centre."""
        return unit((P - self.c) * FLIP)

    def angles(self, P):
        u = self.frame(P)
        return np.degrees(np.arctan2(u[..., 0], u[..., 1])), np.degrees(np.arcsin(np.clip(u[..., 2], -1, 1)))

    def on_skin(self, az, el):
        """The point of the skin in the direction (az, el), and its normal."""
        p = self.c + direction(az, el) * FLIP * self.R * 1.5
        loc, n, _, _ = self.bvh.ray_cast(Vector(p), Vector(self.c - p))
        return np.array(loc), np.array(n) * (1 if np.dot(np.array(n), np.array(loc) - self.c) > 0 else -1)

    def nearest(self, p):
        loc, n, _, _ = self.bvh.find_nearest(Vector(p))
        loc, n = np.array(loc), np.array(n)
        if n @ (loc - self.c) < 0:
            n = -n
        return loc, n

    def collide(self, p, q):
        """q, or where the step p -> q first meets the skin, kept just off it."""
        d = q - p
        L = float(np.linalg.norm(d))
        if L < 1e-9:
            return q, None
        hit = self.bvh.ray_cast(Vector(p), Vector(d / L), L + 0.0004)
        if hit[0] is None:
            return q, None
        n = np.array(hit[1])
        if n @ d > 0:
            n = -n
        return np.array(hit[0]) + n * 0.0005, n

    def hairline(self, line):
        """The hairline as elevation by |azimuth|, round this head's ears."""
        F = line.get("front", 34.0)
        T = line.get("temple", 0.0)
        Sb = line.get("sideburn", 8.0)
        N = line.get("nape", -48.0)
        Ef, Eb, Et = self.ear_front, self.ear_back, self.ear_top
        pts = [(0, F), (16, F - 0.5), (30, F - 3 - 0.4 * T), (42, F - 7 - T), (52, F - 13 - 0.6 * T),
               (60, F - 23 - 0.3 * T), (Ef - 13, Et + 7), (Ef - 9, Et - Sb), (Ef - 2, Et - Sb), (Ef + 1, Et + 1),
               (Ef + 6, Et + 5), ((Ef + Eb) / 2, Et + 7), (Eb - 2, Et + 4), (Eb + 6, Et - 4),
               (Eb + 14, Et - 16), (140, N + 16), (160, N + 4), (180, N)]
        a, e = np.array(sorted(pts)).T
        return lambda az: np.interp(np.abs(az), a, e)


class Style:
    def __init__(self, path, head):
        with open(path, encoding="utf-8") as f:
            self.d = json.load(f)
        self.head = head
        self.base = dict(DEFAULTS, **self.d.get("base", {}))
        self.line = head.hairline(self.d.get("hairline", {}))
        part = self.d.get("parting")
        self.part = None
        if part:
            a = direction(*part["from"])
            w = direction(*part["toward"])
            n = unit(np.cross(a, w))
            if n[0] < 0:
                n = -n
            b = unit(w - a * (w @ a))
            self.part = dict(a=a, b=b, n=n, arc=math.acos(np.clip(a @ w, -1, 1)) * part.get("stop", 1.0),
                             width=part.get("width", 5.0), strength=part.get("strength", 1.5))
        self.whorl = direction(*self.d["whorl"]) if "whorl" in self.d else None
        self.strokes = [dict(s, u=direction(*s["at"]), dir=np.array(s["dir"], float)) for s in self.d.get("flow", [])]
        self.tie_u = direction(*self.d["tie"]["at"]) if "tie" in self.d else None
        az, el = head.ear_at
        self.ears = [direction(az, el), direction(-az, el)]

    def around_ears(self, u, f, strength):
        """f bent up and over the ears near them: away from an ear, and up
        where the hair is still in front of it, so it clears the rim."""
        up = np.array([0.0, 0.0, 1.0])
        for e in self.ears:
            w = math.exp(-(math.degrees(math.acos(np.clip(u @ e, -1, 1))) / 22.0) ** 2)
            if w > 1e-3:
                ahead = smoothstep(-0.05, 0.1, float(u[1] - e[1]))
                lift = unit(up - u * u[2])
                f = f + strength * w * unit(unit(u * (u @ e) - e) + 1.5 * ahead * lift)
        return f

    def side(self, u):
        """1 on the character's left of the parting, -1 on its right; 1
        everywhere without one."""
        if self.part is None:
            return np.ones(len(u), int)
        return np.where(u @ self.part["n"] >= 0, 1, -1)

    def flow(self, u, tied=False):
        """The way hair runs at head-frame direction u (unit, tangent)."""
        if tied and self.tie_u is not None:
            f = self.around_ears(u, unit(self.tie_u - u * (u @ self.tie_u)), 1.4)
            return unit(f - u * (u @ f))
        side = 1 if self.part is None or u @ self.part["n"] >= 0 else -1
        f = np.zeros(3)
        if self.whorl is not None:
            f += 0.2 * unit(u * (u @ self.whorl) - self.whorl)
        for s in self.strokes:
            if "side" in s and s["side"] != side:
                continue
            w = math.exp(-(math.degrees(math.acos(np.clip(u @ s["u"], -1, 1))) / s.get("reach", 25)) ** 2)
            f += w * unit(s["dir"] - u * (u @ s["dir"]))
        if self.part is not None:
            p = self.part
            along = math.atan2(u @ p["b"], u @ p["a"])
            off = math.degrees(math.asin(np.clip(u @ p["n"], -1, 1)))
            if -0.05 < along < p["arc"]:
                fade = smoothstep(p["arc"], p["arc"] * 0.8, along)
                away = unit(p["n"] - u * (u @ p["n"])) * (1 if off >= 0 else -1)
                f += away * p["strength"] * fade * math.exp(-(off / p["width"]) ** 2)
        f = self.around_ears(u, f, 0.5)
        f = f - u * (u @ f)
        if np.linalg.norm(f) < 1e-6:
            f = unit(np.array([0, 0, -1.0]) - u * u[2])
        return unit(f)

    def params(self, u, side):
        """Each parameter at each root: the base (or its profile by
        elevation) blended with the sections near it."""
        el = np.degrees(np.arcsin(np.clip(u[:, 2], -1, 1)))
        n = len(u)

        def value(v):
            if isinstance(v, list):
                a, b = np.array(v, float).T
                return np.interp(el, a, b)
            return np.full(n, float(v))

        out = {k: value(self.base[k]) for k in PARAMS}
        total = np.full(n, self.d.get("base_weight", 0.3))
        acc = {k: out[k] * total for k in PARAMS}
        for s in self.d.get("sections", []):
            w = np.exp(-(degrees_between(u, s["at"]) / s.get("reach", 20)) ** 2)
            if "side" in s:
                w = w * (side == s["side"])
            total = total + w
            for k in PARAMS:
                acc[k] = acc[k] + w * (value(s[k]) if k in s else out[k])
        return {k: acc[k] / total for k in PARAMS}


def sample_roots(head, style, count, rng):
    """count roots over the scalp inside the hairline, area-weighted, the
    hairline thinning over its last few degrees; with each root's normal
    and how near the hairline it is (edge, 1 at the line)."""
    V, T = head.V, head.T
    a, b, c = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
    cross = np.cross(b - a, c - a)
    az, el = head.angles((a + b + c) / 3)
    p = 0.5 * np.linalg.norm(cross, axis=1) * (el > style.line(az) - 4)
    p /= p.sum()
    fade = style.d.get("hairline", {}).get("fade", 0.0)
    out, normals, edge, clip = [], [], [], []
    have = 0
    while have < count:
        k = count * 2
        t = rng.choice(len(T), k, p=p)
        u, v = rng.random(k), rng.random(k)
        flip = u + v > 1
        u[flip], v[flip] = 1 - u[flip], 1 - v[flip]
        P = a[t] + (b[t] - a[t]) * u[:, None] + (c[t] - a[t]) * v[:, None]
        paz, pel = head.angles(P)
        line = style.line(paz)
        jag = 1.2 * np.sin(np.radians(paz) * 41) + 0.8 * np.sin(np.radians(paz) * 97 + 1)
        above = pel + jag - line
        keep = rng.random(k) < smoothstep(-1.0, 3.5, above)
        out.append(P[keep])
        normals.append(unit(cross[t][keep]))
        edge.append(smoothstep(4.0, -0.5, above)[keep])
        f = fade * smoothstep(60, 120, np.abs(paz))
        clip.append(np.where(f > 0, smoothstep(f, -1.0, above), 0.0)[keep])
        have += keep.sum()
    P = np.concatenate(out)[:count]
    N = np.concatenate(normals)[:count]
    N = np.where(((N * (P - head.c)).sum(1) < 0)[:, None], -N, N)
    return P, N, np.concatenate(edge)[:count], np.concatenate(clip)[:count]


def poisson(P, spacing, seed=3):
    """Indices of a subset of P no two closer than spacing."""
    kd = KDTree(len(P))
    keep = []
    taken = np.zeros(len(P), bool)
    for i, p in enumerate(P):
        kd.insert(Vector(p), i)
    kd.balance()
    for i in np.random.default_rng(seed).permutation(len(P)):
        if taken[i]:
            continue
        keep.append(i)
        for _, j, _ in kd.find_range(Vector(P[i]), spacing):
            taken[j] = True
    return np.array(keep, int)


def grow_guide(head, flow, root, normal, prm, rng, stop=None):
    """One guide from root: out of the skin at its lift, then along the flow
    on its layer, or falling where it is free; never into the skin."""
    length = prm["length"] * rng.uniform(0.94, 1.04)
    step = float(np.clip(length / 16, 0.0005, 0.0025))
    lift = math.radians(prm["lift"])
    f = flow(root)
    d = unit(f * math.cos(lift) + normal * math.sin(lift))
    layer = 0.0005 + prm["volume"] * (0.35 + 0.65 * rng.random())
    rise = 0.004 + prm["volume"] * 1.5
    p = root + normal * 0.0002
    pts = [p.copy()]
    s = 0.0
    while s < length:
        q, nq = head.nearest(p)
        dist = float((p - q) @ nq)
        if stop is not None and stop(p):
            break
        f = flow(q)
        settle = smoothstep(0.0, rise, s)
        on = unit(f + nq * float(np.clip((layer - dist) / 0.003, -1.0, 1.0)) * 0.7)
        hug = prm["hug"] * settle
        free = unit(d * (1 - prm["gravity"]) + DOWN * prm["gravity"])
        target = unit(on * hug + free * (1 - hug)) if settle > 0.05 else d
        d = unit(d + (target - d) * prm["stiffness"])
        q2, hit = head.collide(p, p + d * step)
        if hit is not None:
            d = unit(d - hit * (d @ hit))
        p = q2
        pts.append(p.copy())
        s += step
    return np.array(pts)


def resample(curve, m):
    seg = np.linalg.norm(np.diff(curve, axis=0), axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)])
    t = np.linspace(0, cum[-1], m)
    return np.column_stack([np.interp(t, cum, curve[:, i]) for i in range(3)])


class Bun:
    """The tie and the rope of hair coiled round it."""

    def __init__(self, head, tie):
        self.at, self.axis = head.on_skin(*tie["at"])
        self.rope = tie.get("rope", 0.011)
        up = np.array([0.0, 0, 1])
        self.e1 = unit(np.cross(up, self.axis))
        self.e2 = np.cross(self.axis, self.e1)
        self.gather = self.rope * 1.4
        turns = tie.get("turns", 1.5)
        self.twist = tie.get("twist", 20.0)
        phi = np.linspace(0, turns * 2 * math.pi, 400)
        r0 = self.rope * 0.15
        b = self.rope * 2 * 0.82 / (2 * math.pi)
        r = r0 + b * phi
        rmax = r[-1]
        tuck = smoothstep(turns * 2 * math.pi - 1.6, turns * 2 * math.pi, phi)
        h = self.rope * (1.0 + 0.9 * (1 - r / rmax)) - self.rope * 1.1 * tuck
        C = self.at + (np.cos(phi)[:, None] * self.e1 + np.sin(phi)[:, None] * self.e2) * r[:, None]
        # sit on the head's curve, not its tangent plane
        for i in range(len(C)):
            q, n = head.nearest(C[i])
            C[i] = q + n * h[i]
        self.C = C
        seg = np.linalg.norm(np.diff(C, axis=0), axis=1)
        self.s = np.concatenate([[0], np.cumsum(seg)])
        T = unit(np.gradient(C, axis=0))
        self.B = unit(np.array([head.nearest(c)[1] for c in C]))
        self.N = unit(np.cross(T, self.B))
        self.B = np.cross(self.N, T)
        self.R = self.rope * (1 - 0.5 * smoothstep(0.5, 1.0, self.s / self.s[-1]))
        print("BUN rope %.3f length %.3f across %.3f" % (self.rope, self.s[-1], 2 * (rmax + self.rope)))

    def arrived(self, p):
        return np.linalg.norm(p - self.at) < self.gather

    def slot(self, theta, rho):
        """Where a strand sits in the gathered tail at the tie."""
        return (self.at + self.axis * self.rope * 0.5 +
                self.rope * 0.8 * rho[:, None] * (np.cos(theta)[:, None] * self.e1 + np.sin(theta)[:, None] * self.e2))

    def strands(self, theta, rho, end, m):
        """Each strand's path along the rope: [n, m, 3]."""
        L = self.s[-1]
        s = np.linspace(0, 1, m)[None, :] * end[:, None] * L
        idx = lambda a: np.interp(s, self.s, a)
        C = np.stack([idx(self.C[:, k]) for k in range(3)], -1)
        N = np.stack([idx(self.N[:, k]) for k in range(3)], -1)
        B = np.stack([idx(self.B[:, k]) for k in range(3)], -1)
        R = idx(self.R)
        ang = theta[:, None] + s * self.twist * 2 * math.pi
        wander = 1 + 0.18 * np.sin(s / 0.035 * 6.28 + theta[:, None] * 3 + rho[:, None] * 17)
        off = (np.clip(rho[:, None] * wander, 0, 1.1) * R)[..., None] * (np.cos(ang)[..., None] * N + np.sin(ang)[..., None] * B)
        return C + off


def wave(G, N, amp, wavelength, rng):
    """G with a wave across it, growing in from the root."""
    m = len(G)
    t = np.linspace(0, 1, m)
    along = unit(np.gradient(G, axis=0))
    across = unit(np.cross(along, N))
    arc = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(G, axis=0), axis=1))])
    ph = rng.random() * 6.28
    return G + across * (amp * smoothstep(0.0, 0.25, t) * np.sin(arc / wavelength * 6.28 + ph))[:, None]


def grow(head, style, seed=1, info=None):
    """The style on this head: (strands [n, m, 3], radius [n, m], guides).
    info, a dict, is given how the strands were made: per strand its lock's
    guide (lead, a strand index), group, tied, baby and edge (1 at the
    hairline); guides, the guide strands' indices; scalp_m, how many points
    each strand has on the scalp (the rest of a tied one is in the bun)."""
    rng = np.random.default_rng(seed)
    d = style.d
    m = d.get("points", 24)
    count = d.get("density", 30000)
    P, N, edge, clip = sample_roots(head, style, count, rng)
    U = head.frame(P)
    side = style.side(U)
    prm = style.params(U, side)
    tied = np.full(len(P), "tie" in d)
    group = side.copy()
    lock_dir = {}
    # locks: the roots nearest each, one lock of their own
    for k, lk in enumerate(d.get("locks", [])):
        near = np.argsort(np.linalg.norm(U - direction(*lk["at"]), axis=1))[:lk["strands"]]
        group[near] = 10 + k
        tied[near] = False
        for key in PARAMS:
            if key in lk:
                prm[key][near] = lk[key]
        lock_dir[10 + k] = np.array(lk.get("dir", [0, 0, -1]), float)
    # baby hairs: short, fine and loose at the very hairline of the brow and
    # temples (over the ears and at the nape they would stand off as loops)
    front = smoothstep(75.0, 55.0, np.abs(head.angles(P)[0]))
    baby = (rng.random(len(P)) < d.get("baby_hairs", 0.0) * smoothstep(0.5, 1.0, edge) * front) & (group < 10)
    group[baby] = 5 + (side[baby] > 0)
    tied[baby] = False
    prm["length"][baby] = rng.uniform(0.006, 0.016, baby.sum())
    prm["hug"][baby] = 0.75
    prm["lift"][baby] = 20
    prm["gravity"][baby] = 0.3
    # clippered round the back and sides
    prm["length"] *= 1 - 0.6 * clip
    bun = Bun(head, d["tie"]) if "tie" in d else None

    def flow_for(g, is_tied):
        if g in lock_dir:
            v = lock_dir[g]
            return lambda p: unit(v * FLIP)
        return lambda p: style.flow(head.frame(p[None])[0], is_tied) * FLIP

    # guides, spread over each group
    gi = []
    for g in np.unique(group):
        idx = np.where(group == g)[0]
        spacing = d.get("guide_spacing", 0.006) * (0.5 if g >= 10 else 1.0)
        gi.extend(idx[poisson(P[idx], spacing)])
    gi = np.array(gi)
    print("ROOTS", len(P), "GUIDES", len(gi), "groups", {int(g): int((group == g).sum()) for g in np.unique(group)})
    scalp_m = m if bun is None else d.get("scalp_points", 24)
    G = np.zeros((len(gi), scalp_m, 3))
    for j, i in enumerate(gi):
        one = {k: prm[k][i] for k in PARAMS}
        is_tied = bool(tied[i]) and bun is not None
        if is_tied:
            one["length"] = 0.5
        curve = grow_guide(head, flow_for(group[i], is_tied), P[i], N[i], one, rng,
                           stop=bun.arrived if is_tied else None)
        G[j] = resample(curve, scalp_m)
        if one["wave"] > 0:
            G[j] = wave(G[j], N[i], one["wave"], one["wavelength"], rng)
    # children from the three nearest guides of their own group
    t = np.linspace(0, 1, scalp_m)
    S = np.zeros((len(P), scalp_m, 3))
    lead = np.zeros(len(P), int)
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
            w = 1.0 / (np.array([dd for _, _, dd in near]) + 1e-3)
            w /= w.sum()
            shape = (w[:, None, None] * (G[js] - G[js, :1])).sum(0)
            if not tied[i]:
                lf = rng.uniform(0.85, 1.0)
                shape = np.column_stack([np.interp(t * lf, t, shape[:, k]) for k in range(3)])
            S[i] = P[i] + shape
            lead[i] = gi[js[0]]
    # clumps: into the guide's lock, then into a finer lock within it
    lock_of = {int(i): j for j, i in enumerate(gi)}
    c1 = prm["clump"][:, None] * t[None, :] ** 0.8
    target = G[np.array([lock_of[int(lead[i])] for i in range(len(P))])]
    S = S + (target - S) * c1[..., None] * 0.9
    fine = np.zeros(len(P), int)
    for g in np.unique(group):
        idx = np.where(group == g)[0]
        centres = idx[poisson(P[idx], d.get("fine_spacing", 0.0022), seed=7)]
        kd = KDTree(len(centres))
        for a, j in enumerate(centres):
            kd.insert(Vector(P[j]), a)
        kd.balance()
        for i in idx:
            fine[i] = centres[kd.find(Vector(P[i]))[1]]
    c2 = prm["clump2"][:, None] * t[None, :] ** 0.7
    S = S + (S[fine] - S) * c2[..., None]
    # frizz
    fr = prm["frizz"][:, None] * t[None, :] ** 2
    S = S + rng.normal(0, 1, S.shape).cumsum(1) / math.sqrt(scalp_m) * fr[..., None]
    # out of the skin; and near the ears no farther off it than the hair's
    # layer, so strands that glance off an ear's rim lie back down
    ears = np.array(style.ears)
    for i in range(len(P)):
        lim = 0.001 + prm["volume"][i]
        for k in range(1, scalp_m):
            q, nq = head.nearest(S[i, k])
            dist = float((S[i, k] - q) @ nq)
            if dist < 0.0005:
                S[i, k:] += nq * (0.0005 - dist)
            elif dist > lim and not (tied[i] and k > scalp_m * 0.6):
                near = float((ears @ unit(head.frame(S[i, k]))).max())
                if near > math.cos(math.radians(28)):
                    S[i, k] -= nq * (dist - lim)
    radius = 0.0001 * (1 - 0.6 * t)[None, :] * (1 - 0.45 * edge)[:, None]
    radius[baby] *= 0.6
    if info is not None:
        info.update(lead=lead, group=group, tied=tied & (bun is not None), baby=baby, edge=edge, guides=gi,
                    scalp_m=scalp_m)
    if bun is None:
        return S, radius, G
    # tied strands: drawn into their slot at the tie, then round the rope
    rope_m = m - scalp_m
    rel = S[:, -1] - bun.at
    theta = np.arctan2(rel @ bun.e2, rel @ bun.e1)
    rho = np.sqrt(rng.random(len(P)))
    slot = bun.slot(theta, rho)
    ramp = smoothstep(0.55, 1.0, t)
    T_ = np.where(tied)[0]
    S[T_] = S[T_] + (slot[T_] - S[T_, -1])[:, None, :] * ramp[None, :, None]
    end = rng.uniform(0.78, 1.0, len(P))
    rope = bun.strands(theta, rho, end, rope_m + 1)[:, 1:]
    into = smoothstep(0.0, 0.15, np.linspace(0, 1, rope_m))[None, :, None]
    rope = slot[:, None, :] + (rope - slot[:, None, :]) * into
    full = np.zeros((len(P), m, 3))
    full[:, :scalp_m] = S
    full[T_, scalp_m:] = rope[T_]
    # loose strands: their own scalp part, stretched over all m points
    L_ = np.where(~tied)[0]
    tm = np.linspace(0, 1, m)
    for i in L_:
        full[i] = np.column_stack([np.interp(tm, t, S[i, :, k]) for k in range(3)])
    rr = np.zeros((len(P), m))
    tt = np.linspace(0, 1, m)
    rr[:] = 0.0001 * (1 - 0.6 * tt)[None, :] * (1 - 0.45 * edge)[:, None]
    rr[T_] = 0.0001 * (1 - 0.3 * tt)[None, :] * (1 - 0.45 * edge[T_])[:, None]
    rr[baby] *= 0.6
    return full, rr, G

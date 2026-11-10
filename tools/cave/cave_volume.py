"""Builds the spider cave's rock surface as a mesh.

The cave is a signed distance field sampled on a grid: negative where there
is air, positive in rock. Air is a smooth union of a few shapes (the
entrance tunnel, the main chamber, a west gallery up to a ledge, an east
squeeze and a skylight shaft), cut off below by a floor height field and
broken up with noise, with rock columns standing in the chamber. Surface
nets turns the field into one mesh: a vertex per grid cell the surface
passes through, placed at the mean of the cell's edge crossings, and a quad
for every grid edge the surface crosses.

Faces point into the air. Seen from outside the cave (the CRPG camera sits
above the ceiling) every face is a back face: culled when drawn and, being
a one-sided trimesh, passed through by rays, so the camera looks straight
into the chamber.

Where air reaches the edge of the grid the surface stops, leaving a hole:
only the skylight shaft does, so it opens to the sky.

Writes little-endian binaries the Godot bake reads:
    verts.bin    float32 x,y,z per vertex
    normals.bin  float32 x,y,z per vertex (into the air)
    ao.bin       float32 per vertex: 1 open, 0 tucked into a crevice
    index.bin    int32, three per triangle, Godot's clockwise front faces

    python -I tools/cave/cave_volume.py <out_dir> [--cell 0.4] [--seed 7]
"""

import argparse
import os
import time

import numpy as np
from scipy import ndimage

# Grid bounds in metres (the cave's own space; the area scene uses it as is).
LO = np.array([-34.0, -3.0, -42.0])
HI = np.array([34.0, 15.0, 34.0])

LEDGE_Y = 3.0


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b * (1 - h) + a * h - k * h * (1 - h)


def ellipsoid(p, c, r):
    q = (p - c) / r
    return (np.sqrt((q * q).sum(-1)) - 1.0) * r.min()


def capsule(p, a, b, ra, rb):
    # A tube from a to b whose radius goes from ra to rb.
    ab = b - a
    t = np.clip(((p - a) * ab).sum(-1) / (ab @ ab), 0.0, 1.0)
    near = a + t[..., None] * ab
    return np.sqrt(((p - near) ** 2).sum(-1)) - (ra + (rb - ra) * t)


def polyline_param(px, pz, pts):
    # Distance in xz to a polyline and how far along it (0..1) the nearest
    # point is.
    pts = np.asarray(pts, float)
    seg = np.diff(pts, axis=0)
    lens = np.sqrt((seg ** 2).sum(1))
    start = np.concatenate([[0.0], np.cumsum(lens)])
    best = np.full(px.shape, np.inf)
    along = np.zeros(px.shape)
    for i in range(len(seg)):
        dx, dz = px - pts[i, 0], pz - pts[i, 1]
        t = np.clip((dx * seg[i, 0] + dz * seg[i, 1]) / (lens[i] ** 2), 0, 1)
        d = np.hypot(dx - t * seg[i, 0], dz - t * seg[i, 1])
        closer = d < best
        best = np.where(closer, d, best)
        along = np.where(closer, (start[i] + t * lens[i]) / start[-1], along)
    return best, along


def noise(shape, cell, scale, rng):
    # Smooth value noise with features about `scale` metres across.
    n = np.maximum((np.array(shape) * cell / scale).astype(int) + 4, 4)
    coarse = rng.standard_normal(n)
    coords = [np.linspace(1, n[i] - 3, shape[i]) for i in range(3)]
    grid = np.meshgrid(*coords, indexing="ij")
    return ndimage.map_coordinates(coarse, grid, order=3, mode="nearest")


# The gallery climbs from the entrance tunnel's west wall up to the ledge.
GALLERY = [(-2.0, 20.0), (-9.0, 17.0), (-13.5, 11.0), (-14.5, 4.0)]
# The squeeze leaves the tunnel's east wall and enters the chamber's east side.
SQUEEZE = [(2.0, 22.0), (9.0, 19.0), (13.0, 12.0), (13.5, 2.0), (11.0, -3.0)]


def floor_height(x, z, rng_field):
    # The chamber floor is 0. Its west side is a ledge LEDGE_Y up, with a
    # cliff for an edge, that slopes down to the floor at its north end;
    # the gallery's floor climbs from 0 to the ledge along its length.
    edge = -9.0 + 1.2 * np.sin(z * 0.35)
    ledge = np.clip((edge - x) / 0.6, 0.0, 1.0)
    ledge *= np.clip((z + 18.0) / 8.0, 0.0, 1.0)  # ramp down at the north end
    ledge *= np.clip((10.0 - z) / 3.0, 0.0, 1.0)
    h = LEDGE_Y * ledge
    d, t = polyline_param(x, z, GALLERY)
    gallery = LEDGE_Y * np.clip(t * 1.15, 0, 1) * (d < 5.0)
    h = np.maximum(h, gallery)
    return h + rng_field


def build_field(cell, seed):
    rng = np.random.default_rng(seed)
    axes = [np.arange(LO[i], HI[i] + 1e-6, cell) for i in range(3)]
    shape = tuple(len(a) for a in axes)
    X, Y, Z = np.meshgrid(*axes, indexing="ij")
    P = np.stack([X, Y, Z], -1)
    print("grid", shape, "%.1fM cells" % (np.prod(shape) / 1e6))

    # Main chamber, with a second lobe north-east so it isn't one bubble.
    d = ellipsoid(P, np.array([0.0, 0.5, -8.0]), np.array([15.0, 11.0, 14.0]))
    d = smin(d, ellipsoid(P, np.array([8.0, 0.0, -20.0]), np.array([9.0, 8.0, 9.0])), 3.0)
    # The west side of the chamber over the ledge.
    d = smin(d, ellipsoid(P, np.array([-12.0, 3.0, -8.0]), np.array([6.5, 6.5, 14.5])), 3.0)
    # Entrance tunnel from the south, opening into the chamber.
    d = smin(d, capsule(P, np.array([0.0, 1.0, 27.0]), np.array([0.0, 1.5, 6.0]), 3.0, 3.8), 2.0)
    # The skylight shaft, leaning a little, out through the top of the grid.
    d = smin(d, capsule(P, np.array([5.0, 9.0, -12.0]), np.array([7.0, 18.0, -14.0]), 2.6, 1.8), 1.5)
    # West gallery: a tube that follows the climbing floor.
    for (ax, az), (bx, bz), ta, tb in zip(GALLERY[:-1], GALLERY[1:], [0.0, 0.35, 0.7], [0.35, 0.7, 1.0]):
        ya = 1.4 + LEDGE_Y * min(ta * 1.15, 1)
        yb = 1.4 + LEDGE_Y * min(tb * 1.15, 1)
        d = smin(d, capsule(P, np.array([ax, ya, az]), np.array([bx, yb, bz]), 2.4, 2.4), 1.0)
    # East squeeze: low and narrow.
    for (ax, az), (bx, bz) in zip(SQUEEZE[:-1], SQUEEZE[1:]):
        d = smin(d, capsule(P, np.array([ax, 1.2, az]), np.array([bx, 1.2, bz]), 1.9, 1.9), 0.8)

    # Rock columns standing in the chamber: waisted, wide at foot and roof.
    for cx, cz, r in [(-3.5, -5.0, 1.3), (6.5, -11.0, 1.1), (-4.0, -17.0, 1.5)]:
        rad = r * (0.75 + 0.5 * ((Y - 5.5) / 6.0) ** 2)
        col = np.hypot(X - cx, Z - cz) - rad
        d = -smin(-d, col, 1.2)

    # Noise on walls and roof, kept off the floor so it stays walkable.
    n = noise(shape, cell, 6.0, rng) * 0.7 + noise(shape, cell, 2.5, rng) * 0.3 + noise(shape, cell, 1.0, rng) * 0.12
    floor_bump = noise((shape[0], 1, shape[2]), cell, 4.0, rng) * 0.12
    # The floor is sampled at a jittered spot per voxel, so the cliff under
    # the ledge is broken rock rather than a straight wall, while flat
    # floor stays flat.
    jx = noise(shape, cell, 1.8, rng) * 0.7
    jz = noise(shape, cell, 1.8, rng) * 0.7
    fh = floor_height(X + jx, Z + jz, floor_bump)
    above = Y - fh
    d = d + n * np.clip((above - 0.4) / 1.6, 0.0, 1.0)
    # Cut by the floor: rock below it everywhere.
    d = np.maximum(d, -above)
    return d.astype(np.float32), axes


# Points every route must reach from the arrival in the entrance tunnel,
# a metre off the floor: chamber, ledge top, gallery, squeeze, ramp foot.
CHECKS = {
    "arrival": (0.0, 1.0, 24.0),
    "chamber": (2.0, 1.0, -8.0),
    "ledge": (-14.0, LEDGE_Y + 1.0, -4.0),
    "gallery": (-9.0, 2.6, 17.0),
    "squeeze_east": (13.0, 1.0, 12.0),
    "squeeze_south": (13.5, 1.0, 2.0),
    "ramp_foot": (-10.5, 1.0, -19.0),
}


def check_routes(F, axes, cell, clearance=0.55):
    # Air with room for a unit's body (clearance from rock on every side)
    # as connected regions; every check point must sit in the arrival's.
    lo = np.array([a[0] for a in axes])
    room = ndimage.distance_transform_edt(F < 0) * cell > clearance
    labels, _ = ndimage.label(room)
    def label_at(p):
        i = tuple(np.round((np.array(p) - lo) / cell).astype(int))
        return labels[i]
    home = label_at(CHECKS["arrival"])
    ok = True
    for name, p in CHECKS.items():
        good = home != 0 and label_at(p) == home
        ok &= good
        print("route %-14s %s" % (name, "ok" if good else "BLOCKED"))
    return ok


def surface_nets(F, axes, cell):
    lo = np.array([a[0] for a in axes])
    inside = F < 0
    nx, ny, nz = F.shape
    # Corner values of each cell.
    c = [F[i:nx - 1 + i, j:ny - 1 + j, k:nz - 1 + k]
         for i in (0, 1) for j in (0, 1) for k in (0, 1)]
    corner = np.array([(i, j, k) for i in (0, 1) for j in (0, 1) for k in (0, 1)], float)
    edges = [(a, b) for a in range(8) for b in range(a + 1, 8) if np.abs(corner[a] - corner[b]).sum() == 1]
    s = [ci < 0 for ci in c]
    any_in = np.logical_or.reduce(s)
    all_in = np.logical_and.reduce(s)
    active = any_in & ~all_in
    idx = np.nonzero(active)
    print("active cells", len(idx[0]))
    acc = np.zeros((len(idx[0]), 3))
    cnt = np.zeros(len(idx[0]))
    cv = [ci[idx] for ci in c]
    for a, b in edges:
        va, vb = cv[a], cv[b]
        cross = (va < 0) != (vb < 0)
        t = np.where(cross, va / np.where(cross, va - vb, 1.0), 0.0)
        pos = corner[a] + t[:, None] * (corner[b] - corner[a])
        acc += pos * cross[:, None]
        cnt += cross
    local = acc / cnt[:, None]
    verts = lo + (np.stack(idx, 1) + local) * cell
    vid = np.full(active.shape, -1, np.int64)
    vid[idx] = np.arange(len(idx[0]))

    quads = []
    # A grid edge along `axis` from point p to p+1 whose ends differ in sign
    # is crossed by the surface; the four cells around it make a quad.
    for axis in range(3):
        o = [1, 2] if axis == 0 else ([2, 0] if axis == 1 else [0, 1])
        sl_a = [slice(None)] * 3
        sl_b = [slice(None)] * 3
        sl_a[axis] = slice(0, F.shape[axis] - 1)
        sl_b[axis] = slice(1, F.shape[axis])
        ia, ib = inside[tuple(sl_a)], inside[tuple(sl_b)]
        e = [np.asarray(v) for v in np.nonzero(ia != ib)]
        # An edge on the grid's boundary has cells on one side only: no quad.
        keep = np.ones(len(e[0]), bool)
        for ax2 in o:
            keep &= e[ax2] < F.shape[ax2] - 1
            keep &= e[ax2] >= 1
        e = [v[keep] for v in e]
        flip = inside[tuple(e)]  # air at the low end
        def cellid(du, dv):
            q = [v.copy() for v in e]
            q[o[0]] -= du
            q[o[1]] -= dv
            return vid[tuple(q)]
        q0, q1, q2, q3 = cellid(1, 1), cellid(0, 1), cellid(0, 0), cellid(1, 0)
        quad = np.stack([q0, q1, q2, q3], 1)
        quad[flip] = quad[flip][:, ::-1]
        quads.append(quad)
    quads = np.concatenate(quads)
    assert (quads >= 0).all()
    return verts, quads


# ---------------------------------------------------------------- mouth
# The cave's entrance in the goblin quarry: a rock outcrop set into a notch
# in the quarry's south cliff, with a tunnel through it, in quarry space.
# Here the rock is the solid and the faces point out, seen from outside.
MOUTH_AT = np.array([-14.0, 0.0, -79.0])
MOUTH_FLOOR = 3.6
MOUTH_LO = np.array([-24.0, 0.0, -90.0])
MOUTH_HI = np.array([-4.0, 20.0, -68.0])


def rbox(p, c, b, r):
    # A box of half-extents b with edges rounded by r.
    q = np.abs(p - c) - b
    return np.sqrt((np.maximum(q, 0.0) ** 2).sum(-1)) + np.minimum(q.max(-1), 0.0) - r


def build_mouth_field(cell, seed):
    rng = np.random.default_rng(seed)
    axes = [np.arange(MOUTH_LO[i], MOUTH_HI[i] + 1e-6, cell) for i in range(3)]
    shape = tuple(len(a) for a in axes)
    X, Y, Z = np.meshgrid(*axes, indexing="ij")
    P = np.stack([X, Y, Z], -1)
    c = MOUTH_AT
    # Rock, blocky like the quarry's cut faces: a brow over the opening,
    # stepped back and up into a mass that fills the notch past the cliff
    # top, and a buttress either side, the west one taller.
    rock = rbox(P, c + [0.0, 5.6, 2.6], np.array([4.2, 2.6, 2.4]), 0.8)
    rock = smin(rock, rbox(P, c + [0.3, 9.5, -3.0], np.array([5.2, 8.5, 4.6]), 1.0), 1.2)
    rock = smin(rock, rbox(P, c + [-4.3, 4.2, 2.2], np.array([1.6, 4.2, 2.4]), 0.7), 0.9)
    rock = smin(rock, rbox(P, c + [4.1, 3.0, 1.8], np.array([1.5, 3.0, 2.6]), 0.7), 0.9)
    # Bedding: noise stretched flat into horizontal layers, and creases
    # from folded noise, so faces break in ledges and cracks rather than
    # bulging.
    beds = noise(shape, cell, np.array([5.0, 0.9, 5.0]), rng)
    crease = np.abs(noise(shape, cell, 2.2, rng))
    big = noise(shape, cell, 4.0, rng)
    rock = rock + beds * 0.32 + crease * 0.45 + big * 0.5
    # The tunnel: a rounded bore with a flat floor, ending blind inside.
    bore = capsule(P, c + [0.0, MOUTH_FLOOR + 1.3, 7.0], c + [0.0, MOUTH_FLOOR + 1.1, -5.0], 2.3, 2.0)
    bore = bore + noise(shape, cell, 1.5, rng) * 0.25
    air = np.maximum(bore, MOUTH_FLOOR - Y)
    # Negative is air: outside the rock, or in the bore.
    d = np.minimum(-rock, air)
    # Rock below the floor everywhere near the tunnel, so it has a floor.
    d = np.where((Y < MOUTH_FLOOR) & (rock < 1.0), np.maximum(d, MOUTH_FLOOR - Y), d)
    # Open at the grid's edges so the surface closes on itself.
    edge = np.zeros(shape, bool)
    edge[[0, -1], :, :] = edge[:, [0, -1], :] = edge[:, :, [0, -1]] = True
    d[edge & (d > 0)] = -0.1
    return d.astype(np.float32), axes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--cell", type=float, default=0.4)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--mouth", action="store_true", help="the entrance outcrop in the quarry")
    args = ap.parse_args()
    t0 = time.time()
    if args.mouth:
        F, axes = build_mouth_field(args.cell, args.seed)
    else:
        F, axes = build_field(args.cell, args.seed)
    print("field %.1fs" % (time.time() - t0))
    if not args.mouth and not check_routes(F, axes, args.cell):
        raise SystemExit("a route is blocked")
    verts, quads = surface_nets(F, axes, args.cell)
    print("nets %.1fs, %d verts, %d quads" % (time.time() - t0, len(verts), len(quads)))

    lo = np.array([a[0] for a in axes])
    gx, gy, gz = np.gradient(F, args.cell)
    def sample(field, pts):
        g = ((pts - lo) / args.cell).T
        return ndimage.map_coordinates(field, g, order=1, mode="nearest")
    grad = np.stack([sample(gx, verts), sample(gy, verts), sample(gz, verts)], 1)
    normals = -grad / np.maximum(np.linalg.norm(grad, axis=1, keepdims=True), 1e-6)
    # How open the air is a metre out from the surface.
    ao = np.clip(-sample(F, verts + normals * 1.2) / 1.2, 0.0, 1.0)

    # Split quads along the shorter diagonal, then wind every triangle so
    # it is a front face from the air side.
    a, b, c, d = (verts[quads[:, i]] for i in range(4))
    short = np.linalg.norm(a - c, axis=1) < np.linalg.norm(b - d, axis=1)
    t1 = np.where(short[:, None], quads[:, [0, 1, 2]], quads[:, [0, 1, 3]])
    t2 = np.where(short[:, None], quads[:, [0, 2, 3]], quads[:, [1, 2, 3]])
    tris = np.concatenate([t1, t2])
    pa, pb, pc = (verts[tris[:, i]] for i in range(3))
    geo = np.cross(pb - pa, pc - pa)
    want = normals[tris].sum(1)
    # Godot's front faces are clockwise seen from the front, so their
    # right-hand normal points away from the viewer.
    wrong = (geo * want).sum(1) > 0
    tris[wrong] = tris[wrong][:, ::-1]
    print("tris %d, flipped %d" % (len(tris), wrong.sum()))

    os.makedirs(args.out, exist_ok=True)
    verts.astype("<f4").tofile(os.path.join(args.out, "verts.bin"))
    normals.astype("<f4").tofile(os.path.join(args.out, "normals.bin"))
    ao.astype("<f4").tofile(os.path.join(args.out, "ao.bin"))
    tris.astype("<i4").tofile(os.path.join(args.out, "index.bin"))
    print("done %.1fs -> %s" % (time.time() - t0, args.out))


if __name__ == "__main__":
    main()

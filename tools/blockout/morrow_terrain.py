"""Stage 1 of the Morrow overworld: the ground.

One height function over the whole map, sampled every CELL metres, and the
paint that goes on it. Downtown is nearly flat on a gentle tilt, the
outskirts roll, the Greywood climbs into hills, a ridge across the north
and a river valley down the west. The roads out of town are graded: a
smoothed height along each, the ground blended toward it, cut through the
ridge. Doors, the start, the inn and the quarry clearing stand on flat pads.

Writes, under world/morrow/:
    terrain.json          the grid, the river's water line and the lake
    terrain_height.bin    N x N float32 heights, row by row in z
    terrain_normal.bin    N x N x 3 float32 normals
    ground_nature.png     paint, 1 m a texel: R soil, G rock, B dirt
    ground_town.png       paint, 1 m a texel: R asphalt, G paving, B cobble
and a top-down preview to tools/blockout/build/morrow/stage1_terrain.png.

Everything placed on the map reads the same heights through Terrain
(below), which interpolates the grid's triangles exactly as the mesh
(world/morrow/morrow_terrain.gd) draws them.

    python tools/blockout/morrow_terrain.py
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from morrow_layout import (DOORS, DOWNTOWN, HALF, INN_HOUSE, LAKE, OUTSKIRTS, QUARRY_CLEARING, RIDGE,  # noqa: E402
                           RIDGE_HALF_WIDTH, RIDGE_HEIGHT, RIVER, ROAD, SAFE_SPOT, SQUARE, START)

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "world", "morrow")
BUILD = os.path.join(ROOT, "tools", "blockout", "build", "morrow")

X0 = -1024.0          # the grid's corner, x and z
CELL = 4.0
N = 513               # vertices a side: 2048 m
PAINT = 2048          # paint texels a side, 1 m each
SEED = 11

ROAD_GRADE = 0.07     # steepest a graded road climbs
RIVER_CUT = 9.0       # valley floor below the smoothed ground
RIVER_FLOOR = 26.0    # half-width of the valley's flat floor
CHANNEL = 10.0        # half-width of the channel cut in it
CHANNEL_DEPTH = 1.5
WATER_BELOW_BANK = 0.5


# ------------------------------------------------------------------ noise

def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def value_noise(x, z, cell, seed):
    table = np.random.default_rng(seed).random((256, 256)) * 2.0 - 1.0
    u, v = x / cell, z / cell
    gu, gv = np.floor(u), np.floor(v)
    fu, fv = u - gu, v - gv
    fu = fu * fu * fu * (fu * (fu * 6 - 15) + 10)
    fv = fv * fv * fv * (fv * (fv * 6 - 15) + 10)
    iu, iv = gu.astype(np.int64) & 255, gv.astype(np.int64) & 255
    iu1, iv1 = (iu + 1) & 255, (iv + 1) & 255
    a, b = table[iv, iu], table[iv, iu1]
    c, d = table[iv1, iu], table[iv1, iu1]
    return (a + (b - a) * fu) * (1 - fv) + (c + (d - c) * fu) * fv


def fbm(x, z, cell, octaves, seed):
    total, amp, norm = 0.0, 1.0, 0.0
    for k in range(octaves):
        total = total + value_noise(x + 37.1 * k, z - 91.7 * k, cell / (2 ** k), seed + k) * amp
        norm += amp
        amp *= 0.5
    return total / norm


# --------------------------------------------------------------- geometry

def polyline(px, pz, pts):
    """Distance from each point to the line, and how far along it the
    nearest spot is."""
    best = np.full(np.shape(px), np.inf)
    along = np.zeros(np.shape(px))
    acc = 0.0
    for (ax, az), (bx, bz) in zip(pts, pts[1:]):
        dx, dz = bx - ax, bz - az
        length = math.hypot(dx, dz)
        t = np.clip(((px - ax) * dx + (pz - az) * dz) / (length * length), 0.0, 1.0)
        d = np.hypot(px - ax - t * dx, pz - az - t * dz)
        nearer = d < best
        best = np.where(nearer, d, best)
        along = np.where(nearer, acc + t * length, along)
        acc += length
    return best, along


def resample(pts, step):
    xs, zs, ss = [], [], []
    acc = 0.0
    for (ax, az), (bx, bz) in zip(pts, pts[1:]):
        length = math.hypot(bx - ax, bz - az)
        n = max(1, int(length // step))
        for i in range(n):
            t = i / n
            xs.append(ax + (bx - ax) * t)
            zs.append(az + (bz - az) * t)
            ss.append(acc + length * t)
        acc += length
    xs.append(pts[-1][0])
    zs.append(pts[-1][1])
    ss.append(acc)
    return np.array(xs), np.array(zs), np.array(ss)


def sample(h, x, z):
    """Bilinear read of the grid, clamped to it."""
    u = np.clip((np.asarray(x) - X0) / CELL, 0, N - 1.001)
    v = np.clip((np.asarray(z) - X0) / CELL, 0, N - 1.001)
    iu, iv = np.floor(u).astype(int), np.floor(v).astype(int)
    fu, fv = u - iu, v - iv
    a, b = h[iv, iu], h[iv, iu + 1]
    c, d = h[iv + 1, iu], h[iv + 1, iu + 1]
    return (a + (b - a) * fu) * (1 - fv) + (c + (d - c) * fu) * fv


def gaussian(values, sigma_samples):
    r = int(sigma_samples * 3)
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma_samples) ** 2)
    k /= k.sum()
    padded = np.pad(values, r, mode="edge")
    return np.convolve(padded, k, mode="valid")


def limit_grade(profile, step, grade):
    up = profile.copy()
    for i in range(1, len(up)):
        up[i] = np.clip(up[i], up[i - 1] - grade * step, up[i - 1] + grade * step)
    down = profile.copy()
    for i in range(len(down) - 2, -1, -1):
        down[i] = np.clip(down[i], down[i + 1] - grade * step, down[i + 1] + grade * step)
    out = (up + down) * 0.5
    for i in range(1, len(out)):
        out[i] = np.clip(out[i], out[i - 1] - grade * step, out[i - 1] + grade * step)
    return out


def blend_toward(h, target, d, inner, base_width, per_metre):
    """Ground within `inner` of a line takes the target height; past it the
    blend widens with how far the ground must move, so a deep cut gets
    long, gentle sides."""
    diff = target - h
    width = base_width + per_metre * np.abs(diff)
    w = 1.0 - smoothstep(0.0, 1.0, (d - inner) / width)
    return h + diff * w


def square_radius(x, z):
    """A rounded square's radius: the districts are squares."""
    return (np.abs(x) ** 6 + np.abs(z) ** 6) ** (1.0 / 6.0)


# ----------------------------------------------------------------- height

def base_heights(x, z):
    """The land before anything is cut into it: the tilt, the rolling
    outskirts, the Greywood's hills and the ridge. Stage 2 lays its roads
    on this."""
    r = square_radius(x, z)
    town = 1.0 - smoothstep(DOWNTOWN - 20.0, DOWNTOWN + 110.0, r)
    wood = smoothstep(OUTSKIRTS - 60.0, OUTSKIRTS + 120.0, r)

    tilt = 0.010 * x + 0.006 * z
    rolling = fbm(x, z, 260.0, 3, SEED) * 10.0
    hills = fbm(x, z, 460.0, 4, SEED + 10) * 30.0
    h = tilt + town * fbm(x, z, 120.0, 2, SEED + 20) * 0.6
    h = h + (1.0 - town) * rolling * (1.0 - 0.5 * wood) + wood * hills

    # The ridge: a cosine bump along a line, broken up near its crest.
    d, _ = polyline(x, z, RIDGE)
    bump = 0.5 * (1.0 + np.cos(np.pi * np.clip(d / RIDGE_HALF_WIDTH, 0.0, 1.0)))
    crag = 0.8 + 0.2 * fbm(x, z, 90.0, 3, SEED + 30)
    return h + RIDGE_HEIGHT * bump * crag * wood


def line_field(x, z, pts, margin):
    """polyline() over just the grid points within `margin` of the line's
    bounds; inf everywhere else."""
    pts = np.asarray(pts, float)
    step = x[0, 1] - x[0, 0]
    ox, oz = x[0, 0], z[0, 0]
    i0 = max(int((pts[:, 0].min() - margin - ox) / step), 0)
    i1 = min(int((pts[:, 0].max() + margin - ox) / step) + 2, x.shape[1])
    j0 = max(int((pts[:, 1].min() - margin - oz) / step), 0)
    j1 = min(int((pts[:, 1].max() + margin - oz) / step) + 2, x.shape[0])
    dist = np.full(x.shape, np.inf)
    along = np.zeros(x.shape)
    if i1 > i0 and j1 > j0:
        d, a = polyline(x[j0:j1, i0:i1], z[j0:j1, i0:i1], [tuple(p) for p in pts])
        dist[j0:j1, i0:i1] = d
        along[j0:j1, i0:i1] = a
    return dist, along


def load_roads():
    with open(os.path.join(OUT, "roads.json")) as fh:
        return json.load(fh)


# How each kind of road is graded: half-width of its flat, the blend past
# it, and how fast the blend widens with depth. Downtown's are not: the
# town is nearly flat already.
GRADED = {"highway": (ROAD * 0.5 + 3.0, 20.0, 2.5, ROAD_GRADE, 25.0),
          "quarry": (8.0, 16.0, 2.5, ROAD_GRADE, 25.0),
          "lane": (5.5, 10.0, 2.0, 0.10, 14.0)}


def build_heights():
    coords = X0 + np.arange(N) * CELL
    x, z = np.meshgrid(coords, coords)
    r = square_radius(x, z)
    h = base_heights(x, z)
    net = load_roads()

    # The roads, graded in the order stage 2 laid them, so a lane meets
    # the highway it leaves at the highway's height. Ground near each takes
    # the road's smoothed height; downtown is graded already, so only out
    # of town does a road cut.
    out_of_town = smoothstep(DOWNTOWN, DOWNTOWN + 60.0, r)
    roads = []
    for road in net["roads"]:
        if road["kind"] not in GRADED:
            continue
        inner, base_w, per_m, grade, sigma = GRADED[road["kind"]]
        rx, rz, rs = resample([tuple(p) for p in road["points"]], CELL)
        tx, tz = np.gradient(rx), np.gradient(rz)
        tl = np.maximum(np.hypot(tx, tz), 1e-6)
        nx, nz = -tz / tl, tx / tl
        across = np.array([-1.0, -0.5, 0.0, 0.5, 1.0]) * (inner + 3.0)
        prof = np.mean([sample(h, rx + nx * o, rz + nz * o) for o in across], axis=0)
        prof = limit_grade(gaussian(prof, sigma / CELL), CELL, grade)
        dist, along = line_field(x, z, road["points"], inner + base_w + per_m * 40.0)
        target = np.interp(along, rs, prof)
        h = h + (blend_toward(h, target, dist, inner, base_w, per_m) - h) * out_of_town
        roads.append({"name": road["name"], "kind": road["kind"], "s": rs, "prof": prof})

    # The river: down a valley whose floor falls all the way. Where a road
    # bridges it, the road's ground is kept as an embankment, and the cut
    # comes back only under the deck.
    pre = h.copy()
    vx, vz, vs = resample(RIVER, CELL)
    prof = gaussian(sample(h, vx, vz), 40.0 / CELL)
    if prof[0] < prof[-1]:
        prof = np.minimum.accumulate(prof[::-1])[::-1]
    else:
        prof = np.minimum.accumulate(prof)
    floor = prof - RIVER_CUT
    dist, along = polyline(x, z, RIVER)
    target = np.interp(along, vs, floor)
    h = blend_toward(h, target, dist, RIVER_FLOOR, 50.0, 3.0)
    under_deck = 1.0 - smoothstep(CHANNEL + 4.0, CHANNEL + 12.0, dist)
    bridges = []
    for bridge in net["bridges"]:
        road = next(rd for rd in net["roads"] if rd["name"] == bridge["road"])
        graded = next(rd for rd in roads if rd["name"] == bridge["road"])
        inner = GRADED[road["kind"]][0]
        d_road, _ = line_field(x, z, road["points"], 200.0)
        depth = np.maximum(pre - h, 0.0)
        bank = 1.0 - smoothstep(0.0, 1.0, (d_road - inner) / (6.0 + 1.5 * depth))
        keep = bank * (1.0 - under_deck)
        h = h + (pre - h) * keep
        deck = float(np.interp(bridge["s"], graded["s"], graded["prof"]))
        bridges.append(dict(bridge, y=deck))
    channel = 0.5 * (1.0 + np.cos(np.pi * np.clip(dist / CHANNEL, 0.0, 1.0)))
    h = h - CHANNEL_DEPTH * channel
    river = [(float(px), float(pz), float(w - WATER_BELOW_BANK))
             for px, pz, w in zip(vx[::2], vz[::2], floor[::2])]

    # The lake: the ground round it levelled to its rim, a bowl inside.
    lx, lz, lr = LAKE
    dl = np.hypot(x - lx, z - lz)
    ring = (dl > lr) & (dl < lr + 30.0)
    rim = float(h[ring].mean())
    h = blend_toward(h, np.full_like(h, rim), dl, lr + 20.0, 40.0, 2.0)
    bowl = np.clip(1.0 - (dl / lr) ** 2, 0.0, 1.0)
    h = h - 4.0 * bowl
    lake = {"x": lx, "z": lz, "radius": lr, "water": rim - 0.6}

    # Flat pads under everything that must stand level.
    pads = [(dx, dz, 12.0, 30.0) for _, _, (dx, dz), _ in DOORS]
    pads.append((START[0], START[1], 10.0, 25.0))
    pads.append((SAFE_SPOT[0] + INN_HOUSE[0] * 0.5, SAFE_SPOT[1] + INN_HOUSE[1] * 0.5, 18.0, 30.0))
    pads.append((QUARRY_CLEARING[0], QUARRY_CLEARING[1], 80.0, 50.0))
    for px, pz, pr, blend in pads:
        dp = np.hypot(x - px, z - pz)
        level = float(h[dp < pr].mean())
        w = 1.0 - smoothstep(pr, pr + blend, dp)
        h = h + (level - h) * w

    return x, z, h, river, lake, roads, bridges


def normals(h):
    gz, gx = np.gradient(h, CELL)
    n = np.stack([-gx, np.ones_like(h), -gz], axis=-1)
    return n / np.linalg.norm(n, axis=-1, keepdims=True)


# ------------------------------------------------------------------ paint

def road_distance(roads, kinds, narrow=1.0):
    """Metres from each paint texel to the nearest centreline of the given
    kinds, less that road's half-width: negative on the road."""
    best = np.full((PAINT, PAINT), np.inf, np.float32)
    widths = sorted({rd["width"] for rd in roads if rd["kind"] in kinds})
    for w in widths:
        img = Image.new("1", (PAINT, PAINT), 1)
        draw = ImageDraw.Draw(img)
        for rd in roads:
            if rd["kind"] in kinds and rd["width"] == w:
                draw.line([(px - X0, pz - X0) for px, pz in rd["points"]], fill=0, width=1)
        d = ndimage.distance_transform_edt(np.asarray(img)).astype(np.float32) - w * 0.5 * narrow
        best = np.minimum(best, d)
    return best


def build_paint(h):
    coords = X0 + 0.5 + np.arange(PAINT)
    x, z = np.meshgrid(coords, coords)
    r = square_radius(x, z)
    gz, gx = np.gradient(h, CELL)
    slope_grid = np.hypot(gx, gz).astype(np.float32)
    slope = np.asarray(Image.fromarray(slope_grid, "F").resize((PAINT, PAINT), Image.BILINEAR))
    jitter = fbm(x, z, 6.0, 2, SEED + 40)
    roads = load_roads()["roads"]
    town_side = 1.0 - smoothstep(OUTSKIRTS - 10.0, OUTSKIRTS + 10.0, r)

    # Nature: soil thickens into the woods, rock where it is steep, dirt
    # on the lanes, the trails out of town, the quarry clearing and the
    # river's banks.
    wood = smoothstep(OUTSKIRTS - 80.0, OUTSKIRTS + 160.0, r)
    soil = np.clip(wood * (0.6 + 0.6 * fbm(x, z, 60.0, 3, SEED + 50)), 0.0, 1.0)
    rock = smoothstep(0.28, 0.42, slope + 0.06 * jitter)
    out = road_distance(roads, ("highway", "quarry"))
    # Past the outskirts a road narrows to a trail: a third of it each side.
    trail = road_distance(roads, ("highway", "quarry"), narrow=0.33)
    dirt = (1.0 - smoothstep(-0.5, 1.0, trail + 1.5 * jitter)) * (1.0 - town_side)
    lane = road_distance(roads, ("lane",))
    dirt = np.maximum(dirt, 1.0 - smoothstep(-0.5, 1.0, lane + 1.0 * jitter))
    qd = np.hypot(x - QUARRY_CLEARING[0], z - QUARRY_CLEARING[1])
    dirt = np.maximum(dirt, (1.0 - smoothstep(70.0, 90.0, qd + 8.0 * jitter)) * (0.7 + 0.3 * jitter))
    vd, _ = polyline(x, z, RIVER)
    dirt = np.maximum(dirt, 1.0 - smoothstep(CHANNEL + 4.0, CHANNEL + 12.0, vd + 3.0 * jitter))
    ld = np.hypot(x - LAKE[0], z - LAKE[1])
    dirt = np.maximum(dirt, 1.0 - smoothstep(LAKE[2] - 4.0, LAKE[2] + 6.0, ld + 3.0 * jitter))
    nature = np.stack([soil, rock, dirt], axis=-1)

    # Town: asphalt streets, paved blocks, the cobbled square, and the roads
    # out paved as far as the outskirts.
    edge = DOWNTOWN + ROAD * 0.5
    in_town = (np.abs(x) < edge) & (np.abs(z) < edge)
    street = 1.0 - smoothstep(-0.5, 0.5, road_distance(roads, ("avenue", "street", "ring")))
    asphalt = np.where(in_town, street, 0.0)
    asphalt = np.maximum(asphalt, (1.0 - smoothstep(-0.5, 0.5, out)) * town_side)
    paving = np.where(in_town, 1.0 - street, 0.0)
    sq = SQUARE + ROAD * 0.5
    cobble = 1.0 - smoothstep(sq - 0.5, sq + 0.5, np.maximum(np.abs(x), np.abs(z)))
    asphalt = asphalt * (1.0 - cobble)
    paving = paving * (1.0 - cobble)
    town = np.stack([asphalt, paving, cobble], axis=-1)
    return nature, town


def to_png(rgb, path):
    Image.fromarray((np.clip(rgb, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8), "RGB").save(path, optimize=True)


def preview(h, nature, town, river, lake, path):
    size = 1024
    nat = np.asarray(Image.fromarray((nature * 255).astype(np.uint8), "RGB").resize((size, size)), np.float32) / 255
    twn = np.asarray(Image.fromarray((town * 255).astype(np.uint8), "RGB").resize((size, size)), np.float32) / 255
    col = np.ones((size, size, 3), np.float32) * np.array([0.42, 0.52, 0.3])
    for w, c in ((nat[..., 0], (0.38, 0.32, 0.22)), (nat[..., 1], (0.5, 0.49, 0.47)),
                 (nat[..., 2], (0.6, 0.5, 0.36)), (twn[..., 0], (0.25, 0.25, 0.27)),
                 (twn[..., 1], (0.62, 0.61, 0.58)), (twn[..., 2], (0.7, 0.62, 0.5))):
        col = col * (1 - w[..., None]) + np.array(c) * w[..., None]
    hh = np.asarray(Image.fromarray(h.astype(np.float32), "F").resize((size, size), Image.BILINEAR))
    gz, gx = np.gradient(hh, 2048.0 / size)
    light = np.clip(0.75 + (-gx * 0.6 - gz * 0.8) * 1.6, 0.35, 1.3)
    col = col * light[..., None]
    bands = (np.floor(hh / 5.0) != np.floor(np.roll(hh, 1, 0) / 5.0)) | (np.floor(hh / 5.0) != np.floor(np.roll(hh, 1, 1) / 5.0))
    col[bands] *= 0.82
    img = (np.clip(col, 0, 1) * 255).astype(np.uint8)
    px = lambda v: int((v - X0) / 2048.0 * size)  # noqa: E731
    for (wx, wz, _) in river:
        img[max(0, px(wz) - 2):px(wz) + 3, max(0, px(wx) - 2):px(wx) + 3] = (60, 95, 120)
    lx, lz = np.meshgrid(np.arange(size), np.arange(size))
    wet = np.hypot(lx - px(lake["x"]), lz - px(lake["z"])) < lake["radius"] * 0.92 * size / 2048.0
    img[wet] = (60, 95, 120)
    a, b = px(-HALF), px(HALF)
    img[a, a:b] = img[b, a:b] = img[a:b, a] = img[a:b, b] = (200, 40, 40)
    Image.fromarray(img, "RGB").save(path)


# ------------------------------------------------------------- the sampler

class Terrain:
    """The written heights, read the way the mesh draws them: each grid
    cell is two triangles split from (ix+1, iz) to (ix, iz+1)."""

    def __init__(self):
        with open(os.path.join(OUT, "terrain.json")) as fh:
            self.meta = json.load(fh)
        self.x0 = self.meta["x0"]
        self.cell = self.meta["cell"]
        self.n = self.meta["n"]
        self.h = np.fromfile(os.path.join(OUT, "terrain_height.bin"), np.float32).reshape(self.n, self.n)

    def at(self, x, z):
        u = min(max((x - self.x0) / self.cell, 0.0), self.n - 1.0001)
        v = min(max((z - self.x0) / self.cell, 0.0), self.n - 1.0001)
        iu, iv = int(u), int(v)
        fu, fv = u - iu, v - iv
        a = self.h[iv, iu]
        b = self.h[iv, iu + 1]
        c = self.h[iv + 1, iu]
        d = self.h[iv + 1, iu + 1]
        if fu + fv <= 1.0:
            return float(a + (b - a) * fu + (c - a) * fv)
        return float(d + (c - d) * (1.0 - fu) + (b - d) * (1.0 - fv))

    def span(self, x0, x1, z0, z1):
        """Lowest and highest ground under a footprint: its corners, its
        middle and every grid point inside."""
        pts = [self.at(x, z) for x in (x0, x1, (x0 + x1) * 0.5) for z in (z0, z1, (z0 + z1) * 0.5)]
        i0, i1 = int(math.ceil((x0 - self.x0) / self.cell)), int((x1 - self.x0) / self.cell)
        j0, j1 = int(math.ceil((z0 - self.x0) / self.cell)), int((z1 - self.x0) / self.cell)
        if i1 >= i0 and j1 >= j0:
            inside = self.h[max(j0, 0):j1 + 1, max(i0, 0):i1 + 1]
            if inside.size:
                pts += [float(inside.min()), float(inside.max())]
        return min(pts), max(pts)


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(BUILD, exist_ok=True)
    x, z, h, river, lake, roads, bridges = build_heights()
    h = h.astype(np.float32)
    h.tofile(os.path.join(OUT, "terrain_height.bin"))
    normals(h).astype(np.float32).tofile(os.path.join(OUT, "terrain_normal.bin"))
    nature, town = build_paint(h)
    to_png(nature, os.path.join(OUT, "ground_nature.png"))
    to_png(town, os.path.join(OUT, "ground_town.png"))
    meta = {"x0": X0, "cell": CELL, "n": N, "paint_size": PAINT, "paint_x0": X0,
            "river": river, "lake": lake, "bridges": bridges}
    with open(os.path.join(OUT, "terrain.json"), "w", newline="\n") as fh:
        json.dump(meta, fh, indent=1)
    preview(h, nature, town, river, lake, os.path.join(BUILD, "stage1_terrain.png"))

    # The grade report: the playable square, and downtown on its own.
    gz, gx = np.gradient(h, CELL)
    grade = np.hypot(gx, gz)
    play = (np.abs(x) < HALF) & (np.abs(z) < HALF)
    down = (np.abs(x) < DOWNTOWN) & (np.abs(z) < DOWNTOWN)
    print("heights %.1f .. %.1f m" % (h[play].min(), h[play].max()))
    print("grade: playable max %.0f%% (99th %.0f%%), downtown max %.1f%%" % (
        grade[play].max() * 100, np.percentile(grade[play], 99) * 100, grade[down].max() * 100))
    print("lake water %.1f, river water %.1f .. %.1f" % (lake["water"], river[0][2], river[-1][2]))


if __name__ == "__main__":
    main()

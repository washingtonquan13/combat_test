"""Stage 2 of the Morrow overworld: the road network.

Laid on the land before anything is cut into it (morrow_terrain.base_heights);
stage 1 then grades the ground along what this writes. Seeded, so running it
again writes the same roads.

Downtown is four quarters, each its own street grid at its own angle and
pitch, bounded by the two avenues through the square, the ring road at the
downtown edge and the square's own edge. Out of town the north, south and
east roads run straight on; the quarry road is found by A* over the land,
paying for climbs and for every metre near the river, so it takes the
gentle way and crosses the river square on, where it gets a bridge. Lanes
branch off the roads out and off the ring, feel their way along the
contours, and join the next road they meet.

Writes world/morrow/roads.json:
    roads    [{name, kind, width, points: [[x, z], ...]}], in laying order
    bridges  [{road, x, z, s, yaw, length, width}], s along the road
and a top-down preview to tools/blockout/build/morrow/stage2_roads.png.

    python tools/blockout/morrow_roads.py
    python tools/blockout/morrow_terrain.py      # then grade the ground
"""
import heapq
import json
import math
import os
import sys

import numpy as np
import shapely
from PIL import Image, ImageDraw
from shapely.geometry import LineString, Point, box
from shapely.ops import nearest_points

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from morrow_layout import (DOORS, DOWNTOWN, HALF, LAKE, OUTSKIRTS, QUARRY_CLEARING, RIVER, ROAD,  # noqa: E402
                           SQUARE)
from morrow_terrain import (BUILD, CELL, CHANNEL, N, OUT, X0, base_heights, sample,  # noqa: E402
                            square_radius)

SEED = 23
WIDTH = {"avenue": ROAD, "highway": ROAD, "ring": 16.0, "street": 14.0, "square": 0.0,
         "quarry": 12.0, "lane": 7.0}
SQUARE_EDGE = SQUARE + ROAD * 0.5   # the square's cobbles reach this far

# Downtown's quarters: x sign, z sign, the grid's angle in degrees, its
# pitch and how far it is shifted, in metres.
QUARTERS = [(1, 1, 0.0, 58.0, 26.0), (-1, 1, 12.0, 54.0, 9.0),
            (-1, -1, -8.0, 62.0, 17.0), (1, -1, 20.0, 50.0, 23.0)]
LANE_STEP = 20.0
LANE_CLIMB = 0.14     # steepest step a lane will take


class Network:
    def __init__(self):
        self.roads = []
        self._geom = None

    def add(self, name, kind, pts):
        self.roads.append({"name": name, "kind": kind, "width": WIDTH[kind],
                           "points": [[round(float(x), 2), round(float(z), 2)] for x, z in pts]})
        self._geom = None

    def geom(self):
        if self._geom is None:
            self._geom = shapely.union_all([LineString(r["points"]) for r in self.roads if r["kind"] != "square"])
        return self._geom


# ---------------------------------------------------------------- downtown

def downtown(net):
    e, q = DOWNTOWN, SQUARE_EDGE
    net.add("Square", "square", [(-q, -q), (q, -q), (q, q), (-q, q), (-q, -q)])
    net.add("Ring", "ring", [(-e, -e), (e, -e), (e, e), (-e, e), (-e, -e)])
    net.add("AvenueWest", "avenue", [(-e, 0), (-q, 0)])
    net.add("AvenueEast", "avenue", [(q, 0), (e, 0)])
    net.add("AvenueSouth", "avenue", [(0, -e), (0, -q)])
    net.add("AvenueNorth", "avenue", [(0, q), (0, e)])
    for qi, (sx, sz, angle, pitch, shift) in enumerate(QUARTERS):
        quarter = box(min(0, sx * e), min(0, sz * e), max(0, sx * e), max(0, sz * e)).difference(box(-q, -q, q, q))
        edge = quarter.boundary
        clip = quarter.buffer(1.0, join_style="mitre")
        a = math.radians(angle)
        k = 0
        for fam in (0.0, math.pi * 0.5):
            u = (math.cos(a + fam), math.sin(a + fam))
            n = (-u[1], u[0])
            for i in range(-8, 9):
                o = i * pitch + shift
                c = (n[0] * o, n[1] * o)
                line = LineString([(c[0] - u[0] * 600, c[1] - u[1] * 600), (c[0] + u[0] * 600, c[1] + u[1] * 600)])
                for part in shapely.get_parts(line.intersection(clip)):
                    if part.length < 30.0:
                        continue
                    # Too near the quarter's own edge for most of its run: it
                    # would only make a sliver of a block.
                    probe = [part.interpolate(t, normalized=True) for t in np.linspace(0, 1, 11)]
                    if sum(edge.distance(p) < 22.0 for p in probe) > 5:
                        continue
                    net.add("Street%d_%d" % (qi, k), "street", list(part.coords))
                    k += 1


# ------------------------------------------------------------ out of town

class Land:
    """The land stage 2 builds on, and what a new road must keep clear of."""

    def __init__(self):
        coords = X0 + np.arange(N) * CELL
        x, z = np.meshgrid(coords, coords)
        self.h = base_heights(x, z)
        self.river = LineString(RIVER)

    def height(self, x, z):
        return float(sample(self.h, x, z))

    def clear(self, x, z):
        """Somewhere a lane may go."""
        if abs(x) > HALF - 40.0 or abs(z) > HALF - 40.0:
            return False
        r = float(square_radius(np.float64(x), np.float64(z)))
        if r < DOWNTOWN + 25.0 or r > OUTSKIRTS + 140.0:
            return False
        if self.river.distance(Point(x, z)) < 55.0:
            return False
        if math.hypot(x - LAKE[0], z - LAKE[1]) < LAKE[2] + 35.0:
            return False
        if math.hypot(x - QUARRY_CLEARING[0], z - QUARRY_CLEARING[1]) < 120.0:
            return False
        return all(math.hypot(x - dx, z - dz) > 35.0 for _, _, (dx, dz), _ in DOORS)


def chaikin(pts, rounds):
    pts = [tuple(p) for p in pts]
    for _ in range(rounds):
        out = [pts[0]]
        for (ax, az), (bx, bz) in zip(pts, pts[1:]):
            out.append((ax * 0.75 + bx * 0.25, az * 0.75 + bz * 0.25))
            out.append((ax * 0.25 + bx * 0.75, az * 0.25 + bz * 0.75))
        out.append(pts[-1])
        pts = out
    return pts


def astar(land, start, goal, step=8.0, margin=260.0):
    """Cheapest way over the land: a metre costs more the steeper it climbs,
    and much more near the river, so a road crosses it short and square."""
    xs0 = min(start[0], goal[0]) - margin
    zs0 = min(start[1], goal[1]) - margin
    nx = int((max(start[0], goal[0]) + margin - xs0) / step) + 1
    nz = int((max(start[1], goal[1]) + margin - zs0) / step) + 1
    gx, gz = np.meshgrid(xs0 + np.arange(nx) * step, zs0 + np.arange(nz) * step)
    hh = sample(land.h, gx, gz)
    near_river = shapely.distance(land.river, shapely.points(gx.ravel(), gz.ravel())).reshape(gz.shape)
    river_cost = np.where(near_river < CHANNEL + 30.0, 6.0, 0.0)
    blocked = (np.hypot(gx - LAKE[0], gz - LAKE[1]) < LAKE[2] + 25.0) | (np.abs(gx) > 1020) | (np.abs(gz) > 1020)
    blocked |= square_radius(gx, gz) < DOWNTOWN - 5.0
    moves = [(1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1),
             (2, 1), (1, 2), (-2, 1), (-1, 2), (2, -1), (1, -2), (-2, -1), (-1, -2)]
    moves = [(di, dj, step * math.hypot(di, dj)) for di, dj in moves]

    def cell(p):
        return (int(round((p[1] - zs0) / step)), int(round((p[0] - xs0) / step)))

    s, g = cell(start), cell(goal)
    blocked[s] = blocked[g] = False
    best = {s: 0.0}
    came = {}
    frontier = [(0.0, s)]
    while frontier:
        _, cur = heapq.heappop(frontier)
        if cur == g:
            break
        j, i = cur
        base = best[cur]
        for di, dj, length in moves:
            jj, ii = j + dj, i + di
            if not (0 <= jj < nz and 0 <= ii < nx) or blocked[jj, ii]:
                continue
            grade = abs(hh[jj, ii] - hh[j, i]) / length
            cost = base + length * (1.0 + (grade / 0.05) ** 2 + river_cost[jj, ii])
            if cost < best.get((jj, ii), math.inf):
                best[(jj, ii)] = cost
                came[(jj, ii)] = cur
                left = math.hypot(ii - g[1], jj - g[0]) * step
                heapq.heappush(frontier, (cost + left, (jj, ii)))
    path = [g]
    while path[-1] != s:
        path.append(came[path[-1]])
    path.reverse()
    pts = [(xs0 + i * step, zs0 + j * step) for j, i in path]
    pts[0], pts[-1] = start, goal
    line = LineString(pts).simplify(6.0)
    return chaikin(list(line.coords), 3)


def grow_lane(net, land, rng, start, heading, length):
    """A lane from `start`, a step at a time, keeping to the contours, until
    it has gone `length`, runs out of room, or meets another road."""
    pts = [start]
    x, z = start
    travelled = 0.0
    net_geom = net.geom()
    joined = False
    while travelled < length:
        best = None
        for turn in (-24.0, -12.0, 0.0, 12.0, 24.0):
            hd = heading + math.radians(turn)
            px, pz = x + math.cos(hd) * LANE_STEP, z + math.sin(hd) * LANE_STEP
            if not land.clear(px, pz):
                continue
            climb = abs(land.height(px, pz) - land.height(x, z)) / LANE_STEP
            if climb > LANE_CLIMB:
                continue
            score = climb * 8.0 + abs(turn) / 24.0 * 0.12 + rng.random() * 0.3
            if best is None or score < best[0]:
                best = (score, hd, px, pz)
        if best is None:
            break
        _, heading, px, pz = best
        seg = LineString([(x, z), (px, pz)])
        if travelled > 30.0:
            hit = seg.intersection(net_geom)
            if not hit.is_empty:
                p = min(shapely.get_parts(hit) if hit.geom_type.startswith("Multi") else [hit],
                        key=lambda g: g.distance(Point(x, z)))
                pts.append(nearest_points(p, Point(x, z))[0].coords[0])
                joined = True
                break
            near = net_geom.distance(Point(px, pz))
            if near < 14.0:
                pts.append((px, pz))
                pts.append(nearest_points(net_geom, Point(px, pz))[0].coords[0])
                joined = True
                break
        pts.append((px, pz))
        x, z = px, pz
        travelled += LANE_STEP
    if travelled < 60.0:
        return None
    return chaikin(pts, 2), joined


def tangent(line, s):
    a = line.interpolate(max(s - 2.0, 0.0))
    b = line.interpolate(min(s + 2.0, line.length))
    return math.atan2(b.y - a.y, b.x - a.x)


def outskirts(net, land, rng):
    e = DOWNTOWN
    net.add("EastRoad", "highway", [(e, 0), (1030, 0)])
    net.add("NorthRoad", "highway", [(0, e), (0, 1030)])
    net.add("SouthRoad", "highway", [(0, -e), (0, -1030)])
    to_quarry = astar(land, (-e - 8.0, 0.0), QUARRY_CLEARING)
    on_west = astar(land, QUARRY_CLEARING, (-1020.0, 30.0))
    net.add("QuarryRoad", "quarry", [(-e, 0.0)] + to_quarry + on_west[1:])

    # Lanes off the roads out, both sides, every hundred metres or so.
    seeds = []
    for road in [r for r in net.roads if r["kind"] in ("highway", "quarry")]:
        line = LineString(road["points"])
        s = 40.0
        while s < line.length:
            p = line.interpolate(s)
            r = float(square_radius(np.float64(p.x), np.float64(p.y)))
            if DOWNTOWN + 30.0 < r < OUTSKIRTS + 60.0:
                for side in (-1.0, 1.0):
                    if rng.random() < 0.85:
                        seeds.append((p.coords[0], tangent(line, s) + side * math.pi * 0.5))
            s += rng.uniform(60.0, 90.0)
    # And off the ring, outward, away from where the roads leave it.
    ring = LineString(next(r for r in net.roads if r["kind"] == "ring")["points"])
    s = 30.0
    while s < ring.length:
        p = ring.interpolate(s)
        if min(abs(p.x), abs(p.y)) > 50.0 and rng.random() < 0.7:
            out = math.atan2(p.y, p.x)
            # The ring's outward normal: whichever axis it is furthest along.
            out = (0.0 if p.x > 0 else math.pi) if abs(p.x) >= abs(p.y) else (math.pi * 0.5 if p.y > 0 else -math.pi * 0.5)
            seeds.append((p.coords[0], out))
        s += rng.uniform(70.0, 110.0)
    order = rng.permutation(len(seeds))
    k = 0
    grown = []
    for i in order:
        start, heading = seeds[i]
        heading += math.radians(rng.normal(0.0, 12.0))
        lane = grow_lane(net, land, rng, start, heading, rng.uniform(160.0, 360.0))
        if lane is None:
            continue
        net.add("Lane%d" % k, "lane", lane[0])
        grown.append(lane[0])
        k += 1
    # Branches off the lanes, and off those.
    for pts in grown:
        if rng.random() > 0.7:
            continue
        line = LineString(pts)
        s = line.length * rng.uniform(0.35, 0.65)
        heading = tangent(line, s) + rng.choice([-1.0, 1.0]) * math.pi * 0.5
        lane = grow_lane(net, land, rng, line.interpolate(s).coords[0], heading, rng.uniform(80.0, 170.0))
        if lane is not None:
            net.add("Lane%d" % k, "lane", lane[0])
            grown.append(lane[0])
            k += 1


def bridges(net, land):
    out = []
    for road in net.roads:
        if road["kind"] not in ("quarry", "highway", "lane"):
            continue
        line = LineString(road["points"])
        hit = line.intersection(land.river)
        for p in ([] if hit.is_empty else shapely.get_parts(hit)):
            s = line.project(p)
            yaw = tangent(line, s)
            r_s = land.river.project(p)
            ra = land.river.interpolate(max(r_s - 5.0, 0.0))
            rb = land.river.interpolate(r_s + 5.0)
            cross = abs(math.sin(yaw - math.atan2(rb.y - ra.y, rb.x - ra.x)))
            length = 2.0 * (CHANNEL + 12.0) / max(cross, 0.5) + 8.0
            out.append({"road": road["name"], "x": round(p.x, 2), "z": round(p.y, 2), "s": round(s, 2),
                        "yaw": round(yaw, 4), "length": round(length, 2), "width": road["width"] + 2.0})
    return out


# ----------------------------------------------------------------- preview

COLOURS = {"avenue": (60, 60, 66), "ring": (60, 60, 66), "street": (80, 80, 86), "highway": (60, 60, 66),
           "quarry": (150, 110, 70), "lane": (170, 135, 90), "square": (200, 175, 130)}


def preview(net, land, bridge_list, path):
    size = 1024
    scale = size / 2048.0
    hh = np.asarray(Image.fromarray(land.h.astype(np.float32), "F").resize((size, size), Image.BILINEAR))
    gz, gx = np.gradient(hh, 1.0 / scale)
    light = np.clip(0.75 + (-gx * 0.6 - gz * 0.8) * 1.6, 0.35, 1.3)
    col = np.array([0.42, 0.52, 0.3]) * light[..., None]
    img = Image.fromarray((np.clip(col, 0, 1) * 255).astype(np.uint8), "RGB")
    draw = ImageDraw.Draw(img)

    def px(p):
        return ((p[0] - X0) * scale, (p[1] - X0) * scale)

    draw.line([px(p) for p in RIVER], fill=(60, 95, 120), width=int(CHANNEL * 2 * scale))
    lx, lz = px(LAKE[:2])
    lr = LAKE[2] * scale
    draw.ellipse([lx - lr, lz - lr, lx + lr, lz + lr], fill=(60, 95, 120))
    for road in net.roads:
        w = max(1, int(round(road["width"] * scale))) if road["kind"] != "square" else 1
        draw.line([px(p) for p in road["points"]], fill=COLOURS[road["kind"]], width=w)
    for b in bridge_list:
        dx, dz = math.cos(b["yaw"]) * b["length"] * 0.5, math.sin(b["yaw"]) * b["length"] * 0.5
        draw.line([px((b["x"] - dx, b["z"] - dz)), px((b["x"] + dx, b["z"] + dz))], fill=(120, 70, 40),
                  width=max(2, int(b["width"] * scale)))
    for _, _, d, _ in DOORS:
        x, z = px(d)
        draw.ellipse([x - 4, z - 4, x + 4, z + 4], outline=(240, 220, 90), width=2)
    a, b = px((-HALF, -HALF)), px((HALF, HALF))
    draw.rectangle([a, b], outline=(200, 40, 40))
    img.save(path)


def main():
    rng = np.random.default_rng(SEED)
    land = Land()
    net = Network()
    downtown(net)
    outskirts(net, land, rng)
    bridge_list = bridges(net, land)
    with open(os.path.join(OUT, "roads.json"), "w", newline="\n") as fh:
        json.dump({"roads": net.roads, "bridges": bridge_list}, fh, indent=1)
    os.makedirs(BUILD, exist_ok=True)
    preview(net, land, bridge_list, os.path.join(BUILD, "stage2_roads.png"))
    kinds = {}
    for r in net.roads:
        kinds.setdefault(r["kind"], []).append(LineString(r["points"]).length)
    for kind, lengths in kinds.items():
        print("%-8s %3d  %6.0f m" % (kind, len(lengths), sum(lengths)))
    print("bridges", [(b["road"], b["x"], b["z"], b["length"]) for b in bridge_list])


if __name__ == "__main__":
    main()

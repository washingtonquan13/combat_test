"""Stage 3 of the Morrow overworld: the lots and the buildings on them.

Reads stage 2's roads (world/morrow/roads.json) and stage 1's graded ground
(terrain.json and its heights), so run both first. Seeded, so running it
again writes the same town.

Downtown, the blocks are what the roads leave of the ground inside the ring,
less a pavement either side of every road. Each block is cut in two across
its longest side, and the halves cut again, until the pieces are lot-sized;
a piece with no side on a street is a back yard left open, or half the
time a lower building behind the ones in front. Two blocks
are kept as parks, and the square, the door clearings and the inn's corner
stay open too. Buildings fill their lots, taller towards the square.

Out of town, houses stand along the lanes and the roads out, either side,
set back from the road and turned to face it, and only where the ground
under them is near level and nothing else is in the way.

Every building is a footprint, the ground it stands on and a number of
storeys (a 4.5 m ground floor, 3.5 m above that; the facade's bays are 3 m),
with the edge that faces the street marked, so a later pass can put the
doors and shop fronts there. MorrowCity (world/morrow/morrow_city.gd) builds
them on load.

Writes world/morrow/city.json:
    buildings  [{points: [[x, z], ...] anticlockwise seen from above, front,
                 base, floor, storeys, roof, style, district}]
                 front: index i of the street edge points[i] -> points[i+1]
                 base: below the lowest ground under it; floor: the highest
                 roof: "flat" or "gable" (a gable runs along the front)
    parks      [[[x, z], ...]]
and a top-down preview to tools/blockout/build/morrow/stage3_city.png.

    python tools/blockout/morrow_roads.py
    python tools/blockout/morrow_terrain.py
    python tools/blockout/morrow_city.py
"""
import json
import math
import os
import sys

import numpy as np
import shapely
from PIL import Image, ImageDraw
from shapely.geometry import LineString, Point, Polygon, box
from shapely.geometry.polygon import orient

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from morrow_layout import (DOORS, DOWNTOWN, HALF, INN_HOUSE, LAKE, OUTSKIRTS, QUARRY_CLEARING, RIVER,  # noqa: E402
                           SAFE_SPOT, SQUARE, ROAD)
from morrow_terrain import BUILD, OUT, X0, Terrain, square_radius  # noqa: E402

SEED = 31
GROUND_FLOOR = 4.5
STOREY = 3.5
PAVEMENT = 3.0          # either side of a downtown road
SQUARE_EDGE = SQUARE + ROAD * 0.5
DOOR_CLEAR = 30.0       # open ground round a door
STYLES_DOWNTOWN = ["brick", "brick_dark", "plaster", "stone"]
STYLES_HOUSE = ["plaster", "brick", "plaster_warm"]

ground = Terrain()


def load_roads():
    with open(os.path.join(OUT, "roads.json")) as fh:
        return json.load(fh)


def road_buffers(roads, extra, kinds=None):
    parts = [LineString(r["points"]).buffer(r["width"] * 0.5 + extra, cap_style="flat" if r["kind"] == "lane"
                                            else "round")
             for r in roads if r["kind"] != "square" and (kinds is None or r["kind"] in kinds)]
    return shapely.union_all(parts)


def standing(poly):
    """The lowest and highest ground under a footprint: its corners, edge
    middles, centre and a grid inside."""
    x0, z0, x1, z1 = poly.bounds
    pts = list(poly.exterior.coords)[:-1]
    pts += [((a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5) for a, b in zip(pts, pts[1:] + pts[:1])]
    pts.append(tuple(poly.centroid.coords[0]))
    for x in np.arange(x0, x1, 4.0):
        for z in np.arange(z0, z1, 4.0):
            if poly.contains(Point(x, z)):
                pts.append((x, z))
    hs = [ground.at(x, z) for x, z in pts]
    return min(hs), max(hs)


def front_edge(poly, street):
    """The edge of poly lying longest along street (a line or area)."""
    coords = list(poly.exterior.coords)
    best, best_len = 0, -1.0
    for i in range(len(coords) - 1):
        seg = LineString([coords[i], coords[i + 1]])
        on = seg.intersection(street).length if street.geom_type != "Point" else 0.0
        if on > best_len:
            best, best_len = i, on
    return best, best_len


# ---------------------------------------------------------------- downtown

def split(poly, target, rng, depth=0):
    """Cut across the longest side of the bounding box until lot-sized."""
    if poly.area <= target * rng.uniform(0.75, 1.3) or depth > 8:
        return [poly]
    c = list(poly.minimum_rotated_rectangle.exterior.coords)[:4]
    e0 = np.subtract(c[1], c[0])
    e1 = np.subtract(c[3], c[0])
    if np.hypot(*e0) < np.hypot(*e1):
        e0, e1 = e1, e0
        c = [c[0], c[3], c[2], c[1]]
    t = rng.uniform(0.38, 0.62)
    a = np.array(c[0]) + e0 * t
    b = a + e1
    halves = [Polygon([c[0], tuple(a), tuple(b), c[3]]), Polygon([tuple(a), c[1], c[2], tuple(b)])]
    out = []
    for half in halves:
        piece = poly.intersection(half.buffer(0.01, join_style="mitre"))
        for p in shapely.get_parts(piece):
            if p.geom_type == "Polygon" and p.area > 40.0:
                out += split(p, target, rng, depth + 1)
    return out


def thin(poly, least):
    c = list(poly.minimum_rotated_rectangle.exterior.coords)
    return min(math.dist(c[0], c[1]), math.dist(c[1], c[2])) < least


def downtown(roads, rng, reserved):
    inside = box(-DOWNTOWN, -DOWNTOWN, DOWNTOWN, DOWNTOWN)
    streets = road_buffers(roads, PAVEMENT, {"avenue", "ring", "street"})
    square = box(-SQUARE_EDGE - PAVEMENT, -SQUARE_EDGE - PAVEMENT, SQUARE_EDGE + PAVEMENT, SQUARE_EDGE + PAVEMENT)
    blocks = [b for b in shapely.get_parts(inside.difference(streets).difference(square))
              if b.geom_type == "Polygon" and b.area > 300.0]
    blocks.sort(key=lambda b: (round(b.centroid.x, 1), round(b.centroid.y, 1)))

    # Two parks, from the middling blocks away from the square.
    middling = [i for i, b in enumerate(blocks) if 2500.0 < b.area < 6000.0 and
                float(square_radius(np.float64(b.centroid.x), np.float64(b.centroid.y))) > 130.0]
    park_ids = set(rng.choice(middling, size=min(2, len(middling)), replace=False).tolist())
    parks = [blocks[i] for i in sorted(park_ids)]

    out = []
    for i, block in enumerate(blocks):
        if i in park_ids:
            continue
        cx, cz = block.centroid.x, block.centroid.y
        centre = 1.0 - float(square_radius(np.float64(cx), np.float64(cz))) / DOWNTOWN
        target = rng.uniform(380.0, 700.0) + centre * 500.0
        rim = block.exterior.buffer(0.6)
        quarter = (cx > 0) * 1 + (cz > 0) * 2
        for lot in split(block, target, rng):
            # No side on a street: half are back yards left open, half a
            # lower building behind the ones in front.
            behind = lot.intersection(rim).area < 6.0 * 1.2
            if behind and rng.random() < 0.5:
                continue
            foot = lot.buffer(-0.35, join_style="mitre").simplify(0.4)
            if foot.is_empty or foot.geom_type != "Polygon" or foot.area < 70.0 or thin(foot, 5.0):
                continue
            if foot.intersects(reserved):
                continue
            foot = orient(foot, 1.0)
            front, on = front_edge(foot, rim)
            storeys = 2 + int(round(centre * rng.uniform(2.0, 8.0))) + int(rng.random() < 0.25)
            if behind:
                storeys = max(1, storeys - 2)
            style = STYLES_DOWNTOWN[(quarter + int(rng.random() < 0.35) * int(rng.integers(1, 4))) % 4]
            out.append(building(foot, front, storeys, "flat", style, "downtown"))
    return out, parks


# ------------------------------------------------------------ out of town

def house_clear(x, z):
    r = float(square_radius(np.float64(x), np.float64(z)))
    if r < DOWNTOWN + 14.0 or r > OUTSKIRTS + 150.0 or max(abs(x), abs(z)) > HALF - 50.0:
        return False
    if LineString(RIVER).distance(Point(x, z)) < 50.0:
        return False
    if math.hypot(x - LAKE[0], z - LAKE[1]) < LAKE[2] + 25.0:
        return False
    if math.hypot(x - QUARRY_CLEARING[0], z - QUARRY_CLEARING[1]) < 120.0:
        return False
    return True


def outskirts(roads, rng, reserved):
    keep_off = road_buffers(roads, 2.5)
    taken = []
    out = []
    for road in roads:
        if road["kind"] not in ("lane", "highway", "quarry"):
            continue
        line = LineString(road["points"])
        s = rng.uniform(5.0, 25.0)
        while s < line.length - 6.0:
            p0, p1 = line.interpolate(max(s - 2.0, 0.0)), line.interpolate(min(s + 2.0, line.length))
            u = np.array([p1.x - p0.x, p1.y - p0.y])
            u /= max(np.hypot(*u), 1e-6)
            n = np.array([-u[1], u[0]])
            p = line.interpolate(s)
            r = float(square_radius(np.float64(p.x), np.float64(p.y)))
            near_town = 1.0 - min(max((r - DOWNTOWN) / (OUTSKIRTS - DOWNTOWN), 0.0), 1.0)
            for side in (-1.0, 1.0):
                if rng.random() > 0.35 + 0.45 * near_town:
                    continue
                w, d = rng.uniform(9.0, 15.0), rng.uniform(8.0, 12.0)
                back = road["width"] * 0.5 + rng.uniform(4.0, 8.0)
                mid = np.array([p.x, p.y]) + n * side * (back + d * 0.5)
                if not house_clear(*mid):
                    continue
                corners = [mid + u * a * w * 0.5 + n * side * b * d * 0.5
                           for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
                foot = orient(Polygon([tuple(c) for c in corners]), 1.0)
                if foot.intersects(keep_off) or foot.intersects(reserved):
                    continue
                pad = foot.buffer(5.0)
                if any(pad.intersects(t) for t in taken[-400:]):
                    continue
                lo, hi = standing(foot)
                if hi - lo > 2.5:
                    continue
                taken.append(foot)
                front, _ = front_edge(foot, line.buffer(road["width"] * 0.5 + back))
                storeys = 1 + int(rng.random() < 0.45 + 0.3 * near_town)
                style = STYLES_HOUSE[int(rng.integers(0, len(STYLES_HOUSE)))]
                out.append(building(foot, front, storeys, "gable", style, "outskirts", (lo, hi)))
            s += rng.uniform(20.0, 34.0)
    return out


def building(foot, front, storeys, roof, style, district, span=None):
    lo, hi = span if span else standing(foot)
    pts = [[round(x, 2), round(z, 2)] for x, z in list(foot.exterior.coords)[:-1]]
    return {"points": pts, "front": int(front), "base": round(lo - 0.6, 2), "floor": round(hi + 0.1, 2),
            "storeys": int(storeys), "roof": roof, "style": style, "district": district}


def reserved_ground():
    keep = [box(-SQUARE_EDGE, -SQUARE_EDGE, SQUARE_EDGE, SQUARE_EDGE)]
    keep += [Point(d).buffer(DOOR_CLEAR) for _, _, d, _ in DOORS]
    ix, iz = SAFE_SPOT[0] + INN_HOUSE[0], SAFE_SPOT[1] + INN_HOUSE[1]
    keep.append(box(ix - 14, iz - 12, ix + 14, iz + 12))
    return shapely.union_all(keep)


# ---------------------------------------------------------------- preview

def preview(roads, buildings, parks, path):
    size = 2048
    img = Image.new("RGB", (size, size), (96, 112, 78))
    draw = ImageDraw.Draw(img)

    def px(p):
        return ((p[0] - X0), (p[1] - X0))

    draw.line([px(p) for p in RIVER], fill=(60, 95, 120), width=20)
    lx, lz = px(LAKE[:2])
    draw.ellipse([lx - LAKE[2], lz - LAKE[2], lx + LAKE[2], lz + LAKE[2]], fill=(60, 95, 120))
    for road in roads:
        if road["kind"] == "square":
            draw.polygon([px(p) for p in road["points"]], fill=(190, 170, 130))
            continue
        col = (150, 120, 85) if road["kind"] in ("lane", "quarry") else (70, 70, 76)
        draw.line([px(p) for p in road["points"]], fill=col, width=max(1, int(road["width"])))
    for park in parks:
        draw.polygon([px(p) for p in park.exterior.coords], fill=(70, 120, 60))
    for b in buildings:
        t = min(b["storeys"] / 9.0, 1.0)
        col = (int(200 - 90 * t), int(180 - 90 * t), int(160 - 70 * t)) if b["district"] == "downtown" \
            else (180, 110, 80)
        draw.polygon([px(p) for p in b["points"]], fill=col, outline=(40, 40, 40))
        i = b["front"]
        a, c = b["points"][i], b["points"][(i + 1) % len(b["points"])]
        draw.line([px(a), px(c)], fill=(240, 220, 90), width=2)
    for _, _, d, _ in DOORS:
        x, z = px(d)
        draw.ellipse([x - 8, z - 8, x + 8, z + 8], outline=(240, 220, 90), width=3)
    img.save(path)
    # A close-up of downtown, where the lots are too small to read whole.
    c = px((0, 0))
    img.crop((int(c[0] - 300), int(c[1] - 300), int(c[0] + 300), int(c[1] + 300))).save(
        path.replace(".png", "_downtown.png"))
    img.resize((1024, 1024), Image.LANCZOS).save(path)


def main():
    rng = np.random.default_rng(SEED)
    data = load_roads()
    roads = data["roads"]
    reserved = reserved_ground()
    town, parks = downtown(roads, rng, reserved)
    houses = outskirts(roads, rng, reserved)
    every = town + houses
    with open(os.path.join(OUT, "city.json"), "w", newline="\n") as fh:
        json.dump({"ground_floor": GROUND_FLOOR, "storey": STOREY, "buildings": every,
                   "parks": [[[round(x, 2), round(z, 2)] for x, z in list(p.exterior.coords)[:-1]] for p in parks]},
                  fh, separators=(",", ":"))
    os.makedirs(BUILD, exist_ok=True)
    preview(roads, every, parks, os.path.join(BUILD, "stage3_city.png"))
    st = [b["storeys"] for b in town]
    print("downtown %d buildings, storeys %d..%d (mean %.1f), %d parks" % (len(town), min(st), max(st),
                                                                        sum(st) / len(st), len(parks)))
    print("outskirts %d houses" % len(houses))


if __name__ == "__main__":
    main()

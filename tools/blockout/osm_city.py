"""Turns a city-sized OpenStreetMap extract into a stylised overworld: building
footprints merged into block masses, a ground colour map, and impassable water.
build_osm_city.gd then turns the result into a scene.

    python -I tools/blockout/osm_city.py <raw dir> <out dir> --bbox S,W,N,E         --water-seeds LAT,LON;LAT,LON

<raw dir> is what fetch_osm_city.py writes: any number of bld_*.json with
buildings, and features.json with water, roads, green space and rail.

The bbox cuts big water open (a river crossing the map, a lake past its
edge), leaving no ring to fill. --water-seeds names one point inside each
such body; its shorelines become walls and the seed floods its side.

Everything is rasterised at CELL metres (real scale) rather than kept as
polygons. A city has far too many buildings for one node each, and an
overworld wants blocks, not buildings: closing the building mask merges
the houses of one block, and cutting the streets back out keeps the blocks
apart. The block masses are then meshed as flat-topped columns per tile.

Writes into <out dir>:
  ground.png       one pixel per cell, coloured by what the ground is
  tiles/t_X_Z.bin  block masses of one tile, in real metres
  tiles/w_X_Z.bin  the water of one tile, extruded, for collision only
  city.json        grid size, cell, origin, tiles

A tile file is an int32 quad count, then four float32 xyz corners per quad
(counter-clockwise seen from outside), then one uint8 normal per quad:
0 up, 1 north (-z), 2 south (+z), 3 west (-x), 4 east (+x).

Coordinates: x is east, z is south, metres from the bbox centre, the same
frame as osm_to_local.py. Map data (c) OpenStreetMap contributors, ODbL.
"""
import argparse
import glob
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

CELL = 4.0
TILE = 256  # cells per tile side
## Houses without a height tag. Most of the city is one- and two-storey.
DEFAULT_HEIGHT = 7.0
LEVEL_HEIGHT = 3.4
## Heights are rounded to this so a block reads as a few flat plateaus
## instead of every roofline.
HEIGHT_STEP = 4.0
## Buildings closer than about this merge into one mass.
MERGE_CELLS = 5
WATER_WALL = 3.0

ROAD_WIDTHS = {
    "motorway": 26.0, "trunk": 22.0, "primary": 18.0, "secondary": 16.0, "tertiary": 14.0,
    "motorway_link": 10.0, "trunk_link": 10.0, "primary_link": 10.0,
    "residential": 11.0, "unclassified": 11.0, "living_street": 9.0, "pedestrian": 9.0,
    "service": 0.0,
}
GREEN = {("leisure", "park"), ("leisure", "golf_course"), ("leisure", "pitch"),
         ("landuse", "grass"), ("landuse", "meadow"), ("landuse", "recreation_ground"),
         ("landuse", "forest"), ("natural", "wood"), ("natural", "scrub")}
WETLAND = {("natural", "wetland")}
CEMETERY = {("landuse", "cemetery")}

# Ground classes and their colours in ground.png.
GROUND, ROAD, MAJOR, PARK, MARSH, GRAVES, WATER, RAIL = range(8)
PALETTE = {
    GROUND: (178, 168, 150), ROAD: (122, 120, 118), MAJOR: (96, 94, 96),
    PARK: (112, 140, 92), MARSH: (100, 120, 96), GRAVES: (170, 170, 160),
    WATER: (64, 92, 112), RAIL: (110, 100, 92),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("out")
    ap.add_argument("--bbox", required=True)
    ap.add_argument("--water-seeds", default="",
                    help="lat,lon;lat,lon points inside water bodies the bbox cuts open")
    args = ap.parse_args()
    s, w, n, e = (float(v) for v in args.bbox.split(","))
    lat0, lon0 = (s + n) / 2, (w + e) / 2
    m_lat = 111_320.0
    m_lon = 111_320.0 * math.cos(math.radians(lat0))
    half_x = (e - w) / 2 * m_lon
    half_z = (n - s) / 2 * m_lat
    cols = int(math.ceil(2 * half_x / CELL / TILE)) * TILE
    rows = int(math.ceil(2 * half_z / CELL / TILE)) * TILE

    def px(g):
        """Lat/lon to raster pixel coordinates."""
        return ((g["lon"] - lon0) * m_lon + half_x) / CELL, (-(g["lat"] - lat0) * m_lat + half_z) / CELL

    def ring_px(geom):
        return [px(g) for g in geom if g]

    # --- Buildings ---------------------------------------------------------
    heights = Image.new("I", (cols, rows), 0)
    hdraw = ImageDraw.Draw(heights)
    count = 0
    for path in sorted(glob.glob(os.path.join(args.raw, "bld_*.json"))):
        for el in json.load(open(path, encoding="utf-8"))["elements"]:
            if el["type"] != "way" or "geometry" not in el:
                continue
            ring = ring_px(el["geometry"])
            if len(ring) < 3:
                continue
            h = _height(el.get("tags", {}))
            hdraw.polygon(ring, fill=int(round(h)))
            count += 1
    print("buildings", count)
    h = np.array(heights, dtype=np.float32)

    # --- Ground ------------------------------------------------------------
    feats = json.load(open(os.path.join(args.raw, "features.json"), encoding="utf-8"))["elements"]
    ground = Image.new("L", (cols, rows), GROUND)
    gdraw = ImageDraw.Draw(ground)
    water_rings, green_rings, marsh_rings, grave_rings = [], [], [], []
    roads, rails, canals = [], [], []
    shores = []
    for el in feats:
        tags = el.get("tags", {})
        if el["type"] == "relation":
            outers = [m["geometry"] for m in el.get("members", []) if m.get("role") == "outer" and "geometry" in m]
            inners = [m["geometry"] for m in el.get("members", []) if m.get("role") == "inner" and "geometry" in m]
            outer_rings, cut = _join(outers)
            polys = [(r, False) for r in outer_rings] + [(r, True) for r in _join(inners)[0]]
            if tags.get("natural") == "water" or tags.get("waterway") == "riverbank":
                shores.extend(cut)
            else:
                polys += [(c, False) for c in cut if len(c) > 2]
        elif "geometry" in el:
            geom = el["geometry"]
            closed = len(geom) > 2 and geom[0] == geom[-1]
            polys = [(geom, False)] if closed else []
            if not closed:
                if tags.get("highway") in ROAD_WIDTHS:
                    roads.append((geom, tags["highway"]))
                elif tags.get("railway") == "rail":
                    rails.append(geom)
                elif tags.get("waterway") in ("canal", "river"):
                    canals.append((geom, tags.get("width")))
                continue
        else:
            continue
        kind = None
        if tags.get("natural") == "water" or tags.get("waterway") == "riverbank":
            kind = water_rings
        elif any((k, tags.get(k)) in GREEN for k in ("leisure", "landuse", "natural")):
            kind = green_rings
        elif any((k, tags.get(k)) in WETLAND for k in ("natural",)):
            kind = marsh_rings
        elif any((k, tags.get(k)) in CEMETERY for k in ("landuse",)):
            kind = grave_rings
        elif tags.get("highway") in ROAD_WIDTHS and tags.get("area") != "yes":
            roads.append((el["geometry"], tags["highway"]))
            continue
        if kind is not None:
            kind.extend(polys)

    def fill(rings, value):
        for geom, hole in rings:
            ring = ring_px(geom)
            if len(ring) >= 3 and not hole:
                gdraw.polygon(ring, fill=value)
        for geom, hole in rings:
            ring = ring_px(geom)
            if len(ring) >= 3 and hole:
                gdraw.polygon(ring, fill=GROUND)

    fill(marsh_rings, MARSH)
    fill(green_rings, PARK)
    fill(grave_rings, GRAVES)
    for geom in rails:
        gdraw.line(ring_px(geom), fill=RAIL, width=max(1, int(8 / CELL)))
    for geom, kind in roads:
        width = ROAD_WIDTHS[kind]
        if width <= 0:
            continue
        major = kind not in ("residential", "unclassified", "living_street", "pedestrian")
        gdraw.line(ring_px(geom), fill=MAJOR if major else ROAD, width=max(1, int(round(width / CELL))), joint="curve")
    fill(water_rings, WATER)
    # Water the bbox cuts open has no ring to fill. Its shorelines become
    # walls, the map edge closes them, and each seed floods its own side.
    if args.water_seeds:
        barrier = Image.new("L", (cols, rows), 0)
        bdraw = ImageDraw.Draw(barrier)
        for chain in shores:
            if len(chain) > 1:
                bdraw.line(ring_px(chain), fill=1, width=2)
        for seed in args.water_seeds.split(";"):
            lat, lon = (float(v) for v in seed.split(","))
            x, y = px({"lat": lat, "lon": lon})
            if barrier.getpixel((int(x), int(y))) == 0:
                ImageDraw.floodfill(barrier, (int(x), int(y)), 2, border=1)
        flooded = np.array(barrier) > 0
        print("flooded water cells", int(flooded.sum()))
        ground = Image.fromarray(np.where(flooded, WATER, np.array(ground)).astype(np.uint8), "L")
        gdraw = ImageDraw.Draw(ground)
    for geom, width in canals:
        try:
            wm = float(str(width).split()[0])
        except ValueError:
            wm = 24.0
        gdraw.line(ring_px(geom), fill=WATER, width=max(2, int(round(wm / CELL))), joint="curve")
    g = np.array(ground, dtype=np.uint8)

    # --- Block masses ------------------------------------------------------
    built = Image.fromarray(((h > 0) * 255).astype(np.uint8))
    size = MERGE_CELLS | 1
    closed = built.filter(ImageFilter.MaxFilter(size)).filter(ImageFilter.MinFilter(size))
    # Open away specks a single shed would leave on a lawn.
    closed = closed.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))
    mass = np.array(closed) > 0
    open_ground = np.isin(g, (ROAD, MAJOR, WATER, RAIL))
    mass &= ~open_ground
    # A mass is as tall as the tallest building near it, in steps.
    hmax = np.array(Image.fromarray(np.clip(h, 0, 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(size + 2)), dtype=np.float32)
    block_h = np.where(mass, np.maximum(HEIGHT_STEP, np.round(hmax / HEIGHT_STEP) * HEIGHT_STEP), 0.0)

    # --- Write -------------------------------------------------------------
    os.makedirs(os.path.join(args.out, "tiles"), exist_ok=True)
    rgb = np.zeros((rows, cols, 3), dtype=np.uint8)
    for k, c in PALETTE.items():
        rgb[g == k] = c
    Image.fromarray(rgb).save(os.path.join(args.out, "ground.png"), optimize=True)
    water_h = np.where(g == WATER, WATER_WALL, 0.0)

    ox, oz = -half_x, -half_z
    tiles = []
    quads_total = 0
    for tz in range(rows // TILE):
        for tx in range(cols // TILE):
            sl = (slice(tz * TILE, (tz + 1) * TILE), slice(tx * TILE, (tx + 1) * TILE))
            x0, z0 = ox + tx * TILE * CELL, oz + tz * TILE * CELL
            entry = {"x": tx, "z": tz}
            q = _write_tile(os.path.join(args.out, "tiles", "t_%d_%d.bin" % (tx, tz)), block_h[sl], x0, z0)
            if q:
                entry["blocks"] = "t_%d_%d.bin" % (tx, tz)
                quads_total += q
            if _write_tile(os.path.join(args.out, "tiles", "w_%d_%d.bin" % (tx, tz)), water_h[sl], x0, z0):
                entry["water"] = "w_%d_%d.bin" % (tx, tz)
            if len(entry) > 2:
                tiles.append(entry)
    meta = {
        "attribution": "Map data (c) OpenStreetMap contributors, ODbL 1.0. https://www.openstreetmap.org/copyright",
        "bbox": [s, w, n, e], "origin": [lat0, lon0], "cell": CELL, "tile": TILE,
        "size": [cols, rows], "corner": [ox, oz], "tiles": tiles,
    }
    with open(os.path.join(args.out, "city.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent=1)
    print("grid %dx%d cells, %d tiles, %d quads" % (cols, rows, len(tiles), quads_total))


def _height(tags):
    try:
        return float(tags["height"].split()[0])
    except (KeyError, ValueError):
        pass
    try:
        return float(tags["building:levels"]) * LEVEL_HEIGHT + 1.0
    except (KeyError, ValueError):
        return DEFAULT_HEIGHT


def _join(chains):
    """Multipolygon rings arrive split over member ways; join them end to end.

    Geometry clipped to the bbox has None where a way leaves it, so each
    way is first split into the runs inside. Returns the closed rings and
    the chains that could not be closed because the bbox cut them.
    """
    runs = []
    for c in chains:
        run = []
        for p in c or []:
            if p:
                run.append(p)
            elif run:
                runs.append(run)
                run = []
        if run:
            runs.append(run)
    chains = runs
    rings, cut = [], []
    while chains:
        ring = chains.pop(0)
        changed = True
        while ring[0] != ring[-1] and changed:
            changed = False
            for c in chains:
                if c[0] == ring[-1]:
                    ring += c[1:]
                elif c[-1] == ring[-1]:
                    ring += c[-2::-1]
                elif c[-1] == ring[0]:
                    ring = c[:-1] + ring
                elif c[0] == ring[0]:
                    ring = c[:0:-1] + ring
                else:
                    continue
                chains.remove(c)
                changed = True
                break
        (rings if len(ring) > 3 and ring[0] == ring[-1] else cut).append(ring)
    return rings, cut


def _runs(mask_row):
    """(start, end) of each run of True in a 1D bool array."""
    d = np.diff(np.concatenate(([0], mask_row.astype(np.int8), [0])))
    return np.flatnonzero(d == 1), np.flatnonzero(d == -1)


def _write_tile(path, hm, x0, z0):
    """Meshes a height grid as flat-topped columns: one quad per merged
    rectangle of equal height on top, one per run of equal step on the sides.
    Returns the quad count, and writes nothing for an empty grid."""
    if not hm.any():
        if os.path.exists(path):
            os.remove(path)
        return 0
    rows, cols = hm.shape
    quads = []  # (4 corners, normal index)

    # Tops: runs per row, merged downward while the run below matches.
    open_runs = {}
    tops = []
    for r in range(rows + 1):
        cur = {}
        if r < rows:
            row = hm[r]
            for hv in np.unique(row[row > 0]):
                a, b = _runs(row == hv)
                for s_, e_ in zip(a, b):
                    cur[(int(s_), int(e_), float(hv))] = r
        for key, start in open_runs.items():
            if key in cur:
                cur[key] = start
            else:
                tops.append((start, r) + key)
        open_runs = cur
    for r0, r1, c0, c1, hv in tops:
        quads.append((((c0, hv, r0), (c0, hv, r1), (c1, hv, r1), (c1, hv, r0)), 0))

    # Sides between rows (faces looking north or south).
    pad = np.pad(hm, 1)
    for r in range(rows + 1):
        above, below = pad[r, 1:-1], pad[r + 1, 1:-1]
        _sides(quads, above, below, lambda c, y, r=r: (c, y, r), 1, 2, False)
    # Sides between columns (faces looking west or east).
    for c in range(cols + 1):
        left, right = pad[1:-1, c], pad[1:-1, c + 1]
        _sides(quads, left, right, lambda rr, y, c=c: (c, y, rr), 3, 4, True)

    pos = np.empty((len(quads), 4, 3), dtype=np.float32)
    nrm = np.empty(len(quads), dtype=np.uint8)
    for k, (corners, ni) in enumerate(quads):
        pos[k] = [(x0 + cx * CELL, y, z0 + cz * CELL) for cx, y, cz in corners]
        nrm[k] = ni
    with open(path, "wb") as f:
        f.write(np.int32(len(quads)).tobytes())
        f.write(pos.tobytes())
        f.write(nrm.tobytes())
    return len(quads)


def _sides(quads, a, b, corner, n_neg, n_pos, mirrored):
    """Wall quads along one grid line between strips a and b. Where a is
    taller the wall faces b's way, and the other way round. Winding is
    counter-clockwise seen from the side the normal points to; along a
    column line the corner order runs the mirrored way, so it flips."""
    diff = a != b
    if not diff.any():
        return
    lo = np.minimum(a, b)
    hi = np.maximum(a, b)
    facing_b = a > b
    i = 0
    n = len(a)
    while i < n:
        if not diff[i]:
            i += 1
            continue
        j = i + 1
        while j < n and diff[j] and lo[j] == lo[i] and hi[j] == hi[i] and facing_b[j] == facing_b[i]:
            j += 1
        y0, y1 = float(lo[i]), float(hi[i])
        p = [corner(i, y0), corner(j, y0), corner(j, y1), corner(i, y1)]
        # n_pos is the direction from a toward b.
        if facing_b[i] != mirrored:
            quads.append((tuple(p), n_pos if facing_b[i] else n_neg))
        else:
            quads.append((tuple(reversed(p)), n_pos if facing_b[i] else n_neg))
        i = j


if __name__ == "__main__":
    main()

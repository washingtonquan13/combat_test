"""Turns a city-sized OpenStreetMap extract into a stylised overworld: building
footprints merged into block masses with their taller buildings rising out
of them, ground meshes coloured by what the ground is, and impassable
water. build_osm_city.gd then turns the result into a scene.

    python -I tools/blockout/osm_city.py <raw dir> <out dir> [--bbox S,W,N,E] \
        --water-seeds LAT,LON;LAT,LON

<raw dir> is what fetch_osm_city.py writes: any number of bld_*.json with
buildings, features.json with water, roads, green space and rail, and
optionally coast.json with the coastline and boundary.json with the city's
boundary.

With a boundary.json the map is the city: everything is clipped to its
outline, and the bbox, if not given, is the outline's. Without one the map
is the bbox.

The map's edge cuts big water open (a river crossing the map, a lake past
it, the sea, which OSM maps only as coastline), leaving no ring to fill.
--water-seeds names one point inside each such body; its shorelines, run
out to the map edge, cut the map into pieces, and the piece holding the
seed is water.

Everything stays a polygon, so edges keep their real angles. A city has far
too many buildings for one node each, and an overworld wants blocks, not
buildings: closing the union of the footprints merges the houses of one
block, and cutting the streets back out keeps the blocks apart. Heights are
stepped: the mass of each step is every footprint at least that tall,
closed, and kept inside the step below, so a block is one prism with its
tall buildings standing on it as prisms of their own. Low steps close wide
enough to merge a row of houses; high ones only a little, so towers keep
their shapes.

Writes into <out dir>:
  tiles/b_X_Z.bin  buildings of one tile, in real metres
  tiles/g_X_Z.bin  the ground of one tile, flat at y 0, every class
  tiles/w_X_Z.bin  the water of one tile, extruded, for collision only
  tiles/d_X_Z.bin  bridge decks and their ramps, from bridges.py
  city.json        extent, tile size, origin, tiles, and the boundary's
                   rings in metres

A tile file is an int32 triangle count, then three float32 xyz corners per
triangle (counter-clockwise seen from outside, so the normal is
(b - a) x (c - a)), then one uint8 kind per triangle, then one uint8 tint
per triangle. Kinds: building wall 0 and roof 1; ground the classes below.
The tint is a per-building random byte, for varying the palette.

Coordinates: x is east, z is south, metres from the bbox centre, the same
frame as osm_to_local.py. Map data (c) OpenStreetMap contributors, ODbL.
"""
import argparse
import glob
import json
import math
import os
import subprocess
import sys
import time
import zlib

import numpy as np
import shapely
import shapely.ops
from shapely.geometry import LineString, Point, Polygon, box

TILE = 1024.0  # metres per tile side
## Houses without a height tag. Most of the city is one- and two-storey.
DEFAULT_HEIGHT = 7.0
LEVEL_HEIGHT = 3.4
## Heights are rounded to this so a block reads as a few flat plateaus
## instead of every roofline.
HEIGHT_STEP = 4.0
## Footprints closer than twice this merge into one mass, up to LOW_RISE.
MERGE = 8.0
LOW_RISE = 12.0
## Above LOW_RISE only near-touching buildings merge.
TOWER_MERGE = 2.0
## Kept clear between a block and the street, and the smallest piece kept.
SIDEWALK = 1.5
MIN_AREA = 60.0
FILL_DENSITY = 0.15
FILL_TO = 8.0
BLOCK_WALL = 8.0
## Outlines lose detail smaller than this.
SIMPLIFY = 1.0
WATER_WALL = 3.0
## A shoreline the bbox cut is run out to the map edge from this close.
SHORE_REACH = 400.0
## Buildings keep this far inside the boundary, so none stands in the fog
## at the edge of the map; and the boundary outline loses detail smaller
## than BOUNDARY_SIMPLIFY.
BOUNDARY_MARGIN = 60.0
BOUNDARY_SIMPLIFY = 10.0

ROAD_WIDTHS = {
    "motorway": 24.0, "trunk": 22.0, "primary": 18.0, "secondary": 14.0, "tertiary": 11.0,
    "motorway_link": 8.0, "trunk_link": 8.0, "primary_link": 8.0,
    "residential": 8.0, "unclassified": 8.0, "living_street": 6.0, "pedestrian": 5.0,
    "service": 0.0,
}
MINOR_ROADS = ("residential", "unclassified", "living_street", "pedestrian")
RAIL_WIDTH = 8.0
CANAL_WIDTH = 24.0

GREEN = {("leisure", "park"), ("leisure", "golf_course"), ("leisure", "pitch"),
         ("landuse", "grass"), ("landuse", "meadow"), ("landuse", "recreation_ground"),
         ("landuse", "forest"), ("natural", "wood"), ("natural", "scrub")}
WETLAND = {("natural", "wetland")}
CEMETERY = {("landuse", "cemetery")}

# Ground classes. Each one covers the ones before it.
GROUND, MARSH, PARK, GRAVES, RAIL, ROAD, MAJOR, WATER = range(8)
WALL, ROOF = 0, 1


for _k in ("motorway_link", "trunk_link", "primary_link"):
    ROAD_WIDTHS[_k] = 8.0  # a ramp or crossover is narrower than a carriageway
MEDIAN = 6.0  # the two sides of a divided road closer than 2x this read as one
HALVED = ("motorway", "trunk", "primary", "secondary", "tertiary")
for _k in HALVED:
    ROAD_WIDTHS[_k + "~half"] = ROAD_WIDTHS[_k] / 2


def road_class(tags):
    """A one-way carriageway of a divided road is half of it."""
    hw = tags.get("highway")
    if hw in HALVED and (tags.get("oneway") in ("yes", "1", "-1") or hw == "motorway"):
        return hw + "~half"
    return hw


def join_medians(lines):
    """Divided carriageways as one road: their median is closed in."""
    half = [(l, w) for l, w in lines if w > 0]
    if not half:
        return Polygon()
    surf = _strokes(half)
    return _clean(shapely.buffer(shapely.buffer(surf, MEDIAN, quad_segs=4), -MEDIAN, quad_segs=4))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("out")
    ap.add_argument("--bbox")
    ap.add_argument("--iv", action="store_true")
    ap.add_argument("--nofill", action="store_true")
    ap.add_argument("--water-seeds", default="",
                    help="lat,lon;lat,lon points inside water bodies the bbox cuts open")
    args = ap.parse_args()
    t0 = time.time()
    boundary_path = os.path.join(args.raw, "boundary.json")
    rel = None
    if os.path.exists(boundary_path) and not args.bbox:
        rel = json.load(open(boundary_path, encoding="utf-8"))["elements"][0]
    if args.bbox:
        s, w, n, e = (float(v) for v in args.bbox.split(","))
    elif rel:
        pts = [p for m in rel["members"] if m["type"] == "way" for p in m.get("geometry") or [] if p]
        s, w = min(p["lat"] for p in pts), min(p["lon"] for p in pts)
        n, e = max(p["lat"] for p in pts), max(p["lon"] for p in pts)
    else:
        raise SystemExit("give --bbox or a boundary.json")
    lat0, lon0 = (s + n) / 2, (w + e) / 2
    m_lat = 111_320.0
    m_lon = 111_320.0 * math.cos(math.radians(lat0))
    half_x = math.ceil((e - w) / 2 * m_lon / (TILE / 2)) * (TILE / 2)
    half_z = math.ceil((n - s) / 2 * m_lat / (TILE / 2)) * (TILE / 2)
    # The map is the bbox, but the tile grid and ground cover whole tiles.
    real = box(-(e - w) / 2 * m_lon, -(n - s) / 2 * m_lat, (e - w) / 2 * m_lon, (n - s) / 2 * m_lat)
    extent = box(-half_x, -half_z, half_x, half_z)

    def xz(g):
        return (g["lon"] - lon0) * m_lon, -(g["lat"] - lat0) * m_lat

    def ring(geom):
        return [xz(g) for g in geom if g]

    def log(msg):
        print("%6.1fs %s" % (time.time() - t0, msg), flush=True)

    region = real
    if rel:
        ways = [m for m in rel["members"] if m["type"] == "way"]
        outer = _join([m["geometry"] for m in ways if m.get("role") != "inner"])[0]
        inner = _join([m["geometry"] for m in ways if m.get("role") == "inner"])[0]
        region = _area([ring(r) for r in outer], [ring(r) for r in inner])
        region = shapely.simplify(region, BOUNDARY_SIMPLIFY, preserve_topology=True)
        log("boundary %.1f km2" % (region.area / 1e6))
    shapely.prepare(region)

    # --- Buildings ---------------------------------------------------------
    footprints, heights = [], []
    for path in sorted(glob.glob(os.path.join(args.raw, "bld_*.json"))):
        for el in json.load(open(path, encoding="utf-8"))["elements"]:
            if el["type"] != "way" or "geometry" not in el:
                continue
            r = ring(el["geometry"])
            if len(r) < 3:
                continue
            footprints.append(Polygon(r))
            heights.append(_height(el.get("tags", {})))
    footprints = shapely.make_valid(np.array(footprints, dtype=object))
    heights = np.maximum(HEIGHT_STEP, np.round(np.array(heights) / HEIGHT_STEP) * HEIGHT_STEP)
    # make_valid can hand back lines for a degenerate ring; keep area only.
    keep = shapely.area(footprints) > 1.0
    footprints, heights = footprints[keep], heights[keep]
    log("buildings %d" % len(footprints))

    # --- Ground ------------------------------------------------------------
    feats = json.load(open(os.path.join(args.raw, "features.json"), encoding="utf-8"))["elements"]
    coast_path = os.path.join(args.raw, "coast.json")
    if os.path.exists(coast_path):
        feats += json.load(open(coast_path, encoding="utf-8"))["elements"]
    areas = {MARSH: [], PARK: [], GRAVES: [], WATER: []}
    roads, rails, canals, shores = [], [], [], []
    for el in feats:
        tags = el.get("tags", {})
        if el["type"] == "relation":
            outers = [m["geometry"] for m in el.get("members", []) if m.get("role") == "outer" and "geometry" in m]
            inners = [m["geometry"] for m in el.get("members", []) if m.get("role") == "inner" and "geometry" in m]
            outer_rings, cut = _join(outers)
            inner_rings = _join(inners)[0]
            if tags.get("natural") == "water" or tags.get("waterway") == "riverbank":
                shores.extend(cut)
            else:
                outer_rings += [c for c in cut if len(c) > 2]
            poly = _area([ring(r) for r in outer_rings], [ring(r) for r in inner_rings])
        elif "geometry" in el:
            geom = el["geometry"]
            if tags.get("natural") == "coastline":
                shores.append(geom)
                continue
            if not (len(geom) > 2 and geom[0] == geom[-1]):
                line = ring(geom)
                if len(line) < 2:
                    continue
                if tags.get("highway") in ROAD_WIDTHS and tags.get("building", "no") == "no":
                    roads.append((line, road_class(tags), tags.get("bridge", "no") != "no"))
                elif tags.get("railway") == "rail":
                    rails.append(line)
                elif tags.get("waterway") in ("canal", "river") and tags.get("tunnel", "no") == "no"                         and not tags.get("layer", "0").lstrip().startswith("-"):
                    # A culverted ditch (a tunnel, or a layer below ground)
                    # runs under the road; open water there would wall the
                    # road off.
                    canals.append((line, tags.get("width")))
                continue
            poly = _area([ring(geom)], [])
        else:
            continue
        kind = None
        if tags.get("natural") == "water" or tags.get("waterway") == "riverbank":
            kind = WATER
        elif any((k, tags.get(k)) in GREEN for k in ("leisure", "landuse", "natural")):
            kind = PARK
        elif tags.get("natural") in ("wetland",):
            kind = MARSH
        elif tags.get("landuse") == "cemetery":
            kind = GRAVES
        elif tags.get("highway") in ROAD_WIDTHS and tags.get("area") != "yes" and tags.get("building", "no") == "no":
            roads.append((ring(el["geometry"]), road_class(tags), False))
            continue
        if kind is not None and poly is not None:
            areas[kind].append(poly)

    cover = {k: shapely.union_all(v) if v else Polygon() for k, v in areas.items()}
    cover[RAIL] = _strokes([(line, RAIL_WIDTH) for line in rails])
    # A bridge is a deck of its own (bridges.py), not paint on the ground
    # under it; but it still keeps the buildings out from under itself.
    cover[ROAD] = _strokes([(line, ROAD_WIDTHS[k]) for line, k, up in roads if k in MINOR_ROADS and not up])
    cover[MAJOR] = shapely.union_all([_strokes([(line, ROAD_WIDTHS[k]) for line, k, up in roads if k not in MINOR_ROADS and not k.endswith("~half") and not up]), join_medians([(line, ROAD_WIDTHS[k]) for line, k, up in roads if k.endswith("~half") and not up])])
    decks = _strokes([(line, ROAD_WIDTHS[k]) for line, k, up in roads if up])
    canal_strokes = []
    for line, width in canals:
        try:
            wm = float(str(width).split()[0])
        except ValueError:
            wm = CANAL_WIDTH
        canal_strokes.append((line, wm))
    water = [cover[WATER], _strokes(canal_strokes)]
    if args.water_seeds:
        seeds = []
        for seed in args.water_seeds.split(";"):
            lat, lon = (float(v) for v in seed.split(","))
            seeds.append(Point(xz({"lat": lat, "lon": lon})))
        rings, cut = _join(shores)
        flooded = _flood([LineString(ring(c)) for c in rings + cut if len(ring(c)) > 1], region, seeds)
        log("flooded water %.1f km2" % (flooded.area / 1e6))
        water.append(flooded)
    cover[WATER] = shapely.union_all(water)
    log("ground classes")

    # --- Block masses ------------------------------------------------------
    inside = shapely.buffer(region, -BOUNDARY_MARGIN, join_style="mitre")
    shapely.prepare(inside)
    keep = shapely.intersects(inside, footprints)
    footprints, heights = footprints[keep], heights[keep]
    open_ground = shapely.union_all([cover[ROAD], cover[MAJOR], cover[RAIL], cover[WATER], decks])
    open_ground = shapely.buffer(open_ground, SIDEWALK, join_style="mitre")
    shapely.prepare(open_ground)
    fill = Polygon()
    if args.iv and not args.nofill:
        # A superblock is what the kept roads, rail and water enclose. A
        # dense one is filled solid up to house height, one closed region.
        hard = shapely.buffer(shapely.union_all([cover[MAJOR], cover[RAIL], cover[WATER], decks]), SIDEWALK, join_style="mitre")
        open_space = shapely.union_all([cover[PARK], cover[GRAVES]])
        blocks = shapely.difference(inside, hard)
        bld = shapely.union_all(footprints)
        dense = []
        for sb in shapely.get_parts(blocks):
            if sb.area < MIN_AREA:
                continue
            cov = shapely.intersection(bld, sb).area / sb.area
            if cov >= FILL_DENSITY:
                dense.append(sb)
        fill = shapely.difference(shapely.union_all(dense), open_space) if dense else Polygon()
        log("superblocks %d, filled %d" % (shapely.get_num_geometries(blocks), len(dense)))
    steps = []  # (height, mass)
    below = None
    for level in np.unique(heights):
        tall = footprints[heights >= level]
        if len(tall) == 0:
            break
        r = MERGE if level <= LOW_RISE else TOWER_MERGE
        mass = _close(shapely.union_all(tall), r)
        if level <= FILL_TO:
            mass = shapely.union(mass, fill)
        mass = shapely.difference(mass, open_ground)
        mass = shapely.intersection(mass, inside)
        if below is not None:
            mass = shapely.intersection(mass, below)
        mass = _clean(mass)
        if mass.is_empty:
            break
        steps.append((float(level), mass))
        below = mass
        log("step %3d m: %d parts" % (level, shapely.get_num_geometries(mass)))

    # --- Write -------------------------------------------------------------
    os.makedirs(os.path.join(args.out, "tiles"), exist_ok=True)
    for old in glob.glob(os.path.join(args.out, "tiles", "*.bin")):
        os.remove(old)
    nx, nz = int(round(2 * half_x / TILE)), int(round(2 * half_z / TILE))
    buckets = {}  # (tx, tz) -> {"b": [tri arrays], ...}

    def bucket(key, layer):
        return buckets.setdefault(key, {}).setdefault(layer, [])

    def tile_of(geom):
        p = shapely.get_coordinates(geom.representative_point())[0]
        return (min(nx - 1, max(0, int((p[0] + half_x) // TILE))),
                min(nz - 1, max(0, int((p[1] + half_z) // TILE))))

    for i, (level, mass) in enumerate(steps):
        floor = steps[i - 1][0] if i else 0.0
        above = steps[i + 1][1] if i + 1 < len(steps) else None
        for part in shapely.get_parts(mass):
            tint = zlib.crc32(np.round(shapely.get_coordinates(part.representative_point())).tobytes()) & 0xFF
            key = tile_of(part)
            bucket(key, "b").append(_walls(part, floor, level, WALL, tint))
            roof = part if above is None else shapely.difference(part, above)
            if not roof.is_empty:
                bucket(key, "b").append(_flat(roof, level, ROOF, tint))

    # Each ground class without the ones that cover it, so nothing overlaps.
    # Past the boundary there is no ground at all.
    for k in cover:
        cover[k] = shapely.intersection(cover[k], region)
    covered = Polygon()
    layers = {}
    for k in (WATER, MAJOR, ROAD, RAIL, GRAVES, PARK, MARSH):
        layers[k] = shapely.difference(cover[k], covered)
        covered = shapely.union(covered, cover[k])
    layers[GROUND] = shapely.difference(region, covered)
    shapely.prepare(cover[WATER])
    for tz in range(nz):
        for tx in range(nx):
            cell = box(-half_x + tx * TILE, -half_z + tz * TILE, -half_x + (tx + 1) * TILE, -half_z + (tz + 1) * TILE)
            for k, geom in layers.items():
                piece = shapely.intersection(geom, cell)
                if not piece.is_empty:
                    bucket((tx, tz), "g").append(_flat(piece, 0.0, k, 0))
            wet = shapely.intersection(cover[WATER], cell)
            if not wet.is_empty:
                bucket((tx, tz), "w").append(_walls(wet, 0.0, WATER_WALL, WATER, 0))
                bucket((tx, tz), "w").append(_flat(wet, WATER_WALL, WATER, 0))

    walk = shapely.union_all([cover[MAJOR], decks, cover[PARK], cover[GRAVES], cover[WATER]])
    blocked = _clean(shapely.difference(region, walk))
    log("blocked %.2f km2 of %.2f" % (blocked.area / 1e6, region.area / 1e6))
    for tz in range(nz):
        for tx in range(nx):
            cell = box(-half_x + tx * TILE, -half_z + tz * TILE, -half_x + (tx + 1) * TILE, -half_z + (tz + 1) * TILE)
            piece = _polygonal(shapely.intersection(blocked, cell))
            if not piece.is_empty:
                bucket((tx, tz), "w").append(_walls(piece, 0.0, BLOCK_WALL, WATER, 0))
                bucket((tx, tz), "w").append(_flat(piece, BLOCK_WALL, WATER, 0))
    tiles = []
    totals = {"b": 0, "g": 0, "w": 0}
    for (tx, tz), layers_ in sorted(buckets.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        entry = {"x": tx, "z": tz}
        for layer, name in (("b", "blocks"), ("g", "ground"), ("w", "water")):
            parts = [p for p in layers_.get(layer, []) if len(p[0])]
            if not parts:
                continue
            fname = "%s_%d_%d.bin" % (layer, tx, tz)
            totals[layer] += _write(os.path.join(args.out, "tiles", fname), parts)
            entry[name] = fname
        tiles.append(entry)
    meta = {
        "attribution": "Map data (c) OpenStreetMap contributors, ODbL 1.0. https://www.openstreetmap.org/copyright",
        "bbox": [s, w, n, e], "origin": [lat0, lon0], "tile": TILE,
        "corner": [-half_x, -half_z], "extent": [2 * half_x, 2 * half_z], "tiles": tiles,
        "boundary": [np.round(shapely.get_coordinates(r), 1).tolist()
                     for p in shapely.get_parts(shapely.orient_polygons(region)) for r in [p.exterior] + list(p.interiors)],
    }
    with open(os.path.join(args.out, "city.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent=1)
    log("%d tiles; triangles: %d buildings, %d ground, %d water" % (len(tiles), totals["b"], totals["g"], totals["w"]))
    # The water shader's distance-to-shore field. A separate script so it
    # can be re-baked without re-running this one.
    subprocess.run([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "shore_field.py"), args.out], check=True)
    # The bridges, which add their own tiles to city.json.
    subprocess.run([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bridges.py"), args.raw, args.out], check=True)


def _height(tags):
    try:
        return float(tags["height"].split()[0])
    except (KeyError, ValueError):
        pass
    try:
        return float(tags["building:levels"]) * LEVEL_HEIGHT + 1.0
    except (KeyError, ValueError):
        return DEFAULT_HEIGHT


def _area(outers, inners):
    """A multipolygon from outer and inner rings, or None if nothing is left."""
    outer = [Polygon(r) for r in outers if len(r) >= 3]
    if not outer:
        return None
    geom = shapely.union_all(shapely.make_valid(np.array(outer, dtype=object)))
    holes = [Polygon(r) for r in inners if len(r) >= 3]
    if holes:
        geom = shapely.difference(geom, shapely.union_all(shapely.make_valid(np.array(holes, dtype=object))))
    geom = _polygonal(geom)
    return None if geom.is_empty else geom


def _polygonal(geom):
    """Only the polygons of a geometry; make_valid and overlays can leave
    stray lines and points behind."""
    parts = shapely.get_parts(geom)
    keep = [p for p in parts if p.geom_type in ("Polygon", "MultiPolygon")]
    return shapely.union_all(keep) if keep else Polygon()


def _strokes(lines):
    """Lines of the given widths as one polygon, round where they meet."""
    lines = [(l, wd) for l, wd in lines if wd > 0 and len(l) > 1]
    if not lines:
        return Polygon()
    geoms = [LineString(l) for l, _ in lines]
    widths = np.array([wd for _, wd in lines]) / 2
    return shapely.union_all(shapely.buffer(np.array(geoms, dtype=object), widths, quad_segs=4))


def _close(geom, r):
    """Morphological closing: fills gaps and inlets narrower than 2r and
    keeps right-angled corners right-angled."""
    grown = shapely.buffer(geom, r, join_style="mitre", mitre_limit=2.0)
    return shapely.buffer(grown, -r, join_style="mitre", mitre_limit=2.0)


def _clean(geom):
    """Drops slivers and specks, and simplifies the outline."""
    geom = shapely.buffer(shapely.buffer(geom, -1.0, join_style="mitre"), 1.0, join_style="mitre")
    geom = shapely.simplify(geom, SIMPLIFY, preserve_topology=True)
    geom = _polygonal(shapely.make_valid(geom))
    parts = [p for p in shapely.get_parts(geom) if p.area >= MIN_AREA]
    return shapely.union_all(parts) if parts else Polygon()


def _flood(shores, region, seeds):
    """The water the map edge cut open. Each shoreline end close to the
    edge is run out to it; the edge and shorelines then cut the map into
    pieces, and every piece holding a seed is water. A shoreline running on
    past the edge is cut there, and its ends outside, leading nowhere, are
    dropped."""
    edge = shapely.boundary(region)
    lines = [edge]
    for line in shores:
        coords = list(line.coords)
        for end in (0, -1):
            p = Point(coords[end])
            d = edge.distance(p)
            if 0 < d <= SHORE_REACH and region.contains(p):
                q = shapely.ops.nearest_points(edge, p)[0]
                if end == 0:
                    coords.insert(0, (q.x, q.y))
                else:
                    coords.append((q.x, q.y))
        lines.append(LineString(coords))
    noded = shapely.union_all(lines)
    pieces = shapely.get_parts(shapely.polygonize(shapely.get_parts(noded)))
    wet = [p for p in pieces if any(p.contains(s) for s in seeds)]
    return shapely.intersection(shapely.union_all(wet), region) if wet else Polygon()


def _flat(geom, y, kind, tint):
    """A polygon's area as upward-facing triangles at height y."""
    tris = shapely.get_parts(shapely.constrained_delaunay_triangles(geom))
    if len(tris) == 0:
        return _empty()
    c = shapely.get_coordinates(tris).reshape(-1, 4, 2)[:, :3]
    pos = np.empty((len(c), 3, 3), dtype=np.float32)
    pos[:, :, 0] = c[:, :, 0]
    pos[:, :, 1] = y
    pos[:, :, 2] = c[:, :, 1]
    return _facing(pos, np.array([0.0, 1.0, 0.0])), _bytes(len(pos), kind), _bytes(len(pos), tint)


def _walls(geom, y0, y1, kind, tint):
    """The outline of a polygon extruded from y0 to y1, facing out."""
    geom = shapely.orient_polygons(geom)  # shells counter-clockwise in x, z
    quads = []
    for poly in shapely.get_parts(geom):
        for r in [poly.exterior] + list(poly.interiors):
            p = np.asarray(r.coords)
            quads.append(np.concatenate([p[:-1], p[1:]], axis=1))
    if not quads:
        return _empty()
    q = np.concatenate(quads)  # x0 z0 x1 z1
    q = q[np.hypot(q[:, 2] - q[:, 0], q[:, 3] - q[:, 1]) > 1e-6]
    n = len(q)
    a = np.stack([q[:, 0], np.full(n, y0), q[:, 1]], axis=1)
    b = np.stack([q[:, 2], np.full(n, y0), q[:, 3]], axis=1)
    c = np.stack([q[:, 2], np.full(n, y1), q[:, 3]], axis=1)
    d = np.stack([q[:, 0], np.full(n, y1), q[:, 1]], axis=1)
    pos = np.concatenate([np.stack([a, b, c], axis=1), np.stack([a, c, d], axis=1)]).astype(np.float32)
    # Shells run counter-clockwise in (x, z), so outside is to the right.
    dx, dz = q[:, 2] - q[:, 0], q[:, 3] - q[:, 1]
    out = np.stack([dz, np.zeros(n), -dx], axis=1)
    out = np.concatenate([out, out])
    return _facing(pos, out), _bytes(len(pos), kind), _bytes(len(pos), tint)


def _facing(pos, normal):
    """Reorders each triangle so (b - a) x (c - a) points along normal."""
    cross = np.cross(pos[:, 1] - pos[:, 0], pos[:, 2] - pos[:, 0])
    flip = (cross * normal).sum(axis=-1) < 0
    pos[flip] = pos[flip][:, [0, 2, 1]]
    return pos


def _bytes(n, value):
    return np.full(n, value, dtype=np.uint8)


def _empty():
    return np.empty((0, 3, 3), dtype=np.float32), _bytes(0, 0), _bytes(0, 0)


def _write(path, parts):
    pos = np.concatenate([p[0] for p in parts])
    kind = np.concatenate([p[1] for p in parts])
    tint = np.concatenate([p[2] for p in parts])
    with open(path, "wb") as f:
        f.write(np.int32(len(pos)).tobytes())
        f.write(pos.astype(np.float32).tobytes())
        f.write(kind.tobytes())
        f.write(tint.tobytes())
    return len(pos)


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


if __name__ == "__main__":
    main()

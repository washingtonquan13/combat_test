"""Names the places of a built city: where on the map each district is, for
the overworld's area label.

    python -I tools/blockout/districts.py <warped raw> <city dir> [--scene <overworld .tscn>]

The districts are drawn on the real parish (parish_work/districts.json:
blocks of segment.json), but the city was built from a warped copy, and
the warp itself is not kept. Buildings carry their OSM id through it, so
each source building inside a district names its warped twin; every
cell of a RES grid over the map then takes the name of the nearest named
building, so the ground between districts belongs to whichever is
closest. One polygon per piece, clipped to the city line.

Writes <city dir>/districts.json and districts.png, and, when the
overworld scene has no Districts node yet, adds one: an OverworldDistrict
per district with a CollisionPolygon3D per piece. A scene that already
has one is left alone, so renames and hand-moved borders survive a rebuild.
"""
import argparse
import glob
import json
import math
import os
import sys

import numpy as np
import shapely
from scipy.spatial import cKDTree
from shapely.geometry import Polygon

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compress import Frame  # noqa: E402
from parish_warp import district_union  # noqa: E402

RES = 20.0  # m: grid cell the borders are drawn on
SIMPLIFY = 15.0  # m
MIN_PIECE = 200.0 * 200.0  # m2: smaller pieces fold into their neighbour
SEGMENT = "data/blockouts/parish_work"
SOURCE_RAW = "data/blockouts/new_orleans_parish_raw"


def centres(raw):
    """OSM id -> (lon, lat) of the middle of each building's bounds."""
    ids, lon, lat = [], [], []
    for path in sorted(glob.glob(os.path.join(raw, "bld_*.json"))):
        for e in json.load(open(path, encoding="utf-8")).get("elements", []):
            b = e.get("bounds")
            if b:
                ids.append(e["id"])
                lon.append((b["minlon"] + b["maxlon"]) / 2)
                lat.append((b["minlat"] + b["maxlat"]) / 2)
    return np.array(ids, dtype=np.int64), np.array(lon), np.array(lat)


def runs_to_polygon(mask, x0, z0):
    """The cells of a boolean grid as one geometry: each row's runs as boxes."""
    pad = np.zeros((mask.shape[0], mask.shape[1] + 2), bool)
    pad[:, 1:-1] = mask
    d = np.diff(pad.astype(np.int8), axis=1)
    r0, c0 = np.nonzero(d == 1)
    r1, c1 = np.nonzero(d == -1)
    if not len(r0):
        return shapely.Polygon()
    boxes = shapely.box(x0 + c0 * RES, z0 + r0 * RES, x0 + c1 * RES, z0 + (r1 + 1) * RES)
    return shapely.union_all(boxes)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("raw", help="the warped raw the city was built from")
    ap.add_argument("city", help="the osm_city out dir (its city.json)")
    ap.add_argument("--segment", default=SEGMENT)
    ap.add_argument("--source", default=SOURCE_RAW, help="the raw the segment was drawn on")
    ap.add_argument("--scene", help="the overworld .tscn to add a Districts node to")
    a = ap.parse_args()

    seg = json.load(open(os.path.join(a.segment, "segment.json"), encoding="utf-8"))
    dist = json.load(open(os.path.join(a.segment, "districts.json"), encoding="utf-8"))
    city = json.load(open(os.path.join(a.city, "city.json"), encoding="utf-8"))
    names = [d["name"] for d in dist["districts"]]
    polys = district_union(seg, dist)

    # Source buildings by district, in the parish frame.
    sid, slon, slat = centres(a.source)
    sx, sz = Frame(*seg["frame"]).xz(slon, slat)
    label = np.full(len(sid), -1)
    for k, p in enumerate(polys):
        label[shapely.contains_xy(p, sx, sz)] = k
    named = dict(zip(sid[label >= 0].tolist(), label[label >= 0].tolist()))

    # Their warped twins, in map metres.
    wid, wlon, wlat = centres(a.raw)
    wx, wz = Frame(*city["origin"]).xz(wlon, wlat)
    wl = np.array([named.get(i, -1) for i in wid.tolist()])
    hit = wl >= 0
    print("buildings: %d named in the parish, %d of them in the raw the city was built from (of %d)"
          % (len(named), int(hit.sum()), len(wid)))

    # Nearest named building per cell, inside the city line.
    (cx, cz), (ex, ez) = city["corner"], city["extent"]
    nx, nz = int(math.ceil(ex / RES)), int(math.ceil(ez / RES))
    gx, gz = np.meshgrid(cx + (np.arange(nx) + 0.5) * RES, cz + (np.arange(nz) + 0.5) * RES)
    line = shapely.union_all([Polygon(r) for r in city["boundary"]]) if city.get("boundary") else shapely.box(cx, cz, cx + ex, cz + ez)
    inside = shapely.contains_xy(line, gx, gz)
    _, near = cKDTree(np.c_[wx[hit], wz[hit]]).query(np.c_[gx[inside], gz[inside]])
    grid = np.full(gx.shape, -1)
    grid[inside] = wl[hit][near]

    # Fold specks: a piece under MIN_PIECE takes the name of the
    # neighbour it borders most.
    shapes = {k: runs_to_polygon(grid == k, cx, cz) for k in range(len(names))}
    for k in range(len(names)):
        for piece in shapely.get_parts(shapes[k]):
            if piece.area >= MIN_PIECE:
                continue
            ring = piece.buffer(RES * 0.5)
            best = max((j for j in shapes if j != k), key=lambda j: shapes[j].intersection(ring).area)
            shapes[best] = shapely.union(shapes[best], piece)
            shapes[k] = shapely.difference(shapes[k], piece)

    out, report = [], []
    for k, nm in enumerate(names):
        g = shapely.intersection(shapely.simplify(shapes[k], SIMPLIFY), line)
        parts = [p for p in shapely.get_parts(g) if p.geom_type == "Polygon" and p.area >= MIN_PIECE]
        rings = [np.round(np.asarray(p.exterior.coords)[:-1], 1).tolist() for p in parts]
        area = sum(p.area for p in parts)
        out.append({"name": nm, "rings": rings, "area_km2": round(area / 1e6, 2)})
        report.append("  %-26s %5.2f km2 in %d piece%s" % (nm, area / 1e6, len(parts), "" if len(parts) == 1 else "s"))
    print("districts on the map:\n" + "\n".join(report))
    with open(os.path.join(a.city, "districts.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"res": RES, "districts": out}, f, indent=1)
    _png(os.path.join(a.city, "districts.png"), out, line, wx[hit], wz[hit], wl[hit])

    if a.scene:
        _add_to_scene(a.scene, out)


def _png(path, out, line, bx, bz, bl):
    from PIL import Image, ImageDraw
    x0, z0, x1, z1 = line.bounds
    s = 1000.0 / max(x1 - x0, z1 - z0)
    img = Image.new("RGB", (int((x1 - x0) * s) + 1, int((z1 - z0) * s) + 1), (24, 24, 28))
    dr = ImageDraw.Draw(img)
    hue = [(230, 120, 90), (90, 160, 230), (220, 200, 80), (120, 210, 120), (200, 110, 210), (90, 210, 200),
           (240, 160, 60), (160, 140, 240), (170, 210, 80), (230, 110, 150), (130, 180, 160), (200, 200, 200)]
    for k, d in enumerate(out):
        for r in d["rings"]:
            dr.polygon([((x - x0) * s, (z - z0) * s) for x, z in r], fill=tuple(c // 3 for c in hue[k % 12]), outline=hue[k % 12])
    on = (bx >= x0) & (bx < x1) & (bz >= z0) & (bz < z1)
    bx, bz, bl = bx[on], bz[on], bl[on]
    step = max(1, len(bx) // 40000)
    for x, z, k in zip(bx[::step], bz[::step], bl[::step]):
        img.putpixel((int((x - x0) * s), int((z - z0) * s)), hue[k % 12])
    for k, d in enumerate(out):
        if d["rings"]:
            p = max((Polygon(r) for r in d["rings"]), key=lambda p: p.area).representative_point()
            dr.text(((p.x - x0) * s - 30, (p.y - z0) * s), d["name"], fill=(255, 255, 255))
    img.save(path)


def _add_to_scene(path, out):
    text = open(path, encoding="utf-8").read()
    if '[node name="Districts"' in text:
        print("%s already has Districts, left alone" % path)
        return
    script = '[ext_resource type="Script" path="res://world/overworld_district.gd" id="district"]\n'
    last = text.rfind("[ext_resource")
    cut = text.index("\n", last) + 1
    text = text[:cut] + script + text[cut:]
    nodes = ['\n[node name="Districts" type="Node3D" parent="."]\n']
    for d in out:
        if not d["rings"]:
            continue  # not on this map
        node = d["name"].replace(" ", "")
        nodes.append('\n[node name="%s" type="Area3D" parent="Districts"]\n'
                     'collision_layer = 0\ncollision_mask = 0\nmonitoring = false\nmonitorable = false\n'
                     'script = ExtResource("district")\ndisplay_name = %s\n' % (node, json.dumps(d["name"])))
        for i, r in enumerate(d["rings"]):
            pts = ", ".join("%g, %g" % (x, z) for x, z in r)
            nodes.append('\n[node name="Piece%d" type="CollisionPolygon3D" parent="Districts/%s"]\n'
                         'rotation = Vector3(1.5707964, 0, 0)\n'
                         'depth = 400.0\npolygon = PackedVector2Array(%s)\n' % (i, node, pts))
    text = text.rstrip("\n") + "\n" + "".join(nodes)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("districts -> %s" % path)


if __name__ == "__main__":
    main()

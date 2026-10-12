"""Bakes a distance-to-shore field for an osm_city.py output directory.

The water shader uses it the way toon water usually uses the depth buffer:
shallow colour and shore foam near the bank. Our water has no depth under
it, so the distance is baked from the water triangles instead.

    python -I tools/blockout/shore_field.py data/blockouts/<name> [--res 5]

Reads city.json and the ground tiles, writes shore.png and adds a "shore"
entry to city.json. Needs numpy and Pillow. --res defaults to 5 m, or
coarser for a map so big the field would pass PIXELS. Both channels are
metres, capped at 255:
  red    distance to the nearest bank.
  green  how open the water around this point is: the largest red value
         within WIDE metres, reached through water. A canal stays at its
         half-width all along, a pond at its radius, while even the bank of
         a river reads as open water. The shader calms the small bodies by
         it.

If city.json has a boundary, it also writes edge.bin and an "edge" entry,
for the fog at the edge of the map: the signed distance in metres from
each pixel's centre to the boundary, inside positive, as raw little-endian
half floats, row by row from the corner. Half floats hold a metre to
within a millimetre near the line, where the fog fades, so the fade has no
bands; and Godot reads them straight into a filterable texture.
"""
import argparse
import json
import os
import struct

import numpy as np
import shapely
from PIL import Image, ImageDraw

WATER = 7
RANGE = 255.0
WIDE = RANGE
PIXELS = 30e6
EDGE_RES = 20.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--res", type=float, help="metres per pixel")
    args = ap.parse_args()
    with open(os.path.join(args.dir, "city.json"), encoding="utf-8") as f:
        meta = json.load(f)
    cx, cz = meta["corner"]
    if args.res is None:
        args.res = max(5.0, float(np.ceil(np.sqrt(meta["extent"][0] * meta["extent"][1] / PIXELS))))
    w = int(np.ceil(meta["extent"][0] / args.res))
    h = int(np.ceil(meta["extent"][1] / args.res))
    mask = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(mask)
    count = 0
    for tile in meta["tiles"]:
        if "ground" not in tile:
            continue
        for tri in _water_tris(os.path.join(args.dir, "tiles", tile["ground"])):
            pts = [((x - cx) / args.res, (z - cz) / args.res) for x, z in tri]
            draw.polygon(pts, fill=255, outline=255)
            count += 1
    water = np.asarray(mask) > 0
    dist = _distance(~water, RANGE / args.res) * args.res
    dist = np.where(water, dist, 0.0)
    wide = _open_water(dist, water, int(round(WIDE / args.res)))
    out = np.stack([dist, wide, np.zeros_like(dist)], axis=-1)
    out = np.clip(out, 0.0, RANGE).astype(np.uint8)
    Image.fromarray(out, "RGB").save(os.path.join(args.dir, "shore.png"))
    meta["shore"] = {"file": "shore.png", "res": args.res, "range": RANGE}
    if meta.get("boundary"):
        meta["edge"] = _edge(args.dir, meta)
    with open(os.path.join(args.dir, "city.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent=1)
    print(f"shore: {count} water triangles, {w}x{h} px at {args.res} m")


def _edge(out_dir, meta):
    cx, cz = meta["corner"]
    w = int(np.ceil(meta["extent"][0] / EDGE_RES))
    h = int(np.ceil(meta["extent"][1] / EDGE_RES))
    # Measured from the boundary itself, not a mask drawn from it, so the
    # line falls where it is and not on a pixel's edge: a point is inside
    # when it is inside an odd number of the rings.
    rings = [shapely.LinearRing(r) for r in meta["boundary"]]
    zz, xx = np.mgrid[0:h, 0:w]
    x, z = cx + (xx.ravel() + 0.5) * EDGE_RES, cz + (zz.ravel() + 0.5) * EDGE_RES
    dist = np.min([shapely.distance(r, shapely.points(x, z)) for r in rings], axis=0)
    inside = np.sum([shapely.contains_xy(shapely.Polygon(r), x, z) for r in rings], axis=0) % 2 == 1
    signed = np.where(inside, dist, -dist).reshape(h, w)
    with open(os.path.join(out_dir, "edge.bin"), "wb") as f:
        f.write(signed.astype("<f2").tobytes())
    print(f"edge: {w}x{h} px at {EDGE_RES} m, {signed.min():.0f} to {signed.max():.0f} m")
    return {"file": "edge.bin", "res": EDGE_RES, "size": [w, h], "format": "half"}


def _water_tris(path):
    with open(path, "rb") as f:
        data = f.read()
    n = struct.unpack_from("<i", data, 0)[0]
    xyz = np.frombuffer(data, "<f4", n * 9, 4).reshape(n, 3, 3)
    kinds = np.frombuffer(data, np.uint8, n, 4 + n * 36)
    return xyz[kinds == WATER][:, :, [0, 2]].tolist()


def _distance(seed, reach):
    """Pixels from each pixel to the nearest seed pixel, by jump flooding.
    Exact enough within reach pixels, which is all the shader reads."""
    h, w = seed.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    far = np.float32(1e6)
    ny = np.where(seed, yy, far)
    nx = np.where(seed, xx, far)
    best = (ny - yy) ** 2 + (nx - xx) ** 2
    steps = []
    k = 1
    while k < reach:
        k *= 2
    while k >= 1:
        steps.append(k)
        k //= 2
    for k in steps + [1]:
        for dy in (-k, 0, k):
            for dx in (-k, 0, k):
                if dy == 0 and dx == 0:
                    continue
                sy = _shift(ny, dy, dx, far)
                sx = _shift(nx, dy, dx, far)
                d = (sy - yy) ** 2 + (sx - xx) ** 2
                better = d < best
                ny = np.where(better, sy, ny)
                nx = np.where(better, sx, nx)
                best = np.where(better, d, best)
    return np.sqrt(best)


def _open_water(dist, water, steps):
    """Spreads each water pixel's distance to the bank over its neighbours,
    steps pixels through water, keeping the largest."""
    out = dist
    for _ in range(steps):
        grown = out
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy or dx:
                    grown = np.maximum(grown, _shift(out, dy, dx, 0.0))
        out = np.where(water, grown, 0.0)
    return out


def _shift(a, dy, dx, fill):
    """out[y, x] = a[y + dy, x + dx], with fill past the edge."""
    h, w = a.shape
    out = np.full_like(a, fill)
    out[max(0, -dy):h - max(0, dy), max(0, -dx):w - max(0, dx)] = \
        a[max(0, dy):h + min(0, dy), max(0, dx):w + min(0, dx)]
    return out


if __name__ == "__main__":
    main()

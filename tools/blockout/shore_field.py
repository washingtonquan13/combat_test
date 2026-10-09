"""Bakes a distance-to-shore field for an osm_city.py output directory.

The water shader uses it the way toon water usually uses the depth buffer:
shallow colour and shore foam near the bank. Our water has no depth under
it, so the distance is baked from the water triangles instead.

    python -I tools/blockout/shore_field.py data/blockouts/<name> [--res 5]

Reads city.json and the ground tiles, writes shore.png (8-bit, metres to
the nearest non-water point, capped at 255) and adds a "shore" entry to
city.json. Needs numpy and Pillow.
"""
import argparse
import json
import os
import struct

import numpy as np
from PIL import Image, ImageDraw

WATER = 7
RANGE = 255.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--res", type=float, default=5.0, help="metres per pixel")
    args = ap.parse_args()
    with open(os.path.join(args.dir, "city.json"), encoding="utf-8") as f:
        meta = json.load(f)
    cx, cz = meta["corner"]
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
    out = np.clip(np.where(water, dist, 0.0), 0.0, RANGE).astype(np.uint8)
    Image.fromarray(out, "L").save(os.path.join(args.dir, "shore.png"))
    meta["shore"] = {"file": "shore.png", "res": args.res, "range": RANGE}
    with open(os.path.join(args.dir, "city.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent=1)
    print(f"shore: {count} water triangles, {w}x{h} px at {args.res} m")


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


def _shift(a, dy, dx, fill):
    """out[y, x] = a[y + dy, x + dx], with fill past the edge."""
    h, w = a.shape
    out = np.full_like(a, fill)
    out[max(0, -dy):h - max(0, dy), max(0, -dx):w - max(0, dx)] = \
        a[max(0, dy):h + min(0, dy), max(0, dx):w + min(0, dx)]
    return out


if __name__ == "__main__":
    main()

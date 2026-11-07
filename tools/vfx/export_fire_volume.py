"""Export the wall-of-fire sim (bake_fire_wall.py's Mantaflow cache) as a
looping 3D volume of flame, for a raymarched wall: no render at all.

Run inside Blender (for its OpenVDB module), after bake_fire_wall.py has
baked the cache:

  blender --background --factory-startup --python tools/vfx/export_fire_volume.py -- \
      --work <bake work dir> --out assets/vfx/fire_wall_volume.bin

Writes <out> as raw uint8 flame, x fastest, then height, then thickness,
then frame - X wide (along the wall, one tile, tiling seamlessly), Y tall,
Z thick, FRAMES of them, looping - and <out>.json with those sizes and the
tile's size in meters.
"""
import argparse
import glob
import json
import os
import sys

import numpy as np

try:
    import openvdb as vdb
except ImportError:
    import pyopenvdb as vdb

# Must match bake_fire_wall.py.
LOOP = 64
XFADE = 16
SETTLE = 50
SECTION = 1.2
TILE_XFADE = 0.4
VOXEL = 0.025  # HALF_X * 2 / resolution 128


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--work", required=True)
    p.add_argument("--out", required=True)
    args = p.parse_args(argv)
    files = sorted(glob.glob(os.path.join(args.work, "cache", "data", "fluid_data_*.vdb")))
    window = files[SETTLE:SETTLE + LOOP + XFADE]
    assert len(window) == LOOP + XFADE, len(window)
    meta = {g.name: g for g in vdb.readAllGridMetadata(window[0])}
    dims = tuple(int(v) + 1 for v in meta["shadow"].metadata["file_bbox_max"])
    frames = np.zeros((len(window),) + dims, np.float32)
    for n, path in enumerate(window):
        vdb.read(path, "flame").copyToArray(frames[n], ijk=(0, 0, 0))
    # Seamless in time: the loop's first XFADE frames blend in from past its end.
    w = (np.arange(XFADE, dtype=np.float32) / XFADE)[:, None, None, None]
    loop = frames[:LOOP].copy()
    loop[:XFADE] = (1.0 - w) * frames[LOOP:LOOP + XFADE] + w * frames[:XFADE]
    # Seamless along the wall: one SECTION from the middle, the TILE_XFADE
    # past its right end blended into its left.
    sec = int(round(SECTION / VOXEL))
    fade = int(round(TILE_XFADE / VOXEL))
    x0 = dims[0] // 2 - sec // 2
    strip = loop[:, x0:x0 + sec + fade]
    tile = strip[:, :sec].copy()
    wx = (np.arange(fade, dtype=np.float32) / fade)[None, :, None, None]
    tile[:, :fade] = (1.0 - wx) * strip[:, sec:sec + fade] + wx * strip[:, :fade]
    # Up to just past the highest flame.
    lit = np.nonzero(tile.max(axis=(0, 1, 2)) > 0.02)[0]
    top = min(dims[2], int(lit.max()) + 3)
    tile = tile[..., :top]
    hi = np.percentile(tile[tile > 0.01], 99.7)
    tile = np.clip(tile / hi, 0.0, 1.0)
    seam = np.abs(tile[:, -1] - tile[:, 0]).mean()
    near = np.abs(np.diff(tile, axis=1)).mean()
    print(f"[vol] dims={dims} tile={tile.shape[1:]} frames={LOOP} hi={hi:.3f} "
          f"seam={seam:.4f} vs neighbour={near:.4f}")
    # frame, x, y(thick), z(up) -> frame, thick, up, x  (x fastest)
    out = (tile.transpose(0, 2, 3, 1) * 255.0 + 0.5).astype(np.uint8)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    out.tofile(args.out)
    info = {"x": out.shape[3], "y": out.shape[2], "z": out.shape[1], "frames": LOOP,
            "size_m": [sec * VOXEL, top * VOXEL, dims[1] * VOXEL]}
    with open(args.out + ".json", "w") as f:
        json.dump(info, f)
    print(f"[vol] {info} -> {args.out} ({out.nbytes / 1e6:.1f} MB)")


main()

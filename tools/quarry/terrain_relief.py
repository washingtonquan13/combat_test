"""Valley-wide relief, occlusion and shape masks for the quarry ground.

The ground mesh has a vertex every 0.4 m and the bake's height function has
nothing finer than that, so sampling it harder adds nothing. This builds a
finer ground that exists only in textures: the baked heights at 0.2 m plus
small bumps and the rills that rain would cut down the slopes. The walked-on
ground does not move; the shader bends light and paint by these maps.

    godot --headless --path . -s tools/quarry/bake_goblin_quarry.gd -- --dump-heights heights.bin
    python tools/quarry/terrain_relief.py heights.bin world/goblin_quarry [--preview dir]

Writes, one texel per 0.2 m, covering the whole height grid:
  terrain_relief.png  R,G  slope of the fine detail along +X and +Z,
                           0.5 = level, full range = +-SLOPE_RANGE
                      B    sky occlusion, 1 = open ground
  terrain_masks.png   R    runoff: how much water gathers here, 0..1
                      G    hollow (above 0.5) or crest (below 0.5), against
                           the ground a stride or two away
                      B    the same against the ground 4 m away: the dips
                           and rises of a field, which the grass colours by
"""

import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

UP = 2                # texels per mesh cell
SLOPE_RANGE = 1.0     # slope that maps to the ends of the R,G range
SEED = 17


def load(path):
    raw = Path(path).read_bytes()
    nx, nz = struct.unpack_from("<ii", raw, 0)
    x0, z0, cell = struct.unpack_from("<fff", raw, 8)
    n = nx * nz
    h = np.frombuffer(raw, "<f4", n, 20).reshape(nz, nx).astype(np.float64)
    paint = np.frombuffer(raw, "<f4", n * 4, 20 + n * 4).reshape(nz, nx, 4).astype(np.float64)
    return h, paint, cell


def upsample(a, order):
    nz, nx = a.shape
    zz = (np.arange((nz - 1) * UP) + 0.5) / UP
    xx = (np.arange((nx - 1) * UP) + 0.5) / UP
    grid = np.meshgrid(zz, xx, indexing="ij")
    return ndi.map_coordinates(a, grid, order=order, mode="nearest")


def noise(shape, rng, wavelength, texel):
    n = ndi.gaussian_filter(rng.standard_normal(shape), wavelength / texel / 4.0, mode="reflect")
    return n / n.std()


def shifted(a, dz, dx):
    """a[z + dz, x + dx], edges repeated."""
    pz, px = abs(dz), abs(dx)
    p = np.pad(a, ((pz, pz), (px, px)), mode="edge")
    return p[pz + dz:pz + dz + a.shape[0], px + dx:px + dx + a.shape[1]]


NEIGHBOURS = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


def runoff(h, texel, steps):
    """Rain falls evenly and runs downhill, split between lower neighbours by
    steepness. Returns the water passing through each texel, in texels of
    catchment."""
    weights = []
    for dz, dx in NEIGHBOURS:
        drop = (h - shifted(h, dz, dx)) / (texel * np.hypot(dz, dx))
        weights.append(np.maximum(drop, 0.0) ** 3)
    total = np.maximum(sum(weights), 1e-12)
    weights = [w / total for w in weights]
    acc = np.ones_like(h)
    for _ in range(steps):
        new = np.ones_like(h)
        for (dz, dx), w in zip(NEIGHBOURS, weights):
            # What the neighbour at (-dz, -dx) sends this way.
            new += shifted(acc * w, -dz, -dx)
        acc = new
    return acc


def occlusion(h, texel):
    """How much of the sky each texel sees past the ground around it."""
    dists = [1.0, 1.6, 2.4, 3.4, 5.0, 7.0, 10.0, 14.0, 20.0, 28.0]
    dirs = 16
    vis = np.zeros_like(h)
    for d in range(dirs):
        a = 2.0 * np.pi * d / dirs
        horizon = np.zeros_like(h)
        for r in dists:
            dz = int(round(np.sin(a) * r / texel))
            dx = int(round(np.cos(a) * r / texel))
            rise = (shifted(h, dz, dx) - h) / (texel * np.hypot(dz, dx))
            horizon = np.maximum(horizon, rise)
        # sin of the horizon's elevation; the sky above it is what is left.
        vis += 1.0 - horizon / np.sqrt(1.0 + horizon * horizon)
    return vis / dirs


def main():
    args = sys.argv[1:]
    preview = None
    if "--preview" in args:
        i = args.index("--preview")
        preview = Path(args[i + 1])
        del args[i:i + 2]
    src, out = args[0], Path(args[1])
    h0, paint0, cell = load(src)
    texel = cell / UP
    rng = np.random.default_rng(SEED)

    h = upsample(h0, 3)
    paint = np.stack([upsample(paint0[..., k], 1) for k in range(4)], -1)
    rock, grass, dirt = paint[..., 0], paint[..., 2], paint[..., 3]
    gz, gx = np.gradient(h, texel)
    slope = np.hypot(gx, gz)

    # Small bumps: more on slopes, less on trodden dirt, rock keeps its own.
    rough = (0.35 + 0.65 * np.clip(slope / 0.6, 0.0, 1.0)) * (1.0 - 0.6 * dirt) * (1.0 - 0.5 * rock)
    bumps = np.zeros_like(h)
    for wavelength, amp in [(5.0, 0.030), (2.2, 0.022), (1.0, 0.012), (0.5, 0.006)]:
        bumps += noise(h.shape, rng, wavelength, texel) * amp
    detail = bumps * rough
    # Grass hides the ground under it, so small bumps there never show. A
    # field reads as ground by its swells: broad, shallow, and far larger in
    # the light than the mesh could carry without tripping anyone.
    swell = noise(h.shape, rng, 7.0, texel) * 0.11 + noise(h.shape, rng, 3.2, texel) * 0.05
    detail += swell * grass * (1.0 - 0.7 * np.clip(slope / 0.5, 0.0, 1.0))

    # Rills: let rain find its way down, cut where it gathers, twice so the
    # second rain follows the first cuts.
    # Level ground has no rills: water there spreads and soaks in.
    steep = np.clip((ndi.gaussian_filter(slope, 1.0 / texel) - 0.06) / 0.22, 0.0, 1.0)
    acc = None
    for _ in range(2):
        acc = runoff(h + detail, texel, 220)
        gather = np.clip(np.log2(acc) / 9.0, 0.0, 1.0)       # 1 at ~500 texels of catchment
        cut = ndi.gaussian_filter(gather ** 1.5, 0.8) * steep
        detail -= cut * 0.14 * (1.0 - 0.5 * rock)
    detail -= ndi.gaussian_filter(detail, 12.0 / texel)        # keep it local: no valley-wide tilt

    fine = h + detail
    dz, dx = np.gradient(detail, texel)
    # The sky seen past the valley's own shapes; the fine detail's share is
    # the hollow mask, so bumps don't speckle it.
    occ = occlusion(ndi.gaussian_filter(h, 0.8 / texel), texel)
    # Open ground is the measure: a field ringed by far cliffs is not shaded.
    occ = occ / np.percentile(occ, 90)
    occ = np.clip((occ - 0.35) / 0.65, 0.0, 1.0) ** 0.7

    # Against the ground within a stride or two; tanh so cliffs don't flood it.
    hollow = np.tanh((ndi.gaussian_filter(fine, 1.0 / texel) - fine) / 0.22)
    hollow = np.clip(0.5 + 0.5 * hollow, 0.0, 1.0)
    # From the detail alone: against the real heights every terrace and bank
    # reads as one big rise and the whole field takes a single tint.
    broad = ndi.gaussian_filter(detail, 1.0 / texel)
    field = np.tanh((ndi.gaussian_filter(detail, 4.0 / texel) - broad) / 0.12)
    field = np.clip(0.5 + 0.5 * field, 0.0, 1.0)
    run = np.clip((np.log2(acc) - 3.0) / 7.0, 0.0, 1.0)
    run = ndi.gaussian_filter(run, 0.6) * steep

    def byte(a):
        return np.clip(np.round(a * 255.0), 0, 255).astype(np.uint8)

    relief = np.stack([byte(0.5 + dx / SLOPE_RANGE * 0.5), byte(0.5 + dz / SLOPE_RANGE * 0.5), byte(occ)], -1)
    masks = np.stack([byte(run), byte(hollow), byte(field)], -1)
    Image.fromarray(relief, "RGB").save(out / "terrain_relief.png")
    Image.fromarray(masks, "RGB").save(out / "terrain_masks.png")
    print("relief %d x %d at %.2f m; detail %.3f..%.3f m, slope p99 %.2f, occlusion mean %.2f" % (
        h.shape[1], h.shape[0], texel, detail.min(), detail.max(),
        np.percentile(np.hypot(dx, dz), 99), occ.mean()))
    if preview:
        # A lit view from above, to judge the relief without the game.
        light = np.array([-0.5, 0.6, -0.62])
        n = np.stack([-(gx + dx), np.ones_like(h), -(gz + dz)], -1)
        n /= np.linalg.norm(n, axis=-1, keepdims=True)
        lit = np.clip(n @ light, 0.0, 1.0) * 0.8 + 0.2 * occ
        Image.fromarray(byte(lit), "L").save(preview / "lit_detail.png")
        n = np.stack([-gx, np.ones_like(h), -gz], -1)
        n /= np.linalg.norm(n, axis=-1, keepdims=True)
        Image.fromarray(byte(np.clip(n @ light, 0.0, 1.0) * 0.8 + 0.2), "L").save(preview / "lit_plain.png")
        Image.fromarray(byte(occ), "L").save(preview / "occlusion.png")
        Image.fromarray(byte(run), "L").save(preview / "runoff.png")
        Image.fromarray(byte(hollow), "L").save(preview / "hollow.png")
        Image.fromarray(byte(field), "L").save(preview / "field.png")


if __name__ == "__main__":
    main()

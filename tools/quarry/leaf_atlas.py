"""Builds a card atlas of leafy branch clusters from single-leaf scans.

Poly Haven's island tree ships eight loose leaves, which is right for a model
with one quad per leaf but far too many quads for a tree that has to draw at a
distance. This lays those leaves along drawn twigs, and fans several twigs
out of one stem, 4x4 cells to an atlas. A generated tree then places a whole
branch end with one card, the way BG3's and SpeedTree's cluster cards work:
a few large cards instead of many small ones (docs/plans/bg3_foliage_study.md,
change 5). The leaves inside a cluster are shaded darker toward its middle and
bottom, so each card carries its own volume.

Each cell's stem grows from the middle of its bottom edge, so the card's base
sits on the branch and it grows along the card's V axis.

A second file, <out>_surface.png, carries what tree_leaf.gdshader reads as
`surface` (change 4): R, G the normal's x and y in the atlas (y up the
image), B roughness. Each leaf brings its scan's own normals (the midrib and
veins), turned with the leaf, and is tilted out from the cluster's middle, so
a flat card shades like a dome of leaves instead of one sheet.

    python -I tools/quarry/leaf_atlas.py <leaves.png> <out.png> [--seed N]

The scan's normal and roughness maps are found next to <leaves.png>
(`_diff_` swapped for `_nor_gl_` and `_arm_`, .jpg).
"""

import argparse
import os

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

SIZE = 2048
GRID = 4
CELL = SIZE // GRID
SAT = 0.58
GAIN = 1.32
# How far a leaf at the cluster's rim tilts out from it (in normal x, y).
DOME = 0.55
# Each leaf's own random tilt.
TILT = 0.18
FLAT = (128, 128, 170, 255)
# The tilts draw from their own generator, so the colour atlas is unchanged.
TRNG = np.random.default_rng(11)


# The colour the cards end on: a pale sage like BG3's leaf textures, measured
# 2026-11-21 (docs/plans/bg3_foliage_study.md). The rest of the colour comes
# from the leaf shader's tints. SAT pulls each texel toward its own luminance,
# GAIN lightens it; tuned so the opaque texels' median HSV saturation is
# about 0.4 and their median value about 0.40, as BG3's gnarly leaves.
def grade_atlas(img, sat, gain):
    a = np.asarray(img).astype(np.float32)
    rgb = a[..., :3]
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    a[..., :3] = np.clip((lum[..., None] + (rgb - lum[..., None]) * sat) * gain, 0, 255)
    return Image.fromarray(a.round().astype(np.uint8), img.mode)


def cut_leaves(path):
    # Each opaque island is one leaf. The scans have a black rim a few texels
    # wide, so the mask is shrunk past it. Each leaf comes back as a pair:
    # colour, and its surface as RGBA (R, G the normal's x and y in image
    # axes, y down, B roughness, A the colour's alpha).
    a = np.asarray(Image.open(path).convert("RGBA"))
    stem = os.path.splitext(path)[0].replace("_diff_", "_%s_")
    nrm = np.asarray(Image.open(stem % "nor_gl" + ".jpg").convert("RGB")).astype(np.float32) / 255.0
    arm = np.asarray(Image.open(stem % "arm" + ".jpg").convert("RGB"))
    m = a[..., 3] > 128
    lab, n = ndimage.label(m)
    leaves = []
    scale = a.shape[0] / 1024.0
    for i, s in enumerate(ndimage.find_objects(lab)):
        h = s[0].stop - s[0].start
        w = s[1].stop - s[1].start
        if h * w < 2000 * scale * scale:
            continue
        own = lab[s] == i + 1
        inner = ndimage.binary_erosion(own, iterations=int(round(5 * scale)))
        rgba = a[s].copy()
        dark = rgba[..., :3].astype(np.int32).sum(-1) < 60
        rgba[..., 3] = np.where(inner & ~dark, 255, 0)
        surf = np.zeros(rgba.shape, np.uint8)
        # GL normal maps store y up; the atlas works in image axes, y down.
        surf[..., 0] = (nrm[s][..., 0] * 255).round()
        surf[..., 1] = ((1.0 - nrm[s][..., 1]) * 255).round()
        surf[..., 2] = arm[s][..., 1]
        surf[..., 3] = rgba[..., 3]
        leaves.append((Image.fromarray(rgba), surf))
    return leaves


def place(canvas, leaf, base, angle, length, shade, surface=None, tilt=(0.0, 0.0)):
    # Pastes a leaf with its stalk end on `base`, pointing `angle` radians
    # clockwise from straight up, `length` pixels long. With `surface`, the
    # leaf's normals go there too, turned by `angle` and offset by `tilt`.
    rgba, surf = leaf
    w, h = rgba.size
    k = length / h
    size = (max(2, int(w * k)), max(2, int(length)))
    img = rgba.resize(size, Image.LANCZOS)
    arr = np.asarray(img).astype(np.float32)
    arr[..., :3] *= shade
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    c, s = np.cos(angle), np.sin(angle)
    if surface is not None:
        sf = surf.astype(np.float32)
        nx, ny = sf[..., 0] / 127.5 - 1.0, sf[..., 1] / 127.5 - 1.0
        # Turned clockwise with the leaf (image axes, y down).
        sf[..., 0] = (nx * c - ny * s + tilt[0] + 1.0) * 127.5
        sf[..., 1] = (nx * s + ny * c + tilt[1] + 1.0) * 127.5
        simg = Image.fromarray(np.clip(sf, 0, 255).round().astype(np.uint8), "RGBA").resize(size, Image.LANCZOS)
        _paste(surface, simg.rotate(-np.degrees(angle), resample=Image.BICUBIC, expand=True), base, angle, size)
    rot = img.rotate(-np.degrees(angle), resample=Image.BICUBIC, expand=True)
    _paste(canvas, rot, base, angle, size)


def _paste(canvas, rot, base, angle, size):
    # The stalk end is the bottom middle of the unrotated leaf.
    off = np.array([0.0, size[1] / 2.0])
    c, s = np.cos(angle), np.sin(angle)
    stalk = np.array([off[0] * c - off[1] * s, off[0] * s + off[1] * c])
    centre = np.array(base) - stalk
    tl = (int(centre[0] - rot.size[0] / 2), int(centre[1] - rot.size[1] / 2))
    layer = Image.new("RGBA", canvas.size)
    layer.paste(rot, tl, rot)
    canvas.alpha_composite(layer)


def twig(draw, at, angle, length, width, rng, leaves_out, depth, leaf=1.0):
    # One twig from `at`, `angle` radians clockwise from up, drawn as a gentle
    # curve; leaves alternate along it and side twigs fork off the main one.
    bend = rng.uniform(-0.35, 0.35)
    pts = []
    for t in np.linspace(0, 1, 16):
        a = angle + bend * t
        if not pts:
            pts.append(np.array(at, float))
        else:
            pts.append(pts[-1] + np.array([np.sin(a), -np.cos(a)]) * length / 15)
    for d, col in draw:
        for i in range(len(pts) - 1):
            w = np.interp(i, [0, len(pts) - 1], [width, width * 0.4])
            d.line([tuple(pts[i]), tuple(pts[i + 1])], fill=col, width=max(1, int(round(w))))
    nodes = rng.integers(4, 7)
    side = 1 if rng.random() < 0.5 else -1
    for k in range(nodes):
        t = 0.2 + 0.75 * k / (nodes - 1)
        i = min(int(t * (len(pts) - 1)), len(pts) - 1)
        a = angle + bend * t
        side = -side
        if depth == 0 and k in (1, 3):
            twig(draw, pts[i], a + side * rng.uniform(0.55, 0.85), length * rng.uniform(0.45, 0.6), width * 0.6, rng, leaves_out, 1, leaf)
            continue
        leaves_out.append((tuple(pts[i]), a + side * rng.uniform(0.7, 1.3), CELL * leaf * rng.uniform(0.2, 0.27) * (1.0 - 0.2 * t)))
    end = len(pts) - 1
    leaves_out.append((tuple(pts[end]), angle + bend + rng.uniform(-0.2, 0.2), CELL * leaf * 0.22))


def cluster_cell(leaves, rng):
    # A short stem up from the bottom middle, then seven to ten twigs fanned
    # out of its top, three short ones filling the middle and two from the
    # stem's side, so the leaves fill a rough oval over the upper three
    # quarters of the cell with ragged gaps at its edge. No twig reaches past
    # the cell's side, so no leaf is cut off.
    cell = Image.new("RGBA", (CELL, CELL))
    surface = Image.new("RGBA", (CELL, CELL), FLAT[:3] + (0,))
    draw = [(ImageDraw.Draw(cell), (70, 56, 40, 255)), (ImageDraw.Draw(surface), FLAT)]
    hue = rng.uniform(0.85, 1.12)
    order = []
    lean = rng.uniform(-0.12, 0.12)
    top = np.array([CELL / 2 + np.sin(lean) * CELL * 0.2, CELL - 2 - np.cos(lean) * CELL * 0.2])
    for d, col in draw:
        d.line([(CELL / 2, CELL - 2), tuple(top)], fill=col, width=int(CELL * 0.03))
    n = int(rng.integers(7, 11))
    for k in range(n):
        a = lean + np.interp(k, [0, n - 1], [-1.2, 1.2]) + rng.uniform(-0.12, 0.12)
        reach = CELL * rng.uniform(0.38, 0.48)
        reach = min(reach, (CELL * 0.34 - abs(top[0] - CELL / 2)) / max(abs(np.sin(a)) + 0.1, 0.5))
        twig(draw, tuple(top), a, reach, CELL * 0.016, rng, order, 0, 0.5)
    for k in range(3):
        a = lean + rng.uniform(-0.6, 0.6)
        twig(draw, tuple(top), a, CELL * rng.uniform(0.2, 0.28), CELL * 0.012, rng, order, 1, 0.5)
    for side in (-1, 1):
        at = (CELL / 2 + np.sin(lean) * CELL * 0.1, CELL - 2 - np.cos(lean) * CELL * 0.1)
        twig(draw, at, lean + side * rng.uniform(0.9, 1.2), CELL * rng.uniform(0.2, 0.26), CELL * 0.012, rng, order, 1, 0.5)
    # Back to front: the inner and lower leaves, darker, first.
    mid = top + np.array([0.0, -CELL * 0.25])
    def light(base):
        r = np.linalg.norm((np.array(base) - mid) / (CELL * 0.42))
        up = 1.0 - base[1] / CELL
        return (0.68 + 0.36 * min(r, 1.0)) * (0.86 + 0.24 * up) * rng.uniform(0.92, 1.08)
    lit = [(light(b), b, a, l) for b, a, l in order]
    lit.sort(key=lambda x: x[0])
    for k, base, angle, length in lit:
        leaf = leaves[rng.integers(len(leaves))]
        shade = np.array([hue * rng.uniform(0.85, 1.1), rng.uniform(0.88, 1.1), 1.0], np.float32) * k
        # Out from the cluster's middle, more toward its rim: a dome.
        out = (np.array(base) - mid) / (CELL * 0.42)
        tilt = out * DOME / max(1.0, np.linalg.norm(out)) + TRNG.uniform(-TILT, TILT, 2)
        place(cell, leaf, base, angle, length, shade, surface, tilt)
    return cell, surface


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("leaves")
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    leaves = cut_leaves(args.leaves)
    atlas = Image.new("RGBA", (SIZE, SIZE))
    surface = Image.new("RGB", (SIZE, SIZE), FLAT[:3])
    for gy in range(GRID):
        for gx in range(GRID):
            cell, surf = cluster_cell(leaves, rng)
            atlas.paste(cell, (gx * CELL, gy * CELL))
            # The stored y runs up the image, as tree_leaf.gdshader reads it.
            # Flat wherever no leaf is, so mipmaps don't bend the rims.
            sa = np.asarray(surf).astype(np.float32)
            k = sa[..., 3:] / 255.0
            sa = sa[..., :3] * k + np.array(FLAT[:3], np.float32) * (1.0 - k)
            sa[..., 1] = 255.0 - sa[..., 1]
            sa = sa.round().astype(np.uint8)
            surface.paste(Image.fromarray(sa, "RGB"), (gx * CELL, gy * CELL))
    atlas = grade_atlas(atlas, SAT, GAIN)
    atlas.save(args.out)
    side = os.path.splitext(args.out)[0] + "_surface.png"
    surface.save(side)
    print("%d leaves -> %s, %s" % (len(leaves), args.out, side))


if __name__ == "__main__":
    main()

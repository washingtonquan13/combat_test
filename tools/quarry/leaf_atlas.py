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

    python -I tools/quarry/leaf_atlas.py <leaves.png> <out.png> [--seed N]
"""

import argparse

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

SIZE = 2048
GRID = 4
CELL = SIZE // GRID
SAT = 0.58
GAIN = 1.32


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
    # wide, so the mask is shrunk past it.
    a = np.asarray(Image.open(path).convert("RGBA"))
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
        leaves.append(Image.fromarray(rgba))
    return leaves


def place(canvas, leaf, base, angle, length, shade):
    # Pastes a leaf with its stalk end on `base`, pointing `angle` radians
    # clockwise from straight up, `length` pixels long.
    w, h = leaf.size
    k = length / h
    img = leaf.resize((max(2, int(w * k)), max(2, int(length))), Image.LANCZOS)
    arr = np.asarray(img).astype(np.float32)
    arr[..., :3] *= shade
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    rot = img.rotate(-np.degrees(angle), resample=Image.BICUBIC, expand=True)
    # The stalk end is the bottom middle of the unrotated leaf.
    off = np.array([0.0, img.size[1] / 2.0])
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
    col = (70, 56, 40, 255)
    for i in range(len(pts) - 1):
        w = np.interp(i, [0, len(pts) - 1], [width, width * 0.4])
        draw.line([tuple(pts[i]), tuple(pts[i + 1])], fill=col, width=max(1, int(round(w))))
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
    draw = ImageDraw.Draw(cell)
    hue = rng.uniform(0.85, 1.12)
    order = []
    lean = rng.uniform(-0.12, 0.12)
    top = np.array([CELL / 2 + np.sin(lean) * CELL * 0.2, CELL - 2 - np.cos(lean) * CELL * 0.2])
    draw.line([(CELL / 2, CELL - 2), tuple(top)], fill=(70, 56, 40, 255), width=int(CELL * 0.03))
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
        place(cell, leaf, base, angle, length, shade)
    return cell


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("leaves")
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    leaves = cut_leaves(args.leaves)
    atlas = Image.new("RGBA", (SIZE, SIZE))
    for gy in range(GRID):
        for gx in range(GRID):
            atlas.paste(cluster_cell(leaves, rng), (gx * CELL, gy * CELL))
    atlas = grade_atlas(atlas, SAT, GAIN)
    atlas.save(args.out)
    print("%d leaves -> %s" % (len(leaves), args.out))


if __name__ == "__main__":
    main()

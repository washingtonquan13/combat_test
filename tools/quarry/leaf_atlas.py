"""Builds a card atlas of leafy twigs from single-leaf scans.

Poly Haven's island tree ships eight loose leaves, which is right for a model
with one quad per leaf but far too many quads for a tree that has to draw at a
distance. This lays those leaves along drawn twigs, 4x4 cells to an atlas, so a
generated tree places a whole spray of leaves with one card, the way SpeedTree
cluster cards work.

Each cell's twig grows from the middle of its bottom edge up to the top, so the
card's base sits on the branch and it grows along the card's V axis.

    python -I tools/quarry/leaf_atlas.py <leaves.png> <out.png> [--seed N]
"""

import argparse

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

SIZE = 2048
GRID = 4
CELL = SIZE // GRID


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


def twig(draw, at, angle, length, width, rng, leaves_out, depth):
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
            twig(draw, pts[i], a + side * rng.uniform(0.55, 0.85), length * rng.uniform(0.45, 0.6), width * 0.6, rng, leaves_out, 1)
            continue
        leaves_out.append((tuple(pts[i]), a + side * rng.uniform(0.7, 1.3), CELL * rng.uniform(0.2, 0.27) * (1.0 - 0.2 * t)))
    end = len(pts) - 1
    leaves_out.append((tuple(pts[end]), angle + bend + rng.uniform(-0.2, 0.2), CELL * 0.22))


def twig_cell(leaves, rng):
    cell = Image.new("RGBA", (CELL, CELL))
    draw = ImageDraw.Draw(cell)
    hue = rng.uniform(0.85, 1.12)
    order = []
    twig(draw, (CELL / 2, CELL - 2), rng.uniform(-0.1, 0.1), CELL * 0.62, CELL * 0.022, rng, order, 0)
    rng.shuffle(order)
    for base, angle, length in order:
        leaf = leaves[rng.integers(len(leaves))]
        shade = np.array([hue * rng.uniform(0.85, 1.1), rng.uniform(0.88, 1.1), 1.0], np.float32)
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
            atlas.paste(twig_cell(leaves, rng), (gx * CELL, gy * CELL))
    atlas.save(args.out)
    print("%d leaves -> %s" % (len(leaves), args.out))


if __name__ == "__main__":
    main()

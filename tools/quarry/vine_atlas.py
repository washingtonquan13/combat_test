"""Draws a card atlas of ivy runs.

Each cell is a length of climbing stem with its leaves pressed flat, the way
ivy lies on rock: lobed leaves on short stalks, alternating sides, a dark
glossy green with pale veins. A generated vine lays these cards end to end
along its path, so the drawn stem continues from card to card.

Each cell's stem enters at the middle of its bottom edge and leaves through
the top, so a card's base sits on the vine and it grows along the card's V
axis, like the cells of leaf_atlas.py and fern_atlas.py. The bottom row is
older growth, darker with a purple cast.

    python -I tools/quarry/vine_atlas.py <out.png> [--seed N]
"""

import argparse

import numpy as np
from PIL import Image, ImageDraw

SIZE = 2048
GRID = 4
SS = 2
CELL = SIZE // GRID * SS


def leaf_outline(rng, lobes):
    # A palmate ivy leaf in its own frame: stalk at the origin, the middle
    # lobe along +y. Broad triangular lobes, shallow rounded sinuses and a
    # heart-shaped base.
    if lobes == 3:
        tips = [(0.0, 1.0), (-1.05, 0.78), (1.05, 0.78)]
    else:
        tips = [(0.0, 1.0), (-0.9, 0.84), (0.9, 0.84), (-1.85, 0.56), (1.85, 0.56)]
    tips = [(a + rng.uniform(-0.08, 0.08), l * rng.uniform(0.9, 1.06)) for a, l in tips]
    width = 1.05 if lobes == 3 else 0.82
    pts = []
    for th in np.linspace(-np.pi, np.pi, 200):
        r = 0.42
        for a, l in tips:
            d = abs((th - a + np.pi) % (2 * np.pi) - np.pi)
            r = max(r, l * max(0.0, 1.0 - d / width) ** 0.9)
        back = np.pi - abs(th)
        if back < 0.7:
            r *= 0.35 + 0.65 * (back / 0.7) ** 0.7
        pts.append((np.sin(th) * r, np.cos(th) * r + 0.12))
    return np.array(pts), tips


def draw_leaf(img, at, angle, size, col, rng):
    # Draws on its own layer so the blade can be shaded: darker at the stalk,
    # lighter toward the lobe tips, one half lit a little more than the other
    # as if the leaf were folded along its midrib.
    lobes = 5 if rng.random() < 0.75 else 3
    pts, tips = leaf_outline(rng, lobes)
    c, s = np.cos(angle), np.sin(angle)
    rot = np.array([[c, -s], [s, c]])
    # Image y runs down, so a leaf pointing "up" at angle 0 goes to -y.
    def to_img(q):
        return (q * np.array([1.0, -1.0])) @ rot.T * size + np.array(at)
    world = to_img(pts)
    x0, y0 = np.floor(world.min(0)).astype(int) - 2
    x1, y1 = np.ceil(world.max(0)).astype(int) + 2
    w, h = x1 - x0, y1 - y0
    mask = Image.new("L", (w, h))
    md = ImageDraw.Draw(mask)
    md.polygon([tuple(p - np.array([x0, y0])) for p in world], fill=255)
    veins = Image.new("L", (w, h))
    vd = ImageDraw.Draw(veins)
    vw = max(1, int(size * 0.03))
    base = to_img(np.array([[0.0, 0.12]]))[0] - np.array([x0, y0])
    for a, l in tips:
        tip = to_img(np.array([[np.sin(a) * l * 0.8, np.cos(a) * l * 0.8 + 0.12]]))[0] - np.array([x0, y0])
        vd.line([tuple(base), tuple(tip)], fill=255, width=vw)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    rel = np.stack([xx + x0 - at[0], yy + y0 - at[1]], -1) @ rot / size
    rel[..., 1] = -rel[..., 1]
    dist = np.sqrt(rel[..., 0] ** 2 + rel[..., 1] ** 2)
    shade = 0.72 + 0.38 * np.clip(dist, 0, 1) ** 0.8
    shade *= np.where(rel[..., 0] > 0, 1.0, rng.uniform(0.82, 0.92))
    rgb = col[None, None, :] * shade[..., None]
    v = np.asarray(veins, np.float32)[..., None] / 255.0
    rgb = rgb * (1 - 0.5 * v) + np.clip(col * 1.5 + 30, 0, 255) * 0.5 * v
    a = np.asarray(mask, np.float32)
    layer = np.dstack([np.clip(rgb, 0, 255), a]).astype(np.uint8)
    img.alpha_composite(Image.fromarray(layer, "RGBA"), (int(x0), int(y0)))


def run(rng, old):
    img = Image.new("RGBA", (CELL, CELL))
    draw = ImageDraw.Draw(img)
    if old:
        base = np.array([44, 52, 30], float)
        alt = np.array([70, 46, 52], float)
    else:
        base = np.array([40, 66, 28], float)
        alt = np.array([66, 96, 40], float)
    bend = rng.uniform(-0.25, 0.25)
    pts = []
    for t in np.linspace(0.0, 1.0, 48):
        x = CELL / 2 + np.sin(t * np.pi) * bend * CELL * 0.18
        pts.append(np.array([x, CELL - 1 - t * (CELL - 2)]))
    leaves = []
    nodes = rng.integers(7, 10)
    side = 1 if rng.random() < 0.5 else -1
    for k in range(nodes):
        t = 0.04 + 0.78 * (k + rng.uniform(0.25, 0.75)) / nodes
        i = int(t * (len(pts) - 1))
        root = pts[i]
        side = -side
        tg = pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]
        up = np.arctan2(tg[0], -tg[1])
        a = up + side * rng.uniform(0.7, 1.4)
        stalk = CELL * rng.uniform(0.05, 0.1)
        at = root + np.array([np.sin(a), -np.cos(a)]) * stalk
        size = CELL * rng.uniform(0.16, 0.22)
        young = rng.random()
        col = base + (alt - base) * young * (0.6 if old else 1.0)
        col = col * rng.uniform(0.85, 1.1)
        leaves.append((root, at, a + side * rng.uniform(-0.2, 0.35), size, col))
    # A small leaf at the very end, where new growth sits on young stems.
    if not old:
        leaves.append((pts[-4], pts[-4] + np.array([0, -CELL * 0.02]), bend * 0.5, CELL * 0.09, alt * 1.05))
    stem = (62, 52, 36, 255) if not old else (70, 58, 44, 255)
    for i in range(len(pts) - 1):
        draw.line([tuple(pts[i]), tuple(pts[i + 1])], fill=stem, width=max(1, int(CELL * 0.012)))
    for root, at, a, size, col in leaves:
        draw.line([tuple(root), tuple(at)], fill=stem, width=max(1, int(CELL * 0.007)))
    # Big leaves first, so the smaller young ones sit on top.
    for root, at, a, size, col in sorted(leaves, key=lambda l: -l[3]):
        draw_leaf(img, at, a, size, np.clip(col, 0, 255), rng)
    arr = np.asarray(img).astype(np.float32)
    noise = rng.normal(1.0, 0.06, arr.shape[:2])
    arr[..., :3] *= noise[..., None]
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    return img.resize((CELL // SS, CELL // SS), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=9)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    atlas = Image.new("RGBA", (SIZE, SIZE))
    for gy in range(GRID):
        for gx in range(GRID):
            atlas.paste(run(rng, gy == GRID - 1), (gx * SIZE // GRID, gy * SIZE // GRID))
    atlas.save(args.out)
    print("vine atlas -> %s" % args.out)


if __name__ == "__main__":
    main()

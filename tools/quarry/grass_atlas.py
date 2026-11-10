"""Draws a card atlas of grass tufts.

Each cell is a spray of tapered blades rising from its bottom edge, so a
card's base sits on the ground and the blades grow along its V axis, like the
cells of fern_atlas.py. A generated grass clump fans a few of these cards out
from one root, so thin blades are drawn into a texture that mips down
smoothly instead of being geometry thinner than a pixel.

Rows 0-1 are tall tufts: blades of mixed width, some bent over or snapped,
some seed stems with a head of spikelets, and a few dead straw blades.
Rows 2-3 are short carpet: many low blades rooted across the whole bottom
edge, for the wide clumps that cover the ground between the tall tufts.

Colour is near neutral except dead blades and seed heads, which are warm:
the grass shader multiplies this by the ground's own grass colour.

    python -I tools/quarry/grass_atlas.py <out.png> [--seed N]
"""

import argparse

import numpy as np
from PIL import Image, ImageDraw

SIZE = 2048
GRID = 4
SS = 2
CELL = SIZE // GRID * SS


def colour(value, warm):
    # warm 0 is neutral living grass; 1 is straw.
    rgb = np.array([1.0 + 0.04 * (1 - warm), 1.0, 0.94]) * (1 - warm) + np.array([1.5, 1.22, 0.62]) * warm
    return tuple(int(c) for c in np.clip(rgb * value * 255, 0, 255)) + (255,)


def centre_line(root, height, lean, droop, kink, steps):
    # Points along a blade: it leans and curves outward, and past `kink`
    # (if any) it folds over and hangs, the way a snapped or heavy blade does.
    pts = []
    x, y = root
    ang = lean * 0.35
    seg = height / steps
    for i in range(steps + 1):
        t = i / steps
        pts.append((x, y, t))
        bend = lean * 1.4 / steps + droop * t * 2.2 / steps
        if kink is not None and t > kink:
            bend += np.sign(lean if lean != 0 else 1) * 1.6 / steps
        ang += bend
        ang = float(np.clip(ang, -2.4, 2.4))
        x += np.sin(ang) * seg
        y -= np.cos(ang) * seg
    return pts


def blade(draw, pts, width, value, warm, rib=True):
    left, right = [], []
    n = len(pts)
    for i, (x, y, t) in enumerate(pts):
        a = pts[max(i - 1, 0)]
        b = pts[min(i + 1, n - 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        d = max(np.hypot(dx, dy), 1e-6)
        nx, ny = -dy / d, dx / d
        w = width * (1.0 - t) ** 0.7 * (0.65 + 0.35 * min(t * 6.0, 1.0))
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w, y - ny * w))
    for i in range(n - 1):
        t = (i + 0.5) / (n - 1)
        v = value * (0.45 + 0.65 * t ** 0.8)
        draw.polygon([left[i], left[i + 1], right[i + 1], right[i]], fill=colour(v, warm))
        # One half lit more than the other, as if folded along the midrib.
        draw.polygon([left[i], left[i + 1], (pts[i + 1][0], pts[i + 1][1]), (pts[i][0], pts[i][1])],
                     fill=colour(v * 1.1, warm))
    if rib and width > 4:
        draw.line([(p[0], p[1]) for p in pts[2:-3]], fill=colour(value * 0.8, warm), width=max(1, int(width * 0.3)))


def seed_stem(draw, rng, root, height, lean):
    # A thin wiry stem with a head of spikelets, warm and pale.
    pts = centre_line(root, height, lean, rng.uniform(0.0, 0.3), None, 24)
    warm = rng.uniform(0.3, 0.75)
    for i in range(len(pts) - 1):
        draw.line([pts[i][:2], pts[i + 1][:2]], fill=colour(0.75 + 0.2 * pts[i][2], warm), width=max(2, int(CELL * 0.004)))
    head = pts[int(len(pts) * 0.62):]
    kind = rng.integers(0, 2)
    for x, y, t in head:
        if kind == 0:
            # Spike: tight overlapping ovals.
            r = CELL * 0.008 * (1.2 - 0.5 * t)
            draw.ellipse([x - r, y - r * 1.8, x + r, y + r * 1.8], fill=colour(0.85 + rng.uniform(-0.1, 0.1), warm + 0.1))
        elif rng.random() < 0.5:
            # Panicle: spikelets hanging off short side branches.
            s = rng.choice([-1, 1])
            l = CELL * rng.uniform(0.02, 0.05) * (1.2 - t)
            ex, ey = x + s * l, y + l * 0.5
            draw.line([(x, y), (ex, ey)], fill=colour(0.8, warm), width=2)
            r = CELL * 0.006
            draw.ellipse([ex - r, ey - r * 1.6, ex + r, ey + r * 1.6], fill=colour(0.9, warm + 0.1))


def spray(rng, tall):
    img = Image.new("RGBA", (CELL, CELL))
    draw = ImageDraw.Draw(img)
    items = []
    count = rng.integers(36, 46) if tall else rng.integers(70, 90)
    for k in range(count):
        if tall:
            off = float(np.clip(rng.normal(0.0, 0.09), -0.22, 0.22))
            lean = float(np.clip(off * 2.6 + rng.normal(0.0, 0.18), -0.7, 0.7))
            h = CELL * rng.uniform(0.5, 0.95) * (1.0 - abs(lean) * 0.3)
        else:
            # Rooted across the whole bottom edge, so a wide card is solid.
            off = float(rng.uniform(-0.44, 0.44))
            lean = float(np.clip(off * 0.9 + rng.normal(0.0, 0.3), -0.8, 0.8))
            h = CELL * rng.uniform(0.28, 0.78) * (1.0 - abs(lean) * 0.25)
        root = (CELL * (0.5 + off), CELL - 2)
        # Keep the tip inside the cell.
        room = (CELL * 0.48 - abs(root[0] - CELL * 0.5)) / max(h, 1.0)
        if not tall:
            room = 0.9
        lean = float(np.clip(lean, -max(room, 0.05), max(room, 0.05)))
        w = CELL * (rng.uniform(0.009, 0.024) if rng.random() < 0.8 else rng.uniform(0.024, 0.032))
        dead = rng.random() < (0.08 if tall else 0.05)
        kink = rng.uniform(0.45, 0.8) if rng.random() < (0.18 if tall else 0.1) else None
        droop = rng.uniform(0.0, 0.6) if rng.random() < 0.4 else 0.0
        items.append((rng.random(), "blade", root, h, lean, w, dead, kink, droop))
    if tall:
        for k in range(rng.integers(0, 4)):
            off = float(rng.normal(0.0, 0.07))
            items.append((rng.random() * 0.6, "seed", (CELL * (0.5 + off), CELL - 2), CELL * rng.uniform(0.75, 0.97), off * 1.5 + rng.normal(0, 0.08)))
    # Painted back to front; later items sit in front and are lit more.
    for item in sorted(items, key=lambda b: b[0]):
        depth = item[0]
        if item[1] == "seed":
            seed_stem(draw, rng, item[2], item[3], item[4])
            continue
        _, _, root, h, lean, w, dead, kink, droop = item
        pts = centre_line(root, h, lean, droop, kink, 22)
        # Keep the folded part of a blade inside the cell.
        pts = [(min(max(x, 4), CELL - 4), max(y, 4), t) for x, y, t in pts]
        value = 0.55 + 0.4 * depth + rng.uniform(-0.05, 0.05)
        warm = rng.uniform(0.55, 0.85) if dead else rng.uniform(-0.03, 0.08)
        blade(draw, pts, w, value * (0.95 if dead else 1.0), warm)
    arr = np.asarray(img).astype(np.float32)
    noise = rng.normal(1.0, 0.04, arr.shape[:2])
    arr[..., :3] *= noise[..., None]
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    return img.resize((CELL // SS, CELL // SS), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    atlas = Image.new("RGBA", (SIZE, SIZE))
    for gy in range(GRID):
        for gx in range(GRID):
            atlas.paste(spray(rng, gy < 2), (gx * SIZE // GRID, gy * SIZE // GRID))
    atlas.save(args.out)
    print("grass atlas -> %s" % args.out)


if __name__ == "__main__":
    main()

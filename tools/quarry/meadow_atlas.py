"""Draws a card atlas of the small plants that grow among the grass.

Painted in full colour; unlike the grass atlas, the shader keeps it.

    row 0  clover patches, seen from above, centred in the cell
    row 1  weed rosettes (plantain, dandelion), from above, centred
    row 2  flowers from the side, rooted at the bottom edge:
           white, yellow, purple, blue
    row 3  dry stalks and seed heads from the side, rooted at the bottom

Rows 0-1 go on flat cards lying on the ground; rows 2-3 on upright crossed
cards, like the grass tufts.

    python -I tools/quarry/meadow_atlas.py <out.png> [--seed N]
"""

import argparse

import numpy as np
from PIL import Image, ImageDraw

SIZE = 2048
GRID = 4
SS = 2
CELL = SIZE // GRID * SS


def rgb(c, v=1.0):
    return tuple(int(x) for x in np.clip(np.array(c) * v, 0, 255)) + (255,)


def rot(pts, ang, at, size):
    c, s = np.cos(ang), np.sin(ang)
    m = np.array([[c, -s], [s, c]])
    return [tuple(p) for p in (np.array(pts) @ m.T) * size + np.array(at)]


def leaflet(draw, at, ang, size, col, rng):
    # A clover leaflet: a rounded heart with its notch at the tip and a
    # pale chevron across the middle.
    th = np.linspace(0, 2 * np.pi, 40)
    r = 0.5 + 0.12 * np.cos(th)
    pts = np.stack([np.sin(th) * r * 0.9, 0.5 + np.cos(th) * r * 0.85], 1)
    notch = np.abs(np.sin(th)) < 0.18
    pts[notch & (np.cos(th) > 0), 1] -= 0.12
    v = rng.uniform(0.85, 1.12)
    draw.polygon(rot(pts, ang, at, size), fill=rgb(col, v))
    half = pts.copy()
    half[:, 0] = np.minimum(half[:, 0], 0)
    draw.polygon(rot(half, ang, at, size), fill=rgb(col, v * 1.1))
    chev = [(-0.3, 0.55), (0.0, 0.35), (0.3, 0.55)]
    draw.line(rot(chev, ang, at, size), fill=rgb(col, v * 1.45), width=max(1, int(size * 0.07)))


def clover(rng, flowers):
    img = Image.new("RGBA", (CELL, CELL))
    draw = ImageDraw.Draw(img)
    base = np.array([62, 104, 40]) * rng.uniform(0.9, 1.1)
    n = rng.integers(14, 22)
    leaves = []
    for k in range(n):
        r = CELL * 0.33 * np.sqrt(rng.random())
        a = rng.random() * 2 * np.pi
        leaves.append((rng.random(), (CELL / 2 + np.cos(a) * r, CELL / 2 + np.sin(a) * r)))
    for depth, at in sorted(leaves):
        size = CELL * rng.uniform(0.055, 0.08)
        a0 = rng.random() * 2 * np.pi
        col = base * (0.75 + 0.35 * depth)
        for j in range(3):
            leaflet(draw, at, a0 + j * 2 * np.pi / 3, size, col, rng)
    for k in range(flowers):
        # White clover heads: a ball of tiny florets, pinkish at the base.
        r = CELL * 0.22 * np.sqrt(rng.random())
        a = rng.random() * 2 * np.pi
        cx, cy = CELL / 2 + np.cos(a) * r, CELL / 2 + np.sin(a) * r
        R = CELL * rng.uniform(0.035, 0.045)
        draw.ellipse([cx - R, cy - R, cx + R, cy + R], fill=rgb((200, 186, 170)))
        for f in range(40):
            fa, fr = rng.random() * 2 * np.pi, R * np.sqrt(rng.random()) * 0.9
            x, y = cx + np.cos(fa) * fr, cy + np.sin(fa) * fr
            q = R * 0.18
            draw.ellipse([x - q, y - q, x + q, y + q], fill=rgb((240, 238, 228), rng.uniform(0.9, 1.05)))
    return img


def plantain_leaf(draw, at, ang, length, width, col):
    # Broad oval leaf with a short stalk and three parallel veins.
    t = np.linspace(0, 1, 30)
    w = width * np.sin(np.clip((t - 0.2) / 0.8, 0, 1) * np.pi) ** 0.8 + width * 0.08 * (t < 0.2)
    left = np.stack([-w, t], 1)
    right = np.stack([w, t], 1)[::-1]
    pts = np.concatenate([left, right])
    draw.polygon(rot(pts, ang, at, length), fill=rgb(col))
    draw.polygon(rot(np.concatenate([left, np.stack([np.zeros_like(t), t], 1)[::-1]]), ang, at, length), fill=rgb(col, 1.1))
    for vx in (-0.5, 0.0, 0.5):
        vein = [(vx * width * np.sin(min(max((s - 0.2) / 0.8, 0), 1) * np.pi), s) for s in np.linspace(0.15, 0.95, 10)]
        draw.line(rot(vein, ang, at, length), fill=rgb(col, 1.35), width=max(1, int(length * 0.012)))


def dandelion_leaf(draw, at, ang, length, col, rng):
    # Long leaf with backward-pointing lobes along both edges.
    pts_l, pts_r = [], []
    for i in range(31):
        t = i / 30
        w = 0.06 + 0.1 * np.sin(np.clip(t, 0, 1) * np.pi) ** 0.6
        lobe = 0.75 + 0.25 * np.clip(np.sin(t * 5 * np.pi) * 1.5, -1, 1) if t > 0.2 else 0.6
        pts_l.append((-w * lobe, t))
        pts_r.append((w * lobe, t))
    pts = pts_l + pts_r[::-1]
    draw.polygon(rot(pts, ang, at, length), fill=rgb(col))
    draw.line(rot([(0, 0.05), (0, 0.95)], ang, at, length), fill=rgb(col, 1.4), width=max(1, int(length * 0.012)))


def rosette(rng, kind):
    img = Image.new("RGBA", (CELL, CELL))
    draw = ImageDraw.Draw(img)
    at = (CELL / 2, CELL / 2)
    if kind == "plantain":
        n = rng.integers(6, 9)
        base = np.array([66, 98, 42])
        for k in range(n):
            ang = k * 2 * np.pi / n + rng.uniform(-0.3, 0.3)
            col = base * rng.uniform(0.85, 1.15)
            plantain_leaf(draw, at, ang, CELL * rng.uniform(0.3, 0.42), rng.uniform(0.17, 0.24), col)
    else:
        n = rng.integers(8, 12)
        base = np.array([70, 104, 40])
        for k in range(n):
            ang = k * 2 * np.pi / n + rng.uniform(-0.25, 0.25)
            dandelion_leaf(draw, at, ang, CELL * rng.uniform(0.32, 0.45), base * rng.uniform(0.85, 1.15), rng)
        if kind == "dandelion_flower":
            # A flower head seen from above: dense yellow rays.
            R = CELL * 0.07
            for r in range(120):
                a = rng.random() * 2 * np.pi
                l = R * rng.uniform(0.5, 1.0)
                draw.line([at, (at[0] + np.cos(a) * l, at[1] + np.sin(a) * l)], fill=rgb((236, 188, 30), rng.uniform(0.85, 1.05)), width=int(CELL * 0.008))
            q = R * 0.3
            draw.ellipse([at[0] - q, at[1] - q, at[0] + q, at[1] + q], fill=rgb((210, 150, 20)))
    return img


def stem(draw, rng, root, height, lean, col, w):
    pts = []
    x, y = root
    ang = lean * 0.3
    steps = 20
    for i in range(steps + 1):
        pts.append((x, y))
        ang += lean * 0.7 / steps + rng.normal(0, 0.03)
        x += np.sin(ang) * height / steps
        y -= np.cos(ang) * height / steps
    draw.line(pts, fill=rgb(col), width=w)
    return pts


def side_leaf(draw, at, ang, length, col):
    t = np.linspace(0, 1, 16)
    w = 0.18 * np.sin(t * np.pi)
    pts = list(zip(-w, t)) + list(zip(w[::-1], t[::-1]))
    draw.polygon(rot(pts, ang, at, length), fill=rgb(col))


def bloom(draw, rng, at, kind, size):
    x, y = at
    if kind == "white":
        # Daisy-like: white rays round a yellow disc, tilted toward the viewer.
        for k in range(14):
            a = k * 2 * np.pi / 14
            ex, ey = x + np.cos(a) * size, y + np.sin(a) * size * 0.6
            draw.line([(x, y), (ex, ey)], fill=rgb((244, 242, 234), rng.uniform(0.9, 1.0)), width=int(size * 0.35))
        q = size * 0.32
        draw.ellipse([x - q, y - q * 0.7, x + q, y + q * 0.7], fill=rgb((226, 180, 40)))
    elif kind == "yellow":
        # Buttercup: five glossy round petals.
        for k in range(5):
            a = k * 2 * np.pi / 5 + 0.3
            cx, cy = x + np.cos(a) * size * 0.45, y + np.sin(a) * size * 0.3
            r = size * 0.42
            draw.ellipse([cx - r, cy - r * 0.8, cx + r, cy + r * 0.8], fill=rgb((246, 206, 36), rng.uniform(0.9, 1.05)))
        q = size * 0.18
        draw.ellipse([x - q, y - q, x + q, y + q], fill=rgb((190, 150, 30)))
    elif kind == "purple":
        # Knapweed / clover head: a tuft of fine purple florets on a dark cup.
        q = size * 0.45
        draw.ellipse([x - q, y - q * 0.2, x + q, y + q * 1.2], fill=rgb((70, 64, 38)))
        for k in range(36):
            a = -np.pi / 2 + rng.uniform(-1.2, 1.2)
            l = size * rng.uniform(0.5, 1.0)
            draw.line([(x, y), (x + np.cos(a) * l, y + np.sin(a) * l)], fill=rgb((168, 82, 176), rng.uniform(0.85, 1.1)), width=int(size * 0.14))
    else:
        # Speedwell / cornflower: small blue four-petalled flowers in a spray.
        for f in range(rng.integers(3, 6)):
            cx = x + rng.uniform(-1, 1) * size * 0.8
            cy = y + rng.uniform(-1, 1) * size * 0.6
            s = size * rng.uniform(0.35, 0.55)
            for k in range(4):
                a = k * np.pi / 2 + 0.4
                px, py = cx + np.cos(a) * s * 0.5, cy + np.sin(a) * s * 0.4
                draw.ellipse([px - s * 0.45, py - s * 0.4, px + s * 0.45, py + s * 0.4], fill=rgb((92, 120, 214), rng.uniform(0.9, 1.1)))
            draw.ellipse([cx - s * 0.15, cy - s * 0.15, cx + s * 0.15, cy + s * 0.15], fill=rgb((236, 236, 236)))


def flowers(rng, kind):
    img = Image.new("RGBA", (CELL, CELL))
    draw = ImageDraw.Draw(img)
    green = np.array([70, 104, 44])
    n = rng.integers(5, 8)
    for k in range(n):
        off = rng.normal(0, 0.12)
        root = (CELL * (0.5 + np.clip(off, -0.25, 0.25)), CELL - 2)
        h = CELL * rng.uniform(0.45, 0.85)
        pts = stem(draw, rng, root, h, float(np.clip(off * 1.2 + rng.normal(0, 0.15), -0.35, 0.35)), green * rng.uniform(0.8, 1.1), max(3, int(CELL * 0.008)))
        for j in range(rng.integers(1, 3)):
            at = pts[rng.integers(3, 9)]
            side_leaf(draw, at, rng.choice([-1, 1]) * rng.uniform(0.6, 1.2) + np.pi, CELL * rng.uniform(0.1, 0.16), green * rng.uniform(0.8, 1.1))
        bloom(draw, rng, pts[-1], kind, CELL * rng.uniform(0.05, 0.075))
    return img


def dry(rng, kind):
    img = Image.new("RGBA", (CELL, CELL))
    draw = ImageDraw.Draw(img)
    straw = np.array([186, 160, 104])
    n = rng.integers(5, 9)
    for k in range(n):
        off = rng.normal(0, 0.1)
        root = (CELL * (0.5 + np.clip(off, -0.3, 0.3)), CELL - 2)
        h = CELL * rng.uniform(0.6, 0.95)
        col = straw * rng.uniform(0.8, 1.1)
        pts = stem(draw, rng, root, h, off * 1.0 + rng.normal(0, 0.12), col, max(2, int(CELL * 0.006)))
        top = pts[-8:]
        if kind == 0:
            # Dock: rusty seed clusters in whorls up the top of the stem.
            for x, y in top:
                for s in (-1, 1):
                    r = CELL * 0.009
                    cx = x + s * CELL * rng.uniform(0.006, 0.02)
                    draw.ellipse([cx - r, y - r, cx + r, y + r], fill=rgb((122, 84, 56), rng.uniform(0.8, 1.1)))
        elif kind == 1:
            # Plantain spike: a narrow dark cylinder.
            draw.line(top, fill=rgb((98, 82, 56)), width=int(CELL * 0.022))
        elif kind == 2:
            # Feathery grass plume.
            for x, y in top:
                for j in range(5):
                    a = -np.pi / 2 + rng.uniform(-1.0, 1.0)
                    l = CELL * rng.uniform(0.02, 0.05)
                    draw.line([(x, y), (x + np.cos(a) * l, y + np.sin(a) * l * 0.6)], fill=rgb((214, 196, 150), rng.uniform(0.85, 1.05)), width=2)
        else:
            # Seed clock: a white puffball.
            x, y = pts[-1]
            R = CELL * 0.03
            for j in range(80):
                a = rng.random() * 2 * np.pi
                draw.line([(x, y), (x + np.cos(a) * R, y + np.sin(a) * R)], fill=rgb((236, 234, 226), rng.uniform(0.85, 1.0)), width=2)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    cells = [
        [lambda: clover(rng, 0), lambda: clover(rng, 1), lambda: clover(rng, 3), lambda: clover(rng, 0)],
        [lambda: rosette(rng, "plantain"), lambda: rosette(rng, "dandelion"), lambda: rosette(rng, "dandelion_flower"), lambda: rosette(rng, "plantain")],
        [lambda: flowers(rng, "white"), lambda: flowers(rng, "yellow"), lambda: flowers(rng, "purple"), lambda: flowers(rng, "blue")],
        [lambda: dry(rng, 0), lambda: dry(rng, 1), lambda: dry(rng, 2), lambda: dry(rng, 3)],
    ]
    atlas = Image.new("RGBA", (SIZE, SIZE))
    for gy in range(GRID):
        for gx in range(GRID):
            img = cells[gy][gx]()
            img = img.resize((CELL // SS, CELL // SS), Image.LANCZOS)
            atlas.paste(img, (gx * SIZE // GRID, gy * SIZE // GRID))
    atlas.save(args.out)
    print("meadow atlas -> %s" % args.out)


if __name__ == "__main__":
    main()

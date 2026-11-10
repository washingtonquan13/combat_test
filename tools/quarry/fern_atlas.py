"""Draws a card atlas of fern fronds.

Poly Haven's fern is modelled leaf by leaf with no alpha in its texture, so it
can't be cut into cards. This draws fronds instead: a rachis with alternating
pinnae, each pinna lobed into pinnules, 4x4 cells to an atlas. A generated
fern bends one card per frond.

Each cell's frond grows from the middle of its bottom edge up to the top, like
the twig cells of leaf_atlas.py, so the card's base sits at the fern's crown
and the frond runs along the card's V axis.

    python -I tools/quarry/fern_atlas.py <out.png> [--seed N]
"""

import argparse

import numpy as np
from PIL import Image, ImageDraw

SIZE = 2048
GRID = 4
SS = 2
CELL = SIZE // GRID * SS


def frond(rng, age):
    # One frond on a supersampled cell. `age` 0..1 browns it a little.
    img = Image.new("RGBA", (CELL, CELL))
    draw = ImageDraw.Draw(img)
    base_col = np.array([60, 86, 36], float) * rng.uniform(0.9, 1.12)
    tip_col = np.array([98, 120, 52], float) * rng.uniform(0.92, 1.08)
    brown = np.array([118, 92, 46], float)
    bend = rng.uniform(-0.18, 0.18)
    length = CELL * 0.97
    width = CELL * rng.uniform(0.26, 0.3)
    stipe = rng.uniform(0.08, 0.14)
    pts = []
    for t in np.linspace(0.0, 1.0, 64):
        x = CELL / 2 + np.sin(t * np.pi * 0.5) * bend * CELL * 0.5 * t
        pts.append((x, CELL - 2 - t * length))
    pts = np.array(pts)

    def at(t):
        f = t * (len(pts) - 1)
        i = min(int(f), len(pts) - 2)
        return pts[i] + (pts[i + 1] - pts[i]) * (f - i)

    def tangent(t):
        a, b = at(max(t - 0.01, 0.0)), at(min(t + 0.01, 1.0))
        d = b - a
        return d / np.linalg.norm(d)

    pairs = rng.integers(17, 21)
    pinnae = []
    for k in range(pairs):
        for side in (-1, 1):
            t = stipe + (1.0 - stipe) * (k + (0.5 if side > 0 else 0.0)) / pairs
            if t > 0.985:
                continue
            u = (t - stipe) / (1.0 - stipe)
            # Lanceolate outline: widest a third of the way up.
            span = width * (u ** 0.35) * ((1.0 - u) ** 0.8) * 1.75
            if span < CELL * 0.008:
                continue
            pinnae.append((t, u, side, span))
    # Lower pinnae drawn first, so the ones above overlap them.
    for t, u, side, span in pinnae:
        root = at(t)
        tg = tangent(t)
        normal = np.array([-tg[1], tg[0]]) * side
        ang = rng.uniform(1.15, 1.35) - 0.45 * u
        d = normal * np.cos(np.pi / 2 - ang) + tg * np.sin(np.pi / 2 - ang)
        d = d / np.linalg.norm(d)
        n = np.array([-d[1], d[0]])
        hw = span * rng.uniform(0.1, 0.12)
        lobes = max(3, int(span / (CELL * 0.014)))
        steps = lobes * 6
        left, right = [], []
        for i in range(steps + 1):
            s = i / steps
            curl = d * (1.0 - 0.06 * s * s) + tg * 0.18 * s * s
            mid = root + curl * span * s
            w = hw * (np.sin(np.pi * min(s * 1.1, 1.0)) ** 0.6)
            w *= 0.35 + 0.65 * abs(np.sin(s * lobes * np.pi)) ** 0.7
            left.append(tuple(mid + n * w))
            right.append(tuple(mid - n * w))
        shade = 0.82 + 0.18 * rng.random()
        col = base_col + (tip_col - base_col) * u
        col = col + (brown - col) * age * rng.uniform(0.3, 1.0) * u
        col = np.clip(col * shade, 0, 255)
        draw.polygon(left + right[::-1], fill=tuple(int(c) for c in col) + (255,))
        vein = np.clip(col * 0.72, 0, 255)
        draw.line([tuple(root), tuple(root + d * span * 0.92)], fill=tuple(int(c) for c in vein) + (255,), width=max(1, int(CELL * 0.0025)))
    rc = (78, 70, 38, 255)
    for i in range(len(pts) - 1):
        w = np.interp(i, [0, len(pts) - 1], [CELL * 0.011, CELL * 0.003])
        draw.line([tuple(pts[i]), tuple(pts[i + 1])], fill=rc, width=max(1, int(round(w))))
    # Fine speckle so the blades aren't flat fills.
    arr = np.asarray(img).astype(np.float32)
    noise = rng.normal(1.0, 0.07, arr.shape[:2])
    arr[..., :3] *= noise[..., None]
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    return img.resize((CELL // SS, CELL // SS), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=5)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    atlas = Image.new("RGBA", (SIZE, SIZE))
    for gy in range(GRID):
        for gx in range(GRID):
            age = 0.0 if gy < 3 else rng.uniform(0.4, 0.8)
            atlas.paste(frond(rng, age), (gx * SIZE // GRID, gy * SIZE // GRID))
    atlas.save(args.out)
    print("fern atlas -> %s" % args.out)


if __name__ == "__main__":
    main()

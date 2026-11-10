"""Draws a card atlas of grass tufts.

Each cell is a spray of tapered blades rising from the middle of its bottom
edge, so a card's base sits on the ground and the blades grow along its V
axis, like the cells of fern_atlas.py. A generated grass clump fans a few of
these cards out from one root, so thin blades are drawn into a texture that
mips down smoothly instead of being geometry thinner than a pixel.

Colour is near neutral: the grass shader tints it with the ground's own grass
colour, so the texture only carries each blade's shading, darker at the root
and behind, lighter toward the tip.

    python -I tools/quarry/grass_atlas.py <out.png> [--seed N]
"""

import argparse

import numpy as np
from PIL import Image, ImageDraw

SIZE = 2048
GRID = 4
SS = 2
CELL = SIZE // GRID * SS


def blade(draw, rng, root, height, lean, width, value, hue):
    # A tapered blade, curved by its lean and drooping a little at the tip.
    steps = 18
    left, right, mid = [], [], []
    for i in range(steps + 1):
        t = i / steps
        x = root[0] + lean * height * (t * t * 0.85 + 0.15 * t)
        y = root[1] - height * (t - 0.05 * abs(lean) * t * t)
        w = width * (1.0 - t) ** 0.75 * (0.6 + 0.4 * min(t * 6.0, 1.0))
        # The normal of the centre line, so the blade keeps its width as it bends.
        dx = lean * height * (2.0 * t * 0.85 + 0.15)
        dy = -height * (1.0 - 0.1 * abs(lean) * t)
        n = np.array([-dy, dx]) / max(np.hypot(dx, dy), 1e-6)
        c = np.array([x, y])
        left.append(tuple(c + n * w))
        right.append(tuple(c - n * w))
        mid.append(tuple(c))
    for i in range(steps):
        # Shade segment by segment: dark in the tuft's heart, light at the tip.
        t = (i + 0.5) / steps
        v = value * (0.42 + 0.68 * t ** 0.8)
        col = np.clip(np.array([v * (1.0 + hue), v, v * (1.0 - hue * 0.6)]) * 255, 0, 255)
        draw.polygon([left[i], left[i + 1], right[i + 1], right[i]], fill=tuple(int(c) for c in col) + (255,))
    rib = np.clip(np.array([value * 0.8 * (1.0 + hue), value * 0.8, value * 0.76]) * 255, 0, 255)
    draw.line(mid[2:-3], fill=tuple(int(c) for c in rib) + (255,), width=max(1, int(width * 0.35)))


def tuft(rng, tall):
    img = Image.new("RGBA", (CELL, CELL))
    draw = ImageDraw.Draw(img)
    count = rng.integers(40, 52)
    blades = []
    for k in range(count):
        # Roots bunched at the middle; outer blades lean out further.
        off = np.clip(rng.normal(0.0, 0.09), -0.22, 0.22)
        root = (CELL * (0.5 + off), CELL - 2)
        lean = np.clip(off * 2.6 + rng.normal(0.0, 0.15), -0.6, 0.6)
        h = CELL * (rng.uniform(0.55, 0.97) if tall else rng.uniform(0.3, 0.8)) * (1.0 - abs(lean) * 0.35)
        # Keep the tip inside the cell, so no blade is cut off at its edge.
        room = (CELL * 0.48 - abs(root[0] - CELL * 0.5)) / max(h, 1.0)
        lean = float(np.clip(lean, -room, room))
        w = CELL * rng.uniform(0.011, 0.02)
        # Blades drawn later sit in front, so they are lit more.
        depth = rng.random()
        blades.append((depth, root, h, lean, w))
    for depth, root, h, lean, w in sorted(blades, key=lambda b: b[0]):
        value = 0.55 + 0.4 * depth + rng.uniform(-0.05, 0.05)
        hue = rng.uniform(-0.02, 0.05)
        blade(draw, rng, root, h, lean, w, value, hue)
    arr = np.asarray(img).astype(np.float32)
    noise = rng.normal(1.0, 0.05, arr.shape[:2])
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
            # The top row is taller.
            atlas.paste(tuft(rng, gy == 0), (gx * SIZE // GRID, gy * SIZE // GRID))
    atlas.save(args.out)
    print("grass atlas -> %s" % args.out)


if __name__ == "__main__":
    main()

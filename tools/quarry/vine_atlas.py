"""Builds a card atlas of ivy runs from scanned leaves.

Each cell is a length of climbing stem with its leaves pressed flat, the way
ivy lies on rock: lobed leaves on short stalks, alternating sides. A generated
vine lays these cards end to end along its path, so the stem continues from
card to card.

Each cell's stem enters at the middle of its bottom edge and leaves through
the top, so a card's base sits on the vine and it grows along the card's V
axis, like the cells of leaf_atlas.py and fern_atlas.py. The bottom row is
older growth, darker with a purple cast.

The leaves are ambientCG's LeafSet017 and LeafSet029 (CC0), kept in
assets/level/quarry/foliage/ivy_scans. The layout is ours: the stem and
stalks are drawn, and each leaf is a scan set down turned and scaled, with
its normal and roughness maps carried along. Two files come out:

    <out>.png           colour and cut-out
    <out>_surface.png   R, G: normal x, y (y up the image)   B: roughness

    python -I tools/quarry/vine_atlas.py <out.png> [--scans DIR] [--seed N]
"""

import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

SIZE = 2048
GRID = 4
SS = 2
CELL = SIZE // GRID * SS

# name, quarter turns anticlockwise that bring the leaf tips to the top, and
# the leaves (in reading order) that are yellowed or spotted.
SETS = [("LeafSet017", 0, ()), ("LeafSet029", 1, (7, 8))]
STEM_ROUGH = 0.85


def load_leaves(scans):
    # Every leaf of both sets, cut out, tip up, with the point its stalk
    # joins it. Each is a dict of float arrays: rgb 0..255, a 0..1, n (x, y
    # in image axes, y down), r 0..1.
    fresh, worn = [], []
    for name, turns, tired in SETS:
        def load(kind, mode):
            im = Image.open(os.path.join(scans, "%s_2K-JPG_%s.jpg" % (name, kind))).convert(mode)
            return np.rot90(np.asarray(im, np.float32), turns)
        rgb = load("Color", "RGB")
        a = load("Opacity", "L") / 255.0
        r = load("Roughness", "L") / 255.0
        n = load("NormalGL", "RGB")[..., :2] / 127.5 - 1.0
        # To image axes, then the same turn the pixels took.
        n = np.stack([n[..., 0], -n[..., 1]], -1)
        for _ in range(turns):
            n = np.stack([n[..., 1], -n[..., 0]], -1)
        lab, _ = ndimage.label(a > 0.5)
        boxes = [(i + 1, sl) for i, sl in enumerate(ndimage.find_objects(lab)) if (lab[sl] == i + 1).sum() > 20000]
        # Reading order of the scan as published: undo the turn to sort.
        def key(b):
            y, x = b[1][0].start, b[1][1].start
            if turns:
                y, x = x, -y
            return (round(y / 500.0), x)
        for order, (idx, sl) in enumerate(sorted(boxes, key=key)):
            m = (lab[sl] == idx)
            m = ndimage.binary_fill_holes(m) & (a[sl] > 0.0)
            leaf = {"rgb": rgb[sl], "a": a[sl] * m, "n": n[sl], "r": r[sl]}
            h, w = m.shape
            # A scanned leaf lay curled and tilted on the glass; a card on a
            # wall lit that way reads as a dent. The whole-leaf tilt goes and
            # the broad curl is halved; veins and blisters stay.
            wt = leaf["a"]
            sig = 0.08 * max(h, w)
            den = np.maximum(ndimage.gaussian_filter(wt, sig), 1e-3)
            flat = np.empty_like(leaf["n"])
            for k in range(2):
                ch = leaf["n"][..., k]
                broad = ndimage.gaussian_filter(ch * wt, sig) / den
                tilt = float((ch * wt).sum() / wt.sum())
                flat[..., k] = (ch - broad) + 0.5 * (broad - tilt)
            leaf["n"] = flat
            cols = np.arange(w)
            cx = int((m.sum(0) * cols).sum() / m.sum())
            # The stalk joins at the top of the notch in the leaf's base.
            band = range(max(0, cx - w // 8), min(w, cx + w // 8))
            foot = [(np.nonzero(m[:, x])[0].max(), x) for x in band if m[:, x].any()]
            ay, ax = min(foot)
            leaf["anchor"] = (float(ax), float(ay))
            leaf["h"] = float(ay - np.nonzero(m.any(1))[0].min())
            (worn if order in tired else fresh).append(leaf)
    return fresh, worn


def grade(leaf, col, own):
    # The scan's detail in the colour the run wants: `own` of the leaf's own
    # hue is kept, the rest follows col.
    rgb = leaf["rgb"]
    w = leaf["a"][..., None]
    mean = (rgb * w).sum((0, 1)) / w.sum()
    lum = rgb @ np.array([0.3, 0.55, 0.15], np.float32)
    mlum = float(mean @ np.array([0.3, 0.55, 0.15]))
    clum = float(col @ np.array([0.3, 0.55, 0.15]))
    kept = rgb * (clum / mlum)
    toned = col[None, None, :] * (lum / mlum)[..., None]
    return kept * own + toned * (1.0 - own)


class Cell:
    def __init__(self):
        self.rgb = np.zeros((CELL, CELL, 3), np.float32)
        self.a = np.zeros((CELL, CELL), np.float32)
        self.n = np.zeros((CELL, CELL, 2), np.float32)
        self.r = np.full((CELL, CELL), STEM_ROUGH, np.float32)

    def lines(self, segs, col):
        mask = Image.new("L", (CELL, CELL))
        d = ImageDraw.Draw(mask)
        for p, q, w in segs:
            d.line([tuple(p), tuple(q)], fill=255, width=w)
        m = np.asarray(mask.filter(ImageFilter.GaussianBlur(0.8)), np.float32) / 255.0
        self.rgb = self.rgb * (1 - m[..., None]) + np.array(col, np.float32) * m[..., None]
        self.a = np.maximum(self.a, m)

    def stamp(self, leaf, rgb, at, angle, length, flip):
        # Sets the leaf down with its stalk point on `at`, its tip `length`
        # away along `angle` (0 up the image, turning clockwise). A leaf that
        # would cross the cell's edge is made smaller until it fits: a card
        # ends there, and a leaf cut straight across shows.
        c, sn = np.cos(angle), np.sin(angle)
        fx = -1.0 if flip else 1.0
        h, w = leaf["a"].shape
        ax, ay = leaf["anchor"]
        corners = np.array([[0, 0], [w, 0], [0, h], [w, h]], np.float32) - [ax, ay]
        corners[:, 0] *= fx
        for _ in range(8):
            s = length / leaf["h"]
            out = corners @ np.array([[c, sn], [-sn, c]]) * s + at
            x0, y0 = np.floor(out.min(0)).astype(int) - 1
            x1, y1 = np.ceil(out.max(0)).astype(int) + 1
            if x0 >= 0 and y0 >= 0 and x1 <= CELL and y1 <= CELL:
                break
            length *= 0.88
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, CELL), min(y1, CELL)
        if x1 <= x0 or y1 <= y0:
            return
        yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float32)
        dx, dy = (xx - at[0]) / s, (yy - at[1]) / s
        sx = (c * dx + sn * dy) * fx + ax
        sy = -sn * dx + c * dy + ay
        coords = [sy, sx]
        # Shrinking: blur first by the shrink so thin veins don't alias.
        blur = max(0.0, 0.5 / s - 0.5)

        def take(arr):
            if blur > 0.0:
                arr = ndimage.gaussian_filter(arr, blur)
            return ndimage.map_coordinates(arr, coords, order=1, mode="constant", cval=0.0)

        a = take(leaf["a"])
        col = np.stack([take(rgb[..., k] * leaf["a"]) for k in range(3)], -1)
        nx, ny = take(leaf["n"][..., 0] * leaf["a"]) * fx, take(leaf["n"][..., 1] * leaf["a"])
        rough = take(leaf["r"] * leaf["a"])
        safe = np.maximum(a, 1e-4)
        col /= safe[..., None]
        nrm = np.stack([c * nx - sn * ny, sn * nx + c * ny], -1) / safe[..., None]
        rough /= safe
        # What lies under a leaf sits in its shade.
        shade = ndimage.gaussian_filter(a, CELL * 0.006)
        sl = (slice(y0, y1), slice(x0, x1))
        self.rgb[sl] *= (1.0 - 0.45 * shade)[..., None]
        k = a[..., None]
        self.rgb[sl] = self.rgb[sl] * (1 - k) + col * k
        self.n[sl] = self.n[sl] * (1 - k) + nrm * k
        self.r[sl] = self.r[sl] * (1 - a) + rough * a
        self.a[sl] = np.maximum(self.a[sl], a)


def run(rng, old, fresh, worn):
    cell = Cell()
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
        size = CELL * rng.uniform(0.18, 0.25)
        young = rng.random()
        col = base + (alt - base) * young * (0.6 if old else 1.0)
        col = col * rng.uniform(0.85, 1.1)
        pool = worn if (old and rng.random() < 0.3) else fresh
        leaves.append((root, at, a + side * rng.uniform(-0.2, 0.35), size, col, pool[rng.integers(len(pool))]))
    # A small leaf at the very end, where new growth sits on young stems.
    if not old:
        leaves.append((pts[-8], pts[-8] + np.array([0, -CELL * 0.02]), bend * 0.5, CELL * 0.1, alt * 1.05, fresh[rng.integers(len(fresh))]))
    stem = (62, 52, 36) if not old else (70, 58, 44)
    segs = [(pts[i], pts[i + 1], max(1, int(CELL * 0.012))) for i in range(len(pts) - 1)]
    segs += [(l[0], l[1], max(1, int(CELL * 0.007))) for l in leaves]
    cell.lines(segs, stem)
    grain = ndimage.gaussian_filter(rng.normal(0.0, 1.0, (CELL, CELL)), 3.0)
    cell.rgb *= (1.0 + 0.35 * grain / np.abs(grain).max())[..., None].astype(np.float32)
    # Big leaves first, so the smaller young ones sit on top.
    for root, at, a, size, col, leaf in sorted(leaves, key=lambda l: -l[3]):
        tired = any(leaf is w for w in worn)
        rgb = grade(leaf, np.clip(col, 0, 255).astype(np.float32), 0.45 if tired else 0.3)
        cell.stamp(leaf, rgb, at, a, size, rng.random() < 0.5)
    return cell


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--scans", default=os.path.join(os.path.dirname(__file__), "..", "..", "assets", "level", "quarry", "foliage", "ivy_scans"))
    ap.add_argument("--seed", type=int, default=9)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    fresh, worn = load_leaves(args.scans)
    print("leaves: %d fresh, %d worn" % (len(fresh), len(worn)))
    atlas = Image.new("RGBA", (SIZE, SIZE))
    surface = Image.new("RGB", (SIZE, SIZE))
    small = (CELL // SS, CELL // SS)
    for gy in range(GRID):
        for gx in range(GRID):
            c = run(rng, gy == GRID - 1, fresh, worn)
            rgba = np.dstack([np.clip(c.rgb, 0, 255), np.clip(c.a, 0, 1) * 255]).astype(np.uint8)
            # Image y runs down; the normal's y is stored running up.
            surf = np.dstack([c.n[..., 0] * 0.5 + 0.5, -c.n[..., 1] * 0.5 + 0.5, c.r])
            surf = (np.clip(surf, 0, 1) * 255).astype(np.uint8)
            at = (gx * SIZE // GRID, gy * SIZE // GRID)
            atlas.paste(Image.fromarray(rgba, "RGBA").resize(small, Image.LANCZOS), at)
            surface.paste(Image.fromarray(surf, "RGB").resize(small, Image.LANCZOS), at)
    atlas.save(args.out)
    side = os.path.splitext(args.out)[0] + "_surface.png"
    surface.save(side)
    print("vine atlas -> %s, %s" % (args.out, side))


if __name__ == "__main__":
    main()

"""Draws the card atlas of grass tufts.

The atlas is 8 x 5 cells, each 256 px wide and 512 px tall. Rows 0-3 are
grass sprays, one tuft each; column 7 of them is all straw. A grass patch
(`_fan_patch()` in bake_goblin_quarry.gd) draws a spray on each twisted
ribbon of a tuft, the way BG3's Green_Short_A / Long_A sprays are built.
Row 4 is the weed row: columns 0-1 dandelion and 2-3 plantain leaves (flat
stars), 4-5 clover (leaf in the cell's top half, stem in u 0.46-0.54 of the
bottom half), 6-7 seed stalks (between u 0.3 and 0.7).

A tuft is a spray of separate blades, never a slab. Each blade roots near
the bottom edge, spread across the base, and runs to a tip spread wider
still, at a height between half and all of the cell, so the top of the
cell is ragged blade tips with background between them and the base is
blades crossing, not a solid band. A solid lower half rendered as a plate
with straight edges on the card (change 6's third atlas: half of its lower
windows were over 85% opaque and the top fifth was empty). A tuft that fans
out of one point and is fullest at the top reads as a fern frond (change
6's first atlas did).

The shading is baked dark to light: blades are painted back to front, back
ones darker, and each blade darkens a little toward its root. The darkening
is kept shallow (AO 0.8 at the root): the grass shader adds its own near
the camera.

Rows 0-1 are long tufts (cards about 0.7 m tall and 0.29 m wide): thin
blades of mixed height, some bent over or snapped, some seed stems with a
head of spikelets, a few dead straw blades. Rows 2-3 are short tufts (cards
about 0.35 m tall and 0.4 m wide): denser, slightly broader blades. Each
row type is drawn at its card's shape (width to height) and then squeezed
into the cell, so a blade is not stretched on the card.

Colour is near neutral except dead blades and seed heads, which are warm:
the grass shader multiplies this by the ground's own grass colour.

Prints the opaque share of the card (texels with alpha >= 128 inside the
pentagon) per row type and overall, and the cover and brightness of five
bands from top to bottom.

    python -I tools/quarry/grass_atlas.py <out.png> [--seed N]
"""

import argparse

import numpy as np
from PIL import Image, ImageDraw

SIZE = 2048
COLS = 8
ROWS = 4
# Row 4, under the grass rows, holds weed leaves: the atlas is 8 x 5 cells.
WEED_ROW = 4
SS = 2
CELL_W = SIZE // COLS
CELL_H = SIZE // ROWS
HEIGHT = CELL_H * (ROWS + 1)
# The fan card in the cell's UV (V down from the top): root (0.5, 1), side
# points (FAN_U0, FAN_VM) and (1 - FAN_U0, FAN_VM), top corners (0, 0) and
# (1, 0). Keep in step with FAN_U0 / FAN_VM in bake_goblin_quarry.gd.
FAN_U0 = 0.03
FAN_VM = 0.9
# BG3's spray ribbon (read from IP_Vegetation_Grass_Wild_Green_Long_A): one
# root point, then left/right edge pairs out along the spray, as (v, half
# width in u). Keep in step with RIBBON in bake_goblin_quarry.gd.
RIBBON = [(1.0, 0.0), (0.66, 0.26), (0.33, 0.46), (0.0, 0.5)]
# Card width over height, the mean of each card type's range in _fan_patch().
ASPECT_LONG = 0.5
ASPECT_SHORT = 0.5
# How a tuft is drawn. Blade widths are half-widths as a share of the card's
# height; counts are per tuft.
P = {
    "count_long": (12, 18), "count_short": (11, 16),
    "w_long": (0.011, 0.018), "w_short": (0.014, 0.022),
    "root_sd": 0.4, "tip_sd_long": 0.3, "tip_sd_short": 0.3,
    "hf_lo": 0.5, "hf_hi": 0.99, "hf_pow": 0.6,
    "ao": 0.8,
}


def fan(w, h, inset=0.0):
    # The card's outline in pixels, optionally pulled in toward its middle.
    pts = [(0.5 - hw, v) for v, hw in RIBBON] + [(0.5 + hw, v) for v, hw in RIBBON[::-1]]
    out = []
    for u, v in pts:
        u = 0.5 + (u - 0.5) * (1.0 - inset)
        v = v + inset * 0.3 * (1.0 - v)
        out.append((u * w, v * h))
    return out


def inside(poly, x, y):
    # Even-odd test.
    hit = False
    n = len(poly)
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % n]
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            hit = not hit
    return hit


def colour(value, warm):
    # warm 0 is neutral living grass; 1 is straw.
    rgb = np.array([1.0 + 0.06 * (1 - warm), 1.0, 0.88]) * (1 - warm) + np.array([1.5, 1.22, 0.62]) * warm
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


def aim(root, target, steps):
    # The lean and height whose curved centre line ends at `target`.
    dx, dy = target[0] - root[0], root[1] - target[1]
    want = np.arctan2(dx, dy)
    dist = np.hypot(dx, dy)
    lean, height = want / 1.05, dist
    for _ in range(4):
        x, y, _t = centre_line(root, height, lean, 0.0, None, steps)[-1]
        got = np.arctan2(x - root[0], root[1] - y)
        lean += want - got
        height *= dist / max(np.hypot(x - root[0], root[1] - y), 1e-6)
    return float(np.clip(lean, -1.3, 1.3)), height


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


def seed_stem(draw, rng, root, target, scale):
    # A thin wiry stem with a head of spikelets, warm and pale.
    lean, height = aim(root, target, 24)
    pts = centre_line(root, height, lean, 0.0, None, 24)
    warm = rng.uniform(0.3, 0.75)
    for i in range(len(pts) - 1):
        draw.line([pts[i][:2], pts[i + 1][:2]], fill=colour(0.75 + 0.2 * pts[i][2], warm), width=max(2, int(scale * 0.004)))
    head = pts[int(len(pts) * 0.62):]
    kind = rng.integers(0, 2)
    for x, y, t in head:
        if kind == 0:
            # Spike: tight overlapping ovals.
            r = scale * 0.008 * (1.2 - 0.5 * t)
            draw.ellipse([x - r, y - r * 1.8, x + r, y + r * 1.8], fill=colour(0.85 + rng.uniform(-0.1, 0.1), warm + 0.1))
        elif rng.random() < 0.5:
            # Panicle: spikelets hanging off short side branches.
            s = rng.choice([-1, 1])
            l = scale * rng.uniform(0.02, 0.04) * (1.2 - t)
            ex, ey = x + s * l, y + l * 0.5
            draw.line([(x, y), (ex, ey)], fill=colour(0.8, warm), width=2)
            r = scale * 0.006
            draw.ellipse([ex - r, ey - r * 1.6, ex + r, ey + r * 1.6], fill=colour(0.9, warm + 0.1))


def half_width(v):
    # Half the card's width at height v (0 top, 1 root), as a share of it.
    vs = [r[0] for r in RIBBON][::-1]
    hs = [r[1] for r in RIBBON][::-1]
    return float(np.interp(v, vs, hs))


def arc(root, ang, length, droop, steps=24):
    # A blade's centre line: it leaves the root at `ang` off vertical and
    # curves further the same way toward its tip by `droop`.
    pts = []
    x, y = root
    a = ang
    seg = length / steps
    for i in range(steps + 1):
        t = i / steps
        pts.append((x, y, t))
        a += droop * 2.0 * t / steps
        x += np.sin(a) * seg
        y -= np.cos(a) * seg
    return pts


def tuft(rng, tall, dry_all=False):
    # A spray the way BG3 draws one (IP_Vegetation_Grass_Wild_Green_A, read
    # from the game in the grass study): 15-30 hair-thin blades fanning out of
    # one root point at the bottom middle, spread about +-35 degrees and
    # leaning mostly one way, arching over toward their tips, of every length
    # from a third of the card to all of it. A few thin dry strands and, on
    # long tufts, a seed stem. About a third of the card is opaque; the rest
    # is gaps. Colour varies blade to blade (yellow-green, blue-green, olive,
    # tan) around neutral, since the shader multiplies by the ground's grass.
    h = CELL_H * SS
    w = int(round(h * (ASPECT_LONG if tall else ASPECT_SHORT)))
    img = Image.new("RGBA", (w, h))
    draw = ImageDraw.Draw(img)
    root = (w * 0.5, h * 0.985)
    items = []
    count = rng.integers(*P["count_long" if tall else "count_short"])
    side = rng.choice([-1.0, 1.0])
    for k in range(count):
        # Angle off vertical at the root, leaning more to one side.
        ang = float(np.clip(rng.normal(side * 0.05, 0.2), -0.45, 0.45))
        length = h * (0.45 + 0.53 * rng.random() ** 0.5)
        # Arch: the blade curves further the way it leans, more if it is long.
        droop = np.sign(ang if abs(ang) > 0.05 else side) * rng.uniform(0.1, 0.5) * (length / h)
        dry = dry_all or rng.random() < 0.15
        lo, hi = P["w_long" if tall else "w_short"]
        width = rng.uniform(lo, hi) * h * (0.6 if dry else 1.0)
        items.append((rng.random(), "blade", ang, length, droop, width, dry))
    if tall:
        for k in range(rng.integers(0, 2)):
            target = (w * (0.5 + float(rng.normal(0.0, 0.18))), h * rng.uniform(0.02, 0.1))
            items.append((rng.random() * 0.6, "seed", target))
    for item in sorted(items, key=lambda b: b[0]):
        depth = item[0]
        if item[1] == "seed":
            seed_stem(draw, rng, root, item[2], h * 0.5)
            continue
        _, _, ang, length, droop, width, dry = item
        # A blade stays inside the card, so the card's outline is never drawn:
        # one that would leave it is swung in and straightened until it fits.
        for tries in range(12):
            pts = arc(root, ang, length, droop)
            if all(abs(px / w - 0.5) <= half_width(py / h) * 0.97 and py > 0 for px, py, _t in pts):
                break
            ang *= 0.85
            droop *= 0.8
            length *= 0.97
        # Back blades darker, but not by much: patches overlap 6-8 tufts, so
        # more back blades show than on one tuft alone.
        value = 0.53 + 0.5 * depth + rng.uniform(-0.08, 0.08)
        if dry:
            warm = rng.uniform(0.5, 0.95)
        else:
            warm = rng.choice([rng.uniform(-0.12, -0.03), rng.uniform(-0.03, 0.1), rng.uniform(0.12, 0.3)], p=[0.3, 0.5, 0.2])
        blade(draw, pts, width, value, warm, rib=True)
    # Dead litter at the root: short brown strands lying across the base.
    for k in range(rng.integers(6, 12)):
        x = w * (0.5 + rng.normal(0.0, 0.08))
        y = h * rng.uniform(0.86, 0.97)
        a = rng.uniform(-1.4, 1.4)
        l = h * rng.uniform(0.04, 0.1)
        pts = arc((x, y), a, l, rng.uniform(-0.4, 0.4), steps=8)
        if all(abs(px / w - 0.5) <= half_width(py / h) * 0.97 for px, py, _t in pts):
            blade(draw, pts, h * 0.006, rng.uniform(0.6, 0.85), rng.uniform(0.7, 1.0), rib=False)
    mask = Image.new("L", (w, h))
    ImageDraw.Draw(mask).polygon(fan(w, h), fill=255)
    arr = np.asarray(img).astype(np.float32)
    arr[..., 3] *= np.asarray(mask).astype(np.float32) / 255.0
    up = 1.0 - np.arange(h, dtype=np.float32) / h
    ao = P["ao"] + (1.0 - P["ao"]) * np.clip(up / 0.4, 0.0, 1.0)
    arr[..., :3] *= ao[:, None, None]
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    return img.resize((CELL_W, CELL_H), Image.LANCZOS)


def leaf(rng, kind):
    # One weed leaf, upright from its stalk at the bottom middle, in full
    # colour: a weed card lies nearly flat in a rosette and keeps this colour
    # (the grass shader's weed cards). Kinds: 0 dandelion (toothed lobes),
    # 1 plantain (ribbed lance), 2 dock (broad oval, wavy), 3 small round.
    h = CELL_H * SS
    w = CELL_W * SS
    img = Image.new("RGBA", (w, h))
    draw = ImageDraw.Draw(img)
    base = np.array([0.36, 0.5, 0.2]) * rng.uniform(0.75, 1.05)
    base = base + np.array([0.04, 0.0, -0.02]) * rng.normal(0.0, 1.0)
    stalk = 0.06 if kind != 3 else 0.25
    length = rng.uniform(0.82, 0.96)
    top = 1.0 - length
    n = 60
    left, right, mid = [], [], []
    for i in range(n + 1):
        t = i / n
        v = 1.0 - (stalk + (1.0 - stalk - top) * t) if t > 0 else 1.0 - 0.0
        y = h * (0.99 - (0.99 - top) * t)
        if kind == 0:
            # Runcinate: lobes whose sharp tips point back toward the stalk.
            f = (t * 5.5) % 1.0
            prof = np.sin(np.pi * t ** 0.8) * 0.34 * (0.3 + 0.7 * (1.0 - f) ** 2.2) * (1 - 0.6 * (t < 0.12))
        elif kind == 1:
            prof = np.sin(np.pi * t ** 0.7) * 0.2
        elif kind == 2:
            prof = np.sin(np.pi * t ** 0.85) * 0.4 * (1.0 + 0.05 * np.sin(t * 40.0))
        else:
            prof = (np.sqrt(max(0.0, 1.0 - ((t - 0.62) / 0.38) ** 2)) * 0.45) if t > 0.24 else 0.025
        if t < stalk / (1.0 - top) and kind != 3:
            prof = 0.025
        bend = 0.04 * np.sin(np.pi * t) * w
        cx = w * 0.5 + bend
        left.append((cx - prof * w, y))
        right.append((cx + prof * w, y))
        mid.append((cx, y))
    col = tuple(int(c) for c in np.clip(base * 255, 0, 255)) + (255,)
    draw.polygon(left + right[::-1], fill=col)
    # Lighter half, darker half, a pale midrib, side veins.
    light = tuple(int(c) for c in np.clip(base * 1.15 * 255, 0, 255)) + (255,)
    draw.polygon(left + mid[::-1], fill=light)
    rib = tuple(int(c) for c in np.clip((base * 0.6 + 0.35) * 255, 0, 255)) + (255,)
    draw.line(mid[:-3], fill=rib, width=max(2, int(w * 0.012)))
    if kind == 1:
        for off in (-0.35, 0.35):
            pts = [(mid[i][0] + off * (right[i][0] - mid[i][0]), mid[i][1]) for i in range(5, n - 3)]
            draw.line(pts, fill=tuple(int(c) for c in np.clip(base * 0.85 * 255, 0, 255)) + (255,), width=2)
    else:
        for i in range(8, n - 4, 5):
            for sgn, edge in ((-1, left), (1, right)):
                ex = mid[i][0] + 0.8 * (edge[min(i + 3, n)][0] - mid[i][0])
                draw.line([mid[i], (ex, edge[min(i + 3, n)][1])], fill=tuple(int(c) for c in np.clip(base * 0.88 * 255, 0, 255)) + (255,), width=2)
    arr = np.asarray(img).astype(np.float32)
    # Darker toward the stalk, as the rosette's centre is shaded.
    up = 1.0 - np.arange(h, dtype=np.float32) / h
    arr[..., :3] *= (0.7 + 0.3 * np.clip(up / 0.5, 0.0, 1.0))[:, None, None]
    mask = Image.new("L", (w, h))
    ImageDraw.Draw(mask).polygon(fan(w, h), fill=255)
    arr[..., 3] *= np.asarray(mask).astype(np.float32) / 255.0
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    return img.resize((CELL_W, CELL_H), Image.LANCZOS)


def clover(rng):
    # One clover for the weed row: a three-leaf clover seen from above in
    # the cell's top half (a square, the flat leaf quad), and a thin stem in
    # the bottom half, between u 0.46 and 0.54 (the stem quad).
    h = CELL_H * SS
    w = CELL_W * SS
    img = Image.new("RGBA", (w, h))
    draw = ImageDraw.Draw(img)
    base = np.array([0.3, 0.5, 0.2]) * rng.uniform(0.8, 1.05)
    col = lambda k: tuple(int(c) for c in np.clip(base * k * 255, 0, 255)) + (255,)
    cx, cy = w * 0.5, w * 0.5
    spin = rng.uniform(0, 2 * np.pi)
    for i in range(3):
        a = spin + i * 2 * np.pi / 3
        r = w * 0.2
        lx, ly = cx + np.cos(a) * r, cy + np.sin(a) * r
        # A heart: two lobes either side of the leaf's midline.
        px, py = -np.sin(a), np.cos(a)
        for sgn in (-1, 1):
            ox, oy = lx + px * sgn * r * 0.45, ly + py * sgn * r * 0.45
            rr = r * 0.62
            draw.ellipse([ox - rr, oy - rr, ox + rr, oy + rr], fill=col(1.0 if sgn > 0 else 0.88))
        draw.line([(cx, cy), (lx + np.cos(a) * r * 0.5, ly + np.sin(a) * r * 0.5)], fill=col(0.7), width=3)
        # The pale chevron clover leaves carry.
        for sgn in (-1, 1):
            ox, oy = lx + px * sgn * r * 0.4, ly + py * sgn * r * 0.4
            draw.line([(lx - np.cos(a) * r * 0.1, ly - np.sin(a) * r * 0.1), (ox, oy)], fill=col(1.35), width=4)
    draw.ellipse([cx - w * 0.04, cy - w * 0.04, cx + w * 0.04, cy + w * 0.04], fill=col(0.7))
    sw = w * 0.04
    draw.rectangle([w * 0.5 - sw * 0.6, h * 0.5, w * 0.5 + sw * 0.6, h], fill=col(0.85))
    draw.rectangle([w * 0.5 - sw * 0.6, h * 0.5, w * 0.5, h], fill=col(0.7))
    return img.resize((CELL_W, CELL_H), Image.LANCZOS)


def stalk(rng):
    # One seed stalk for the weed row, upright tufts' stalks: a wiry stem
    # with a head of spikelets on its top third, drawn between u 0.3 and 0.7
    # (the stalk quad, a fifth as wide as it is tall), warm and pale.
    h = CELL_H * SS
    w = CELL_W * SS
    img = Image.new("RGBA", (w, h))
    draw = ImageDraw.Draw(img)
    warm = rng.uniform(0.25, 0.7)
    x0, x1 = w * 0.32, w * 0.68
    cx = w * 0.5
    sway = rng.uniform(-0.04, 0.04) * w
    pts = [(cx + sway * (i / 40) ** 2, h * (0.995 - 0.97 * i / 40)) for i in range(41)]
    for i in range(40):
        draw.line([pts[i], pts[i + 1]], fill=colour(0.7 + 0.25 * i / 40, warm), width=max(3, int(w * 0.03)))
    kind = rng.integers(0, 2)
    for i in range(26, 41):
        x, y = pts[i]
        t = (i - 26) / 14
        if kind == 0:
            r = w * 0.032 * (1.1 - 0.5 * t)
            draw.ellipse([x - r, y - r * 2.2, x + r, y + r * 2.2], fill=colour(0.85 + rng.uniform(-0.1, 0.1), warm + 0.1))
        else:
            for s in (-1, 1):
                l = w * rng.uniform(0.08, 0.15) * (1.1 - 0.6 * t)
                ex = float(np.clip(x + s * l, x0, x1))
                ey = y + l * 0.6
                draw.line([(x, y), (ex, ey)], fill=colour(0.8, warm), width=3)
                r = w * 0.025
                draw.ellipse([ex - r, ey - r * 1.8, ex + r, ey + r * 1.8], fill=colour(0.9, warm + 0.1))
    arr = np.asarray(img).astype(np.float32)
    # The weed row is shown in full colour, not tinted by the ground's grass:
    # a dull green-tan, as dark as the leaves.
    arr[..., :3] *= np.array([0.52, 0.5, 0.3]) * rng.uniform(0.85, 1.05)
    arr[:, :int(x0)] = 0
    arr[:, int(x1):] = 0
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    return img.resize((CELL_W, CELL_H), Image.LANCZOS)


def opaque_share(cell):
    # Texels with alpha >= 128 over the texels inside the card's outline.
    mask = Image.new("L", (CELL_W, CELL_H))
    ImageDraw.Draw(mask).polygon(fan(CELL_W, CELL_H), fill=255)
    m = np.asarray(mask) >= 128
    a = np.asarray(cell)[..., 3] >= 128
    return float((a & m).sum()) / float(m.sum())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    atlas = Image.new("RGBA", (SIZE, HEIGHT))
    shares = {True: [], False: []}
    for gy in range(ROWS):
        for gx in range(COLS):
            cell = tuft(rng, gy < 2, gx == COLS - 1)
            shares[gy < 2].append(opaque_share(cell))
            atlas.paste(cell, (gx * CELL_W, gy * CELL_H))
    for gx in range(COLS):
        kind = gx // 2
        cell = leaf(rng, kind) if kind < 2 else clover(rng) if kind == 2 else stalk(rng)
        atlas.paste(cell, (gx * CELL_W, WEED_ROW * CELL_H))
    atlas.save(args.out)
    arr = np.asarray(atlas).astype(np.float32) / 255.0
    for r in range(ROWS):
        cell = arr[r * CELL_H:(r + 1) * CELL_H]
        bands = []
        for b in range(5):
            band = cell[CELL_H * b // 5:CELL_H * (b + 1) // 5]
            m = band[..., 3] >= 0.5
            lum = float((band[..., :3][m] @ np.array([0.2126, 0.7152, 0.0722])).mean()) if m.any() else 0.0
            bands.append("%.2f/%.2f" % (m.mean(), lum))
        print("row %d cover/brightness, top to bottom: %s" % (r, " ".join(bands)))
    every = shares[True] + shares[False]
    print("opaque share of card: long %.1f%%, short %.1f%%, all %.1f%% (min %.1f%%)" % (
        100 * np.mean(shares[True]), 100 * np.mean(shares[False]), 100 * np.mean(every), 100 * min(every)))
    print("grass atlas -> %s" % args.out)


if __name__ == "__main__":
    main()

"""Paints the lightning flipbook the electric effects play on their ribbons.

Each frame is one stylised bolt running left (root) to right (tip), both
ends pinned to the frame's vertical middle so the ribbon's ends meet what
the arc joins. Bold kinks with straight runs between them, a stroke that
tapers from root to tip, and a few short branches. Channels:
    R  the white-hot core
    G  the soft glow around it
lightning_flipbook.gdshader colours them. Frames sit in a COLS x ROWS grid.

    python tools/lightning_flipbook.py [seed]
"""
import sys

import numpy as np
from PIL import Image

FRAME_W, FRAME_H = 512, 128
COLS, ROWS = 2, 8
OUT = "assets/vfx/lightning/lightning_flipbook.png"


def bolt_path(rng, start, end, kinks, amplitude):
    """A kinked polyline from start to end: big zigzags, then one pass of fine detail."""
    xs = np.sort(rng.uniform(0.0, 1.0, kinks))
    t = np.concatenate([[0.0], xs, [1.0]])
    side = np.where(np.arange(kinks) % 2 == 0, 1.0, -1.0) * rng.choice([-1.0, 1.0])
    off = side * rng.uniform(0.35, 1.0, kinks) * amplitude
    # Calm at the ends, wildest in the middle.
    off *= np.sin(xs * np.pi) ** 0.6
    d = end - start
    normal = np.array([-d[1], d[0]]) / np.linalg.norm(d)
    pts = start + t[:, None] * d + np.concatenate([[0.0], off, [0.0]])[:, None] * normal
    # Fine detail: each run gets a small midpoint nudge.
    mids = (pts[:-1] + pts[1:]) * 0.5
    seg = np.linalg.norm(pts[1:] - pts[:-1], axis=1)
    mids += rng.normal(0.0, 1.0, mids.shape) * seg[:, None] * 0.08
    out = np.empty((len(pts) + len(mids), 2))
    out[0::2] = pts
    out[1::2] = mids
    return out


def distance_to_path(px, py, path, width_at):
    """Per pixel: distance to the path, and the stroke width at the nearest point."""
    best = np.full(px.shape, np.inf)
    width = np.zeros(px.shape)
    for a, b, wa, wb in zip(path[:-1], path[1:], width_at[:-1], width_at[1:]):
        ab = b - a
        h = np.clip(((px - a[0]) * ab[0] + (py - a[1]) * ab[1]) / max(ab @ ab, 1e-9), 0.0, 1.0)
        d = np.hypot(px - a[0] - ab[0] * h, py - a[1] - ab[1] * h)
        closer = d < best
        best = np.where(closer, d, best)
        width = np.where(closer, wa + (wb - wa) * h, width)
    return best, width


def paint_frame(rng):
    py, px = np.mgrid[0:FRAME_H, 0:FRAME_W].astype(np.float64) + 0.5
    mid = FRAME_H / 2
    core = np.zeros((FRAME_H, FRAME_W))
    glow = np.zeros((FRAME_H, FRAME_W))

    def stroke(path, root_w, tip_w, strength):
        nonlocal core, glow
        along = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(path, axis=0), axis=1))])
        widths = root_w + (tip_w - root_w) * along / along[-1]
        d, w = distance_to_path(px, py, path, widths)
        core = np.maximum(core, strength * np.clip(1.0 - (d - w * 0.5) / 1.2, 0.0, 1.0))
        glow = np.maximum(glow, strength * np.exp(-d / (w * 3.0 + 4.0)))

    main = bolt_path(rng, np.array([0.0, mid]), np.array([FRAME_W, mid]),
                     int(rng.integers(6, 10)), FRAME_H * 0.3)
    stroke(main, 5.0, 2.0, 1.0)
    for _ in range(int(rng.integers(1, 4))):
        i = int(rng.integers(2, len(main) * 3 // 4))
        start = main[i]
        reach = rng.uniform(0.12, 0.3) * FRAME_W
        angle = rng.uniform(0.35, 0.9) * rng.choice([-1.0, 1.0])
        end = start + reach * np.array([np.cos(angle), np.sin(angle)])
        end[1] = np.clip(end[1], FRAME_H * 0.12, FRAME_H * 0.88)
        stroke(bolt_path(rng, start, end, int(rng.integers(2, 4)), reach * 0.15), 2.5, 1.0, 0.7)
    # Nothing at the frame's long edges, so the ribbon's edges never show.
    edge = np.clip(np.minimum(py, FRAME_H - py) / (FRAME_H * 0.15), 0.0, 1.0)
    return core * edge, glow * edge


def main():
    rng = np.random.default_rng(int(sys.argv[1]) if len(sys.argv) > 1 else 7)
    atlas = np.zeros((FRAME_H * ROWS, FRAME_W * COLS, 3))
    for f in range(COLS * ROWS):
        core, glow = paint_frame(rng)
        y, x = (f // COLS) * FRAME_H, (f % COLS) * FRAME_W
        atlas[y:y + FRAME_H, x:x + FRAME_W, 0] = core
        atlas[y:y + FRAME_H, x:x + FRAME_W, 1] = glow
    Image.fromarray((atlas * 255).round().astype(np.uint8)).save(OUT)
    print("wrote", OUT)


if __name__ == "__main__":
    main()

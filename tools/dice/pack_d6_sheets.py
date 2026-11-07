"""Packs the frames render_d6_sheets.py wrote into the popup's sprite sheets.

    python -I tools/dice/pack_d6_sheets.py <frames_dir> <out_dir>

Writes into <out_dir> (assets/ui/dice/ in the project):

    d6_tumble_<a|b|c>.png  TUMBLE_COLS x TUMBLE_ROWS grid, row-major
    d6_settle_<n>.png      SETTLE_COLS x SETTLE_ROWS grid, row-major
    d6_landed.png          one row: faces 1..6 left to right

Every cell is the same square frame. Godot's skill_check_dice_popup.gd
reads these with AtlasTexture regions, so its FRAME_PX/grid constants must
match the ones here.
"""

import os
import sys

import numpy as np
from PIL import Image

TUMBLE_COLS, TUMBLE_ROWS = 8, 4
SETTLE_COLS, SETTLE_ROWS = 4, 4


def load_frames(folder: str) -> list:
    names = sorted(n for n in os.listdir(folder) if n.endswith(".png"))
    return [np.asarray(Image.open(os.path.join(folder, n)).convert("RGBA")) for n in names]


def check_edges(name: str, frames: list) -> None:
    """Warns when anything solid touches a frame edge, i.e. got cropped."""
    worst = 0
    for f in frames:
        edge = np.concatenate([f[0, :, 3], f[-1, :, 3], f[:, 0, 3], f[:, -1, 3]])
        worst = max(worst, int(edge.max()))
    if worst > 40:
        print(f"pack_d6_sheets: WARNING {name}: alpha {worst} at a frame edge (cropped?)")


## Alpha fades to nothing over this many pixels at every frame edge, so a
## soft shadow tail never ends in a hard line. The die keeps well clear.
EDGE_FEATHER = 12


def feather(frame: np.ndarray) -> np.ndarray:
    h, w = frame.shape[:2]
    ramp_y = np.clip(np.minimum(np.arange(h), np.arange(h)[::-1]) / EDGE_FEATHER, 0, 1)
    ramp_x = np.clip(np.minimum(np.arange(w), np.arange(w)[::-1]) / EDGE_FEATHER, 0, 1)
    out = frame.copy()
    out[..., 3] = (out[..., 3] * np.outer(ramp_y, ramp_x)).astype(np.uint8)
    return out


def grid(frames: list, cols: int, rows: int) -> Image.Image:
    if len(frames) != cols * rows:
        raise SystemExit(f"expected {cols * rows} frames, got {len(frames)}")
    h, w = frames[0].shape[:2]
    sheet = np.zeros((rows * h, cols * w, 4), np.uint8)
    for i, f in enumerate(frames):
        r, c = divmod(i, cols)
        sheet[r * h:(r + 1) * h, c * w:(c + 1) * w] = feather(f)
    return Image.fromarray(sheet, "RGBA")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    for name in ("a", "b", "c"):
        frames = load_frames(os.path.join(src, f"tumble_{name}"))
        check_edges(f"tumble_{name}", frames)
        grid(frames, TUMBLE_COLS, TUMBLE_ROWS).save(os.path.join(out, f"d6_tumble_{name}.png"), optimize=True)
    for value in range(1, 7):
        frames = load_frames(os.path.join(src, f"settle_{value}"))
        check_edges(f"settle_{value}", frames)
        grid(frames, SETTLE_COLS, SETTLE_ROWS).save(os.path.join(out, f"d6_settle_{value}.png"), optimize=True)
    landed = [np.asarray(Image.open(os.path.join(src, f"landed_{v}.png")).convert("RGBA")) for v in range(1, 7)]
    check_edges("landed", landed)
    grid(landed, 6, 1).save(os.path.join(out, "d6_landed.png"), optimize=True)
    print("pack_d6_sheets: sheets written to", out)


main()

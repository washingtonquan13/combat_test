"""Packs the frames render_d6_sheets.py wrote into the popup's sprite sheets.

    python -I tools/dice/pack_d6_sheets.py <frames_dir> <out_dir>

Writes into <out_dir> (assets/ui/dice/ in the project), every sheet a grid
COLS wide, row-major, unused trailing cells empty:

    d6_roll_<name>.png   one community tumble (double_roll_1/2, single_roll)
    d6_settle_<n>.png    the settle onto face n; its last frame is the landed
                         still
    d6_landed.png        one row: faces 1..6 at rest, left to right

Godot's skill_check_dice_popup.gd reads these with AtlasTexture regions, so
its FRAME_PX, COLS and frame counts must match the renders.
"""

import os
import sys

import numpy as np
from PIL import Image

COLS = 8
ROLLS = ("double_roll_1", "double_roll_2", "single_roll")


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


# Alpha fades to nothing over this many pixels at every frame edge, so a
# motion-blur smear never ends in a hard line. The die keeps well clear.
EDGE_FEATHER = 12


def feather(frame: np.ndarray) -> np.ndarray:
    h, w = frame.shape[:2]
    ramp_y = np.clip(np.minimum(np.arange(h), np.arange(h)[::-1]) / EDGE_FEATHER, 0, 1)
    ramp_x = np.clip(np.minimum(np.arange(w), np.arange(w)[::-1]) / EDGE_FEATHER, 0, 1)
    out = frame.copy()
    out[..., 3] = (out[..., 3] * np.outer(ramp_y, ramp_x)).astype(np.uint8)
    return out


def grid(frames: list, cols: int = COLS) -> Image.Image:
    rows = -(-len(frames) // cols)
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
    for name in ROLLS:
        frames = load_frames(os.path.join(src, f"roll_{name}"))
        check_edges(f"roll_{name}", frames)
        grid(frames).save(os.path.join(out, f"d6_roll_{name}.png"), optimize=True)
        print(f"pack_d6_sheets: roll_{name} {len(frames)} frames")
    landed = []
    for value in range(1, 7):
        frames = load_frames(os.path.join(src, f"settle_{value}"))
        check_edges(f"settle_{value}", frames)
        grid(frames).save(os.path.join(out, f"d6_settle_{value}.png"), optimize=True)
        landed.append(frames[-1])
    grid(landed, 6).save(os.path.join(out, "d6_landed.png"), optimize=True)
    print("pack_d6_sheets: sheets written to", out)


main()

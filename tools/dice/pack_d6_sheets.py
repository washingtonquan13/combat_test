"""Packs the frames render_d6_sheets.py wrote into the popup's sprite sheets.

    python -I tools/dice/pack_d6_sheets.py <frames_dir> <throws.json> <out_dir>

Every sheet is a grid of CELL px cells, COLS wide (fewer when it holds
fewer), row-major, unused trailing cells empty: cell k sits at column
k % COLS, row k // COLS. The die's rest centre is the cell's centre, drawn
1:1. Writes into <out_dir> (assets/ui/dice/ in the project):

    d6_roll_<i>_<n>.png   throw i, the whole roll, frames 0..frames-1,
                          ending on face n; its last cell is the still of
                          n, pixel for pixel
    d6_still_blank.png    the die at rest, no numeral
    d6_numerals.png       numerals 1..6, transparent elsewhere: drawn over
                          d6_still_blank, numeral n makes the still of n
    d6_glint.png          a highlight sweeping the resting die, to be drawn
                          additively (the glint render minus the blank)
    d6_dice.json          cell, cols, fps, sizes, and per throw its frame
                          count and the die's path (px from rest, screen y
                          down, z = px above rest height) for every frame

skill_check_dice_popup.gd reads the sidecar; nothing about the sheets'
layout is hard-coded there beyond the rule above.
"""

import json
import os
import sys

import numpy as np
from PIL import Image

CELL = 208
COLS = 8
# Alpha fades to nothing over this many pixels at every cell edge, so a
# smear that reaches it never ends in a hard line. The die keeps clear.
EDGE_FEATHER = 6
# Launch delays of the popup's three dice, frames, and their slot spacing
# in faces; must match d6_throws.py, which cleared the throws for them.
LAUNCH_FRAMES = [0, 4, 8]
SLOT_SPACING = 1.6
GLINT_FRAMES = 10
# Frames the glint fades over at each end.
GLINT_RAMP = 2.0


def load(folder: str) -> dict:
    """{frame index: RGBA uint8 array} from <folder>/<frame>.png."""
    out = {}
    for name in os.listdir(folder):
        if name.endswith(".png"):
            im = np.asarray(Image.open(os.path.join(folder, name)).convert("RGBA"))
            assert im.shape[:2] == (CELL, CELL), f"{folder}/{name}: {im.shape}"
            out[int(name[:-4])] = im
    return out


def span(frames: dict, first: int, last: int, where: str) -> list:
    missing = [f for f in range(first, last + 1) if f not in frames]
    if missing:
        raise SystemExit(f"pack_d6_sheets: {where} lacks frames {missing}")
    return [frames[f] for f in range(first, last + 1)]


def check_edges(name: str, frames: list) -> None:
    """Warns when anything solid touches a cell edge, i.e. got cropped."""
    worst = 0
    for f in frames:
        edge = np.concatenate([f[0, :, 3], f[-1, :, 3], f[:, 0, 3], f[:, -1, 3]])
        worst = max(worst, int(edge.max()))
    if worst > 8:
        print(f"pack_d6_sheets: WARNING {name}: alpha {worst} at a cell edge (cropped?)")


def feather(frame: np.ndarray) -> np.ndarray:
    ramp = np.clip((np.minimum(np.arange(CELL), np.arange(CELL)[::-1]) + 0.5) / EDGE_FEATHER, 0, 1)
    out = frame.copy()
    out[..., 3] = np.round(out[..., 3] * np.outer(ramp, ramp)).astype(np.uint8)
    return out


def save(frames: list, path: str) -> None:
    check_edges(os.path.basename(path), frames)
    cols = min(COLS, len(frames))
    rows = -(-len(frames) // cols)
    sheet = np.zeros((rows * CELL, cols * CELL, 4), np.uint8)
    for k, f in enumerate(frames):
        r, c = divmod(k, cols)
        sheet[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL] = feather(f)
    Image.fromarray(sheet, "RGBA").save(path, optimize=True)


def premul(im: np.ndarray) -> np.ndarray:
    f = im.astype(np.float64) / 255.0
    return np.concatenate([f[..., :3] * f[..., 3:], f[..., 3:]], -1)


def over(top: np.ndarray, bottom: np.ndarray) -> np.ndarray:
    """Straight-alpha top over bottom, as the popup draws it; premultiplied
    float result."""
    t, b = premul(top), premul(bottom)
    return t + b * (1.0 - t[..., 3:])


def solve_numeral(render: np.ndarray, blank: np.ndarray, still: np.ndarray) -> np.ndarray:
    """The numeral layer, solved so that drawn over the blank it gives the
    still. Blender blends a glyph's edge in linear light, the popup in
    display values, so the holdout render's own edge (its coverage as
    alpha) would come out dark and thin. Kept: where the glyph is (its
    footprint) and its colour; solved per pixel: the alpha that best turns
    the blank into the still with that colour, then the colour that makes
    up the rest."""
    s = still[..., :3].astype(np.float64) / 255.0
    b = blank[..., :3].astype(np.float64) / 255.0 * (blank[..., 3:] / 255.0)
    glyph = render[..., 3] > 0
    n = np.where(glyph[..., None], render[..., :3].astype(np.float64) / 255.0, 1.0)
    ds, dn = s - b, n - b
    a = np.clip((ds * dn).sum(-1) / np.maximum((dn * dn).sum(-1), 1e-6), 0.0, 1.0) * glyph
    a = np.round(a * 255) / 255
    rgb = np.where(a[..., None] > 0, (s - b * (1.0 - a[..., None])) / np.maximum(a[..., None], 1e-6), 0.0)
    out = np.zeros_like(render)
    out[..., :3] = np.round(np.clip(rgb, 0.0, 1.0) * 255).astype(np.uint8)
    out[..., 3] = np.round(a * 255).astype(np.uint8)
    return out


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    src, throws_path, out = sys.argv[1:]
    with open(throws_path) as fh:
        throws = json.load(fh)
    os.makedirs(out, exist_ok=True)
    one = lambda folder: span(load(os.path.join(src, folder)), 0, 0, folder)[0]
    stills = {n: one(f"still_{n}") for n in range(1, 7)}
    blank = one("still_blank")
    numerals = [solve_numeral(one(f"numeral_{n}"), blank, stills[n]) for n in range(1, 7)]

    sidecar_heads = []
    for i, head in enumerate(throws["heads"]):
        last = head["frames"] - 1
        assert len(head["path_px"]) == head["frames"]
        for n in range(1, 7):
            key = f"roll_{i}_{n}"
            roll = span(load(os.path.join(src, key)), 0, last, key)
            gap = np.abs(roll[-1].astype(int) - stills[n].astype(int)).max()
            print(f"pack_d6_sheets: {key}: last frame vs still max diff {gap}")
            roll[-1] = stills[n]
            save(roll, os.path.join(out, f"d6_{key}.png"))
        sidecar_heads.append({
            "frames": head["frames"],
            "path": [[round(c, 2) for c in p] for p in head["path_px"]],
        })

    save([blank], os.path.join(out, "d6_still_blank.png"))
    save(numerals, os.path.join(out, "d6_numerals.png"))
    for n in range(1, 7):
        gap = np.abs(over(numerals[n - 1], blank) - premul(stills[n])).max() * 255
        print(f"pack_d6_sheets: blank + numeral {n} vs still max diff {gap:.1f}")

    # The glint: what the sweeping light adds over the blank die, alpha
    # solid wherever the die is, for an additive draw.
    lit = span(load(os.path.join(src, "glint")), 0, GLINT_FRAMES - 1, "glint")
    base = premul(blank)
    solid = blank[..., 3] > 0
    # Faded in and out over the end frames, so the additive layer starts
    # and stops at nothing even where the bar still clips a corner.
    def ramp(x: float) -> float:
        t = min(max(x / GLINT_RAMP, 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)

    glint = []
    for i, f in enumerate(lit):
        add = np.clip(premul(f)[..., :3] - base[..., :3], 0.0, 1.0)
        add *= ramp(i) * ramp(GLINT_FRAMES - 1 - i)
        cell = np.zeros((CELL, CELL, 4), np.uint8)
        cell[..., :3] = np.round(add * 255).astype(np.uint8) * solid[..., None]
        cell[..., 3] = solid * 255
        glint.append(cell)
    save(glint, os.path.join(out, "d6_glint.png"))
    print("pack_d6_sheets: glint peak add", max(int(g[..., :3].max()) for g in glint))

    with open(os.path.join(out, "d6_dice.json"), "w", newline="\n") as fh:
        json.dump({
            "cell": CELL, "cols": COLS, "fps": throws["fps"], "face_px": throws["face_px"],
            "glint_frames": GLINT_FRAMES, "launch_frames": LAUNCH_FRAMES,
            "slot_spacing_px": round(SLOT_SPACING * throws["face_px"], 2),
            "heads": sidecar_heads,
        }, fh, separators=(",", ":"))
        fh.write("\n")
    print("pack_d6_sheets: sheets written to", out)


main()

"""Turns render_wheel.py's layers into the files odds_wheel.gd loads.

python -I pack_wheel.py RENDER_DIR OUT_DIR
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# Keep in step with render_wheel.py: the sheen is rendered this much brighter.
SHEEN_GAIN = 16.0
# Godot blends 2D in display colours while the sheen was lit in linear light,
# so its strength is worked out over a typical wedge at this linear brightness.
TYPICAL_WEDGE = 0.03
# Display gamma, for turning a linear shadow into a black overlay's alpha.
GAMMA = 2.2
# The slices of spinning.png, in the order of OddsWheel.Kind, then the pegs.
SPINNING = ["wheel_success", "wheel_fail", "wheel_crit_success", "wheel_crit_fail", "pegs"]


def read(folder, name):
    return np.asarray(Image.open(folder / f"{name}.png").convert("RGBA"), dtype=np.float64) / 255.0


def write(pixels, path):
    Image.fromarray((np.clip(pixels, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8), "RGBA").save(path, optimize=True)


def to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_display(c):
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.maximum(c, 1e-9) ** (1.0 / 2.4) - 0.055)


def frame_over_shade(frame, shade):
    disc = shade[..., 3] > 0.99
    lit = to_linear(shade[..., 0])
    ratio = np.clip(lit / np.percentile(lit[disc], 99.5), 0.0, 1.0)
    shadow = (1.0 - ratio ** (1.0 / GAMMA)) * shade[..., 3]
    alpha = frame[..., 3] + shadow * (1.0 - frame[..., 3])
    out = frame.copy()
    out[..., 3] = alpha
    visible = alpha > 0.0
    for c in range(3):
        out[..., c][visible] = frame[..., c][visible] * frame[..., 3][visible] / alpha[visible]
    return out


def sheen_overlay(sheen):
    light = to_linear(sheen[..., :3]) / SHEEN_GAIN
    delta = to_display(TYPICAL_WEDGE + light) - to_display(np.full_like(light, TYPICAL_WEDGE))
    # A half-step of noise so a gradient this faint doesn't band.
    noise = np.random.default_rng(7).random(delta.shape[:2])[..., None] / 255.0
    out = sheen.copy()
    out[..., :3] = delta + noise * (delta > 0.0)
    return out


def main():
    source, target = Path(sys.argv[1]), Path(sys.argv[2])
    target.mkdir(parents=True, exist_ok=True)
    write(np.concatenate([read(source, name) for name in SPINNING], axis=1), target / "spinning.png")
    write(frame_over_shade(read(source, "frame"), read(source, "shade")), target / "frame.png")
    write(sheen_overlay(read(source, "sheen")), target / "sheen.png")
    write(read(source, "needle"), target / "needle.png")


main()

#!/usr/bin/env bash
# DEPRECATED: skill checks spin the odds wheel now (tools/wheel). The dice stay
# buildable, for skill_check_dice_popup.gd, but no new work should build on them.
#
# Builds the sprite d6: simulates and picks the throws (d6_throws.py, about
# eight minutes), renders each throw whole once per result face in Blender
# from the community "Numbered Dice" d20 scene (Nexus mod 1325, not in the
# repo) and packs the frames into assets/ui/dice/. Usage: bash tools/dice/build.sh [work_dir]
# work_dir (throws.json and the loose per-frame PNGs) defaults to a temp
# folder; a throws.json already in it is reused, delete it to re-simulate.
# DICE_BLEND points at numbers_main.blend, DICE_FONT at the numeral font
# (default C:/Windows/Fonts/DejaVuSans-Bold.ttf).
set -euo pipefail

BLENDER="${BLENDER:-/c/Program Files/Blender Foundation/Blender 4.3/blender.exe}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK="${1:-$(mktemp -d)}"
DICE_BLEND="${DICE_BLEND:-/d/BrowserDownloads/Numbered Dice-1325-1-1-1693758005/numbers_main.blend}"
THROWS="$WORK/throws.json"
FRAMES="$WORK/frames"

mkdir -p "$WORK"
if [ ! -f "$THROWS" ]; then
    python -I "$SCRIPT_DIR/d6_throws.py" "$THROWS"
fi
"$BLENDER" -b "$DICE_BLEND" -P "$SCRIPT_DIR/render_d6_sheets.py" -- --throws "$THROWS" --out "$FRAMES"
python -I "$SCRIPT_DIR/pack_d6_sheets.py" "$FRAMES" "$THROWS" "$PROJECT_DIR/assets/ui/dice"

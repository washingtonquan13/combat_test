#!/usr/bin/env bash
# Renders the sprite d6 in Blender from the community "Numbered Dice" d20
# scene (Nexus mod 1325, not in the repo) and packs the frames into
# assets/ui/dice/. Usage: bash tools/dice/build.sh [frames_dir]
# frames_dir (the loose per-frame PNGs) defaults to a temp folder; DICE_BLEND
# points at numbers_main.blend.
set -euo pipefail

BLENDER="${BLENDER:-/c/Program Files/Blender Foundation/Blender 4.3/blender.exe}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FRAMES="${1:-$(mktemp -d)}"
DICE_BLEND="${DICE_BLEND:-/d/BrowserDownloads/Numbered Dice-1325-1-1-1693758005/numbers_main.blend}"

"$BLENDER" -b "$DICE_BLEND" -P "$SCRIPT_DIR/render_d6_sheets.py" -- --out "$FRAMES"
python -I "$SCRIPT_DIR/pack_d6_sheets.py" "$FRAMES" "$PROJECT_DIR/assets/ui/dice"

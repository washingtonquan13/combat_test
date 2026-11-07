#!/usr/bin/env bash
# Renders the sprite d6 in Blender and packs the frames into
# assets/ui/dice/. Usage: bash tools/dice/build.sh [frames_dir]
# frames_dir (the loose per-frame PNGs) defaults to a temp folder.
set -euo pipefail

BLENDER="${BLENDER:-/c/Program Files/Blender Foundation/Blender 4.3/blender.exe}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FRAMES="${1:-$(mktemp -d)}"

"$BLENDER" -b -P "$SCRIPT_DIR/render_d6_sheets.py" -- --out "$FRAMES"
python -I "$SCRIPT_DIR/pack_d6_sheets.py" "$FRAMES" "$PROJECT_DIR/assets/ui/dice"

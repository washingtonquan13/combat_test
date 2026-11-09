#!/usr/bin/env bash
# Renders the odds wheel in Blender and packs it into assets/ui/wheel/.
# Usage: bash tools/wheel/build.sh [lacquer] [wood]    (default both)
# WHEEL_WORK keeps the raw layers somewhere instead of a temp folder.
# Numerals use Windows fonts (Cambria Bold, Palatino Bold).
set -euo pipefail

BLENDER="${BLENDER:-/c/Program Files/Blender Foundation/Blender 4.3/blender.exe}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK="${WHEEL_WORK:-$(mktemp -d)}"

if [ "$#" -eq 0 ]; then
    set -- lacquer wood
fi

for look in "$@"; do
    mkdir -p "$WORK/$look"
    "$BLENDER" -b --factory-startup --python-exit-code 1 -P "$SCRIPT_DIR/render_wheel.py" -- --look "$look" --out "$WORK/$look"
    python -I "$SCRIPT_DIR/pack_wheel.py" "$WORK/$look" "$PROJECT_DIR/assets/ui/wheel/$look"
done

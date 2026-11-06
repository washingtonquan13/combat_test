#!/usr/bin/env bash
# Renders the dialogue overlay (staged with a synthetic conversation) to a
# PNG plus a sibling <path>.layout.txt describing every Control's rect —
# see tools/ui_snapshot.gd / tools/README.md for what it captures.
#
# Usage: tools/snap.sh [output_path]
#   output_path defaults to ./overlay.png in the CALLER's current directory.
#
# --headless cannot render, so this launches a real (if brief) window with
# the opengl3 driver. The window flashing on screen for under a second is
# expected, not a bug.
set -euo pipefail

GODOT="/d/PortablePrograms/Godot_v4.4.1-stable_win64.exe/Godot_v4.4.1-stable_win64_console.exe"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_PATH="${1:-$(pwd)/overlay.png}"
# Godot wants a native Windows path for save_png/FileAccess on this
# platform; convert only if this looks like a Git-Bash-style /c/... path.
case "$OUT_PATH" in
	/*) OUT_PATH="$(cd "$(dirname "$OUT_PATH")" && pwd -W 2>/dev/null || pwd)/$(basename "$OUT_PATH")" ;;
esac

echo "ui_snapshot: capturing to $OUT_PATH"

if ! timeout 60 "$GODOT" --path "$PROJECT_DIR" --rendering-driver opengl3 --resolution 1600x900 \
	res://tools/ui_snapshot.tscn -- --out="$OUT_PATH"; then
	echo "ui_snapshot: Godot exited non-zero — see output above for the failure line" >&2
	exit 1
fi

if [ ! -f "$OUT_PATH" ]; then
	echo "ui_snapshot: Godot exited 0 but $OUT_PATH was never written" >&2
	exit 1
fi

echo "$OUT_PATH"

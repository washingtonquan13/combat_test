#!/usr/bin/env bash
# Combat AI regression suite. Exits 0 on pass, 1 on any failure.
# See tests/README.md.
set -uo pipefail

GODOT="${GODOT:-D:/PortablePrograms/Godot_v4.4.1-stable_win64.exe/Godot_v4.4.1-stable_win64_console.exe}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$GODOT" ]; then
  echo "Godot not found at: $GODOT" >&2
  echo "Set GODOT=/path/to/godot_console.exe and re-run." >&2
  exit 2
fi

# "no debug info in PE/COFF executable" is crash-handler noise from the
# console build and says nothing about the tests.
"$GODOT" --path "$ROOT" --headless res://tests/test_runner.tscn 2>&1 \
  | grep -v "no debug info in PE/COFF executable"
exit "${PIPESTATUS[0]}"

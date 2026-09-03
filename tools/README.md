# ui_snapshot

Run `tools/snap.sh [output_path]` (Git Bash) to render the real DialogueOverlay with a synthetic 5-choice conversation and save it to `output_path` (default `./overlay.png`), plus a `<output_path>.layout.txt` dump of every Control's rect/anchors/min-size/size-flags under the overlay.

A brief window flash is expected — `--headless` cannot render, so this runs with `--rendering-driver opengl3` in a real (if short-lived) window.

To run it directly instead of via the wrapper: `"$GODOT" --path . --rendering-driver opengl3 --resolution 1600x900 res://tools/ui_snapshot.tscn -- --out=<absolute_path.png>`.

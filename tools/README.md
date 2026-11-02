# ui_snapshot

Run `tools/snap.sh [output_path]` (Git Bash) to render the real DialogueOverlay with a synthetic 5-choice conversation and save it to `output_path` (default `./overlay.png`), plus a `<output_path>.layout.txt` dump of every Control's rect/anchors/min-size/size-flags under the overlay.

A brief window flash is expected — `--headless` cannot render, so this runs with `--rendering-driver opengl3` in a real (if short-lived) window.

To run it directly instead of via the wrapper: `"$GODOT" --path . --rendering-driver opengl3 --resolution 1600x900 res://tools/ui_snapshot.tscn -- --out=<absolute_path.png>`.

# item_layer_demo

A recorded walkthrough of the inventory, run in the real game. It is not a test and is not part of `tests/run.sh`. It boots MainRoot, makes a character and loots the test_arena chest. Then it uses synthetic mouse input to drag items in the grid and onto and off equip slots, uses right-click Equip and Drop, switches the viewed unit, sorts, applies the dialogue item effects, and saves, loads and starts a new game. Each step prints PASS/FAIL, and the result is the closing `DEMO RESULT: n/m passed` line. It moves the real OS cursor while it runs.

`"$GODOT" --path . --rendering-driver opengl3 --resolution 1600x900 --write-movie <out.avi> --fixed-fps 30 res://tools/item_layer_demo.tscn` records it. Drop `--write-movie`/`--fixed-fps` to only watch it.

# attack_rows_demo

A short recorded walkthrough of attack rows, built on item_layer_demo's helpers: an empty hand shows Punch on the hotbar, the iron sword turns it into Swing and Thrust, unequipping brings Punch back, and a beast's natural rows are captioned. Record it the same way as item_layer_demo, with `res://tools/attack_rows_demo.tscn`.

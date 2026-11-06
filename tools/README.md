# ui_snapshot

Run `tools/snap.sh [output_path]` (Git Bash) to render the real DialogueOverlay with a synthetic 5-choice conversation and save it to `output_path` (default `./overlay.png`), plus a `<output_path>.layout.txt` dump of every Control's rect/anchors/min-size/size-flags under the overlay.

A brief window flash is expected — `--headless` cannot render, so this runs with `--rendering-driver opengl3` in a real (if short-lived) window.

To run it directly instead of via the wrapper: `"$GODOT" --path . --rendering-driver opengl3 --resolution 1600x900 res://tools/ui_snapshot.tscn -- --out=<absolute_path.png>`.

# item_layer_demo

A recorded walkthrough of the inventory, run in the real game. It is not a test and is not part of `tests/run.sh`. It boots MainRoot, makes a character and loots the test_arena chest. Then it uses synthetic mouse input to drag items in the grid and onto and off equip slots, uses right-click Equip and Drop, switches the viewed unit, sorts, applies the dialogue item effects, and saves, loads and starts a new game. Each step prints PASS/FAIL, and the result is the closing `DEMO RESULT: n/m passed` line. It moves the real OS cursor while it runs.

`"$GODOT" --path . --rendering-driver opengl3 --resolution 1600x900 --write-movie <out.avi> --fixed-fps 30 res://tools/item_layer_demo.tscn` records it. Drop `--write-movie`/`--fixed-fps` to only watch it.

# attack_rows_demo

A short recorded walkthrough of attack rows, built on item_layer_demo's helpers: an empty hand shows Punch on the hotbar, the iron sword turns it into Swing and Thrust, unequipping brings Punch back, and a beast's natural rows are captioned. Record it the same way as item_layer_demo, with `res://tools/attack_rows_demo.tscn`.

# sockets_demo

A recorded walkthrough of rarity, sockets and runes, built on item_layer_demo's helpers. It runs 12 checks with real drags. A socket awl adds a socket to the iron sword, an iron rune fills it (+1 damage on its rows), a second rune is refused by the full sword, and the last awl is used up. The rare chest is equipped and a vigor rune socketed into it while worn raises max HP, and the stats column follows. Hovering the sword shows the tooltip in the rarity colour. Record it with `res://tools/sockets_demo.tscn`.

# hands_demo

A recorded walkthrough of hands, also built on item_layer_demo's helpers. It runs 13 checks. A sword in each hand adds off-hand attacks at -4 to the hotbar. A greatsword fills the main hand and shows a faded ghost in the off hand, which refuses a shield. At ST 9 the greatsword (min ST 12) is -3 to hit. With a shield on, the greatsword is refused. Drops back into the bag go to fixed cells, because `_last_free_cell` keeps clear of the grid's scrolling edges and found none here. Record it with `res://tools/hands_demo.tscn`. Set `HANDS_SNAPSHOT=<path>.png` to also save a zoomed still of the weapon slots while the ghost shows.

# attack_flow_demo

A recorded walkthrough of the attack flow (1bf3e4c), built on item_layer_demo's helpers. It runs 11 checks. A Magic Missile's damage is rolled at the cast, nothing lands while it flies, and exactly that amount lands when it arrives. A fireball's blast is decided per unit at the cast the same way. A target killed mid-flight takes nothing and the cast still finishes. A caster that ends its turn while busy and then dies mid-action no longer ends the next unit's turn. Record it with `res://tools/attack_flow_demo.tscn`.

# combat_rules_demo

A recorded walkthrough of the combat rules, built on item_layer_demo's helpers. It runs 17 checks against a same-faction dummy in a leather chestpiece. It shows crushing, cutting and impaling after DR, with live Swing and Thrust. It shows Target Vitals and Target Head (to-hit and wounding), and a level-2 Deceptive Attack. Bloodied and Exhausted come on below a third of HP or FP. Stacking heavy gear raises the encumbrance level with the inventory open. Downing the whole party brings up the game over screen. The HT roll to stay up is random, so the demo forces the failure the way test_game_over does. Record it with `res://tools/combat_rules_demo.tscn`.

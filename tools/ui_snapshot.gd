extends Node
## Standalone snapshot tool — NOT a test, NOT part of tests/run.sh. Boots
## the real DialogueOverlay (systems/dialogue_system/dialogue_overlay.tscn)
## under a synthetic conversation staged the same cheap way tests/dialogue/
## suites do (see tests/ai_test_case.gd spawn_unit / test_a_skill_shows_
## its_level.gd's Stealth setup), captures the rendered viewport to a PNG,
## and dumps every Control under the overlay to a sibling .layout.txt so
## the layout can be judged from text alone.
##
## Run via tools/snap.sh — this scene must be run with a real rendering
## driver (--headless cannot render), as a SCENE (not --script) so the
## project's autoloads (DialogueManager, UIStack, ...) are alive. See
## tools/README.md.
##
## Deliberately does not depend on MainRoot.tscn or anything under ui/ —
## this tool owns only tools/, so it builds its own minimal CanvasLayer
## and 3D parent for the two throwaway Units the conversation needs.

const OverlayScene: PackedScene = preload("res://systems/dialogue_system/dialogue_overlay.tscn")
const UnitScene: PackedScene = preload("res://systems/unit_system/unit.tscn")
const PlaceholderModel: PackedScene = preload("res://scenes/character_models/placeholder_model.tscn")

## ~140 characters, to exercise Line label wrapping (see the brief).
const LONG_CHOICE_TEXT: String = "I know this sounds strange, but if you let me look through the back room before the caravan arrives, I promise I will explain everything afterward."

var _units_root: Node3D
var _out_path: String = ""


func _ready() -> void:
	_out_path = _parse_out_arg()
	if _out_path == "":
		_fail("no --out=<path> argument given (args seen: %s)" % [OS.get_cmdline_user_args()])
		return

	_units_root = Node3D.new()
	add_child(_units_root)

	var actor: Unit = _make_unit("Player")
	var npc: Unit = _make_unit("Innkeeper")
	_train_stealth(actor)

	var overlay: UIScreen = OverlayScene.instantiate()
	var layer := CanvasLayer.new()
	add_child(layer)
	layer.add_child(overlay)

	# One frame so DialogueOverlay._ready() has connected to
	# DialogueManager's signals before start_dialogue() below fires them.
	await get_tree().process_frame

	DialogueManager.start_dialogue(_build_sample_node(), {"player": actor, "npc": npc})

	if not DialogueManager.is_active():
		_fail("DialogueManager.start_dialogue() did not open a conversation (is_active() is false) — check StashManager.is_active()/Unit.in_combat() guards in dialogue_manager.gd")
		return
	if not overlay.visible:
		_fail("DialogueOverlay never became visible after dialogue_started — its _on_dialogue_started/open()/UIStack.push path did not run as expected")
		return

	# At least 4 process frames plus one real render, per the brief.
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		_fail("get_viewport().get_texture().get_image() returned null — no rendering driver active?")
		return

	var save_err: int = img.save_png(_out_path)
	if save_err != OK:
		_fail("Image.save_png('%s') failed with error code %d" % [_out_path, save_err])
		return

	_write_layout_dump(overlay, _out_path + ".layout.txt")

	print("ui_snapshot: wrote %s" % _out_path)
	get_tree().quit(0)


func _parse_out_arg() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.substr("--out=".length())
	return ""


func _make_unit(shown_name: String) -> Unit:
	var unit: Unit = UnitScene.instantiate()
	var definition := UnitDefinition.new()
	definition.model_scene = PlaceholderModel
	# Assigned before add_child so Unit._enter_tree sees it, same order
	# every real spawn path (and tests/ai_test_case.gd's spawn_unit) uses.
	unit.definition = definition
	_units_root.add_child(unit)
	unit.display_name = shown_name
	unit.faction = &"player"
	unit.strength = 12
	unit.dexterity = 12
	unit.maximum_hp = 20
	unit.current_hp = 20
	unit.reset_turn_actions()
	return unit


## Trains Stealth on actor exactly the way test_a_skill_shows_its_level.gd
## does, so the skill-check choice below renders a real computed level
## instead of a synthetic one. Acrobatics is deliberately left untrained
## on this same actor, for the untrained-but-defaulted choice.
func _train_stealth(actor: Unit) -> void:
	var stealth: Skill = load("res://data/skills/stealth.tres")
	if stealth == null:
		return
	var stealth_instance := SkillInstance.new()
	stealth_instance.skill_data = stealth
	stealth_instance.levels_purchased = 1
	_units_root.add_child(stealth_instance)
	actor.add_skill(stealth_instance)


func _build_sample_node() -> DialogueNode:
	var node := DialogueNode.new()
	node.id = "ui_snapshot_root"
	node.speaker = "npc"
	node.text_block = "You're not from around here, are you? Keep your voice down if you want to talk."

	var plain := LineChoice.new()
	plain.text = "Just passing through."

	var stealth_check := SkillCheckChoice.new()
	stealth_check.text = "Slip past without being seen."
	stealth_check.skill_name = "Stealth"

	var acrobatics_check := SkillCheckChoice.new()
	acrobatics_check.text = "Vault the counter and bolt for the back room."
	acrobatics_check.skill_name = "Acrobatics"

	var long_choice := LineChoice.new()
	long_choice.text = LONG_CHOICE_TEXT

	var aligned := LineChoice.new()
	aligned.text = "Threaten to burn the place down if they don't talk."
	aligned.alignment_name = "Chaotic"

	node.choices = [plain, stealth_check, acrobatics_check, long_choice, aligned]
	return node


## Writes one line per Control under root (root included), in tree order:
## its path relative to root, global rect, custom_minimum_size,
## size_flags_horizontal, and all four anchors — enough to spot a pixel
## constant or a non-expanding child without opening the PNG.
func _write_layout_dump(root: Control, path: String) -> void:
	var lines: PackedStringArray = []
	_collect_layout_lines(root, root, lines)

	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("ui_snapshot: could not open '%s' for writing (error %d)" % [path, FileAccess.get_open_error()])
		return
	file.store_string("\n".join(lines) + "\n")
	file.close()


func _collect_layout_lines(root: Control, node: Control, lines: PackedStringArray) -> void:
	var rel_path: String = "." if node == root else str(root.get_path_to(node))
	var rect: Rect2 = node.get_global_rect()
	lines.append(
		"%s  rect=(%.1f, %.1f, %.1f, %.1f)  min_size=(%.1f, %.1f)  size_flags_h=%d  mouse_filter=%d  anchors=(%.3f, %.3f, %.3f, %.3f)" % [
			rel_path,
			rect.position.x, rect.position.y, rect.size.x, rect.size.y,
			node.custom_minimum_size.x, node.custom_minimum_size.y,
			node.size_flags_horizontal,
			node.mouse_filter,
			node.anchor_left, node.anchor_top, node.anchor_right, node.anchor_bottom,
		]
	)
	for child in node.get_children():
		if child is Control:
			_collect_layout_lines(root, child, lines)


func _fail(message: String) -> void:
	push_error("ui_snapshot: %s" % message)
	printerr("ui_snapshot FAILED: %s" % message)
	get_tree().quit(1)

extends Node
## Standalone recorded walkthrough — NOT a test, NOT part of tests/run.sh.
## Boots the real game, walks into test_arena and plays
## cinematics/proof_hero_meeting.tscn exactly as the debug harness's H key
## does, clicking through each line after a few seconds. Prints how far the
## hero's face moved while it talked, so a recording can be checked by
## number as well as by eye.
##
##   Godot --rendering-driver opengl3 --resolution 1600x900 \
##     --write-movie out.avi --fixed-fps 30 res://tools/proof_hero_meeting_demo.tscn

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const HARNESS_SCRIPT := "res://debug/debug_cutscene_harness.gd"
const READ_SECONDS := 3.5

var _peak: Dictionary = {}


func _ready() -> void:
	add_child(MainRootScene.instantiate())
	_run.call_deferred()


func _run() -> void:
	await _wait(1.0)
	get_tree().get_first_node_in_group("main_menu")._on_start_pressed()
	await _wait(1.0)
	var creation: Node = get_tree().get_first_node_in_group("character_creation")
	creation._on_auto_fill_pressed()
	await _wait(0.5)
	creation._on_confirm_pressed()
	await WorldManager.world_focused
	await _wait(2.0)

	var harness: Node = _find_harness(get_tree().root)
	if harness == null:
		print("DEMO: no cutscene harness in MainRoot")
		get_tree().quit(1)
		return
	_click_through()
	await harness._play_at_leader(harness.HERO_PATH, harness.HERO_ANCHOR)
	await _wait(1.0)
	print("DEMO face peaks: ", _peak)
	get_tree().quit()


func _click_through() -> void:
	var waited := 0.0
	while true:
		await get_tree().process_frame
		var delta: float = get_process_delta_time()
		var stage: CinematicStage = CinematicDirector.current_stage()
		if stage == null:
			if waited < 0.0:
				return
			continue
		_sample_face(stage)
		if stage.is_waiting():
			waited = maxf(waited, 0.0) + delta
			if waited >= READ_SECONDS:
				waited = -1.0
				var press := InputEventAction.new()
				press.action = &"cinematic_advance"
				press.pressed = true
				Input.parse_input_event(press)
				var release := InputEventAction.new()
				release.action = &"cinematic_advance"
				Input.parse_input_event(release)
		elif waited > 0.0:
			waited = 0.0


func _sample_face(stage: CinematicStage) -> void:
	var hero: Node = stage.actor(&"hero")
	var face: FaceDriver = FaceDriver.of(hero)
	if face == null:
		return
	for shape in face._current:
		_peak[shape] = maxf(_peak.get(shape, 0.0), snappedf(face._current[shape], 0.01))


func _find_harness(node: Node) -> Node:
	var script: Script = node.get_script()
	if script and script.resource_path == HARNESS_SCRIPT:
		return node
	for child in node.get_children():
		var found: Node = _find_harness(child)
		if found:
			return found
	return null


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

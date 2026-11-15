extends Node
## Standalone walkthrough — NOT a test, NOT part of tests/run.sh.
## Boots the real game into the quarry, stands the proof hero in front of
## the Scared Townperson and starts their ordinary dialogue, so what is on
## screen is what DialogueStaging, DialogueGaze and FaceDriver do with no
## authored cutscene. Saves a still a moment into each line and one at each
## set of choices, always taking the first choice.
##
##   Godot --resolution 1600x900 res://tools/dialogue_stills_demo.tscn -- --out <dir>

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const HERO: UnitDefinition = preload("res://data/units/npcs/proof_hero.tres")
const NPC_NAME := "Scared Townperson"
const STAND_OFF := 1.5
const INTO_LINE := 0.9
const MAX_STILLS := 14

var _out := ""
var _count := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	_out = args[i + 1] if i >= 0 and i + 1 < args.size() else "user://dialogue_stills"
	DirAccess.make_dir_recursive_absolute(_out)
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

	var npc: Unit = WorldManager.spawn_parent().find_child(NPC_NAME, true, false) as Unit
	if npc == null:
		print("DEMO: no ", NPC_NAME)
		get_tree().quit(1)
		return
	var hero: Unit = HERO.unit_scene.instantiate()
	hero.definition = HERO
	WorldManager.spawn_parent().add_child(hero)
	var ahead: Vector3 = npc.visual_forward()
	ahead.y = 0.0
	hero.global_position = npc.global_position + ahead.normalized() * STAND_OFF
	hero.snap_face_point(npc.global_position)
	npc.snap_face_point(hero.global_position)
	await _wait(1.0)

	var cast := {"player": hero, "npc": npc, "leader": hero}
	var root: DialogueNode = npc.resolve_dialogue_root(Conversation.new(null, cast))
	var c: Conversation = TalkInteraction.start(root, cast)
	if c == null:
		print("DEMO: the conversation was refused")
		get_tree().quit(1)
		return

	var seen := 0
	var idle := 0.0
	while not c.ended and _count < MAX_STILLS:
		await get_tree().process_frame
		if c.transcript.size() > seen:
			seen = c.transcript.size()
			var entry: Dictionary = c.transcript[seen - 1]
			await _wait(INTO_LINE)
			await _still("line_%s" % entry.speaker, "%s: %s" % [entry.speaker, entry.text])
			var skip := InputEventAction.new()
			skip.action = &"cinematic_advance"
			skip.pressed = true
			Input.parse_input_event(skip)
			idle = 0.0
			continue
		var snap: Dictionary = c.snapshot()
		if not snap.waiting.is_empty() or snap.busy:
			idle = 0.0
			continue
		idle += get_process_delta_time()
		if idle < 1.5:
			continue
		idle = 0.0
		if snap.choices.is_empty():
			break
		await _still("choices", "choices: %s" % [snap.choices.map(func(e): return e.text)])
		c.choose(snap.choices[0].id)
	await _wait(0.5)
	print("DEMO done, ", _count, " stills")
	get_tree().quit()


func _still(label: String, note: String) -> void:
	await RenderingServer.frame_post_draw
	var path := "%s/%02d_%s.png" % [_out, _count, label]
	get_viewport().get_texture().get_image().save_png(path)
	print("STILL ", path.get_file(), " | ", note)
	_count += 1


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

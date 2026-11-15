extends Node
## Standalone walkthrough — NOT a test, NOT part of tests/run.sh.
## Plays the paired kill (cinematics/paired_stab.tscn, a PairedActionBeat)
## three times in the quarry, each from a different start: on the clip's own
## places, half a metre too far with the victim's back turned, and too near
## and off to one side. The log prints how far the sword's tip is from the
## victim's chest on the contact frame.
##
##   Godot --resolution 1600x900 --write-movie <out.avi> --fixed-fps 30 res://tools/paired_stab_demo.tscn

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const HERO: UnitDefinition = preload("res://data/units/companions/human_barbarian.tres")
const SCENE: PackedScene = preload("res://cinematics/paired_stab.tscn")
const PAIR: PairedClip = preload("res://assets/paired_clips/stab.tres")
const SWORD: PackedScene = preload("res://scenes/weapons/iron_sword.tscn")
const BLADE := 0.787
## Metres further off, metres aside, degrees the victim is turned away.
const STARTS: Array = [
	{"further": 0.0, "aside": 0.0, "turned": 0.0, "name": "Take 1: standing where the clips were made for"},
	{"further": 0.5, "aside": 0.0, "turned": 150.0, "name": "Take 2: half a metre too far, back turned"},
	{"further": -0.4, "aside": 0.4, "turned": -50.0, "name": "Take 3: too near and off to one side"},
]

var _caption: Label


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

	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_caption = Label.new()
	_caption.position = Vector2(28, 20)
	_caption.add_theme_font_size_override("font_size", 26)
	_caption.add_theme_color_override("font_outline_color", Color.BLACK)
	_caption.add_theme_constant_override("outline_size", 10)
	layer.add_child(_caption)

	var ahead: Vector3 = PartyManager.leader.visual_forward()
	ahead.y = 0.0
	ahead = ahead.normalized()
	var side: Vector3 = ahead.cross(Vector3.UP)
	var reach: float = PAIR.partner_from_lead.origin.z

	for i in STARTS.size():
		var start: Dictionary = STARTS[i]
		var base: Vector3 = PartyManager.leader.global_position + ahead * 3.0 + side * [7.0, 8.5, 5.5][i]
		var killer: Unit = _spawn(base)
		var victim: Unit = _spawn(base + ahead * (reach + start.further) + side * start.aside)
		await _wait(0.6)
		killer.snap_face_point(killer.global_position + ahead)
		victim.snap_face_point(victim.global_position - ahead.rotated(Vector3.UP, deg_to_rad(start.turned)))
		StandIn.body_of(killer).main_hand_grip.add_child(SWORD.instantiate())
		_say(start.name)

		var cast := SceneCast.new().track_unit(&"killer", killer).track_unit(&"victim", victim)
		var result: Array = []
		_play(cast, result)
		var measured := false
		while result.is_empty():
			await get_tree().process_frame
			var tree: BodyAnimationTree = BodyAnimationTree.of(StandIn.body_of(killer))
			if not measured and tree and String(tree.current_animation) == PAIR.lead_clip \
					and tree.current_animation_position >= PAIR.contact_time:
				measured = true
				print("DEMO %s: tip %.3f m from the chest at contact" % [start.name,
					_tip(StandIn.body_of(killer)).distance_to(_bone(StandIn.body_of(victim), "UpperChest"))])
		print("DEMO victim alive: ", is_instance_valid(victim) and victim.is_alive())
		await _wait(1.0)
		if is_instance_valid(killer):
			killer.queue_free()
		if is_instance_valid(victim):
			victim.queue_free()

	print("DEMO done")
	get_tree().quit()


func _spawn(at: Vector3) -> Unit:
	var unit: Unit = HERO.unit_scene.instantiate()
	unit.definition = HERO
	WorldManager.spawn_parent().add_child(unit)
	unit.global_position = at
	return unit


func _play(cast: SceneCast, result: Array) -> void:
	result.append(await CinematicDirector.play(SCENE, cast))


func _tip(model: CharacterModel) -> Vector3:
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	var hand: Transform3D = skeleton.get_bone_global_pose(skeleton.find_bone("RightHand"))
	return skeleton.global_transform * hand * model.main_hand_grip.transform * Vector3(0.0, BLADE, 0.0)


func _bone(model: CharacterModel, bone: String) -> Vector3:
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone)).origin


func _say(text: String) -> void:
	_caption.text = text
	print("DEMO caption: ", text)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

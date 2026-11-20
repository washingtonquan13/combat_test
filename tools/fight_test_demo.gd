extends Node
## Standalone walkthrough — NOT a test, NOT part of tests/run.sh.
## Plays the duel (cinematics/fight_test.tscn: a PairedActionBeat on
## assets/paired_clips/duel.tres) once in the quarry, the hero on the CC
## male body against the townsperson on the CC female body, a sword each.
## The log prints how far apart the blades are at the two parries, how far
## the point is from the shoulder at the hit, and how far each body's hips
## jump on the frame the duel hands back to standing.
##
##   Godot --resolution 1600x900 --write-movie <out.avi> --fixed-fps 30 res://tools/fight_test_demo.tscn

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const LEAD: UnitDefinition = preload("res://data/units/companions/player_character.tres")
const PARTNER: UnitDefinition = preload("res://data/units/npcs/townsperson.tres")
const SCENE: PackedScene = preload("res://cinematics/fight_test.tscn")
const PAIR: PairedClip = preload("res://assets/paired_clips/duel.tres")
const SWORD: PackedScene = preload("res://scenes/weapons/iron_sword.tscn")
const BLADE := 0.787
## What each contact is: two blades meeting, or the lead's point in a body.
const KINDS: Array[String] = ["parry", "parry", "hit"]


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

	var ahead: Vector3 = PartyManager.leader.visual_forward()
	ahead.y = 0.0
	ahead = ahead.normalized()
	var side: Vector3 = ahead.cross(Vector3.UP)
	var base: Vector3 = PartyManager.leader.global_position + ahead * 3.0 + side * 6.0
	var lead: Unit = _spawn(LEAD, base)
	var partner: Unit = _spawn(PARTNER, base + ahead * PAIR.partner_from_lead.origin.length())
	await _wait(1.5)
	lead.snap_face_point(lead.global_position + ahead)
	partner.snap_face_point(partner.global_position - ahead)
	for unit: Unit in [lead, partner]:
		StandIn.body_of(unit).main_hand_grip.add_child(SWORD.instantiate())

	var cast := SceneCast.new().track_unit(&"lead", lead).track_unit(&"partner", partner)
	var result: Array = []
	_play(cast, result)
	var next := 0
	var was_fighting := false
	var hips_before: Array = []
	while result.is_empty():
		await get_tree().process_frame
		var a: CharacterModel = StandIn.body_of(lead)
		var b: CharacterModel = StandIn.body_of(partner)
		var tree: BodyAnimationTree = BodyAnimationTree.of(a)
		if tree == null:
			continue
		var fighting: bool = String(tree.current_animation) == PAIR.lead_clip
		if fighting:
			hips_before = [_bone(a, "Hips"), _bone(b, "Hips")]
			var t: float = tree.current_animation_position
			if next < PAIR.contacts.size() and t >= PAIR.contacts[next]:
				if KINDS[next] == "parry":
					print("DEMO contact %d (parry) at %.3f s: blades %.3f m apart" % [next, t,
						_gap(_blade(a), _blade(b))])
				else:
					var shoulder: Vector3 = _bone(b, "LeftUpperArm")
					var edge: Array = _blade(a)
					print("DEMO contact %d (hit) at %.3f s: point %.3f m from the shoulder, blade %.3f m" % [next, t,
						(edge[1] as Vector3).distance_to(shoulder),
						shoulder.distance_to(Geometry3D.get_closest_point_to_segment(shoulder, edge[0], edge[1]))])
				next += 1
		elif was_fighting:
			await get_tree().process_frame
			print("DEMO hand-back hips jump: lead %.3f m, partner %.3f m" % [
				_flat(hips_before[0] - _bone(a, "Hips")), _flat(hips_before[1] - _bone(b, "Hips"))])
		was_fighting = fighting
	print("DEMO partner alive: ", partner.is_alive())
	await _wait(1.0)
	print("DEMO done")
	get_tree().quit()


func _spawn(definition: UnitDefinition, at: Vector3) -> Unit:
	var unit: Unit = definition.unit_scene.instantiate()
	unit.definition = definition
	WorldManager.spawn_parent().add_child(unit)
	unit.global_position = at
	return unit


func _play(cast: SceneCast, result: Array) -> void:
	result.append(await CinematicDirector.play(SCENE, cast))


## [hilt, point] of the sword in `model`'s hand, in the world.
func _blade(model: CharacterModel) -> Array:
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	var hand: Transform3D = skeleton.get_bone_global_pose(skeleton.find_bone("RightHand"))
	var grip: Transform3D = skeleton.global_transform * hand * model.main_hand_grip.transform
	return [grip.origin, grip * Vector3(0.0, BLADE, 0.0)]


func _gap(one: Array, two: Array) -> float:
	var closest: PackedVector3Array = Geometry3D.get_closest_points_between_segments(one[0], one[1], two[0], two[1])
	return closest[0].distance_to(closest[1])


func _bone(model: CharacterModel, bone: String) -> Vector3:
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone)).origin


func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

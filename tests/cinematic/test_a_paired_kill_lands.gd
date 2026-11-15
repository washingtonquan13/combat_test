extends AiTestCase
## A paired kill lands wherever the two started (PairedActionBeat): the
## scene's stab is played from starts half a metre out in each direction,
## and on the contact frame the sword's tip is in the other body's chest
## every time. When it is over the one stabbed is dead, lying where the
## clip left them.

const SCENE: PackedScene = preload("res://cinematics/paired_stab.tscn")
const PAIR: PairedClip = preload("res://assets/paired_clips/stab.tres")
const BLADE := 0.787
## How far from the middle of the chest the tip may be at contact.
const IN_THE_CHEST := 0.22
## Where the partner starts, from where the clip wants them: metres further
## off, metres to the side, and degrees turned away.
const STARTS: Array = [
	[0.0, 0.0, 0.0],
	[0.5, 0.0, 0.0],
	[-0.5, 0.0, 40.0],
	[0.0, 0.5, -60.0],
	[0.35, -0.35, 180.0],
]


func wants_world() -> bool:
	return true


func run() -> void:
	# Each on ground of its own: the last one's body is still lying there.
	for i in STARTS.size():
		var start: Array = STARTS[i]
		await _stab(8.0 + i * 5.0, start[0], start[1], start[2])
		free_spawned()
		await get_tree().process_frame


func _stab(x: float, further: float, aside: float, turned: float) -> void:
	var label: String = "%+.2f m off, %+.2f m aside, turned %d" % [further, aside, turned]
	var reach: float = PAIR.partner_from_lead.origin.z
	var killer: Unit = spawn_brute(x, 0.0)
	var victim: Unit = spawn_brute(x + aside, reach + further)
	await get_tree().process_frame
	killer.snap_face_point(killer.global_position + Vector3.BACK)
	victim.snap_face_point(victim.global_position + Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(turned)))

	var cast := SceneCast.new().track_unit(&"killer", killer).track_unit(&"victim", victim)
	var result: Array = []
	_play(cast, result)
	var tree: BodyAnimationTree = null
	var waited := 0.0
	while result.is_empty() and waited < 10.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		tree = BodyAnimationTree.of(StandIn.body_of(killer))
		if tree and String(tree.current_animation) == PAIR.lead_clip \
				and tree.current_animation_position >= PAIR.contact_time:
			break
	check("%s: the lunge reaches its contact frame" % label, result.is_empty() and waited < 10.0)
	var tip: Vector3 = _tip(StandIn.body_of(killer))
	var chest: Vector3 = _bone(StandIn.body_of(victim), "UpperChest")
	check("%s: the tip is in the chest at contact" % label, tip.distance_to(chest) < IN_THE_CHEST,
		"%.3f m from it" % tip.distance_to(chest))

	while result.is_empty():
		await get_tree().process_frame
	check("%s: the one stabbed is dead" % label, not victim.is_alive())
	for i in 3:
		await get_tree().process_frame
	var head: float = _bone(StandIn.body_of(victim), "Head").y - victim.global_position.y
	check("%s: and lies where the clip left them" % label, head < 0.45, "head %.2f m up" % head)


func _play(cast: SceneCast, result: Array) -> void:
	result.append(await CinematicDirector.play(SCENE, cast))


func _tip(model: CharacterModel) -> Vector3:
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	var hand: Transform3D = skeleton.get_bone_global_pose(skeleton.find_bone("RightHand"))
	return skeleton.global_transform * hand * model.main_hand_grip.transform * Vector3(0.0, BLADE, 0.0)


func _bone(model: CharacterModel, bone: String) -> Vector3:
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone)).origin

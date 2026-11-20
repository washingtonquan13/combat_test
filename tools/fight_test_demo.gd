extends Node
## Standalone walkthrough — NOT a test, NOT part of tests/run.sh.
## Plays the duel (cinematics/fight_test.tscn: a PairedActionBeat on
## assets/paired_clips/duel.tres) once in the quarry, the hero on the CC
## male body against the townsperson on the CC female body, a sword each.
## The log prints how far apart the blades are at the two parries, how far
## the point is from the shoulder at the hit, and how far each body's hips
## jump on the frame the duel hands back to standing. Then, per contact,
## the impact layer as it played (CinematicStage.impact): that nothing stops
## on the contact (no hit-stop), how long the camera shook, how
## many frames early the sound started, whether the spark or blood spawned,
## the frame the struck body's reaction began, and the cut check.
##
##   Godot --resolution 1600x900 --write-movie <out.avi> --fixed-fps 30 res://tools/fight_test_demo.tscn

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const LEAD: UnitDefinition = preload("res://data/units/companions/player_character.tres")
const PARTNER: UnitDefinition = preload("res://data/units/npcs/townsperson.tres")
const SCENE: PackedScene = preload("res://cinematics/fight_test.tscn")
const PAIR: PairedClip = preload("res://assets/paired_clips/duel.tres")
const SWORD: PackedScene = preload("res://scenes/weapons/iron_sword.tscn")
const BLADE := 0.787
const FRAME := 1.0 / 30.0


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
	var seen := 0
	var was_fighting := false
	var hips_before: Array = []
	# One per impact: what the frames after it measured.
	var watch: Array[Dictionary] = []
	while result.is_empty():
		# After every node's _process this frame, before it is drawn: what is
		# read here is what this frame shows.
		await RenderingServer.frame_pre_draw
		var a: CharacterModel = StandIn.body_of(lead)
		var b: CharacterModel = StandIn.body_of(partner)
		var tree: BodyAnimationTree = BodyAnimationTree.of(a)
		var stage: CinematicStage = CinematicDirector.current_stage()
		var camera: CinematicCamera = CinematicDirector.camera()
		if tree == null or stage == null:
			continue
		var frame: int = Engine.get_process_frames()
		for w: Dictionary in watch:
			_follow(w, stage, camera, a, b, frame)
		var impacts: Array = stage.impact_log.filter(func(r: Dictionary) -> bool: return not r.get("early", false))
		while seen < impacts.size():
			var record: Dictionary = impacts[seen]
			var event: ContactEvent = record.event
			var w: Dictionary = {i = seen, record = record, shake_end = -1, peak = 0.0, flinch = -1,
				still = 0, still_done = false,
				pose = [_bone(a, "Hips"), _bone(b, "Hips"), _bone(a, "RightHand"), _bone(b, "RightHand")]}
			for earlier: Dictionary in watch:
				earlier.peak_done = true  # a new shake starts; the last one's peak is taken
			watch.append(w)
			if event.kind == ContactEvent.Kind.PARRY:
				print("DEMO contact %d (parry) at %.3f s: blades %.3f m apart" % [seen, event.time,
					_gap(_blade(a), _blade(b))])
			else:
				var shoulder: Vector3 = _bone(b, "LeftUpperArm")
				var edge: Array = _blade(a)
				print("DEMO contact %d (hit) at %.3f s: point %.3f m from the shoulder, blade %.3f m" % [seen, event.time,
					(edge[1] as Vector3).distance_to(shoulder),
					shoulder.distance_to(Geometry3D.get_closest_point_to_segment(shoulder, edge[0], edge[1]))])
			_follow(w, stage, camera, a, b, frame)
			seen += 1
		var fighting: bool = String(tree.current_animation) == PAIR.lead_clip
		if fighting:
			hips_before = [_bone(a, "Hips"), _bone(b, "Hips")]
		elif was_fighting:
			await get_tree().process_frame
			print("DEMO hand-back hips jump: lead %.3f m, partner %.3f m" % [
				_flat(hips_before[0] - _bone(a, "Hips")), _flat(hips_before[1] - _bone(b, "Hips"))])
		was_fighting = fighting
	for w: Dictionary in watch:
		var record: Dictionary = w.record
		var event: ContactEvent = record.event
		var early: int = record.frame - record.heard_frame if record.heard_frame >= 0 else -99
		print("DEMO impact %d %s: contact pose shown %d more frame(s) (0 = no hit-stop)" % [
			w.i, event.describe(), w.still])
		print("DEMO impact %d: trauma %.2f, shake asked %.2f s, shook %.3f s to zero, peak offset %.4f m" % [
			w.i, record.trauma, record.shake, (w.shake_end - record.frame) * FRAME if w.shake_end >= 0 else -1.0, w.peak])
		print("DEMO impact %d: sound %d frame(s) early, %s spawned at %s, reaction %s" % [
			w.i, early, "blood" if event.draws_blood() else "spark", "yes" if record.get("vfx", false) else "NO",
			"n/a (parry)" if event.kind == ContactEvent.Kind.PARRY else
				("frame %d after the contact" % (w.flinch - record.frame)) if w.flinch >= 0 else "NONE"])
	var problems: PackedStringArray = _cut_problems
	print("DEMO cut check: shot changes at %s; problems: %s" % [_cut_times, "none" if problems.is_empty() else "; ".join(problems)])
	print("DEMO partner alive: ", partner.is_alive())
	await _wait(1.0)
	print("DEMO done")
	get_tree().quit()


var _cut_problems := PackedStringArray()
var _cut_times := PackedFloat32Array()


## One frame of what an impact did, from its contact frame on.
func _follow(w: Dictionary, stage: CinematicStage, camera: CinematicCamera,
		a: CharacterModel, b: CharacterModel, frame: int) -> void:
	_cut_problems = stage.cut_problems()
	_cut_times = stage.shot_change_times()
	var record: Dictionary = w.record
	if frame == record.frame:
		return
	var now: Array = [_bone(a, "Hips"), _bone(b, "Hips"), _bone(a, "RightHand"), _bone(b, "RightHand")]
	var drift: float = 0.0
	for k in 4:
		drift = maxf(drift, (now[k] as Vector3).distance_to(w.pose[k]))
	# Frames after the contact frame that show the contact pose again.
	if not w.still_done:
		if drift < 0.00001:
			w.still += 1
		else:
			w.still_done = true
	if camera and not w.get("peak_done", false) and w.shake_end < 0:
		w.peak = maxf(w.peak, camera.shake_offset())
		if w.shake_end < 0 and camera.trauma() <= 0.0:
			w.shake_end = frame
	var tree: BodyAnimationTree = BodyAnimationTree.of(b)
	if w.flinch < 0 and tree and tree.is_flinching():
		w.flinch = frame


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

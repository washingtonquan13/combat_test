extends Node
## Standalone walkthrough — NOT a test, NOT part of tests/run.sh.
## Plays Showcase 1's duel (cinematics/duel_m2.tscn) in the quarry: the
## victim cornered by the rocks, the attacker closing on her, the hero
## leaping in, one exchange and the kill. Then plays it again and skips it
## a second in, to show the skip lands in the same end state.
##
## The log prints every number docs/plans/bg3_cinematics.md's M2 exit asks
## for: per impact the shake, sound lead and reaction, and that nothing
## stops on it (no hit-stop); the contact times and their gaps; the kill
## contact gap; how far the music duck leads the kill; the cut check; the
## framing check (FramingCheck: who is on screen, how big, heads in frame,
## the 180-degree line); the end states; and how flat the ground is under
## the marks.
##
##   Godot --resolution 1600x900 --write-movie <out.avi> --fixed-fps 30 res://tools/duel_m2_demo.tscn

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const HERO: UnitDefinition = preload("res://data/units/companions/player_character.tres")
const ATTACKER: UnitDefinition = preload("res://data/units/npcs/proof_hero.tres")
const VICTIM: UnitDefinition = preload("res://data/units/npcs/townsperson.tres")
const SCENE: PackedScene = preload("res://cinematics/duel_m2.tscn")
const SWORD: PackedScene = preload("res://scenes/weapons/iron_sword.tscn")
const BLADE := 0.787
const FRAME := 1.0 / 30.0
## Preloaded, not named: a new class_name is unknown to a run until an editor
## has rescanned the project.
const FRAMING_CHECK := preload("res://systems/cinematic_system/framing_check.gd")
## The stage's marks, stage-local, read from duel_m2.tscn itself.
var MARKS := {}

var _anchor: Marker3D


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

	var probe: Node = SCENE.instantiate()
	for mark: String in ["landing", "attacker_spot", "victim_spot"]:
		MARKS[mark] = (probe.find_child(mark, true, false) as Node3D).transform
	probe.free()
	var ahead: Vector3 = PartyManager.leader.visual_forward()
	ahead.y = 0.0
	ahead = ahead.normalized()
	var side: Vector3 = ahead.cross(Vector3.UP)
	var base: Vector3 = PartyManager.leader.global_position + ahead * 3.0 + side * 6.0
	_anchor = Marker3D.new()
	_anchor.name = "duel_m2_anchor"
	_anchor.add_to_group("scene_marks")
	WorldManager.spawn_parent().add_child(_anchor)
	_anchor.global_transform = _flattest(base)
	base = _anchor.global_position
	for mark: String in MARKS:
		var at: Vector3 = _world(mark).origin
		print("DEMO ground under %s: %+.3f m from the anchor's height" % [mark, _ground(at, at.y) - base.y])

	var units: Array = await _cast_up()
	await _watch_run(units[0], units[1], units[2])

	for unit: Variant in units:
		if is_instance_valid(unit):
			unit.queue_free()
	await _wait(1.0)
	Music.unduck(0.0)
	units = await _cast_up()
	var hero: Unit = units[0]
	var attacker: Unit = units[1]
	var victim: Unit = units[2]
	var hp_before: float = victim.get_pool(StatIds.HP)
	var result: Array = []
	_play(units, result)
	await _wait(1.0)
	CinematicDirector._skip_requested = true
	while result.is_empty():
		await get_tree().process_frame
	await _wait(0.5)
	print("DEMO skip run: attacker %s; victim alive %s, HP %d -> %d of %d; hero alive %s; duck %.1f dB" % [
		_state(attacker), victim.is_alive(), hp_before,
		victim.get_pool(StatIds.HP), roundi(victim.get_stat(StatIds.HP)), hero.is_alive(), Music.get("_duck_db")])
	await _wait(1.0)
	print("DEMO done")
	get_tree().quit()


func _cast_up() -> Array:
	var hero: Unit = _spawn(HERO, _world("landing").origin + Vector3(0, 0, 40))
	var attacker: Unit = _spawn(ATTACKER, _world("attacker_spot").origin)
	var victim: Unit = _spawn(VICTIM, _world("victim_spot").origin)
	await _wait(1.5)
	for unit: Unit in [hero, attacker]:
		StandIn.body_of(unit).main_hand_grip.add_child(SWORD.instantiate())
	return [hero, attacker, victim]


func _watch_run(hero: Unit, attacker: Unit, victim: Unit) -> void:
	var hp_before: float = victim.get_pool(StatIds.HP)
	var result: Array = []
	_play([hero, attacker, victim], result)
	var seen := 0
	var watch: Array[Dictionary] = []
	var duck_frame := -1
	var kill_frame := -1
	var facing_printed := false
	var framing: RefCounted = FRAMING_CHECK.new()
	while result.is_empty():
		await RenderingServer.frame_pre_draw
		# Framing first: the attacker's unit can go away once he is dead, and
		# the aftermath still has to be measured.
		if CinematicDirector.current_stage():
			framing.sample(CinematicDirector.current_stage())
		if not is_instance_valid(attacker) or not is_instance_valid(hero):
			continue
		var a: CharacterModel = StandIn.body_of(hero)
		var b: CharacterModel = StandIn.body_of(attacker)
		var stage: CinematicStage = CinematicDirector.current_stage()
		var camera: CinematicCamera = CinematicDirector.camera()
		if a == null or b == null or stage == null:
			continue
		var frame: int = Engine.get_process_frames()
		if duck_frame < 0 and float(Music.get("_duck_db")) <= -59.0:
			duck_frame = frame
		for w: Dictionary in watch:
			_follow(w, stage, camera, a, b, frame)
		var impacts: Array = stage.impact_log.filter(func(r: Dictionary) -> bool: return not r.get("early", false))
		while seen < impacts.size():
			var record: Dictionary = impacts[seen]
			var event: ContactEvent = record.event
			var w: Dictionary = {i = seen, record = record, shake_end = -1, peak = 0.0,
				still = 0, still_done = false,
				solo = event.kind == ContactEvent.Kind.LAND,
				pose = [_bone(a, "Hips"), _bone(b, "Hips"), _bone(a, "RightHand"), _bone(b, "RightHand")]}
			for earlier: Dictionary in watch:
				earlier.peak_done = true
			watch.append(w)
			if event.kind == ContactEvent.Kind.LAND:
				var land: Vector3 = _world("landing").origin
				print("DEMO landing: hero hips %.3f m (flat) from the landing mark, impact point %.3f m from it, height %+.3f" % [
					_flat(_bone(a, "Hips") - land), _flat(record.point - land), record.point.y - land.y])
			if not facing_printed:
				facing_printed = true
				for pair: Array in [[hero, "landing"], [attacker, "attacker_spot"], [victim, "victim_spot"]]:
					var unit: Unit = pair[0]
					var want: Vector3 = _world(pair[1]).basis.z
					var have: Vector3 = unit.visual_forward()
					print("DEMO facing %s: visual_forward %s, mark +Z %s, %.1f deg apart" % [
						pair[1], have.snappedf(0.01), want.snappedf(0.01),
						rad_to_deg(Vector2(have.x, have.z).angle_to(Vector2(want.x, want.z)))])
			if event.kind == ContactEvent.Kind.KILL:
				kill_frame = frame
				var edge: Array = _blade(a)
				print("DEMO kill contact: point %.4f m from the attacker's Spine" % (edge[1] as Vector3).distance_to(_bone(b, "Spine")))
			_follow(w, stage, camera, a, b, frame)
			seen += 1
	var times: PackedFloat32Array = []
	for w: Dictionary in watch:
		var record: Dictionary = w.record
		var event: ContactEvent = record.event
		times.append(record.at)
		var early: int = record.frame - record.heard_frame if record.heard_frame >= 0 else -99
		print("DEMO impact %d %s at scene %.3f s: contact pose shown %d more frame(s) (0 = no hit-stop)" % [
			w.i, event.describe(), record.at, w.still])
		print("DEMO impact %d: trauma %.2f, shake asked %.2f s, shook %.3f s to zero, peak %.4f m; sound %d frame(s) early, vfx %s" % [
			w.i, record.trauma, record.shake, (w.shake_end - record.frame) * FRAME if w.shake_end >= 0 else -1.0,
			w.peak, early, "yes" if record.get("vfx", false) else "none"])
	var gaps: PackedFloat32Array = []
	for k in range(1, times.size()):
		gaps.append(times[k] - times[k - 1])
	var even := false
	for k in range(2, gaps.size()):
		var lo: float = minf(gaps[k - 2], minf(gaps[k - 1], gaps[k]))
		var hi: float = maxf(gaps[k - 2], maxf(gaps[k - 1], gaps[k]))
		even = even or hi <= lo * 1.15
	print("DEMO contacts at %s, gaps %s, burst span %.3f s, three even gaps in a row: %s" % [
		times, gaps, times[-1] - times[0] if times.size() > 1 else 0.0, "YES" if even else "no"])
	if kill_frame >= 0:
		print("DEMO music duck reached -59 dB %.3f s before the kill (need >= 0.5)" % ((kill_frame - duck_frame) * FRAME if duck_frame >= 0 else -99.0))
	for line: String in framing.report():
		print("DEMO framing " + line)
	var framing_problems: PackedStringArray = framing.problems()
	print("DEMO framing check: %s" % ("no problems" if framing_problems.is_empty() else "%d problem(s)" % framing_problems.size()))
	for line: String in framing_problems:
		print("DEMO framing problem: " + line)
	print("DEMO cut check: shot changes at %s; problems: %s" % [_cut_times, "none" if _cut_problems.is_empty() else "; ".join(_cut_problems)])
	print("DEMO played run: attacker %s; victim alive %s, HP %d -> %d of %d; hero alive %s" % [
		_state(attacker), victim.is_alive(), hp_before, victim.get_pool(StatIds.HP),
		roundi(victim.get_stat(StatIds.HP)), hero.is_alive()])
	await _wait(1.0)


var _cut_problems := PackedStringArray()
var _cut_times := PackedFloat32Array()


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
		if w.get("solo", false) and k % 2 == 1:
			continue  # a landing is about the one who lands
		drift = maxf(drift, (now[k] as Vector3).distance_to(w.pose[k]))
	# Frames after the contact frame that show the contact pose again: with
	# no hit-stop there are none.
	if not w.still_done:
		if drift < 0.00001:
			w.still += 1
		else:
			w.still_done = true
	if camera and not w.get("peak_done", false) and w.shake_end < 0:
		w.peak = maxf(w.peak, camera.shake_offset())
		if camera.trauma() <= 0.0:
			w.shake_end = frame


## A dead unit is freed after its death_cleanup_delay; either way it is out.
func _state(unit: Variant) -> String:
	if not is_instance_valid(unit) or unit.is_queued_for_deletion():
		return "dead (body cleaned up)"
	return "alive" if (unit as Unit).is_alive() else "dead"


## The anchor near `near` (within 8 m, any turn) whose marks stand most
## level: PairedActionBeat is made for level ground, and a partner standing
## 10 cm low takes the thrust 10 cm high.
func _flattest(near: Vector3) -> Transform3D:
	var best := Transform3D(Basis.IDENTITY, Vector3(near.x, _ground(near, near.y), near.z))
	var best_spread := INF
	for ring in range(0, 9):
		for step in range(0, maxi(1, ring * 6)):
			var spot: Vector3 = near + Vector3(ring, 0, 0).rotated(Vector3.UP, TAU * step / maxi(1, ring * 6))
			spot.y = _ground(spot, INF)
			if spot.y == INF:
				continue
			for turn in range(0, 12):
				var at := Transform3D(Basis(Vector3.UP, TAU * turn / 12.0), spot)
				var lo := INF
				var hi := -INF
				for mark: String in MARKS:
					var p: Vector3 = (at * (MARKS[mark] as Transform3D)).origin
					var y: float = _ground(p, INF)
					lo = minf(lo, y)
					hi = maxf(hi, y)
				if hi - lo < best_spread:
					best_spread = hi - lo
					best = at
	print("DEMO anchor: %s, turned %.0f deg, marks' ground spread %.3f m" % [
		best.origin.snappedf(0.01), rad_to_deg(best.basis.get_euler().y), best_spread])
	return best


func _world(mark: String) -> Transform3D:
	return _anchor.global_transform * (MARKS[mark] as Transform3D)


func _ground(at: Vector3, fallback: float) -> float:
	var space: PhysicsDirectSpaceState3D = WorldManager.spawn_parent().get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 5.0, at + Vector3.DOWN * 10.0)
	var hit: Dictionary = space.intersect_ray(query)
	return hit.position.y if hit else fallback


func _spawn(definition: UnitDefinition, at: Vector3) -> Unit:
	var unit: Unit = definition.unit_scene.instantiate()
	unit.definition = definition
	WorldManager.spawn_parent().add_child(unit)
	unit.global_position = at
	return unit


func _play(units: Array, result: Array) -> void:
	var cast := SceneCast.new().track_unit(&"hero", units[0]).track_unit(&"attacker", units[1]).track_unit(&"victim", units[2])
	result.append(await CinematicDirector.play(SCENE, cast))


func _blade(model: CharacterModel) -> Array:
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	var hand: Transform3D = skeleton.get_bone_global_pose(skeleton.find_bone("RightHand"))
	var grip: Transform3D = skeleton.global_transform * hand * model.main_hand_grip.transform
	return [grip.origin, grip * Vector3(0.0, BLADE, 0.0)]


func _bone(model: CharacterModel, bone: String) -> Vector3:
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone)).origin


func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


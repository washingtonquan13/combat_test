extends "res://tools/dragon_demo.gd"
## Recorded showcase of the dragon body at SM +2, +3 and +4 in a row beside
## the SM 0 hero - NOT a test. Each is test_dragon with its SM changed, so
## the one SM 0 body is worn at 2.5x, 3.5x and 5x.

## Override with `-- --sizes=4,7` on the command line.
var SIZES: Array[int] = [2, 3, 4]
## The body's nose and tail from its torso centre at SM 0, in metres
## (export_dragon.py's rest bounding box).
const NOSE: float = 0.59
const TAIL: float = 1.41
const GAP: float = 1.5
## Half the rest wingspan at SM 0: the near wing reaches this far toward
## the camera in a side-on shot.
const HALF_SPAN: float = 1.41

var _dragons: Array[Unit] = []
var _centres: Array[Vector3] = []
var _origin: Vector3
var _line: Vector3
var _length: float


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sizes="):
			SIZES.assign(Array(arg.trim_prefix("--sizes=").split(",")).map(func(x): return int(x)))
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.visible = false
	var camera: CRPGCamera = _camera()
	camera.min_distance = 3.0
	camera.max_distance = 80.0
	camera.min_pitch = 8.0
	camera.max_pitch = 14.0

	_length = _row_length()
	if not _find_row():
		print("DEMO RESULT: no clear ground for a %.0f m row" % _length)
		get_tree().quit()
		return
	_hero.global_position = _origin
	_hero.snap_face_direction(_toward())
	SelectionManager.select(_hero)
	_spawn_row()
	await _wait(0.5)

	await _row_shot()
	await _close_ups()
	await _flight()

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.5)
	get_tree().quit()


## The row from the hero's far side to the last tail: hero, then each
## dragon nose first, GAP apart.
func _row_distance() -> float:
	var k: float = SizeModifier.scale_for(SIZES.max())
	return maxf(_length * 0.62, HALF_SPAN * k + 6.0)


func _row_length() -> float:
	var s: float = 0.25 + GAP
	for sm in SIZES:
		var k: float = SizeModifier.scale_for(sm)
		s += (NOSE + TAIL) * k + GAP
	return s


func _spawn_row() -> void:
	var s: float = 0.25 + GAP
	for sm in SIZES:
		var k: float = SizeModifier.scale_for(sm)
		s += NOSE * k
		var centre: Vector3 = _origin + _line * s
		s += TAIL * k + GAP
		var definition: UnitDefinition = load("res://data/units/demons/dragon.tres").duplicate()
		definition.stats = definition.stats.duplicate()
		definition.stats[&"SM"] = sm
		definition.display_name = "Dragon SM +%d" % sm
		var unit: Unit = definition.unit_scene.instantiate()
		unit.definition = definition
		unit.faction = Unit.PLAYER_FACTION
		WorldManager.spawn_parent().add_child(unit)
		unit.global_position = centre
		unit.snap_face_direction(-_line)
		_dragons.append(unit)
		_centres.append(centre)


func _across() -> Vector3:
	return _line.cross(Vector3.UP).normalized()


## From the row toward the camera in the side-on shots: the camera looks
## along -_toward(), which puts the hero on the left of the screen.
func _toward() -> Vector3:
	return _across()


## Points the camera along look (flat), so it sits on look's far side.
func _look(look: Vector3) -> void:
	var camera: CRPGCamera = _camera()
	camera.target_yaw = rad_to_deg(atan2(-look.x, -look.z))


func _row_shot() -> void:
	var middle: Vector3 = _origin + _line * (_length * 0.5) + Vector3(0, 1.8, 0)
	_frame(middle, _row_distance())
	_look(-_toward())
	await _wait(2.0)
	_say("SM 0 hero, then one dragon body at " + ", ".join(SIZES.map(func(sm): return "SM +%d (%.0f m)" % [sm, SizeModifier.length_for(sm)])))
	for i in SIZES.size():
		var want: float = SizeModifier.scale_for(SIZES[i])
		_check("SM +%d worn at %.1fx" % [SIZES[i], want], absf(_dragons[i].worn_size - want) < 0.01)
		_check("SM +%d plays Idle" % SIZES[i], _clip_of(_dragons[i]) == &"Idle")
	await _wait(3.5)
	var camera: CRPGCamera = _camera()
	for step in 6:
		camera.target_yaw = camera.current_yaw + 60.0
		await _wait(1.7)
	_look(-_toward())
	await _wait(1.5)


## The hero beside each dragon in turn, side on: stood at its flank,
## between it and the camera.
func _close_ups() -> void:
	for i in SIZES.size():
		var sm: int = SIZES[i]
		var k: float = SizeModifier.scale_for(sm)
		var mid: Vector3 = _centres[i] + _line * ((TAIL - NOSE) * k * 0.5)
		# Ahead of the nose, a step toward the camera: clear of the wings,
		# which spread sideways from the shoulders.
		_hero.global_position = _centres[i] - _line * (NOSE * k + 1.0) + _toward() * 0.8
		_hero.snap_face_direction((_toward() + _line).normalized())
		_frame(mid + Vector3(0, 0.45 * k, 0), maxf(1.24 * (NOSE + TAIL) * k * 0.5 + 3.0, HALF_SPAN * k + 4.0))
		_look(-_toward())
		_say("SM +%d: %.0f m nose to tail, %.1fx the SM 0 body, beside a 1.8 m hero" % [sm, SizeModifier.length_for(sm), k])
		await _wait(4.0)
	_hero.global_position = _origin
	_hero.snap_face_direction(_toward())


func _flight() -> void:
	var middle: Vector3 = _origin + _line * (_length * 0.5) + Vector3(0, 3.5, 0)
	_frame(middle, _row_distance())
	_look(-_toward())
	await _wait(2.0)
	_say("Fly: the same 3 m takeoff height at every size")
	for dragon in _dragons:
		Fly.effects[0].apply(dragon, null, Fly, false)
		await _wait(0.35)
	await _wait(3.0)
	for i in SIZES.size():
		_check("SM +%d aloft in Fly" % SIZES[i], _clip_of(_dragons[i]) == &"Fly")
	await _wait(2.5)
	_say("Land")
	for dragon in _dragons:
		dragon.land(true)
	await _wait(5.0)
	for i in SIZES.size():
		_check("SM +%d back in Idle" % SIZES[i], _clip_of(_dragons[i]) == &"Idle")
	await _wait(1.0)


func _clip_of(unit: Unit) -> StringName:
	var player: AnimationPlayer = unit.find_children("AnimationPlayer", "AnimationPlayer", true, false)[0]
	var name := String(player.current_animation)
	return StringName(name.get_slice("/", name.get_slice_count("/") - 1))


## Finds flat, empty ground for the row near where the hero arrived: an
## origin and a direction whose strip, wings' width either side, has a
## floor at the hero's height all along and nothing standing on it.
func _find_row() -> bool:
	var start: Vector3 = _hero.global_position
	var offsets: Array[Vector2] = []
	for x in range(-30, 31, 5):
		for z in range(-30, 31, 5):
			offsets.append(Vector2(x, z))
	offsets.sort_custom(func(a, b): return a.length() < b.length())
	for o in offsets:
		var ground = _floor_at(start + Vector3(o.x, 0, o.y))
		if ground == null:
			continue
		for d in 8:
			var a: float = TAU * d / 8.0
			var line := Vector3(sin(a), 0, cos(a))
			if _row_clear(ground, line):
				_origin = ground
				_line = line
				print("DRAGON ROW origin ", _origin, " line ", _line, " length ", _length)
				return true
	return false


func _row_clear(origin: Vector3, line: Vector3) -> bool:
	for t in 9:
		var p = _floor_at(origin + line * (_length * t / 8.0))
		if p == null or absf(p.y - origin.y) > 0.2:
			return false
	var across := line.cross(Vector3.UP).normalized()
	for side in [-6.0, 6.0]:
		for t in 5:
			var p = _floor_at(origin + line * (_length * t / 4.0) + across * side)
			if p == null or absf(p.y - origin.y) > 0.2:
				return false
	var box := BoxShape3D.new()
	box.size = Vector3(14.0, 6.0, _length + 2.0)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(Basis.looking_at(line), origin + line * (_length * 0.5) + Vector3(0, 3.3, 0))
	query.collide_with_areas = false
	for hit in _space().intersect_shape(query, 32):
		if not hit.collider is CharacterBody3D:
			return false
	return true


func _floor_at(p: Vector3):
	var ray := PhysicsRayQueryParameters3D.create(p + Vector3(0, 6, 0), p - Vector3(0, 6, 0))
	ray.exclude = PartyManager.members.map(func(m): return m.get_rid())
	var hit: Dictionary = _space().intersect_ray(ray)
	return hit.position if hit else null


func _space() -> PhysicsDirectSpaceState3D:
	return _hero.get_world_3d().direct_space_state

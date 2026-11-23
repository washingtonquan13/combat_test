extends "res://tools/dragon_sizes_demo.gd"
## Recorded showcase of the SM 6 dragon flying - NOT a test. Beside the
## hero, takeoff, a flying circuit with the camera following, landing.
## Also logs how far below the unit's origin the wings reach in each
## flight clip, to judge how much takeoff height the body really needs.


func _run() -> void:
	SIZES = [6]
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.visible = false
	var camera: CRPGCamera = _camera()
	camera.min_distance = 3.0
	camera.max_distance = 80.0
	_length = _row_length()
	if not _find_row():
		print("DEMO RESULT: no clear ground for a %.0f m row" % _length)
		get_tree().quit()
		return
	_hero.global_position = _origin
	_hero.snap_face_direction(_toward())
	SelectionManager.select(_hero)
	_spawn_row()
	var dragon: Unit = _dragons[0]
	_dragon = dragon
	await _wait(0.5)

	var mid: Vector3 = _centres[0] + Vector3(0, 3.0, 0)
	_frame(mid, 34.0)
	_look(-_toward())
	await _wait(1.5)
	_say("Dragon, SM 6: 20 m nose to tail, beside the 1.8 m hero")
	_check("plays Idle", _clip() == &"Idle")
	await _wait(3.0)

	_say("Fly: Takeoff into the Fly loop")
	_probe_wings(dragon, "Idle")
	camera.focus_target = dragon
	camera.target_distance = 40.0
	Fly.effects[0].apply(dragon, null, Fly, false)
	await _sample_wings(dragon, 2.6, "Takeoff")
	_check("aloft plays Fly", _clip() == &"Fly")
	_check("it is flying", dragon.is_flying())
	await _sample_wings(dragon, 2.0, "Fly")

	var legs: Array[Vector3] = [
		_origin + _line * (_length * 0.9) + _across() * 14.0,
		_origin - _line * 6.0 + _across() * 18.0,
		_centres[0],
	]
	var captions := ["A flying move order, the camera following", "Banking round the hero", "And back"]
	for i in legs.size():
		_say(captions[i])
		_check("leg %d accepted" % (i + 1), dragon.move_to(legs[i]))
		var yaw0 := camera.current_yaw
		var t := 0.0
		var start := dragon.global_position
		var steps := 0
		var backwards := 0
		var last := start
		await get_tree().process_frame
		_check("leg %d plays Fly_Forward" % (i + 1), _clip() == &"Fly_Forward")
		while dragon.is_moving() and t < 12.0:
			var flat := Vector3(dragon.global_position.x - last.x, 0, dragon.global_position.z - last.z)
			var ahead := Vector3(legs[i].x - last.x, 0, legs[i].z - last.z)
			if flat.length() > 0.001 and ahead.length() > 1.0:
				steps += 1
				if flat.dot(ahead) < 0.0:
					backwards += 1
			last = dragon.global_position
			camera.target_yaw = yaw0 + t * 6.0
			await get_tree().process_frame
			t += get_process_delta_time()
		print("DRAGON leg %d: %.1f s, %d of %d frames moved away from the goal, ended %.1f m short" % [i + 1, t, backwards, steps, Vector2(dragon.global_position.x - legs[i].x, dragon.global_position.z - legs[i].z).length()])
		_check("leg %d never bounces back" % (i + 1), backwards == 0)
		await _wait(1.0)
		_check("leg %d settles back to Fly" % (i + 1), _clip() == &"Fly")

	_say("Land: down in the Fly loop, Land on touchdown")
	camera.target_distance = 34.0
	var down := [false]
	dragon.touched_down.connect(func(_u): down[0] = true, CONNECT_ONE_SHOT)
	dragon.land(true)
	await _until(func(): return down[0], 8.0)
	await _wait(0.1)
	_check("touchdown plays Land", _clip() == &"Land")
	await _wait(3.0)
	_check("back in Idle", _clip() == &"Idle")
	await _wait(1.5)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.0)
	get_tree().quit()


var _wing_low := {}


func _sample_wings(unit: Unit, seconds: float, label: String) -> void:
	var left := seconds
	while left > 0.0:
		_probe_wings(unit, label)
		await get_tree().process_frame
		left -= get_process_delta_time()
	var k: float = SizeModifier.scale_for(floori(unit.get_stat(StatIds.SM)))
	print("DRAGON lowest bone below origin in %s: %.2f m (%.3f m at SM 0)" % [label, _wing_low[label], _wing_low[label] / k])


## The lowest bone below the unit's origin (its feet), positive = below.
func _probe_wings(unit: Unit, label: String) -> void:
	var skeleton: Skeleton3D = unit.find_children("*", "Skeleton3D", true, false)[0]
	var low := -INF
	for i in skeleton.get_bone_count():
		var p: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(i).origin
		low = maxf(low, unit.global_position.y - p.y)
	_wing_low[label] = maxf(_wing_low.get(label, -INF), low)

extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase of the hero's locomotion - NOT a test. Breathing Idle,
## the turns in place standing, a move behind (turn first, then the walk
## start), a walk stop, and a long move into the run and its stop. Record it
## the same way as item_layer_demo, without opengl3.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var home: Vector3 = _hero.global_position
	var ahead: Vector3 = _hero.visual_forward()
	var right: Vector3 = ahead.cross(Vector3.UP)
	_frame(home + Vector3(0.0, 1.0, 0.0), 5.0)
	await _wait(1.5)

	_say("Breathing Idle")
	await _wait(5.0)
	_say("Turn in place, 90 left")
	await _face(-right, 3.0)
	_say("Turn in place, 180")
	await _face(right, 3.5)
	_say("Turn in place, 90 right")
	await _face(-ahead, 3.0)
	_say("Short move behind: turn, walk start, walk stop")
	await _go(home + ahead * 4.0)
	await _wait(2.5)
	_frame(home + ahead * 4.0 + Vector3(0.0, 1.0, 0.0), 9.0)
	_say("Long move: run, run stop")
	await _go(home + ahead * 4.0 + right * 16.0)
	await _wait(3.0)
	get_tree().quit()


## Faces `direction` the way gameplay does: face_direction every physics frame.
func _face(direction: Vector3, seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		var dt: float = get_physics_process_delta_time()
		_hero.face_direction(direction, dt)
		await get_tree().physics_frame
		left -= dt
		if fmod(left, 0.5) < dt:
			print("  yaw %.1f, turning %s" % [rad_to_deg(_hero.rotation.y), _hero.animator().locomotion.turning()])


func _go(to: Vector3) -> void:
	if not _hero.move_to(to):
		_say("move refused")
		return
	await get_tree().physics_frame
	while _hero.is_moving():
		await get_tree().physics_frame

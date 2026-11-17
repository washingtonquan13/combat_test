extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase of the hero's locomotion - NOT a test. Warrior Idle,
## the turns in place standing, a short move behind (under way at once,
## swinging round as it steps off), a walk that a click further on breaks
## into the run, and a run sent back the other way. Prints how soon each
## order is under way. Record it the same way as item_layer_demo, without
## opengl3. The camera follows the hero, close. INERTIA=0 in the environment
## records it with plain crossfades instead of BodyInertia, for a before
## and after.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	BodyAnimationTree.of(_hero).inertia().enabled = OS.get_environment("INERTIA") != "0"
	var home: Vector3 = _hero.global_position
	var ahead: Vector3 = _hero.visual_forward()
	var right: Vector3 = ahead.cross(Vector3.UP)
	_follow(4.5)
	await _wait(1.5)

	_say("Warrior Idle")
	await _wait(3.0)
	_say("Turn in place, 90 left (standing)")
	await _face(-right, 2.5)
	_say("Turn in place, 180 (standing)")
	await _face(right, 3.0)
	_say("Short move behind: steps off at once, swings round")
	await _go(home - ahead * 1.5)
	await _wait(2.0)
	var at: Vector3 = _hero.global_position
	_say("Walk, then a click further on: breaks into the run")
	_order(at + ahead * 1.5)
	await _wait(0.6)
	await _go(at + ahead * 9.0)
	await _wait(2.0)
	at = _hero.global_position
	_say("Run, then a click back the other way")
	_order(at + right * 10.0)
	await _wait(1.0)
	await _go(at - right * 2.0)
	await _wait(3.0)
	get_tree().quit()


## The camera on the hero, `distance` away, following.
func _follow(distance: float) -> void:
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	camera.focus_target = _hero
	camera.target_anchor_offset = Vector3.ZERO
	camera.target_distance = distance
	camera.target_yaw = camera.current_yaw + 70.0


## Orders a move and prints how long the unit took to be under way and how
## its gait goes over the next second.
func _order(to: Vector3) -> bool:
	var from: Vector3 = _hero.global_position
	if not _hero.move_to(to):
		_say("move refused")
		return false
	var loco: UnitLocomotion = _hero.animator().locomotion
	var t: float = 0.0
	var under_way: float = -1.0
	for i in 30:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if under_way < 0.0 and _hero.global_position.distance_to(from) > 0.02:
			under_way = t
			print("  under way after %.2f s" % t)
		if i % 6 == 5:
			print("  t %.2f state %s clip %s, walk under %.2f, %.2f m/s" % [t, UnitLocomotion.State.keys()[loco.state],
				_hero.animator().playback.current_animation, _hero.animator().playback.partner_weight(), loco._speed])
	return true


func _go(to: Vector3) -> void:
	if not await _order(to):
		return
	while _hero.is_moving():
		await get_tree().physics_frame


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

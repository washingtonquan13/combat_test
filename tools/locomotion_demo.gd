extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase of the hero's locomotion - NOT a test. Warrior Idle,
## the turns in place standing, a short move behind (under way at once,
## swinging round as it steps off), a walk that a click further on breaks
## into the run, and a run sent back the other way. Prints how soon each
## order is under way. Record it the same way as item_layer_demo, without
## opengl3. The camera follows the hero, close. INERTIA=0 in the environment
## records it with plain crossfades instead of BodyInertia, for a before
## and after. RUN_STOP=walk ends the runs on the walk's stop instead of
## Run To Stop.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	BodyAnimationTree.of(_hero).inertia().enabled = OS.get_environment("INERTIA") != "0"
	UnitLocomotion.runs_end_on_walk_stop = OS.get_environment("RUN_STOP") == "walk"
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
	await _wait(2.0)
	_say("Run a curve, as hold-to-move does: the head leads into it")
	await _curve(_hero.global_position, ahead, right)
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
			print("  t %.2f state %s clip %s, walk under %.2f, %.2f m/s, lead %.0f deg" % [t, UnitLocomotion.State.keys()[loco.state],
				_hero.animator().playback.current_animation, _hero.animator().playback.partner_weight(), loco._speed,
				rad_to_deg(loco._turn_lead._shown) if loco._turn_lead else 0.0])
	return true


func _go(to: Vector3) -> void:
	if not await _order(to):
		return
	var loco: UnitLocomotion = _hero.animator().locomotion
	var n: int = 0
	while _hero.is_moving():
		await get_tree().physics_frame
		n += 1
		var left: float = _hero.global_position.distance_to(to)
		if left < 4.0 and n % 4 == 0:
			var current = _hero.animator().playback._playback.current
			print("  end %.2f m left, %s, %.2f m/s, clip %s at %.2fx, walk under %.2f, entered %.0f deg off" % [left,
				UnitLocomotion.State.keys()[loco.state], loco._speed, _hero.animator().playback.current_animation,
				current.speed_scale if current else 0.0, _hero.animator().playback.partner_weight(), loco.entry_gap])


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


## Orders along a half circle, one ahead of the hero every 0.3 s, the way a
## held button sends them, and prints the lead.
func _curve(from: Vector3, ahead: Vector3, right: Vector3) -> void:
	var loco: UnitLocomotion = _hero.animator().locomotion
	var centre: Vector3 = from + right * 4.0
	for i in 14:
		var angle: float = PI * float(i + 2) / 14.0
		var point: Vector3 = centre - right * 4.0 * cos(angle) + ahead * 4.0 * sin(angle)
		_hero.move_to(point)
		for f in 9:
			await get_tree().physics_frame
		print("  curve %d lead %.0f deg, %.2f m/s, clip %s" % [i, rad_to_deg(loco._turn_lead._shown) if loco._turn_lead else 0.0,
			loco._speed, _hero.animator().playback.current_animation])
	while _hero.is_moving():
		await get_tree().physics_frame

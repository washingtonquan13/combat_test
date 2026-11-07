extends "res://tools/attack_flow_demo.gd"
## Recorded look at the Fireball body animation with its VFX - NOT a test.
## Arm (dip, gather, wind-up) lights the held flame, Hold loops, Cast
## whips and pushes and the ball leaves on the release key. Once at real
## speed, once slowed.

func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	for other in WorldManager.spawn_parent().find_children("*", "Unit", true, false):
		if other != _hero:
			other.visible = false
	# A close camera of its own, three-quarters from the caster's right.
	var fwd: Vector3 = _hero.visual_forward()
	var right: Vector3 = fwd.cross(Vector3.UP)
	var eye := Camera3D.new()
	eye.fov = 50.0
	WorldManager.spawn_parent().add_child(eye)
	eye.global_position = _hero.global_position + right * -4.2 + fwd * 1.6 + Vector3(0, 1.3, 0)
	eye.look_at(_hero.global_position + fwd * 1.6 + Vector3(0, 1.1, 0))
	eye.make_current()
	await _wait(2.0)
	for scale: float in [1.0, 0.35]:
		Engine.time_scale = scale
		_say("Fireball - %s" % ("real speed" if scale == 1.0 else "slowed to 35%"))
		AbilityManager.arm(Fireball)
		await _wait(2.6)
		await _hero.use_ability(Fireball, _spot(-12.0, 0.0))
		await _wait(2.5)
	Engine.time_scale = 1.0
	get_tree().quit()

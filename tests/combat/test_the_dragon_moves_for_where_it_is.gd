extends AiTestCase
## The dragon's clips answer to where it is and what it's doing: aloft it
## plays its air set, a body with no air set plays its usual clips, and it
## steps round on the spot only for a real turn, not for a snap to a target.
##
## Reads UnitAnimator's _aloft and _sequence_for deliberately: flying for
## real needs a Fly cast and a climb that have nothing to do with which clip
## answers.


func run() -> void:
	var dragon: Unit = spawn_demon("dragon", Vector3.ZERO)
	await get_tree().process_frame
	var animator: Node = dragon.get_node("UnitAnimator")
	var player: AnimationPlayer = animator.animation_player

	check("on the ground it bites from the ground", _first(animator, &"attack.bite") == "Bite",
		_first(animator, &"attack.bite"))
	animator._aloft = true
	check("aloft it bites from the air", _first(animator, &"attack.bite") == "Bite_Air",
		_first(animator, &"attack.bite"))
	check("and claws from the air", _first(animator, &"attack.claw") == "Claw_Air",
		_first(animator, &"attack.claw"))
	var breath: AnimationSequence = animator._sequence_for(&"breath")
	check("and breathes through all three air phases",
		breath.phases.map(func(p): return p.animation_name) == ["Breath_Air", "Breath_Hold_Air", "Breath_Out_Air"])
	check("and flinches in the air", animator._clip(&"hit.air") == "Hit_Air", animator._clip(&"hit.air"))
	animator._aloft = false
	check("the bite lands on its keyed moment", _has_moment(player.get_animation("Bite_Air"), &"impact"))
	check("the breath lets go on its keyed moment", _has_moment(player.get_animation("Breath_Air"), &"release"))
	check("knocked down is not dead", animator._clip(&"knockdown") == "Knockdown", animator._clip(&"knockdown"))

	var man: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(20, 0, 0))
	await get_tree().process_frame
	var his: Node = man.get_node("UnitAnimator")
	var grounded: AnimationSequence = his._sequence_for(&"attack.swing")
	his._aloft = true
	check("a body with no air set plays its usual clip", his._sequence_for(&"attack.swing") == grounded)

	await _turning(dragon, player)
	free_spawned()


## Facing is written on render frames (the aim indicator) while the animator
## ticks on physics frames, so this runs at frame rates either side of the
## physics rate.
func _turning(dragon: Unit, player: AnimationPlayer) -> void:
	var cap: int = Engine.max_fps
	for fps: int in [20, 30, 60, 144]:
		Engine.max_fps = fps
		player.play("Idle")
		await _settle()
		await _turn(dragon, 2.0)
		check("at %d fps turning left steps left" % fps, player.current_animation == "Turn_L", player.current_animation)
		await _settle()
		check("at %d fps it stops when the turn does" % fps, player.current_animation == "Idle", player.current_animation)
		await _turn(dragon, -2.0)
		check("at %d fps turning right steps right" % fps, player.current_animation == "Turn_R", player.current_animation)
		await _settle()
		dragon.snap_face_direction(_direction(dragon, 1.0))
		await _physics_frames(2)
		check("at %d fps a snap to a target is not a turn" % fps, player.current_animation == "Idle", player.current_animation)
	Engine.max_fps = cap


func _turn(dragon: Unit, angle: float) -> void:
	var toward: Vector3 = _direction(dragon, angle)
	for i: int in 4:
		await get_tree().process_frame
		dragon.face_direction(toward, get_process_delta_time())
	await _physics_frames(1)


func _direction(dragon: Unit, angle: float) -> Vector3:
	var yaw: float = dragon.rotation.y + angle - deg_to_rad(dragon.facing_offset_degrees)
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func _settle() -> void:
	await get_tree().create_timer(0.3).timeout


func _physics_frames(count: int) -> void:
	for i: int in count:
		await get_tree().physics_frame


func _first(animator: Node, motion: StringName) -> String:
	return animator._sequence_for(motion).phases[0].animation_name


func _has_moment(anim: Animation, method: StringName) -> bool:
	for track: int in anim.get_track_count():
		if anim.track_get_type(track) != Animation.TYPE_METHOD:
			continue
		for key: int in anim.track_get_key_count(track):
			if anim.method_track_get_name(track, key) == method:
				return true
	return false

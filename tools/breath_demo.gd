extends "res://tools/wall_of_fire_demo.gd"
## Recorded showcase of the Fire Breath gust - NOT a test. Real casts
## through use_ability: the Bite clip, the gust down the cone, the burning
## ground it leaves. Prints the world viewport's GPU time before and
## during a gust.

const Breath: Ability = preload("res://data/abilities/fire_breath.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	var ahead: Vector3 = _spot(-5.0, 0.0)
	var below: Vector3 = _spot(-4.0, 0.0)
	_dummy(-5.0, 0.5)
	# The rest of the party well behind and off to the side, out of shot.
	var i: int = 0
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.global_position = _spot(9.0 + i * 1.5, -9.0)
			i += 1
	_frame(below, 12.0)
	# Turned to face down the range before the first frame, so no cast turns it.
	_hero.snap_face_direction(ahead - _hero.global_position)
	var viewport: Viewport = WorldManager.focused_viewport()
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	await _wait(2.0)
	var idle: float = await _gpu_ms(viewport, 30)

	await _wait(0.5)
	_hero.use_ability(Breath, Breath.targeting.resolve_target_point(ahead))
	var gust: Node = await _gust()
	var busy: float = await _gpu_ms(viewport, 20) if gust else -1.0
	print("BREATH GPU ms idle %.2f, during gust %.2f" % [idle, busy])
	await _wait(3.0)
	await _wait(3.0)
	SurfaceManager.expire_all_ground(WorldManager.context())

	# Flying, breathing down onto the ground ahead.
	var ground_y: float = _hero.global_position.y
	var fly: Ability = load("res://data/abilities/fly.tres")
	fly.effects[0].apply(_hero, null, fly, false)
	await _wait(3.0)
	AbilityManager.set_aim_height_override(ground_y)
	_hero.use_ability(Breath, Breath.targeting.resolve_target_point(below))
	AbilityManager.has_aim_height_override = false
	await _wait(5.0)
	get_tree().quit()


## Waits for a gust to appear, up to 3 s.
func _gust() -> Node:
	for i in 180:
		var found: Array = get_tree().root.find_children("FireBreath*", "", true, false)
		if not found.is_empty():
			return found[0]
		await get_tree().process_frame
	print("BREATH no gust appeared")
	return null


func _gpu_ms(viewport: Viewport, frames: int) -> float:
	var total: float = 0.0
	for i in frames:
		await get_tree().process_frame
		total += RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
	return total / frames

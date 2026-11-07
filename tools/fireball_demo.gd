extends "res://tools/wall_of_fire_demo.gd"
## Recorded showcase of the Explosive Fireball blast - NOT a test. Real
## casts through use_ability: a burst on the ground (a full patch of
## burning ground), one 1.5 m up (a smaller patch), one 3.5 m up (none).
## Prints the burning cells each leaves and the GPU time during a blast.

const Fireball: Ability = preload("res://data/abilities/explosive_fireball.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	var ahead: Vector3 = _spot(-8.0, 0.0)
	var i: int = 0
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.global_position = _spot(9.0 + i * 1.5, -9.0)
			i += 1
	_frame(_spot(-5.0, 0.0), 14.0)
	_hero.snap_face_direction(ahead - _hero.global_position)
	var viewport: Viewport = WorldManager.focused_viewport()
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	await _wait(2.0)
	var idle: float = await _gpu_ms(viewport, 30)
	var ground_y: float = ahead.y
	for height: float in [0.0, 1.5, 3.5]:
		if height > 0.0:
			AbilityManager.set_aim_height_override(ground_y + height)
		var target: Vector3 = Fireball.targeting.resolve_target_point(ahead)
		AbilityManager.has_aim_height_override = false
		_hero.use_ability(Fireball, target)
		var blast: Node = await _blast()
		var busy: float = await _gpu_ms(viewport, 20) if blast else -1.0
		await _wait(2.5)
		print("FIREBALL at +%.1f m: %d burning cells, GPU ms idle %.2f, during blast %.2f" % [height, _burning_cells(), idle, busy])
		await _wait(2.0)
		SurfaceManager.expire_all_ground(WorldManager.context())
		await _wait(1.5)
	get_tree().quit()


func _burning_cells() -> int:
	var total: int = 0
	for patch: SurfacePatch in SurfaceManager._grid_for(WorldManager.context()).patches:
		total += patch.cells.size()
	return total


## Waits for a blast to appear, up to 4 s.
func _blast() -> Node:
	for i in 240:
		var found: Array = get_tree().root.find_children("Blast", "", true, false)
		if not found.is_empty():
			return found[0]
		await get_tree().process_frame
	print("FIREBALL no blast appeared")
	return null


func _gpu_ms(viewport: Viewport, frames: int) -> float:
	var total: float = 0.0
	for f in frames:
		await get_tree().process_frame
		total += RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
	return total / frames

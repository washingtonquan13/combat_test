extends "res://tools/fog_cloud_demo.gd"
## Recorded side view, NOT a test: each cloud cast twice side by side,
## round (height_scale 1) on the left, squashed (its authored 0.5) on
## the right, from a camera held low.

const Darkness: Ability = preload("res://data/abilities/darkness.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	camera.min_pitch = 14.0
	camera.max_pitch = 14.0
	var left: Vector3 = _spot(-10.0, -6.0)
	var right: Vector3 = _spot(-10.0, 6.0)
	var yaw: float = camera.current_yaw
	_frame((left + right) * 0.5 + Vector3(0.0, 1.5, 0.0), 24.0)
	camera.target_yaw = yaw
	for ability: Ability in [Fog, Darkness]:
		_say("%s: squashed 0.5 (left) vs round (right)" % ability.ability_name)
		await _wait(1.5)
		var surface: Surface = _cloud(ability)
		var round_surface: Surface = surface.duplicate()
		round_surface.height_scale = 1.0
		SurfaceManager.spawn(round_surface, left + Vector3(0.0, 1.5, 0.0), 5.0, _hero)
		SurfaceManager.spawn(surface, right + Vector3(0.0, 1.5, 0.0), 5.0, _hero)
		await _wait(6.0)
		SurfaceManager.expire_all_clouds(WorldManager.context())
		await _wait(3.0)
	get_tree().quit()



func _cloud(ability: Ability) -> Surface:
	for effect in ability.effects:
		if effect is SpawnSurfaceEffect:
			return effect.surface
	return null

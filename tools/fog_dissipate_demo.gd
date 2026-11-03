extends "res://tools/fog_cloud_demo.gd"
## Recorded close-up of Fog Cloud and Darkness burning off — NOT a test.
## Both clouds cast side by side, then expired together.

const Darkness: Ability = preload("res://data/abilities/darkness.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	# Taken before casting: the hero turns to face its target, which moves _spot().
	var fog_at: Vector3 = _spot(-15.0, 0.0) + Vector3(0.0, 1.5, 0.0)
	var dark_at: Vector3 = _spot(-7.0, 0.0) + Vector3(0.0, 1.5, 0.0)
	_frame(_spot(-10.0, 0.0), 18.0)
	await _hero.use_ability(Fog, fog_at)
	# One cast per turn: the second cloud is spawned the way the spell would.
	SurfaceManager.spawn((Darkness.effects[0] as SpawnSurfaceEffect).surface, dark_at, 5.0, _hero)
	await _wait(6.0)
	_say("Both clouds burn off")
	for active in SurfaceManager.active_surfaces.duplicate():
		SurfaceManager._expire(active)
	await _wait(5.0)
	print("DEMO RESULT: done")
	get_tree().quit()

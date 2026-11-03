extends "res://tools/fog_cloud_demo.gd"
## Recorded close-up of Fog Cloud and Darkness burning off — NOT a test.
## Both clouds cast side by side, then expired together.

const Darkness: Ability = preload("res://data/abilities/darkness.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	_frame(_spot(-6.0, 0.0), 16.0)
	await _hero.use_ability(Fog, _spot(-9.0, 0.0) + Vector3(0.0, 1.5, 0.0))
	# One cast per turn: the second cloud is spawned the way the spell would.
	SurfaceManager.spawn((Darkness.effects[0] as SpawnSurfaceEffect).surface, _spot(-3.0, 0.0) + Vector3(0.0, 1.5, 0.0), 4.5, _hero)
	await _wait(3.0)
	_say("Both clouds burn off")
	for active in SurfaceManager.active_surfaces.duplicate():
		SurfaceManager._expire(active)
	await _wait(5.0)
	print("DEMO RESULT: done")
	get_tree().quit()

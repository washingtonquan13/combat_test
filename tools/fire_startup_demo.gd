extends "res://tools/wall_of_fire_demo.gd"
## Recorded look at fire catching - NOT a test: burning ground cast twice
## (game distance, then close), then Wall of Fire cast twice the same way.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.deselect_all()
	var ground: Surface = (Wall.effects[0] as SpawnSurfaceEffect).surface.leaves_behind
	var spot: Vector3 = _spot(-8.0, 0.0)
	var line := LineTarget.new(_spot(-8.0, -4.0), _spot(-8.0, 4.0))
	for distance: float in [14.0, 7.0]:
		_frame(spot, distance)
		await _wait(1.5)
		_say("Burning ground catches")
		SurfaceManager.spawn(ground, spot, 2.0, _hero)
		await _wait(3.5)
		SurfaceManager.expire_all_ground(WorldManager.context())
		await _wait(2.0)
	for distance: float in [16.0, 9.0]:
		_frame(spot, distance)
		await _wait(1.5)
		_say("Wall of Fire catches")
		await _hero.use_ability(Wall, line)
		await _wait(4.0)
		SurfaceManager.expire_all_clouds(WorldManager.context())
		SurfaceManager.expire_all_ground(WorldManager.context())
		await _wait(2.5)
	print("DEMO RESULT: done")
	get_tree().quit()

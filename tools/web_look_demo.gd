extends "res://tools/surfaces_look_demo.gd"
## Recorded look at the Web surface alone - NOT a test: one patch, seen
## at game distance, then close, then low.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.deselect_all()
	var at: Vector3 = _spot(-8.0, 0.0)
	_frame(at, 18.0)
	await _wait(1.0)
	SurfaceManager.spawn(_ground(preload("res://systems/surface_system/web.tscn")), at, 3.0, _hero)
	_dummy(-8.0, 1.0)
	await _wait(3.0)
	_frame(at, 8.0)
	await _wait(3.0)
	_frame(at, 4.0)
	await _wait(3.0)
	print("DEMO RESULT: done")
	get_tree().quit()

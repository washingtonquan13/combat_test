extends "res://tools/surfaces_look_demo.gd"
## Recorded look at Fire alone, for judging it - NOT a test: from afar,
## up close at two distances, then going out.

const FIRE: PackedScene = preload("res://systems/surface_system/fire.tscn")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.deselect_all()
	var spot: Vector3 = _spot(-12.0, 0.0)
	_frame(spot, 14.0)
	await _wait(1.0)
	var fire: Node3D = FIRE.instantiate()
	WorldManager.spawn_parent().add_child(fire)
	fire.global_position = spot
	fire.scale = Vector3(2.0, 1.0, 2.0)
	_say("Fire")
	await _wait(4.0)
	_frame(spot, 7.0)
	await _wait(5.0)
	_frame(spot, 4.0)
	await _wait(5.0)
	_frame(spot, 9.0)
	await _wait(1.5)
	_say("Fire goes out")
	fire.dissipate()
	await _wait(3.5)
	print("DEMO RESULT: done")
	get_tree().quit()

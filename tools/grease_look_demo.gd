extends "res://tools/fog_cloud_demo.gd"
## Recorded close-up of Grease, for judging its look — NOT a test. The
## patch is cast under the hero (it must not paint them) and over a step
## and a slope (it must drape), then expired.

const Grease: Ability = preload("res://data/abilities/grease.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	var at: Vector3 = _spot(-6.0, 0.0)
	_block(at + Vector3(1.9, 0.15, 0.0), Vector3(1.6, 0.3, 2.5), 0.0)
	_block(at + Vector3(-2.2, 0.0, 0.0), Vector3(2.0, 0.6, 2.5), 15.0)
	# No selection: its movement-range overlay would tint the floor.
	SelectionManager.deselect_all()
	_frame(at, 9.0)
	await _wait(2.0)
	_say("Grease spreads")
	SurfaceManager.spawn((Grease.effects[0] as SpawnSurfaceEffect).surface, at, 3.0, _hero)
	await _wait(2.0)
	_say("Units standing in it stay clean")
	await _walk(_hero, at)
	await _wait(2.0)
	_say("Grease expires")
	for active in SurfaceManager.active_surfaces.duplicate():
		SurfaceManager._expire(active)
	await _wait(2.5)
	print("DEMO RESULT: done")
	get_tree().quit()


## A grey step or slope (tilted about z) for the film to drape over.
func _block(centre: Vector3, extents: Vector3, tilt_degrees: float) -> void:
	var block := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = extents
	block.mesh = mesh
	WorldManager.spawn_parent().add_child(block)
	block.global_position = centre
	block.rotation_degrees.z = tilt_degrees

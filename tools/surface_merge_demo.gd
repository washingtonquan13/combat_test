extends "res://tools/grease_look_demo.gd"
## Recorded check of the surface grid, for judging it - NOT a test. Two
## Grease casts overlap and pool into one film (a red post marks each
## cast's centre, so a mirrored film would show), a third spills up onto
## a step and joins them, Water is cast over part of the pool and takes
## those cells, half the grease dries up, then the rest goes.

const WATER: PackedScene = preload("res://systems/surface_system/water.tscn")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.deselect_all()
	var at: Vector3 = _spot(-8.0, 0.0)
	var grease: Surface = (Grease.effects[0] as SpawnSurfaceEffect).surface
	# Off the world's axes on purpose: the film must land where cast.
	var first: Vector3 = at + Vector3(-1.2, 0.0, -0.8)
	var second: Vector3 = at + Vector3(1.4, 0.0, 1.1)
	var third: Vector3 = at + Vector3(2.6, 0.0, -1.8)
	_block(third + Vector3(0.9, 0.15, -0.4), Vector3(2.0, 0.3, 2.0), 0.0)
	for point in [first, second, third]:
		_post(point)
	_frame(at, 11.0)
	await _wait(2.0)

	_say("Grease")
	SurfaceManager.spawn(grease, first, 2.0, _hero)
	await _wait(2.0)
	_say("More grease overlapping it pools into one")
	SurfaceManager.spawn(grease, second, 1.8, _hero)
	await _wait(2.5)
	_say("Grease spilled up onto a step joins the pool")
	SurfaceManager.spawn(grease, third, 1.6, _hero)
	await _wait(2.5)
	_say("Water cast over the pool takes those cells")
	SurfaceManager.spawn(_water(), at + Vector3(0.3, 0.0, 0.2), 1.3, _hero)
	await _wait(3.0)

	_say("Half the grease dries up")
	var grid: SurfaceGrid = SurfaceManager._grid_for(WorldManager.context())
	for patch in grid.patches.duplicate():
		if patch.surface != grease:
			continue
		var drying: Array[SurfaceCell] = []
		for cell in patch.cells:
			if cell.centre().x < at.x:
				drying.append(cell)
		SurfaceManager.expire_cells(grid, patch, drying)
	await _wait(3.0)
	_say("Everything dries up")
	SurfaceManager.expire_all_ground(WorldManager.context())
	await _wait(3.0)
	print("DEMO RESULT: done")
	get_tree().quit()


## A thin red post at point, on the units' render layer so no film
## paints it.
func _post(point: Vector3) -> void:
	var post := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.05
	mesh.bottom_radius = 0.05
	mesh.height = 1.0
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.9, 0.1, 0.1)
	mesh.material = material
	post.mesh = mesh
	post.layers = 1 << (Unit.RENDER_LAYER - 1)
	WorldManager.spawn_parent().add_child(post)
	post.global_position = point + Vector3(0.0, 0.5, 0.0)


func _water() -> Surface:
	var water := Surface.new()
	water.surface_name = "Water"
	water.shape = Surface.Shape.DISC
	water.duration_rounds = -1
	water.ambient_scene = WATER
	return water

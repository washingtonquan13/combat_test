extends "res://tools/surface_merge_demo.gd"
## Recorded check of the Fire surface's pooling, for judging it - NOT a
## test. Two Fire casts overlap and burn as one, a third spills up onto
## a step and joins them, Water then Grease are cast over parts of the
## fire and put those cells out, half the fire burns out, then the rest.

const FIRE: PackedScene = preload("res://systems/surface_system/fire.tscn")
const GREASE: PackedScene = preload("res://systems/surface_system/grease.tscn")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.deselect_all()
	var at: Vector3 = _spot(-8.0, 0.0)
	var fire: Surface = _ground(FIRE)
	var first: Vector3 = at + Vector3(-1.2, 0.0, -0.8)
	var second: Vector3 = at + Vector3(1.4, 0.0, 1.1)
	var third: Vector3 = at + Vector3(2.6, 0.0, -1.8)
	_block(third + Vector3(0.9, 0.15, -0.4), Vector3(2.0, 0.3, 2.0), 0.0)
	_frame(at, 10.0)
	await _wait(2.0)

	_say("Fire")
	SurfaceManager.spawn(fire, first, 2.0, _hero)
	await _wait(2.5)
	_say("More fire overlapping it burns as one")
	SurfaceManager.spawn(fire, second, 1.8, _hero)
	await _wait(3.0)
	_say("Fire spilled up onto a step joins it")
	SurfaceManager.spawn(fire, third, 1.6, _hero)
	await _wait(3.0)
	_say("Water cast over the fire puts those cells out")
	SurfaceManager.spawn(_water(), at + Vector3(0.3, 0.0, 0.2), 1.3, _hero)
	await _wait(3.5)
	_say("Grease cast over it takes its cells too")
	SurfaceManager.spawn(_ground(GREASE), first + Vector3(-0.6, 0.0, -0.3), 1.1, _hero)
	await _wait(3.5)

	_say("Half the fire burns out")
	var grid: SurfaceGrid = SurfaceManager._grid_for(WorldManager.context())
	for patch in grid.patches.duplicate():
		if patch.surface != fire:
			continue
		var dying: Array[SurfaceCell] = []
		for cell in patch.cells:
			if cell.centre().x < at.x + 0.5:
				dying.append(cell)
		SurfaceManager.expire_cells(grid, patch, dying)
	await _wait(3.0)
	_say("Everything goes")
	SurfaceManager.expire_all_ground(WorldManager.context())
	await _wait(3.0)
	print("DEMO RESULT: done")
	get_tree().quit()


func _ground(look: PackedScene) -> Surface:
	var surface := Surface.new()
	surface.shape = Surface.Shape.DISC
	surface.duration_rounds = -1
	surface.ambient_scene = look
	return surface

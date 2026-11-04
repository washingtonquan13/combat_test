extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase of Wall of Fire — NOT a test. A longbow shot, then a
## wall between the shooter and the dummy, a dummy walking through it, a
## second dummy flying through it, and the wall running out and leaving
## burning ground. Record it the same way as fog_cloud_demo.

const Wall: Ability = preload("res://data/abilities/wall_of_fire.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	_hero.set_base_stat(StatIds.DX, 14)
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/longbow.tres")))
	var middle: Vector3 = _spot(-6.0, 0.0)
	var far: Vector3 = _spot(-12.0, 0.0)
	var near: Vector3 = _spot(-2.5, 1.5)
	var line := LineTarget.new(_spot(-6.0, -5.0), _spot(-6.0, 5.0))
	var flier_start: Vector3 = _spot(-12.0, -2.0) + Vector3.UP * 2.5
	var dummy: Unit = _dummy(-12.0, 0.0)
	var wall_surface: Surface = (Wall.effects[0] as SpawnSurfaceEffect).surface
	var burning: StatusEffect = wall_surface.status_effect
	SelectionManager.select(_hero)
	_frame(middle, 16.0)
	await _wait(2.0)
	var shoot: Ability = _attack("Shoot")

	_check("clear field: the hero sees the dummy", LineOfSight.has_clear_shot(_hero, dummy))
	await _fire(shoot, dummy, "Clear line: shoot the dummy 12 m away")

	_say("Cast Wall of Fire across the field: click its start, then its end")
	await _wait(1.5)
	await _hero.use_ability(Wall, line)
	await _wait(2.5)
	_check("the wall blocks the sight line", not LineOfSight.has_clear_shot(_hero, dummy))
	await _fire(shoot, dummy, "Shoot through the wall")
	_check("no burning ground under it yet (no double dip)", SurfaceManager.surface_at(middle, WorldManager.context()) == null)

	_say("The dummy walks through the wall")
	await _walk(dummy, near)
	await _wait(0.5)
	_check("walking through set it Burning", dummy.has_status(burning))
	_say("Through it: Burning")
	await _wait(2.5)

	var flier: Unit = _dummy(-12.0, -2.0)
	flier.global_position = flier_start
	_say("A second dummy flies through, 2.5 m up")
	await _wait(1.0)
	await _walk(flier, near + Vector3(0.0, 2.5, -1.5))
	await _wait(0.5)
	_check("flying through set it Burning too", flier.has_status(burning))
	_say("Flying through: Burning too")
	await _wait(2.5)

	_say("Out of combat a round is 6 s: when its 5 rounds are up...")
	_frame(middle, 13.0)
	await _wait(1.5)
	# Real quiet rounds have ticked meanwhile too: step only until it's out.
	while not SurfaceManager.cloud_grid.is_empty():
		SurfaceManager._on_quiet_round()
	await _wait(2.0)
	_check("the wall has run out", SurfaceManager.cloud_grid.is_empty())
	var left: Surface = SurfaceManager.surface_at(middle, WorldManager.context())
	_check("it left burning ground where it stood", left != null and left == wall_surface.leaves_behind)
	_check("the sight line is clear again", LineOfSight.has_clear_shot(_hero, dummy))
	var cell: SurfaceCell = WorldManager.context().surface_grid.cell_under(middle)
	_check("the burning ground has its full 2 rounds", cell != null and cell.rounds == wall_surface.leaves_behind.duration_rounds)
	_say("...it has burned down, leaving the ground on fire for 2 rounds")
	await _wait(5.0)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.0)
	get_tree().quit()

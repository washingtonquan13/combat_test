extends "res://tools/breakable_demo.gd"
## Recorded showcase of oil barrels — NOT a test. One smashed cold spills
## oil where it stood. A fire bolt into a row of them sets the first off,
## and each blast sets off the next a beat later, burning the crate and
## the dummy standing between them.

const OIL: PackedScene = preload("res://systems/interaction_system/props/oil_barrel.tscn")
const CRATE_PROP: PackedScene = preload("res://systems/interaction_system/props/crate.tscn")
const FIRE_BOLT: Ability = preload("res://data/abilities/fire_bolt.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	_hero.set_base_stat(StatIds.DX, 16)
	_hero.set_base_stat(StatIds.ST, 16)
	SelectionManager.select(_hero)

	var cold: Breakable = _place(OIL, -2.5, 1.5)
	_frame(cold.aim_point().lerp(_hero.global_position, 0.5), 4.5)
	_say("An oil barrel: %d HP, DR %d. Smash it cold" % [cold.full_hp(), cold.dr])
	await _wait(2.5)
	var stood: Vector3 = cold.ground_point()
	_hero.move_to(stood + (_hero.global_position - stood).normalized() * 1.0)
	while _hero.is_moving():
		await get_tree().process_frame
	await _wait(0.5)
	var swings := 0
	while is_instance_valid(cold) and cold.is_alive() and swings < 10:
		swings += 1
		_hero.reset_turn_actions()
		await _hero.use_ability(_hero.default_ability(), cold)
		await _until_idle(6.0)
		await _wait(0.5)
	var spilled: Surface = SurfaceManager.surface_at(stood, WorldManager.context_for(_hero))
	_check("the cold barrel broke", not is_instance_valid(cold) or not cold.is_alive())
	_check("it spilled oil", spilled != null and spilled.resource_path.ends_with("grease.tres"))
	_say("Broken: it spills oil where it stood")
	await _wait(4.0)

	var row: Array[Breakable] = [_place(OIL, -7.0, -2.0), _place(OIL, -7.0, 0.0), _place(OIL, -7.0, 2.0)]
	var crate: Breakable = _place(CRATE_PROP, -8.2, 1.0)
	var dummy: Unit = _dummy(-8.2, -1.0)
	_frame(row[1].aim_point().lerp(_hero.global_position, 0.3), 7.0)
	_say("Three oil barrels, a crate and a dummy. A fire bolt into the first")
	await _wait(3.0)
	var hp: int = dummy.get_pool(StatIds.HP)
	_hero.reset_turn_actions()
	_hero.set_pool(StatIds.FP, 30)
	await _hero.use_ability(FIRE_BOLT, row[0])
	await _wait(2.5)
	var gone := 0
	for barrel in row:
		gone += int(not is_instance_valid(barrel) or not barrel.is_alive())
	var crate_note: String = "broken" if not is_instance_valid(crate) or not crate.is_alive() else "%d/%d HP" % [crate.hp, crate.full_hp()]
	_say("%d of 3 barrels went off. The dummy took %d, the crate is %s" % [gone, hp - dummy.get_pool(StatIds.HP), crate_note])
	_check("the chain reached every barrel", gone == 3)
	await _wait(6.0)
	get_tree().quit()


func _place(scene: PackedScene, forward: float, side: float) -> Breakable:
	var prop: Node3D = scene.instantiate()
	WorldManager.spawn_parent().add_child(prop)
	prop.global_position = _spot(forward, side)
	var breakable: Breakable = Breakable.of(prop)
	NavigationGrid.invalidate_region(prop, breakable.box())
	return breakable

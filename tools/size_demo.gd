extends "res://tools/wall_of_fire_demo.gd"
## Recorded showcase of Size Modifier worn physically - NOT a test. A pixie
## (SM -4), the hero (SM 0) and a dragon (SM +2) side by side, selected so
## the rings show, then the dragon walks past.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	var i: int = 0
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.global_position = _spot(9.0 + i * 1.5, -9.0)
			i += 1
	var pixie: Unit = _spawn("res://data/units/demons/test_pixie.tres", _spot(-3.0, -1.5))
	var dragon: Unit = _spawn("res://data/units/demons/dragon.tres", _spot(-3.0, 2.5))
	for unit: Unit in [_hero, pixie, dragon]:
		print("SIZE %s SM %d scale %.2f radius %.2f height %.2f chest %.2f" % [unit.display_name,
			unit.get_stat(StatIds.SM), unit.get_node("CharacterModel").scale.x, unit.radius, unit.height,
			unit.anchor(CharacterModel.Anchor.CHEST).y - unit.global_position.y])
	print("STEP frame")
	_frame(_spot(-3.0, 0.5), 11.0)
	print("STEP framed paused=%s" % get_tree().paused)
	await _wait(2.0)
	print("STEP select _hero")
	SelectionManager.select(_hero)
	await _wait(2.0)
	print("STEP select dragon")
	SelectionManager.select(dragon)
	await _wait(2.0)
	print("STEP select pixie")
	SelectionManager.select(pixie)
	await _wait(2.0)
	get_tree().quit()


func _spawn(path: String, at: Vector3) -> Unit:
	var unit: Unit = load(path).unit_scene.instantiate()
	unit.definition = load(path)
	unit.faction = _hero.faction
	WorldManager.spawn_parent().add_child(unit)
	unit.global_position = at
	unit.snap_face_direction(_hero.visual_forward())
	return unit

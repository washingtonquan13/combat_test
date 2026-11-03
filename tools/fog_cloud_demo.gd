extends "res://tools/weapons_demo.gd"
## Recorded showcase of Fog Cloud — NOT a test. Reuses the weapons demo's
## boot, dummy and shot helpers. A longbow shot, then a cloud between the
## shooter and the dummy, a dummy walking in and out of it, a cloud
## hanging overhead, and the cloud running out. Record it the same way
## as item_layer_demo.

const Fog: Ability = preload("res://data/abilities/fog_cloud.tres")

var _marker := Node3D.new()


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	_hero.set_base_stat(StatIds.DX, 14)
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/longbow.tres")))
	# Fixed now: the hero turns to face what it shoots, which flips _spot().
	var middle: Vector3 = _spot(-6.0, 0.0)
	var far: Vector3 = _spot(-12.0, 0.0)
	var dummy: Unit = _dummy(-12.0, 0.0)
	var blinded: StatusEffect = (Fog.effects[0] as SpawnSurfaceEffect).surface.status_effect
	SelectionManager.select(_hero)
	_frame(middle, 14.0)
	await _wait(2.0)
	var shoot: Ability = _attack("Shoot")

	_check("clear field: the hero sees the dummy", LineOfSight.has_clear_shot(_hero, dummy))
	await _fire(shoot, dummy, "Clear line: shoot the dummy 12 m away")

	_say("Cast Fog Cloud between them, at chest height")
	await _wait(1.5)
	await _hero.use_ability(Fog, middle + Vector3(0.0, 1.5, 0.0))
	await _wait(2.5)
	_check("the cloud blocks the sight line", not LineOfSight.has_clear_shot(_hero, dummy))
	await _fire(shoot, dummy, "Shoot through the fog")

	_say("The dummy walks into the cloud")
	await _walk(dummy, middle)
	await _wait(1.0)
	_check("inside the cloud it is Blinded (-10 to its attacks)", dummy.has_status(blinded))
	_say("Inside: Blinded, -10 to its attacks")
	await _wait(3.0)

	_say("It walks back out")
	await _walk(dummy, far)
	await _wait(1.0)
	_check("out of the cloud, Blinded comes off", not dummy.has_status(blinded))
	_say("Outside again: Blinded is gone")
	await _wait(2.5)

	_say("The cloud fades")
	SurfaceManager.expire_all_clouds(WorldManager.context())
	await _wait(4.0)

	_say("A second cloud, lifted high overhead (Ctrl-drag in game)")
	await _wait(1.0)
	await _hero.use_ability(Fog, middle + Vector3(0.0, 7.0, 0.0))
	_frame(middle + Vector3(0.0, 2.0, 0.0), 18.0)
	await _wait(3.0)
	_check("a cloud overhead leaves the sight line clear", LineOfSight.has_clear_shot(_hero, dummy))
	await _fire(shoot, dummy, "Shoot under it")
	var high: Vector3 = Vector3(0.0, 7.0, 0.0)
	_check("a sight line at the cloud's height is blocked", SurfaceManager.blocks_sight(_hero, _hero.global_position + high, far + high))
	_say("Up in the air it still blocks sight at its own height")
	_frame(middle + Vector3(0.0, 4.0, 0.0), 16.0)
	await _wait(4.0)

	_say("Out of combat a round is 6 s: 10 rounds later...")
	await _wait(1.5)
	for _i in SurfaceManager.cloud_grid.cells.values()[0].rounds:
		SurfaceManager._on_quiet_round()
	await _wait(4.0)
	_check("it has run out", SurfaceManager.cloud_grid.is_empty())
	_say("...it has run out")
	await _wait(2.0)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.0)
	get_tree().quit()


## Points the follow camera at a fixed spot instead of the selection.
func _frame(point: Vector3, distance: float) -> void:
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	if not _marker.is_inside_tree():
		WorldManager.spawn_parent().add_child(_marker)
	_marker.global_position = point
	camera.focus_target = _marker
	# Bound from unbound keeps the old anchor; centre on the marker.
	camera.target_anchor_offset = Vector3.ZERO
	camera.target_distance = distance
	camera.target_yaw = camera.current_yaw + 70.0


func _walk(unit: Unit, to: Vector3) -> void:
	var tween := create_tween()
	tween.tween_property(unit, "global_position", to, 2.0)
	await tween.finished

extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase of Darkness — NOT a test. The fog demo's stage: a
## shot blocked by the cloud, the same shot with Dark Vision, a dummy
## Blinded inside, then one with Dark Vision that is not, and the
## darkness burning off.

const Darkness: Ability = preload("res://data/abilities/darkness.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	_hero.set_base_stat(StatIds.DX, 14)
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/longbow.tres")))
	var middle: Vector3 = _spot(-6.0, 0.0)
	var far: Vector3 = _spot(-12.0, 0.0)
	var dummy: Unit = _dummy(-12.0, 0.0)
	var blinded: StatusEffect = (Darkness.effects[0] as SpawnSurfaceEffect).surface.status_effect
	SelectionManager.select(_hero)
	_frame(middle, 14.0)
	await _wait(2.0)
	var shoot: Ability = _attack("Shoot")

	_say("Cast Darkness between them")
	await _wait(1.0)
	await _hero.use_ability(Darkness, middle + Vector3(0.0, 1.5, 0.0))
	await _wait(2.5)
	_check("Darkness blocks the hero's sight", not LineOfSight.has_clear_shot(_hero, dummy))
	await _fire(shoot, dummy, "No Dark Vision: the shot is blocked")

	_hero.dark_vision = true
	_check("with Dark Vision the hero sees through", LineOfSight.has_clear_shot(_hero, dummy))
	await _fire(shoot, dummy, "Give the hero Dark Vision: it sees straight through")
	_hero.dark_vision = false

	_say("A dummy without Dark Vision walks in")
	await _walk(dummy, middle)
	await _wait(1.0)
	_check("inside, it is Blinded", dummy.has_status(blinded))
	_say("Blinded inside")
	await _wait(2.0)
	await _walk(dummy, far)
	await _wait(0.5)

	dummy.dark_vision = true
	_say("Now the dummy has Dark Vision and walks in again")
	await _walk(dummy, middle)
	await _wait(1.0)
	_check("with Dark Vision it is not Blinded", not dummy.has_status(blinded))
	_say("Not Blinded: it sees in the dark")
	await _wait(2.5)

	_say("The darkness burns off")
	for active in SurfaceManager.active_surfaces.duplicate():
		SurfaceManager._expire(active)
	await _wait(4.0)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.0)
	get_tree().quit()

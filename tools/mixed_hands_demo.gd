extends "res://tools/weapon_visuals_demo.gd"
## Recorded look at one weapon set holding a sword and a pistol - NOT a
## test. Set I: iron sword in the main hand, pistol in the off hand.
## Swings at a near dummy, then shoots a far one from the same set, no
## swap. Record it with tools/render_movie.sh on the patched Godot.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for key in EquipSlot.HAND_SLOTS:
		if _hero.get_equipped_item(key):
			_hero.unequip_item(key)
	_hero.set_base_stat(StatIds.DX, 16)
	SelectionManager.select(_hero)
	_say("Set I: iron sword in the main hand, pistol in the off hand")
	_hero.equip_item(MAIN, ItemInstance.new(IronSword))
	_hero.equip_item(OFF, ItemInstance.new(load("res://data/items/pistol.tres")))
	_hero.set_weapons_sheathed(false)
	var near: Unit = _dummy(-1.2, 0.0)
	var far: Unit = _dummy(-8.0, 1.5)
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	camera.min_distance = 2.0
	camera.focus_target = _hero
	camera.target_anchor_offset = Vector3.ZERO
	camera.target_distance = 3.2
	# From the hero's front-left, so both hands face the camera.
	var side: Vector3 = _hero.visual_forward().rotated(Vector3.UP, deg_to_rad(-50.0))
	camera.target_yaw = rad_to_deg(atan2(side.x, side.z))
	await _wait(3.0)
	var body := _hero.get_node("CharacterModel") as CharacterModel
	print("[mixed] held main=%s off=%s grips main=%s off=%s sheathed=%s set=%d" % [
		_weapons(_hero).held_model(MAIN), _weapons(_hero).held_model(OFF),
		body.main_hand_grip, body.off_hand_grip, _hero.weapons_sheathed, _hero.active_weapon_set])
	_check("both are in hand", _weapons(_hero).held_model(MAIN) != null and _weapons(_hero).held_model(OFF) != null)
	_check("one set offers both", _names().has("Swing") and _names().has("Shoot (off hand)"))
	print("[mixed] attacks: ", _names())

	_say("Swing with the sword")
	await _timed(_attack("Swing"), near)
	await _wait(1.5)
	_say("Shoot with the pistol, same set, no swap")
	var t: Dictionary = await _timed(_attack("Shoot (off hand)"), far)
	_check("the sword stayed in hand while shooting", _weapons(_hero).held_model(MAIN) != null)
	_check("the pistol fired (%s)" % t.clip, t.releases.size() > 0)
	await _wait(2.5)

	var total := _passed + _failed.size()
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(1.0)
	get_tree().quit()

extends "res://tools/weapon_visuals_demo.gd"
## Recorded walkthrough of weapon stances and reloads — NOT a test. With a
## weapon drawn the hero stands in its guard (WeaponData.stance_animation)
## instead of upright with the weapon hanging, a shield's guard beating the
## sword's, and comes back to it after an attack; Reload plays the drawn
## gun's own clip (WeaponData.reload_animation), holds the turn through it
## and fills the magazine. Record it the same way as item_layer_demo.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	_bare_handed()
	_hero.set_base_stat(StatIds.DX, 16)
	SelectionManager.select(_hero)
	await _wait(1.0)

	await _melee_stances()
	await _gun("pistol", "Shoot", "Weapon/Stance_Pistol", "Weapon/Reload_Pistol")
	await _gun("rifle", "Burst", "Weapon/Stance_Longgun", "Weapon/Reload_Rifle")
	await _gun("crossbow", "Shoot", "Weapon/Stance_Crossbow", "Weapon/Reload_Crossbow")
	_say("Longbow: the bow held low, an arrow on the string")
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/longbow.tres")))
	await _wait(2.0)
	_check_stance("Weapon/Stance_Bow")
	_say("Hands empty: back to the plain idle")
	_bare_handed()
	await _wait(1.5)
	_check_stance(_animator(_hero).idle_animation)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.5)
	get_tree().quit()


func _melee_stances() -> void:
	_say("Iron sword drawn: the hero stands in its guard")
	_hero.equip_item(MAIN, ItemInstance.new(IronSword))
	await _wait(2.0)
	_check_stance("Weapon/Stance_Sword")
	var near: Unit = _dummy(-1.2, 0.0)
	await _wait(1.0)
	await _timed(_attack("Swing"), near)
	await _wait(0.5)
	_check_stance("Weapon/Stance_Sword", "after the swing")
	near.queue_free()
	_say("A shield in the other hand: the shield's guard")
	_hero.equip_item(OFF, ItemInstance.new(load("res://data/items/wooden_shield.tres")))
	await _wait(2.0)
	_check_stance("Weapon/Stance_Shield")
	_bare_handed()
	_say("Greatsword: both hands on the hilt, the blade up")
	_hero.equip_item(MAIN, ItemInstance.new(load("res://data/items/greatsword.tres")))
	await _wait(2.0)
	_check_stance("Weapon/Stance_Greatsword")
	_bare_handed()


## Draws the gun, fires its `row` once, empties it, reloads.
func _gun(item: String, row: String, stance: String, reload_clip: String) -> void:
	_say("%s: its stance, a shot, then a reload" % item.capitalize())
	var gun := ItemInstance.new(load("res://data/items/%s.tres" % item))
	_hero.equip_item(RANGED, gun)
	await _wait(2.0)
	_check_stance(stance)
	var far: Unit = _dummy(-8.0, 0.0)
	await _wait(0.5)
	var shot: Ability = _attack(row)
	_check("%s is offered" % row, shot != null)
	if shot:
		await _timed(shot, far)
	await _wait(0.5)
	_check_stance(stance, "after the shot")
	far.queue_free()
	gun.fire(999)
	var reload: Ability = _attack("Reload", true)
	_check("Reload is offered", reload != null)
	if reload:
		var t: Dictionary = await _timed(reload, _hero)
		var length: float = _animator(_hero).animation_player.get_animation(reload_clip).length \
			if _animator(_hero).animation_player.has_animation(reload_clip) else 0.0
		_check("Reload plays %s (%s)" % [reload_clip, t.clip], t.clip == reload_clip)
		_check("the turn is held through the reload (%.2f s of a %.2f s clip)" % [t.done, length],
			length > 0.0 and t.done >= length * 0.9)
		_check("the magazine is full (%d of %d)" % [gun.shots_left(), gun.magazine()],
			gun.shots_left() == gun.magazine())
		await _wait(0.5)
		_check_stance(stance, "after the reload")
	await _wait(1.0)
	_bare_handed()


func _check_stance(stance: String, when: String = "") -> void:
	var showing := String(_animator(_hero).animation_player.current_animation)
	_check("standing in %s%s (%s)" % [stance, " " + when if when else "", showing], showing == stance)


func _bare_handed() -> void:
	for key in [MAIN, OFF, RANGED, EquipSlot.Slot.RANGED_OFF_HAND]:
		if _hero.get_equipped_item(key):
			_hero.unequip_item(key)

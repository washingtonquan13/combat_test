extends "res://tools/item_layer_demo.gd"
## Recorded showcase of weapon parts 3-8 — NOT a test. Reuses the item
## layer demo's boot, caption and check helpers. Shields, both weapon
## sets live at once, a bow's own ST, ½D, a crossbow's one-shot
## magazine and Reload, a thrown axe that stays in hand, a pistol's
## RoF 3 and a rifle's RoF 10 burst. The targets are same-faction
## dummies, so shooting them starts no fight: the rolls, defenses, DR
## and ammo are all real, the turn economy is out of the picture. Record
## it the same way as item_layer_demo.

const MAIN := EquipSlot.Slot.MELEE_MAIN_HAND
const OFF := EquipSlot.Slot.MELEE_OFF_HAND
const RANGED := EquipSlot.Slot.RANGED_MAIN_HAND

var _hero: Unit


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for key in [MAIN, OFF, RANGED, EquipSlot.Slot.RANGED_OFF_HAND]:
		if _hero.get_equipped_item(key):
			_hero.unequip_item(key)
	_hero.set_base_stat(StatIds.DX, 14)
	# Behind the hero: the arena has cover in front past ~9.
	var near: Unit = _dummy(-8.0, 0.0)
	var far: Unit = _dummy(-24.0, 0.0)
	SelectionManager.select(_hero)
	await _wait(1.0)

	_say("Shield: a bash from the off hand, no -4, and DB to every defense")
	_hero.equip_item(MAIN, ItemInstance.new(IronSword))
	_hero.equip_item(OFF, ItemInstance.new(load("res://data/items/wooden_shield.tres")))
	await _wait(2.0)
	_check("sword + shield offer Swing, Thrust, Shield Bash", _names() == ["Swing", "Thrust", "Shield Bash"])
	_say("Wooden shield DB 2: Block %d" % _hero.block_target())
	await _wait(2.5)

	_say("Free sets: put a longbow in the ranged hands — melee stays on the bar")
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/longbow.tres")))
	await _wait(2.0)
	_check("both sets on the hotbar", _names() == ["Swing", "Thrust", "Shield Bash", "Shoot"])
	var shoot: Ability = _attack("Shoot")
	var row: AttackRow = shoot.effects[0].row_for(_hero)
	_say("Longbow: %s from its own ST 11 (hero ST %d), Acc +3, ½D 20, Max 40"
		% [row.describe_damage(_hero), floori(_hero.get_stat(StatIds.ST))])
	_check("bow rolls from its own ST", row.describe_damage(_hero).begins_with("1d+1"))
	await _wait(3.0)
	await _fire(shoot, near, "Shoot the near dummy (8)")
	var near_expected: float = shoot.effects[0].expected_damage(_hero, near)
	var far_expected: float = shoot.effects[0].expected_damage(_hero, far)
	_check("past ½D the damage is halved", is_equal_approx(far_expected, near_expected / 2.0))
	await _fire(shoot, far, "Past ½D (24 > 20): average %.1f instead of %.1f" % [far_expected, near_expected])

	_say("Crossbow: fixed 1d+3 whatever your ST, one bolt, then Reload")
	_hero.unequip_item(RANGED)
	var crossbow := ItemInstance.new(load("res://data/items/crossbow.tres"))
	_hero.equip_item(RANGED, crossbow)
	await _wait(2.0)
	_check("Reload joins the bar", _names(true).has("Reload"))
	var bolt: Ability = _attack("Shoot")
	await _fire(bolt, near, "Shoot the crossbow")
	_check("crossbow empty, slot disabled", bolt.out_of_ammo(_hero) and _slot_disabled(bolt))
	_say("Empty: the Shoot slot greys out")
	await _wait(2.5)
	await _hero.use_ability(_attack("Reload", true), _hero)
	_say("Reload (one attack action): %d bolt" % _hero.shots_left(bolt))
	_check("Reload refilled it", _hero.shots_left(bolt) == 1 and not _slot_disabled(bolt))
	await _wait(2.5)

	_say("Throwing axe in the melee hand: Swing and Throw, never used up")
	_hero.unequip_item(OFF)
	_hero.unequip_item(MAIN)
	_hero.unequip_item(RANGED)
	var axe := ItemInstance.new(load("res://data/items/throwing_axe.tres"))
	_hero.equip_item(MAIN, axe)
	await _wait(2.0)
	_check("axe offers Swing and Throw", _names() == ["Swing", "Throw"])
	await _fire(_attack("Throw"), near, "Throw it")
	_check("axe still in hand", _hero.get_equipped_item(MAIN) == axe)
	_say("Still in hand after the throw")
	await _wait(2.0)

	_say("Pistol: 2d+2 pi, 9 shots, RoF 3, Rcl 2")
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/pistol.tres")))
	await _wait(2.0)
	var pistol: Ability = _attack("Shoot")
	await _fire(pistol, near, "Fire RoF 3: one hit + one per 2 of margin")
	_check("RoF 3 spent 3 rounds", _hero.shots_left(pistol) == 6)

	_say("Assault rifle: 5d pi, 30 rounds, RoF 10 (+2 to hit), Rcl 2")
	_hero.unequip_item(RANGED)
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/rifle.tres")))
	await _wait(2.0)
	var burst: Ability = _attack("Burst")
	for i in 3:
		await _fire(burst, near, "Burst %d of 3: each hit meets DR on its own" % (i + 1))
	_check("three bursts empty the magazine", burst.out_of_ammo(_hero) and _slot_disabled(burst))
	_say("Out of ammo: Burst greys out until Reload")
	await _wait(2.5)
	await _hero.use_ability(_attack("Reload", true), _hero)
	_check("Reload refilled the rifle", _hero.shots_left(burst) == 30)
	_say("Reload: %d rounds" % _hero.shots_left(burst))
	await _wait(2.5)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.0)
	get_tree().quit()


## Shoots, waits for the swing to finish, and captions what happened.
func _fire(ability: Ability, target: Unit, caption: String) -> void:
	_say(caption)
	await _wait(1.2)
	var before: int = target.get_pool(StatIds.HP)
	var result: Dictionary = await _hero.use_ability(ability, target)
	await _wait(1.0)
	var line: String
	if not result.get("in_range", false):
		line = "out of range / no shot"
	elif not result.has("to_hit"):
		line = "did not fire"
	elif not result.to_hit.success:
		line = "miss (rolled %d vs %d)" % [result.to_hit.roll, result.to_hit.target]
	elif not result.get("hit", false):
		line = "%s stopped it" % result.defense.kind
	else:
		line = "%d hit%s, %d damage" % [result.hits, "" if result.hits == 1 else "s", before - target.get_pool(StatIds.HP)]
	var left: int = _hero.shots_left(ability)
	_say(caption + "  →  " + line + ("" if left < 0 else "  (%d left)" % left))
	await _wait(2.5)


## A same-faction target: shooting it starts no fight.
func _dummy(forward: float, side: float) -> Unit:
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	var definition := UnitDefinition.new()
	definition.model_scene = load("res://scenes/character_models/placeholder_model.tscn")
	unit.definition = definition
	WorldManager.spawn_parent().add_child(unit)
	unit.faction = _hero.faction
	unit.set_base_stat(StatIds.DX, 3)
	unit.set_base_stat(StatIds.HT, 3)
	unit.set_base_stat(StatIds.HP, 300)
	unit.set_pool(StatIds.HP, 300)
	unit.global_position = _spot(forward, side)
	return unit


func _spot(forward: float, side: float) -> Vector3:
	var right: Vector3 = _hero.visual_forward().cross(Vector3.UP)
	return _hero.global_position + _hero.visual_forward() * forward + right * side


func _attack(name: String, any: bool = false) -> Ability:
	for a in _hero.combat_abilities():
		if a.ability_name == name and (any or a.effects.any(func(e): return e is GearDamageEffect)):
			return a
	return null


func _names(any: bool = false) -> Array:
	return _hero.combat_abilities().filter(func(a):
		return any or a.effects.any(func(e): return e is GearDamageEffect)).map(func(a): return a.ability_name)


func _slot_disabled(ability: Ability) -> bool:
	for slot in get_tree().root.find_children("*", "Button", true, false):
		if slot.has_method("refresh_state") and slot.ability == ability:
			slot.refresh_state()
			return slot.disabled
	return false

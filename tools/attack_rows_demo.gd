extends "res://tools/item_layer_demo.gd"
## Short recorded walkthrough of attack rows — NOT a test. Reuses the
## item layer demo's boot, caption and check helpers. An empty hand shows
## Punch on the hotbar; equipping the iron sword turns it into Swing and
## Thrust; unequipping brings Punch back. A beast's natural rows are
## listed in the caption. Record it the same way as item_layer_demo.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	var hero: Unit = PartyManager.leader
	SelectionManager.select(hero)
	_say("Empty hands: the basic attack is a punch")
	await _wait(2.5)
	_check("hotbar attack is Punch", _names(hero) == ["Punch"])
	await _wait(1.5)

	_say("Equip the iron sword: one hotbar attack per row")
	hero.equip_item(EquipSlot.Slot.MELEE_MAIN_HAND, ItemInstance.new(IronSword))
	await _wait(2.5)
	_check("hotbar attacks are Swing and Thrust", _names(hero) == ["Swing", "Thrust"])
	await _wait(2.0)

	_say("Unequip it: back to a punch")
	hero.unequip_item(EquipSlot.Slot.MELEE_MAIN_HAND)
	await _wait(2.0)
	_check("hotbar attack is Punch again", _names(hero) == ["Punch"])
	await _wait(1.5)

	var definition: UnitDefinition = load("res://data/units/demons/beast.tres")
	var rows: Array = definition.natural_attacks.map(func(r): return r.label + " (" + r.describe_damage() + ")")
	_say("A beast's body attacks: " + ", ".join(rows))
	_check("beast has Bite and Claws", rows.size() == 2)
	await _wait(3.0)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	await _wait(2.0)
	get_tree().quit()


func _names(unit: Unit) -> Array:
	var weapon_attacks := unit.combat_abilities().filter(func(a):
		return a.effects.any(func(e): return e is GearDamageEffect))
	return weapon_attacks.map(func(a): return a.ability_name)

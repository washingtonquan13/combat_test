extends "res://tools/item_layer_demo.gd"
## Short recorded walkthrough of hands — NOT a test. Reuses the item
## layer demo's boot, drag, caption and check helpers. Drags a second
## sword into the off hand (its own hotbar attacks at -4), then a
## greatsword into the main hand: the off hand shows its ghost and
## refuses a shield, and ST short of 12 costs to hit. Record it the same
## way as item_layer_demo.

const Greatsword: ItemDefinition = preload("res://data/items/greatsword.tres")
const WoodenShield: ItemDefinition = preload("res://data/items/wooden_shield.tres")
const MAIN := EquipSlot.Slot.MELEE_MAIN_HAND
const OFF := EquipSlot.Slot.MELEE_OFF_HAND


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	var hero: Unit = PartyManager.leader
	for key in [MAIN, OFF]:
		if hero.get_equipped_item(key):
			hero.unequip_item(key)
	var bag := PartyManager.inventory
	var sword_a := ItemInstance.new(IronSword)
	var sword_b := ItemInstance.new(IronSword)
	var great := ItemInstance.new(Greatsword)
	var shield := ItemInstance.new(WoodenShield)
	bag.add(sword_a)
	bag.add(sword_b)
	var overview: Node = get_tree().get_first_node_in_group("party_overview")
	var inventory: Inventory = overview.get_inventory()
	overview.open_for(hero)
	await _wait(1.0)

	_say("One-handed: a sword in each hand")
	await _drag(await _widget_center(inventory, sword_a), _center(_slot(MAIN)))
	await _wait(0.5)
	await _drag(await _widget_center(inventory, sword_b), _center(_slot(OFF)))
	await _wait(0.8)
	_check("both hands hold a sword", hero.get_equipped_item(MAIN) == sword_a and hero.get_equipped_item(OFF) == sword_b)
	await _wait(1.0)

	overview.close()
	SelectionManager.select(hero)
	var attacks: Array = _attacks(hero)
	var main_hit: int = hero.to_hit_target(hero, attacks[0])
	var off_hit: int = hero.to_hit_target(hero, attacks[2])
	_say("Off-hand sword: its own attacks, to hit %d vs %d (-4)" % [off_hit, main_hit])
	await _wait(1.0)
	_check("hotbar shows main and off-hand attacks",
		_names(attacks) == ["Swing", "Thrust", "Swing (off hand)", "Thrust (off hand)"])
	_check("off hand is -4 to hit", off_hit == main_hit - 4)
	await _wait(3.0)

	overview.open_for(hero)
	await _wait(0.8)
	_say("Unequip both swords")

	await _drag(_center(_slot(OFF)), _cell_center.bind(inventory, sword_b, Vector2i(1, 1)))
	await _wait(0.6)
	await _drag(_center(_slot(MAIN)), _cell_center.bind(inventory, sword_a, Vector2i(4, 1)))
	await _wait(0.8)

	_check("both swords back in the bag", hero.get_equipped_item(MAIN) == null and hero.get_equipped_item(OFF) == null)
	bag.remove(sword_a)
	bag.remove(sword_b)
	bag.add(great)
	bag.add(shield)
	await _wait(0.8)
	_say("Two-handed: the greatsword takes both hands")
	await _drag(await _widget_center(inventory, great), _center(_slot(MAIN)))
	await _wait(1.0)
	_check("greatsword in the main hand", hero.get_equipped_item(MAIN) == great)
	_check("off-hand slot shows its faded ghost", _slot(OFF)._ghost != null and _slot(OFF)._ghost.is_visible_in_tree())
	await _wait(2.0)

	_say("The off hand refuses a shield while it's held")
	await _drag(await _widget_center(inventory, shield), _center(_slot(OFF)))
	await _wait(1.0)
	_check("shield stayed in the bag", bag.has_instance(shield) and hero.get_equipped_item(OFF) == null)
	await _wait(1.5)

	var st: int = floori(hero.get_stat(StatIds.ST))
	var greatswing: Ability = _attacks(hero)[0]
	var hit: int = hero.to_hit_target(hero, greatswing)
	var unpenalized: int = main_hit
	_say("Min ST 12: ST %d is %+d to hit (%d vs a sword's %d)" % [st, mini(st - 12, 0), hit, unpenalized])
	_check("ST short of 12 costs 1 per point", hit == unpenalized + mini(st - 12, 0))
	await _wait(3.0)
	hero.set_base_stat(StatIds.ST, 9)
	hit = hero.to_hit_target(hero, greatswing)
	_say("Drop ST to 9: -3 to hit (%d)" % hit)
	_check("ST 9 is -3", hit == unpenalized - 3)
	hero.set_base_stat(StatIds.ST, st)
	await _wait(3.0)

	_say("Take it off: the ghost goes, the shield fits")
	await _drag(_center(_slot(MAIN)), _cell_center.bind(inventory, great, Vector2i(5, 1)))
	await _wait(0.6)
	await _drag(await _widget_center(inventory, shield), _center(_slot(OFF)))
	await _wait(1.0)
	_check("ghost gone, shield in the off hand", _slot(OFF)._ghost == null and hero.get_equipped_item(OFF) == shield)
	await _wait(1.0)

	_say("And with the shield on, the greatsword won't go in")
	await _drag(await _widget_center(inventory, great), _center(_slot(MAIN)))
	await _wait(1.0)
	_check("greatsword refused, still in the bag", bag.has_instance(great) and hero.get_equipped_item(MAIN) == null)
	await _wait(1.5)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.0)
	get_tree().quit()


func _attacks(unit: Unit) -> Array:
	return unit.combat_abilities().filter(func(a):
		return a.effects.any(func(e): return e is GearDamageEffect))


func _names(attacks: Array) -> Array:
	return attacks.map(func(a): return a.ability_name)

extends "res://tools/item_layer_demo.gd"
## Recorded showcase of affixes, item level, identification and the loot
## roller — NOT a test. Rolls at two levels, a rare sword refused by the
## hand until a real drag of the scroll identifies it, a kill leaving
## Remains, and test_arena's loot chest rolling on first open. Record it
## the same way as item_layer_demo.

const MAIN := EquipSlot.Slot.MELEE_MAIN_HAND
const TooltipScene: PackedScene = preload("res://systems/inventory_system/item_tooltip.tscn")

var _hero: Unit


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for key in _hero.get_equipped_slots():
		_hero.unequip_item(key)
	var bag := PartyManager.inventory
	bag.clear()

	_say("Roll 300 drops at item level 1 and 300 at item level 12")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var low := LootRoller.roll_many(1, 300, rng)
	var high := LootRoller.roll_many(12, 300, rng)
	var all := low + high
	_check("no affix above its item's level", all.all(func(i):
		return i.affixes.all(func(a): return a.level <= i.item_level)))
	_check("level 1 never rolls Vicious (level 10)", not low.any(func(i): return _has(i, &"vicious")))
	_check("level 12 does", high.any(func(i): return _has(i, &"vicious")))
	_check("magic: 1-2 affixes, at most one of each kind", all.all(func(i):
		return i.rarity != ItemInstance.Rarity.MAGIC or (i.affixes.size() in [1, 2]
			and i.prefixes().size() <= 1 and i.suffixes().size() <= 1)))
	_check("rare: 2-4 affixes, at most two of each kind, a two-word name", all.all(func(i):
		return i.rarity != ItemInstance.Rarity.RARE or (i.affixes.size() >= 2 and i.affixes.size() <= 4
			and i.prefixes().size() <= 2 and i.suffixes().size() <= 2 and i.rare_name.split(" ").size() == 2)))
	_check("only normal items drop identified", all.all(func(i):
		return i.identified == (i.rarity == ItemInstance.Rarity.NORMAL)))
	var samples: Array = []
	for item in high:
		if item.affixes.size() > 0 and samples.size() < 4:
			item.identify()
			samples.append(item.display_name())
	_say("Some level 12 drops, identified: " + ", ".join(samples))
	await _wait(3.5)

	_say("An unidentified rare sword: Keen (+2 damage) and of the Bear (+1 ST)")
	var sword := ItemInstance.new(IronSword)
	sword.rarity = ItemInstance.Rarity.RARE
	sword.item_level = 5
	sword.affixes.assign([AffixDatabase.find(&"keen"), AffixDatabase.find(&"of_the_bear")])
	sword.rare_name = "Grim Fang"
	sword.identified = false
	var scroll := ItemInstance.new(load("res://data/items/identify_scroll.tres"))
	bag.add(sword)
	bag.add(scroll)
	var overview: Node = get_tree().get_first_node_in_group("party_overview")
	overview.open_for(_hero)
	await _wait(1.5)
	var inventory: Inventory = overview.get_inventory()
	var slot := _slot(MAIN)
	var st: float = _hero.get_stat(StatIds.ST)
	var swing: int = sword.attacks()[0].damage_bonus
	_check("unidentified: base name, no damage bonus",
		sword.display_name() == IronSword.item_name and swing == IronSword.weapon_data.attacks[0].damage_bonus)
	var lines := await _tooltip_lines(sword)
	_check("its tooltip says Unidentified and hides the affixes", lines.has("Unidentified") and not lines.has("+2 damage"))
	_say("Hover it: Unidentified")
	await _glide(await _widget_center(inventory, sword), 0)
	await _wait(3.0)

	_say("Try to wear it: an unidentified item can't be equipped")
	await _drag(await _widget_center(inventory, sword), _center(slot))
	await _wait(1.0)
	_check("refused: still in the bag, the hand empty", _hero.get_equipped_item(MAIN) == null and bag.has_instance(sword))
	_check("the right-click Equip refuses it too", not slot.accepts(sword))
	await _wait(1.5)

	_say("Drag the Scroll of Identify onto the sword")
	await _drag(await _widget_center(inventory, scroll), await _widget_center(inventory, sword))
	await _wait(1.0)
	_check("identified, the scroll is spent", sword.identified and not bag.has_instance(scroll))
	_check("its name is the rare name", sword.display_name() == "Grim Fang")
	lines = await _tooltip_lines(sword)
	_check("its tooltip lists both affixes", lines.has("+2 damage") and lines.has("+1 ST"))
	await _wait(1.5)

	_say("Now it can be worn")
	await _drag(await _widget_center(inventory, sword), _center(slot))
	await _wait(1.0)
	_check("worn: +1 ST and +2 damage", _hero.get_equipped_item(MAIN) == sword
		and _hero.get_stat(StatIds.ST) == st + 1 and sword.attacks()[0].damage_bonus == swing + 2)
	_say("ST %d → %d, Swing %+d → %+d" % [st, _hero.get_stat(StatIds.ST), swing, sword.attacks()[0].damage_bonus])
	await _wait(2.0)
	_say("Hover it: Grim Fang, Iron Sword — Rare, item level 5, both affixes")
	await _glide(_center(slot), 0)
	await _wait(3.5)
	overview.close()
	await _wait(1.0)

	_say("A level 10 monster that always drops: kill it")
	var monster := _monster(-6.0)
	await _wait(1.5)
	var spot := monster.global_position
	monster.take_damage(9999)
	await _wait(1.5)
	var remains: Remains = _remains()
	_check("it left Remains where it fell", remains != null and remains.global_position.distance_to(spot) < 0.1)
	if remains:
		var stash := StashComponent.find_on(remains)
		var items := stash.inventory.get_container().items()
		_check("holding its drops (%d), gear at item level 10" % items.size(), items.size() > 0
			and items.all(func(i): return not i.definition is GearItem or i.item_level == 10))
		_say("Open the Remains: Take All")
		StashManager.open_stash(stash, _hero)
		await _wait(2.0)
		var panel: Node = get_tree().root.find_child("StashPanel", true, false)
		await _click(_center(panel.get_node("%TakeAllButton")))
		await _wait(1.5)
		StashManager.close_stash()
		await _wait(0.5)
		_check("emptied Remains are gone", not is_instance_valid(remains) or remains.is_queued_for_deletion())

	_say("The loot chest rolls its contents the first time it's opened, at the area's level")
	var chest_stash := StashComponent.find_on(get_tree().root.find_child("LootChest", true, false))
	var chest_bag: ItemContainer = chest_stash.inventory.get_container()
	_check("closed, the chest is empty", chest_bag.items().is_empty())
	StashManager.open_stash(chest_stash, _hero)
	await _wait(2.5)
	var rolled := chest_bag.items().size()
	_check("opened: %d drops, gear at test_arena's level 2" % rolled, rolled > 0
		and chest_bag.items().all(func(i): return not i.definition is GearItem or i.item_level == 2))
	StashManager.close_stash()
	await _wait(0.5)
	StashManager.open_stash(chest_stash, _hero)
	await _wait(1.5)
	_check("reopened: no second roll", chest_bag.items().size() == rolled)
	StashManager.close_stash()
	_check("the save remembers it rolled", chest_stash.save_state().get("rolled", false))
	await _wait(1.0)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.0)
	get_tree().quit()


func _has(item: ItemInstance, id: StringName) -> bool:
	return item.affixes.any(func(a): return a.id == id)


func _tooltip_lines(item: ItemInstance) -> Array:
	var tip: Control = TooltipScene.instantiate()
	add_child(tip)
	tip.show_item(item)
	await get_tree().process_frame
	var lines: Array = tip.find_children("*", "Label", true, false).map(func(l): return l.text)
	tip.queue_free()
	return lines


func _monster(forward: float) -> Unit:
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	var definition := UnitDefinition.new()
	definition.model_scene = load("res://scenes/character_models/placeholder_model.tscn")
	definition.level = 10
	definition.max_drops = 3
	definition.drop_chance = 1.0
	unit.definition = definition
	WorldManager.spawn_parent().add_child(unit)
	unit.faction = _hero.faction
	unit.global_position = _hero.global_position + _hero.visual_forward() * forward
	return unit


func _remains() -> Remains:
	for node in get_tree().root.find_children("*", "StaticBody3D", true, false):
		if node is Remains and not node.is_queued_for_deletion():
			return node
	return null

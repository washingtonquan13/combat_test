extends "res://tools/item_layer_demo.gd"
## Recorded showcase of rarity and rune sockets — NOT a test. Every
## socket and rune here goes in by a real drag onto the item in the
## grid or the equip slot. Record it the same way as item_layer_demo.

var _hero: Unit


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for key in _hero.get_equipped_slots():
		_hero.unequip_item(key)
	var bag := PartyManager.inventory
	bag.clear()
	var sword := ItemInstance.new(IronSword)
	sword.rarity = ItemInstance.Rarity.MAGIC
	var chest := ItemInstance.new(load("res://data/items/leather_chestpiece.tres"))
	chest.rarity = ItemInstance.Rarity.RARE
	chest.sockets = 1
	var awls := ItemInstance.new(load("res://data/items/socket_awl.tres"), 2)
	var iron := ItemInstance.new(load("res://data/items/iron_rune.tres"), 2)
	var vigor := ItemInstance.new(load("res://data/items/vigor_rune.tres"))
	for item in [sword, chest, awls, iron, vigor]:
		bag.add(item)
	var overview: Node = get_tree().get_first_node_in_group("party_overview")
	overview.open_for(_hero)
	await _wait(1.5)
	var inventory: Inventory = overview.get_inventory()
	_check("rarity frames: magic sword, rare chest", _widget(inventory, sword).rarity_frame.visible
		and _widget(inventory, chest).rarity_frame.border_color == ItemInstance.RARITY_COLORS[ItemInstance.Rarity.RARE])

	_say("Iron Sword: 2x3, one-handed — up to 2 sockets. It has none.")
	await _wait(2.0)
	var swing_before: String = sword.attacks()[0].describe_damage()
	_say("Drag a Socket Awl onto the sword")
	await _drag(await _widget_center(inventory, awls), await _widget_center(inventory, sword))
	await _wait(1.0)
	_check("the awl added a socket and one awl is spent", sword.sockets == 1 and awls.count == 1)
	_check("the sword shows one empty pip", _widget(inventory, sword).socket_pips.get_child_count() == 1)

	_say("Drag an Iron Rune into it: +1 damage on a weapon")
	await _drag(await _widget_center(inventory, iron), await _widget_center(inventory, sword))
	await _wait(1.0)
	_check("the rune went in for good", sword.runes.size() == 1 and iron.count == 1)
	_say("Swing: %s  →  %s" % [swing_before, sword.attacks()[0].describe_damage()])
	_check("its Swing is +1", sword.attacks()[0].damage_bonus == IronSword.weapon_data.attacks[0].damage_bonus + 1)
	await _wait(2.5)

	_say("The second Iron Rune has no free socket: dropping it just moves it")
	await _drag(await _widget_center(inventory, iron), await _widget_center(inventory, sword))
	await _wait(1.0)
	_check("a full item takes no rune", sword.runes.size() == 1 and iron.count == 1)
	await _wait(1.5)

	_say("The last awl onto the sword: 2 of 2 sockets")
	await _drag(await _widget_center(inventory, awls), await _widget_center(inventory, sword))
	await _wait(1.0)
	_check("the last awl is used up and gone from the bag", sword.sockets == 2 and not bag.has_instance(awls)
		and _widget(inventory, awls) == null)
	await _wait(1.5)

	_say("Wear the rare chest (DR 2, one socket)")
	var slot := _slot(EquipSlot.Slot.CHEST_ARMOR)
	await _drag(await _widget_center(inventory, chest), _center(slot))
	await _wait(1.0)
	var hp: float = _hero.get_stat(StatIds.HP)
	_say("Drag a Vigor Rune onto the worn chest: +2 HP on armour")
	await _drag(await _widget_center(inventory, vigor), _center(slot))
	await _wait(1.0)
	_check("socketed while worn: HP +2 at once", chest.runes.size() == 1 and _hero.get_stat(StatIds.HP) == hp + 2)
	_say("HP %d → %d" % [hp, _hero.get_stat(StatIds.HP)])
	await _wait(2.0)

	var tip: Control = _widget(inventory, sword)._make_custom_tooltip("")
	add_child(tip)
	await get_tree().process_frame
	var lines: Array = tip.find_children("*", "Label", true, false).map(func(l): return l.text)
	_check("the tooltip lists the rune and sockets", lines.has("Sockets: 2 / 2") and lines.has("Iron Rune: +1 damage"))
	tip.queue_free()
	_check("the sheet shows the new max HP", _stats_text().contains("%d / %d" % [_hero.get_pool(StatIds.HP), _hero.get_stat(StatIds.HP)]))
	_say("Hover the sword: name in its rarity colour, rows, sockets, runes")
	await _glide(await _widget_center(inventory, sword), 0)
	await _wait(3.5)

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.0)
	get_tree().quit()


func _stats_text() -> String:
	var column: Node = get_tree().get_first_node_in_group("party_overview").find_child("StatsColumn", true, false)
	return " ".join(column.find_children("*", "Label", true, false).map(func(l): return l.text))


func _widget(inventory: Inventory, item: ItemInstance) -> Item:
	for widget in _widgets(inventory):
		if widget.instance == item:
			return widget
	return null

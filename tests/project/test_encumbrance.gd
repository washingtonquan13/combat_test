extends AiTestCase
## Encumbrance: worn weight against Basic Lift (ST x ST / 5) sets a
## level that takes Move and Dodge; nothing goes on past 10 x BL.


func wants_world() -> bool:
	return true


func run() -> void:
	var hero: Unit = spawn_unit(&"player", 5, 10, 10, [melee()], Vector3.ZERO)
	var move: float = hero.get_stat(StatIds.MOVE)
	var dodge: float = hero.get_stat(StatIds.DODGE)
	check("ST 5 lifts 5 lb", hero.basic_lift() == 5.0)

	hero.equip_item(EquipSlot.Slot.CHEST_ARMOR, ItemInstance.new(load("res://data/items/leather_chestpiece.tres")))
	hero.equip_item(EquipSlot.Slot.BOOTS, ItemInstance.new(load("res://data/items/leather_boots.tres")))
	check("13 lb is Medium", hero.encumbrance_level() == 2, "level %d" % hero.encumbrance_level())
	check("Medium: Move x0.6 rounded down, Dodge -2",
		hero.get_stat(StatIds.MOVE) == maxf(1.0, floorf(move * 0.6)) and hero.get_stat(StatIds.DODGE) == dodge - 2,
		"move %s dodge %s" % [hero.get_stat(StatIds.MOVE), hero.get_stat(StatIds.DODGE)])

	hero.equip_item(EquipSlot.Slot.MELEE_MAIN_HAND, ItemInstance.new(load("res://data/items/greatsword.tres")))
	hero.equip_item(EquipSlot.Slot.RANGED_OFF_HAND, ItemInstance.new(load("res://data/items/tower_shield.tres")))
	var rifle := ItemInstance.new(load("res://data/items/rifle.tres"))
	check("45 of 50 lb worn, a 9 lb rifle won't go on",
		hero.worn_weight() == 45.0 and not hero.weight_allows(EquipSlot.Slot.RANGED_MAIN_HAND, rifle))

	hero.unequip_item(EquipSlot.Slot.RANGED_OFF_HAND)
	hero.unequip_item(EquipSlot.Slot.MELEE_MAIN_HAND)
	hero.unequip_item(EquipSlot.Slot.BOOTS)
	hero.unequip_item(EquipSlot.Slot.CHEST_ARMOR)
	check("taking it all off restores Move and Dodge",
		hero.get_stat(StatIds.MOVE) == move and hero.get_stat(StatIds.DODGE) == dodge)

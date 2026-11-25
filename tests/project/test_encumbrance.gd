extends AiTestCase
## Encumbrance: worn weight against Basic Lift (ST x ST / 5) sets a
## level that takes Move and Dodge; nothing goes on past 10 x BL.


func wants_world() -> bool:
	return true


func run() -> void:
	var hero: Unit = spawn_unit(&"player", 4, 10, 10, [melee()], Vector3.ZERO)
	var move: float = hero.get_stat(StatIds.MOVE)
	var dodge: float = hero.get_stat(StatIds.DODGE)
	check("ST 4 lifts 3.2 lb", is_equal_approx(hero.basic_lift(), 3.2))

	hero.equip_item(EquipSlot.Slot.CHEST_ARMOR, ItemInstance.new(load("res://data/items/ranger_garb.tres")))
	hero.equip_item(EquipSlot.Slot.HELMET, ItemInstance.new(load("res://data/items/leather_helmet.tres")))
	check("8 lb is Medium", hero.encumbrance_level() == 2, "level %d" % hero.encumbrance_level())
	check("Medium: Move x0.6 rounded down, Dodge -2",
		hero.get_stat(StatIds.MOVE) == maxf(1.0, floorf(move * 0.6)) and hero.get_stat(StatIds.DODGE) == dodge - 2,
		"move %s dodge %s" % [hero.get_stat(StatIds.MOVE), hero.get_stat(StatIds.DODGE)])

	hero.equip_item(EquipSlot.Slot.SET_1_MAIN_HAND, ItemInstance.new(load("res://data/items/greatsword.tres")))
	var tower := ItemInstance.new(load("res://data/items/tower_shield.tres"))
	check("15 of 32 lb worn, a 25 lb tower shield won't go on",
		hero.worn_weight() == 15.0 and not hero.weight_allows(EquipSlot.Slot.SET_2_OFF_HAND, tower))

	hero.unequip_item(EquipSlot.Slot.SET_1_MAIN_HAND)
	hero.unequip_item(EquipSlot.Slot.HELMET)
	hero.unequip_item(EquipSlot.Slot.CHEST_ARMOR)
	check("taking it all off restores Move and Dodge",
		hero.get_stat(StatIds.MOVE) == move and hero.get_stat(StatIds.DODGE) == dodge)

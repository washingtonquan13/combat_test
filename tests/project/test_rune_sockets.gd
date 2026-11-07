extends AiTestCase
## Sockets: min(cells, the kind's limit), an awl adds one, a rune fills
## one for good. A rune's local half writes this copy's own attack rows;
## its global half reaches the wearer, live while worn. All of it saves.


func wants_world() -> bool:
	return true


func run() -> void:
	var boots := ItemInstance.new(load("res://data/items/leather_boots.tres"))
	var chest := ItemInstance.new(load("res://data/items/leather_chestpiece.tres"))
	var belt := ItemInstance.new(load("res://data/items/leather_belt.tres"))
	var greatsword := ItemInstance.new(load("res://data/items/greatsword.tres"))
	check("2x2 boots hold 2, chest 3, belt 0, two-hander 3",
		[boots.max_sockets(), chest.max_sockets(), belt.max_sockets(), greatsword.max_sockets()] == [2, 3, 0, 3])

	var awl: SocketTool = load("res://data/items/socket_awl.tres")
	while awl.can_apply_to(boots):
		awl.apply_to(boots)
	check("the awl stops at the limit", boots.sockets == 2)

	var iron: RuneItem = load("res://data/items/iron_rune.tres")
	var sword_def: GearItem = load("res://data/items/iron_sword.tres")
	var sword := ItemInstance.new(sword_def)
	var plain := ItemInstance.new(sword_def)
	check("no socket, no rune", not iron.can_apply_to(sword))
	sword.add_socket()
	iron.apply_to(sword)
	check("a rune fills it for good", sword.runes == [iron] and not iron.can_apply_to(sword))
	var shared: AttackRow = sword_def.weapon_data.attacks[0]
	check("the runed copy has its own rows, +1 damage",
		sword.attacks()[0] != shared and sword.attacks()[0].damage_bonus == shared.damage_bonus + 1)
	check("the shared row and a plain copy are untouched",
		plain.attacks()[0] == shared and shared.damage_bonus == 2)
	check("its rows stay the same objects", sword.attacks()[0] == sword.attacks()[0])

	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	var dr: float = hero.get_stat(StatIds.DR)
	chest.sockets = 2
	hero.equip_item(EquipSlot.Slot.CHEST_ARMOR, chest)
	check("the chest gives its own DR 2", hero.get_stat(StatIds.DR) == dr + 2)
	iron.apply_to(chest)
	check("a rune socketed while worn adds +1 DR at once", hero.get_stat(StatIds.DR) == dr + 3)
	hero.unequip_item(EquipSlot.Slot.CHEST_ARMOR)
	check("taking it off takes all of it", hero.get_stat(StatIds.DR) == dr)

	var saved: Dictionary = chest.to_dict()
	var loaded := ItemInstance.from_dict(JSON.parse_string(JSON.stringify(saved)))
	check("sockets and runes survive a save", loaded.sockets == 2 and loaded.runes == [iron],
		"saved %s" % saved)
	check("an old save's bare id still loads", ItemInstance.from_dict("leather_boots").definition.id == &"leather_boots")

extends AiTestCase
## Affixes: per-rarity counts and caps, never above the item's level. An
## unidentified copy's affixes do nothing until identified, worn or not.
## Everything rolled saves.


func wants_world() -> bool:
	return true


func run() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var rolls: Array[ItemInstance] = LootRoller.roll_many(3, 400, rng)
	check("no affix above its item's level", rolls.all(func(i):
		return i.affixes.all(func(a): return a.level <= 3)))
	check("magic 1-2, rare 2-4, never past the per-kind cap", rolls.all(func(i):
		var caps: Array = LootRoller.AFFIX_COUNTS.get(i.rarity, [0, 0, 0])
		return i.affixes.is_empty() if caps[1] == 0 else (i.affixes.size() >= caps[0]
			and i.affixes.size() <= caps[1] and i.prefixes().size() <= caps[2] and i.suffixes().size() <= caps[2])))

	var sword := ItemInstance.new(load("res://data/items/iron_sword.tres"))
	sword.rarity = ItemInstance.Rarity.RARE
	sword.item_level = 5
	sword.affixes.assign([AffixDatabase.find(&"keen"), AffixDatabase.find(&"of_the_bear")])
	sword.rare_name = "Grim Fang"
	sword.identified = false
	var hand := EquipSlot.new()
	hand.slot_type = GearItem.SlotType.MELEE_MAIN_HAND
	var damage: int = sword.attacks()[0].damage_bonus
	check("unidentified: no damage bonus, and no slot takes it", sword.attacks()[0].damage_bonus == damage
		and sword.modifiers().is_empty() and not hand.accepts(sword))
	sword.identify()
	check("identified: +2 damage, +1 ST, and it can be worn", sword.attacks()[0].damage_bonus == damage + 2
		and sword.modifiers().size() == 2 and hand.accepts(sword))
	hand.free()

	sword.identified = false
	var saved: Dictionary = sword.to_dict()
	var loaded := ItemInstance.from_dict(JSON.parse_string(JSON.stringify(saved)))
	check("affixes, level, name and identified survive a save", loaded.affixes == sword.affixes
		and loaded.item_level == 5 and loaded.rare_name == "Grim Fang" and not loaded.identified, "saved %s" % saved)
	var widow := ItemInstance.new(load("res://data/items/iron_sword.tres"))
	widow.unique = UniqueDatabase.find(&"widows_kiss")
	widow.rarity = ItemInstance.Rarity.UNIQUE
	check("a unique survives a save", ItemInstance.from_dict(JSON.parse_string(JSON.stringify(widow.to_dict()))).unique
		== widow.unique)

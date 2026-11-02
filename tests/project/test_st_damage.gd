extends AiTestCase
## ST damage follows the Basic Set table (B16), and keeps going past it;
## an empty hand punches for thrust-1. The AI prices a hit through the
## target's DR roll by roll, the way the hit itself meets it.


func wants_world() -> bool:
	return true


func run() -> void:
	# ST: [thrust, swing], from the book's table and +1d per 10 ST past 100.
	var rows: Dictionary = {
		1: ["1d-6", "1d-5"], 6: ["1d-4", "1d-3"], 10: ["1d-2", "1d"],
		27: ["3d-1", "5d+1"], 100: ["11d", "13d"], 120: ["13d", "15d"],
	}
	for st in rows:
		var got: Array = [_dice(UnitCombat._thrust_dice(st)), _dice(UnitCombat._swing_dice(st))]
		check("ST %d is %s/%s" % [st, rows[st][0], rows[st][1]], got == rows[st], "got %s" % [got])

	var brawler: Unit = spawn_unit(&"player", 14, 10, 10, [melee()], Vector3.ZERO)
	var punch: float = GearDamageEffect.new().expected_damage(brawler)
	check("an empty hand punches for thrust-1",
		punch == brawler.expected_damage(UnitCombat.DamageType.THRUST, -1), "got %.2f" % punch)

	# ST 10 swing is 1d: against DR 2 the rolls 1..6 do 0,0,1,2,3,4.
	var armored: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(3.0, 0.0, 0.0))
	armored.set_base_stat(StatIds.DR, 2)
	var swing: StDamageEffect = StDamageEffect.new()
	var priced: float = swing.expected_damage(armored, armored)
	check("1d against DR 2 is priced at 10/6, not 3.5 - 2", is_equal_approx(priced, 10.0 / 6.0), "got %.3f" % priced)
	var cr := DamageResolver.WoundType.CRUSHING
	check("a hit through DR 2 takes 2 off", DamageResolver.injury(5, armored) == 3 and DamageResolver.injury(5, armored, cr, 1.0, true) == 5)
	# B379: what gets through is multiplied, rounded down, at least 1.
	var cut: int = DamageResolver.injury(5, armored, DamageResolver.WoundType.CUTTING)
	var imp: int = DamageResolver.injury(5, armored, DamageResolver.WoundType.IMPALING)
	var pi_small: int = DamageResolver.injury(3, armored, DamageResolver.WoundType.SMALL_PIERCING)
	check("cutting x1.5, impaling x2, small piercing still does 1", cut == 4 and imp == 6 and pi_small == 1,
		"cut %d, imp %d, pi- %d" % [cut, imp, pi_small])
	swing.wound_type = DamageResolver.WoundType.IMPALING
	priced = swing.expected_damage(armored, armored)
	check("the AI prices the multiplier too", is_equal_approx(priced, 20.0 / 6.0), "got %.3f" % priced)
	# B378: DR 4 against (2) is 2, against (0.5) is 8.
	armored.set_base_stat(StatIds.DR, 4)
	var halved: int = DamageResolver.injury(5, armored, cr, 2.0)
	var doubled: int = DamageResolver.injury(9, armored, cr, 0.5)
	check("armor divisor (2) halves DR, (0.5) doubles it", halved == 3 and doubled == 1, "(2) %d, (0.5) %d" % [halved, doubled])
	swing.wound_type = cr
	swing.armor_divisor = 2.0
	priced = swing.expected_damage(armored, armored)
	check("the AI prices the divisor too", is_equal_approx(priced, 10.0 / 6.0), "got %.3f" % priced)
	var sword: GearItem = load("res://data/items/iron_sword.tres")
	var fireball: Ability = load("res://data/abilities/explosive_fireball.tres")
	var burns: bool = fireball.effects.any(func(e): return "wound_type" in e and e.wound_type == DamageResolver.WoundType.BURNING)
	check("the sword cuts and the fireball burns", sword.weapon_data.attacks[0].wound_type == DamageResolver.WoundType.CUTTING and burns)

	# Rows: each way to attack is its own ability, and the loadout picks them.
	var fighter: Unit = spawn_unit(&"player", 12, 10, 10, [melee()], Vector3(4, 0, 0))
	var names: Callable = func(u: Unit): return u.combat_abilities().map(func(a): return a.ability_name)
	check("an empty hand offers a punch", names.call(fighter) == ["Punch"], "got %s" % [names.call(fighter)])
	fighter.equip_item(EquipSlot.Slot.MELEE_MAIN_HAND, ItemInstance.new(sword))
	check("a sword offers swing and thrust", names.call(fighter) == ["Swing", "Thrust"], "got %s" % [names.call(fighter)])
	check("the same row is the same ability each time", fighter.combat_abilities()[1] == fighter.combat_abilities()[1])
	var thrust: Ability = fighter.combat_abilities()[1]
	check("the thrust row impales", thrust.effects[0].located_wound_type(fighter) == DamageResolver.WoundType.IMPALING)
	var beast: Unit = spawn_demon("beast", Vector3(8, 0, 0))
	check("a beast bites and claws", names.call(beast) == ["Bite", "Claws"], "got %s" % [names.call(beast)])

	# Hands: a second sword is its own attacks at -4; a two-handed one
	# needs the off hand empty, keeps it so, and wants ST 12.
	var off_hand := EquipSlot.Slot.MELEE_OFF_HAND
	fighter.equip_item(off_hand, ItemInstance.new(sword))
	var all: Array[Ability] = fighter.combat_abilities()
	check("an off-hand sword adds its own swing and thrust", names.call(fighter) == ["Swing", "Thrust", "Swing (off hand)", "Thrust (off hand)"],
		"got %s" % [names.call(fighter)])
	check("the off hand is -4 to hit", fighter.to_hit_target(beast, all[2]) == fighter.to_hit_target(beast, all[0]) - 4)
	var greatsword := ItemInstance.new(load("res://data/items/greatsword.tres"))
	var main := EquipSlot.Slot.MELEE_MAIN_HAND
	check("a two-handed weapon won't go in with the off hand full", not fighter.hands_allow(main, greatsword))
	fighter.unequip_item(off_hand)
	fighter.unequip_item(main)
	fighter.equip_item(main, greatsword)
	var shield := ItemInstance.new(load("res://data/items/wooden_shield.tres"))
	check("a two-handed weapon keeps the off hand empty", not fighter.hands_allow(off_hand, shield) and fighter.hands_allow(main, greatsword))
	var plain: int = fighter.to_hit_target(beast, all[0])
	check("ST 12 wields it freely", fighter.to_hit_target(beast, fighter.combat_abilities()[0]) == plain)
	fighter.set_base_stat(StatIds.ST, 10)
	check("ST 10 is -2 to hit with it", fighter.to_hit_target(beast, fighter.combat_abilities()[0]) == plain - 2)

	# Shields: a bash from the off hand, at no off-hand penalty; DB grows
	# with size.
	fighter.unequip_item(main)
	fighter.equip_item(off_hand, shield)
	all = fighter.combat_abilities()
	check("a shield adds a bash beside the punch", names.call(fighter) == ["Punch", "Shield Bash"], "got %s" % [names.call(fighter)])
	check("a bash takes no off-hand penalty", fighter.to_hit_target(beast, all[1]) == fighter.to_hit_target(beast, all[0]))
	var block_medium: int = fighter.block_target()
	fighter.unequip_item(off_hand)
	fighter.equip_item(off_hand, ItemInstance.new(load("res://data/items/tower_shield.tres")))
	check("a tower shield blocks 1 better than a medium one", fighter.block_target() == block_medium + 1)
	free_spawned()


func _dice(dice: Dictionary) -> String:
	var bonus: int = dice.flat_bonus
	return "%dd%s" % [dice.count, "" if bonus == 0 else "%+d" % bonus]

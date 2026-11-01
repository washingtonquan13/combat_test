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
	check("a hit through DR 2 takes 2 off", DamageResolver.injury(5, armored) == 3 and DamageResolver.injury(5, armored, cr, true) == 5)
	# B379: what gets through is multiplied, rounded down, at least 1.
	var cut: int = DamageResolver.injury(5, armored, DamageResolver.WoundType.CUTTING)
	var imp: int = DamageResolver.injury(5, armored, DamageResolver.WoundType.IMPALING)
	var pi_small: int = DamageResolver.injury(3, armored, DamageResolver.WoundType.SMALL_PIERCING)
	check("cutting x1.5, impaling x2, small piercing still does 1", cut == 4 and imp == 6 and pi_small == 1,
		"cut %d, imp %d, pi- %d" % [cut, imp, pi_small])
	swing.wound_type = DamageResolver.WoundType.IMPALING
	priced = swing.expected_damage(armored, armored)
	check("the AI prices the multiplier too", is_equal_approx(priced, 20.0 / 6.0), "got %.3f" % priced)
	var sword: GearItem = load("res://data/items/iron_sword.tres")
	var fireball: Ability = load("res://data/abilities/explosive_fireball.tres")
	var burns: bool = fireball.effects.any(func(e): return "wound_type" in e and e.wound_type == DamageResolver.WoundType.BURNING)
	check("the sword cuts and the fireball burns", sword.weapon_data.wound_type == DamageResolver.WoundType.CUTTING and burns)
	free_spawned()


func _dice(dice: Dictionary) -> String:
	var bonus: int = dice.flat_bonus
	return "%dd%s" % [dice.count, "" if bonus == 0 else "%+d" % bonus]

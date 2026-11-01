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
	check("a hit through DR 2 takes 2 off", DamageResolver.injury(5, armored) == 3 and DamageResolver.injury(5, armored, true) == 5)
	free_spawned()


func _dice(dice: Dictionary) -> String:
	var bonus: int = dice.flat_bonus
	return "%dd%s" % [dice.count, "" if bonus == 0 else "%+d" % bonus]

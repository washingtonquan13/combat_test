extends AiTestCase
## Dodge: every hit but a critical one is rolled against the defender's
## Dodge, and the hit chance the AI and the cursor readout show includes
## it. Only the odds are asserted; the roll itself is left to chance.


func wants_world() -> bool:
	return true


func run() -> void:
	var attacker: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	var defender: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(1.5, 0.0, 0.0))
	check("Dodge derives as (DX + HT) / 4 + 3", defender.get_stat(StatIds.DODGE) == 8,
		"got %d" % defender.get_stat(StatIds.DODGE))

	# Skill 10 hits on 108 of 216 rolls, 4 of them critical; Dodge 8
	# succeeds on 56. 4 + 104 x 160/216, over 216.
	var expected: float = (4.0 + 104.0 * 160.0 / 216.0) / 216.0
	var chance: float = attacker.hit_chance(defender, melee())
	check("hit chance counts the defender's Dodge, not against crits",
		absf(chance - expected) < 0.0001, "got %.4f, want %.4f" % [chance, expected])

	defender.apply_status(UnitCombat.downed_status())
	check("a Downed unit cannot dodge", not defender.can_dodge()
		and absf(attacker.hit_chance(defender, melee()) - 0.5) < 0.0001)
	free_spawned()

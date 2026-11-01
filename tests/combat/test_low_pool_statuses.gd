extends AiTestCase
## Bloodied (HP below a third) and Exhausted (FP below a third) halve
## Move and Dodge, rounding up, and come off when the pool climbs back.
## Both at once quarter them.


func run() -> void:
	var unit: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3.ZERO)
	var bloodied: StatusEffect = Unit.LOW_POOL_STATUSES[StatIds.HP]
	var exhausted: StatusEffect = Unit.LOW_POOL_STATUSES[StatIds.FP]

	unit.set_pool(StatIds.HP, 3)
	check("HP 3 of 10 is Bloodied: Move 5 -> 3, Dodge 8 -> 4",
		unit.has_status(bloodied) and unit.get_stat(StatIds.MOVE) == 3 and unit.get_stat(StatIds.DODGE) == 4,
		"Move %d, Dodge %d" % [unit.get_stat(StatIds.MOVE), unit.get_stat(StatIds.DODGE)])

	unit.set_pool(StatIds.FP, 3)
	check("Bloodied and Exhausted together quarter: Move 2, Dodge 2",
		unit.has_status(exhausted) and unit.get_stat(StatIds.MOVE) == 2 and unit.get_stat(StatIds.DODGE) == 2,
		"Move %d, Dodge %d" % [unit.get_stat(StatIds.MOVE), unit.get_stat(StatIds.DODGE)])

	unit.set_pool(StatIds.HP, 4)
	unit.set_pool(StatIds.FP, 4)
	check("back at a third, both come off and the stats return",
		not unit.has_status(bloodied) and not unit.has_status(exhausted)
		and unit.get_stat(StatIds.MOVE) == 5 and unit.get_stat(StatIds.DODGE) == 8,
		"Move %d, Dodge %d" % [unit.get_stat(StatIds.MOVE), unit.get_stat(StatIds.DODGE)])

	unit.set_pool(StatIds.HP, 2)
	# Straight into a second unit's StatusManager, past the pool rule, so
	# only load_state can have put the halving there.
	var loaded: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(3.0, 0.0, 0.0))
	loaded._status_manager.load_state(unit._status_manager.save_state())
	check("a loaded Bloodied keeps its halving",
		loaded.has_status(bloodied) and loaded.get_stat(StatIds.DODGE) == 4,
		"Dodge %d" % loaded.get_stat(StatIds.DODGE))
	free_spawned()

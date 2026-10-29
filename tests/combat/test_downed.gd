extends AiTestCase
## The downed rule: party members go Downed below 0 HP instead of dying,
## enemies still die at 0. Only the deterministic parts — the HT roll
## itself is left to chance and not asserted on.


func wants_world() -> bool:
	return true


func run() -> void:
	var saved: Array[StringName] = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = [] as Array[StringName]

	_thresholds()
	_enemies_die_at_zero()
	_minus_five_hp_is_death()
	_hits_drain_the_timer()
	await _fight_end_stabilizes()

	CombatAi.ai_factions = saved
	free_spawned()


func _thresholds() -> void:
	var unit: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	check("one threshold at 0", unit._combat._thresholds_crossed(5, 0) == 1)
	check("10 to -20 crosses 0, -10, -20", unit._combat._thresholds_crossed(10, -20) == 3)
	check("staying between thresholds crosses none", unit._combat._thresholds_crossed(-11, -19) == 0)
	remove_spawned(unit)


func _enemies_die_at_zero() -> void:
	var enemy: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3.ZERO)
	enemy.take_damage(15)
	check("an enemy dies at 0", not enemy.is_alive() and enemy.current_hp == 0)


func _minus_five_hp_is_death() -> void:
	var unit: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	unit.take_damage(100)
	check("-5x HP is death outright", not unit.is_alive() and unit.current_hp == -50)


func _hits_drain_the_timer() -> void:
	var unit: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	unit.current_hp = -3
	unit.apply_status(UnitCombat.downed_status())
	unit.take_damage(1)
	check("a hit takes a turn off the timer", unit.is_downed() and unit.downed_turns_left() == 2)
	check("picked up at negative HP", unit.pick_up() and not unit.is_downed() and unit.current_hp == -4)
	unit.apply_status(UnitCombat.downed_status())
	unit.take_damage(1)
	unit.take_damage(1)
	unit.take_damage(1)
	check("the last turn running out is death", not unit.is_alive())
	check("a cure can't take Downed off", not UnitCombat.downed_status().curable)


func _fight_end_stabilizes() -> void:
	var enemy: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3.ZERO)
	var ally: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(1.5, 0.0, 0.0))
	var downed: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(3.0, 0.0, 0.0))
	var roster: Array[Unit] = [enemy, ally, downed]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame
	downed.current_hp = -12
	downed.apply_status(UnitCombat.downed_status())
	downed.downed_changed.emit(downed)
	check("one ally down doesn't end the fight", fight.phase != Encounter.Phase.OUT_OF_COMBAT)
	enemy.take_damage(50)
	check("Downed is stabilized at 1 HP when the fight ends",
		fight.phase == Encounter.Phase.OUT_OF_COMBAT and downed.current_hp == 1 and not downed.is_downed())

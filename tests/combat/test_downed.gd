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
	_hits_mark_death()
	_turn_rolls()
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
	check("an enemy dies at 0", not enemy.is_alive() and enemy.get_pool(StatIds.HP) == 0)


func _minus_five_hp_is_death() -> void:
	var unit: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	unit.take_damage(100)
	check("-5x HP is death outright", not unit.is_alive() and unit.get_pool(StatIds.HP) == -50)


func _hits_mark_death() -> void:
	var unit: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	unit.set_pool(StatIds.HP, -3)
	unit.apply_status(UnitCombat.downed_status())
	unit.take_damage(1)
	check("a hit is one mark toward death", unit.is_downed() and unit.downed_tally() == {"stable": 0, "death": 1})
	unit.take_damage(1, true)
	check("a critical hit is two, and the third mark kills", not unit.is_alive())

	var other: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(2.0, 0.0, 0.0))
	other.set_pool(StatIds.HP, -4)
	other.apply_status(UnitCombat.downed_status())
	check("picked up at negative HP", other.pick_up() and not other.is_downed() and other.get_pool(StatIds.HP) == -4)
	check("a cure can't take Downed off", not UnitCombat.downed_status().curable)
	other.apply_status(UnitCombat.downed_status())
	other.heal(1)
	check("any heal picks a Downed unit up", not other.is_downed() and other.get_pool(StatIds.HP) == -3)
	remove_spawned(other)


## The rolls themselves are left to chance: whatever they come up, five
## turns always end one track or the other.
func _turn_rolls() -> void:
	var unit: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	unit.set_pool(StatIds.HP, -4)
	unit.apply_status(UnitCombat.downed_status())
	for i in 5:
		if not unit.is_alive() or unit.is_stable():
			break
		unit.tick_statuses()
	check("five turns end in stable or dead", not unit.is_alive() or (unit.is_stable() and unit.is_downed()))
	if unit.is_alive():
		var stable_at: Dictionary = unit.downed_tally().duplicate()
		unit.tick_statuses()
		check("a stable unit rolls no more", unit.downed_tally() == stable_at)
	remove_spawned(unit)

	var stable: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	stable.set_pool(StatIds.HP, -4)
	stable.apply_status(UnitCombat.downed_status())
	stable.stabilize()
	var tracker: DownedTracker = stable.get_node("DownedTracker")
	check("the tracker shows the stable icon, not the bars",
		tracker.is_visible_in_tree() and tracker._stable_icon.is_visible_in_tree() and not tracker._tracks.is_visible_in_tree())
	stable.take_damage(1)
	check("a hit on a stable unit starts both tracks over from a failure",
		stable.is_alive() and not stable.is_stable() and stable.downed_tally() == {"stable": 0, "death": 1})
	check("the tracker's bars come back, one red filled",
		tracker._tracks.is_visible_in_tree() and not tracker._stable_icon.is_visible_in_tree()
		and tracker._death_bars[0].get_theme_stylebox("panel") == tracker.death_on
		and tracker._death_bars[1].get_theme_stylebox("panel") == tracker.death_off)
	stable.pick_up()
	check("the tracker hides once picked up", not tracker.is_visible_in_tree())
	remove_spawned(stable)


func _fight_end_stabilizes() -> void:
	var enemy: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3.ZERO)
	var ally: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(1.5, 0.0, 0.0))
	var downed: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(3.0, 0.0, 0.0))
	var roster: Array[Unit] = [enemy, ally, downed]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame
	downed.set_pool(StatIds.HP, -12)
	downed.apply_status(UnitCombat.downed_status())
	downed.downed_changed.emit(downed)
	check("one ally down doesn't end the fight", fight.phase != Encounter.Phase.OUT_OF_COMBAT)
	enemy.take_damage(50)
	check("the fight's end leaves the Downed stable, still down, HP kept",
		fight.phase == Encounter.Phase.OUT_OF_COMBAT and downed.get_pool(StatIds.HP) == -12 and downed.is_stable())

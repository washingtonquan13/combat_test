extends AiTestCase
## Advantages: numbers scale by level and name their source, the status
## behind one stays hidden, and a pool holding the bonus survives every
## way a unit is rebuilt.


func wants_world() -> bool:
	return true


func run() -> void:
	var extra: Advantage = AdvantageDatabase.find(&"extra_hit_points")
	check("the authored advantage is found by id", extra != null)
	if extra == null:
		return
	_test_levels(extra)
	_test_save_and_load(extra)
	_test_definition(extra)
	_test_granted_ability()
	_test_party_round_trip(extra)
	free_spawned()


func _test_levels(extra: Advantage) -> void:
	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	hero.set_advantage_level(extra, 3)
	check("three levels add three HP", hero.get_stat(StatIds.HP) == 13.0, str(hero.get_stat(StatIds.HP)))
	check("a stat tooltip names it", hero.stat_modifier_sources(StatIds.HP).has("Extra Hit Points"),
		str(hero.stat_modifier_sources(StatIds.HP)))
	check("it is not on the status row", hero.active_statuses().is_empty())
	check("the authored file keeps its per-level number", extra.behaviors[0].amount == 1)

	hero.set_advantage_level(extra, 99)
	check("a level is capped at max_level", hero.advantage_level(&"extra_hit_points") == 10
		and hero.get_stat(StatIds.HP) == 20.0, str(hero.get_stat(StatIds.HP)))
	hero.set_advantage_level(extra, 0)
	check("level 0 takes it away", hero.get_advantages().is_empty() and hero.get_stat(StatIds.HP) == 10.0)


func _test_save_and_load(extra: Advantage) -> void:
	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	hero.set_advantage_level(extra, 3)
	hero.set_pool(StatIds.HP, 13)
	var state: Dictionary = hero.save_state()
	check("no status is saved for it", state["statuses"].is_empty(), str(state["statuses"]))

	var fresh: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	fresh.load_state(state)
	check("a load brings the level back", fresh.advantage_level(&"extra_hit_points") == 3)
	check("a load keeps the HP above the old maximum", fresh.get_pool(StatIds.HP) == 13, str(fresh.get_pool(StatIds.HP)))
	hero.load_state(state)
	check("loading over itself doesn't count it twice", hero.get_stat(StatIds.HP) == 13.0, str(hero.get_stat(StatIds.HP)))


func _test_definition(extra: Advantage) -> void:
	var born: UnitDefinition = _harness_definition().duplicate()
	var levels: Dictionary[Advantage, int] = {extra: 2}
	born.advantages = levels
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	unit.definition = born
	_spawn_parent().add_child(unit)
	_spawned.append(unit)
	check("a definition's advantage is on the unit", unit.advantage_level(&"extra_hit_points") == 2)
	check("the unit starts with a full pool that counts it",
		unit.get_pool(StatIds.HP) == int(unit.get_stat(StatIds.HP))
		and unit.stat_modifier_sources(StatIds.HP).has("Extra Hit Points"),
		"%d of %s" % [unit.get_pool(StatIds.HP), unit.get_stat(StatIds.HP)])

	var changing: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	changing.definition = born
	changing.definition = _harness_definition()
	check("a new definition clears the old one's", changing.get_advantages().is_empty())
	changing.free()


func _test_granted_ability() -> void:
	var granted: Ability = melee()
	var trick := Advantage.new()
	trick.id = &"test_trick"
	trick.advantage_name = "Trick"
	trick.abilities.append(granted)
	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3.ZERO)
	hero.set_advantage_level(trick, 1)
	check("it grants its ability", hero.abilities.has(granted))
	hero.set_advantage_level(trick, 0)
	check("taking it away takes the ability", not hero.abilities.has(granted))


func _test_party_round_trip(extra: Advantage) -> void:
	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	hero.set_advantage_level(extra, 3)
	hero.set_pool(StatIds.HP, 13)
	var record: PartyMemberData = PartyManager._load_one(PartyManager._save_one(PartyManager._capture_one(hero)))
	var point := Node3D.new()
	_spawn_parent().add_child(point)
	var back: Unit = PartyManager.spawn_member(record, _spawn_parent(), point)
	_spawned.append(back)
	point.free()
	check("the party keeps the level through a save", back.advantage_level(&"extra_hit_points") == 3)
	check("the party keeps the HP above the old maximum", back.get_pool(StatIds.HP) == 13, str(back.get_pool(StatIds.HP)))

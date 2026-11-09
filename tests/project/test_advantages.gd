extends AiTestCase
## Advantages: numbers scale by level and name their source, the status
## behind one stays hidden, and a pool holding the bonus survives every
## way a unit is rebuilt.


class NoFallDamage extends StatusBehavior:
	func soften_fall(_unit: Unit, _damage: int) -> int:
		return 0


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
	_test_damage_resistance()
	_test_falls()
	_test_hard_to_kill()
	_test_charismatic()
	await _test_super_jump()
	free_spawned()


func _test_damage_resistance() -> void:
	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	hero.set_advantage_level(AdvantageDatabase.find(&"damage_resistance"), 2)
	check("Damage Resistance takes two off a hit", DamageResolver.injury(5, hero, DamageResolver.WoundType.CRUSHING) == 3)


func _test_falls() -> void:
	var catfall: Advantage = AdvantageDatabase.find(&"catfall")
	var plain: Unit = spawn_unit(&"player", 10, 20, 20, [melee()], Vector3(4, 0, 0))
	check("an 8 m fall hurts without Catfall", ArcFlight.take_fall(plain, 8.0) > 0)
	var cat: Unit = spawn_unit(&"player", 10, 20, 20, [melee()], Vector3(8, 0, 0))
	cat.set_advantage_level(catfall, 1)
	check("Catfall takes 4.5 m off a jump's fall", ArcFlight.take_fall(cat, 8.0) == 0)
	var hp: int = cat.get_pool(StatIds.HP)
	cat._movement._apply_fall_damage(5.0)
	check("and off a fall from flight", cat.get_pool(StatIds.HP) == hp)

	var halved: bool = false
	for _i in 30:
		var softened: int = cat.soften_fall(10)
		check("a landing is whole or half", softened == 10 or softened == 5, str(softened))
		halved = halved or softened == 5
	check("a DX roll halves it", halved)
	check("nothing softens a fall without it", plain.soften_fall(10) == 10)

	var cushion := Advantage.new()
	cushion.id = &"test_cushion"
	var behaviors: Array[StatusBehavior] = [NoFallDamage.new()]
	cushion.behaviors = behaviors
	var cushioned: Unit = spawn_unit(&"player", 10, 20, 20, [melee()], Vector3(12, 0, 0))
	cushioned.set_advantage_level(cushion, 1)
	check("a jump's fall is softened", ArcFlight.take_fall(cushioned, 20.0) == 0)
	hp = cushioned.get_pool(StatIds.HP)
	cushioned._movement._apply_fall_damage(20.0)
	check("and a fall from flight", cushioned.get_pool(StatIds.HP) == hp)


func _test_hard_to_kill() -> void:
	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	hero.set_advantage_level(AdvantageDatabase.find(&"hard_to_kill"), 3)
	var target: int = hero.roll_while_downed()["target"]
	check("Hard to Kill adds to the roll while Downed", target == 13, str(target))


func _test_charismatic() -> void:
	var plain: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(2, 0, 0))
	hero.set_advantage_level(AdvantageDatabase.find(&"charismatic"), 2)
	var gain: int = SkillCalculator.get_skill_level(hero, "Persuasion").skill_level - SkillCalculator.get_skill_level(plain, "Persuasion").skill_level
	check("Charismatic adds to Persuasion", gain == 2, str(gain))
	check("and not to Stealth", SkillCalculator.get_skill_level(hero, "Stealth").skill_level == SkillCalculator.get_skill_level(plain, "Stealth").skill_level)


func _test_super_jump() -> void:
	var jump: Ability = load("res://data/abilities/jump.tres")
	var targeting: GroundPointTargeting = jump.targeting
	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3.ZERO)
	var enemy: Unit = spawn_unit(&"enemy", 10, 10, 10, [], Vector3(0, 0, 20))
	var ordinary: float = targeting.range_for(hero)
	var super_jump: Advantage = AdvantageDatabase.find(&"super_jump")
	hero.set_advantage_level(super_jump, 3)
	check("three levels jump eight times as far", is_equal_approx(targeting.range_for(hero), ordinary * 8.0), str(targeting.range_for(hero)))
	check("and ignore 12 m of a fall", is_equal_approx(hero.counted_fall(13.0), 1.0), str(hero.counted_fall(13.0)))
	hero.set_advantage_level(super_jump, 1)
	check("a short hop keeps its low arc", is_equal_approx(targeting.arc_height_for(hero, Vector3(1, 0, 0)), targeting.flight_arc_height))
	check("a full jump goes twice as high", is_equal_approx(targeting.arc_height_for(hero, Vector3(ordinary * 2.0, 0, 0)), targeting.flight_arc_height * 2.0))

	var roster: Array[Unit] = [hero, enemy]
	CombatManager.start_combat(roster)
	for _i in 5:
		await get_tree().physics_frame
	hero.global_position = Vector3.ZERO
	hero.move_remaining = 2.5
	var click := Vector3(4.4, 0, 0)
	var landing: Vector3 = targeting.landing_for(hero, click)
	check("the Move left reaches twice as far", landing.is_equal_approx(click), str(landing))
	jump.effects[0].apply(hero, click, jump, false)
	check("and costs half as much", is_equal_approx(hero.move_remaining, 0.3), str(hero.move_remaining))
	enemy.take_damage(50)


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

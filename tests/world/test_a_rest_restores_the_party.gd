extends AiTestCase
## Resting (docs/systems/rest.md): an inn is free and fills everyone, the
## Downed included; making camp spends one Camp Supplies if there is one,
## and the night there fills everyone with it and gives back half
## without, once; every rest empties the overworld's cleared encounter
## counts. The trip to the camp and its ambush are the random encounter
## suite's (test_a_random_encounter_is_fought.gd).


func wants_world() -> bool:
	return true


func run() -> void:
	var saved_groups: Array[PartyGroup] = PartyManager.groups.duplicate()
	var saved_active: PartyGroup = PartyManager.active_group
	var saved_bag := PartyManager.inventory.save_state()
	var saved_flags := FlagManager.save_state()
	PartyManager.groups = [] as Array[PartyGroup]
	PartyManager.active_group = null
	PartyManager.inventory.clear()

	var a: Unit = spawn_unit(&"player", 10, 10, 20, [melee()], Vector3.ZERO)
	var b: Unit = spawn_unit(&"player", 10, 10, 20, [melee()], Vector3(2.0, 0.0, 0.0))
	PartyManager.add_member(a)
	PartyManager.add_member(b)
	check("SETUP: resting is allowed here", Rest.blocked_reason() == "", Rest.blocked_reason())

	a.set_pool(StatIds.HP, 2)
	b.set_pool(StatIds.HP, -3)
	b.apply_status(UnitCombat.downed_status())
	FlagManager.set_flag(OverworldEncounters.CLEARED_PREFIX + "TestWilds", 2)
	check("an inn rest is taken, with no supplies", Rest.inn_rest())
	check("and fills everyone", a.get_pool(StatIds.HP) == 20 and b.get_pool(StatIds.HP) == 20,
		"%d, %d" % [a.get_pool(StatIds.HP), b.get_pool(StatIds.HP)])
	check("and picks the Downed up", not b.is_downed())
	check("and the wilds fill again", OverworldEncounters.cleared_in("TestWilds") == 0)

	a.set_pool(StatIds.HP, 2)
	b.set_pool(StatIds.HP, -3)
	b.apply_status(UnitCombat.downed_status())
	var plan := Rest.plan_camp()
	check("camp without supplies is still made", not plan.is_empty() and not plan.supplied)
	FlagManager.set_flag(OverworldEncounters.CLEARED_PREFIX + "TestWilds", 2)
	Rest.rest_at_camp()
	check("and gives back half", a.get_pool(StatIds.HP) == 12, "%d" % a.get_pool(StatIds.HP))
	check("to the Downed too, who get up", not b.is_downed() and b.get_pool(StatIds.HP) == 7,
		"%d" % b.get_pool(StatIds.HP))
	check("and the wilds fill again", OverworldEncounters.cleared_in("TestWilds") == 0)
	Rest.rest_at_camp()
	check("one night per camp", a.get_pool(StatIds.HP) == 12, "%d" % a.get_pool(StatIds.HP))

	var supplies := ItemInstance.new(Rest.SUPPLIES)
	supplies.count = 2
	PartyManager.inventory.add(supplies)
	plan = Rest.plan_camp()
	check("camp with supplies spends one", plan.supplied and Rest.supplies_count() == 1,
		"%d" % Rest.supplies_count())
	Rest.rest_at_camp()
	check("and the night fills everyone", a.get_pool(StatIds.HP) == 20 and b.get_pool(StatIds.HP) == 20,
		"%d, %d" % [a.get_pool(StatIds.HP), b.get_pool(StatIds.HP)])

	PartyManager.groups = saved_groups
	PartyManager.active_group = saved_active
	PartyManager.inventory.load_state(saved_bag)
	FlagManager.load_state(saved_flags)
	free_spawned()

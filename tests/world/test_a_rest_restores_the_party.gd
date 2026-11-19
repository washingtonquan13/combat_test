extends AiTestCase
## Resting (docs/systems/rest.md): a short rest gives back half and leaves
## the Downed down; a full rest spends one Camp Supplies, fills everyone
## and picks the Downed up, and refuses with none; both empty the
## overworld's cleared encounter counts.


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
	check("a short rest is taken", Rest.short_rest())
	check("and gives back half", a.get_pool(StatIds.HP) == 12, "%d" % a.get_pool(StatIds.HP))
	check("but leaves the Downed down", b.is_downed() and b.get_pool(StatIds.HP) == -3)
	check("and the wilds fill again", OverworldEncounters.cleared_in("TestWilds") == 0)

	check("no supplies, no full rest", not Rest.full_rest() and b.is_downed())
	var supplies := ItemInstance.new(Rest.SUPPLIES)
	supplies.count = 2
	PartyManager.inventory.add(supplies)
	FlagManager.set_flag(OverworldEncounters.CLEARED_PREFIX + "TestWilds", 2)
	check("with supplies, a full rest is taken", Rest.full_rest())
	check("and costs one", Rest.supplies_count() == 1, "%d" % Rest.supplies_count())
	check("and fills everyone", a.get_pool(StatIds.HP) == 20 and b.get_pool(StatIds.HP) == 20,
		"%d, %d" % [a.get_pool(StatIds.HP), b.get_pool(StatIds.HP)])
	check("and picks the Downed up", not b.is_downed())
	check("and the wilds fill again", OverworldEncounters.cleared_in("TestWilds") == 0)

	PartyManager.groups = saved_groups
	PartyManager.active_group = saved_active
	PartyManager.inventory.load_state(saved_bag)
	FlagManager.load_state(saved_flags)
	free_spawned()

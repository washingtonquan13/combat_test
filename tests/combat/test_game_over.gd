extends AiTestCase
## The party loses when nobody in it is left standing: every member Downed
## or dead. Only the rule and its signal; the screen that answers it lives
## in MainRoot and is checked by hand.


func wants_world() -> bool:
	return true


func run() -> void:
	var saved_groups: Array[PartyGroup] = PartyManager.groups.duplicate()
	var saved_active: PartyGroup = PartyManager.active_group
	PartyManager.groups = [] as Array[PartyGroup]
	PartyManager.active_group = null

	var a: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	var b: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(2.0, 0.0, 0.0))
	PartyManager.add_member(a)
	PartyManager.add_member(b)
	var fired: Array[int] = [0]
	var on_defeat := func() -> void: fired[0] += 1
	PartyManager.defeated.connect(on_defeat)

	_down(a)
	await get_tree().process_frame
	check("one member standing is not a loss", not PartyManager.is_defeated() and fired[0] == 0)
	check("SETUP: saving is allowed before the loss", SaveManager.can_save())

	_down(b)
	await get_tree().process_frame
	check("the last one standing going Downed is a loss", PartyManager.is_defeated() and fired[0] == 1)
	check("a lost game can't be saved", not SaveManager.can_save())

	b.heal(1)
	check("picking one up undoes it", not PartyManager.is_defeated())

	b.take_damage(100)
	await get_tree().process_frame
	check("the rest dying is a loss too", PartyManager.is_defeated() and fired[0] == 2)

	PartyManager.defeated.disconnect(on_defeat)
	PartyManager.groups = saved_groups
	PartyManager.active_group = saved_active
	free_spawned()


func _down(unit: Unit) -> void:
	unit.set_pool(StatIds.HP, -3)
	unit.apply_status(UnitCombat.downed_status())
	unit.downed_changed.emit(unit)

extends AiTestCase
## Systems answer about a world, not about the game.
##
## Every bug found in play since the merge has been one shape: a rule that
## was correct while there was one world, silently acting as a global rule.
## A fight adopting a unit two areas away. Perception refusing to start one
## anywhere because one was running somewhere. Dialogue silenced everywhere
## by a battle nobody was near.
##
## The tell each time is a global question — CombatManager.in_combat,
## any_combat_running, UnitQuery.living_units, raw distance — where the
## honest question is per-unit or per-world.
##
## Two live World3Ds with units at IDENTICAL coordinates, which is the only
## arrangement that can tell a scoped query from an unscoped one: in a
## one-world game the two are indistinguishable, which is exactly why this
## class keeps shipping.

var _viewport_a: SubViewport
var _viewport_b: SubViewport
var _ally_a: Unit
var _foe_a: Unit
var _ally_b: Unit
var _foe_b: Unit
var _fight_a: Encounter = null
var _saved_factions: Array = []


func run() -> void:
	_saved_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []

	await _build_two_worlds()
	if _ally_a == null:
		check("SETUP: two populated worlds", false)
		_teardown()
		return

	await _a_fight_stays_in_its_own_world()
	await _the_sweep_does_not_reach_across()
	# Before the awareness case, which is what finishes world A's fight.
	_a_unit_only_joins_a_fight_where_it_stands()
	await _ending_a_fight_only_clears_its_own_world()

	_ladders_belong_to_a_world()

	_teardown()


func _build_two_worlds() -> void:
	_viewport_a = _make_viewport()
	_viewport_b = _make_viewport()
	await get_tree().process_frame

	# Same coordinates in both: every area in this project is authored
	# around the origin, so two live worlds genuinely do overlap, and a
	# query that used raw distance would see all four as one crowd.
	_ally_a = _spawn_in(_viewport_a, &"player", Vector3.ZERO)
	_foe_a = _spawn_in(_viewport_a, &"enemy", Vector3(2.0, 0.0, 0.0))
	_ally_b = _spawn_in(_viewport_b, &"player", Vector3.ZERO)
	_foe_b = _spawn_in(_viewport_b, &"enemy", Vector3(2.0, 0.0, 0.0))
	await get_tree().physics_frame


func _make_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	_root.add_child(viewport)
	return viewport


func _spawn_in(viewport: SubViewport, faction: StringName, position: Vector3) -> Unit:
	var unit: Unit = load("res://unit.tscn").instantiate()
	viewport.add_child(unit)
	unit.faction = faction
	unit.strength = 12
	unit.dexterity = 12
	unit.maximum_hp = 30
	unit.current_hp = 30
	var abilities: Array[Ability] = [melee()]
	unit.abilities = abilities
	unit.global_position = position
	unit.reset_turn_actions()
	return unit


## The reported bug, as a property: a battle in one world must not reach
## into another, in either direction.
func _a_fight_stays_in_its_own_world() -> void:
	var combatants: Array[Unit] = [_ally_a, _foe_a]
	_fight_a = CombatManager.start_combat(combatants)
	await get_tree().process_frame

	check("SETUP: a fight is running in world A",
		is_instance_valid(_fight_a) and _fight_a.is_running)

	# Asserted BEFORE the sweep runs, because the sweep may legitimately
	# start a fight in B as well — that is the scoping working, and it would
	# make "is B fighting" useless as evidence afterwards.
	check("a fight in A does not make anyone in B a combatant",
		not _ally_b.in_combat() and not _foe_b.in_combat(),
		"a battle elsewhere counted as their fight")

	check("and is not 'running' for a unit in B",
		not CombatManager.combat_running_in_world_of(_ally_b),
		"asked globally, so nothing in B could ever start its own")

	check("while it certainly is for a unit in A",
		CombatManager.combat_running_in_world_of(_ally_a))


## The sweep is what dragged newcomers into the wrong world's battle: it
## measured raw distance, and both worlds sit on the origin.
func _the_sweep_does_not_reach_across() -> void:
	DetectionManager.enabled = true
	DetectionManager.scan()
	DetectionManager.enabled = false
	await get_tree().process_frame

	if not is_instance_valid(_fight_a):
		check("SETUP: world A's fight survived the sweep", false)
		return

	check("world B's units are not adopted by world A's fight",
		not _fight_a.turn_order.has(_ally_b)
			and not _fight_a.turn_order.has(_foe_b),
		"pulled into a battle they are nowhere near")

	# If perception started one in B, that is the point — it could not,
	# while any fight anywhere counted as "already fighting here".
	if is_instance_valid(_ally_b) and _ally_b.in_combat():
		check("a fight that starts in B is B's own, not A's",
			_ally_b.encounter != _fight_a,
			"joined the battle in the other world")
	else:
		check("nothing in B was enrolled in a fight it is not in",
			true)


## Awareness was reset for every unit in every world whenever any fight
## ended, quietly undoing an ambush two areas away.
func _ending_a_fight_only_clears_its_own_world() -> void:
	if not is_instance_valid(_foe_b) or not is_instance_valid(_ally_b):
		check("SETUP: world B still has both its units", false)
		return

	_foe_b.awareness().notice(_ally_b, true)
	if not _foe_b.awareness().is_aware_of(_ally_b):
		check("SETUP: world B's enemy has noticed somebody", false)
		return
	check("SETUP: world B's enemy has noticed somebody", true)

	if is_instance_valid(_fight_a) and _fight_a.is_running:
		_fight_a.finish(&"")
		await get_tree().process_frame

	check("a fight ending in A does not make B's enemy forget",
		is_instance_valid(_foe_b) and _foe_b.awareness().is_aware_of(_ally_b),
		"an unrelated skirmish finishing wiped an ambush two areas away")

## A unit can only join a fight happening where it is standing.
##
## Reported from play as "we only have one combat": two areas' fights
## showed as a single initiative row and units in one area were
## controllable from the other. The debug spawner called
## add_unit_to_combat with no encounter, which fell back to
## focused_encounter — the fight ON SCREEN, not the fight where the unit
## was. ONE such member is enough to poison an encounter: from then on
## _draw_in_latecomers finds a legitimately same-world combatant inside it
## and pulls in more, until the two are one.
func _a_unit_only_joins_a_fight_where_it_stands() -> void:
	if not is_instance_valid(_fight_a):
		check("SETUP: world A had a fight", false)
		return

	var newcomer: Unit = _spawn_in(_viewport_b, &"enemy", Vector3(4.0, 0.0, 0.0))

	# Staged, not assumed: the reported condition is the player LOOKING at
	# one area's fight while a unit appears in another. The sweep above may
	# have started a fight in B and taken focus with it, which would make the
	# fallback check below pass without testing anything.
	CombatManager.focused_encounter = _fight_a
	check("SETUP: the fight on screen is world A's",
		CombatManager.focused_encounter == _fight_a)

	# Exactly what the debug spawner did: no encounter, no reference unit.
	CombatManager.add_unit_to_combat(newcomer)

	check("a unit is not enrolled in a fight in another world",
		not _fight_a.turn_order.has(newcomer),
		"joined a battle it is nowhere near, which merges the two")

	# And the guard holds even when the wrong fight is named outright.
	CombatManager.add_unit_to_combat(newcomer, null, _fight_a)
	check("and not even when that fight is named explicitly",
		not _fight_a.turn_order.has(newcomer),
		"the choke point let a caller poison the encounter anyway")

	if is_instance_valid(newcomer):
		if newcomer.is_in_group("units"):
			newcomer.remove_from_group("units")
		if newcomer.get_parent():
			newcomer.get_parent().remove_child(newcomer)
		newcomer.queue_free()


## "ladders" is one global group with no world in it, and both worlds sit
## on the origin.
func _ladders_belong_to_a_world() -> void:
	var route: Dictionary = Ladder.find_route(_ally_b, Vector3(0.0, 6.0, 0.0))
	var reached_across: bool = false
	if not route.is_empty() and route.has("ladder"):
		var ladder = route["ladder"]
		if ladder is Node3D and (ladder as Node3D).is_inside_tree():
			reached_across = (ladder as Node3D).get_world_3d() != _ally_b.get_world_3d()
	check("a unit is never routed to a ladder in another world",
		not reached_across,
		"climbing something that is not there")


func _teardown() -> void:
	if is_instance_valid(_fight_a) and _fight_a.is_running:
		_fight_a.finish(&"")
	for unit in [_ally_a, _foe_a, _ally_b, _foe_b]:
		if is_instance_valid(unit):
			if unit.is_in_group("units"):
				unit.remove_from_group("units")
			if unit.get_parent():
				unit.get_parent().remove_child(unit)
			unit.queue_free()
	for viewport in [_viewport_a, _viewport_b]:
		if is_instance_valid(viewport):
			_root.remove_child(viewport)
			viewport.queue_free()
	CombatAi.ai_factions = _saved_factions

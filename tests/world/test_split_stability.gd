extends AiTestCase
## A fight survives the rest of the party walking away from it.
##
## Reported from play: two members in a battle, the other two sent to
## different areas, and the fight ends by itself — "mutual defeat" in the
## log with no actions taken — while the two fighting vanish. Separately,
## members standing in other areas sometimes stop being selectable, with or
## without a fight involved.
##
## "Mutual defeat" is the message finish(&"") prints, and the only thing
## that calls finish(&"") without a winner is WorldContext.dispose() — so
## the fight's world was torn down under it. Both symptoms follow from one
## cause if a group stops being findable: an unfindable group means its
## area is unearned (freed, taking the fight and the fighters with it) AND
## means clicking its members' portraits reaches nothing.

const HOME := &"test_arena"
const AWAY := &"test_area_2"
const FAR := &"cathedral_of_shadows"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _saved_factions: Array = []

var _fighters: Array[Unit] = []
var _wanderers: Array[Unit] = []
var _enemy: Unit = null
var _fight: Encounter = null


func run() -> void:
	_saved_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []

	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return

	if await _stage_the_scenario():
		await _the_wanderers_leave_one_at_a_time()
		_the_fight_is_still_running()
		_everybody_is_still_reachable()
		await _a_half_abstract_group_is_embodied_whole()

	_restore()


## The live members, padded out with fresh ones in the loaded world until
## there are enough for the scenario.
func _party_of(wanted: int) -> Array[Unit]:
	var party: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			party.append(unit)

	var world: Node = WorldManager.current_world()
	while party.size() < wanted and is_instance_valid(world):
		var extra: Unit = spawn_brute(float(party.size()) * 2.0)
		extra.reparent(world, false)
		PartyManager.add_member(extra)
		party.append(extra)
	return party


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_load()


## Four members in one area, two of them in a fight.
func _stage_the_scenario() -> bool:
	# Collapse to one group first: these suites share a PartyManager, and
	# members counts only the EMBODIED half, so a scattered party arrives
	# here looking like a party of one.
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	# Topped up rather than assumed: these suites share a PartyManager and
	# whatever ran before may have left fewer. The scenario needs exactly
	# four — two to fight and two to wander off separately.
	var party: Array[Unit] = _party_of(4)
	if party.size() < 4:
		check("SETUP: four members, as reported", false,
			"%d member(s)" % party.size())
		return false

	_fighters = [party[0], party[1]]
	_wanderers = [party[2], party[3]]

	_enemy = spawn_unit(&"enemy", 12, 12, 30, [melee()],
		_fighters[0].global_position + Vector3(3.0, 0.0, 0.0))
	_enemy.reparent(WorldManager.current_world(), false)
	await get_tree().physics_frame

	var combatants: Array[Unit] = [_fighters[0], _fighters[1], _enemy]
	_fight = CombatManager.start_combat(combatants)
	await get_tree().process_frame

	check("SETUP: a fight is running with two members in it",
		is_instance_valid(_fight) and _fight.is_running)
	return is_instance_valid(_fight) and _fight.is_running


## The reported sequence: one leaves, then the other, to different places.
func _the_wanderers_leave_one_at_a_time() -> void:
	WorldManager.load_area(AWAY, &"", [_wanderers[0]] as Array[Unit])
	await get_tree().process_frame

	check("the first wanderer got out while the fight ran",
		is_instance_valid(_wanderers[0])
			and WorldManager.context() != null
			and WorldManager.context().contains(_wanderers[0]),
		"they did not arrive")

	# Back to the fight's world to send the second one somewhere else.
	var home_group: PartyGroup = PartyManager.group_of(_wanderers[1])
	check("the second wanderer is still in a group after the first left",
		home_group != null,
		"they belong to no group, so nothing can reach or keep them")
	if home_group == null:
		return

	check("and that group's world can still be focused",
		WorldManager.focus_group(home_group),
		"the area they are standing in is gone")
	await get_tree().process_frame

	WorldManager.load_area(FAR, &"", [_wanderers[1]] as Array[Unit])
	await get_tree().process_frame

	check("the second wanderer got out too",
		is_instance_valid(_wanderers[1])
			and WorldManager.context() != null
			and WorldManager.context().contains(_wanderers[1]))


## THE bug. Nothing happened in that fight — nobody acted — so the only way
## it ends is if something ended it.
func _the_fight_is_still_running() -> void:
	check("the fight is still running after everyone else walked away",
		is_instance_valid(_fight) and _fight.is_running,
		"it ended by itself, with no actions taken")

	check("and the two fighting still exist",
		is_instance_valid(_fighters[0]) and is_instance_valid(_fighters[1]),
		"they were freed along with their world")

	check("their world is still loaded",
		WorldManager.is_area_resident(HOME),
		"freed while a battle was running in it")


## The other report, which needs no fight at all: a member somewhere else
## stops being selectable. Clicking a portrait routes through
## WorldManager.focus_group(PartyManager.group_of(unit)), so it fails if
## either the group or its world has gone.
func _everybody_is_still_reachable() -> void:
	var unreachable: Array[String] = []
	for unit in _fighters + _wanderers:
		if not is_instance_valid(unit):
			unreachable.append("<freed>")
			continue
		var group: PartyGroup = PartyManager.group_of(unit)
		if group == null:
			unreachable.append("%s: no group" % unit.name)
		elif not WorldManager.is_area_resident(group.area_id):
			unreachable.append("%s: area %s gone" % [unit.name, group.area_id])

	check("every member can still be reached from their portrait",
		unreachable.is_empty(), ", ".join(unreachable))


## A group can hold live units for SOME of its members and only records
## for the rest — that is exactly what absorb() leaves behind when an
## abstract group merges into an embodied one, which is what happens when
## a group walks into an area where another is already standing.
##
## Embodying used to branch on the group as a whole: relocate if embodied,
## build if not. Taking the relocate branch carried the units it had and
## silently dropped everyone who existed only as a record — no Unit, so no
## portrait, nothing selectable, and nothing to find them by.
func _a_half_abstract_group_is_embodied_whole() -> void:
	var world: Node = WorldManager.current_world()
	var area: AreaDefinition = WorldManager.current_area()
	if not is_instance_valid(world) or area == null:
		check("SETUP: a world to embody into", false)
		return

	var marker := Node3D.new()
	world.add_child(marker)

	var group := PartyGroup.new()
	group.area_id = area.id
	group.embodied = true
	PartyManager.groups.append(group)

	# One member who is here.
	var present: Unit = spawn_brute(30.0)
	present.reparent(world, false)
	present.persistent_id = &"probe_present"
	group.units.append(present)

	# And one who exists only as a record, as after a merge.
	var absent := PartyMemberData.new()
	absent.id = &"probe_absent"
	absent.display_name = "Absent"
	absent.faction = &"player"
	absent.maximum_hp = 10
	absent.current_hp = 10
	group.records.append(absent)

	PartyManager.embody(group, world, marker)
	await get_tree().process_frame

	var built: bool = false
	for unit in group.live_units():
		if unit.persistent_id == &"probe_absent":
			built = true
	check("a member who existed only as a record is built, not dropped",
		built,
		"they have no Unit, so nothing can show or select them")

	check("and the one already here is not duplicated",
		group.live_units().size() == 2,
		"%d unit(s) for 2 members" % group.live_units().size())

	for unit in group.live_units():
		if PartyManager.is_member(unit):
			PartyManager.remove_member(unit)
		if unit.is_in_group("units"):
			unit.remove_from_group("units")
		if unit.get_parent():
			unit.get_parent().remove_child(unit)
		unit.queue_free()
	PartyManager.groups.erase(group)
	marker.queue_free()


func _restore() -> void:
	if is_instance_valid(_fight) and _fight.is_running:
		_fight.finish(&"")
	if is_instance_valid(_enemy):
		if _enemy.is_in_group("units"):
			_enemy.remove_from_group("units")
		if _enemy.get_parent():
			_enemy.get_parent().remove_child(_enemy)
		_enemy.queue_free()

	WorldManager.unload(true)
	CombatAi.ai_factions = _saved_factions
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()

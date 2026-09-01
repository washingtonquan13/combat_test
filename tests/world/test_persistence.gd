extends AiTestCase
## Units remember what happened to them, and can be found again afterwards.
##
## Two gaps sat underneath the whole save system. Nothing identified a unit
## across a save — `persistent_id` was an authored export for area content,
## and party members spawned from records had none — so a turn order, or
## anything else written down about a unit, could not be written down at
## all. And `Unit` implemented neither `save_state` nor `load_state`, so
## `AreaState` recorded who DIED and what containers held, and nothing
## else.
##
## The second gap was already visible in play rather than only across
## saves: a world that has not earned residency is freed and rebuilt from
## authored content, so an enemy you wounded and walked away from came back
## whole.

const HOME := &"test_arena"
const AWAY := &"test_area_2"
const WEAKENED := "res://data/statuses/weakened.tres"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []


func run() -> void:
	_a_unit_round_trips_its_own_state()
	_an_id_survives_capture_and_respawn()

	if _install_synthetic_host():
		await _an_area_remembers_what_happened_in_it()
		await _a_split_party_round_trips()
		await _a_fight_resumes_where_it_was_left()
		# Before the host goes: freeing it frees every world mounted under it,
		# and WorldManager would still be holding records that name them.
		WorldManager.unload()
		await get_tree().process_frame
		_restore_host()


# --- state ------------------------------------------------------------

func _a_unit_round_trips_its_own_state() -> void:
	var before: Unit = spawn_brute(0.0)
	before.current_hp = 7
	before.current_fp = 3
	before.move_remaining = 2.5
	before.has_attacked = true
	before.global_position = Vector3(3.0, 0.0, -4.0)

	var effect: StatusEffect = load(WEAKENED)
	if effect:
		before.apply_status(effect)

	var state: Dictionary = before.save_state()

	var after: Unit = spawn_brute(20.0)
	after.load_state(state)

	check("hp and fp come back", after.current_hp == 7 and after.current_fp == 3,
		"%d hp, %d fp" % [after.current_hp, after.current_fp])
	check("the turn already partly spent comes back",
		is_equal_approx(after.move_remaining, 2.5) and after.has_attacked,
		"%.2f move, attacked=%s" % [after.move_remaining, after.has_attacked])
	check("and where they were standing",
		after.global_position.is_equal_approx(Vector3(3.0, 0.0, -4.0)),
		str(after.global_position))

	if effect:
		# Nothing serialized statuses at all before this.
		check("statuses come back, with their remaining duration",
			after.has_status(effect),
			"a buff or debuff was silently dropped")


## Identity is the whole of the rest: everything else here reduces to
## "write down who, then find them again". A regenerated id would restore
## plausible-looking state onto the wrong unit rather than failing.
func _an_id_survives_capture_and_respawn() -> void:
	var unit: Unit = spawn_brute(4.0)
	check("a unit nobody named starts unaddressable, as the convention says",
		unit.persistent_id == &"",
		"given an id that a world rebuild would not reproduce")

	PartyManager.add_member(unit)
	# Capture is where a party member is first named: the RECORD carries the
	# id from then on, which is what makes it survive a world being rebuilt.
	PartyManager.capture()
	var original: StringName = unit.persistent_id
	check("capture names a member who arrived without one",
		original != &"", "still unaddressable after capture")

	var record: PartyMemberData = null
	for candidate in PartyManager.roster:
		if candidate.id == original:
			record = candidate
			break
	check("capture carries the id onto the record", record != null,
		"the record could not name who it came from")

	if record:
		var respawned: Unit = PartyManager.spawn_member(record, _root, _root)
		check("and a respawned member is still the same person",
			respawned.persistent_id == original,
			"%s became %s" % [original, respawned.persistent_id])
		if respawned.is_in_group("units"):
			respawned.remove_from_group("units")
		respawned.queue_free()

	if PartyManager.is_member(unit):
		PartyManager.remove_member(unit)


# --- areas ------------------------------------------------------------

func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


## The in-play acceptance, headless: wound somebody, leave so their world
## is freed, come back and find them as you left them.
func _an_area_remembers_what_happened_in_it() -> void:
	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var victim: Unit = _an_npc_here()
	if victim == null:
		check("SETUP: an NPC in the area to wound", false)
		return

	var id: StringName = victim.persistent_id
	var wounded_to: int = maxi(1, victim.current_hp - 5)
	victim.current_hp = wounded_to
	victim.global_position += Vector3(2.0, 0.0, 2.0)
	var moved_to: Vector3 = victim.global_position

	# Leaving frees this world: nothing running in it, nobody left standing.
	WorldManager.load_area(AWAY)
	await get_tree().process_frame
	check("SETUP: the world really was freed rather than kept",
		not WorldManager.is_area_resident(HOME),
		"still resident, so this proves nothing")

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var again: Unit = _unit_with_id(id)
	check("the same NPC is there under the same id", again != null,
		"could not find %s after coming back" % id)
	if again == null:
		return

	check("still wounded", again.current_hp == wounded_to,
		"%d hp, expected %d" % [again.current_hp, wounded_to])
	check("and still where they had moved to",
		again.global_position.distance_to(moved_to) < 1.0,
		"back at their authored spot")


## A save used to write one flat member list and one area id, so splitting
## the party, saving and loading reunited everyone in one place. Nobody was
## lost — every record was written — but where they were standing was.
##
## Round-tripped through PartyManager's own save_state/load_state rather
## than a file: what is under test is whether the SHAPE carries a split,
## and going through disk would only add ConfigFile to the things that
## could be wrong.
func _a_split_party_round_trips() -> void:
	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var party: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			party.append(unit)
	if party.size() < 2:
		check("SETUP: a party to split", false, "%d member(s)" % party.size())
		return

	var going: Array[Unit] = [party[0]]
	WorldManager.load_area(AWAY, &"", going)
	await get_tree().process_frame

	var before_groups: int = PartyManager.groups.size()
	check("SETUP: the party really is split", before_groups == 2,
		"%d group(s)" % before_groups)

	# capture() first: a party member has no id until then (ids are minted
	# for records, not for every unit), so reading them before would key
	# everybody on the empty string and collapse them into one entry.
	PartyManager.capture()
	var expected: Dictionary = {}
	for group in PartyManager.groups:
		for record in group.records:
			expected[String(record.id)] = String(group.current_area_id())

	var state: Dictionary = PartyManager.save_state()
	check("the save writes one entry per group",
		state.get("groups", []).size() == before_groups,
		"%d group(s) written for %d" % [state.get("groups", []).size(), before_groups])

	PartyManager.load_state(state)

	check("and loading gets the same number back",
		PartyManager.groups.size() == before_groups,
		"%d group(s) after load" % PartyManager.groups.size())

	var restored: Dictionary = {}
	for group in PartyManager.groups:
		for record in group.records:
			restored[String(record.id)] = String(group.current_area_id())

	check("everybody is accounted for",
		restored.size() == expected.size(),
		"%d of %d" % [restored.size(), expected.size()])

	var misplaced: int = 0
	for id in expected:
		if restored.get(id, "") != expected[id]:
			misplaced += 1
	check("and everybody is still in the area they were in",
		misplaced == 0,
		"%d member(s) came back somewhere else" % misplaced)

	check("a group standing in an area with no Units is ABSTRACT on load",
		not PartyManager.groups[0].embodied,
		"a group claims to be embodied with nothing to be")


## can_save() refused mid-combat, and its own comment named exactly why:
## turn order, initiative and status effects were things nothing wrote.
## Now a fight is written down as who is in it, in what order, and how far
## through — every combatant's own state travelling with the unit rather
## than with the encounter.
##
## Round-tripped through the encounter's own save_state and
## CombatManager.restore_combat rather than through a file, for the same
## reason as the split test above: what is under test is the shape, not
## ConfigFile.
func _a_fight_resumes_where_it_was_left() -> void:
	var saved_factions: Array = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []

	WorldManager.load_area(HOME)
	await get_tree().process_frame
	PartyManager.capture()

	var ally: Unit = null
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			ally = unit
			break
	var foe: Unit = _an_npc_here()
	if ally == null or foe == null:
		check("SETUP: two named combatants", false)
		CombatAi.ai_factions = saved_factions
		return

	check("SETUP: both combatants are named",
		ally.persistent_id != &"" and foe.persistent_id != &"",
		"an unnamed combatant cannot be written down at all")

	var combatants: Array[Unit] = [ally, foe]
	var fight: Encounter = CombatManager.start_combat(combatants)
	await get_tree().process_frame

	if not is_instance_valid(fight) or not fight.is_running:
		check("SETUP: the fight started and is running", false)
		CombatAi.ai_factions = saved_factions
		return

	# Put it partway through DIRECTLY rather than by advancing turns. What
	# is under test is whether this state survives being written down, and
	# driving real turn advancement to reach it only adds a way for the
	# fight to end underneath the test instead.
	fight._turn_index = 1
	fight.round_number = 3
	fight.current_unit.move_remaining = 1.75
	# Held on to so the resume can be checked for IDENTITY and not just for
	# a matching id. CombatManager._find_by_id returns the FIRST unit in the
	# tree carrying an id, so a duplicate resolves silently to the wrong
	# instance — one that has never had a turn, and whose move_remaining is
	# therefore its untouched 0.0 default.
	var acting: Unit = fight.current_unit

	var expected_order: Array = []
	for unit in fight.turn_order:
		expected_order.append(String(unit.persistent_id))
	var expected_current: StringName = fight.current_unit.persistent_id
	var expected_round: int = fight.round_number
	var expected_move: float = fight.current_unit.move_remaining

	# The headline. can_save() refused mid-combat for exactly as long as
	# nothing could write a fight down.
	check("a save is allowed while a battle is running",
		SaveManager.can_save(),
		"still refused, so none of the rest of this is reachable")

	var state: Dictionary = fight.save_state()
	check("the fight writes down everyone in it, in order",
		state.get("turn_order", []) == expected_order,
		str(state.get("turn_order", [])))

	# End it and rebuild from the record, which is what a load does.
	fight.finish(&"")
	await get_tree().process_frame
	check("SETUP: the original fight is over", not CombatManager.in_combat)

	var resumed: Encounter = CombatManager.restore_combat(state)
	await get_tree().process_frame

	check("the fight comes back", resumed != null and resumed.is_running,
		"nothing resumed")
	if resumed == null:
		CombatAi.ai_factions = saved_factions
		return

	var order: Array = []
	for unit in resumed.turn_order:
		order.append(String(unit.persistent_id))
	check("with the same initiative order", order == expected_order,
		"%s, expected %s" % [str(order), str(expected_order)])
	check("on the same unit's turn",
		resumed.current_unit != null
			and resumed.current_unit.persistent_id == expected_current,
		"resumed on somebody else")
	check("in the same round", resumed.round_number == expected_round,
		"round %d, expected %d" % [resumed.round_number, expected_round])

	check("and it comes back around the same unit, not a lookalike",
		resumed.current_unit == acting,
		"same persistent_id, different instance — two units are answering to it")

	# Turn economy belongs to the UNIT, not the encounter — the point of
	# keeping it out of save_state is that it comes back anyway.
	check("and the turn already partly spent is still partly spent",
		is_equal_approx(resumed.current_unit.move_remaining, expected_move),
		"%.2f, expected %.2f" % [resumed.current_unit.move_remaining, expected_move])

	resumed.finish(&"")
	await get_tree().process_frame
	CombatAi.ai_factions = saved_factions


func _an_npc_here() -> Unit:
	var context: WorldContext = WorldManager.context()
	for unit in UnitQuery.living_units(get_tree()):
		if context and not context.contains(unit):
			continue
		# An AUTHORED id specifically. A unit whose scene never named it is
		# not persistent, by the convention this project already had — and
		# giving it one here would only produce a key that never matches
		# again, since rebuilding the world instantiates a new one.
		if not unit.is_player_controlled() and unit.persistent_id.begins_with("test_arena_"):
			return unit
	return null


func _unit_with_id(id: StringName) -> Unit:
	var context: WorldContext = WorldManager.context()
	for unit in UnitQuery.living_units(get_tree()):
		if context and not context.contains(unit):
			continue
		if unit.persistent_id == id:
			return unit
	return null


func _restore_host() -> void:
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()

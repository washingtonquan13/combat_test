extends AiTestCase
## Every party member is always reachable.
##
## One property, asserted across a matrix of states, because "a unit became
## unclickable" has now been fixed three times with three different causes:
## a group holding records but no units, a focus gate that asked whether
## people could LEAVE, and a click routed through a second-hand record of
## where somebody was standing.
##
## Three causes, one symptom. A test written against any one of them would
## have caught only that one. This is written against the SYMPTOM instead:
## whatever state the party is in, asking to go to a member must either
## take you there or say why not — never fail silently, and never leave a
## member that nothing can name.
##
## That is what makes it a net rather than another patch. It does not need
## to know the next cause in order to catch it.

const HOME := &"test_arena"
const AWAY := &"test_area_2"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _saved_factions: Array = []


func run() -> void:
	_saved_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []

	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return

	await _together_in_one_world()
	await _split_across_two_worlds()
	await _with_one_group_abstract_on_the_overworld()
	await _with_a_fight_running()
	_a_stale_stored_area_does_not_lie()

	_a_refusal_is_never_silent()

	_restore()


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


# --- the property ------------------------------------------------------

## THE invariant. For every member, in whatever form they currently exist,
## reveal() must give a definite answer — and for anyone whose world is
## loaded, that answer must be "you are there now".
func _every_member_is_reachable(situation: String) -> void:
	var unreachable: Array[String] = []
	var unnamed: int = 0

	for entry in PartyManager.everyone():
		var unit: Unit = entry as Unit
		var group: PartyGroup = null
		var who: String = "?"

		if unit != null:
			group = PartyManager.group_of(unit)
			who = unit.display_name
		else:
			var record: PartyMemberData = entry as PartyMemberData
			if record == null:
				unnamed += 1
				continue
			who = record.display_name
			group = _group_holding(record)

		var result: int = WorldManager.reveal(unit, group)

		# A member whose area is not loaded is allowed to be out of reach —
		# but it must SAY so. Silence is the failure this exists to catch.
		if result == WorldManager.Reveal.NOT_FOUND:
			unreachable.append("%s: nothing knows where they are" % who)
		elif result == WorldManager.Reveal.AREA_NOT_LOADED:
			# Acceptable only if their area really is unloaded.
			if group and WorldManager.is_area_resident(group.current_area_id()):
				unreachable.append("%s: refused, but their area IS loaded" % who)
		elif result == WorldManager.Reveal.REFUSED_MODAL:
			# Acceptable only if a modal really is open. A fight is NOT one:
			# looking away moves nobody, and refusing for that reason is one of
			# the three historical causes this suite exists to catch.
			if not _a_modal_is_open():
				unreachable.append("%s: refused as modal with no modal open" % who)

	check("every member is reachable, %s" % situation,
		unreachable.is_empty(), ", ".join(unreachable))
	check("and every member is nameable, %s" % situation,
		unnamed == 0, "%d entry(s) are neither a unit nor a record" % unnamed)


## A conversation, negotiation, loot screen or context menu — something
## the player is genuinely INSIDE. Deliberately not combat: a fight is a
## thing you can look away from.
func _a_modal_is_open() -> bool:
	if InteractionMenu.is_open():
		return true
	var mode: GameMode.Mode = GameMode.current_mode()
	if mode == GameMode.Mode.EXPLORATION:
		return false
	if mode == GameMode.Mode.OVERWORLD:
		return false
	if mode == GameMode.Mode.COMBAT:
		return false
	return true


func _group_holding(record: PartyMemberData) -> PartyGroup:
	for group in PartyManager.groups:
		if group.records.has(record):
			return group
	return null


# --- the matrix --------------------------------------------------------

func _together_in_one_world() -> void:
	_collapse_to_one_group()
	WorldManager.load_area(HOME)
	await get_tree().process_frame
	_every_member_is_reachable("with the party together")


func _split_across_two_worlds() -> void:
	var live: Array[Unit] = _live_members()
	if live.size() < 2:
		check("SETUP: two members to split", false, "%d" % live.size())
		return

	var going: Array[Unit] = [live[0]]
	WorldManager.load_area(AWAY, &"", going)
	await get_tree().process_frame
	_every_member_is_reachable("with the party split across two areas")

	# And from the other side, which is the direction that broke: the
	# player commanding one group, reaching for somebody in the other.
	var back: PartyGroup = PartyManager.group_of(live[1]) if is_instance_valid(live[1]) else null
	if back:
		WorldManager.focus_group(back)
		await get_tree().process_frame
		_every_member_is_reachable("looking at the other half")


## An abstract group has no Unit anywhere — the case where the group's
## remembered area is the only thing that can answer.
func _with_one_group_abstract_on_the_overworld() -> void:
	var live: Array[Unit] = _live_members()
	if live.is_empty():
		check("SETUP: somebody to send to the overworld", false)
		return

	var going: Array[Unit] = [live[0]]
	WorldManager.load_area(&"overworld", &"", going)
	await get_tree().process_frame
	await get_tree().process_frame
	_every_member_is_reachable("with a group folded down to records")


## A fight must not make anybody unreachable — looking away moves nobody.
func _with_a_fight_running() -> void:
	var live: Array[Unit] = _live_members()
	if live.is_empty():
		check("SETUP: somebody to fight", false)
		return

	var fighter: Unit = live[0]
	var world: Node = fighter.get_parent()
	if not is_instance_valid(world):
		check("SETUP: the fighter is in a world", false)
		return

	var foe: Unit = spawn_unit(&"enemy", 12, 12, 30, [melee()],
		fighter.global_position + Vector3(2.0, 0.0, 0.0))
	foe.reparent(world, false)
	await get_tree().physics_frame

	var combatants: Array[Unit] = [fighter, foe]
	var fight: Encounter = CombatManager.start_combat(combatants)
	await get_tree().process_frame

	_every_member_is_reachable("with a battle running")

	if is_instance_valid(fight) and fight.is_running:
		fight.finish(&"")
	await get_tree().process_frame
	if is_instance_valid(foe):
		_spawned.erase(foe)
		if foe.is_in_group("units"):
			foe.remove_from_group("units")
		if foe.get_parent():
			foe.get_parent().remove_child(foe)
		foe.queue_free()


## Phase 1's claim, asserted directly rather than through a symptom.
##
## Sabotaging the derivation only SOMETIMES broke something downstream,
## which means the reachability property alone does not pin it: reveal()
## asks a live unit its own world, so a stale stored area stops being able
## to make anybody unreachable. That is the fix working — but it also
## leaves the derivation itself uncovered unless it is checked head on.
func _a_stale_stored_area_does_not_lie() -> void:
	var live: Array[Unit] = _live_members()
	if live.is_empty():
		check("SETUP: an embodied member to ask about", false)
		return

	var unit: Unit = live[0]
	var group: PartyGroup = PartyManager.group_of(unit)
	var truth: AreaDefinition = WorldManager.area_of(unit)
	if group == null or truth == null:
		check("SETUP: a member in a group in a loaded area", false)
		return

	var remembered: StringName = group.abstract_area_id
	group.abstract_area_id = &"somewhere_they_are_not"

	check("a group reports where its members ARE, not what was written down",
		group.current_area_id() == truth.id,
		"said %s; they are standing in %s" % [group.current_area_id(), truth.id])

	group.abstract_area_id = remembered


## The other half of the property: when it does refuse, it says which
## precondition failed rather than returning an unexplained false.
func _a_refusal_is_never_silent() -> void:
	var nowhere := PartyGroup.new()
	nowhere.abstract_area_id = &"an_area_that_does_not_exist"

	var result: int = WorldManager.reveal(null, nowhere)
	check("a member in an unloaded area is refused BY NAME",
		result == WorldManager.Reveal.AREA_NOT_LOADED,
		"got %d, which tells a caller nothing" % result)

	var lost := PartyGroup.new()
	check("and one nothing knows about is refused by name too",
		WorldManager.reveal(null, lost) == WorldManager.Reveal.NOT_FOUND)

	check("neither counts as having arrived",
		not WorldManager.revealed(result))


# --- helpers -----------------------------------------------------------

func _live_members() -> Array[Unit]:
	var live: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			live.append(unit)
	return live


## These suites share one PartyManager; a scattered party arriving here
## would test a shape this case did not choose.
func _collapse_to_one_group() -> void:
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]


func _restore() -> void:
	WorldManager.discard_worlds()
	_collapse_to_one_group()
	CombatAi.ai_factions = _saved_factions
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()

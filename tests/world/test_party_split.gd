extends AiTestCase
## The party can be in two places at once.
##
## Travel used to be a round trip through data: PartyManager.capture()
## copied every member into a PartyMemberData, the world was freed, and
## spawn_party() built fresh Units from those records on the other side.
## That was lossy by construction — _capture_one copies a fixed list of
## fields, so anything added to Unit and not to that list vanished on
## every area transition — and it could only ever move the party whole,
## because roster has no notion of who is going.
##
## Travellers now REPARENT between worlds. The two claims worth asserting
## are therefore about identity and about absence: the units that arrive
## are the same objects that left, and the ones that didn't travel are
## still standing where they were, in a world that consequently refuses to
## be freed.
##
## What makes this work is rungs 2 and 3a rather than anything here: every
## query, AI check, detection sweep and navigation query derives its world
## from the unit's own get_world_3d(), so re-parenting a unit simply puts
## it in the other world. This suite is largely checking that that claim
## was true.

const HOME := &"test_arena"
const AWAY := &"test_area_2"

var _traveller: Unit = null
var _stayer: Unit = null
var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false, "WorldManager refused")
		return

	await _travellers_arrive_as_the_same_units()
	await _a_member_left_behind_stays_behind()
	await _the_world_holding_them_cannot_be_freed()
	await _going_to_a_companion_moves_nobody()
	await _collecting_everyone_again()

	WorldManager.unload()
	await get_tree().process_frame
	_restore_host()


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_load()


## Identity again, as with residency, and for the same reason: a rebuilt
## unit and a carried one are indistinguishable by their fields. Only the
## object tells them apart.
func _travellers_arrive_as_the_same_units() -> void:
	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var before: Array[int] = _member_ids()
	if before.is_empty():
		check("SETUP: the home area put a party on the board", false)
		return
	check("SETUP: the home area put a party on the board", true)

	WorldManager.load_area(AWAY)
	await get_tree().process_frame

	check("the party that arrives is the party that left, object for object",
		_member_ids() == before,
		"rebuilt from roster — live state would have been dropped")
	check("and they are in the destination world, not the one they left",
		_all_members_in(WorldManager.context()))


## THE claim. Everything above would still pass if travel moved everyone.
func _a_member_left_behind_stays_behind() -> void:
	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var everyone: Array[Unit] = _living_members()
	if everyone.size() < 2:
		check("SETUP: at least two members to split", false,
			"%d member(s)" % everyone.size())
		return

	var going: Array[Unit] = [everyone[0]]
	var staying: Unit = everyone[1]
	_traveller = everyone[0]
	_stayer = staying
	var home_world: Node = WorldManager.current_world()

	WorldManager.load_area(AWAY, &"", going)
	await get_tree().process_frame

	check("the traveller went",
		is_instance_valid(going[0]) and WorldManager.context().contains(going[0]),
		"the selected member did not arrive")
	check("and the one who stayed did NOT come along",
		is_instance_valid(staying) and not WorldManager.context().contains(staying),
		"everyone travelled — the subset was ignored")
	check("they are still standing in the world they were left in",
		is_instance_valid(staying) and staying.get_parent() == home_world)
	check("and both are still counted as party members",
		PartyManager.is_member(going[0]) and PartyManager.is_member(staying))


## Residency is earned, and a companion waiting for you is the plainest
## thing there is to earn it with. Without this the world would be freed
## as unearned and take them with it.
func _the_world_holding_them_cannot_be_freed() -> void:
	check("the world holding the left-behind member stays loaded",
		WorldManager.is_area_resident(HOME),
		"freed — the member waiting in it went with it")
	check("without anyone having pinned it",
		not WorldManager.is_area_pinned(HOME),
		"only pinning kept it, which proves nothing")


## Clicking an absent companion's portrait goes to them (see
## unit_portrait._on_pressed). The claim worth asserting is that this is
## NOT travel: the player's attention moves and nobody else does.
func _going_to_a_companion_moves_nobody() -> void:
	if not is_instance_valid(_stayer) or not is_instance_valid(_traveller):
		check("SETUP: a split party to look across", false)
		return

	var stayer_world: Node = _stayer.get_parent()
	var traveller_world: Node = _traveller.get_parent()

	var went: bool = WorldManager.focus_world_of(_stayer)
	await get_tree().process_frame

	check("the player's attention follows an absent companion", went)
	check("and lands in the world that companion is standing in",
		WorldManager.context() != null and WorldManager.context().contains(_stayer))
	check("nobody was carried along by looking at them",
		_stayer.get_parent() == stayer_world
			and _traveller.get_parent() == traveller_world,
		"attention switching moved the party — that is travel, not looking")
	check("and the world just looked away from is still loaded",
		WorldManager.resident_area_ids().size() == 2,
		"looking away freed it: %s" % str(WorldManager.resident_area_ids()))


## Going somewhere the party cannot be embodied at all (the overworld and
## its single avatar) collects everyone, wherever they were standing —
## roster has no notion of who is where, so it has to be all or nothing.
func _collecting_everyone_again() -> void:
	var split_across: int = WorldManager.resident_area_ids().size()
	check("SETUP: the party really is split across two worlds",
		split_across == 2, "%d resident" % split_across)

	WorldManager.load_area(&"overworld")
	await get_tree().process_frame
	await get_tree().process_frame

	check("a world with no place for units abstracts the whole party away",
		PartyManager.members.is_empty(),
		"%d still embodied" % PartyManager.members.size())
	check("and nobody is lost doing it — they are all in the roster",
		PartyManager.roster.size() >= 2,
		"roster holds %d" % PartyManager.roster.size())
	check("the world that was only being kept for them is gone too",
		not WorldManager.is_area_resident(HOME))


# --- helpers ---------------------------------------------------------

func _living_members() -> Array[Unit]:
	var live: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			live.append(unit)
	return live


func _member_ids() -> Array[int]:
	var ids: Array[int] = []
	for unit in _living_members():
		ids.append(unit.get_instance_id())
	ids.sort()
	return ids


func _all_members_in(context: WorldContext) -> bool:
	if context == null:
		return false
	for unit in _living_members():
		if not context.contains(unit):
			return false
	return true


func _restore_host() -> void:
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()

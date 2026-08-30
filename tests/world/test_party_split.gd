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
	await _the_overworld_takes_only_the_travellers()
	await _two_groups_stand_on_the_overworld()
	await _the_whole_party_stays_reachable()

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


## Going somewhere the party cannot be embodied at all (the overworld
## and its avatar) folds the TRAVELLING GROUP down to records - and
## only that group.
##
## An earlier pass collected everyone here, which is what made the
## split unreachable in the actual game: every route in this game runs
## through the overworld, so every route reunited the party. This suite
## asserted that rule, which is why it passed while the feature did not
## work.
func _the_overworld_takes_only_the_travellers() -> void:
	var split_across: int = WorldManager.resident_area_ids().size()
	check("SETUP: the party really is split across two worlds",
		split_across == 2, "%d resident" % split_across)
	if not is_instance_valid(_stayer) or not is_instance_valid(_traveller):
		check("SETUP: both halves still alive", false)
		return

	# The player is standing with _stayer (see the previous case), so
	# they are who travels.
	var stayer_group: PartyGroup = PartyManager.group_of(_stayer)
	var other_group: PartyGroup = PartyManager.group_of(_traveller)
	check("SETUP: the two halves really are different groups",
		stayer_group != null and other_group != null and stayer_group != other_group)

	WorldManager.load_area(&"overworld")
	await get_tree().process_frame
	await get_tree().process_frame

	check("the group that travelled is folded down to records",
		stayer_group != null and not stayer_group.embodied
			and not stayer_group.records.is_empty(),
		"the travellers did not abstract")
	check("and the group that did NOT travel is still standing where it was",
		other_group != null and other_group.embodied
			and is_instance_valid(_traveller),
		"the overworld reached into another world and collected them")
	check("so the world holding them is still loaded",
		WorldManager.is_area_resident(AWAY),
		"freed - the member waiting in it went with it")
	check("and nobody was lost: everyone is in a group somewhere",
		PartyManager.members.size() + PartyManager.roster.size() >= 2)

## The overworld draws one avatar PER GROUP standing in it. This is what
## makes a split party representable at all: with a single avatar there
## was nothing a second group could be, which is why travelling there
## used to collect everyone.
##
## Worth asserting headlessly even though the real gate is visual — the
## first version of sync_avatars threw on a typed-array assignment and
## built no avatars whatsoever, and every check in this suite still
## passed.
func _two_groups_stand_on_the_overworld() -> void:
	if not is_instance_valid(_traveller):
		check("SETUP: the other half is still alive", false)
		return

	# One group is already abstract on the overworld; bring the other one
	# out to join it, so there are genuinely two.
	if not WorldManager.focus_world_of(_traveller):
		check("SETUP: could reach the other group", false)
		return
	await get_tree().process_frame
	WorldManager.load_area(&"overworld")
	await get_tree().process_frame
	await get_tree().process_frame

	var overworld: Node = WorldManager.current_world()
	var avatars: Array[Node] = []
	if overworld:
		for child in overworld.get_children():
			if child is OverworldAvatar:
				avatars.append(child)

	check("the overworld draws one avatar per group standing in it",
		avatars.size() == 2, "%d avatar(s) for 2 groups" % avatars.size())

	var active_count: int = 0
	var groups_seen: Array[PartyGroup] = []
	for avatar in avatars:
		if avatar.active:
			active_count += 1
			check("the driveable avatar is the group the player is commanding",
				avatar.group == PartyManager.active_group)
		if avatar.group and not groups_seen.has(avatar.group):
			groups_seen.append(avatar.group)

	# Two avatars reading the same WASD is the failure mode here, and it
	# looks like the party walking in lockstep while claiming to be apart.
	check("exactly one of them takes input",
		active_count == 1, "%d avatars are active" % active_count)
	check("and they stand for different groups",
		groups_seen.size() == avatars.size())
	check("two groups on the overworld do NOT merge",
		PartyManager.groups_in_area(&"overworld").size() == 2,
		"merged into %d" % PartyManager.groups_in_area(&"overworld").size())


## Nobody vanishes from the party just because they are somewhere the
## player is not, and there is always a way back to them.
##
## Both halves of this shipped broken. The party panel listed live Units
## only, so a split party showed NOTHING — a group left behind produces
## no member_added (it was never removed) and the fall-back that drew
## records only ran when nobody at all was embodied. With no rows there
## was nothing to click, and so no way back to the half left behind.
func _the_whole_party_stays_reachable() -> void:
	# Reunite first, so this case does not inherit whatever shape the
	# previous one left the party in. Each group is commanded in turn and
	# walked to the same area, where arriving merges them.
	for group in PartyManager.groups.duplicate():
		if WorldManager.focus_group(group):
			WorldManager.load_area(HOME)
			await get_tree().process_frame
	await get_tree().process_frame

	var everyone: Array = PartyManager.everyone()
	check("SETUP: a party to lose track of", everyone.size() >= 2,
		"%d member(s)" % everyone.size())
	if everyone.size() < 2:
		return

	var live: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			live.append(unit)
	if live.size() < 2:
		check("SETUP: two embodied members to split", false)
		return

	var going: Array[Unit] = [live[0]]
	var left_behind: Unit = live[1]
	WorldManager.load_area(&"overworld", &"", going)
	await get_tree().process_frame
	await get_tree().process_frame

	var after: Array = PartyManager.everyone()
	check("a split party still accounts for everybody",
		after.size() == everyone.size(),
		"%d before, %d after" % [everyone.size(), after.size()])

	# The panel rendered from members alone, which is exactly the half
	# that is empty in the direction that broke.
	var has_record: bool = false
	var has_unit: bool = false
	for entry in after:
		if entry is Unit:
			has_unit = true
		else:
			has_record = true
	check("and reports BOTH forms, not just the embodied half",
		has_unit and has_record,
		"units=%s records=%s" % [has_unit, has_record])

	# The way back to an abstract group: it has no Unit anywhere, so
	# nothing in the world can be clicked to reach it.
	var abstract_group: PartyGroup = null
	for group in PartyManager.groups:
		if not group.embodied and not group.records.is_empty():
			abstract_group = group
			break
	check("the travelling group really did abstract", abstract_group != null)

	check("and the one left behind is still embodied where it was",
		is_instance_valid(left_behind) and PartyManager.is_member(left_behind))

	if is_instance_valid(left_behind):
		var back: bool = WorldManager.focus_group(PartyManager.group_of(left_behind))
		await get_tree().process_frame
		check("a group can be reached by group alone, with no node to click",
			back and WorldManager.context() != null
				and WorldManager.context().contains(left_behind),
			"no route back to the half left behind")


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

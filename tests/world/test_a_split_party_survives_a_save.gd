extends AiTestCase
## A party split between an ordinary world and the overworld comes back
## from a save split the same way.
##
## Reported from play: with one group embodied in an ordinary area and
## another abstract on the overworld, saving in the ordinary area and
## loading it again can send the wrong group to the overworld.
##
## This intersection was untested. test_party_split covers splitting and
## the overworld thoroughly and never saves; test_load_restores_every_area
## covers a real save across two areas and never touches the overworld.
## Both pass, and neither one of them can see this.
##
## The overworld is not just another area for this purpose. It is the one
## world with spawns_party() -> false, so arriving there FOLDS a group down
## to records instead of spawning Units — which means the group's location
## stops being derivable from a live member and falls back to
## abstract_area_id. Two groups whose remembered ids collide are then
## indistinguishable to _group_claiming(), which returns the first match.

const HOME := &"test_arena"
const OVERWORLD := &"overworld"
## Somewhere the arrival point is not, so "restored" cannot be mistaken for
## "spawned at the door".
const MARKER := Vector3(18.0, 0.0, -14.0)

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _overview: Node = null
var _snapshot: Dictionary = {}
var _save_path: String = ""


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return
	_snapshot_globals()
	_install_party_overview()

	PartyManager.clear_members()
	PartyManager.load_state({})

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var party: Array[Unit] = _live_members()
	if party.size() < 2:
		check("SETUP: a party big enough to split", false, "%d member(s)" % party.size())
		_restore()
		return

	var traveller: Unit = party[0]
	var stayer: Unit = party[1]
	var traveller_id: StringName = traveller.persistent_id
	var stayer_id: StringName = stayer.persistent_id

	# One member walks out to the overworld. They fold down to records
	# there; the other stays embodied in HOME.
	var going: Array[Unit] = [traveller]
	WorldManager.load_area(OVERWORLD, &"", going)
	await get_tree().process_frame
	await get_tree().process_frame

	# Back to the ordinary world, so THAT is what the save is taken in.
	WorldManager.reveal(stayer, PartyManager.group_of(stayer))
	await get_tree().process_frame

	var area: AreaDefinition = WorldManager.current_area()
	if area == null or area.id != HOME:
		check("SETUP: the save is taken in the ordinary world", false,
			"focused on %s" % ("nothing" if area == null else String(area.id)))
		_restore()
		return

	check("SETUP: the party really is split across two worlds",
		_area_holding(traveller_id) == OVERWORLD and _area_holding(stayer_id) == HOME,
		"before saving: traveller in '%s', stayer in '%s'" % [
			_area_holding(traveller_id), _area_holding(stayer_id)])

	if not SaveManager.save("split across the overworld"):
		check("SETUP: the save was written", false)
		_restore()
		return
	var saves: Array[Dictionary] = SaveManager.list_saves()
	if saves.is_empty():
		check("SETUP: the save can be found again", false)
		_restore()
		return
	_save_path = saves[0]["path"]

	if not SaveManager.load_file(_save_path):
		check("SETUP: the save loads", false)
		_restore()
		return
	await get_tree().process_frame
	await get_tree().process_frame

	# --- the actual question -----------------------------------------
	check("the party comes back as two groups, not one",
		PartyManager.groups.size() == 2,
		"%d group(s) — %s" % [PartyManager.groups.size(), _describe_groups()])

	check("the one who stayed is still in the ordinary world",
		_area_holding(stayer_id) == HOME,
		"they are in '%s' — %s" % [_area_holding(stayer_id), _describe_groups()])

	check("and the one on the overworld is still on the overworld",
		_area_holding(traveller_id) == OVERWORLD,
		"they are in '%s' — %s" % [_area_holding(traveller_id), _describe_groups()])

	check("and the two are still in different groups",
		_group_holding(stayer_id) != _group_holding(traveller_id)
			and _group_holding(stayer_id) != null,
		"they were merged — %s" % _describe_groups())

	await _and_again_when_the_save_is_taken_on_the_overworld(stayer_id, traveller_id)
	_restore()


## The same split, saved from the OTHER side.
##
## This is the variant that exercises the avatar-transform path at all.
## SaveManager._capture_avatar_transform() only returns a value when the
## FOCUSED world has get_avatar(), so a save taken in an ordinary area
## writes none and _on_world_loaded's avatar branch never runs. Saving on
## the overworld is what arms it.
##
## And what it arms is a SINGLE transform, captured from
## get_avatar() — which is _active_avatar(), one group's — then applied on
## load to get_avatar() again, meaning whichever group happens to be active
## when the overworld's world_loaded fires. Those are two different
## questions with the same name.
func _and_again_when_the_save_is_taken_on_the_overworld(
		stayer_id: StringName, traveller_id: StringName) -> void:
	if _save_path != "":
		DirAccess.remove_absolute(_save_path)
		_save_path = ""

	# LOOK at the overworld group, do not travel to it. load_area() with no
	# travellers resolves to "everyone embodied in the focused world", so it
	# would take the ordinary-world group along and there would be nothing
	# split left to test.
	var away: PartyGroup = _group_holding(traveller_id)
	if away == null or not WorldManager.focus_group(away):
		check("SETUP: could look at the overworld group without moving anyone", false)
		return
	await get_tree().process_frame
	await get_tree().process_frame

	var area: AreaDefinition = WorldManager.current_area()
	if area == null or area.id != OVERWORLD:
		check("SETUP: the second save is taken on the overworld", false,
			"focused on %s" % ("nothing" if area == null else String(area.id)))
		return

	# Walk the overworld group somewhere distinctive, through the avatar,
	# so the live write-back is part of what is under test rather than a
	# value poked straight into the group.
	var away_avatar: Node3D = _avatar_for(away)
	if away_avatar == null:
		check("SETUP: the overworld group has an avatar to move", false)
		return
	away_avatar.global_position = MARKER
	await get_tree().physics_frame
	await get_tree().physics_frame

	check("SETUP: walking the avatar records the group's position",
		away.overworld_position.distance_to(MARKER) < 1.0,
		"group remembers %s, avatar is at %s" % [
			str(away.overworld_position), str(away_avatar.global_position)])

	var before: String = _describe_groups()

	if not SaveManager.save("split, saved from the overworld"):
		check("SETUP: the overworld save was written", false)
		return
	var saves: Array[Dictionary] = SaveManager.list_saves()
	if saves.is_empty():
		check("SETUP: the overworld save can be found again", false)
		return
	_save_path = saves[0]["path"]

	if not SaveManager.load_file(_save_path):
		check("SETUP: the overworld save loads", false)
		return
	await get_tree().process_frame
	await get_tree().process_frame

	check("saved from the overworld, the ordinary-world group stays put",
		_area_holding(stayer_id) == HOME,
		"they are in '%s'
          before: %s
          after:  %s" % [
			_area_holding(stayer_id), before, _describe_groups()])
	check("and the overworld group stays on the overworld",
		_area_holding(traveller_id) == OVERWORLD,
		"they are in '%s' — %s" % [_area_holding(traveller_id), _describe_groups()])
	check("and they are still two groups",
		_group_holding(stayer_id) != _group_holding(traveller_id)
			and _group_holding(stayer_id) != null,
		_describe_groups())

	# The property the deleted global avatar_transform was trying to serve.
	# PartyGroup.overworld_position already carries it PER GROUP — written
	# live by the avatar, saved and restored per group — so the single
	# world/avatar_transform record was a second copy of one fact, captured
	# from whichever group was active and reapplied to whichever group was
	# active on load. Removing it is only safe if this holds.
	var restored: PartyGroup = _group_holding(traveller_id)
	check("and the overworld group is standing where it was left",
		restored != null and restored.overworld_position.distance_to(MARKER) < 1.0,
		"remembers %s, was left at %s" % [
			"nothing" if restored == null else str(restored.overworld_position),
			str(MARKER)])

	var rebuilt: Node3D = _avatar_for(restored)
	check("and its avatar was rebuilt there, not at the door",
		rebuilt != null and rebuilt.global_position.distance_to(MARKER) < 1.5,
		"avatar %s" % ("missing" if rebuilt == null else str(rebuilt.global_position)))


## Which area a member is in, by id, whichever form their group is in.
func _area_holding(id: StringName) -> StringName:
	var group: PartyGroup = _group_holding(id)
	return group.current_area_id() if group else &"<nowhere>"


func _group_holding(id: StringName) -> PartyGroup:
	for group in PartyManager.groups:
		for unit in group.units:
			if is_instance_valid(unit) and unit.persistent_id == id:
				return group
		for record in group.records:
			if record.id == id:
				return group
	return null


## Every group, what it thinks its area is, and who is in it — so a
## failure says what actually happened rather than only that it did.
func _describe_groups() -> String:
	var parts: Array[String] = []
	for i in PartyManager.groups.size():
		var g: PartyGroup = PartyManager.groups[i]
		var who: Array[String] = []
		for unit in g.live_units():
			who.append(unit.get_display_name())
		for record in g.records:
			who.append(record.display_name)
		parts.append("group %d: area '%s' embodied=%s abstract='%s' [%s]" % [
			i, g.current_area_id(), g.embodied, g.abstract_area_id, ", ".join(who)])
	return " | ".join(parts)


## The overworld's avatar for a group, found by asking the avatars
## themselves rather than reaching into the world's private table.
func _avatar_for(group: PartyGroup) -> Node3D:
	var world: Node = WorldManager.current_world()
	if world == null or group == null:
		return null
	for child in world.get_children():
		if child is OverworldAvatar and (child as OverworldAvatar).group == group:
			return child
	return null


func _live_members() -> Array[Unit]:
	var live: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			live.append(unit)
	return live


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


func _install_party_overview() -> void:
	_overview = preload("res://ui/party_overview.tscn").instantiate()
	_root.add_child(_overview)


func _snapshot_globals() -> void:
	_snapshot = {
		"flags": FlagManager.save_state(),
		"party": PartyManager.save_state(),
		"demons": DemonRoster.save_state(),
		"currency": CurrencyManager.save_state(),
	}


func _restore() -> void:
	if _save_path != "":
		DirAccess.remove_absolute(_save_path)
	WorldManager.discard_worlds()
	if not _snapshot.is_empty():
		FlagManager.load_state(_snapshot["flags"])
		PartyManager.load_state(_snapshot["party"])
		DemonRoster.load_state(_snapshot["demons"])
		CurrencyManager.load_state(_snapshot["currency"])
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_overview):
		_overview.queue_free()
	if is_instance_valid(_host):
		_host.queue_free()

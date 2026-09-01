extends AiTestCase
## Worlds outlive the player's attention.
##
## Before this, leaving an area meant freeing it: WorldManager was
## replace-only, so everything the world knew died with it and the only
## thing that survived was whatever AreaState had been told to persist.
## Residency splits "the player left" from "the world ended".
##
## The centrepiece is INSTANCE IDENTITY. A rebuilt world and a re-entered
## one look identical from the outside — same area, same layout, same
## authored content — so every assertion that isn't identity would pass
## against the old replace-only behaviour too. Comparing the actual object
## is the only thing that distinguishes them.
##
## Drives the real load_area path, with a synthetic host standing in for
## MainRoot's WorldHost the way tests/world/test_world_hosting.gd does.

const HOME := &"test_arena"
const AWAY := &"test_area_2"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false, "WorldManager refused")
		return

	await _an_unearned_world_is_retired()
	await _a_pinned_world_is_re_entered_not_rebuilt()
	await _the_party_does_not_double_up()
	await _unload_takes_everything()

	_restore_host()


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


## Residency is EARNED, not budgeted. A world with nothing running in it
## costs more to keep than to rebuild, and AreaState already carries what
## outlives a reload — so the default has to be that it goes.
func _an_unearned_world_is_retired() -> void:
	WorldManager.load_area(HOME)
	await get_tree().process_frame
	check("the first area loads and is resident",
		WorldManager.is_area_resident(HOME))

	WorldManager.load_area(AWAY)
	await get_tree().process_frame
	check("moving on retires a world with nothing left to preserve",
		not WorldManager.is_area_resident(HOME),
		"still resident: %s" % str(WorldManager.resident_area_ids()))
	check("and the destination is the resident one",
		WorldManager.is_area_resident(AWAY)
			and WorldManager.current_area().id == AWAY)


## THE claim. Everything else in this suite would pass against the old
## replace-only WorldManager; this is the assertion that cannot.
func _a_pinned_world_is_re_entered_not_rebuilt() -> void:
	var home: Node = WorldManager.load_area(HOME)
	await get_tree().process_frame
	if home == null:
		check("SETUP: home area loaded", false)
		return

	var home_id: int = home.get_instance_id()
	WorldManager.set_area_pinned(HOME, true)

	WorldManager.load_area(AWAY)
	await get_tree().process_frame
	check("a pinned world survives the player leaving it",
		WorldManager.is_area_resident(HOME),
		"retired despite being pinned")
	check("even though the player is somewhere else entirely",
		WorldManager.current_area().id == AWAY)
	check("and it is still in the tree, still able to run",
		is_instance_valid(home) and home.is_inside_tree(),
		"the world was freed out from under the residency record")

	var returned: Node = WorldManager.load_area(HOME)
	await get_tree().process_frame
	check("coming back gives the SAME world, not a fresh copy of it",
		returned != null and returned.get_instance_id() == home_id,
		"rebuilt — everything that was running in it was lost")
	check("and the player is looking at it again",
		WorldManager.current_area().id == HOME
			and WorldManager.focused_viewport() == returned.get_parent())

	WorldManager.set_area_pinned(HOME, false)


## Travelling must not multiply the party. Before splitting this was
## guaranteed by force — the whole world was freed — and now that a world
## can outlive the player, a member left standing in it while a copy is
## rebuilt somewhere else is a live possibility.
func _the_party_does_not_double_up() -> void:
	WorldManager.load_area(HOME)
	await get_tree().process_frame
	var before: int = _party_units_everywhere()

	WorldManager.set_area_pinned(HOME, true)
	WorldManager.load_area(AWAY)
	await get_tree().process_frame
	check("travelling out does not multiply the party",
		_party_units_everywhere() == before,
		"%d before, %d after" % [before, _party_units_everywhere()])

	WorldManager.load_area(HOME)
	await get_tree().process_frame
	check("and neither does coming back to a world that stayed loaded",
		_party_units_everywhere() == before,
		"%d before, %d after" % [before, _party_units_everywhere()])
	check("everyone the manager thinks is live really is",
		_all_members_valid(), "PartyManager.members holds a freed unit")

	WorldManager.set_area_pinned(HOME, false)


## Across every resident world, not just the focused one — the whole point
## is that a copy could be hiding in the world nobody is looking at.
func _party_units_everywhere() -> int:
	var count: int = 0
	for unit in UnitQuery.all_units(get_tree()):
		if is_instance_valid(unit) and unit.is_player_controlled():
			count += 1
	return count


func _all_members_valid() -> bool:
	for unit in PartyManager.members:
		if not is_instance_valid(unit):
			return false
	return true


## unload() means "nothing is loaded", not "nothing is focused" —
## SaveManager is about to replace the entire game state, and a fight
## running in another area is part of what it replaces.
func _unload_takes_everything() -> void:
	WorldManager.load_area(HOME)
	WorldManager.set_area_pinned(HOME, true)
	WorldManager.load_area(AWAY)
	await get_tree().process_frame
	check("SETUP: two areas resident at once",
		WorldManager.resident_area_ids().size() == 2,
		"got %s" % str(WorldManager.resident_area_ids()))

	WorldManager.unload()
	await get_tree().process_frame
	await get_tree().process_frame
	check("unload frees every resident world, pinned or not",
		WorldManager.resident_area_ids().is_empty(),
		"survived: %s" % str(WorldManager.resident_area_ids()))
	check("and nothing is focused afterwards",
		WorldManager.current_world() == null
			and WorldManager.focused_viewport() == null)


func _restore_host() -> void:
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()

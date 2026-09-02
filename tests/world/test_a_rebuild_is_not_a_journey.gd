extends AiTestCase
## A rebuilt world is not one the player walked into.
##
## WorldManager._enter_world serves two operations — travel and restore —
## and they differ on more than they look like they do. Three of those
## differences have now been found, each one as a play report rather than
## as a failure here: which permission question to ask, who is coming
## along, and this one, where those people land.
##
## The arrival point is derived. Given no explicit spawn point,
## _resolve_entry_spawn_point looks at the area being LEFT and finds the
## door in the destination that leads back to it — which is exactly right
## for walking through a doorway, and meaningless during a restore, where
## "the area being left" is whichever area the load loop happened to
## rebuild last. The overworld authors DoorA with target_area =
## "test_arena", so a rebuild of the overworld taken while the arena was
## focused resolved to that door purely because of iteration order.
##
## It was latent rather than visible: saved positions are applied over the
## top afterwards, so the wrong door usually gets overwritten. A group
## with no remembered position — one that has never stood on the
## overworld — has nothing to overwrite it with, and lands at a doorway
## chosen by loop order.
##
## THE PAIR IS THE POINT. Asserting only that a rebuild lands at "default"
## would pass just as well if back-links were broken outright, so the
## travel case is asserted alongside it. What is under test is that the
## derivation is CONDITIONAL on why the world is being entered, not that
## it is gone.

const HOME := &"test_arena"
const OVERWORLD := &"overworld"
## What the overworld authors as its way back to HOME (see its
## SpawnPoints/DoorA, target_area = "test_arena"). Travel must resolve to
## this; a rebuild must not.
const BACK_LINK := &"DoorA"
## Where a world with no doorway to arrive through puts people instead.
const FALLBACK := &"default"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _snapshot: Dictionary = {}
## Every reason, in the order the worlds were built.
var _seen: Array = []


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return
	_snapshot_globals()
	WorldManager.world_loaded.connect(_note_reason)

	PartyManager.clear_members()
	PartyManager.load_state({})

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	# --- travel: the derivation still happens --------------------------
	WorldManager.load_area(OVERWORLD)
	await get_tree().process_frame
	check("walking to the overworld arrives through its door back to the arena",
		WorldManager.pending_spawn_point_name() == BACK_LINK,
		"arrived at '%s', expected '%s' — if this is '%s' the back-link " % [
			WorldManager.pending_spawn_point_name(), BACK_LINK, FALLBACK] +
		"derivation has been disabled rather than made conditional")

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var area: AreaDefinition = WorldManager.current_area()
	if area == null or area.id != HOME:
		check("SETUP: back in the arena, so a rebuild has an origin to be wrong about", false,
			"focused on %s" % ("nothing" if area == null else String(area.id)))
		_restore()
		return

	# --- restore: the same derivation must not happen ------------------
	# Nobody is claiming it: `null` is a real answer, and it keeps this
	# about the arrival point rather than about who arrives.
	WorldManager.rebuild_area(OVERWORLD, null)
	await get_tree().process_frame

	check("but rebuilding the overworld out of a save does not go through that door",
		WorldManager.pending_spawn_point_name() == FALLBACK,
		"arrived at '%s', expected '%s'. '%s' means the rebuild derived an " % [
			WorldManager.pending_spawn_point_name(), FALLBACK, BACK_LINK] +
		"entry point from whatever area was focused when the loop reached " +
		"it — an ordering artefact, not a journey anyone made")

	check("and every world built says which operation built it",
		not _seen.is_empty()
			and _seen[-1] == WorldManager.Entry.REBUILD
			and not _seen.slice(0, _seen.size() - 1).has(WorldManager.Entry.REBUILD),
		"reasons in build order: %s (TRAVEL=%d, REBUILD=%d) — a rebuild " % [
			str(_seen), WorldManager.Entry.TRAVEL, WorldManager.Entry.REBUILD] +
		"reported as travel is how all three of these bugs got in")

	_restore()


func _note_reason(_world: Node, reason: WorldManager.Entry) -> void:
	_seen.append(reason)


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


func _snapshot_globals() -> void:
	_snapshot = {
		"flags": FlagManager.save_state(),
		"party": PartyManager.save_state(),
		"demons": DemonRoster.save_state(),
		"currency": CurrencyManager.save_state(),
	}


func _restore() -> void:
	if WorldManager.world_loaded.is_connected(_note_reason):
		WorldManager.world_loaded.disconnect(_note_reason)
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
	if is_instance_valid(_host):
		_host.queue_free()

class_name AreaState
extends RefCounted
## Per-area persistent state — the diff against authored content that
## survives leaving and re-entering an area. Static, no autoload, same
## shape as AreaDatabase itself.
##
## Backed by FlagManager under a reserved "areastate/" prefix rather than
## a parallel store — FlagManager is already the project's de facto
## global flag dictionary and already survives area transitions; this
## file adds STRUCTURE on top of it (a keying convention and two clearly
## separated concerns), not a second storage mechanism.
##
## Two axes, deliberately kept separate — conflating them is exactly how
## a container silently refills:
## - EXISTENCE (mark_removed/is_removed): this entity should not exist
##   at all. A defeated goblin has no state to restore; it must simply
##   never enter the tree.
## - STATE (store_state/stored_state): this entity exists, but its
##   contents differ from its authored placeholder. Opaque to this file
##   — only the object that produced it (via save_state(), see
##   WorldManager's reconciliation pass) interprets it.
##
## stored_state() returning null vs. an empty Dictionary is load-bearing:
## null means "never recorded, use authored contents"; an empty items
## list means "recorded, and it's empty" (the player took everything).
## Collapsing those two is precisely the bug this file exists to fix,
## reintroduced from the other direction.
##
## Entities are addressed by (area_id, entity_id) where entity_id comes
## from Unit.persistent_id / InteractableProp.persistent_id — an
## authored StringName, never a node path or instance identity, per the
## project's own "save data never depends on runtime node identity"
## invariant (see world_manager.gd's own invariants).

const _PREFIX: String = "areastate/"


static func mark_removed(area_id: StringName, entity_id: StringName) -> void:
	FlagManager.set_flag(_removed_key(area_id, entity_id), true)


static func is_removed(area_id: StringName, entity_id: StringName) -> bool:
	return FlagManager.get_flag(_removed_key(area_id, entity_id), false)


## state must not be empty — an empty Dictionary is the save_state()
## convention for "nothing worth recording" (see StashComponent's own
## header), so storing one here would be indistinguishable from never
## having called this at all. Callers that want to explicitly record
## "recorded and empty" (a looted-clean container) should pass a
## Dictionary with an empty inner list, e.g. {"items": []}.
static func store_state(area_id: StringName, entity_id: StringName, state: Dictionary) -> void:
	FlagManager.set_flag(_state_key(area_id, entity_id), state)


## null if this entity has never had state recorded — see this file's
## own header on why that must stay distinguishable from a recorded-but-
## empty state.
static func stored_state(area_id: StringName, entity_id: StringName) -> Variant:
	if not FlagManager.has_flag(_state_key(area_id, entity_id)):
		return null
	return FlagManager.get_flag(_state_key(area_id, entity_id))


## Clears every recorded fact for one area — debug reset, New Game+, a
## plot event that restores a place. Enumerable as a unit precisely
## because every key here carries the "areastate/<area_id>/" prefix;
## this is the payoff of routing everything through this file instead of
## letting callers touch FlagManager directly with ad hoc key names.
static func clear_area(area_id: StringName) -> void:
	var area_prefix: String = "%s%s/" % [_PREFIX, area_id]
	for flag_name in FlagManager.get_flag_names_with_prefix(area_prefix):
		FlagManager.clear_flag(flag_name)


static func _removed_key(area_id: StringName, entity_id: StringName) -> String:
	return "%s%s/%s/removed" % [_PREFIX, area_id, entity_id]


static func _state_key(area_id: StringName, entity_id: StringName) -> String:
	return "%s%s/%s/state" % [_PREFIX, area_id, entity_id]

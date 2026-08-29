extends Node
## Autoload singleton. Register as "StashManager" under
## Project > Project Settings > AutoLoad.
##
## Tracks which StashComponent (if any) is currently being looted —
## typed to the component, not to whatever owns it, so this has no idea
## whether the thing being looted is a chest, a corpse, or anything
## else (see stash_component.gd). Deliberately dumb about PRESENTATION,
## same split as DialogueManager/dialogue_overlay: stash_panel.gd just
## listens to the signals below and does the actual reparenting of
## Inventory nodes — this file never touches a Control.

signal stash_opened(stash: StashComponent, actor: Unit)
signal stash_closed()

var current_stash: StashComponent = null


func is_active() -> bool:
	return current_stash != null


## Mutually exclusive with a conversation — see DialogueManager.start_dialogue's
## matching StashManager.is_active() guard — and with another stash already
## open, since the reparent-based transfer only ever has one "loot UI" to
## reparent into.
func open_stash(stash: StashComponent, actor: Unit) -> void:
	if not stash or DialogueManager.is_active() or is_active():
		return
	current_stash = stash
	GameMode.push_mode(GameMode.Mode.LOOTING)
	stash_opened.emit(stash, actor)


func close_stash() -> void:
	# Captured before current_stash is cleared below — closing is the
	# right moment to persist (see StashComponent.save_state()'s own
	# header): the panel's reparent-based transfer means contents are
	# only settled once it closes, not while items are mid-drag.
	var closing_stash: StashComponent = current_stash

	current_stash = null
	GameMode.pop_mode()
	stash_closed.emit()

	_persist_stash_state(closing_stash)


## The owning persistent node is always this component's direct parent
## — same structural convention StashComponent.find_on() itself relies
## on, just walked in reverse. Silently no-ops for a stash whose owner
## has no persistent_id (not everything lootable needs to be area-state-
## tracked) or that has no current area (WorldManager.current_area() is
## null outside a loaded area).
func _persist_stash_state(stash: StashComponent) -> void:
	if not is_instance_valid(stash):
		return

	var owner_node: Node = stash.get_parent()
	if not owner_node or owner_node.get("persistent_id") == null or owner_node.persistent_id == &"":
		return

	var area: AreaDefinition = WorldManager.current_area()
	if not area:
		return

	AreaState.store_state(area.id, owner_node.persistent_id, stash.save_state())

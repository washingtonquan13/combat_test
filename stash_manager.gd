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
	current_stash = null
	GameMode.pop_mode()
	stash_closed.emit()

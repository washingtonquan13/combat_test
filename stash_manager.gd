extends Node
## Autoload singleton. Register as "StashManager" under
## Project > Project Settings > AutoLoad.
##
## Tracks which Chest (if any) is currently being looted. Deliberately
## dumb about PRESENTATION, same split as DialogueManager/dialogue_overlay:
## stash_panel.gd just listens to the signals below and does the actual
## reparenting of Inventory nodes — this file never touches a Control.

signal stash_opened(chest: Chest, actor: Unit)
signal stash_closed()

var current_chest: Chest = null


func is_active() -> bool:
	return current_chest != null


## Mutually exclusive with a conversation — see DialogueManager.start_dialogue's
## matching StashManager.is_active() guard — and with another chest already
## open, since the reparent-based transfer only ever has one "loot UI" to
## reparent into.
func open_stash(chest: Chest, actor: Unit) -> void:
	if DialogueManager.is_active() or is_active():
		return
	current_chest = chest
	stash_opened.emit(chest, actor)


func close_stash() -> void:
	current_chest = null
	stash_closed.emit()

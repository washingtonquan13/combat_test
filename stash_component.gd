class_name StashComponent
extends Node
## Drop this into ANY scene — a chest, eventually a lootable corpse, a
## barrel, anything, regardless of its own base type — to make that
## thing lootable. LootInteraction/StashManager/StashPanel never check
## for a specific class; they look for a StashComponent child via
## find_on(), so "can this be looted" is a scene-composition question,
## not a class hierarchy one. Same idea as Unit.interactions/
## InteractableProp.interactions composing right-click verbs onto
## whatever needs them — just a child Node instead of a Resource, since
## a stash needs real per-instance mutable state (an Inventory full of
## Items), not authored/shared data.
##
## Inventory starts invisible — it renders in screen space regardless of
## being parented under a 3D node (Control rendering only needs a
## Viewport, not a CanvasItem ancestor), so an always-visible=true
## Inventory sitting under a chest would show up on screen at all times.
## StashPanel is responsible for toggling it back to true/false around
## the reparent in/out (see stash_panel.gd).

@export var display_name: String = "Container"
@onready var inventory: Inventory = $Inventory


## Duck-typing by child presence rather than by the target's class —
## Unit and InteractableProp (or anything else that wants to be
## lootable someday) share no common base below Node, so this can't
## live as a shared method on either of them the way get_interactions()
## couldn't either (see interactable_prop.gd's header for that same
## reasoning). Direct children only, deliberately not recursive — this
## component is always meant to be a direct child of whatever it makes
## lootable, never nested deeper.
static func find_on(node: Node) -> StashComponent:
	for child in node.get_children():
		if child is StashComponent:
			return child
	return null

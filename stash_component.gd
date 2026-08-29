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


## Thin delegation to this stash's own Inventory, which is where the
## contents actually live (see inventory.gd's own save_state()/
## load_state() for the real implementation — moved there so
## SaveManager can reuse the exact same pair for the party's shared
## Inventory instead of a second, parallel implementation). Kept here
## because WorldManager's reconciliation pass duck-types against
## whatever node carries persistent_id (this component's OWNER, e.g. the
## chest — see world_manager.gd's own _reconcile_area_state()), not
## against an Inventory directly.
##
## _get_inventory(), not the @onready `inventory` member — see that
## method's own header on why save_state()/load_state() can't assume
## _ready() has already run.
func save_state() -> Dictionary:
	return _get_inventory().save_state()


func load_state(state: Dictionary) -> void:
	_get_inventory().load_state(state)


## get_node(), not the @onready `inventory` member — that member is only
## guaranteed resolved once THIS node's own _ready() has run, which
## save_state()/load_state() cannot assume: WorldManager's reconciliation
## pass calls load_state() before the world (and therefore this node)
## has entered the tree at all. get_node() works regardless, since it
## walks this node's already-built child structure rather than
## depending on tree-entry timing.
func _get_inventory() -> Inventory:
	return get_node("Inventory") as Inventory


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

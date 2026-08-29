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

const ITEM_SCENE: PackedScene = preload("res://systems/inventory_system/item.tscn")

@export var display_name: String = "Container"
@onready var inventory: Inventory = $Inventory


## Part of the save_state()/load_state() contract WorldManager's
## reconciliation pass duck-types against (see area_state.gd/
## world_manager.gd) — an empty Dictionary means "nothing worth
## recording," so a chest that was never opened is correctly left to
## rebuild from its authored contents instead of being stored as an
## empty state (see AreaState.stored_state()'s own header on why null
## and "recorded empty" must never be conflated).
##
## Grid position round-trips through cell_size_px, the same convention
## request_item_drop()/auto_place_item() already use (see inventory.gd).
## Item identity is ItemDefinition.id, not a direct resource reference —
## the same reason AreaDatabase/ItemDatabase key everything else by id
## rather than by resource path.
func save_state() -> Dictionary:
	var target: Inventory = _get_inventory()
	var item_layer: Node = _get_item_layer(target)
	var items: Array[Dictionary] = []
	for child in item_layer.get_children():
		if child is Item and child.definition:
			var grid_pos: Vector2i = child.position / target.cell_size_px
			items.append({
				"id": child.definition.id,
				"x": grid_pos.x,
				"y": grid_pos.y,
				"stack": child.current_stack_count,
			})
	return {"items": items}


## Rebuilds this stash's contents from a previously-saved state, replacing
## whatever's currently in it (the authored placeholder contents, at the
## point this is ever called — see WorldManager's reconciliation pass,
## which calls this before the world enters the tree, hence _get_inventory()
## below rather than the @onready inventory member: _ready() hasn't
## cascaded yet at that point, so the @onready var is still unset).
func load_state(state: Dictionary) -> void:
	var target: Inventory = _get_inventory()
	var item_layer: Node = _get_item_layer(target)
	# Item children only — item_layer also holds GhostPreview (see
	# inventory.tscn), a structural sibling Inventory's own @onready
	# ghost_preview member caches a reference to. Freeing it here left
	# that reference dangling: the next drag over this SAME Inventory
	# instance (still live — this rebuild never touches the Inventory
	# node itself, only wipes its contents) crashed on the first
	# ghost_preview.size/.visible write in update_ghost_preview()/
	# hide_ghost_preview() (inventory.gd), against an already-freed node.
	for child in item_layer.get_children():
		if child is Item:
			child.queue_free()

	for entry in state.get("items", []):
		var definition: ItemDefinition = ItemDatabase.find(entry.get("id", &""))
		if not definition:
			push_warning("StashComponent.load_state: unknown item id '%s'" % entry.get("id"))
			continue

		var item: Item = ITEM_SCENE.instantiate()
		item.definition = definition
		item.current_stack_count = entry.get("stack", 1)
		item.layout = Item.LayoutMode.GRID
		item_layer.add_child(item)
		item.position = Vector2i(entry.get("x", 0), entry.get("y", 0)) * target.cell_size_px


## get_node(), not the @onready `inventory` member — that member is only
## guaranteed resolved once THIS node's own _ready() has run, which
## save_state()/load_state() cannot assume (see load_state()'s own note).
## get_node() works regardless, since it walks this node's already-built
## child structure rather than depending on tree-entry timing.
func _get_inventory() -> Inventory:
	return get_node("Inventory") as Inventory


## Same reasoning as _get_inventory() above, one level deeper: Inventory's
## OWN item_layer is itself an @onready var (see inventory.gd), unresolved
## until Inventory._ready() has run — which is exactly as untrue in this
## detached window as it is for this component's own inventory member.
## get_node() on the already-built child structure sidesteps that too.
func _get_item_layer(target: Inventory) -> Node:
	return target.get_node("ScrollContainer/ItemLayer")


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

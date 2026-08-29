class_name ItemDefinition
extends Resource
## Mechanical-agnostic definition of one kind of item — what every Item
## instance's `definition` can point at, gear or not. GearItem (see that
## file) extends this to add the mechanical fields (slot_type,
## stat_modifiers, weapon_data) that only equipment needs; a consumable
## or currency item uses this base directly.
##
## `id` is the stable identity AreaState/save data serializes an Item
## instance BY — never a resource path (renaming/reorganizing a .tres
## would silently break saved references) and never a node identity
## (this is authored data, shared across every Item instance pointing at
## it). Resolved back to a real definition via ItemDatabase.find().
##
## Item (inventory_system/item.gd) stays the UI/grid presentation —
## icon, stacking, drag-and-drop; this is the DATA a given Item
## instance's `definition` points at, same "data resource separate from
## the presentation node" split GearItem's own header already
## describes.

@export var id: StringName = &""
@export var item_name: String = "Unnamed Item"
@export var icon: Texture2D
@export var width: int = 1
@export var height: int = 1
@export var maximum_stack_count: int = 99

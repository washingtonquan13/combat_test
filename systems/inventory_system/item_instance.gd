class_name ItemInstance
extends RefCounted
## One copy of an item — the per-copy state that ItemDefinition (shared,
## authored, one per kind of item) can't hold. Today that's only a stack
## count; it's where per-copy rolled state (rarity, affixes, sockets,
## item level, identified) goes when those exist.
##
## RefCounted rather than Resource on purpose: a Resource can be saved
## into a .tres and shared by accident, the same trap
## resource_vs_node_for_mutable_state warns about. Two units can never
## end up wearing the same copy.
##
## Lives in an ItemContainer (a grid) or a UnitEquipment slot. The Item
## Control is only a view of one of these — see item.gd.

signal changed

var definition: ItemDefinition

var count: int = 1:
	set(value):
		count = value
		changed.emit()

## Same name and meaning as Item.gear_data had, so call sites that read
## `.gear_data` (UnitCombat, GearDamageEffect, PartyManager) read an
## instance exactly the way they read a widget.
var gear_data: GearItem:
	get: return definition as GearItem


func _init(item_definition: ItemDefinition = null, stack: int = 1) -> void:
	definition = item_definition
	count = stack


func size() -> Vector2i:
	if not definition:
		return Vector2i.ONE
	return Vector2i(definition.width, definition.height)

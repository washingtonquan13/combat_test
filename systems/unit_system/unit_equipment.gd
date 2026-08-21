class_name UnitEquipment
extends RefCounted
## Owns which Item is equipped in which of this unit's EquipSlots — the
## per-unit storage that lets the SAME 16 EquipSlot nodes in
## party_overview.tscn show a different loadout depending on which
## unit's sheet is open (see party_overview.gd's open_for(), which
## reparents items in/out of storage exactly the way stash_panel.gd
## already does for a chest's Inventory).
##
## Keyed by EquipSlot.Slot — a real, typed per-slot identity distinct
## from GearItem.SlotType (which only answers "what kind of item fits
## here," not "which specific slot is this"; SlotType.RING alone can't
## tell the two ring slots apart, which is exactly why Slot exists).
## Previously keyed by the EquipSlot node's own scene-tree name, which
## broke silently the moment any of the 16 slot nodes got renamed in
## the editor — a typed enum key can't drift out of sync with the scene
## the way a hand-matched string could.
##
## Takes owner: Unit because equip()/unequip() call back into
## register_stat_modifier()/unregister_stat_modifier() — same
## composition shape as UnitCombat/UnitMovement, unlike UnitStatModifiers
## (which never needs to reach into Unit at all).

var _owner: Unit
var _equipped: Dictionary = {}  # EquipSlot.Slot -> Item


func _init(owner: Unit) -> void:
	_owner = owner


func get_item(slot_key: EquipSlot.Slot) -> Item:
	return _equipped.get(slot_key)


## Records item as equipped in slot_key and registers every stat
## modifier its GearItem grants — does NOT touch the scene tree (no
## reparenting here); that's EquipSlot's job, this is just the per-unit
## bookkeeping of what's currently worn.
func equip(slot_key: EquipSlot.Slot, item: Item) -> void:
	_equipped[slot_key] = item
	if item.gear_data:
		for modifier in item.gear_data.stat_modifiers:
			_owner.register_stat_modifier(modifier, item.gear_data.item_name)


## Clears slot_key and reverts every stat modifier the previously-equipped
## item was granting. Returns the item that was there (or null), so the
## caller can decide where it goes next (back to a slot's item_layer, the
## party stash, ...).
func unequip(slot_key: EquipSlot.Slot) -> Item:
	var item: Item = _equipped.get(slot_key)
	if item and item.gear_data:
		for modifier in item.gear_data.stat_modifiers:
			_owner.unregister_stat_modifier(modifier)
	_equipped.erase(slot_key)
	return item

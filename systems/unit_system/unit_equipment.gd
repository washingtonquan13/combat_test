class_name UnitEquipment
extends RefCounted
## Owns which ItemInstance is equipped in which of this unit's EquipSlots — the
## per-unit storage that lets the SAME 16 EquipSlot nodes in
## party_overview.tscn show a different loadout depending on which
## unit's sheet is open (see party_overview.gd's open_for(), which
## rebuilds the slots' widgets from whichever unit is shown).
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
## composition shape as UnitCombat/UnitMovement, unlike UnitStats
## (which never needs to reach into Unit at all).

var _owner: Unit
var _equipped: Dictionary = {}  # EquipSlot.Slot -> ItemInstance


func _init(owner: Unit) -> void:
	_owner = owner


func get_item(slot_key: EquipSlot.Slot) -> ItemInstance:
	return _equipped.get(slot_key)


## Each hand slot's partner, main -> off.
const OFF_HAND_OF: Dictionary = {
	EquipSlot.Slot.MELEE_MAIN_HAND: EquipSlot.Slot.MELEE_OFF_HAND,
	EquipSlot.Slot.RANGED_MAIN_HAND: EquipSlot.Slot.RANGED_OFF_HAND,
}


## Whether item can go in slot_key given what the other hand holds: a
## two-handed weapon needs the off hand empty, and while one is held
## the off hand takes nothing. Refuses rather than moving the other
## hand's item, so nothing ever leaves a slot the player didn't touch.
func hands_allow(slot_key: EquipSlot.Slot, item: ItemInstance) -> bool:
	for main in OFF_HAND_OF:
		if OFF_HAND_OF[main] == slot_key:
			return not is_two_handed(get_item(main))
	if OFF_HAND_OF.has(slot_key) and is_two_handed(item):
		return get_item(OFF_HAND_OF[slot_key]) == null
	return true


static func is_two_handed(item: ItemInstance) -> bool:
	return item != null and item.gear_data != null and item.gear_data.weapon_data != null 		and item.gear_data.weapon_data.two_handed


## Every slot currently holding an item — used by PartyMemberData.capture()
## to enumerate a unit's loadout without needing to probe all 16 EquipSlot
## enum values by hand.
func equipped_slots() -> Array:
	return _equipped.keys()


## Records item as equipped in slot_key and registers every stat
## modifier its GearItem grants — does NOT touch the scene tree; showing
## it is EquipSlot's job, this is just the per-unit bookkeeping of what's
## currently worn.
func equip(slot_key: EquipSlot.Slot, item: ItemInstance) -> void:
	_equipped[slot_key] = item
	if item.gear_data:
		for modifier in item.gear_data.stat_modifiers:
			_owner.register_stat_modifier(modifier, item.gear_data.item_name)


## Clears slot_key and reverts every stat modifier the previously-equipped
## item was granting. Returns the item that was there (or null), so the
## caller can decide where it goes next (a grid, another slot, ...).
func unequip(slot_key: EquipSlot.Slot) -> ItemInstance:
	var item: ItemInstance = _equipped.get(slot_key)
	if item and item.gear_data:
		for modifier in item.gear_data.stat_modifiers:
			_owner.unregister_stat_modifier(modifier, item.gear_data.item_name)
	_equipped.erase(slot_key)
	return item

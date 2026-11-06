class_name GearItem
extends ItemDefinition
## Mechanical definition of one kind of EQUIPPABLE item — what
## EquipSlot.accepts_item() validates against and what an equipped item
## actually grants (stat_modifiers, shared with StatusModifierBehavior's
## status-effect callers — see UnitEquipment.equip). id/item_name/icon/
## width/height are inherited from ItemDefinition (see that file) —
## every Item instance's grid footprint comes from the same shared
## record regardless of whether it's gear, so a new Item pointed at a
## given GearItem can't get a different size by mistake (the exact bug
## the sword/shield icons hit earlier — hand-measured, hand-set, wrong
## the first time).
##
## A non-gear item (currency, a plain consumable) simply points its
## Item.definition at a plain ItemDefinition instead of a GearItem —
## nothing here is mandatory.

enum SlotType {
	HELMET, AMULET, CLOAK, CHEST_ARMOR, UNDERSHIRT, BRACERS,
	RING, GLOVES, BELT, LEGS, BOOTS,
	MELEE_MAIN_HAND, MELEE_OFF_HAND, RANGED_MAIN_HAND, RANGED_OFF_HAND,
}

@export var slot_type: SlotType = SlotType.HELMET

## In pounds, as GURPS lists it. Only what is worn or wielded counts
## toward encumbrance (UnitEquipment) — the shared bag weighs nothing.
@export var weight: float = 0.0

## Applied to the wearer via Unit.register_stat_modifier()/
## unregister_stat_modifier() on equip/unequip (see UnitEquipment) —
## the exact same StatModifierBehavior class status effects already
## use, summed by the same UnitStats registry regardless of
## source. Empty for an item with no mechanical stat effect.
@export var stat_modifiers: Array[StatModifierBehavior] = []

## Held in either melee hand, lets the holder Block (UnitCombat). Its
## Defense Bonus is an ordinary DB entry in stat_modifiers.
@export var is_shield: bool = false

## Null for armor/accessories — only set when this GearItem is a weapon.
@export var weapon_data: WeaponData = null


## Each hand slot's partner, main -> off.
const OFF_HAND_OF: Dictionary = {
	SlotType.MELEE_MAIN_HAND: SlotType.MELEE_OFF_HAND,
	SlotType.RANGED_MAIN_HAND: SlotType.RANGED_OFF_HAND,
}


## Whether this kind of item goes in a slot of type target: its own
## slot type, and for a one-handed weapon the off hand too.
func fits(target: SlotType) -> bool:
	if target == slot_type:
		return true
	return weapon_data != null and not weapon_data.two_handed and OFF_HAND_OF.get(slot_type) == target


## Most sockets a copy of this kind can have, before the grid-size cap
## (ItemInstance.max_sockets): what the slot allows, and a third for a
## weapon that takes both hands.
func socket_limit() -> int:
	if weapon_data and weapon_data.two_handed:
		return 3
	return SOCKET_LIMITS.get(slot_type, 0)


const SOCKET_LIMITS: Dictionary = {
	SlotType.HELMET: 2, SlotType.CLOAK: 1, SlotType.CHEST_ARMOR: 3,
	SlotType.BRACERS: 1, SlotType.GLOVES: 2, SlotType.LEGS: 2, SlotType.BOOTS: 2,
	SlotType.MELEE_MAIN_HAND: 2, SlotType.MELEE_OFF_HAND: 2,
	SlotType.RANGED_MAIN_HAND: 2, SlotType.RANGED_OFF_HAND: 2,
}

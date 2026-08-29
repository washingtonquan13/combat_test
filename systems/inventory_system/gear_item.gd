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

## Applied to the wearer via Unit.register_stat_modifier()/
## unregister_stat_modifier() on equip/unequip (see UnitEquipment) —
## the exact same StatModifierBehavior class status effects already
## use, summed by the same UnitStatModifiers registry regardless of
## source. Empty for an item with no mechanical stat effect.
@export var stat_modifiers: Array[StatModifierBehavior] = []

## Null for armor/accessories — only set when this GearItem is a weapon.
@export var weapon_data: WeaponData = null

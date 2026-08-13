class_name GearItem
extends Resource
## Mechanical definition of one kind of item — what EquipSlot.accepts_item()
## validates against, what an equipped item actually grants (stat_modifiers,
## shared with StatusModifierBehavior's status-effect callers — see
## UnitEquipment.equip), and its grid footprint (width/height), so a new
## Item instance referencing the same GearItem can't get a different size
## by mistake (the exact bug the sword/shield icons hit earlier — hand-
## measured, hand-set, wrong the first time).
##
## Item (inventory_system/item.gd) is the UI/grid presentation — icon,
## stacking, drag-and-drop — and stays that way; this is the DATA a
## given Item instance's gear_data can point at, same "data resource
## separate from the presentation node" split as Ability/AbilityEffect.
## A non-gear item (currency, a plain consumable) simply leaves
## gear_data unset on its Item — nothing here is mandatory.

enum SlotType {
	HELMET, AMULET, CLOAK, CHEST_ARMOR, UNDERSHIRT, BRACERS,
	RING, GLOVES, BELT, LEGS, BOOTS,
	MELEE_MAIN_HAND, MELEE_OFF_HAND, RANGED_MAIN_HAND, RANGED_OFF_HAND,
}

@export var item_name: String = "Unnamed Item"
@export var icon: Texture2D
@export var width: int = 1
@export var height: int = 1
@export var slot_type: SlotType = SlotType.HELMET

## Applied to the wearer via Unit.register_stat_modifier()/
## unregister_stat_modifier() on equip/unequip (see UnitEquipment) —
## the exact same StatModifierBehavior class status effects already
## use, summed by the same UnitStatModifiers registry regardless of
## source. Empty for an item with no mechanical stat effect.
@export var stat_modifiers: Array[StatModifierBehavior] = []

## Null for armor/accessories — only set when this GearItem is a weapon.
@export var weapon_data: WeaponData = null

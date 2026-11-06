class_name ItemModifier
extends Resource
## What one rune (later one affix) does to the copy it sits on. Two
## halves, split by who they change:
##
## - Local: the copy's own attacks. ItemInstance.attacks() builds this
##   copy's rows from the shared WeaponData rows plus these, so the .tres
##   rows every other copy points at are never written to.
## - Global: the wearer. Registered on equip exactly like the base
##   GearItem.stat_modifiers (see UnitEquipment) — an armour's +1 DR is
##   one of these, not a local stat of the armour.

## Shown in the tooltip: "+1 damage", "+1 DR".
@export var label: String = ""

@export_group("Local")
## Added to every attack row's damage: the SWING/THRUST bonus, or a
## FIXED row's dice bonus.
@export var damage_bonus: int = 0
## Added to every attack row's to-hit (AttackRow.to_hit_bonus).
@export var to_hit_bonus: int = 0

@export_group("Global")
@export var stat_modifiers: Array[StatModifierBehavior] = []


func changes_attacks() -> bool:
	return damage_bonus != 0 or to_hit_bonus != 0


## Writes the local half into row, which must be this copy's own
## duplicate.
func apply_to_row(row: AttackRow) -> void:
	if row.damage_base == AttackRow.DamageBase.FIXED:
		row.fixed_dice_bonus += damage_bonus
	else:
		row.damage_bonus += damage_bonus
	row.to_hit_bonus += to_hit_bonus

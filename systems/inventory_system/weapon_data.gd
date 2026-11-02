class_name WeaponData
extends Resource
## Composed onto GearItem only when it's actually a weapon — kept
## separate rather than a pile of weapon-only fields sitting unused on
## every armor/accessory GearItem too, same reasoning StatusBehavior
## already splits "what a status DOES" into small focused pieces
## instead of one class with a field per possible status.
##
## A weapon is its rows: each AttackRow is one way to use it (a
## broadsword swings to cut or thrusts to impale), and each becomes its
## own attack on the hotbar — see Unit.combat_abilities().

@export var attacks: Array[AttackRow] = []


## This weapon's rows of one kind, in authored order.
func rows_of(kind: AttackRow.Kind) -> Array[AttackRow]:
	var rows: Array[AttackRow] = []
	for row in attacks:
		if row and row.kind == kind:
			rows.append(row)
	return rows

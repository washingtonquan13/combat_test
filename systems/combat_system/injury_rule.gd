@tool
class_name InjuryRule
extends Resource
## One change an InjuryPreset makes to a body plan: op with value on
## field, for the rows and wound types listed. See InjuryProfile.build.

enum Op { SET, CAP }
enum Field { MULTIPLIER, MAX_INJURY, DR }

@export var op: Op = Op.SET
@export var field: Field = Field.MULTIPLIER
## CAP keeps the lower of this and what is there. For MAX_INJURY, 0 (no
## cap) counts as higher than any cap.
@export var value: float = 1.0
## The rows this changes, by location (torso.tres for the torso). Empty
## is every row.
@export var rows: Array[HitLocation] = []
## The wound types this changes; empty is all of them.
@export var wound_types: Array[DamageResolver.WoundType] = []


func applies_to(row: BodyRow) -> bool:
	return rows.is_empty() or rows.has(row.location)


func types() -> Array:
	if wound_types.is_empty():
		return range(DamageResolver.WoundType.size())
	return wound_types


func apply(row: BodyRow, wound_type: int) -> void:
	var current: float = row.get_value(field, wound_type)
	match op:
		Op.SET:
			row.set_value(field, wound_type, value)
		Op.CAP:
			var uncapped: bool = field == Field.MAX_INJURY and current <= 0.0
			if uncapped or value < current:
				row.set_value(field, wound_type, value)

@tool
class_name InjuryRule
extends Resource
## One change an InjuryTrait makes to a body plan: op with value on
## field, for the rows and wound types listed. Rules apply in a fixed
## order (ORDER) whatever order the traits arrive in, so two traits
## always merge the same way. See InjuryProfile.build.

enum Op { SET, SCALE, ADD, CAP, COPY_TORSO }
enum Field { MULTIPLIER, MAX_INJURY, DR }

## COPY_TORSO is last so a copied row takes the torso's final numbers.
const ORDER: Array[Op] = [Op.SET, Op.SCALE, Op.ADD, Op.CAP, Op.COPY_TORSO]

@export var op: Op = Op.SET
## Ignored by COPY_TORSO.
@export var field: Field = Field.MULTIPLIER
## CAP keeps the lower of this and what is there. For MAX_INJURY, 0 (no
## cap) counts as higher than any cap.
@export var value: float = 1.0
## The rows this changes, by location (torso.tres for the torso). Empty
## is every row.
@export var rows: Array[HitLocation] = []
## The wound types this changes; empty is all of them. Ignored by
## COPY_TORSO.
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
		Op.SCALE:
			row.set_value(field, wound_type, current * value)
		Op.ADD:
			row.set_value(field, wound_type, current + value)
		Op.CAP:
			var uncapped: bool = field == Field.MAX_INJURY and current <= 0.0
			if uncapped or value < current:
				row.set_value(field, wound_type, value)

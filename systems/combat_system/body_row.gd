@tool
class_name BodyRow
extends Resource
## One hit location of a BodyPlan: what each wound type does there
## (B379, B398-399). Every array is indexed by DamageResolver.WoundType,
## one entry per type, so a row answers for every attack. There is no
## list of types a location "doesn't take": a location that is no better
## than the torso for a type just holds the torso's numbers.

## Which location this is; the torso row holds torso.tres.
@export var location: HitLocation
## Resolve exactly as the torso does (No Vitals, No Brain). Applied after
## every other rule, so it follows the torso's final numbers.
@export var copy_torso: bool = false
## Wounding multiplier per wound type. 0 is immune: no injury, not even 1.
@export var multipliers: PackedFloat32Array = PackedFloat32Array([1, 1.5, 2, 0.5, 1, 1.5, 2, 1, 1, 1])
## Most injury one hit can do, per wound type; 0 is no cap (Diffuse).
@export var max_injury: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
## DR this location adds per wound type, before the armor divisor (the
## skull's 2).
@export var dr: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])


## The value of field (InjuryRule.Field) for wound_type.
func get_value(field: int, wound_type: int) -> float:
	match field:
		InjuryRule.Field.MULTIPLIER:
			return multipliers[wound_type]
		InjuryRule.Field.MAX_INJURY:
			return max_injury[wound_type]
		_:
			return dr[wound_type]


func set_value(field: int, wound_type: int, value: float) -> void:
	match field:
		InjuryRule.Field.MULTIPLIER:
			multipliers[wound_type] = value
		InjuryRule.Field.MAX_INJURY:
			max_injury[wound_type] = roundi(value)
		_:
			dr[wound_type] = roundi(value)


## Whether wound_type lands here any differently than on other.
func differs_from(other: BodyRow, wound_type: int) -> bool:
	return not is_equal_approx(multipliers[wound_type], other.multipliers[wound_type]) \
		or max_injury[wound_type] != other.max_injury[wound_type] or dr[wound_type] != other.dr[wound_type]


## Takes other's numbers for every wound type.
func copy_values(other: BodyRow) -> void:
	multipliers = other.multipliers.duplicate()
	max_injury = other.max_injury.duplicate()
	dr = other.dr.duplicate()

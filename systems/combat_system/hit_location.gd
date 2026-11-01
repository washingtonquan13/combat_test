class_name HitLocation
extends Resource
## A part of the body an attack can be aimed at instead of the torso
## (GURPS B398-399). Taking a to-hit penalty buys a different wounding
## multiplier, and some locations come with DR of their own (the skull).
## Only the wound types listed can be aimed here; any other attack goes
## to the torso as usual, without the penalty — see
## UnitCombat.hit_location_for.

@export var display_name: String = ""
@export var to_hit_penalty: int = 0
## Replaces the wound type's own multiplier (B379's table) outright: a
## pi- hit to the vitals is x3, not x1.5.
@export var wounding_multiplier: float = 1.0
## Added to the target's DR before any armor divisor, as natural DR is.
@export var extra_dr: int = 0
@export var wound_types: Array[DamageResolver.WoundType] = []


func allows(wound_type: DamageResolver.WoundType) -> bool:
	return wound_types.has(wound_type)


## "-3 to hit, x3 wounding" for a tooltip, plus the extra DR and which
## wound types qualify.
func describe() -> String:
	var parts: PackedStringArray = ["%+d to hit" % to_hit_penalty, "x%s wounding" % String.num(wounding_multiplier)]
	if extra_dr > 0:
		parts.append("+%d DR" % extra_dr)
	var types: PackedStringArray = []
	for wound_type in wound_types:
		types.append(DamageResolver.ABBREVIATION[wound_type])
	return "%s\n%s only; anything else hits the torso" % [", ".join(parts), ", ".join(types)]

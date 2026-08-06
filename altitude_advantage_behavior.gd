class_name AltitudeAdvantageBehavior
extends StatusBehavior
## Ranged attacks against a unit high above the attacker are harder to
## land; against one below the attacker, easier — continuous with
## altitude difference, not banded, to match this project's free-
## altitude flight (see the flight-design discussion this followed).
## Same shape as ProneBehavior (which splits melee/ranged the same way,
## via ability.targeting's type), but a scaled continuous value instead
## of a flat bonus.
##
## Melee gets no equivalent modifier here on purpose: MeleeEnemyTargeting's
## own tiny range (see Unit.edge_distance_to, already full 3D distance)
## already makes it unable to reach a meaningfully elevated target at
## all — there's no realistic case where a melee attack against an
## airborne target would even reach modify_incoming_attack_to_hit in the
## first place, so a melee rule here would be dead code, not a missing
## rule.

## To-hit penalty per meter the defender is ABOVE the attacker (and,
## symmetrically, bonus per meter BELOW) — starting/tunable balance
## value, not a derived constant.
@export var to_hit_penalty_per_meter: float = 0.5
@export var max_modifier: int = 4


func modify_incoming_attack_to_hit(defender: Unit, attacker: Unit, ability: Ability) -> int:
	if not ability.targeting is RangedEnemyTargeting:
		return 0

	var altitude_advantage: float = defender.global_position.y - attacker.global_position.y
	var modifier: int = roundi(-altitude_advantage * to_hit_penalty_per_meter)
	return clamp(modifier, -max_modifier, max_modifier)


func describe() -> String:
	return "Altitude affects ranged attacks against this unit"

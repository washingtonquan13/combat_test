class_name AltitudeAdvantageBehavior
extends Resource
## General high-ground rule for ranged attacks — a unit shooting DOWN at
## a target below it gets easier, shooting UP gets harder, continuous
## with the height difference rather than banded, to match this
## project's free-altitude flight (see the flight-design discussion this
## followed).
##
## Originally a StatusBehavior attached only to the Flying status,
## meaning the bonus only ever applied when the DEFENDER happened to be
## flying — a grounded unit standing on this project's own elevated
## platforms got no benefit at all for shooting down at someone on the
## floor. Altitude difference isn't really a persistent condition on one
## unit the way a status is, though — it's a live relationship between
## attacker and defender positions at the moment of THIS attack, which
## is why it now lives as a plain Resource UnitCombat.use_ability() calls
## directly (see the ALTITUDE_ADVANTAGE const there) instead of going
## through StatusManager's per-status aggregation.
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

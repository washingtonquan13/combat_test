class_name GrantFlightEffect
extends AbilityEffect
## Applies flying_status to attacker and lifts them takeoff_height
## straight up. Relative (+=), not an absolute Y, so it lifts correctly
## from whatever height the caster is already standing at (a platform,
## not just y=0).

@export var flying_status: StatusEffect
@export var takeoff_height: float = 3.0


func apply(attacker: Unit, _target, _ability: Ability) -> Dictionary:
	if not flying_status:
		return {}

	attacker.apply_status(flying_status)
	attacker.global_position.y += takeoff_height
	# The unit's next move should hold this new height by default, not
	# snap back toward wherever flight_target_altitude was last left
	# (0.0, or a stale value from a previous flight) — see
	# Unit.adjust_flight_altitude()/movement_indicator.gd's R/F key
	# handling for how the player changes this afterward.
	attacker.flight_target_altitude = attacker.global_position.y

	SystemLog.print("%s takes to the air." % LogFormat.unit_name(attacker))
	return {}


func describe() -> String:
	return "Grants flight"

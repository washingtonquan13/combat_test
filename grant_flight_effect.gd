class_name GrantFlightEffect
extends AbilityEffect
## Applies flying_status to attacker and lifts them takeoff_height
## straight up, eased over ascend_duration via Tween rather than an
## instant teleport — see Unit.land() for the matching landing animation
## (same TRANS_SINE/EASE_IN_OUT curve, so takeoff and landing read as one
## consistent "this is what airborne motion looks like" language rather
## than two independently-tuned effects). Relative (current height +
## takeoff_height), not an absolute Y, so it lifts correctly from
## whatever height the caster is already standing at (a platform, not
## just y=0).

@export var flying_status: StatusEffect
@export var takeoff_height: float = 3.0
@export var ascend_duration: float = 0.6


func apply(attacker: Unit, _target, _ability: Ability) -> Dictionary:
	if not flying_status:
		return {}

	attacker.apply_status(flying_status)
	var target_y: float = attacker.global_position.y + takeoff_height
	# The unit's next move should hold this new height by default, not
	# snap back toward wherever flight_target_altitude was last left
	# (0.0, or a stale value from a previous flight) — see
	# Unit.set_flight_altitude()/movement_indicator.gd's Ctrl-drag
	# handling for how the player changes this afterward. Set immediately
	# rather than waiting for the ascend animation to finish, so anything
	# reading it mid-animation (the movement preview, an AI decision)
	# already sees the real final altitude, not a stale one.
	attacker.flight_target_altitude = target_y

	attacker.begin_busy()
	var tween: Tween = attacker.create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(attacker, "global_position:y", target_y, ascend_duration)
	tween.finished.connect(attacker.end_busy)

	SystemLog.print("%s takes to the air." % LogFormat.unit_name(attacker))
	return {}


func describe() -> String:
	return "Grants flight"

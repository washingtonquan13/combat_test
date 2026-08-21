class_name GrantFlightEffect
extends AbilityEffect
## Applies flying_status to attacker and lifts them takeoff_height
## straight up, eased via Tween over a duration scaled by takeoff_height
## (distance/vertical_speed, clamped to [min_ascend_duration,
## max_ascend_duration]) rather than a fixed time or an instant teleport
## — see Unit.land() for the matching landing animation (same
## TRANS_SINE/EASE_IN_OUT curve and same distance-scaled pacing logic,
## so takeoff and landing read as one consistent "this is what airborne
## motion looks like" language rather than two independently-tuned
## effects). Relative (current height + takeoff_height), not an absolute
## Y, so it lifts correctly from whatever height the caster is already
## standing at (a platform, not just y=0).

@export var flying_status: StatusEffect
@export var takeoff_height: float = 3.0
## Vertical ascent speed (m/s) — see Unit.vertical_speed for why landing
## uses the same idea (kept as a separate value here since takeoff has
## a single call site and landing has several).
@export var vertical_speed: float = 6.0
## Floor on the ascend duration — keeps a tiny takeoff_height from
## reading as an instant snap.
@export var min_ascend_duration: float = 0.15
## Ceiling on the ascend duration. Same rationale as
## Unit.max_land_duration: a generous standalone backstop (not derived
## from any flight-altitude constant) so it never engages for any
## realistic takeoff_height and every normal takeoff reads as true
## constant velocity — it only guards against an unusually large
## takeoff_height set on some future ability.
@export var max_ascend_duration: float = 4.0


func apply(attacker: Unit, _target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not flying_status:
		return {}

	attacker.apply_status(flying_status)
	# Clamped to the same flight envelope every other altitude write in
	# this project already respects (Unit.set_flight_altitude(),
	# UnitMovement.plan_route(), movement_indicator.gd's own preview) —
	# this was the one unclamped write. Without it, taking off from
	# anywhere within takeoff_height of NavigationGrid.FLIGHT_CEILING_HEIGHT
	# (a tall platform, notably) left the unit standing above the ceiling,
	# which NavigationGrid.is_valid_cell() hard-rejects for a flying query
	# — every subsequent find_path() call, preview or real, then starts
	# from a cell the grid considers invalid and returns nothing: no
	# indicator, no movement, until landing brought the unit back into the
	# valid range.
	var target_y: float = clamp(
		attacker.global_position.y + takeoff_height,
		NavigationGrid.FLIGHT_MIN_ALTITUDE,
		NavigationGrid.FLIGHT_CEILING_HEIGHT
	)
	# The unit's next move should hold this new height by default, not
	# snap back toward wherever flight_target_altitude was last left
	# (0.0, or a stale value from a previous flight) — see
	# Unit.set_flight_altitude()/movement_indicator.gd's Ctrl-drag
	# handling for how the player changes this afterward. Set immediately
	# rather than waiting for the ascend animation to finish, so anything
	# reading it mid-animation (the movement preview, an AI decision)
	# already sees the real final altitude, not a stale one.
	attacker.flight_target_altitude = target_y

	# Distance actually traveled (not the nominal takeoff_height) — the
	# two only diverge in the clamped near-ceiling case, same "duration
	# tracks the real distance" discipline Unit.land() already uses for
	# its own descent.
	var ascent: float = target_y - attacker.global_position.y
	var duration: float = clampf(ascent / vertical_speed, min_ascend_duration, max_ascend_duration)

	attacker.begin_busy()
	var tween: Tween = attacker.create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(attacker, "global_position:y", target_y, duration)
	tween.finished.connect(attacker.end_busy)

	SystemLog.print("%s takes to the air." % LogFormat.unit_name(attacker))
	return {}


func describe() -> String:
	return "Grants flight"

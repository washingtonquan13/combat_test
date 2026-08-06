class_name GrantFlightEffect
extends AbilityEffect
## Applies flying_status to attacker and lifts them takeoff_height
## straight up — the only altitude change this project can make happen
## right now, since free-form altitude control (the click-then-adjust-
## height UI discussed but not yet built) doesn't exist yet. From this
## point on, UnitMovement.move_to()'s flying branch just holds whatever
## height the unit is currently at on every subsequent move; there's no
## way to go any higher or lower until that follow-up lands. Relative
## (+=), not an absolute Y, so it lifts correctly from whatever height
## the caster is already standing at (a platform, not just y=0).

@export var flying_status: StatusEffect
@export var takeoff_height: float = 3.0


func apply(attacker: Unit, _target, _ability: Ability) -> Dictionary:
	if not flying_status:
		return {}

	# Deliberately triggered here, at cast time, rather than left to
	# UnitMovement.move_to()'s own lazy call (still there too, as a
	# harmless no-op once this has already run) — a freshly-created
	# NavigationRegion3D needs the NavigationServer a couple of frames
	# to actually register before it's queryable (confirmed by testing:
	# creating it and querying in the same synchronous call silently
	# returned zero waypoints). Casting Fly and then clicking a
	# destination are always separate inputs in real play, so triggering
	# the one-time creation here rather than inside move_to() itself
	# gives that sync gap time to close before it could matter — can't
	# just await it here instead, since Ability effects are called
	# synchronously by UnitCombat.use_ability() (no `await` at that call
	# site), so an await here wouldn't actually be waited on by the caller.
	NavigationCarving.ensure_air_region_baked(attacker.get_tree())

	attacker.apply_status(flying_status)
	attacker.global_position.y += takeoff_height

	SystemLog.print("%s takes to the air." % LogFormat.unit_name(attacker))
	return {}


func describe() -> String:
	return "Grants flight"

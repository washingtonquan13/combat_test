class_name KnockbackEffect
extends AbilityEffect
## Pushes the TARGET directly away from the caster along the straight
## line between them, by a fixed distance — same direct global_position
## Tween approach MoveCasterEffect uses for Jump (see that file), just
## applied to target instead of attacker, with no arc: a shove is a pure
## horizontal displacement, it never changes the target's altitude — a
## flying target stays exactly as airborne as it was (deliberate design
## choice: shove isn't a fall/knockdown, that's IncapacitateBehavior's
## job — see Unit.ground_if_flying()).
##
## Deliberately bypasses move_and_slide() and PathAvoidance the same way
## Jump does — a shove isn't a walk order, it shouldn't path around
## obstacles or ask permission. The one thing it DOES respect is the
## navmesh itself for a GROUNDED target: the destination is snapped onto
## walkable ground so a knockback can't shove a unit through a wall or
## off into the void. A FLYING target skips that snap entirely — see
## apply()'s own comment for why: NavigationServer3D.
## map_get_closest_point() has no navigation_layers parameter (confirmed
## — same limitation Unit.land() works around), so with both a ground
## and an air region on the same map it could just as easily snap onto
## the wrong one, silently dropping a flying target toward the ground
## instead of leaving it at its own height.
## Does NOT check for another unit already standing at the landing spot
## (no pileup/collision resolution) — an intentional simplification, not
## an oversight; revisit if stacking knockbacks into a wall of allies
## becomes a real tactic worth modeling.
##
## Doesn't touch anyone's move_remaining — being shoved isn't the
## target's own movement choice, so it costs neither the caster's nor
## the target's turn budget. Still triggers ordinary physics overlap
## (Area3D.body_entered/exited) same as any other movement, since that's
## driven by the physics engine noticing the collision shape moved, not
## by HOW it moved — knocking someone into Grease works correctly for
## free, no special-casing needed here.

@export var distance: float = 3.0
@export var push_duration: float = 0.25


func apply(attacker: Unit, target, _ability: Ability) -> Dictionary:
	if not target is Unit:
		return {}

	var from: Vector3 = attacker.global_position
	var to: Vector3 = target.global_position
	var offset: Vector3 = to - from
	offset.y = 0.0
	if offset.length() < 0.001:
		return {}

	var direction: Vector3 = offset.normalized()
	var raw_destination: Vector3 = to + direction * distance

	var destination: Vector3
	if target.is_flying():
		# No navmesh snap here — see this file's header for why
		# map_get_closest_point() isn't safe to use once an air region
		# exists on the same map. Not needed anyway: the air layer is
		# currently one open rectangle with no carved obstacles (see
		# NavigationCarving.ensure_air_region_baked), so there's nothing
		# to snap away from. Y is explicitly held at the target's
		# current altitude regardless of what raw_destination's Y ended
		# up being (it already matches, since offset.y was zeroed above
		# — this just makes that invariant explicit rather than implicit).
		destination = raw_destination
		destination.y = to.y
	else:
		var map_rid: RID = target.nav_agent.get_navigation_map()
		destination = NavigationServer3D.map_get_closest_point(map_rid, raw_destination)

	var actual_distance: float = to.distance_to(destination)

	_animate_push(target, destination)

	return {"knockback_distance": actual_distance}


func _animate_push(target: Unit, destination: Vector3) -> void:
	var start: Vector3 = target.global_position
	target.begin_busy()
	var tween: Tween = target.create_tween()
	tween.tween_method(
		func(t: float): target.global_position = start.lerp(destination, t),
		0.0, 1.0, push_duration
	)
	tween.finished.connect(target.end_busy)


func describe() -> String:
	return "Knockback %.1fm" % distance

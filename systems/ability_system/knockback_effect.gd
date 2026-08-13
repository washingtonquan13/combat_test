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
## grid itself for a GROUNDED target: the destination is snapped onto a
## valid supported cell (see NavigationGrid.nearest_valid_point) so a
## knockback can't shove a unit through a wall, off into the void, or
## into another unit. A FLYING target skips that snap entirely — see
## apply()'s own comment for why.
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


func apply(attacker: Unit, target, _ability: Ability, _is_critical: bool) -> Dictionary:
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
		# No grid snap here, deliberately — a shove is a pure horizontal
		# displacement (see this file's header); it doesn't check for
		# real obstacles at the target's altitude at all (shove is
		# melee-range, so attacker and target are already close in
		# altitude, and nothing has asked for shove-respects-air-
		# obstacles specifically). Y is explicitly held at the target's
		# current altitude regardless of what raw_destination's Y ended
		# up being (it already matches, since offset.y was zeroed above
		# — this just makes that invariant explicit rather than implicit).
		destination = raw_destination
		destination.y = to.y
	else:
		var clearance: float = target.radius + target.avoidance_margin
		var snap: Dictionary = NavigationGrid.nearest_valid_point(target.get_tree(), raw_destination, clearance, false, target)
		# Nothing valid found nearby (e.g. shoved toward a solid wall
		# with no clear cell within range) — left exactly where it is
		# rather than guessing a fallback, same "no guessing" philosophy
		# as Unit.land()'s own "nowhere to land" case.
		destination = snap.point if snap.found else to

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

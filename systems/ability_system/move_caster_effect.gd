class_name MoveCasterEffect
extends AbilityEffect
## Moves the ATTACKER (not target) to a ground point — pairs with
## GroundPointTargeting, where target is a Vector3, not a Unit.
##
## Deliberately does NOT reuse Unit.move_to() — that would defeat the
## entire point of a jump, since normal pathfinding tries to route
## AROUND whatever gap you're trying to jump OVER (or fails to find a
## path at all). Instead this directly animates global_position along a
## simple arc via Tween, bypassing move_and_slide()'s physics collision
## response on purpose: a jump is supposed to be able to arc over things
## a walk would be physically blocked by.
##
## Consumes the SAME move_remaining budget normal movement does, if in
## combat — a jump that cost nothing would trivially bypass the turn's
## whole movement economy. If the intended distance exceeds what's left,
## the landing point is clamped shorter along the same direction rather
## than the jump being rejected outright, same "walk as far as you can"
## convention Unit.move_to() already established for an ordinary click
## beyond range.
##
## arc_point() and clamp_to_budget() are public deliberately, not just
## implementation details — jump_indicator.gd calls both directly so the
## preview arc is computed EXACTLY the way the real jump will be, rather
## than duplicating this math and risking the two silently drifting
## apart the way line_of_sight_indicator.gd's necessary duplication can.

@export var jump_duration: float = 0.4
@export var arc_height: float = 1.5


func apply(attacker: Unit, target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Vector3:
		return {}

	if CombatManager.in_combat and not attacker.has_move_remaining():
		return {}

	var destination: Vector3 = clamp_to_budget(attacker, target)
	var distance: float = attacker.global_position.distance_to(destination)

	_animate_jump(attacker, destination)

	if CombatManager.in_combat:
		attacker.spend_move(distance)

	return {"jumped_distance": distance}


## The actual landing point after clamping to whatever move budget is
## left this turn — unchanged if out of combat, or if there's enough
## budget to cover the full distance already.
func clamp_to_budget(attacker: Unit, destination: Vector3) -> Vector3:
	if not CombatManager.in_combat:
		return destination

	var distance: float = attacker.global_position.distance_to(destination)
	if distance <= attacker.move_remaining or distance <= 0.001:
		return destination

	var direction: Vector3 = (destination - attacker.global_position) / distance
	return attacker.global_position + direction * attacker.move_remaining


func _animate_jump(attacker: Unit, destination: Vector3) -> void:
	var start: Vector3 = attacker.global_position
	attacker.begin_busy()
	var tween: Tween = attacker.create_tween()
	tween.tween_method(
		func(t: float): attacker.global_position = arc_point(start, destination, t),
		0.0, 1.0, jump_duration
	)
	tween.finished.connect(attacker.end_busy)


## Point along the jump's parabolic arc at t (0 = start, 1 = end), peaking
## at arc_height above a straight lerp when t=0.5.
func arc_point(start: Vector3, end: Vector3, t: float) -> Vector3:
	var point: Vector3 = start.lerp(end, t)
	point.y += arc_height * 4.0 * t * (1.0 - t)
	return point


func describe() -> String:
	return "Leap to target location"

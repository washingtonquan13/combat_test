class_name MoveCasterEffect
extends AbilityEffect
## Moves the ATTACKER (not target) to a ground point — pairs with
## GroundPointTargeting, where target is a Vector3, not a Unit.
##
## Deliberately does NOT reuse Unit.move_to() — that would defeat the
## entire point of a jump, since normal pathfinding tries to route
## AROUND whatever gap you're trying to jump OVER (or fails to find a
## path at all). Instead this flies global_position (ArcFlight) along a
## simple arc via Tween, bypassing move_and_slide()'s physics collision
## response on purpose: a jump is supposed to be able to arc over things
## a walk would be physically blocked by.
##
## Consumes the SAME move_remaining budget normal movement does, if in
## combat — a jump that cost nothing would trivially bypass the turn's
## whole movement economy. If the intended distance exceeds what's left,
## the landing point is clamped shorter along the same direction rather
## than the jump being rejected outright: GroundPointTargeting.landing_for,
## so the click is checked (walls, footing) at the shortened spot.
##
## arc_point() is public deliberately: jump_indicator.gd calls it (and
## landing_for) so the preview arc is the real jump's, not a copy.

@export var jump_duration: float = 0.4


func apply(attacker: Unit, target, ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Vector3:
		return {}

	if attacker.in_combat() and not attacker.has_move_remaining():
		return {}

	var targeting := ability.targeting as GroundPointTargeting if ability else null
	var destination: Vector3 = targeting.landing_for(attacker, target) if targeting else target
	var distance: float = attacker.global_position.distance_to(destination)

	ArcFlight.fly(attacker, destination, arc_height_of(ability), jump_duration)

	if attacker.in_combat():
		attacker.spend_move(distance)

	return {"jumped_distance": distance}


## The jump's peak height: its targeting's flight_arc_height, the curve
## the targeting checks for walls, so the flight and the check can't
## differ.
static func arc_height_of(ability: Ability) -> float:
	var targeting := ability.targeting as GroundPointTargeting if ability else null
	return targeting.flight_arc_height if targeting else 0.0


## Point along the jump's arc at t (0 = start, 1 = end).
func arc_point(ability: Ability, start: Vector3, end: Vector3, t: float) -> Vector3:
	return ArcFlight.point(start, end, arc_height_of(ability), t)


func describe() -> String:
	return "Leap to target location"

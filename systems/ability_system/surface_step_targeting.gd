class_name SurfaceStepTargeting
extends GroundPointTargeting
## A step from one surface to another of the same element (Puddle Step:
## sink into one water surface, rise out of another nearby). The caster
## must be standing in a ground surface of `element`, and the point must be
## on one too; in between nothing matters (no path, no sight line), since
## the caster goes through the surface, not over the ground.
##
## Kept to an element rather than to Water so a shadow version can reuse
## it once shadows are surfaces.

@export var element: Surface.Element = Surface.Element.WATER


func check(attacker: Unit, target) -> Reach:
	if not target is Vector3:
		return Reach.INVALID
	if not standing_in(attacker):
		return Reach.INVALID
	var destination: Vector3 = target
	if attacker.global_position.distance_to(destination) > range_for(attacker):
		return Reach.OUT_OF_RANGE
	if not _surface_matches(SurfaceManager.surface_at(destination, WorldManager.context_for(attacker))):
		return Reach.INVALID
	if not _can_stand_at(attacker, destination):
		return Reach.INVALID
	return Reach.OK


## Whether attacker is in a ground surface of element right now. A flier
## isn't in anything on the ground.
func standing_in(attacker: Unit) -> bool:
	if attacker.is_flying():
		return false
	for surface in SurfaceManager.surfaces_under(attacker):
		if _surface_matches(surface):
			return true
	return false


func _surface_matches(surface: Surface) -> bool:
	return surface != null and surface.element == element


func describe() -> String:
	return "From %s to %s, range %.1f" % [_element_name(), _element_name(), max_range]


func _element_name() -> String:
	return String(Surface.Element.keys()[element]).to_lower()

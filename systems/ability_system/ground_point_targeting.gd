class_name GroundPointTargeting
extends AbilityTargeting
## Targets a ground point instead of a unit — for abilities like a
## BG3-style Jump, not an attack. target here is a Vector3, not a Unit.
##
## Deliberately does NOT check that a connected walkable path exists
## between attacker and the point — a jump is explicitly supposed to be
## able to cross a gap a normal walk couldn't path through (that's the
## entire point of it being a jump and not just another way to walk).
## What it DOES check: max_range (straight-line), that the landing spot
## is actually on walkable ground (not floating over a void or inside a
## wall), and that nothing else is already standing there.
##
## Known limitation: CombatAI's targeting is built entirely around
## finding and approaching a hostile UNIT (_find_nearest_hostile
## returns a Unit, never a point) — an AI unit whose default_ability()
## uses this targeting type would never find a valid target and
## effectively never use it. Making the AI capable of choosing to jump
## somewhere is real follow-up work, not something this pass solved; as
## long as AI units don't have a ground-targeted ability as abilities[0],
## this doesn't cause a problem, just an ability the AI never picks.

@export var max_range: float = 6.0
## How close (meters) the landing point needs to be to an actual valid
## grid cell (see NavigationGrid) to count as "on walkable ground" —
## matches the tolerance pattern used elsewhere for point validation
## (see PathAvoidance).
@export var navmesh_tolerance: float = 0.5
## Whether the landing point's altitude validity follows the ATTACKER's
## own flying state (true — correct for Jump: a flying attacker jumps to
## an airborne point, a grounded one to a ground point, since the
## attacker itself ends up there) or is always validated as ground
## regardless of the attacker's altitude (false — needed for anything
## that places something ELSE at the point, like Summon Spirit: a
## summoned creature is independently grounded, so validating against
## the flying CASTER's altitude was rejecting every ground click while
## airborne — the caster's own state has nothing to do with where the
## summon lands). Defaults true to match this targeting type's original,
## Jump-only behavior; abilities that place something else should set
## this false in their .tres.
@export var validate_as_caster_flying: bool = true


func is_valid_target(attacker: Unit, target) -> bool:
	if not target is Vector3:
		return false

	var destination: Vector3 = target

	if attacker.global_position.distance_to(destination) > max_range:
		return false

	var flying: bool = attacker.is_flying() if validate_as_caster_flying else false
	var clearance: float = attacker.radius + attacker.avoidance_margin
	var max_radius_cells: int = ceili(navmesh_tolerance / NavigationGrid.CELL_SIZE)
	var snap: Dictionary = NavigationGrid.nearest_valid_point(attacker.get_tree(), destination, clearance, flying, attacker, max_radius_cells)
	if not snap.found or snap.point.distance_to(destination) > navmesh_tolerance:
		return false

	var obstacles: Dictionary = PathAvoidance.gather_obstacles(attacker.get_tree(), [attacker])
	for i in obstacles.positions.size():
		var required: float = obstacles.radii[i] + attacker.radius
		if destination.distance_to(obstacles.positions[i]) < required:
			return false

	return true


func expects_point_target() -> bool:
	return true


func describe() -> String:
	return "Ground target, range %.1f" % max_range

class_name GroundPointTargeting
extends AbilityTargeting
## Targets a ground point instead of a unit — for abilities like a
## BG3-style Jump, not an attack. target here is a Vector3, not a Unit.
##
## Deliberately does NOT check that a connected navmesh path exists
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
## How close (meters) the landing point needs to be to the actual
## navmesh to count as "on walkable ground" — matches the tolerance
## pattern used elsewhere for point validation (see PathAvoidance).
@export var navmesh_tolerance: float = 0.5


func is_valid_target(attacker: Unit, target) -> bool:
	if not target is Vector3:
		return false

	var destination: Vector3 = target

	if attacker.global_position.distance_to(destination) > max_range:
		return false

	var map_rid: RID = attacker.nav_agent.get_navigation_map()
	var closest_on_mesh: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, destination)
	if closest_on_mesh.distance_to(destination) > navmesh_tolerance:
		return false

	var obstacles: Dictionary = PathAvoidance.gather_obstacles(attacker.get_tree(), [attacker])
	for i in obstacles.positions.size():
		var required: float = obstacles.radii[i] + attacker.radius
		if destination.distance_to(obstacles.positions[i]) < required:
			return false

	return true


func describe() -> String:
	return "Ground target, range %.1f" % max_range

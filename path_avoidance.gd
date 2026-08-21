class_name PathAvoidance
extends RefCounted
## Live obstacle data for a single point-validity check — NOT a path
## planner. This file used to hold a full deterministic potential-field
## steering simulation (simulate_path() and its supporting machinery:
## steering_direction/effective_target/_simulate_path_pass/retry-on-
## zigzag detection) that UnitMovement.move_to() called to plan an
## avoidance-correct route before NavigationGrid existed. That planner
## has zero remaining callers — NavigationGrid.find_path() (a real grid
## search that already knows about every unit's footprint via
## update_occupancy()) plus RoutePlanner.plan() (budget/terrain-cost
## truncation) replaced it entirely — and has been deleted rather than
## kept "just in case," since git history is the actual right place for
## that, not several hundred lines of live, unused simulation code.
## Several other files' comments still described the deleted planner as
## the live movement planner; those were stale documentation, not code,
## and have been corrected to point at RoutePlanner instead.
##
## gather_obstacles() below is the one piece that's still genuinely
## used — by GroundPointTargeting.is_valid_target(), as a LIVE (not
## occupancy-snapshot-based) hard-overlap backstop. See that call site's
## own comment for why a live scan matters there specifically, even
## though NavigationGrid's own occupancy grid already answers a similar
## question: occupancy is a manually-refreshed snapshot (see
## NavigationGrid.update_occupancy), not automatically current, so a
## validity check that must never be wrong even when occupancy happens
## to be stale needs its own independent, always-live source of truth.

## Collects every other living unit's position/radius as obstacle data.
## excluded is a list of units to leave out (always at least the mover
## itself; AI callers should also exclude whatever unit they're trying to
## approach, since standing near your own target isn't something to
## steer away from).
static func gather_obstacles(tree: SceneTree, excluded: Array) -> Dictionary:
	var positions: PackedVector3Array = PackedVector3Array()
	var radii: PackedFloat32Array = PackedFloat32Array()

	for node in tree.get_nodes_in_group("units"):
		var unit := node as Unit
		if not unit or unit in excluded or not unit.is_alive():
			continue
		positions.append(unit.global_position)
		radii.append(unit.radius)

	return {"positions": positions, "radii": radii}

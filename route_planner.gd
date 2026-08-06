class_name RoutePlanner
extends RefCounted
## Turns a raw route (NavigationGrid.find_path() — already correct with
## respect to other units and real level geometry; see navigation_grid.gd)
## into a budget-aware walking plan: the same route, truncated to fit
## `budget`, with terrain cost (see Surface.movement_cost_multiplier)
## integrated along the way.
##
## Used by BOTH the real move (UnitMovement.move_to) and the preview
## (movement_indicator) — the literal same function, the same inputs, so
## what's previewed is exactly what happens; there's no separate
## simulation to keep in sync, same WYSIWYG guarantee the old
## PathAvoidance-based planner had, just without needing to simulate
## unit-avoidance at all (the navmesh itself is already avoidance-correct
## by the time this runs).
##
## Subdivides each navmesh segment into STEP_LENGTH chunks so a
## difficult-terrain Surface sitting between two waypoints still gets
## sampled, rather than only ever being checked exactly at waypoints —
## not physically exact, just fine-grained enough that it doesn't matter.
## The final affordable step is clamped so cumulative cost never exceeds
## budget, landing the last point at exactly budget cost rather than the
## nearest step boundary — this is what lets UnitMovement charge
## move_remaining from a known plan total instead of a re-measurement.
##
## Returns {"path": PackedVector3Array, "cumulative_cost": PackedFloat32Array}
## — cumulative_cost[i] is the total cost to reach path[i] from the
## start (cumulative_cost[0] is always 0.0), parallel to path.
static func plan(waypoints: PackedVector3Array, budget: float, cost_sampler: Callable) -> Dictionary:
	const STEP_LENGTH: float = 0.5

	var path: PackedVector3Array = PackedVector3Array([waypoints[0]])
	var cumulative_cost: PackedFloat32Array = PackedFloat32Array([0.0])
	var traveled: float = 0.0

	for i in range(1, waypoints.size()):
		var segment_start: Vector3 = waypoints[i - 1]
		var segment_end: Vector3 = waypoints[i]
		var segment_length: float = segment_start.distance_to(segment_end)
		if segment_length < 0.001:
			continue

		var steps: int = max(1, ceili(segment_length / STEP_LENGTH))
		var step_length: float = segment_length / steps
		var previous_point: Vector3 = segment_start

		for s in range(1, steps + 1):
			var t: float = float(s) / float(steps)
			var point: Vector3 = segment_start.lerp(segment_end, t)

			var multiplier: float = cost_sampler.call(previous_point) if cost_sampler.is_valid() else 1.0
			multiplier = max(multiplier, 0.001)
			var step_cost: float = step_length * multiplier

			if traveled + step_cost >= budget:
				var remaining: float = budget - traveled
				var frac: float = clamp(remaining / step_cost, 0.0, 1.0)
				path.append(previous_point.lerp(point, frac))
				cumulative_cost.append(budget)
				return {"path": path, "cumulative_cost": cumulative_cost}

			traveled += step_cost
			path.append(point)
			cumulative_cost.append(traveled)
			previous_point = point

	return {"path": path, "cumulative_cost": cumulative_cost}

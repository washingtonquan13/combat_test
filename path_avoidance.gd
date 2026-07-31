class_name PathAvoidance
extends RefCounted
## Deterministic, plan-then-execute obstacle avoidance for turn-based
## movement — designed around one hard requirement: a unit must arrive at
## EXACTLY the point the player or AI chose, with no gap between what's
## previewed and what actually happens, and with move budget consumed
## authentically (real distance) rather than approximated.
##
## Reactive avoidance (Godot's built-in RVO, or the continuous
## potential-field steering an earlier version of this file used) cannot
## give that guarantee by nature — it decides velocity moment-to-moment
## as it walks, so the exact arrival point and exact distance walked
## aren't known until the move is already over. That's fine for a game
## that tolerates "ended up roughly there." It's the wrong tool when the
## requirement is "guaranteed to end up exactly there."
##
## The fix: don't react during the walk — decide the ENTIRE route before
## a single step is taken, then walk that fixed result exactly as
## planned. simulate_path() does the planning: it runs the same
## attraction/repulsion steering math used by earlier versions of this
## system, but as a one-shot deterministic simulation over fixed inputs
## (every other unit's CURRENT position — valid to treat as static for
## the whole plan, since only one unit ever moves at a time in this
## turn-based system) rather than as a live per-frame reaction. Given the
## same inputs, it always produces the same output — which is exactly
## what makes it usable for both the movement preview AND the real move:
## they call the literal same function, so what you see is what happens.
## Unit.move_to() calls this ONCE, up front, then just walks the result
## point by point with no further avoidance decisions made mid-walk.


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


## Pushes a single point clear of every obstacle's clearance radius, if
## it isn't already, then snaps it onto the navmesh. Used to sanitize a
## destination before planning starts — a raw destination sitting inside
## another unit's clearance zone has no valid exact point to plan toward
## at all, so it needs to be resolved to the nearest one first.
static func clear_goal(
	goal: Vector3,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float,
	nav_map: RID
) -> Vector3:
	var point: Vector3 = goal
	var max_iterations: int = 8

	for _iteration in max_iterations:
		var offending: int = -1
		var offending_dist: float = INF
		for j in obstacle_positions.size():
			var min_clearance: float = obstacle_radii[j] + clearance
			var d: float = point.distance_to(obstacle_positions[j])
			if d < min_clearance and d < offending_dist:
				offending = j
				offending_dist = d

		if offending == -1:
			break

		var obstacle_pos: Vector3 = obstacle_positions[offending]
		var min_clearance: float = obstacle_radii[offending] + clearance
		var away: Vector3 = point - obstacle_pos
		away.y = 0.0
		var push_dir: Vector3 = away.normalized() if away.length() > 0.01 else Vector3.RIGHT
		point = obstacle_pos + push_dir * min_clearance

	return NavigationServer3D.map_get_closest_point(nav_map, point)


## The steering direction for one simulated step: a unit vector blending
## "toward the effective aim point" (see effective_target) with "away
## from anything too close." influence_padding extends how far out
## repulsion starts ramping up beyond bare clearance distance, so the
## simulated route curves around an obstacle before grazing it rather
## than reacting at the last instant. Returns Vector3.ZERO only when
## target is effectively already reached.
static func steering_direction(
	position: Vector3,
	target: Vector3,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float,
	influence_padding: float
) -> Vector3:
	var aim: Vector3 = effective_target(position, target, obstacle_positions, obstacle_radii, clearance)

	var to_aim: Vector3 = aim - position
	to_aim.y = 0.0
	if to_aim.length() < 0.001:
		return Vector3.ZERO
	var desired: Vector3 = to_aim.normalized()

	var repulsion: Vector3 = Vector3.ZERO
	for j in obstacle_positions.size():
		var min_clearance: float = obstacle_radii[j] + clearance
		var influence: float = min_clearance + influence_padding

		var away: Vector3 = position - obstacle_positions[j]
		away.y = 0.0
		var dist: float = away.length()

		if dist < influence and dist > 0.001:
			var strength: float = 1.0
			if influence > min_clearance:
				strength = clamp((influence - dist) / (influence - min_clearance), 0.0, 1.0)
			repulsion += (away / dist) * strength

	var blended: Vector3 = desired + repulsion

	if blended.length() < 0.05:
		# desired and repulsion have nearly cancelled — a potential-field
		# local minimum (an obstacle sitting almost exactly between
		# position and the aim point). Nudge perpendicular to break the
		# tie instead of stalling the simulation.
		var nudge: Vector3 = Vector3(-desired.z, 0.0, desired.x)
		blended += nudge * 0.5

	return blended.normalized() if blended.length() > 0.001 else Vector3.ZERO


## Where to actually aim, given what's in the way — not just "target."
## Scans for every obstacle sitting in the direct corridor from position
## to target, measures how far left/right they collectively extend (not
## just whichever is closest), and returns a point offset past whichever
## side needs the smaller detour, with a bit of forward progress mixed
## in. Recomputed fresh every call — across a simulation's steps, as the
## simulated position advances, fewer obstacles stay "in the corridor,"
## so this naturally straightens back toward target once actually clear
## of whatever was blocking it. This is what lets the simulated route
## treat several obstacles standing together as ONE blockage to go
## around, instead of reacting to only whichever one is nearest.
static func effective_target(
	position: Vector3,
	target: Vector3,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float
) -> Vector3:
	var to_target: Vector3 = target - position
	to_target.y = 0.0
	var dist_to_target: float = to_target.length()
	if dist_to_target < 0.001:
		return target

	var direction: Vector3 = to_target / dist_to_target
	var perpendicular: Vector3 = Vector3(-direction.z, 0.0, direction.x)

	var left_extent: float = 0.0
	var right_extent: float = 0.0
	var blocking: bool = false

	for j in obstacle_positions.size():
		var rel: Vector3 = obstacle_positions[j] - position
		rel.y = 0.0
		var forward: float = rel.dot(direction)
		if forward <= 0.0 or forward >= dist_to_target:
			continue

		var lateral: float = rel.dot(perpendicular)
		var required: float = obstacle_radii[j] + clearance
		if absf(lateral) < required:
			blocking = true
			if lateral >= 0.0:
				left_extent = max(left_extent, required - lateral)
			else:
				right_extent = max(right_extent, required + lateral)

	if not blocking:
		return target

	var offset: float = min(left_extent, right_extent) + clearance
	var side: Vector3 = perpendicular if left_extent <= right_extent else -perpendicular
	var forward_reach: float = min(dist_to_target, offset * 2.0)

	return position + direction * forward_reach + side * offset


## THE PLANNER. Simulates steering_direction forward through a sequence
## of navmesh waypoints, in small fixed time steps, entirely ahead of
## time — no real unit is touched, nothing here is live. Deterministic:
## the same waypoints/obstacles/budget always produce the same exact
## route, which is what makes calling this once (in Unit.move_to, before
## any movement starts) and walking the fixed result afterward a hard
## guarantee rather than an approximation — there is no live decision
## left to diverge from what this returns.
##
## budget caps total distance — the LAST step is clamped so the returned
## path's total length never exceeds it, landing the final point at
## exactly budget distance (not the nearest step boundary), which is what
## lets move budget be charged by this path's exact known length rather
## than measured after the fact. Pass a large value (e.g. the indicator
## does) to get the full route to target regardless of a unit's actual
## move_remaining, for previewing the whole path with its own budget
## split drawn separately.
static func simulate_path(
	waypoints: PackedVector3Array,
	move_speed: float,
	budget: float,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float,
	influence_padding: float,
	arrival_tolerance: float
) -> PackedVector3Array:
	if waypoints.size() < 2:
		return waypoints

	const STEP_TIME: float = 0.05
	const MAX_STEPS: int = 600  # 30 simulated seconds — generous safety cap

	var path: PackedVector3Array = PackedVector3Array([waypoints[0]])
	var position: Vector3 = waypoints[0]
	var waypoint_index: int = 1
	var traveled: float = 0.0
	var step_dist: float = move_speed * STEP_TIME

	for _step in MAX_STEPS:
		if traveled >= budget or waypoint_index >= waypoints.size():
			break

		var target: Vector3 = waypoints[waypoint_index]
		if position.distance_to(target) <= arrival_tolerance:
			waypoint_index += 1
			continue

		var dir: Vector3 = steering_direction(position, target, obstacle_positions, obstacle_radii, clearance, influence_padding)
		if dir == Vector3.ZERO:
			break

		var move_dist: float = min(step_dist, budget - traveled)
		position += dir * move_dist
		traveled += move_dist
		path.append(position)

	return path


## Total length of a polyline — used to know a planned path's exact
## distance up front (for authentic, precise budget spend) without
## re-measuring anything after the fact.
static func path_length(path: PackedVector3Array) -> float:
	var total: float = 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total

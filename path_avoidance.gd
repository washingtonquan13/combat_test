class_name PathAvoidance
extends RefCounted
## Shared utility for making navmesh paths acknowledge other units, which
## Godot's own pathfinding never does — NavigationObstacle3D/avoidance
## only affect local steering velocity during an already-moving agent,
## never NavigationServer3D.map_get_path() itself. This is a documented,
## acknowledged upstream limitation (see the Godot docs on
## NavigationObstacles, and godotengine/godot-proposals#14316 requesting
## exactly this feature), not something specific to this project.
##
## What this does instead: takes a raw path and, for each segment that
## passes within an obstacle's clearance radius, tries to insert a detour
## point that actually has room — checked against BOTH the walkable
## navmesh (so a detour never gets pushed into a wall) and every OTHER
## obstacle nearby (so dodging one unit doesn't walk straight into
## another's safety margin). If neither side of an obstacle has room, the
## path is truncated there rather than pretending a fit exists — a unit
## squeezed between a wall and another unit, or between two units with a
## gap narrower than it needs, should stop rather than attempt to occupy
## a space it physically can't. This is a geometric patch, not real
## crowd/dynamic pathfinding — it won't search for some entirely
## different route around a blocked area the way a proper replan would,
## but it correctly refuses to send a unit somewhere it can't fit,
## instead of just pretending clearance from one obstacle is enough.


## Collects every other living unit's position/radius as obstacle data,
## for feeding into avoid_obstacles()/find_budget_path(). excluded
## is a list of units to leave out (always at least the mover itself; AI
## callers should also exclude whatever unit they're trying to approach,
## since standing near your own target isn't something to detour around).
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


## Nudges path around any obstacle a segment would otherwise cut through.
## nav_map is required — validating a candidate detour point means
## checking it's still actually on the walkable mesh, not just doing the
## push-vector math in a vacuum.
##
## Iterative, front-to-back: each pass finds the FIRST blocked segment
## encountered walking the path from the start (not just the first one in
## obstacle-list order), fixes only that one, then rescans the ENTIRE
## updated path again before touching anything further along. That's
## what makes this safe against a detour point itself landing close to a
## different obstacle — since every rescan checks the whole path fresh,
## including points inserted by earlier passes, that new problem gets
## caught and fixed on the next iteration instead of being invisible to
## a one-shot algorithm that only ever checked the original segments.
## Resolving obstacles in the order the path actually reaches them (not
## obstacle-list order) is also what prevents zigzagging — the path
## never gets a detour point for something farther along before the
## nearer conflict is settled.
static func avoid_obstacles(
	path: PackedVector3Array,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float,
	nav_map: RID
) -> PackedVector3Array:
	if path.size() < 2 or obstacle_positions.is_empty():
		return path

	var current: PackedVector3Array = path.duplicate()
	# Generous but bounded — a persistently-conflicting configuration
	# should degrade (return whatever's been resolved so far) rather than
	# loop forever chasing a fit that keeps moving.
	var max_iterations: int = 32

	for _iteration in max_iterations:
		var blocked_index: int = -1
		var blocked_obstacle: int = -1

		for i in range(1, current.size()):
			var seg_start: Vector3 = current[i - 1]
			var seg_end: Vector3 = current[i]
			var hit := _first_blocking_obstacle(seg_start, seg_end, obstacle_positions, obstacle_radii, clearance)

			if hit.index != -1:
				blocked_index = i
				blocked_obstacle = hit.index
				break

		if blocked_index == -1:
			return current

		var seg_start: Vector3 = current[blocked_index - 1]
		var seg_end: Vector3 = current[blocked_index]
		var obstacle_pos: Vector3 = obstacle_positions[blocked_obstacle]
		var min_clearance: float = obstacle_radii[blocked_obstacle] + clearance

		var detour = _find_valid_detour(
			seg_start, seg_end, obstacle_pos, min_clearance,
			obstacle_positions, obstacle_radii, clearance, blocked_obstacle, nav_map
		)

		if detour == null:
			# Neither side of this obstacle has room — genuinely doesn't
			# fit given current positions. Truncate the path here rather
			# than sending the unit at a gap it can't occupy; a wider gap
			# may open up once other units finish moving, at which point
			# the next move order (or the AI's next attempt) will find it.
			var truncated: PackedVector3Array = PackedVector3Array()
			for k in blocked_index:
				truncated.append(current[k])
			return truncated

		current.insert(blocked_index, detour)

	return current


## Finds whichever obstacle is encountered FIRST along this segment
## (smallest t, i.e. closest to seg_start) among all that violate their
## clearance — not just any one that happens to be too close. Returns
## {index, t}; index is -1 if nothing blocks this segment.
static func _first_blocking_obstacle(
	seg_start: Vector3, seg_end: Vector3,
	obstacle_positions: PackedVector3Array, obstacle_radii: PackedFloat32Array, clearance: float
) -> Dictionary:
	var best_index: int = -1
	var best_t: float = INF

	for j in obstacle_positions.size():
		var obstacle_pos: Vector3 = obstacle_positions[j]
		var min_clearance: float = obstacle_radii[j] + clearance
		var t: float = _closest_t_on_segment(obstacle_pos, seg_start, seg_end)
		var closest: Vector3 = seg_start.lerp(seg_end, t)
		var dist: float = closest.distance_to(obstacle_pos)

		if dist < min_clearance and t < best_t:
			best_t = t
			best_index = j

	return {"index": best_index, "t": best_t}


## Samples points around center at exactly radius, trying angles closest
## to preferred_dir first (so the "natural" side of an obstacle is used
## when it's viable) and fanning outward around the rest of the circle if
## those are blocked too. A single obstacle only ever has two genuinely
## distinct sides worth trying, but a point squeezed between SEVERAL
## obstacles (or an obstacle and a wall) might only have room at some
## other angle entirely — checking just the two perpendicular spots
## missed that room existed at all. Returns null if nothing around the
## whole ring is valid.
static func _find_valid_point_around(
	center: Vector3, radius: float, preferred_dir: Vector3,
	obstacle_positions: PackedVector3Array, obstacle_radii: PackedFloat32Array, clearance: float,
	skip_index: int, nav_map: RID
) -> Variant:
	const SAMPLE_COUNT: int = 12  # every 30 degrees around the circle

	var base_angle: float = atan2(preferred_dir.z, preferred_dir.x)
	var angles: Array[float] = []
	for i in SAMPLE_COUNT:
		angles.append(i * TAU / SAMPLE_COUNT)

	angles.sort_custom(func(a, b): return _angle_distance(a, base_angle) < _angle_distance(b, base_angle))

	for angle in angles:
		var candidate: Vector3 = center + Vector3(cos(angle), 0.0, sin(angle)) * radius
		candidate.y = center.y
		if _is_valid_detour_point(candidate, obstacle_positions, obstacle_radii, clearance, skip_index, nav_map):
			return candidate

	return null


static func _angle_distance(a: float, b: float) -> float:
	var diff: float = fmod(a - b + PI, TAU) - PI
	if diff < -PI:
		diff += TAU
	return abs(diff)


## Pushes a single point clear of every obstacle's clearance radius, if
## it isn't already — used to sanitize a destination before pathfinding
## even runs (see find_budget_path). Iterative and bounded the same way
## avoid_obstacles is, for the same reason: pushing clear of one obstacle
## can land within a second one's clearance, which then needs its own
## push. Returns null if no valid nearby point could be found at all
## (e.g. the goal is deep inside a tight cluster with no room anywhere
## close by).
static func clear_goal(
	goal: Vector3,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float,
	nav_map: RID
) -> Variant:
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
			return point

		var obstacle_pos: Vector3 = obstacle_positions[offending]
		var min_clearance: float = obstacle_radii[offending] + clearance

		var away: Vector3 = point - obstacle_pos
		away.y = 0.0
		var preferred_dir: Vector3 = away.normalized() if away.length() > 0.01 else Vector3.RIGHT

		var candidate = _find_valid_point_around(
			obstacle_pos, min_clearance, preferred_dir,
			obstacle_positions, obstacle_radii, clearance, offending, nav_map
		)

		if candidate == null:
			return null

		point = candidate

	return null


## Tries positions around the obstacle, closest to the segment's natural
## push direction first (see _find_valid_point_around); null if nothing
## around the whole circle has room — the gap is too narrow for this
## unit to fit through at all, however it tries to go around.
static func _find_valid_detour(
	seg_start: Vector3, seg_end: Vector3, obstacle_pos: Vector3, min_clearance: float,
	obstacle_positions: PackedVector3Array, obstacle_radii: PackedFloat32Array, clearance: float,
	skip_index: int, nav_map: RID
) -> Variant:
	var closest: Vector3 = _closest_point_on_segment(obstacle_pos, seg_start, seg_end)
	var to_closest: Vector3 = closest - obstacle_pos
	to_closest.y = 0.0
	var dist: float = to_closest.length()

	var preferred_dir: Vector3
	if dist > 0.01:
		preferred_dir = to_closest.normalized()
	else:
		# Segment passes almost exactly through the obstacle's center —
		# direction from the obstacle is undefined, so use a direction
		# perpendicular to the segment itself instead of dividing by ~0.
		var seg_dir: Vector3 = seg_end - seg_start
		seg_dir.y = 0.0
		preferred_dir = seg_dir.normalized().cross(Vector3.UP) if seg_dir.length_squared() > 0.0001 else Vector3.RIGHT

	return _find_valid_point_around(
		obstacle_pos, min_clearance, preferred_dir,
		obstacle_positions, obstacle_radii, clearance, skip_index, nav_map
	)


## A detour point is valid if it's actually on the walkable navmesh (not
## pushed into a wall or off the edge of the level) AND clear of every
## OTHER obstacle's own clearance radius (not just the one this detour is
## reacting to) — checking against the obstacle that triggered the
## detour would be trivially true by construction, so it's skipped.
static func _is_valid_detour_point(
	point: Vector3, obstacle_positions: PackedVector3Array, obstacle_radii: PackedFloat32Array,
	clearance: float, skip_index: int, nav_map: RID
) -> bool:
	var closest_on_mesh: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, point)
	if closest_on_mesh.distance_to(point) > 0.1:
		return false

	for k in obstacle_positions.size():
		if k == skip_index:
			continue
		var required: float = obstacle_radii[k] + clearance
		if point.distance_to(obstacle_positions[k]) < required:
			return false

	return true


## The path the unit should actually walk this turn: the real navmesh
## path from start to goal, detoured around obstacles (see
## avoid_obstacles), truncated wherever cumulative distance would exceed
## budget. Returns the FULL path (not just the final point) — the caller
## is expected to walk it waypoint by waypoint, which is what makes the
## fitting/detour validation actually count for something instead of
## being computed and then discarded in favor of some other steering
## method that doesn't know about any of it. Always includes at least
## [start] even in edge cases (zero budget, unreachable goal, or a goal
## with no valid nearby point at all) so callers never have to
## special-case an empty result.
static func find_budget_path(
	nav_map: RID,
	start: Vector3,
	goal: Vector3,
	budget: float,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float
) -> PackedVector3Array:
	if budget <= 0.0:
		return PackedVector3Array([start])

	# The goal itself needs the same validation as any other point on the
	# path — segment detouring only ever adjusts points ALONG THE WAY to
	# a destination, it can never fix the destination being invalid,
	# since there's no "beyond it" to redirect into. Without this, a goal
	# sitting inside another unit's clearance zone just makes the final
	# segment re-flag as blocked forever, no matter how many detour
	# points get inserted before it.
	var safe_goal = clear_goal(goal, obstacle_positions, obstacle_radii, clearance, nav_map)
	if safe_goal == null:
		return PackedVector3Array([start])

	var raw_path: PackedVector3Array = NavigationServer3D.map_get_path(nav_map, start, safe_goal, true)
	if raw_path.size() < 2:
		return PackedVector3Array([start])

	var path: PackedVector3Array = avoid_obstacles(raw_path, obstacle_positions, obstacle_radii, clearance, nav_map)

	var result: PackedVector3Array = PackedVector3Array([path[0]])
	var accumulated: float = 0.0

	for i in range(1, path.size()):
		var seg_start: Vector3 = path[i - 1]
		var seg_end: Vector3 = path[i]
		var seg_len: float = seg_start.distance_to(seg_end)

		if accumulated + seg_len >= budget:
			var remaining: float = budget - accumulated
			var t: float = (remaining / seg_len) if seg_len > 0.0 else 0.0
			result.append(seg_start.lerp(seg_end, t))
			return result

		accumulated += seg_len
		result.append(seg_end)

	return result


static func _closest_t_on_segment(point: Vector3, seg_start: Vector3, seg_end: Vector3) -> float:
	var seg: Vector3 = seg_end - seg_start
	var seg_len_sq: float = seg.length_squared()
	if seg_len_sq < 0.0001:
		return 0.0
	return clamp((point - seg_start).dot(seg) / seg_len_sq, 0.0, 1.0)


static func _closest_point_on_segment(point: Vector3, seg_start: Vector3, seg_end: Vector3) -> Vector3:
	return seg_start.lerp(seg_end, _closest_t_on_segment(point, seg_start, seg_end))

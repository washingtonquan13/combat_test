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
##
## Two refinements on top of the base steering, both aimed at the same
## underlying issue: steering_direction/effective_target only ever reason
## about OTHER UNITS, never walls — wall-awareness exists ONLY as the
## post-hoc navmesh snap at the end of each step (see simulate_path). That
## combination can deadlock: a step aims to satisfy unit clearance,
## clips a wall, gets snapped back, aims the same way again next step —
## a stable stuck point, not noise.
##
##  - STRICT side commitment in effective_target: once a side (left/right
##    around a blocking obstacle) is chosen, it is NEVER re-litigated
##    while still navigating around that same blockage — only released
##    once the direct line is genuinely clear again (see preferred_side).
##    An earlier version of this tried a soft "prefer the same side
##    unless the other is meaningfully shorter" threshold instead; it
##    didn't reliably hold, because the geometry that makes one side look
##    shorter can shift by MORE than any fixed threshold as the mover's
##    own avoidance motion changes its position — the fix isn't a bigger
##    threshold, it's not re-asking the question at all while still
##    committed.
##  - Detect-and-retry in simulate_path: after a full pass, if the
##    resulting path is excessively longer than the direct waypoint route
##    (the actual harm zigzag causes — wasted move budget, matching what
##    was actually reported), re-run the whole simulation once more
##    forcing the OPPOSITE initial side choice, and keep whichever
##    result is actually shorter. This is what "detect zigzag and look
##    for a path without it" means concretely — an explicit compare-and-
##    choose, not a hope that a smarter in-the-moment heuristic avoids it.
##  - Progressive clearance/padding relaxation when forward progress
##    stalls for several consecutive steps — eases the avoidance margin
##    down (never below the mover's bare physical radius, passed in as
##    min_clearance — that floor is what guarantees this can never cause
##    actual visual overlap, only let two units pass closer than their
##    full comfort margin) until the path can actually get through a gap
##    that's physically passable but was being blocked by the SOFT
##    clearance requirement alone. If relaxation alone doesn't resolve a
##    stall (clearance has eased most of the way to the floor and it's
##    STILL not moving), the side commitment above is released early as a
##    last resort — committing hard to a side is only a good idea as long
##    as that side is actually working out.


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
## than reacting at the last instant.
##
## Returns {"direction": Vector3, "side": float} rather than a bare
## Vector3 — direction is Vector3.ZERO only when target is effectively
## already reached; side is whichever way effective_target went around an
## obstacle this step (1.0 left, -1.0 right, 0.0 if nothing was blocking),
## passed straight through from effective_target's own result. Callers
## (simulate_path) feed this back in as the NEXT step's preferred_side —
## see that parameter's doc comment on effective_target for why.
static func steering_direction(
	position: Vector3,
	target: Vector3,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float,
	influence_padding: float,
	preferred_side: float = 0.0,
	bias_opposite: bool = false
) -> Dictionary:
	var aim_result: Dictionary = effective_target(position, target, obstacle_positions, obstacle_radii, clearance, preferred_side, bias_opposite)
	var aim: Vector3 = aim_result.point

	var to_aim: Vector3 = aim - position
	to_aim.y = 0.0
	if to_aim.length() < 0.001:
		return {"direction": Vector3.ZERO, "side": 0.0}
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

	var direction: Vector3 = blended.normalized() if blended.length() > 0.001 else Vector3.ZERO
	return {"direction": direction, "side": aim_result.side}


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
##
## preferred_side (1.0 left, -1.0 right, 0.0 no commitment yet — see
## steering_direction, which threads the PREVIOUS step's chosen side back
## in here) makes the left-vs-right choice STICK: once committed to a
## side for a given blocking situation, that side is used directly,
## skipping the left_extent-vs-right_extent comparison entirely, for as
## long as something's still blocking. It's only ever recomputed fresh
## when preferred_side is 0.0 — which simulate_path only passes after a
## step reports back "clear" (blocking was false), i.e. genuinely past
## whatever it was going around. Without this, an obstacle sitting almost
## exactly on the line to target makes left_extent/right_extent nearly
## equal, and as the mover's own avoidance motion shifts its position
## step to step, which one's smaller can swing enough to flip the choice
## — the aim point alternates left/right, which is what "zigzagging near
## a destination next to another unit" actually was.
##
## bias_opposite flips which side a FRESH (uncommitted) decision defaults
## to — used only by simulate_path's retry pass (see that function) to
## deliberately explore the other routing option when the first attempt
## turned out to wander excessively, never used for the normal/first
## pass.
##
## Returns {"point": Vector3, "side": float} — side is 0.0 when nothing's
## blocking (point is just target unmodified), otherwise whichever side
## was actually used this call, for the caller to feed back in as next
## step's preferred_side.
static func effective_target(
	position: Vector3,
	target: Vector3,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float,
	preferred_side: float = 0.0,
	bias_opposite: bool = false
) -> Dictionary:
	var to_target: Vector3 = target - position
	to_target.y = 0.0
	var dist_to_target: float = to_target.length()
	if dist_to_target < 0.001:
		return {"point": target, "side": 0.0}

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
		return {"point": target, "side": 0.0}

	var use_left: bool
	if preferred_side != 0.0:
		use_left = preferred_side > 0.0
	elif bias_opposite:
		use_left = left_extent > right_extent
	else:
		use_left = left_extent <= right_extent

	var offset: float = (left_extent if use_left else right_extent) + clearance
	var side_vec: Vector3 = perpendicular if use_left else -perpendicular
	var forward_reach: float = min(dist_to_target, offset * 2.0)

	var point: Vector3 = position + direction * forward_reach + side_vec * offset
	return {"point": point, "side": 1.0 if use_left else -1.0}


## THE PLANNER. Simulates steering_direction forward through a sequence
## of navmesh waypoints, in small fixed time steps, entirely ahead of
## time — no real unit is touched, nothing here is live. Deterministic:
## the same waypoints/obstacles/budget/cost_sampler always produce the
## same exact route, which is what makes calling this once (in
## Unit.move_to, before any movement starts) and walking the fixed
## result afterward a hard guarantee rather than an approximation —
## there is no live decision left to diverge from what this returns.
##
## Each step is snapped back onto the navmesh (nav_map) after moving —
## steering_direction only ever reasons about UNITS (obstacle_positions),
## it has no idea walls exist. The straight line between two consecutive
## navmesh waypoints is guaranteed wall-clear, but a detour CURVING
## around a nearby unit is not automatically wall-aware just because its
## endpoints are — without this snap, repulsion from a unit near a
## corridor wall could push the simulated path straight into that wall,
## since nothing in the steering math would ever know it was there.
##
## budget caps total COST, not total physical distance — those two are
## only the same number when cost_sampler is unset (or returns 1.0
## everywhere). cost_sampler, if valid, is called with the CURRENT
## simulated position once per step and returns a multiplier applied to
## that step's physical distance before it's charged against budget —
## see Surface.movement_cost_multiplier/SurfaceManager.
## movement_cost_multiplier_at for the actual difficult-terrain use of
## this. Left unset (the default), every step costs exactly its physical
## distance, same as before this parameter existed. The LAST affordable
## step is clamped so total cost never exceeds budget, landing the final
## point at exactly budget cost (not the nearest step boundary) — which
## is why the return value carries cumulative_cost alongside path rather
## than callers re-deriving cost from raw geometry — this file used to
## expose a separate path_length() helper for that, removed once cost
## stopped being the same number as physical length; recompute from
## cumulative_cost instead of resurrecting it for a general "physical
## length" need if one ever comes up. Pass a large budget (e.g. the
## indicator does) to get the full route to target regardless of a unit's actual
## move_remaining, for previewing the whole path with its own cost split
## drawn separately.
##
## Returns {"path": PackedVector3Array, "cumulative_cost": PackedFloat32Array}
## — cumulative_cost[i] is the total cost to reach path[i] from the
## start (cumulative_cost[0] is always 0.0), parallel to path. Callers
## that need "how much did this whole plan cost" want
## cumulative_cost[-1]; callers that need a cost-aware split partway
## through the path (see movement_indicator.gd) read the array directly
## rather than re-summing distances themselves, so there's no chance of
## a re-derivation disagreeing with what was actually simulated.
## min_clearance is the hard floor progressive relaxation (see this
## file's header) will never ease clearance below — pass the mover's bare
## physical radius (NOT radius+avoidance_margin), which combined with an
## obstacle's own radius in effective_target/steering_direction's math is
## exactly the true no-overlap boundary. Left at its default (0.0), which
## reads as "no floor supplied," relaxation is disabled entirely (clamps
## to the unrelaxed clearance) rather than silently relaxing toward
## zero — a caller has to explicitly opt in with a real floor for this to
## do anything, so an old, not-yet-updated call site fails safe (back to
## the original stuck-not-overlapping behavior) instead of failing
## permissive.
##
## Runs _simulate_path_pass once, then checks whether that result is
## actually GOOD — see _should_retry, which is the real question this
## asks: either "it never got reasonably close to the destination, and
## that's not just because it ran out of budget getting there" (stuck),
## or "it got there, but by wandering far more than the direct route
## required" (zigzagged). Either way, this re-runs the ENTIRE simulation
## once more with bias_opposite (see effective_target), forcing every
## fresh left/right decision to try the OTHER option instead — a genuine
## second attempt at the route, not a tweak to the first one — and keeps
## whichever of the two actually did better (see _is_better_result). A
## short route (< 1m) skips this entirely — not worth a second pass for a
## hop too small to meaningfully get stuck or wander on.
static func simulate_path(
	waypoints: PackedVector3Array,
	move_speed: float,
	budget: float,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float,
	influence_padding: float,
	arrival_tolerance: float,
	nav_map: RID,
	cost_sampler: Callable = Callable(),
	min_clearance: float = 0.0
) -> Dictionary:
	var result: Dictionary = _simulate_path_pass(
		waypoints, move_speed, budget, obstacle_positions, obstacle_radii,
		clearance, influence_padding, arrival_tolerance, nav_map,
		cost_sampler, min_clearance, false
	)

	if not _should_retry(result, waypoints, budget):
		return result

	var retry: Dictionary = _simulate_path_pass(
		waypoints, move_speed, budget, obstacle_positions, obstacle_radii,
		clearance, influence_padding, arrival_tolerance, nav_map,
		cost_sampler, min_clearance, true
	)
	return retry if _is_better_result(retry, result, waypoints) else result


## The actual "discard it and take a new path" check: did the FIRST pass
## reach the real destination (the last waypoint — where the player
## actually clicked, resolved onto the navmesh) within a reasonable
## slack, or did it stall short for a reason that ISN'T simply running
## out of move budget getting there? A destination farther than
## move_remaining SHOULD stop short — that's correct, not a bug, so
## budget_exhausted is checked explicitly and excluded. Also flags a
## technically-completed path that wandered excessively far to get
## there (ZIGZAG_LENGTH_RATIO) as still worth a second attempt, even
## though it did arrive — "reached, but by taking 3x the direct
## distance" is still the thing this whole mechanism exists to catch.
static func _should_retry(result: Dictionary, waypoints: PackedVector3Array, budget: float) -> bool:
	const ARRIVAL_SLACK: float = 0.5  # meters short of the destination that still counts as "didn't get there"
	const ZIGZAG_LENGTH_RATIO: float = 1.35

	var route_len: float = _route_length(waypoints)
	if route_len < 1.0:
		return false

	var path: PackedVector3Array = result.path
	var costs: PackedFloat32Array = result.cumulative_cost
	var last_point: Vector3 = path[path.size() - 1]
	var destination: Vector3 = waypoints[waypoints.size() - 1]
	var final_cost: float = costs[costs.size() - 1] if costs.size() > 0 else 0.0

	var reached: bool = last_point.distance_to(destination) <= ARRIVAL_SLACK
	var budget_exhausted: bool = final_cost >= budget - 0.01

	if not reached and not budget_exhausted:
		return true

	return _path_length(path) > route_len * ZIGZAG_LENGTH_RATIO


## Which of two full simulation results actually did better — first by
## whichever got genuinely closer to the real destination (not just
## "shorter," which a path that gave up early would win on for the wrong
## reason), and only once they're comparably close, by whichever took
## less distance to get there.
static func _is_better_result(candidate: Dictionary, baseline: Dictionary, waypoints: PackedVector3Array) -> bool:
	var destination: Vector3 = waypoints[waypoints.size() - 1]
	var candidate_path: PackedVector3Array = candidate.path
	var baseline_path: PackedVector3Array = baseline.path

	var candidate_dist: float = candidate_path[candidate_path.size() - 1].distance_to(destination)
	var baseline_dist: float = baseline_path[baseline_path.size() - 1].distance_to(destination)

	if absf(candidate_dist - baseline_dist) > 0.1:
		return candidate_dist < baseline_dist

	return _path_length(candidate_path) < _path_length(baseline_path)


## Sum of consecutive distances along a polyline — used both for
## _route_length (the waypoints themselves) and to measure how long a
## simulated path actually came out.
static func _path_length(points: PackedVector3Array) -> float:
	var total: float = 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total


static func _route_length(waypoints: PackedVector3Array) -> float:
	return _path_length(waypoints)


## One deterministic simulation pass — see simulate_path for the
## detect-and-retry wrapper around this, and bias_opposite's doc comment
## on effective_target for what it does here.
static func _simulate_path_pass(
	waypoints: PackedVector3Array,
	move_speed: float,
	budget: float,
	obstacle_positions: PackedVector3Array,
	obstacle_radii: PackedFloat32Array,
	clearance: float,
	influence_padding: float,
	arrival_tolerance: float,
	nav_map: RID,
	cost_sampler: Callable,
	min_clearance: float,
	bias_opposite: bool
) -> Dictionary:
	if waypoints.size() < 2:
		var flat_costs: PackedFloat32Array = PackedFloat32Array()
		for _i in waypoints.size():
			flat_costs.append(0.0)
		return {"path": waypoints, "cumulative_cost": flat_costs}

	const STEP_TIME: float = 0.05
	const MAX_STEPS: int = 600  # 30 simulated seconds — generous safety cap

	# Stall detection/relaxation tuning — see this file's header for why
	# this exists. STALL_STEPS_BEFORE_RELAX * STEP_TIME (0.3s) of
	# near-zero progress before easing up at all; each easing step is
	# gradual (10%/25% toward the floor), not an instant drop, so a
	# genuinely brief hesitation doesn't overreact. RELEASE_COMMITMENT_AT
	# is the last-resort escape valve: if clearance has already relaxed
	# most of the way to the floor and it's STILL not making progress,
	# the side commitment itself gets released early (see
	# STALL_STEPS_BEFORE_RELAX's use below) rather than staying
	# permanently locked onto a side that isn't actually working.
	const STALL_PROGRESS_THRESHOLD: float = 0.02  # meters/step below which a step "didn't really move"
	const STALL_STEPS_BEFORE_RELAX: int = 6
	const CLEARANCE_RELAX_STEP: float = 0.9   # multiplies the 0..1 relax weight toward the floor
	const PADDING_RELAX_STEP: float = 0.75    # padding has no overlap floor, so it can ease off faster
	const RELEASE_COMMITMENT_AT: float = 0.3  # clearance_weight below this + still stalling -> release the side

	var path: PackedVector3Array = PackedVector3Array([waypoints[0]])
	var cumulative_cost: PackedFloat32Array = PackedFloat32Array([0.0])
	var position: Vector3 = waypoints[0]
	var waypoint_index: int = 1
	var traveled: float = 0.0
	var step_dist: float = move_speed * STEP_TIME

	# clearance_weight/padding_weight are 1.0 = full unrelaxed strength,
	# easing toward 0.0 (= min_clearance / zero padding) under sustained
	# stall, reset to 1.0 the instant a step makes real progress again.
	var floor_clearance: float = clearance if min_clearance <= 0.0 else min(min_clearance, clearance)
	var clearance_weight: float = 1.0
	var padding_weight: float = 1.0
	var stall_steps: int = 0
	var preferred_side: float = 0.0

	for _step in MAX_STEPS:
		if traveled >= budget or waypoint_index >= waypoints.size():
			break

		var target: Vector3 = waypoints[waypoint_index]
		if position.distance_to(target) <= arrival_tolerance:
			waypoint_index += 1
			preferred_side = 0.0
			clearance_weight = 1.0
			padding_weight = 1.0
			stall_steps = 0
			continue

		var effective_clearance: float = lerp(floor_clearance, clearance, clearance_weight)
		var effective_padding: float = influence_padding * padding_weight

		var steer: Dictionary = steering_direction(
			position, target, obstacle_positions, obstacle_radii,
			effective_clearance, effective_padding, preferred_side, bias_opposite
		)
		var dir: Vector3 = steer.direction
		preferred_side = steer.side
		if dir == Vector3.ZERO:
			break

		# Guarded away from 0 — a stray 0 multiplier would make
		# max_affordable (and therefore move_dist) infinite/undefined.
		var multiplier: float = cost_sampler.call(position) if cost_sampler.is_valid() else 1.0
		multiplier = max(multiplier, 0.001)

		var max_affordable: float = (budget - traveled) / multiplier
		var move_dist: float = min(step_dist, max_affordable)
		var tentative: Vector3 = position + dir * move_dist

		# See doc comment above — this is what keeps unit-avoidance from
		# ever curving the simulated path off the walkable navmesh.
		var snapped: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, tentative)
		var actual_dist: float = position.distance_to(snapped)

		if actual_dist < STALL_PROGRESS_THRESHOLD:
			stall_steps += 1
			if stall_steps >= STALL_STEPS_BEFORE_RELAX:
				clearance_weight *= CLEARANCE_RELAX_STEP
				padding_weight *= PADDING_RELAX_STEP
				stall_steps = 0
				if clearance_weight < RELEASE_COMMITMENT_AT:
					preferred_side = 0.0
		else:
			stall_steps = 0
			clearance_weight = 1.0
			padding_weight = 1.0

		position = snapped
		traveled += actual_dist * multiplier
		path.append(position)
		cumulative_cost.append(traveled)

	return {"path": path, "cumulative_cost": cumulative_cost}

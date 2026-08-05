class_name UnitMovement
extends RefCounted
## Owns path-following movement for ONE unit — deterministic
## plan-then-execute, same as before, but now the ROUTE ITSELF (not a
## repulsion simulation layered on top of it) is what avoids other
## units: this unit carries its own NavigationObstacle3D that carves a
## hole into the baked navmesh, and every other living unit does the
## same, so NavigationServer3D.map_get_path() simply never returns a
## route through occupied space in the first place. See
## navigation_carving.gd for how/when the navmesh actually gets rebaked
## (once per turn, or once per free-roam move order — NOT continuously),
## and this file's header history: an earlier version used a custom
## potential-field steering pass (path_avoidance.gd, still present,
## intentionally unused, kept as a revert path) to fake unit-avoidance on
## top of a navmesh that didn't know about units at all; a version after
## that tried Godot's live NavigationAgent3D RVO avoidance instead, which
## was also reverted — this is turn-based with only ONE unit ever moving
## at a time, so there's no reciprocal multi-agent negotiation to do,
## just one mover against momentarily-static obstacles, which navmesh
## carving solves directly and exactly rather than approximately.
##
## Once the route itself is already avoidance-correct, all move_to() has
## left to do is turn it into a budget-aware walking plan — see
## RoutePlanner.plan, which truncates the route to fit `budget` and
## integrates terrain cost (Surface.movement_cost_multiplier) along the
## way. The SAME function is what movement_indicator.gd calls for the
## preview, so preview and real move can never disagree.
##
## move_speed/radius/avoidance_margin/arrival_tolerance/stuck_timeout/
## nav_agent all stay directly on Unit rather than moving in here — the
## @export ones for the same editor-safety reasoning as UnitFacing's
## rotation_speed (the Inspector needs to read/write them before this
## component exists), and radius/nav_agent specifically because they're
## read directly by code well outside movement entirely (combat
## targeting, area effects). This component reads all of them back
## through its owner reference.
##
## Can't call move_and_slide() or set velocity/global_position on
## itself — a RefCounted has no physics body or transform at all — so
## the physics step, like UnitFacing's rotation methods, writes to
## _owner.velocity and calls _owner.move_and_slide() directly rather
## than being fully self-contained.

var _owner: Unit

var _moving: bool = false
var _move_start_position: Vector3 = Vector3.ZERO
var _stuck_timer: float = 0.0
var _last_progress_position: Vector3 = Vector3.ZERO

## The exact route this unit is currently walking, and which point in it
## is next. Planned ONCE, in full, before movement starts (see move_to /
## RoutePlanner.plan) — nothing about avoidance is decided live while
## walking; physics_process just follows these fixed points.
var _current_path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
## The planned path's exact total BUDGET COST — not necessarily its
## physical length; the two only diverge while crossing difficult
## terrain (see Surface.movement_cost_multiplier) — computed once when
## the plan is made. Spent as this turn's move budget on a normal
## completion (see _finish_move) rather than re-measuring distance
## walked, since a precomputed, deterministically-followed plan is
## authoritative by construction.
var _planned_cost: float = 0.0


func _init(owner: Unit) -> void:
	_owner = owner


## Configures this unit's carving obstacle — a real saved child node
## (Unit.nav_obstacle, see unit.tscn/unit.gd), not something created in
## code — see this file's header and navigation_carving.gd for the full
## picture. avoidance_enabled is OFF: this is carving (a bake-time hole
## in the navmesh), not live RVO push.
func setup_avoidance() -> void:
	_owner.nav_agent.radius = _owner.radius + _owner.avoidance_margin
	_owner.nav_agent.avoidance_enabled = false

	# Doubled own radius as a placeholder until the first real rebake
	# calls set_carving_radius with an actual mover's size (see that
	# method's doc comment for why the hole needs room for BOTH bodies).
	# Confirmed empirically, not obvious from the docs: carving reads
	# ONLY the `vertices` polygon outline, never `radius` — radius is
	# exclusively an avoidance (RVO) property. A radius-only obstacle
	# silently carves nothing at all.
	_set_carving_shape(_owner.radius * 2.0 + _owner.avoidance_margin)


## Toggles whether this unit's own footprint carves the navmesh at all —
## called by NavigationCarving right before a rebake, disabled for
## whichever unit(s) are about to move (a unit can't have its own
## standing position baked into a hole, or map_get_path has nowhere
## valid to start from).
func set_carving_enabled(enabled: bool) -> void:
	_owner.nav_obstacle.affect_navigation_mesh = enabled


## Resizes the carved hole for whoever's about to be walking around this
## unit — see NavigationCarving, which computes this from the actual
## mover's radius each rebake rather than a value fixed at setup time.
## Confirmed empirically (a route hugging a hole sized to only the
## STANDING unit's own radius+margin let a moving unit's route aim
## straight at a point still deep inside the standing unit's physical
## body — carving nullifies navmesh cells strictly within the obstacle's
## own shape, it does NOT separately erode by the walking agent's radius
## the way baking erodes away from walls): the hole has to be big enough
## for BOTH bodies — this unit's own radius, AND the radius of whoever
## is walking past it — or move_and_slide's physical collision (not the
## plan) ends up being what actually stops the mover, short and stuck,
## rather than the plan routing cleanly around in the first place.
func set_carving_radius(mover_clearance: float) -> void:
	_set_carving_shape(_owner.radius + _owner.avoidance_margin + mover_clearance)


## Builds a circular polygon (see set_carving_radius's doc comment for
## why this can't just be nav_obstacle.radius) and assigns it as the
## obstacle's carve outline. Local space, Y ignored (the obstacle's own
## global Y position is what's actually used for vertical placement, per
## NavigationObstacle3D.vertices) — a flat ring of points around the
## unit's own origin is all carving needs.
func _set_carving_shape(radius: float) -> void:
	const SEGMENTS: int = 12
	var vertices: PackedVector3Array = PackedVector3Array()
	for i in SEGMENTS:
		var angle: float = TAU * float(i) / float(SEGMENTS)
		vertices.append(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
	_owner.nav_obstacle.vertices = vertices


func is_moving() -> bool:
	return _moving


## Orders this unit toward destination — see this file's header for the
## deterministic plan-then-execute rationale. Out of combat, budget is
## effectively unlimited. In combat: only CombatManager.current_unit may
## move, and the plan is truncated at exactly move_remaining — see
## RoutePlanner.plan. Callers are responsible for making sure the navmesh
## has actually been rebaked for this unit as a mover before calling this
## (see NavigationCarving.rebake_for_movers) — combat turn-start and
## free-roam move orders both already do this.
func move_to(destination: Vector3) -> bool:
	if not _owner.can_act():
		return false

	var budget: float = INF

	if CombatManager.in_combat:
		if CombatManager.current_unit != _owner:
			return false
		if not _owner.has_move_remaining():
			return false
		budget = _owner.move_remaining

	var map_rid: RID = _owner.nav_agent.get_navigation_map()
	var waypoints: PackedVector3Array = NavigationServer3D.map_get_path(map_rid, _owner.global_position, destination, true)
	if waypoints.size() < 2:
		return false

	var planned: Dictionary = RoutePlanner.plan(waypoints, budget, SurfaceManager.movement_cost_multiplier_at)
	var planned_path: PackedVector3Array = planned.path

	if planned_path.size() < 2:
		return false

	_current_path = planned_path
	_path_index = 1
	_planned_cost = planned.cumulative_cost[-1] if planned.cumulative_cost.size() > 0 else 0.0
	_move_start_position = _owner.global_position
	_stuck_timer = 0.0
	_last_progress_position = _owner.global_position
	_moving = true
	_owner.movement_started.emit(_owner)
	return true


## Cancels the current move order in place, still spending whatever
## distance was actually covered (combat only).
func stop_moving() -> void:
	if not _moving:
		return
	_finish_move()


## Immediate, raw stop with NO signal emission and NO budget spend — used
## by Unit._handle_death(): a dying unit shouldn't fire movement_finished
## or charge itself for a move it's not actually completing, it's just
## being silenced. Distinct from stop_moving(), which goes through the
## normal _finish_move() flow deliberately.
func force_stop() -> void:
	_moving = false
	_owner.velocity = Vector3.ZERO
	_current_path = PackedVector3Array()
	_path_index = 0


func physics_process(delta: float) -> void:
	if not _moving:
		return

	# Skip past any waypoints already within arrival_tolerance — matters
	# most right after a step lands very close to the next waypoint, so
	# the unit doesn't stall trying to "arrive" at a point behind or
	# barely past its current position.
	while _path_index < _current_path.size():
		var to_waypoint: Vector3 = _current_path[_path_index] - _owner.global_position
		to_waypoint.y = 0.0
		if to_waypoint.length() > _owner.arrival_tolerance:
			break
		_path_index += 1

	if _path_index >= _current_path.size():
		_finish_move()
		return

	# Last-resort safety net — see stuck_timeout's doc comment. The path
	# being followed here is already geometrically clear of every other
	# unit AND every wall (it came straight from the carved navmesh), so
	# in normal circumstances this should never trigger; it exists for
	# genuinely unexpected physical obstruction (e.g. physics collision
	# response deviating from the plan) rather than as the primary
	# mechanism for anything.
	if _owner.global_position.distance_to(_last_progress_position) < 0.05:
		_stuck_timer += delta
		if _stuck_timer >= _owner.stuck_timeout:
			_finish_move()
			return
	else:
		_stuck_timer = 0.0
		_last_progress_position = _owner.global_position

	var to_target: Vector3 = _current_path[_path_index] - _owner.global_position
	to_target.y = 0.0
	var direction: Vector3 = to_target.normalized()

	_owner.face_direction(direction, delta)

	_owner.velocity = direction * _owner.move_speed
	_owner.move_and_slide()


func _finish_move() -> void:
	_moving = false
	_owner.velocity = Vector3.ZERO

	if CombatManager.in_combat:
		# The plan completed fully (walked every point) → charge its
		# exact known cost, not a re-measurement — that cost IS what was
		# spent, by construction, since nothing deviated from the plan.
		# Cut short instead (stuck_timeout, or a manual stop_moving()
		# mid-route) → fall back to actually-measured PHYSICAL
		# displacement, since in that abnormal case the plan and reality
		# genuinely diverged. That fallback under-charges if the
		# cut-short portion crossed difficult terrain — same "rare
		# last-resort path, not the normal case" trade-off as every other
		# use of stuck_timeout in this file, not worth chasing exactly.
		var completed_fully: bool = _path_index >= _current_path.size()
		var spent: float = _planned_cost if completed_fully else _move_start_position.distance_to(_owner.global_position)
		_owner.spend_move(spent)

	_current_path = PackedVector3Array()
	_path_index = 0
	_planned_cost = 0.0
	_owner.movement_finished.emit(_owner)
	# _moving just flipped to false above — is_busy()'s answer may have
	# changed as a result, but UnitActionState has no way to learn that
	# on its own (is_moving() is polled, not pushed), so this explicitly
	# tells it to re-check.
	_owner.notify_movement_idle_check()

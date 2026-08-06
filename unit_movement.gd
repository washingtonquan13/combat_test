class_name UnitMovement
extends RefCounted
## Owns path-following movement for ONE unit — deterministic
## plan-then-execute: NavigationGrid.find_path() (see that file) already
## returns a route that avoids every other living unit's footprint AND
## real level geometry, for both grounded and flying movement over one
## shared grid, so move_to() has nothing left to decide about avoidance —
## it just walks the fixed result. This file's header history: an earlier
## version used a custom potential-field steering pass (path_avoidance.gd,
## still present, intentionally unused, kept as a revert path) to fake
## unit-avoidance on top of a navmesh that didn't know about units at all;
## a version after that tried Godot's live NavigationAgent3D RVO avoidance
## instead, also reverted; the navmesh itself was replaced by NavigationGrid
## after repeated bake/sync bugs (see that file's own header) — this is
## turn-based with only ONE unit ever moving at a time, so there's no
## reciprocal multi-agent negotiation to do, just one mover against
## momentarily-static obstacles.
##
## Once the route itself is already avoidance-correct, all move_to() has
## left to do is turn it into a budget-aware walking plan — see
## RoutePlanner.plan, which truncates the route to fit `budget` and
## integrates terrain cost (Surface.movement_cost_multiplier) along the
## way. The SAME function is what movement_indicator.gd calls for the
## preview, so preview and real move can never disagree.
##
## move_speed/radius/avoidance_margin/arrival_tolerance/stuck_timeout all
## stay directly on Unit rather than moving in here — the @export ones for
## the same editor-safety reasoning as UnitFacing's rotation_speed (the
## Inspector needs to read/write them before this component exists), and
## radius specifically because it's read directly by code well outside
## movement entirely (combat targeting, area effects). This component
## reads all of them back through its owner reference.
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


func is_moving() -> bool:
	return _moving


## Orders this unit toward destination — see this file's header for the
## deterministic plan-then-execute rationale. Out of combat, budget is
## effectively unlimited. In combat: only CombatManager.current_unit may
## move, and the plan is truncated at exactly move_remaining — see
## RoutePlanner.plan. Callers are responsible for making sure the grid's
## occupancy is current for this unit as a mover before calling this (see
## NavigationGrid.update_occupancy) — combat turn-start and free-roam move
## orders both already do this.
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

	var flying: bool = _owner.is_flying()
	var query_destination: Vector3 = destination
	if flying:
		# XZ comes from wherever was clicked; Y is the pilot's own target
		# altitude (see Unit.flight_target_altitude), not the clicked
		# point's Y — a ground click always resolves near y=0, which
		# isn't where a flying unit is headed. find_path() below does a
		# genuine 3D search between the unit's real current position and
		# this point, so the returned route already climbs/descends
		# around real obstacles at each height — no separate "bake at one
		# height, then reinterpret Y along XZ progress" step needed.
		query_destination.y = clamp(
			_owner.flight_target_altitude,
			NavigationGrid.FLIGHT_MIN_ALTITUDE,
			NavigationGrid.FLIGHT_CEILING_HEIGHT
		)

	var waypoints: PackedVector3Array = NavigationGrid.find_path(_owner.get_tree(), _owner.global_position, query_destination, _owner, flying)
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
	# barely past its current position. Y is flattened for a GROUND
	# unit (horizontal arrival is all that ever mattered before flight
	# existed) but kept for a flying one — otherwise a flying unit could
	# consider itself "arrived" at a waypoint from XZ distance alone
	# while still well off in altitude, and skip past the very step that
	# was supposed to carry it the rest of the way up/down.
	var flying: bool = _owner.is_flying()
	while _path_index < _current_path.size():
		var to_waypoint: Vector3 = _current_path[_path_index] - _owner.global_position
		if not flying:
			to_waypoint.y = 0.0
		if to_waypoint.length() > _owner.arrival_tolerance:
			break
		_path_index += 1

	if _path_index >= _current_path.size():
		_finish_move()
		return

	# Last-resort safety net — see stuck_timeout's doc comment. The path
	# being followed here is already geometrically clear of every other
	# unit AND every solid cell (it came straight from NavigationGrid), so
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

	# Y flattened for a GROUND unit — velocity was never meant to carry a
	# vertical component before flight existed, gravity/floor collision
	# via move_and_slide() handled that implicitly. A flying unit needs
	# the real 3D direction, or it silently only ever moves horizontally
	# no matter what altitude its planned path actually climbs/descends
	# to (confirmed by testing: the planned path and its movement COST
	# were correctly 3D, but nothing ever consumed the path's Y before
	# this — this is that missing consumer).
	var to_target: Vector3 = _current_path[_path_index] - _owner.global_position
	if not flying:
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

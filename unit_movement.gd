class_name UnitMovement
extends RefCounted
## Owns path-following movement for ONE unit — the deterministic
## plan-then-execute system (see move_to()'s doc comment for the full
## rationale) where the entire route is simulated once, up front, via
## PathAvoidance.simulate_path, then walked exactly as planned with no
## live avoidance decisions. Owned by that Unit (see Unit._movement),
## same pattern as StatusManager/UnitActionState/UnitFacing/UnitSelection.
##
## move_speed/radius/avoidance_margin/arrival_tolerance/stuck_timeout/
## nav_agent all stay directly on Unit rather than moving in here — the
## @export ones for the same editor-safety reasoning as UnitFacing's
## rotation_speed (the Inspector needs to read/write them before this
## component exists), and radius/nav_agent specifically because they're
## read directly by code well outside movement entirely (combat
## targeting, area effects, PathAvoidance's own obstacle gathering) —
## radius in particular is a general "how big is this unit" property,
## not a movement-specific one, even though avoidance is what most
## heavily depends on it. This component reads all of them back through
## its owner reference.
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
## PathAvoidance.simulate_path) — nothing about avoidance is decided
## live while walking; physics_process just follows these fixed points.
var _current_path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
## The planned path's exact total length, computed once when the plan is
## made. Spent as this turn's move budget on a normal completion (see
## _finish_move) rather than re-measuring distance walked, since a
## precomputed, deterministically-followed path is authoritative by
## construction.
var _planned_distance: float = 0.0


func _init(owner: Unit) -> void:
	_owner = owner


func setup_avoidance() -> void:
	_owner.nav_agent.radius = _owner.radius + _owner.avoidance_margin
	# Real-time RVO steering is intentionally OFF — see move_to()'s doc
	# comment for why. nav_agent is kept only for get_navigation_map()
	# and closest-point queries (used by PathAvoidance); it no longer
	# drives how this unit actually moves.
	_owner.nav_agent.avoidance_enabled = false


func is_moving() -> bool:
	return _moving


## Orders this unit toward destination — see this file's header for the
## deterministic plan-then-execute rationale. Out of combat, budget is
## effectively unlimited. In combat: only CombatManager.current_unit may
## move, and the plan is truncated at exactly move_remaining — see
## PathAvoidance.simulate_path. extra_avoidance_exclusions lets a caller
## (e.g. CombatAI approaching its own attack target) leave specific
## units out of the plan's avoidance — you don't want to route around
## the very unit you're trying to reach.
func move_to(destination: Vector3, extra_avoidance_exclusions: Array = []) -> bool:
	if not _owner.can_act():
		return false

	var budget: float = INF

	if CombatManager.in_combat:
		if CombatManager.current_unit != _owner:
			return false
		if not _owner.has_move_remaining():
			return false
		budget = _owner.move_remaining

	var excluded: Array = [_owner]
	excluded.append_array(extra_avoidance_exclusions)
	var obstacles: Dictionary = PathAvoidance.gather_obstacles(_owner.get_tree(), excluded)
	var map_rid: RID = _owner.nav_agent.get_navigation_map()
	var clearance: float = _owner.radius + _owner.avoidance_margin

	var safe_destination: Vector3 = PathAvoidance.clear_goal(
		destination, obstacles.positions, obstacles.radii, clearance, map_rid
	)

	var waypoints: PackedVector3Array = NavigationServer3D.map_get_path(map_rid, _owner.global_position, safe_destination, true)
	if waypoints.size() < 2:
		return false

	var planned_path: PackedVector3Array = PathAvoidance.simulate_path(
		waypoints, _owner.move_speed, budget,
		obstacles.positions, obstacles.radii, clearance, _owner.avoidance_margin, _owner.arrival_tolerance, map_rid
	)

	if planned_path.size() < 2:
		return false

	_current_path = planned_path
	_path_index = 1
	_planned_distance = PathAvoidance.path_length(planned_path)
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
	# most right after a simulated step lands very close to the next
	# waypoint, so the unit doesn't stall trying to "arrive" at a point
	# behind or barely past its current position.
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
	# being followed here was already planned to fit (see
	# PathAvoidance.simulate_path), so in normal circumstances this
	# should never trigger; it exists for genuinely unexpected physical
	# obstruction (e.g. physics collision response deviating from the
	# plan) rather than as the primary mechanism for anything.
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
		# exact known length, not a re-measurement — that length IS what
		# was walked, by construction, since nothing deviated from it.
		# Cut short instead (stuck_timeout, or a manual stop_moving()
		# mid-route) → fall back to actually-measured displacement, since
		# in that abnormal case the plan and reality genuinely diverged.
		var completed_fully: bool = _path_index >= _current_path.size()
		var traveled: float = _planned_distance if completed_fully else _move_start_position.distance_to(_owner.global_position)
		_owner.spend_move(traveled)

	_current_path = PackedVector3Array()
	_path_index = 0
	_planned_distance = 0.0
	_owner.movement_finished.emit(_owner)
	# _moving just flipped to false above — is_busy()'s answer may have
	# changed as a result, but UnitActionState has no way to learn that
	# on its own (is_moving() is polled, not pushed), so this explicitly
	# tells it to re-check.
	_owner.notify_movement_idle_check()

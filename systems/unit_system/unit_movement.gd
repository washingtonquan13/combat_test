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

## Which leg of a ladder journey (see Ladder, move_to's ladder branch, and
## _begin_ladder_journey/_climb_ladder/_on_climb_finished below) is
## currently in flight: 0 = none, 1 = walking to the ladder's near point,
## 2 = climbing, 3 = walking from the ladder's far point to the real
## final destination. Checked by _finish_move() to decide whether an
## ordinary walk completing should chain into the next ladder stage
## instead of emitting movement_finished right away.
var _ladder_stage: int = 0
var _ladder: Ladder = null
var _ladder_far: Vector3 = Vector3.ZERO
## Whether this journey is climbing up (base->top) or down (top->base) —
## needed because climb_waypoints' path isn't symmetric (see its own
## header); the climb must be walked in the right order, not just
## between the right two points.
var _ladder_going_up: bool = true
var _ladder_final_destination: Vector3 = Vector3.ZERO

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

	# Ladders are a grounded-only mechanic (see Ladder) — a flying unit
	# already has unrestricted vertical movement and never needs one, so
	# this check is skipped entirely for a flying mover rather than
	# needing its own flying-awareness.
	if not _owner.is_flying():
		var route: Dictionary = Ladder.find_route(_owner, destination)
		if not route.is_empty():
			if route.affordable:
				return _begin_ladder_journey(route, destination)
			# Can't afford the full climb this turn (see Ladder.
			# find_route/required_move — checked as a hard precondition,
			# never clamped/attempted-and-stranded) — walk toward the
			# ladder's near point as far as ordinary budget allows, but
			# never start the climb itself. Matches
			# movement_indicator.gd's preview exactly: never shows or
			# attempts a climb that won't complete.
			return _start_walk(route.near, budget)

	return _start_walk(destination, budget)


## Plans a route to raw_destination within budget and starts walking it —
## the shared "plan then execute" core move_to() itself uses for an
## ordinary move, and each walking leg of a ladder journey (see
## _begin_ladder_journey/_on_climb_finished) reuses identically, so a
## ladder's walking legs are governed by the exact same budget-truncation/
## terrain-cost rules as any other move.
func _start_walk(raw_destination: Vector3, budget: float) -> bool:
	var flying: bool = _owner.is_flying()
	var query_destination: Vector3 = raw_destination
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


## Stage 1 of a ladder journey — see Ladder.find_route for `route`'s
## shape. Already confirmed affordable IN FULL (walk + climb together)
## before this is ever called (see move_to), so this walk is guaranteed
## to complete without being cut short by budget — passing move_remaining
## itself as the budget (rather than INF) keeps this consistent with
## every other walk's budget accounting regardless, belt-and-suspenders
## rather than relying purely on that guarantee.
##
## Returns whether the journey actually started — move_to() forwards this
## as its own return value. _start_walk can legitimately fail here for
## two very different reasons that must NOT be treated the same way:
## already standing at (or effectively at) route.near — the common case
## right after climbing UP, since the very next thing a player often does
## is immediately try to climb back DOWN from essentially that same
## spot — versus route.near being genuinely unreachable. The first isn't
## a failure at all, it just means there's no walk needed before
## climbing; skip straight to stage 2. Confirmed as a real, reproducible
## bug, not a hypothetical: before this distinction existed, the "already
## there" case silently left _ladder_stage stuck at 1 forever — nothing
## was ever going to advance it, since physics_process()'s own
## "reached the end" check (which is what would normally notice and
## chain into the climb) never runs at all while _moving is false — so
## the unit stood frozen while move_to() had already told its caller the
## move succeeded. That's exactly "can climb up but can't come back
## down": climbing up starts from somewhere genuinely far from the base,
## so the walk is real; climbing down starts from right where the unit
## is already standing after the climb up, hitting this exact case.
func _begin_ladder_journey(route: Dictionary, final_destination: Vector3) -> bool:
	_ladder = route.ladder
	_ladder_far = route.far
	_ladder_final_destination = final_destination
	_ladder_going_up = route.going_up

	if _owner.global_position.distance_to(route.near) <= _owner.arrival_tolerance:
		_ladder_stage = 2
		_climb_ladder()
		return true

	if _start_walk(route.near, _owner.move_remaining if CombatManager.in_combat else INF):
		_ladder_stage = 1
		return true

	_ladder = null
	return false


## Stage 2 — the actual climb. Bypasses move_and_slide() entirely, the
## same technique MoveCasterEffect/KnockbackEffect already use for Jump/
## Shove — a climb isn't a walk order, it shouldn't path around anything.
## Spends required_move atomically, all at once (already confirmed
## affordable in full back in move_to/find_route) — not measured or
## re-derived here, matching this ladder's own "no partial climb"
## contract.
##
## Animates through Ladder.climb_waypoints (up to 3 points: base, an
## intermediate straight-up point, top), NOT a bare start-to-destination
## lerp — a single diagonal line between an outside-the-geometry point
## and an inset one can cut straight through whatever solid corner sits
## between them (confirmed, reproduced — see that function's own
## header). climb_waypoints always computes base-to-top order and gets
## reversed here for a descent — NOT recomputed from _owner's actual
## current position — because the path's shape depends on which end is
## genuinely outside the geometry (always the base), not on which
## direction happens to be first; see climb_waypoints' header for the
## real, reproduced bug that came from getting this backwards.
## Ladder.find_route already validated this exact route via
## _climb_path_is_clear before this journey was ever allowed to begin,
## so this is playing back an already-confirmed-safe path, not hoping it
## happens to be clear. Each segment's duration is proportional to its
## own share of the total distance, so a long vertical climb with a
## short horizontal step at the top doesn't spend equal time on both.
func _climb_ladder() -> void:
	var ladder: Ladder = _ladder

	_owner.begin_busy()
	if CombatManager.in_combat:
		_owner.spend_move(ladder.required_move)

	var waypoints: PackedVector3Array = Ladder.climb_waypoints(ladder.base_position(), ladder.top_position())
	if not _ladder_going_up:
		waypoints.reverse()
	if waypoints.size() < 2:
		# Degenerate ladder (base and top coincide) — nothing to actually
		# animate.
		_on_climb_finished.call_deferred()
		return

	var total_dist: float = 0.0
	for i in range(1, waypoints.size()):
		total_dist += waypoints[i - 1].distance_to(waypoints[i])

	var tween: Tween = _owner.create_tween()
	for i in range(1, waypoints.size()):
		var seg_start: Vector3 = waypoints[i - 1]
		var seg_end: Vector3 = waypoints[i]
		var seg_dist: float = seg_start.distance_to(seg_end)
		var seg_duration: float = ladder.climb_duration * (seg_dist / total_dist) if total_dist > 0.001 else ladder.climb_duration
		tween.tween_method(
			func(t: float): _owner.global_position = seg_start.lerp(seg_end, t),
			0.0, 1.0, seg_duration
		)
	tween.finished.connect(_on_climb_finished)


## Stage 3 — walk from the ladder's far point toward the real destination,
## using whatever move_remaining is left after the climb. This leg is
## ordinary movement in every sense (can fall short of the real
## destination, same ARRIVAL_SLACK/budget rules as any other move) — the
## "no partial movement" guarantee only ever protected the climb itself,
## not the rest of the turn's movement.
func _on_climb_finished() -> void:
	_owner.end_busy()
	_ladder_stage = 3
	_ladder = null
	var final_destination: Vector3 = _ladder_final_destination

	if not _start_walk(final_destination, _owner.move_remaining if CombatManager.in_combat else INF):
		# Nothing left to walk (already there, or no valid path onward) —
		# the journey still completed successfully; emit completion
		# directly instead of waiting on a walk leg that was never going
		# to start.
		_ladder_stage = 0
		_owner.movement_finished.emit(_owner)
		_owner.notify_movement_idle_check()


## Cancels the current move order in place, still spending whatever
## distance was actually covered (combat only).
func stop_moving() -> void:
	if not _moving:
		return
	_finish_move()


## Immediate, raw stop with NO signal emission and NO budget spend —
## called via Unit.force_stop_movement() by UnitDeath.handle_death(): a
## dying unit shouldn't fire movement_finished or charge itself for a
## move it's not actually completing, it's just being silenced. Distinct
## from stop_moving(), which goes through the normal _finish_move() flow
## deliberately.
func force_stop() -> void:
	_moving = false
	_owner.velocity = Vector3.ZERO
	_current_path = PackedVector3Array()
	_path_index = 0
	_ladder_stage = 0
	_ladder = null


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

	# Needed both for the spend calculation below AND to decide whether a
	# ladder journey's walking leg may chain into its next stage (see
	# below) — an organically-completed leg chains, one cut short
	# (stuck_timeout, or a manual stop_moving() mid-route) aborts the
	# ladder journey cleanly instead of climbing from wherever it
	# happened to stop.
	var completed_fully: bool = _path_index >= _current_path.size()

	if CombatManager.in_combat:
		# The plan completed fully (walked every point) → charge its
		# exact known cost, not a re-measurement — that cost IS what was
		# spent, by construction, since nothing deviated from the plan.
		# Cut short instead → fall back to actually-measured PHYSICAL
		# displacement, since in that abnormal case the plan and reality
		# genuinely diverged. That fallback under-charges if the
		# cut-short portion crossed difficult terrain — same "rare
		# last-resort path, not the normal case" trade-off as every other
		# use of stuck_timeout in this file, not worth chasing exactly.
		var spent: float = _planned_cost if completed_fully else _move_start_position.distance_to(_owner.global_position)
		_owner.spend_move(spent)

	_current_path = PackedVector3Array()
	_path_index = 0
	_planned_cost = 0.0

	if _ladder_stage == 1 and completed_fully:
		# Reached the ladder's base/top — the walking leg is done, but
		# this ISN'T the end of the overall move yet, so movement_finished
		# doesn't fire here; the climb (stage 2) picks up immediately.
		_ladder_stage = 2
		_climb_ladder()
		return

	if _ladder_stage != 0:
		# Either stage 3 (the walk after climbing) finished — completed
		# fully or not, same "may fall short" rule as any other move — or
		# stage 1 got cut short and the journey is aborting cleanly.
		_ladder_stage = 0
		_ladder = null

	_owner.movement_finished.emit(_owner)
	# _moving just flipped to false above — is_busy()'s answer may have
	# changed as a result, but UnitActionState has no way to learn that
	# on its own (is_moving() is polled, not pushed), so this explicitly
	# tells it to re-check.
	_owner.notify_movement_idle_check()


## Sets flight_target_altitude directly, clamped to the valid flight
## envelope (see NavigationGrid.FLIGHT_MIN_ALTITUDE/FLIGHT_CEILING_HEIGHT)
## — called every frame from movement_indicator.gd's Ctrl-drag altitude
## control while this unit is the active, flying unit. Doesn't move the
## unit itself; only changes where its NEXT move_to() call will aim for.
func set_flight_altitude(altitude: float) -> void:
	_owner.flight_target_altitude = clamp(
		altitude,
		NavigationGrid.FLIGHT_MIN_ALTITUDE,
		NavigationGrid.FLIGHT_CEILING_HEIGHT
	)


## Forces this unit out of the air by removing every status currently
## granting it flight — used by IncapacitateBehavior so Sleep/Stun/
## Paralysis (anything built from it) knocks a flying unit down instead
## of leaving it hovering, unreachable, indefinitely for the rest of the
## status's duration. Deliberately doesn't call land() itself: removing
## the status is what fires ForceLandOnExpireBehavior.on_remove() (see
## statuses/flying.tres), the exact same landing logic a voluntary Land
## cast already goes through — one landing implementation, not two.
func ground_if_flying() -> void:
	for effect in _owner.flight_granting_statuses():
		_owner.remove_status(effect)


## Descends this unit straight down onto whatever solid ground is
## directly below it, eased via Tween over a duration scaled by descent
## distance (see Unit.vertical_speed) rather than a fixed time or an
## instant teleport (same TRANS_SINE/EASE_IN_OUT curve GrantFlightEffect
## uses for takeoff, so the two read as one consistent motion language)
## — called by ForceLandOnExpireBehavior the instant the Flying status is
## removed, whether that's a voluntary Land ability, the status's own
## duration running out, or IncapacitateBehavior force-removing it
## (Sleep/Stun/Paralysis on a flying unit). Deliberately the same landing
## regardless of caller — a graceful descent even when knocked out isn't
## fully realistic, but a single shared animation is worth more than
## relitigating tone per call site; revisit only with a concrete reason.
## Same begin_busy()/Tween/end_busy() shape _climb_ladder() above already
## uses — this bypasses the path-following system entirely too, for the
## same reason: a landing isn't a walk order, it shouldn't path around
## anything.
##
## A physics raycast rather than a NavigationGrid lookup: landing needs
## the true physical surface directly beneath this exact XZ position, not
## the nearest VALID cell (which could be meters off to the side) — a
## raycast is the right tool for "what's physically underneath me,"
## independent of grid resolution. Excludes every unit (not just self)
## from the raycast since ground and unit collision share collision_layer
## 1 by default in this project (see indicator_base.gd) — otherwise
## landing directly above an ally would land ON them instead of the
## ground beneath them.
func land() -> void:
	var exclude: Array[RID] = []
	for node in _owner.get_tree().get_nodes_in_group("units"):
		if node is Unit:
			exclude.append(node.get_rid())

	var space_state := _owner.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(_owner.global_position, _owner.global_position + Vector3.DOWN * 200.0)
	query.exclude = exclude
	var result: Dictionary = space_state.intersect_ray(query)

	if result.is_empty():
		# Flew out over a genuine void with nothing below — left exactly
		# where it is rather than guessing at a fallback position. A
		# known limitation (see this project's flight-design notes), not
		# a crash.
		SystemLog.print("%s has nowhere to land." % LogFormat.unit_name(_owner))
		return

	var descent: float = absf(_owner.global_position.y - result.position.y)
	var duration: float = clampf(descent / _owner.vertical_speed, _owner.min_land_duration, _owner.max_land_duration)

	_owner.begin_busy()
	var tween: Tween = _owner.create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_owner, "global_position:y", result.position.y, duration)
	tween.finished.connect(_owner.end_busy)
	SystemLog.print("%s lands." % LogFormat.unit_name(_owner))

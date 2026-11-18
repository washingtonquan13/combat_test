class_name UnitMovement
extends RefCounted
## Owns path-following movement for ONE unit — deterministic
## plan-then-execute: NavigationGrid.find_path() (see that file) already
## returns a route that avoids every other living unit's footprint AND
## real level geometry, for both grounded and flying movement over one
## shared grid, so move_to() has nothing left to decide about avoidance —
## it just walks the fixed result. This file's header history: an earlier
## version used a custom potential-field steering pass (path_avoidance.gd
## — that planner has since been deleted from that file entirely, having
## reached zero real callers; see its own header) to fake unit-avoidance
## on top of a navmesh that didn't know about units at all; a version
## after that tried Godot's live NavigationAgent3D RVO avoidance instead,
## also reverted; the navmesh itself was replaced by NavigationGrid after
## repeated bake/sync bugs (see that file's own header) — this is
## turn-based with only ONE unit ever moving at a time, so there's no
## reciprocal multi-agent negotiation to do, just one mover against
## momentarily-static obstacles.
##
## Once the route itself is already avoidance-correct, all move_to() has
## left to do is turn it into a budget-aware walking plan — see
## RoutePlanner.plan, which truncates the route to fit `budget` and
## integrates terrain cost (Surface.movement_cost_multiplier) along the
## way. The movement preview gets its route from preview_route() here,
## which makes move_to()'s own route choice (ladder branch included) over
## the same planner, so preview and real move can't disagree.
##
## move_speed/radius/avoidance_margin/arrival_tolerance/stuck_timeout all
## stay directly on Unit rather than moving in here — the @export ones for
## the same editor-safety reasoning as UnitFacing's rotation_speed (the
## Inspector needs to read/write them before this component exists), and
## radius specifically because it's read directly by code well outside
## movement entirely (combat targeting, area effects). This component
## reads all of them back through its owner reference.
##
## Can't set velocity/global_position on itself — a RefCounted has no
## physics body or transform at all — so the physics step, like
## UnitFacing's rotation methods, writes to _owner directly rather than
## being fully self-contained. A grounded body is placed (see
## _keep_to_ground): NavigationGrid is the one judge of where it can
## stand. Only a flier still moves by _owner.move_and_slide().

## Same "authored global rule, reached by a preload const" idiom
## UnitCombat.ALTITUDE_ADVANTAGE already uses — see FlightRules' own
## header for why altitude's cost side is data rather than a hardcoded
## constant.
const FLIGHT_RULES: FlightRules = preload("res://data/flight_rules.tres")

var _owner: Unit

## Read once from ProjectSettings rather than re-fetched every physics
## frame — same default (physics/3d/default_gravity, 9.8) every
## CharacterBody3D in Godot uses out of the box. Only applied to a
## grounded (non-flying) unit, by _keep_to_ground, when it stands higher
## over its grid ground than a walk follows (a stacked spawn, a knockback,
## a despawning platform): it falls there rather than hanging in the air
## with no support cell for NavigationGrid to path across.
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

var _moving: bool = false
## The tween carrying the body through the air, if one is (carry_tween).
var _carrier: Tween = null
var _crawl_pose: CrawlPose = null
## Whether the route being walked was planned for a crawler. Neither body
## can walk the other's route, so a change mid-walk ends the walk.
var _route_crawls: bool = false
## Where a crawler last had hold of a wall: how far it falls if it lets go.
var _hold_height: float = NAN
var _stuck_timer: float = 0.0
var _last_progress_position: Vector3 = Vector3.ZERO

## A ladder climb is part of the route, not a separate stage: points
## _climb_first.._climb_last of _current_path are reached by climbing
## (see Ladder and _ladder_route), -1 when the route has none. While the
## next point is one of them the unit is climbing (is_climbing): no
## gravity, no move_and_slide, Ladder.climb_speed, facing the ladder.
## The climb costs no move budget (BG3's rule — only the walk to the
## near end is paid) and is atomic: an order given mid-climb waits at
## the far end (_after_climb) rather than leaving the unit on the rungs.
var _climb_first: int = -1
var _climb_last: int = -1
var _climb_speed: float = 0.75
## The ladder's own facing (Ladder.facing) — toward the rungs, both ways
## (a unit climbs down facing them too), and defined for a purely
## vertical ladder whose ends share an XZ.
var _climb_facing: Vector3 = Vector3.ZERO
## An order given while climbing: {destination, ignore}, run by
## _finish_move once the far end is reached. Empty when none.
var _after_climb: Dictionary = {}
## The ladder the route climbs, null when it has none. One climber at a
## time (Ladder.climber): the walk holds short of the near end while
## someone else is on it, and claims it on stepping onto the rungs.
var _climb_ladder: Ladder = null
## Whether the climb goes up the ladder (false: down). With _climb_first
## it names the legs of Ladder.climb_waypoints: the two over the top
## edge are the targets at _climb_first + 2 and + 3 either way.
var _climb_up: bool = true
## The tolerance a climb point is reached within — tight, because the
## points are the corner of the landing, and arriving early cuts it.
const CLIMB_ARRIVAL: float = 0.01
## The tolerance the end is reached within while a stop lands the unit on
## it (UnitLocomotion.lands): the stop's own last step puts it there.
const LANDED: float = 0.005
## A surface facing up less than this needs holding on to. Steeper floors
## than the walkable limit count, so a crawler never slides off a ramp.
const CLING_BELOW: float = 0.7

## The exact route this unit is currently walking, and which point in it
## is next. Planned ONCE, in full, before movement starts (see move_to /
## RoutePlanner.plan) — nothing about avoidance is decided live while
## walking; physics_process just follows these fixed points.
var _current_path: PackedVector3Array = PackedVector3Array()
## RoutePlanner's cumulative cost along _current_path, kept for
## current_route() (the committed line movement_indicator.gd draws).
var _current_cost: PackedFloat32Array = PackedFloat32Array()
var _path_index: int = 0
## The planned path's exact total BUDGET COST — not necessarily its
## physical length; the two only diverge while crossing difficult
## terrain (see Surface.movement_cost_multiplier) — computed once when
## the plan is made. Spent as this turn's move budget on a normal
## completion (see _finish_move) rather than re-measuring distance
## walked, since a precomputed, deterministically-followed plan is
## authoritative by construction.
var _planned_cost: float = 0.0

## preview_route()'s cache of its last find_path() query — see that
## function. Only the search is cached; RoutePlanner.plan() re-runs.
var _preview_cached: bool = false
var _preview_flying: bool = false
var _preview_crawling: bool = false
var _preview_start_cell: Vector3i
var _preview_dest_cell: Vector3i
var _preview_waypoints: PackedVector3Array = PackedVector3Array()
## The grid's occupancy version and the ignore list the cached search
## saw: a unit moving, dying or appearing changes the version, so the
## cache can never show a route around (or through) where units were.
var _preview_occupancy_version: int = -1
var _preview_ignore: Array = []

## The ignore list of the journey in flight, so a ladder journey's later
## walking legs avoid the same units its first leg did.
var _move_ignore: Array = []

## How fast a grounded body falls right now (m/s, down); 0 on the ground.
var _fall_speed: float = 0.0


func _init(owner: Unit) -> void:
	_owner = owner


func is_moving() -> bool:
	return _moving


## Whether the unit is on a ladder right now — its next point is a climb
## point. Still is_moving(): the climb is part of the move.
func is_climbing() -> bool:
	return _moving and _climb_first >= 0 and _path_index >= _climb_first and _path_index <= _climb_last


func climbing_ladder() -> Ladder:
	return _climb_ladder if is_climbing() else null


## Which way the unit is going on the rungs right now: 1 up, -1 down, 0
## when it isn't climbing, is stepping on or off a level leg, or is
## climbing over the top edge (climbing_over).
func climb_direction() -> int:
	if not is_climbing() or climbing_over() != 0:
		return 0
	var rise: float = _current_path[_path_index].y - _owner.global_position.y
	if absf(rise) < 0.01:
		return 0
	return 1 if rise > 0.0 else -1


## The speed of the climb being made (Ladder.climb_speed), m/s.
func climb_speed() -> float:
	return _climb_speed


## 1 while climbing over the top edge onto the landing, -1 while getting
## on from it, 0 otherwise: the two legs between the last rungs
## (Ladder.OVER_RUNGS below the landing) and the step off, which one
## clip covers.
func climbing_over() -> int:
	if not is_climbing() or (_path_index != _climb_first + 2 and _path_index != _climb_first + 3):
		return 0
	return 1 if _climb_up else -1


## How long the climb over the top edge takes: both its legs at
## climb_speed. The clip is played to fit it.
func climb_over_seconds() -> float:
	if _climb_first < 0:
		return 0.0
	var p: PackedVector3Array = _current_path
	var length: float = p[_climb_first + 1].distance_to(p[_climb_first + 2]) 			+ p[_climb_first + 2].distance_to(p[_climb_first + 3])
	return length / _climb_speed


## The height the rungs climb end at (Ladder.climb_waypoints' stop):
## the climbing loop is phased from here, so its cycle meets the clip
## over the top at its first frame.
func climb_stop_height() -> float:
	if _climb_first < 0:
		return _owner.global_position.y
	return _current_path[_climb_first + (1 if _climb_up else 3)].y


## The route being walked, whole (start to destination, as planned at
## the order), in preview_route()'s shape; empty while not walking.
func current_route() -> Dictionary:
	if not _moving or _current_path.size() < 2:
		return {}
	return {"path": _current_path, "cumulative_cost": _current_cost}


## Budget cost of the current route walked so far; 0 while not walking.
## For displays only: the budget itself is still charged once, at the
## end (_finish_move), so nothing that reads move_remaining changes.
func cost_walked() -> float:
	if not _moving or _path_index < 1 or _current_cost.size() != _current_path.size():
		return 0.0
	var i: int = mini(_path_index, _current_path.size() - 1)
	var from: Vector3 = _current_path[i - 1]
	var to: Vector3 = _current_path[i]
	var length: float = from.distance_to(to)
	var t: float = 1.0
	if length > 0.0:
		t = clampf(1.0 - _owner.global_position.distance_to(to) / length, 0.0, 1.0)
	return lerpf(_current_cost[i - 1], _current_cost[i], t)


## Orders this unit toward destination — see this file's header for the
## deterministic plan-then-execute rationale. Out of combat, budget is
## effectively unlimited. In combat: only CombatManager.current_unit may
## move, and the plan is truncated at exactly move_remaining — see
## RoutePlanner.plan. Occupancy is always current: the grid checks it
## against the live units on every query (see NavigationGrid). Every other
## unit is avoided except those in `ignore` — a group moving together
## passes itself, so members don't route around where the others are
## about to leave.
func move_to(destination: Vector3, ignore: Array = []) -> bool:
	# can_be_commanded(), not can_act(): a unit that is already walking is
	# precisely when the player most wants to say something else. can_act()
	# counts walking as busy, so opening with it meant every click during a
	# walk was refused and silently dropped — no redirect, no cancel, no
	# feedback, just a unit finishing an order the player had changed their
	# mind about.
	if not _owner.can_be_commanded() or _owner.is_rooted():
		return false

	# Never left on the rungs: an order given mid-climb ends the current
	# route at the ladder's far end and runs from there.
	if is_climbing():
		_after_climb = {"destination": destination, "ignore": ignore}
		_end_route_at_climb_end()
		return true

	var budget: float = INF

	# Turn order binds a unit only while it is actually IN a fight. A unit
	# standing outside one moves freely even while a battle rages nearby —
	# which is what makes walking a straggler into an ambush possible.
	if _owner.in_combat():
		if not _owner.is_my_turn():
			return false
		# What is left once the move in flight is charged for the distance
		# walked so far, which replacing it below does.
		budget = _owner.move_remaining - cost_walked()
		if budget <= 0.0:
			return false

	# Planned before the order in flight is touched: an order that can't
	# start (nowhere to stand, no way there) leaves the unit doing what it
	# was doing, rather than standing still mid-stride with a walk nobody
	# ended.
	var planned: Dictionary = plan_route(destination, budget, ignore)
	if (planned.path as PackedVector3Array).size() < 2:
		return false

	# The order in flight is REPLACED, not queued behind. Ended without
	# announcing, since it did not finish — but still charged for the
	# distance actually walked, which _finish_move already measures for a
	# move cut short rather than trusting the abandoned plan's cost.
	if _moving:
		_finish_move(false)
	_move_ignore = ignore
	return _begin_route(planned)


## The route move_to(raw_destination) would walk, cut at budget, WITHOUT
## starting it — the one route query, so whatever asks "can I get there
## and what does it cost" (the AI scorer, any behavior pricing a move)
## gets the answer the move itself acts on, ladders included.
##
## Ladders are a grounded-only mechanic (see Ladder) — a flier already has
## unrestricted vertical movement, so it never looks for one. A ladder
## journey the budget can't reach the top of is never planned (the climb
## is atomic, see Ladder.required_move): the route is the walk toward the
## near end instead, as far as budget goes.
##
## budget defaults to INF — a bare route/cost query has no inherent
## budget of its own; move_to() passes move_remaining in combat.
func plan_route(raw_destination: Vector3, budget: float = INF, ignore: Array = []) -> Dictionary:
	if _crawls():
		return _plan_waypoints(_crawl_waypoints(raw_destination, ignore), budget, false)
	if not _owner.is_flying():
		var route: Dictionary = Ladder.find_route(_owner, raw_destination, ignore)
		if not route.is_empty():
			if _climb_affordable(route, budget):
				return _ladder_route(route, budget - _climb_end_cost(route))
			return _direct_route(route.near, budget, ignore)
	return _direct_route(raw_destination, budget, ignore)


## A flier uses its wings, not its feet.
func _crawls() -> bool:
	return _owner.can_crawl() and not _owner.is_flying()


func _crawl_waypoints(destination: Vector3, ignore: Array) -> PackedVector3Array:
	return NavigationGrid.find_crawl_path(_owner.get_tree(), _owner.global_position, destination, _owner, ignore)


## plan_route()'s walked case: find_path() and RoutePlanner, nothing else.
func _direct_route(raw_destination: Vector3, budget: float, ignore: Array) -> Dictionary:
	var flying: bool = _owner.is_flying()
	var query_destination: Vector3 = _query_destination(raw_destination)
	var waypoints: PackedVector3Array = NavigationGrid.find_path(_owner.get_tree(), _owner.global_position, query_destination, _owner, flying, ignore)
	return _plan_waypoints(waypoints, budget, flying)


## What a ladder journey has cost by the time the unit stands at the far
## end: the walk to the near end plus the ladder's required_move.
static func _climb_end_cost(route: Dictionary) -> float:
	return _route_end_cost(route.near_planned) + route.ladder.required_move


## Whether budget covers getting up (or down) the whole ladder — one hard
## precondition, never clamped into a climb that stops on the rungs.
static func _climb_affordable(route: Dictionary, budget: float) -> bool:
	return budget >= _climb_end_cost(route)


## The point find_path() is actually asked to reach for raw_destination.
## A grounded unit goes exactly where it was sent. A flier takes XZ from
## wherever was clicked and Y from the pilot's own target altitude (see
## Unit.flight_target_altitude), not the clicked point's Y — a ground
## click always resolves near y=0, which isn't where a flying unit is
## headed. find_path() does a genuine 3D search between the unit's real
## current position and this point, so the returned route already
## climbs/descends around real obstacles at each height — no separate
## "bake at one height, then reinterpret Y along XZ progress" step needed.
## Shared by plan_route() and preview_route() so the two can't ask for
## different destinations.
func _query_destination(raw: Vector3) -> Vector3:
	var query: Vector3 = raw
	if _owner.is_flying():
		var altitude: float = _owner.flight_target_altitude
		# The floor is looked up from the altitude, or from the hovered
		# point when the altitude is below it: an altitude under ground
		# the cursor is on lies inside the terrain, where the floor found
		# is a hollow pocket no search can reach.
		query.y = clamp_flight_altitude(altitude, Vector3(raw.x, maxf(altitude, raw.y), raw.z), _owner)
	return query


## altitude clamped to the valid flight envelope - the one copy of that
## rule, shared by the move query, set_flight_altitude, takeoff, the AI
## and the router's altitude plane (IdleIntent.clamp_height), so the plane
## the player sees is the altitude the flier will take. The floor is
## relative: FLIGHT_MIN_ALTITUDE above the ground under `at`
## (NavigationGrid.flight_floor_at), so a flier can drop into a pit as far
## as it can hover over y=0 ground. With no `at` (the plane, which has no
## one XZ) it is the lowest the world allows, and the move query lifts to
## the floor at its own destination. The ceiling is relative the same way
## (NavigationGrid.flight_ceiling_at, FLIGHT_MAX_ALTITUDE over the same
## ground), so a rooftop gets the same band as y=0; with no `at` it is the
## highest the world allows.
static func clamp_flight_altitude(altitude: float, at: Variant = null, world_ref: Node = null) -> float:
	var tree := Engine.get_main_loop() as SceneTree
	var floor_y: float
	var ceiling_y: float
	if at == null:
		floor_y = NavigationGrid.flight_lowest_altitude(tree, world_ref)
		ceiling_y = NavigationGrid.flight_highest_altitude(tree, world_ref)
	else:
		floor_y = NavigationGrid.flight_floor_at(tree, at, world_ref)
		ceiling_y = NavigationGrid.flight_ceiling_at(tree, at, world_ref)
	return clampf(altitude, floor_y, ceiling_y)


## RoutePlanner.plan() over find_path()'s waypoints, with the flier's
## vertical cost multipliers — the one budget/cost step plan_route() and
## preview_route() share. Vertical multipliers are only ever non-default
## (1.0/1.0) for a flying mover — see FlightRules's own header. A
## grounded unit's route is billed identically to before they existed,
## since RoutePlanner.plan()'s defaults are a strict no-op.
func _plan_waypoints(waypoints: PackedVector3Array, budget: float, flying: bool) -> Dictionary:
	if waypoints.size() < 2:
		return {"path": PackedVector3Array(), "cumulative_cost": PackedFloat32Array()}
	var ascend_multiplier: float = FLIGHT_RULES.ascend_cost_multiplier if flying else 1.0
	var descend_multiplier: float = FLIGHT_RULES.descend_cost_multiplier if flying else 1.0
	return RoutePlanner.plan(waypoints, budget, SurfaceManager.cost_sampler(_owner), ascend_multiplier, descend_multiplier)


## The route move_to(dest) would take, planned in full rather than cut at
## move_remaining — for the movement preview, which draws the in-budget
## part and the rest in different colours from the returned
## cumulative_cost. Makes the same choice move_to() does, in the same
## order: a grounded unit headed for a ladder end gets the ladder journey
## (or, when the climb is unaffordable, only the walk toward the near end
## — never a climb the move won't perform); anything else gets
## plan_route()'s query. Truncating this at move_remaining gives the
## route move_to() walks, since RoutePlanner.plan() cuts the same path.
##
## Returns {path, cumulative_cost} — RoutePlanner.plan()'s shape; an
## empty path when there is no route.
##
## Called every frame while the preview is live, so the A* search is
## cached by (start cell, destination cell, flying, occupancy version,
## ignore) — the mouse sitting still is the common case, and any unit
## moving changes the version. RoutePlanner.plan() re-runs every call: a
## cheap linear walk, and it keeps terrain cost live.
func preview_route(dest: Vector3, ignore: Array = []) -> Dictionary:
	var crawling: bool = _crawls()
	if not _owner.is_flying() and not crawling:
		var route: Dictionary = Ladder.find_route(_owner, dest, ignore)
		if not route.is_empty():
			return _preview_ladder_route(route, ignore)

	var flying: bool = _owner.is_flying()
	var query_destination: Vector3 = _query_destination(dest)
	var start_cell: Vector3i = NavigationGrid.world_to_cell(_owner.global_position, _owner)
	var dest_cell: Vector3i = NavigationGrid.world_to_cell(query_destination, _owner)
	var version: int = NavigationGrid.occupancy_version(_owner.get_tree(), _owner)
	if not (
		_preview_cached
		and flying == _preview_flying
		and crawling == _preview_crawling
		and start_cell == _preview_start_cell
		and dest_cell == _preview_dest_cell
		and version == _preview_occupancy_version
		and ignore == _preview_ignore
	):
		_preview_waypoints = _crawl_waypoints(query_destination, ignore) if crawling else NavigationGrid.find_path(_owner.get_tree(), _owner.global_position, query_destination, _owner, flying, ignore)
		_preview_cached = true
		_preview_flying = flying
		_preview_crawling = crawling
		_preview_start_cell = start_cell
		_preview_dest_cell = dest_cell
		# find_path may itself have rebuilt occupancy; read the version it used.
		_preview_occupancy_version = NavigationGrid.occupancy_version(_owner.get_tree(), _owner)
		_preview_ignore = ignore.duplicate()

	return _plan_waypoints(_preview_waypoints, INF, flying)


## preview_route()'s ladder branch — see Ladder.find_route for `route`'s
## shape. Uncut, but making plan_route()'s choice at the real budget: when
## move_to() would only walk toward the near end, that walk is all there
## is to show.
func _preview_ladder_route(route: Dictionary, ignore: Array) -> Dictionary:
	if not _climb_affordable(route, _owner.move_budget()):
		return route.near_planned
	return _ladder_route(route, INF)


## The one route over a whole ladder journey, walked by move_to and drawn
## by the preview: the walk to the near end, the climb, then the walk from
## the far end to the destination, cut at tail_budget. Returns RoutePlanner's
## {path, cumulative_cost} plus climb_first/climb_last/climb_speed/
## climb_facing for _begin_route.
##
## The climb is Ladder.climb_waypoints (reversed for a descent), not a
## straight near-to-far line — the clipping bug that function's header
## describes. Its first point is the near end itself, so the unit settles
## onto the exact foot of the ladder before going up rather than climbing
## from wherever the walk's arrival_tolerance let it stop. It adds no
## cost but the ladder's required_move, charged at the far end.
func _ladder_route(route: Dictionary, tail_budget: float) -> Dictionary:
	var ladder: Ladder = route.ladder
	var path: PackedVector3Array = route.near_planned.path.duplicate()
	var cost: PackedFloat32Array = route.near_planned.cumulative_cost.duplicate()
	var walk_cost: float = _route_end_cost(route.near_planned)

	var climb_points: PackedVector3Array = Ladder.climb_waypoints(ladder.base_position(), ladder.top_position())
	if not route.going_up:
		climb_points.reverse()
	var climb_first: int = path.size()
	for i in climb_points.size():
		path.append(climb_points[i])
		cost.append(walk_cost + (ladder.required_move if i == climb_points.size() - 1 else 0.0))
	var climb_last: int = path.size() - 1
	var climbed_cost: float = cost[climb_last]

	# The tail is grounded (ladders are grounded-only), found by
	# Ladder.find_route from the far end, and the only leg the budget can
	# cut short.
	var tail_waypoints: PackedVector3Array = route.tail_waypoints
	if tail_waypoints.size() >= 2 and tail_budget > 0.0:
		var tail: Dictionary = _plan_waypoints(tail_waypoints, tail_budget, false)
		for i in range(1, tail.path.size()):
			path.append(tail.path[i])
			cost.append(climbed_cost + tail.cumulative_cost[i])

	return {
		"path": path,
		"cumulative_cost": cost,
		"climb_first": climb_first,
		"climb_last": climb_last,
		"climb_speed": ladder.climb_speed,
		"climb_facing": ladder.facing(),
		"climb_up": route.going_up,
		"ladder": ladder,
	}


static func _route_end_cost(planned: Dictionary) -> float:
	var cost: PackedFloat32Array = planned.cumulative_cost
	return cost[cost.size() - 1] if cost.size() > 0 else 0.0


## Starts walking `planned` — RoutePlanner's {path, cumulative_cost}, or
## _ladder_route's, whose climb_* keys mark the climb inside it. Every move
## goes through here, so a ladder journey is one move: one
## movement_started, one movement_finished, one current_route() the line,
## the destination ring and the Move bar all read the whole way.
func _begin_route(planned: Dictionary) -> bool:
	var planned_path: PackedVector3Array = planned.path
	if planned_path.size() < 2:
		return false

	_current_path = planned_path
	_current_cost = planned.cumulative_cost
	_path_index = 1
	_planned_cost = _route_end_cost(planned)
	_climb_first = planned.get("climb_first", -1)
	_climb_last = planned.get("climb_last", -1)
	_climb_speed = planned.get("climb_speed", _climb_speed)
	_climb_facing = planned.get("climb_facing", Vector3.ZERO)
	_climb_ladder = planned.get("ladder", null)
	_climb_up = planned.get("climb_up", true)
	_stuck_timer = 0.0
	_last_progress_position = _owner.global_position
	_route_crawls = _crawls()
	_moving = true
	_owner.movement_started.emit(_owner)
	return true


## Cuts the route being walked at the ladder's far end — an order given
## mid-climb (move_to, stop_moving) takes effect there, never on the
## rungs. The budget charged is the route's cost up to that point.
func _end_route_at_climb_end() -> void:
	var end: int = _climb_last + 1
	_current_path = _current_path.slice(0, end)
	_current_cost = _current_cost.slice(0, end)
	_planned_cost = _current_cost[end - 1] if _current_cost.size() >= end else _planned_cost


## Cancels the current move order in place, still spending whatever
## distance was actually covered (combat only).
func stop_moving() -> void:
	if not _moving:
		return
	# Mid-climb the stop lands at the ladder's far end, not on the rungs.
	if is_climbing():
		_after_climb = {}
		_end_route_at_climb_end()
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
	_current_cost = PackedFloat32Array()
	_path_index = 0
	_climb_first = -1
	_climb_last = -1
	_climb_ladder = null
	_after_climb = {}


## A tween to carry the body with: Jump, Shove, takeoff, landing. It runs on
## the physics step, as walking does, and while it runs physics_process
## leaves the body alone, so one thing at a time writes the position.
func carry_tween() -> Tween:
	_carrier = _owner.create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	return _carrier


func physics_process(delta: float) -> void:
	_step(delta)
	# Steering turns the unit during the step, and the tilt is relative to it.
	if _crawl_pose != null:
		_crawl_pose.refit()


func _step(delta: float) -> void:
	var crawling: bool = _crawls()
	if _moving and crawling != _route_crawls:
		stop_moving()
	var clinging: bool = _update_crawl(delta, crawling)
	if _carrier != null and _carrier.is_valid():
		_hold_height = NAN
		return
	if clinging:
		_hold_height = _owner.global_position.y

	var flying: bool = _owner.is_flying()

	# A grounded body stands where the grid says the ground is (see
	# _keep_to_ground), idle or walking: the grid is the one judge of where
	# a body can stand. Physics contact never was a second judge that
	# agreed with it - a capsule slid off faces the grid routed over and
	# lips it let a route step up. Idle, it runs too, so a body set down in
	# the air (a stacked spawn, a vanished platform) falls onto its ground
	# before anyone orders it anywhere. Flying is untouched: altitude there
	# is flight_target_altitude's.
	if not _moving:
		if not flying and not clinging:
			_keep_to_ground(delta)
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
	# A climb point is reached in 3D and almost exactly (CLIMB_ARRIVAL).
	# Never onto a ladder someone else is on: the walk holds short.
	var held: bool = _waiting_for_ladder()
	# A stop landing the unit on its end (UnitLocomotion.lands) carries it
	# onto the point itself: arriving within the tolerance cut it short.
	var animator: UnitAnimator = _owner.animator()
	var lands: bool = animator != null and animator.locomotion != null and animator.locomotion.lands()
	while _path_index < _current_path.size():
		if held and _path_index + 1 >= _climb_first:
			break
		var to_waypoint: Vector3 = _current_path[_path_index] - _owner.global_position
		var climb_point: bool = _climb_first >= 0 and _path_index >= _climb_first and _path_index <= _climb_last
		if not flying and not climb_point and not crawling:
			to_waypoint.y = 0.0
		var tolerance: float = _owner.arrival_tolerance
		if climb_point:
			tolerance = CLIMB_ARRIVAL
		elif lands and _path_index == _current_path.size() - 1:
			tolerance = LANDED
		if to_waypoint.length() > tolerance:
			break
		_path_index += 1

	if _path_index >= _current_path.size():
		_finish_move()
		return

	if held:
		_hold(delta)
		return

	if is_climbing():
		_climb_ladder.claim(_owner)
		_climb_step(delta)
		return

	if crawling:
		_crawl_step(delta)
		return

	if not flying:
		_walk_step(delta)
		return

	# Last-resort safety net for a flier, the one body still moved by
	# move_and_slide — see stuck_timeout's doc comment. Its route is
	# already clear of every unit and solid cell, so this exists only for
	# collision response deviating from the plan.
	if _owner.global_position.distance_to(_last_progress_position) < 0.05:
		_stuck_timer += delta
		if _stuck_timer >= _owner.stuck_timeout:
			_finish_move()
			return
	else:
		_stuck_timer = 0.0
		_last_progress_position = _owner.global_position

	# A flier takes the path's real 3D direction: its planned altitude is
	# in the path's Y, and nothing else would carry it there.
	var direction: Vector3 = (_current_path[_path_index] - _owner.global_position).normalized()
	_owner.face_direction(direction, delta)
	_owner.velocity = direction * _owner.move_speed
	_owner.move_and_slide()


## One frame of a grounded walk: placed directly along the grid's route at
## move_speed, the height from the grid's ground under it (_keep_to_ground),
## never pushed about by physics contact. The route runs a body's clearance
## off every wall and other unit, and only where the grid has ground, so
## nothing is left for collision to decide: a walk the grid planned is a
## walk the body makes.
##
## A body with a locomotion set (UnitLocomotion) says how far instead: its
## loop's own speed, a start's or a stop's own curve, nothing while it turns
## in place (and then it, not the path, turns the unit).
func _walk_step(delta: float) -> void:
	var at: Vector3 = _owner.global_position
	var target: Vector3 = _current_path[_path_index]
	var level := Vector3(target.x - at.x, 0.0, target.z - at.z)
	var run: float = level.length()
	var step: float = _owner.move_speed * delta
	var animator: UnitAnimator = _owner.animator()
	var loco: UnitLocomotion = animator.locomotion if animator else null
	if loco and loco.drives():
		step = loco.travel(delta, remaining_distance())
	if run > 1e-4:
		_owner.face_direction(level / run, delta)
	var next: Vector3 = at + (level if run <= step else level / run * step)
	_owner.velocity = Vector3.ZERO
	_owner.global_position = next
	_keep_to_ground(delta)
	_stuck_timer = 0.0
	_last_progress_position = _owner.global_position


## Metres of route left on the ground, from where the unit stands.
func remaining_distance() -> float:
	if not _moving:
		return 0.0
	var from: Vector3 = _owner.global_position
	var left: float = 0.0
	for i in range(_path_index, _current_path.size()):
		var p: Vector3 = _current_path[i]
		left += Vector2(p.x - from.x, p.z - from.z).length()
		from = p
	return left


## The point `metres` further along the route from where the unit stands
## (its end, if nearer), level with the unit. INF when not moving.
func point_ahead(metres: float) -> Vector3:
	if not _moving or _path_index >= _current_path.size():
		return Vector3.INF
	var from: Vector3 = _owner.global_position
	var left: float = metres
	for i in range(_path_index, _current_path.size()):
		var p: Vector3 = _current_path[i]
		var leg := Vector3(p.x - from.x, 0.0, p.z - from.z)
		var length: float = leg.length()
		if length >= left:
			from = Vector3(from.x, _owner.global_position.y, from.z) + leg / maxf(length, 1e-5) * left
			return from
		left -= length
		from = p
	return Vector3(from.x, _owner.global_position.y, from.z)


## The way the route leaves from where the unit stands, level.
func first_leg() -> Vector3:
	if not _moving or _path_index >= _current_path.size():
		return Vector3.ZERO
	var to: Vector3 = _current_path[_path_index] - _owner.global_position
	return Vector3(to.x, 0.0, to.z).normalized()


## Whether this move is all walked on the ground: no ladder, wall or flight
## in it. Only such a move is shown by the body's locomotion set.
func walks_on_foot() -> bool:
	return _moving and _climb_first < 0 and not _route_crawls and not _owner.is_flying()


## Up or down a slope as fast as the walk climbs it (twice its speed:
## anything up to 63 degrees, past the steepest ground there is), and
## falling under gravity when the ground is further below than that.
const GROUND_FOLLOW_RATE := 2.0

## Brings a grounded body to the grid's ground under it: onto it along a
## slope or a lip, falling onto it when it's further below. A crawler that
## let go pays for its drop on landing.
func _keep_to_ground(delta: float) -> void:
	var at: Vector3 = _owner.global_position
	_owner.velocity = Vector3.ZERO
	var ground: float = _ground_height(at)
	var follow: float = _owner.move_speed * GROUND_FOLLOW_RATE * delta
	if at.y - ground > follow + _fall_speed * delta:
		_fall_speed += _gravity * delta
		_owner.global_position.y = maxf(ground, at.y - _fall_speed * delta)
		if _owner.global_position.y > ground:
			return
	else:
		_owner.global_position.y = move_toward(at.y, ground, maxf(follow, _fall_speed * delta))
	if _owner.global_position.y != ground:
		return
	_fall_speed = 0.0
	if not is_nan(_hold_height):
		ArcFlight.take_fall(_owner, _hold_height - ground)
		_hold_height = NAN


## The ground a body at `at` stands on: the grid's (ground_height_at, the
## top of the first solid cell at or under its feet), which says which
## floor and to within a cell how high, made exact by the face itself
## inside that one cell, so a slope is a slope and not 0.25 m stairs. The
## face is only read inside the grid's cell: it never moves the body onto
## a floor the grid doesn't have.
func _ground_height(at: Vector3) -> float:
	var cell: float = NavigationGrid.CELL_SIZE
	var tree := _owner.get_tree()
	var grid: float = NavigationGrid.ground_height_at(tree, at + Vector3.UP * cell * 0.5, _owner)
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(at.x, grid + cell, at.z), Vector3(at.x, grid - cell, at.z), _owner.collision_mask)
	query.exclude = [_owner.get_rid()]
	var hit: Dictionary = _owner.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position.y if not hit.is_empty() else grid


## Holding on is asked of the surface every tick, never remembered: nothing
## to save, and nothing to go stale when the wall goes or the unit is Downed.
## Returns whether the unit is hanging on (a floor needs no hanging on to).
func _update_crawl(delta: float, crawling: bool) -> bool:
	var normal := Vector3.ZERO
	var surface: Dictionary = {}
	if crawling:
		normal = NavigationGrid.crawl_normal(_owner.get_tree(), _owner.global_position, _owner)
		surface = CrawlPose.true_surface(_owner, _owner.global_position, normal)
		if _crawl_pose == null:
			_crawl_pose = CrawlPose.new(_owner)
	if _crawl_pose != null:
		# The grid's normal decides whether it clings, the true one how it looks.
		_crawl_pose.update(delta, surface.get("normal", Vector3.ZERO), surface.get("gap", 0.0), _crawl_travel(crawling))
	return normal != Vector3.ZERO and normal.y < CLING_BELOW


func _crawl_travel(crawling: bool) -> Vector3:
	if not crawling or not _moving or _path_index >= _current_path.size():
		return Vector3.ZERO
	return (_current_path[_path_index] - _owner.global_position).normalized()



## One frame on a surface, placed directly like a ladder climb: the route
## already runs a body's radius off everything, and it runs where a capsule
## under gravity can't go.
func _crawl_step(delta: float) -> void:
	var target: Vector3 = _current_path[_path_index]
	var to_target: Vector3 = target - _owner.global_position
	var step: float = _owner.move_speed * delta
	_owner.velocity = Vector3.ZERO
	var level := Vector3(to_target.x, 0.0, to_target.z)
	if level.length() > 0.05:
		_owner.face_direction(level.normalized(), delta)
	if to_target.length() <= step:
		_owner.global_position = target
	else:
		_owner.global_position += to_target.normalized() * step
	_stuck_timer = 0.0
	_last_progress_position = _owner.global_position


## Whether this unit is walking to a ladder someone else is on and has
## come within Ladder.WAIT_DISTANCE of its near end — where it waits.
func _waiting_for_ladder() -> bool:
	if _climb_ladder == null or _path_index >= _climb_first:
		return false
	var to_near: Vector3 = _current_path[_climb_first] - _owner.global_position
	to_near.y = 0.0
	return to_near.length() <= Ladder.WAIT_DISTANCE and _climb_ladder.is_busy_for(_owner)


## One frame waiting for the ladder: standing on its ground, and never
## counted as stuck — the wait ends when the ladder frees.
func _hold(delta: float) -> void:
	_keep_to_ground(delta)
	_stuck_timer = 0.0
	_last_progress_position = _owner.global_position


## One frame on the ladder: straight at the next climb point at
## climb_speed, placed directly — no gravity, no move_and_slide, since the
## climb runs along the landing's own edge (Ladder.climb_waypoints) where
## collision would only snag. Already-validated geometry: Ladder.find_route
## checked this path before the move was allowed.
func _climb_step(delta: float) -> void:
	var target: Vector3 = _current_path[_path_index]
	var to_target: Vector3 = target - _owner.global_position
	var step: float = _climb_speed * delta
	_owner.velocity = Vector3.ZERO
	# The level step between the landing's edge and the top is walked
	# facing the way it goes; the rest faces the ladder.
	var landing_leg: bool = _path_index == _climb_first + (4 if _climb_up else 1)
	var level := Vector3(to_target.x, 0.0, to_target.z)
	if landing_leg and level.length() > 0.01:
		_owner.face_direction(level, delta)
	elif _climb_facing != Vector3.ZERO:
		_owner.face_direction(_climb_facing, delta)
	if to_target.length() <= step:
		_owner.global_position = target
	else:
		_owner.global_position += to_target.normalized() * step
	_stuck_timer = 0.0
	_last_progress_position = _owner.global_position


## announce = false ends the move without emitting movement_finished:
## the move did not finish, it was REPLACED by a new order (see
## move_to). The budget is still charged for the distance actually
## walked; only the "I am done" announcement is withheld, because
## listeners treat it as a completed step and act on it.
func _finish_move(announce: bool = true) -> void:
	var walked: float = cost_walked()
	_moving = false
	_owner.velocity = Vector3.ZERO

	var completed_fully: bool = _path_index >= _current_path.size()

	if _owner.in_combat():
		# The plan completed fully (walked every point) → charge its
		# exact known cost, not a re-measurement — that cost IS what was
		# spent, by construction, since nothing deviated from the plan.
		# Cut short (replaced, stopped, stuck) → the route's cost up to
		# where the unit is (cost_walked, what the Move bar showed), not
		# the straight-line displacement: that would bill a free ladder
		# climb's height, and miss terrain cost.
		var spent: float = _planned_cost if completed_fully else walked
		_owner.spend_move(spent)

	_current_path = PackedVector3Array()
	_current_cost = PackedFloat32Array()
	_path_index = 0
	_planned_cost = 0.0
	_climb_first = -1
	_climb_last = -1
	_climb_ladder = null

	# An order given mid-climb runs now, from the far end; it replaces
	# this move, so this one doesn't announce — unless it can't start.
	var queued: Dictionary = _after_climb
	_after_climb = {}
	if not queued.is_empty() and move_to(queued.destination, queued.ignore):
		return

	if announce:
		_owner.movement_finished.emit(_owner)
	# _moving just flipped to false above — is_busy()'s answer may have
	# changed as a result, but UnitActionState has no way to learn that
	# on its own (is_moving() is polled, not pushed), so this explicitly
	# tells it to re-check.
	_owner.notify_movement_idle_check()


## Sets flight_target_altitude directly, clamped to the valid flight
## envelope (see NavigationGrid.FLIGHT_MIN_ALTITUDE/FLIGHT_MAX_ALTITUDE)
## — called by IdleIntent.steer when the player moves the altitude plane
## (Ctrl + wheel, or a Ctrl hold) while this unit flies. Doesn't move the
## unit itself; only changes where its NEXT move_to() call will aim for.
func set_flight_altitude(altitude: float) -> void:
	_owner.flight_target_altitude = clamp_flight_altitude(altitude, null, _owner)


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
## A begin_busy()/Tween/end_busy() shape — this bypasses the path-following system entirely too, for the
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
## controlled=true (a voluntary Land action, see LandEffect) never rolls
## fall damage regardless of descent — altitude itself stays pure upside
## (see FlightRules' own header), so the only cost this file's flight
## economy exacts is an UNCONTROLLED landing, exactly like running out
## of movement budget already costs a turn. false (the default, and what
## every other caller passes — natural expiry, IncapacitateBehavior
## forcing a flyer down) rolls FlightRules.roll_fall_damage() against the
## same descent this function was already computing for the animation,
## and applies it the same way DamageEffect.apply() does (roll, subtract
## DR, floor at 0, take_damage()) — so falling composes with death,
## AreaState recording, and everything else that already expects that
## exact shape.
func land(controlled: bool = false) -> void:
	var exclude: Array[RID] = []
	for unit in UnitQuery.all_units_near(_owner):
		exclude.append(unit.get_rid())

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

	if not controlled:
		_apply_fall_damage(descent)

	_owner.begin_busy()
	var tween: Tween = carry_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_owner, "global_position:y", result.position.y, duration)
	tween.finished.connect(func(): _owner.touched_down.emit(_owner))
	tween.finished.connect(_owner.end_busy)
	SystemLog.print("%s lands." % LogFormat.unit_name(_owner))


## Rolled and applied before the landing tween even starts, not on
## impact — descent is already fully known at this point (the whole
## fall happened off-screen while the unit was flying), so there's
## nothing meaningful left to wait for; this also sidesteps needing to
## reason about whether a lethal fall should interrupt the descent
## animation.
func _apply_fall_damage(descent: float) -> void:
	var raw_damage: int = FLIGHT_RULES.roll_fall_damage(_owner.counted_fall(descent))
	if raw_damage <= 0:
		return
	raw_damage = _owner.soften_fall(raw_damage)

	var applied: int = DamageResolver.injury(raw_damage, _owner, DamageResolver.WoundType.CRUSHING, 1.0, false, not FLIGHT_RULES.fall_damage_reduced_by_dr)

	if applied > 0:
		SystemLog.print("%s takes %d fall damage." % [LogFormat.unit_name(_owner), applied])
		_owner.take_damage(applied)

class_name Ladder
extends Node3D
## A grounded-unit-only vertical connector between two points (up to a
## rooftop, down into a pit, ...) that ordinary NavigationGrid pathfinding
## can't cross on its own — NavigationGrid's grid assumes a unit either
## has solid support directly below (grounded) or roams with full
## clearance (flying); a ladder is neither, so it's handled entirely
## OUTSIDE the grid rather than teaching the grid a third case.
##
## No collision on this node or its mesh, deliberately —
## NavigationGrid::collect_static_shapes (gdextension/src/navigation_grid
## .cpp) walks every StaticBody3D in the tree with no way to exclude one,
## so any real physics collision here would make the grid treat the
## ladder's own footprint as solid, blocking the ordinary walk that's
## supposed to reach its base/top in the first place.
##
## Conceptually the same idea as Unreal's NavLinkProxy or Unity's
## NavMeshLink — a manually-placed connector the pathfinder doesn't
## discover on its own. Unlike those, this ISN'T integrated into
## NavigationGrid's own search: find_route() below is called by
## UnitMovement before it walks, prices each ladder (walk to it, climb,
## walk on) against the plain walked path from ordinary
## NavigationGrid.find_path() calls, and the winner is stitched into the
## one route UnitMovement walks — deliberately, to avoid the C++ engine
## changes real graph integration would require for a feature this narrow
## in scope. One ladder per journey; chains of ladders are not searched.
##
## Grounded units only — a flying unit already has unrestricted vertical
## movement and never needs one; UnitMovement only ever calls find_route()
## for a non-flying unit.
##
## Scene setup: base_marker/top_marker are Marker3D children, dragged
## into place in the editor (gives a real 3D gizmo, unlike typing raw
## Vector3 numbers). The visual mesh is a plain MeshInstance3D with no
## collision — assign your own mesh in the Inspector.

## Paths to Marker3D children marking exactly where a unit's feet land at
## each end. NodePath rather than a direct Marker3D reference — dragging
## a child into a direct-node-typed export slot relies on the editor's
## own remapping when the scene is saved from the UI; a NodePath assigns
## unambiguously either way, including when a scene is authored by hand.
@export var base_marker: NodePath = NodePath("Base")
@export var top_marker: NodePath = NodePath("Top")

## Flat move-budget cost of using this ladder, checked as a hard
## precondition (not a clamp) before a climb ever starts — see
## find_route()/UnitMovement.move_to. Defaults to 0: a ladder is free
## once reached, BG3's rule — only the walk to the near end is paid. Set higher only for the rare ladder that should feel
## like a real commitment.
@export var required_move: float = 0.0

## Climbing speed in m/s, along UnitMovement's route (the climb is part
## of the move, see _ladder_route there). A real climber manages ~0.5,
## the CMU capture behind the climb clip 0.2; 0.75 is a brisk scramble
## (the clip at ~3.7x, a rung every 0.36 s) and a 6 m ladder in 8 s. The
## clip's rate follows this, so any value keeps hands and feet in step.
@export var climb_speed: float = 0.75

func _ready() -> void:
	add_to_group("ladders")


func base_position() -> Vector3:
	var marker := get_node_or_null(base_marker) as Node3D
	return marker.global_position if marker else global_position


func top_position() -> Vector3:
	var marker := get_node_or_null(top_marker) as Node3D
	return marker.global_position if marker else global_position


## How close a walked path's end must come to the asked-for point to
## count as getting there (find_path snaps an unstandable point).
const ARRIVAL: float = 1.0

static var _cache_key: Array = []
static var _cache_route: Dictionary = {}


## The ONE shared query behind UnitMovement.plan_route — so the real move,
## its preview and the AI's pricing of a move can't disagree about whether
## a destination takes a ladder.
##
## A ladder is taken, wherever the destination is, when it is the only
## way there or the cheaper one (BG3 routes through ladders the same way):
## the walk to its near end, the free climb, and the walk on from its far
## end, against the plain walked path. Only a move that changes level
## looks at all (the unit nearer the near end's height, the destination
## nearer the far end's), so a flat click costs no path query.
##
## Returns {} when walking is as good or the only option. Otherwise:
##   ladder: Ladder
##   near / far: Vector3 — the end walked to, and the end climbed to
##   near_planned: RoutePlanner.plan()'s {path, cumulative_cost} to near,
##     planned without a budget so the caller sees the whole cost
##   tail_waypoints: find_path from far to the destination (UnitMovement
##     plans it with what budget is left)
##   going_up: bool — which way to walk climb_waypoints (see its header)
## Whether a budget covers the climb is the caller's question (see
## UnitMovement.plan_route): the same route serves every budget.
##
## Cached on the last query (unit, cells, occupancy, ignore): the preview
## asks every frame and the mouse sitting still is the common case.
static func find_route(unit: Unit, destination: Vector3, ignore: Array = []) -> Dictionary:
	var candidates: Array = []
	for end in _climbable_ends(unit):
		var near: Vector3 = end[1]
		var far: Vector3 = end[2]
		if absf(destination.y - far.y) >= absf(destination.y - near.y):
			continue
		candidates.append(end)
	if candidates.is_empty():
		return {}

	var tree: SceneTree = unit.get_tree()
	var key: Array = [
		unit.get_instance_id(),
		NavigationGrid.world_to_cell(unit.global_position),
		NavigationGrid.world_to_cell(destination),
		NavigationGrid.occupancy_version(tree, unit),
		ignore.hash(),
	]
	if key == _cache_key:
		return _cache_route
	var route: Dictionary = _best_route(unit, destination, ignore, candidates)
	_cache_key = key
	_cache_route = route
	return route


## The ladder ends `unit` could climb to from the level it stands on:
## [ladder, near, far, going_up] for each ladder in its world whose near
## end is nearer the unit's height than its far end. find_route's first
## filter, and the AI's question of what heights a grounded unit can ever
## get to (see AiScorer._can_ever_reach) — one copy, so the AI never
## counts a climb the move wouldn't consider.
static func _climbable_ends(unit: Unit) -> Array:
	var ends: Array = []
	# "ladders" is one global group with no world in it, and every area is
	# authored around the origin, so a ladder two areas away sits at
	# coordinates this unit could plausibly route to.
	for node in unit.get_tree().get_nodes_in_group("ladders"):
		var ladder := node as Ladder
		if not ladder or not ladder.is_inside_tree():
			continue
		if ladder.get_world_3d() != unit.get_world_3d():
			continue
		var top: Vector3 = ladder.top_position()
		var base: Vector3 = ladder.base_position()
		for going_up in [true, false]:
			var near: Vector3 = base if going_up else top
			var far: Vector3 = top if going_up else base
			if absf(unit.global_position.y - near.y) >= absf(unit.global_position.y - far.y):
				continue
			ends.append([ladder, near, far, going_up])
	return ends


## Heights a grounded unit can reach by one climb from where it stands —
## the far ends of _climbable_ends. No path query: whether the walk to the
## ladder exists is the route's question, not this one's.
static func climbable_heights(unit: Unit) -> PackedFloat32Array:
	var heights := PackedFloat32Array()
	for end in _climbable_ends(unit):
		heights.append((end[2] as Vector3).y)
	return heights


static func _best_route(unit: Unit, destination: Vector3, ignore: Array, candidates: Array) -> Dictionary:
	var sampler: Callable = SurfaceManager.cost_sampler(unit)
	var best_cost: float = INF
	var direct: Dictionary = _plan_leg(unit, unit.global_position, destination, ignore, sampler)
	if not direct.is_empty():
		best_cost = _end_cost(direct)

	var best: Dictionary = {}
	for candidate in candidates:
		var ladder: Ladder = candidate[0]
		var near: Vector3 = candidate[1]
		var far: Vector3 = candidate[2]
		var going_up: bool = candidate[3]
		# Straight-line floor first: most ladders lose to the plain walk
		# without a single path query.
		var floor_cost: float = _flat(unit.global_position, near) + ladder.required_move + _flat(far, destination)
		if floor_cost >= best_cost:
			continue
		# A misplaced ladder whose climb would cut through geometry
		# declines to engage rather than animate through it (see
		# climb_waypoints for the reproduced corner-clip).
		if not _climb_path_is_clear(unit, ladder.base_position(), ladder.top_position(), going_up):
			continue
		var near_planned: Dictionary = _plan_leg(unit, unit.global_position, near, ignore, sampler)
		if near_planned.is_empty():
			continue
		var tail: Dictionary = _plan_leg(unit, far, destination, ignore, sampler)
		if tail.is_empty():
			continue
		var total: float = _end_cost(near_planned) + ladder.required_move + _end_cost(tail)
		if total >= best_cost:
			continue
		best_cost = total
		best = {
			"ladder": ladder,
			"near": near,
			"far": far,
			"near_planned": near_planned,
			"tail_waypoints": tail.waypoints,
			"going_up": going_up,
		}
	return best


## A walked leg, planned without a budget: {path, cumulative_cost,
## waypoints}, or {} when it does not get there. Standing on the start
## already is a real, free leg — the common case right after a climb,
## when the next order is the climb back.
static func _plan_leg(unit: Unit, from: Vector3, to: Vector3, ignore: Array, sampler: Callable) -> Dictionary:
	if from.distance_to(to) <= unit.arrival_tolerance:
		var trivial := PackedVector3Array([from, to])
		return {"path": trivial, "cumulative_cost": PackedFloat32Array([0.0, 0.0]), "waypoints": trivial}
	var waypoints: PackedVector3Array = NavigationGrid.find_path(unit.get_tree(), from, to, unit, false, ignore)
	if waypoints.size() < 2 or waypoints[waypoints.size() - 1].distance_to(to) > ARRIVAL:
		return {}
	var planned: Dictionary = RoutePlanner.plan(waypoints, 9999.0, sampler)
	planned["waypoints"] = waypoints
	return planned


static func _end_cost(planned: Dictionary) -> float:
	var cost: PackedFloat32Array = planned.cumulative_cost
	return cost[cost.size() - 1] if cost.size() > 0 else 0.0


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## The actual climb route, ALWAYS expressed base-to-top regardless of
## which direction a unit is actually traveling — the caller reverses the
## result for a top-to-base descent (see going_up below; find_route and
## UnitMovement._ladder_route both already know the real direction, so
## reversing there is trivial). Goes straight up first, staying at
## BASE's own XZ the entire way (guaranteed clear the whole way up,
## since that's exactly where a unit walks up to on ordinary ground
## before ever starting to climb), THEN a horizontal step at TOP's height
## onto TOP's actual XZ — that step lands exactly at the landing
## surface's own height, so it grazes along the top of whatever's there
## instead of cutting through its interior.
##
## NOT safe to compute generically from whichever endpoint happens to be
## passed first — a real, reproduced bug, not a hypothetical: an earlier
## version anchored the vertical run at the FIRST argument's XZ
## regardless of direction, which worked climbing up (base is naturally
## first there) but broke climbing back down (top would have been
## first — and top is typically inset ONTO whatever it's landing on, so
## a vertical run at top's own XZ plunges straight through that
## landing's solid interior on the way down, the same clipping bug this
## function exists to prevent, just triggered in the other direction).
## Fixed by always computing the path in a single canonical order and
## letting the caller reverse it, rather than recomputing the shape
## itself per direction.
##
## Shared by find_route's safety check and UnitMovement._ladder_route's
## actual climb, so what's validated and what's played can never
## disagree.
##
## Returns 2-3 points, base-to-top order (degenerate cases collapse — a
## purely vertical ladder with the same XZ at both ends never needs the
## horizontal step at all, see the distance guards below).
static func climb_waypoints(base: Vector3, top: Vector3) -> PackedVector3Array:
	var elbow: Vector3 = Vector3(base.x, top.y, base.z)
	var waypoints := PackedVector3Array([base])
	if base.distance_to(elbow) > 0.001:
		waypoints.append(elbow)
	if elbow.distance_to(top) > 0.001:
		waypoints.append(top)
	return waypoints


## Whether climb_waypoints(base, top)'s planned route is actually clear of
## solid geometry along its full length, not just at its endpoints (those
## are already confirmed valid points by construction — this checks what
## connects them). Sampled roughly every 0.5m along each segment against
## NavigationGrid's own already-baked solidity data, via
## nearest_valid_point with max_radius_cells=0 — passing 0 means
## find_nearest_free_cell (see navigation_grid.cpp) never searches
## outward from the sampled point's own exact cell, so a `found: false`
## result means precisely "this exact point is solid," not "nothing
## valid was found nearby." No new NavigationGrid binding needed — this
## reuses the exact query nearest_valid_point already exposes.
##
## Checked with flying=true, even though a ladder is otherwise a
## grounded-only mechanic (see this file's own header) — that's about who
## may USE a ladder and how it costs move budget, not about what makes a
## given point in space "clear." A mid-climb point is airborne by
## definition (gripping a ladder, not standing on unsupported ground), so
## the right validity rule for it is flying's — pure clearance, no
## "solid directly below" requirement — not grounded's. Checking with
## flying=false was a real bug caught by testing, not a hypothetical:
## every sampled point partway up any vertical climb has nothing solid
## directly beneath it by construction, so that check rejected every
## climb, including entirely unobstructed ones.
##
## Second bug caught by the SAME test run, same root cause (guessing
## instead of reading is_valid_cell's actual C++): flying=true ALSO
## enforces NavigationGrid's own FLIGHT_MIN_ALTITUDE floor
## (navigation_grid.cpp's is_valid_cell, the `if (flying)` block at the
## very top) — a "you can't hover at ground level" GAME RULE, not a
## collision fact, and it rejected this ladder's own base region (a
## typical ground-level base sits well under that altitude). There's no
## public query for "clear of solid geometry, no support-below
## requirement, no altitude floor" — building one would be exactly the
## NavigationGrid engine change this whole feature was built to avoid.
## Sample points below that floor are skipped instead: they're always
## close to `near`, already confirmed walkable by the ordinary
## ground-based find_path call earlier in find_route, so skipping them
## isn't skipping a real risk — it's a small region this specific check
## structurally can't see, covered by a different one instead.
##
## Third bug, also caught by the same run: max_radius_cells=0 (an exact,
## no-snap check) is precise but brittle exactly where this needs it
## least — the horizontal step lands deliberately ON a landing surface's
## own top boundary (see climb_waypoints), and rasterize_chunk's
## inside-test is inclusive of a box's exact boundary, so a sample
## landing in the cell nearest that boundary can get classified as still
## part of the solid platform rather than the clear space just above it.
## Every OTHER caller in this codebase that snaps a point sidesteps this
## with a real (nonzero) search radius; a small one (SNAP_RADIUS_CELLS,
## one cell) fixes the false rejection at an exact boundary without
## meaningfully weakening real-obstruction detection — an obstacle
## actually worth rejecting a ladder over spans many cells, not one.
static func _climb_path_is_clear(unit: Unit, base: Vector3, top: Vector3, going_up: bool) -> bool:
	const SAMPLE_SPACING: float = 0.5
	const SNAP_RADIUS_CELLS: int = 1

	var clearance: float = unit.radius + unit.avoidance_margin
	var waypoints: PackedVector3Array = climb_waypoints(base, top)
	if not going_up:
		waypoints.reverse()
	var min_checkable_altitude: float = NavigationGrid.get_flight_min_altitude()

	for i in range(1, waypoints.size()):
		var a: Vector3 = waypoints[i - 1]
		var b: Vector3 = waypoints[i]
		var segment_length: float = a.distance_to(b)
		if segment_length < 0.001:
			continue

		var steps: int = max(1, ceili(segment_length / SAMPLE_SPACING))
		for s in range(steps + 1):
			var t: float = float(s) / float(steps)
			var sample: Vector3 = a.lerp(b, t)
			if sample.y < min_checkable_altitude:
				continue
			var check: Dictionary = NavigationGrid.nearest_valid_point(unit.get_tree(), sample, clearance, true, unit, SNAP_RADIUS_CELLS)
			if not check.found:
				return false

	return true

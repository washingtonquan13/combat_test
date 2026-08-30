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
## NavigationGrid's own search: find_route() below is called externally,
## by UnitMovement, BEFORE any pathfinding runs, and the actual journey is
## stitched together from two ordinary NavigationGrid.find_path() calls
## plus a direct Tween for the climb itself — deliberately, to avoid the
## C++ engine changes real graph integration would require for a feature
## this narrow in scope.
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
## find_route()/UnitMovement._begin_ladder_journey. Defaults to 0: most
## ladders should be free once reached, matching how Solasta treats
## "easy surfaces like ladders or ropes... without any trouble" as the
## baseline case. Set higher only for the rare ladder that should feel
## like a real commitment.
@export var required_move: float = 0.0

## Duration of the climb's Tween — same role as MoveCasterEffect's
## jump_duration. First-guess default, untuned by eye like every other
## timing value in this project until it's actually been watched.
@export var climb_duration: float = 0.6

## How close a move_to() destination needs to be to base_position()/
## top_position() to be interpreted as "use this ladder" — see
## find_route().
@export var interaction_radius: float = 1.5


func _ready() -> void:
	add_to_group("ladders")


func base_position() -> Vector3:
	var marker := get_node_or_null(base_marker) as Node3D
	return marker.global_position if marker else global_position


func top_position() -> Vector3:
	var marker := get_node_or_null(top_marker) as Node3D
	return marker.global_position if marker else global_position


## The ONE shared query both UnitMovement's real move and
## movement_indicator.gd's preview call — so neither can disagree with the
## other about whether a destination implies using a ladder, or whether
## the unit can currently afford it. Same discipline jump_indicator.gd
## already applies to Jump's arc: what's shown must be exactly what will
## happen, never an approximation of it.
##
## Returns {} if no ladder in the "ladders" group is relevant to
## destination at all (i.e. destination isn't near any ladder's base or
## top). Otherwise:
##   ladder: Ladder
##   near: Vector3 — the end closer to the unit's current side, walked to
##     normally before climbing
##   far: Vector3 — the other end, where destination actually is
##   near_planned: Dictionary — RoutePlanner.plan()'s own return shape
##     ({path, cumulative_cost}) for the real route from the unit's
##     current position to `near`, planned with an effectively unlimited
##     budget so the caller sees the FULL route/cost regardless of
##     move_remaining (same convention movement_indicator.gd already uses
##     for its own preview planning)
##   going_up: bool — true if near==base/far==top (climbing up), false if
##     near==top/far==base (climbing down). UnitMovement needs this to
##     know which direction to actually walk climb_waypoints in — see
##     that function's own header for why the path isn't symmetric.
##   affordable: bool — whether move_remaining covers near_planned's full
##     cost PLUS required_move, checked all at once as a single hard
##     precondition. Always true outside combat (move is unlimited there,
##     same as ordinary movement's own budget = INF rule).
static func find_route(unit: Unit, destination: Vector3) -> Dictionary:
	for node in unit.get_tree().get_nodes_in_group("ladders"):
		var ladder := node as Ladder
		if not ladder:
			continue

		var top: Vector3 = ladder.top_position()
		var base: Vector3 = ladder.base_position()

		var near: Vector3
		var far: Vector3
		var going_up: bool
		if destination.distance_to(top) <= ladder.interaction_radius:
			near = base
			far = top
			going_up = true
		elif destination.distance_to(base) <= ladder.interaction_radius:
			near = top
			far = base
			going_up = false
		else:
			continue

		# near/far are themselves confirmed-valid points, but the PATH
		# connecting them isn't automatically safe — a straight line
		# between an outside-the-geometry point and an inset landing point
		# can cut straight through whatever solid corner sits between
		# them (confirmed, reproduced: a ladder mounted on a wall with its
		# top inset onto the platform above cut through the platform's own
		# corner for the top half of the climb, in BOTH directions — see
		# climb_waypoints' own header for why going_up has to be passed
		# through here too, not just to UnitMovement). Skip this ladder
		# rather than offer a climb that would visibly clip — a broken/
		# misplaced ladder should silently decline to engage, not animate
		# through geometry.
		if not _climb_path_is_clear(unit, base, top, going_up):
			continue

		# find_path returning fewer than 2 waypoints normally means "no
		# route exists," but it's ALSO what a start==destination query
		# returns — and the unit already standing at/very near `near` is
		# the COMMON case here, not an edge case: it's exactly where a
		# unit stands right after climbing UP a moment ago, so the very
		# next thing they do is often try to climb back DOWN from
		# essentially that same spot. Confirmed as a real bug, not
		# hypothetical: this used to fall through to `continue` (silently
		# refusing to offer the ladder at all) whenever the click was
		# close enough to already-arrived. Treated as a trivial, real,
		# zero-cost route instead of a failure.
		var near_planned: Dictionary
		if unit.global_position.distance_to(near) <= unit.arrival_tolerance:
			near_planned = {
				"path": PackedVector3Array([unit.global_position, near]),
				"cumulative_cost": PackedFloat32Array([0.0, 0.0]),
			}
		else:
			var waypoints: PackedVector3Array = NavigationGrid.find_path(unit.get_tree(), unit.global_position, near, unit, false)
			if waypoints.size() < 2:
				continue
			near_planned = RoutePlanner.plan(waypoints, 9999.0, SurfaceManager.movement_cost_multiplier_at)

		var cost_to_near: float = near_planned.cumulative_cost[near_planned.cumulative_cost.size() - 1] if near_planned.cumulative_cost.size() > 0 else 0.0
		var affordable: bool = (not unit.in_combat()) or (unit.move_remaining >= cost_to_near + ladder.required_move)

		return {
			"ladder": ladder,
			"near": near,
			"far": far,
			"near_planned": near_planned,
			"going_up": going_up,
			"affordable": affordable,
		}

	return {}


## The actual climb route, ALWAYS expressed base-to-top regardless of
## which direction a unit is actually traveling — the caller reverses the
## result for a top-to-base descent (see going_up below; find_route and
## UnitMovement._climb_ladder both already know the real direction, so
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
## Shared by find_route's safety check and UnitMovement._climb_ladder's
## actual animation, so what's validated and what's played can never
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

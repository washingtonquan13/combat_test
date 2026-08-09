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
		if destination.distance_to(top) <= ladder.interaction_radius:
			near = base
			far = top
		elif destination.distance_to(base) <= ladder.interaction_radius:
			near = top
			far = base
		else:
			continue

		var waypoints: PackedVector3Array = NavigationGrid.find_path(unit.get_tree(), unit.global_position, near, unit, false)
		if waypoints.size() < 2:
			continue

		var near_planned: Dictionary = RoutePlanner.plan(waypoints, 9999.0, SurfaceManager.movement_cost_multiplier_at)
		var cost_to_near: float = near_planned.cumulative_cost[near_planned.cumulative_cost.size() - 1] if near_planned.cumulative_cost.size() > 0 else 0.0
		var affordable: bool = (not CombatManager.in_combat) or (unit.move_remaining >= cost_to_near + ladder.required_move)

		return {
			"ladder": ladder,
			"near": near,
			"far": far,
			"near_planned": near_planned,
			"affordable": affordable,
		}

	return {}

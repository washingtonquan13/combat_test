extends IndicatorBase
## Movement path preview, BG3-style. Only shows during combat, for the
## unit whose turn it currently is, and only if that unit is
## player-controlled (Unit.is_player_controlled) — the AI's turns don't
## get this, and neither does anything out of combat.
##
## Scene setup: attach this script to any plain Node3D in your main scene
## — it builds its own child MeshInstance3D visuals in code, nothing else
## needs to be wired up. Requires ground_collision_mask (see
## IndicatorBase) to match whatever physics layer your ground/terrain
## body (see ground_click_target.gd) is actually on, so mouse hover can
## be raycast onto it.
##
## A line follows the EXACT planned route (via RoutePlanner.plan — the
## same budget/cost planner Unit.move_to() itself calls, over a route
## from NavigationGrid.find_path() that's already avoidance-correct
## against every other unit's footprint and real level geometry, see
## navigation_grid.gd) from the unit to wherever the mouse is hovering,
## colored white for the portion within move_remaining and red for the
## portion beyond it. Since this calls the literal same planning function
## the real move will use, over the same grid state, this preview IS what
## will happen — not an approximation of it.
##
## The line itself is corner-rounded and drawn as short dashes rather
## than one solid strip — see _round_corners/_draw_dashed_strip below —
## for the BG3-style segmented rope look.
##
## Note: this draws 1-pixel unshaded lines (ImmediateMesh, PRIMITIVE_
## LINES) — fine for a first pass, but Godot doesn't give line
## primitives real width without building an actual ribbon mesh, so the
## dashes here are thin, not the thick capsule shapes a reference image
## might show. If you want visibly thick segments later, that's a
## natural follow-up.

@export var path_in_range_color: Color = Color(1, 1, 1, 0.9)
@export var path_out_of_range_color: Color = Color(1, 0.2, 0.2, 0.9)
## Lifts the line slightly above the ground to avoid z-fighting with
## terrain geometry.
@export var height_offset: float = 0.05
## Purely visual corner rounding for the rendered line — see
## _round_corners. The taut path RoutePlanner produces is optimal but
## not smooth: real corners at real angles, which read as jagged when
## drawn as-is. This never touches the actual path/cost/collision data,
## only what gets drawn here.
@export var corner_round_radius: float = 0.35
@export var corner_round_segments: int = 6
## Dash + gap arc-length (meters) for the segmented "rope" look — see
## _draw_dashed_strip.
@export var dash_length: float = 0.3
@export var dash_gap: float = 0.18

var _path_mesh: MeshInstance3D
var _path_immediate: ImmediateMesh

## Cache for the last NavigationGrid.find_path() query this preview made —
## see _update_path_preview. A* is a real search, not free; re-running it
## unconditionally every rendered frame (most of which the mouse hasn't
## meaningfully moved) was this preview's single biggest performance cost.
var _last_query_unit: Unit = null
var _last_query_flying: bool = false
var _last_query_start_cell: Vector3i
var _last_query_dest_cell: Vector3i
var _last_waypoints: PackedVector3Array = PackedVector3Array()

## Whether the Ctrl altitude-drag was active last frame — used only to
## detect the moment it STARTS (see _handle_altitude_input), so the drag's
## XZ anchor gets captured once per press instead of drifting every frame.
var _altitude_dragging: bool = false
## XZ position the altitude drag's vertical plane is anchored to — wherever
## the ground hover was pointing at the instant the modifier was pressed.
## Frozen for the duration of the hold: while dragging, the mouse only
## controls height, not destination, so the two can't fight over the same
## input.
var _altitude_drag_anchor_xz: Vector2 = Vector2.ZERO


func _ready() -> void:
	var built: Dictionary = _create_line_mesh()
	_path_mesh = built.mesh_instance
	_path_immediate = built.immediate


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	if not unit:
		_hide_all()
		return

	_handle_altitude_input(unit)
	_update_path_preview(unit)


## Delegates the shared "is the player currently free to act" condition
## to PlayerInteractionState, plus this script's own specific rule: hide
## whenever ANY ability is armed, since a click in that state uses the
## ability instead of moving (see ground_click_target.gd).
func _get_active_unit() -> Unit:
	if PlayerInteractionState.has_any_ability_armed():
		return null
	return PlayerInteractionState.get_active_unit()


func _hide_all() -> void:
	if _path_mesh:
		_path_mesh.visible = false


## Modifier-style altitude control: hold fly_altitude_modifier (Ctrl) and
## the active flying unit's TARGET altitude tracks the mouse directly,
## instead of the old R/F "nudge at a fixed speed" scheme. Called from
## _process() rather than an input callback since it needs to keep sampling
## the live mouse position for as long as the modifier stays down. Same
## gating as the path preview (only reached at all once _get_active_unit()
## already passed in _process), plus its own is_flying() check, since a
## non-flying active unit shouldn't react to this just because it's held.
##
## How the drag itself works: on the frame the modifier is first held, the
## XZ point the ground hover was aiming at gets frozen as _altitude_drag_
## anchor_xz — for the rest of the hold, mouse movement only changes
## height, not destination, so the two never fight over the same input.
## Height comes from casting the camera ray through the current mouse
## position and intersecting it against a vertical "wall" of infinite
## height standing at that anchor XZ, facing the camera — see
## _sample_altitude_from_mouse for why that's the right shape of plane to
## use. Releasing the modifier ends the drag; whatever altitude it landed
## on stays committed (same as R/F leaving flight_target_altitude wherever
## it was last nudged to).
func _handle_altitude_input(unit: Unit) -> void:
	if not unit.is_flying() or not Input.is_action_pressed("fly_altitude_modifier"):
		_altitude_dragging = false
		return

	if not _altitude_dragging:
		var ground_point = _get_mouse_ground_point()
		var anchor: Vector3 = ground_point if ground_point != null else unit.global_position
		_altitude_drag_anchor_xz = Vector2(anchor.x, anchor.z)
		_altitude_dragging = true

	var sampled_altitude = _sample_altitude_from_mouse(_altitude_drag_anchor_xz)
	if sampled_altitude != null:
		unit.set_flight_altitude(sampled_altitude)


## Reads the altitude implied by the current mouse position: casts the
## camera ray through the mouse and intersects it with a vertical plane
## anchored at anchor_xz. The plane's normal is the camera's own back
## vector flattened to purely horizontal (Y zeroed before normalizing) —
## flattening it is what keeps this a true vertical wall regardless of the
## CRPGCamera's pitch, so only how high or low the ray crosses that wall
## matters. Without flattening, a pitched-down camera would tilt the
## "wall" too, coupling horizontal mouse movement into the altitude result
## in a way that would feel wrong to drag. Returns null if there's no
## active camera or the ray can't hit the plane at all (near-parallel to
## it — not reachable in practice given the camera's pitch is clamped well
## away from looking straight along the horizon).
func _sample_altitude_from_mouse(anchor_xz: Vector2):
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var back: Vector3 = camera.global_transform.basis.z
	var normal := Vector3(back.x, 0.0, back.z)
	if normal.length() < 0.001:
		return null
	normal = normal.normalized()

	var anchor_point := Vector3(anchor_xz.x, 0.0, anchor_xz.y)
	var plane := Plane(normal, anchor_point)

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)

	var hit = plane.intersects_ray(from, dir)
	if hit == null:
		return null
	return hit.y


func _update_path_preview(unit: Unit) -> void:
	var hover_point = _get_mouse_ground_point()
	if hover_point == null:
		_path_mesh.visible = false
		return

	# Mirrors UnitMovement.move_to()'s own flying branch exactly — same
	# XZ-from-click/Y-from-target-altitude query, so this preview can't
	# diverge from what the real move will do (see this file's header).
	var flying: bool = unit.is_flying()
	var query_hover_point: Vector3 = hover_point
	if flying:
		query_hover_point.y = clamp(
			unit.flight_target_altitude,
			NavigationGrid.FLIGHT_MIN_ALTITUDE,
			NavigationGrid.FLIGHT_CEILING_HEIGHT
		)

	# Only re-run the actual A* search when the meaningful inputs moved to
	# a different CELL — hover position, unit's own position, or flying
	# altitude (already folded into dest_cell, since query_hover_point.y
	# carries the target altitude) — not on every single frame regardless
	# of whether anything changed, which is most frames (the mouse sitting
	# still is the common case, not the exception). RoutePlanner.plan
	# below still re-runs every frame regardless — it's a cheap linear
	# walk of the path, not a search, so it can stay live-updating against
	# move_remaining without needing the same caching.
	var start_cell: Vector3i = NavigationGrid.world_to_cell(unit.global_position)
	var dest_cell: Vector3i = NavigationGrid.world_to_cell(query_hover_point)
	var query_unchanged: bool = (
		unit == _last_query_unit
		and flying == _last_query_flying
		and start_cell == _last_query_start_cell
		and dest_cell == _last_query_dest_cell
	)

	var waypoints: PackedVector3Array
	if query_unchanged:
		waypoints = _last_waypoints
	else:
		# Hovering directly over another unit's own footprint has nothing
		# valid to plan toward exactly at that point — find_path()
		# naturally resolves to the nearest valid cell outside it, same as
		# move_to() itself; no separate sanitizing step needed.
		waypoints = NavigationGrid.find_path(unit.get_tree(), unit.global_position, query_hover_point, unit, flying)
		_last_query_unit = unit
		_last_query_flying = flying
		_last_query_start_cell = start_cell
		_last_query_dest_cell = dest_cell
		_last_waypoints = waypoints

	if waypoints.size() < 2:
		_path_mesh.visible = false
		return

	# The SAME planning call move_to() itself makes, with the same
	# cost_sampler — a large budget here gets the full route to the hover
	# point regardless of move_remaining; the white/red split below is
	# what shows how far the unit could actually get this turn. Because
	# this is the literal same function over the literal same grid
	# state, this preview and the real move can never disagree.
	var planned: Dictionary = RoutePlanner.plan(waypoints, 9999.0, SurfaceManager.movement_cost_multiplier_at)
	var path: PackedVector3Array = planned.path

	if path.size() < 2:
		_path_mesh.visible = false
		return

	_draw_path(path, planned.cumulative_cost, unit.move_remaining)
	_path_mesh.visible = true


## Rebuilds the path line each frame, split into an in-range sub-path
## (cumulative COST <= budget) and an out-of-range sub-path (the rest) —
## cost, not raw distance, read straight from simulate_path's own
## cumulative_cost array rather than re-summing segment lengths here.
## That matters once difficult terrain is in play: re-deriving cost from
## geometry alone would silently ignore any multiplier, putting the
## split in the wrong place. Reading the exact numbers the simulation
## already produced means this can't disagree with where the real move
## will actually run out. The split point is interpolated along
## whichever path segment crosses the budget boundary, so the color
## change lands exactly at the true edge of move_remaining rather than
## snapping to the nearest path vertex.
##
## Each sub-path is corner-rounded and drawn as its own dashed strip
## (see _round_corners/_draw_dashed_strip), with the dash phase carried
## from the in-range strip into the out-of-range one so the segmented
## rhythm reads as one continuous rope through the budget boundary
## rather than two independently-phased halves.
func _draw_path(path: PackedVector3Array, cumulative_cost: PackedFloat32Array, budget: float) -> void:
	_path_immediate.clear_surfaces()

	var lift := Vector3(0, height_offset, 0)

	var split_index: int = path.size()
	var split_point: Vector3 = path[path.size() - 1]
	if budget <= 0.0:
		split_index = 0
		split_point = path[0]
	else:
		for i in range(1, path.size()):
			if cumulative_cost[i] >= budget:
				var segment_cost: float = cumulative_cost[i] - cumulative_cost[i - 1]
				var remaining: float = budget - cumulative_cost[i - 1]
				var t: float = (remaining / segment_cost) if segment_cost > 0.0 else 0.0
				split_point = path[i - 1].lerp(path[i], t)
				split_index = i
				break

	var in_range_points := PackedVector3Array()
	for i in range(0, split_index):
		in_range_points.append(path[i])
	if split_index < path.size():
		in_range_points.append(split_point)

	var out_of_range_points := PackedVector3Array()
	if split_index < path.size():
		out_of_range_points.append(split_point)
		for i in range(split_index, path.size()):
			out_of_range_points.append(path[i])

	var in_range_rounded := _round_corners(in_range_points, corner_round_radius, corner_round_segments)
	var out_of_range_rounded := _round_corners(out_of_range_points, corner_round_radius, corner_round_segments)

	var phase: float = _draw_dashed_strip(in_range_rounded, path_in_range_color, lift, 0.0)
	_draw_dashed_strip(out_of_range_rounded, path_out_of_range_color, lift, phase)


## Purely visual corner rounding for the rendered path line — replaces
## each interior vertex with a small quadratic-Bezier fillet so real
## grid-aligned turns don't read as jagged 90/45-degree corners. Radius
## is clamped per-corner to at most half of either adjacent segment's
## length, so short zigzag segments can't produce overlapping arcs.
## Endpoints are always kept exact (the line still starts at the unit
## and ends exactly at the hover point / budget split). The result is
## only ever used for drawing — never fed back into pathfinding, cost,
## or the real move.
func _round_corners(points: PackedVector3Array, radius: float, arc_segments: int) -> PackedVector3Array:
	if points.size() < 3 or radius <= 0.0:
		return points

	var result := PackedVector3Array()
	result.append(points[0])

	for i in range(1, points.size() - 1):
		var prev: Vector3 = points[i - 1]
		var corner: Vector3 = points[i]
		var next: Vector3 = points[i + 1]

		var to_prev: Vector3 = corner - prev
		var to_next: Vector3 = next - corner
		var len_prev: float = to_prev.length()
		var len_next: float = to_next.length()
		if len_prev < 0.001 or len_next < 0.001:
			result.append(corner)
			continue

		var r: float = min(radius, len_prev * 0.5, len_next * 0.5)
		var arc_start: Vector3 = corner - (to_prev / len_prev) * r
		var arc_end: Vector3 = corner + (to_next / len_next) * r

		result.append(arc_start)
		for s in range(1, arc_segments):
			var t: float = float(s) / float(arc_segments)
			var a: Vector3 = arc_start.lerp(corner, t)
			var b: Vector3 = corner.lerp(arc_end, t)
			result.append(a.lerp(b, t))
		result.append(arc_end)

	result.append(points[points.size() - 1])
	return result


## Walks `points` (already corner-rounded) and emits it as PRIMITIVE_LINES
## dashes of dash_length separated by dash_gap, instead of one solid
## strip — the segmented "rope" look from the BG3-style reference.
## `phase` is how far into the dash+gap period the pattern already was
## when this call starts (arc-length); pass the return value from one
## call into the next so consecutive strips (in-range then out-of-range)
## continue the same rhythm instead of each restarting its own pattern
## from a fresh dash. Returns the phase for whatever continues after
## this strip.
func _draw_dashed_strip(points: PackedVector3Array, color: Color, lift: Vector3, phase: float) -> float:
	var period: float = dash_length + dash_gap
	if points.size() < 2 or period <= 0.0:
		return phase

	var cumulative := PackedFloat32Array()
	cumulative.resize(points.size())
	cumulative[0] = 0.0
	for i in range(1, points.size()):
		cumulative[i] = cumulative[i - 1] + points[i - 1].distance_to(points[i])
	var total: float = cumulative[cumulative.size() - 1]

	_path_immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	_path_immediate.surface_set_color(color)

	var pos: float = -fmod(phase, period)
	while pos < total:
		var dash_start: float = max(pos, 0.0)
		var dash_end: float = min(pos + dash_length, total)
		if dash_end > dash_start:
			_path_immediate.surface_add_vertex(_point_at_distance(points, cumulative, dash_start) + lift)
			_path_immediate.surface_add_vertex(_point_at_distance(points, cumulative, dash_end) + lift)
		pos += period

	_path_immediate.surface_end()

	return fmod(phase + total, period)


## Point on `points` (with per-vertex cumulative arc length `cumulative`)
## at arc-length `distance` from the start, clamped to the endpoints —
## shared walking logic for _draw_dashed_strip.
func _point_at_distance(points: PackedVector3Array, cumulative: PackedFloat32Array, distance: float) -> Vector3:
	if distance <= 0.0:
		return points[0]
	var total: float = cumulative[cumulative.size() - 1]
	if distance >= total:
		return points[points.size() - 1]
	for i in range(1, points.size()):
		if cumulative[i] >= distance:
			var seg_len: float = cumulative[i] - cumulative[i - 1]
			var t: float = ((distance - cumulative[i - 1]) / seg_len) if seg_len > 0.0 else 0.0
			return points[i - 1].lerp(points[i], t)
	return points[points.size() - 1]

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
## The line itself is corner-rounded (_round_corners) then drawn as one
## flat, ground-hugging ribbon mesh (_draw_textured_ribbon), carrying
## real UVs and shaded by movement_indicator_line.gdshader: additive
## blend, brightness shaped only by a soft smoothstep falloff across the
## ribbon's WIDTH (UV.y) — no crisp/opaque line, no length-wise dash
## pattern, just the glowing gradient edge itself. (Two earlier,
## discarded variants: a dashed pattern sampled along the ribbon's
## length, and a separate crisp regular-alpha "core" line under a
## soft "glow" halo — both removed per explicit request; the soft
## gradient edge WAS the intended line all along, not an add-on around
## something harder.) Deliberately pushed past the scene's
## glow_hdr_threshold (brightness_boost uniform — see main.tscn's
## WorldEnvironment, which enables glow project-wide) so it actually
## blooms instead of just being a bright shape.
##
## The ribbon stays ground-flat (oriented via _horizontal_perpendicular,
## always in the XZ plane) rather than camera-facing — this is a path
## decal lying on the terrain, not an effect that should swivel to face
## the camera as it orbits.
##
## Godot (like most renderers) doesn't give line primitives real width,
## so the ribbon is real geometry: flat quads (ImmediateMesh,
## PRIMITIVE_TRIANGLES), not PRIMITIVE_LINES.

@export var path_in_range_color: Color = Color(1, 1, 1, 0.5)
@export var path_out_of_range_color: Color = Color(1, 0, 0, 0.5)
## Total arc length (meters) over which the color smoothly blends from
## path_in_range_color to path_out_of_range_color, centered on the
## move_remaining budget boundary — see _draw_textured_ribbon/
## _color_at_arc_length. 0 reproduces a hard, instant color cut exactly
## at the boundary.
@export var color_transition_length: float = 0
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
## Ribbon width (meters) — see movement_indicator_line.gdshader.
@export var line_width: float = 0.05
## Fraction of the ribbon's width spent fading in from each edge — see
## the shader's edge_softness. Smaller reads as a crisper edge; 0.5 (the
## max) fades continuously from edge to centerline with no flat plateau
## at all. Kept high/soft since the gradient falloff IS the whole
## visual, not a halo around something crisper.
@export var edge_softness: float = 0.5
## Multiplies brightness past the scene's glow_hdr_threshold (Environment
## default 1.0) so the line actually blooms — see
## movement_indicator_line.gdshader's brightness_boost uniform.
@export var brightness_boost: float = 2.5

const LINE_SHADER: Shader = preload("res://movement_indicator_line.gdshader")

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

	var mat := ShaderMaterial.new()
	mat.shader = LINE_SHADER
	mat.set_shader_parameter("edge_softness", edge_softness)
	mat.set_shader_parameter("brightness_boost", brightness_boost)
	_path_mesh.material_override = mat


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

	# Mirrors UnitMovement.move_to()'s own ladder branch exactly (see
	# Ladder.find_route) — same query, same affordability check, so this
	# preview can never show a climb the real move wouldn't also perform,
	# or vice versa. Bypasses the ordinary cached-query path entirely
	# below; see _update_ladder_preview for why.
	if not unit.is_flying():
		var route: Dictionary = Ladder.find_route(unit, hover_point)
		if not route.is_empty():
			_update_ladder_preview(unit, route, hover_point)
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


## Ladder-aware counterpart to the tail end of _update_path_preview above
## — see Ladder.find_route for `route`'s shape. Reuses _draw_path
## completely unchanged in both branches below; only how the (path,
## cumulative_cost) pair fed into it gets assembled differs.
func _update_ladder_preview(unit: Unit, route: Dictionary, hover_point: Vector3) -> void:
	if not route.affordable:
		# Can't afford the climb this turn — show exactly what
		# UnitMovement.move_to() will actually do: walk toward the
		# ladder's near point, ordinary in-range/out-of-range split, and
		# nothing beyond it. Never draw a climb that won't happen — the
		# whole point of this ladder's "no partial movement" design is
		# that the preview must never promise an outcome the execution
		# can't deliver.
		var near_planned: Dictionary = route.near_planned
		if near_planned.path.size() < 2:
			_path_mesh.visible = false
			return
		_draw_path(near_planned.path, near_planned.cumulative_cost, unit.move_remaining)
		_path_mesh.visible = true
		return

	# Affordable — build ONE combined path spanning all three legs (walk
	# to near, the climb itself as a flat required_move cost, walk from
	# far toward the actual hover point) and hand it to the exact same
	# _draw_path used for an ordinary move. _draw_path only ever needs a
	# path + parallel cumulative cost + a budget; it doesn't care whether
	# a given segment's cost came from ordinary walking or a ladder's
	# flat climb cost, so no drawing logic needs to change for this case
	# at all.
	var combined_path: PackedVector3Array = route.near_planned.path.duplicate()
	var combined_cost: PackedFloat32Array = route.near_planned.cumulative_cost.duplicate()
	var base_cost: float = combined_cost[combined_cost.size() - 1] if combined_cost.size() > 0 else 0.0

	# The climb segment itself — the SAME base-to-top canonical path
	# (reversed for a descent, via route.going_up) UnitMovement.
	# _climb_ladder actually animates, NOT a straight line from near to
	# far. A straight line is the exact clipping bug already found and
	# fixed once in the real movement (see Ladder.climb_waypoints' own
	# header) — drawing one here instead would silently reintroduce it
	# in the preview only, showing a line cutting through geometry the
	# real climb now correctly detours around.
	var climb_points: PackedVector3Array = Ladder.climb_waypoints(route.ladder.base_position(), route.ladder.top_position())
	if not route.going_up:
		climb_points.reverse()
	var climb_total: float = base_cost
	for i in range(1, climb_points.size()):
		combined_path.append(climb_points[i])
		climb_total = base_cost + (route.ladder.required_move if i == climb_points.size() - 1 else 0.0)
		combined_cost.append(climb_total)

	var tail_waypoints: PackedVector3Array = NavigationGrid.find_path(unit.get_tree(), route.far, hover_point, unit, false)
	if tail_waypoints.size() >= 2:
		var tail_planned: Dictionary = RoutePlanner.plan(tail_waypoints, 9999.0, SurfaceManager.movement_cost_multiplier_at)
		for i in range(1, tail_planned.path.size()):
			combined_path.append(tail_planned.path[i])
			combined_cost.append(climb_total + tail_planned.cumulative_cost[i])

	_draw_path(combined_path, combined_cost, unit.move_remaining)
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
## Each sub-path is corner-rounded SEPARATELY (see _round_corners — it
## keeps endpoints exact, so the split point stays at its precise
## interpolated position in both halves rather than getting rounded away
## from the true budget edge), then the two rounded halves are
## concatenated into one continuous polyline (dropping the duplicate
## split-point vertex where they join) and drawn as a single ribbon —
## see _draw_textured_ribbon/_color_at_arc_length for how that ribbon's
## per-vertex color smoothly blends across the budget boundary instead
## of the two halves each being a single flat color with a hard cut
## between them.
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

	if out_of_range_rounded.size() < 2:
		# The whole path fits comfortably within move_remaining — there's
		# no real budget boundary anywhere on it at all, so split_point
		# above is just a leftover placeholder value, not a true edge to
		# blend toward. INF as the split position makes
		# _color_at_arc_length naturally resolve to pure
		# path_in_range_color everywhere (see its own comment) without a
		# separate code path here.
		_draw_textured_ribbon(in_range_rounded, INF, lift, line_width)
		return

	var combined := in_range_rounded.duplicate()
	for i in range(1, out_of_range_rounded.size()):
		combined.append(out_of_range_rounded[i])

	var split_arc_length := 0.0
	for i in range(1, in_range_rounded.size()):
		split_arc_length += in_range_rounded[i - 1].distance_to(in_range_rounded[i])

	_draw_textured_ribbon(combined, split_arc_length, lift, line_width)


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


## Draws `points` (already corner-rounded, ONE continuous polyline
## spanning the whole path — see _draw_path for why the in-range and
## out-of-range halves get concatenated before reaching here) into
## _path_immediate. UV.y is 0 at the left edge, 1 at the right, for the
## shader's width falloff (see movement_indicator_line.gdshader) — the
## only UV component the current shader actually reads. UV.x is still
## tracked as cumulative arc length in meters, even though nothing
## currently samples it — cheap to keep computing correctly, and would
## make a future animated-flow or length-based effect a small addition
## rather than a rework. Reused as the input to _color_at_arc_length,
## which is where each vertex's actual color comes from — not a single
## flat tint for the whole ribbon, see that function.
##
## Uses a proper miter join: one perpendicular PER POINT (via
## _miter_perpendiculars), not one per segment — otherwise two quads
## meeting at a bend each compute their own perpendicular from only
## their own segment's direction and disagree on where their shared edge
## actually is, leaving a visible gap or overlap at every corner.
## Sharing one perpendicular per point makes adjacent quads agree
## exactly on the joint's edge vertices instead.
func _draw_textured_ribbon(points: PackedVector3Array, split_arc_length: float, lift: Vector3, width: float) -> void:
	if points.size() < 2 or width <= 0.0:
		return

	var lifted := PackedVector3Array()
	for p in points:
		lifted.append(p + lift)

	var cumulative := PackedFloat32Array()
	cumulative.resize(lifted.size())
	cumulative[0] = 0.0
	for i in range(1, lifted.size()):
		cumulative[i] = cumulative[i - 1] + lifted[i - 1].distance_to(lifted[i])

	var perps := _miter_perpendiculars(lifted, width * 0.5)
	var half_transition: float = color_transition_length * 0.5

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	for i in range(1, lifted.size()):
		if cumulative[i] - cumulative[i - 1] < 0.0001:
			continue
		var a: Vector3 = lifted[i - 1]
		var b: Vector3 = lifted[i]
		var perp_a: Vector3 = perps[i - 1]
		var perp_b: Vector3 = perps[i]
		var uv_a: float = cumulative[i - 1]
		var uv_b: float = cumulative[i]
		var color_a: Color = _color_at_arc_length(uv_a, split_arc_length, half_transition)
		var color_b: Color = _color_at_arc_length(uv_b, split_arc_length, half_transition)

		vertices.append(a - perp_a)
		uvs.append(Vector2(uv_a, 0.0))
		colors.append(color_a)
		vertices.append(a + perp_a)
		uvs.append(Vector2(uv_a, 1.0))
		colors.append(color_a)
		vertices.append(b + perp_b)
		uvs.append(Vector2(uv_b, 1.0))
		colors.append(color_b)

		vertices.append(a - perp_a)
		uvs.append(Vector2(uv_a, 0.0))
		colors.append(color_a)
		vertices.append(b + perp_b)
		uvs.append(Vector2(uv_b, 1.0))
		colors.append(color_b)
		vertices.append(b - perp_b)
		uvs.append(Vector2(uv_b, 0.0))
		colors.append(color_b)

	if vertices.is_empty():
		return

	_path_immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(vertices.size()):
		_path_immediate.surface_set_color(colors[i])
		_path_immediate.surface_set_uv(uvs[i])
		_path_immediate.surface_add_vertex(vertices[i])
	_path_immediate.surface_end()


## Color for a vertex at `arc_length` along the ribbon, blending smoothly
## between path_in_range_color and path_out_of_range_color across
## `half_transition` meters on each side of `split_arc_length` (the
## move_remaining budget boundary) — an exact 50/50 mix precisely AT the
## boundary, pure path_in_range_color at half_transition or more before
## it, pure path_out_of_range_color at half_transition or more after.
## half_transition<=0 reproduces a hard, instant cut. split_arc_length
## can be INF (see _draw_path) to mean "no real boundary on this
## ribbon" — every finite arc_length then reads as arbitrarily far
## "before" it, which this formula already resolves to pure
## path_in_range_color without needing a separate branch for that case.
func _color_at_arc_length(arc_length: float, split_arc_length: float, half_transition: float) -> Color:
	if half_transition <= 0.0:
		return path_out_of_range_color if arc_length >= split_arc_length else path_in_range_color
	var t: float = clamp((arc_length - split_arc_length) / half_transition, -1.0, 1.0)
	var t01: float = (t + 1.0) * 0.5
	return path_in_range_color.lerp(path_out_of_range_color, t01)


## One ribbon-width perpendicular per point in `lifted`, for a proper
## miter join (see _draw_textured_ribbon) — at an interior point, this
## is the perpendicular of the AVERAGED incoming/outgoing segment
## direction rather than either segment's own, so both quads sharing
## that point use the exact same edge vertices there. At an endpoint
## (only one adjacent segment exists) it's just that segment's own
## perpendicular.
##
## Scaled by 1/cos(half the turn angle) — the standard miter-length
## correction. Without it, a shared perpendicular angled between two
## segments doesn't reach `half_width` measured perpendicular to either
## ACTUAL segment, so the ribbon would visibly pinch thinner at every
## bend. The correction blows up toward a sharp spike as the turn
## approaches a full reversal (a well-known miter-join degenerate case),
## guarded by falling back to no correction there — not a real concern
## in practice since _round_corners already keeps the turn angle at any
## one point small (it subdivides each corner into corner_round_segments
## pieces), never a sharp reversal.
func _miter_perpendiculars(lifted: PackedVector3Array, half_width: float) -> PackedVector3Array:
	var perps := PackedVector3Array()
	perps.resize(lifted.size())
	for i in range(lifted.size()):
		var dir_in := Vector3.ZERO
		var dir_out := Vector3.ZERO
		if i > 0:
			var d: Vector3 = lifted[i] - lifted[i - 1]
			if d.length() > 0.0001:
				dir_in = d.normalized()
		if i < lifted.size() - 1:
			var d: Vector3 = lifted[i + 1] - lifted[i]
			if d.length() > 0.0001:
				dir_out = d.normalized()

		var miter_dir: Vector3 = dir_in + dir_out
		if miter_dir.length() < 0.0001:
			miter_dir = dir_in if dir_in.length() > 0.0001 else dir_out

		var stretch: float = 1.0
		if dir_in.length() > 0.0001 and dir_out.length() > 0.0001:
			var cos_half_angle: float = sqrt(max(0.0, (1.0 + dir_in.dot(dir_out)) * 0.5))
			if cos_half_angle > 0.2:
				stretch = 1.0 / cos_half_angle

		perps[i] = _horizontal_perpendicular(miter_dir) * half_width * stretch
	return perps


## Sideways (XZ-plane) direction perpendicular to `direction`, for a
## flat ground-hugging ribbon's width — always horizontal regardless of
## `direction`'s own slope, so the ribbon reads as a constant-width
## trail seen from above rather than one that thins out as the path
## steepens (relevant for a flying unit's path, which can bend up/down).
## Falls back to world right when `direction` is purely vertical (no
## horizontal component to rotate) — an edge case straight-up/down
## flight movement can hit.
func _horizontal_perpendicular(direction: Vector3) -> Vector3:
	var horizontal := Vector2(direction.x, direction.z)
	if horizontal.length() < 0.001:
		return Vector3.RIGHT
	horizontal = horizontal.normalized()
	return Vector3(-horizontal.y, 0.0, horizontal.x)

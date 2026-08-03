extends Node3D
## Movement path preview, BG3-style. Only shows during combat, for the
## unit whose turn it currently is, and only if that unit is
## player-controlled (Unit.is_player_controlled) — the AI's turns don't
## get this, and neither does anything out of combat.
##
## Scene setup: attach this script to any plain Node3D in your main scene
## — it builds its own child MeshInstance3D visuals in code, nothing else
## needs to be wired up. Requires ground_collision_mask to match whatever
## physics layer your ground/terrain body (see ground_click_target.gd) is
## actually on, so mouse hover can be raycast onto it.
##
## A line follows the EXACT planned route (via PathAvoidance.simulate_path
## — the same deterministic planner Unit.move_to() itself calls) from the
## unit to wherever the mouse is hovering, colored white for the portion
## within move_remaining and red for the portion beyond it. Since this
## calls the literal same planning function the real move will use, with
## the same obstacle data, this preview IS what will happen — not an
## approximation of it.
##
## Note: this draws a 1-pixel unshaded line (ImmediateMesh, LINE_STRIP) —
## fine for a first pass, but Godot doesn't give line primitives real
## width without building an actual ribbon mesh. If you want a visibly
## thick line later, that's a natural follow-up.

@export var ground_collision_mask: int = 1
@export var path_in_range_color: Color = Color(1, 1, 1, 0.9)
@export var path_out_of_range_color: Color = Color(1, 0.2, 0.2, 0.9)
## Lifts the line slightly above the ground to avoid z-fighting with
## terrain geometry.
@export var height_offset: float = 0.05

var _path_mesh: MeshInstance3D
var _path_immediate: ImmediateMesh


func _ready() -> void:
	_build_path_line()


func _build_path_line() -> void:
	_path_mesh = MeshInstance3D.new()
	add_child(_path_mesh)

	_path_immediate = ImmediateMesh.new()
	_path_mesh.mesh = _path_immediate

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_path_mesh.material_override = mat
	_path_mesh.visible = false


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	if not unit:
		_hide_all()
		return

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


func _update_path_preview(unit: Unit) -> void:
	var hover_point = _get_mouse_ground_point()
	if hover_point == null:
		_path_mesh.visible = false
		return

	var map_rid: RID = unit.nav_agent.get_navigation_map()
	var obstacles: Dictionary = PathAvoidance.gather_obstacles(get_tree(), [unit])
	var clearance: float = unit.radius + unit.avoidance_margin

	# Sanitize the hover point the same way move_to() sanitizes a move
	# goal (see PathAvoidance.clear_goal) — hovering directly over
	# another unit would otherwise have nothing valid to plan toward.
	var safe_hover_point: Vector3 = PathAvoidance.clear_goal(hover_point, obstacles.positions, obstacles.radii, clearance, map_rid)

	var waypoints: PackedVector3Array = NavigationServer3D.map_get_path(map_rid, unit.global_position, safe_hover_point, true)
	if waypoints.size() < 2:
		_path_mesh.visible = false
		return

	# The SAME planning call move_to() itself makes — a large budget here
	# gets the full route to the hover point regardless of move_remaining;
	# the white/red split below is what shows how far the unit could
	# actually get this turn. Because this is the literal same
	# deterministic function with the same obstacle data, this preview
	# and the real move can never disagree.
	var path: PackedVector3Array = PathAvoidance.simulate_path(
		waypoints, unit.move_speed, 9999.0,
		obstacles.positions, obstacles.radii, clearance, unit.avoidance_margin, unit.arrival_tolerance, map_rid
	)

	if path.size() < 2:
		_path_mesh.visible = false
		return

	_draw_path(path, unit.move_remaining)
	_path_mesh.visible = true


func _get_mouse_ground_point():
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = from + dir * 1000.0

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = ground_collision_mask
	var result := space_state.intersect_ray(query)

	if result.is_empty():
		return null
	return result.position


## Rebuilds the path line each frame, split into a white segment
## (cumulative distance <= budget) and a red segment (the rest). The split
## point is interpolated along whichever path segment crosses the budget
## boundary, so the color change lands exactly at the true edge of
## move_remaining rather than snapping to the nearest path vertex.
func _draw_path(path: PackedVector3Array, budget: float) -> void:
	_path_immediate.clear_surfaces()
	_path_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)

	var lift := Vector3(0, height_offset, 0)
	var accumulated: float = 0.0
	var split_done: bool = budget <= 0.0

	_path_immediate.surface_set_color(path_out_of_range_color if split_done else path_in_range_color)
	_path_immediate.surface_add_vertex(path[0] + lift)

	for i in range(1, path.size()):
		var segment_start: Vector3 = path[i - 1]
		var segment_end: Vector3 = path[i]
		var segment_length: float = segment_start.distance_to(segment_end)

		if not split_done and accumulated + segment_length >= budget:
			var remaining: float = budget - accumulated
			var t: float = (remaining / segment_length) if segment_length > 0.0 else 0.0
			var split_point: Vector3 = segment_start.lerp(segment_end, t)

			_path_immediate.surface_set_color(path_in_range_color)
			_path_immediate.surface_add_vertex(split_point + lift)

			_path_immediate.surface_set_color(path_out_of_range_color)
			_path_immediate.surface_add_vertex(split_point + lift)

			split_done = true

		accumulated += segment_length
		_path_immediate.surface_set_color(path_out_of_range_color if split_done else path_in_range_color)
		_path_immediate.surface_add_vertex(segment_end + lift)

	_path_immediate.surface_end()

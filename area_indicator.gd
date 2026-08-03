extends Node3D
## AoE ability preview, BG3-style: a line from caster to the hovered
## point (colored by range/line-of-sight, same states as
## line_of_sight_indicator.gd), plus a RING outline at that point sized
## to the real blast radius — read directly from the armed ability's own
## AreaDamageEffect, not a duplicated/guessed value, same WYSIWYG
## principle as the other indicators. A ring rather than a filled disc
## deliberately — an outline shows exactly what's inside the blast
## without obscuring it, and matches how every other indicator in this
## project draws via line primitives rather than solid meshes.
##
## Only shows during combat, for the unit whose turn it currently is,
## only when player-controlled, and only when the currently armed
## ability uses AreaTargeting.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own visuals in code. ground_collision_mask must match whatever
## physics layer your ground/terrain body is on.

@export var ground_collision_mask: int = 1
@export var clear_color: Color = Color(1, 1, 1, 0.9)
@export var blocked_color: Color = Color(1, 0.2, 0.2, 0.9)
@export var out_of_range_color: Color = Color(0.5, 0.5, 0.5, 0.6)
@export var line_height_offset: float = 1.5
@export var ring_color: Color = Color(1, 0.5, 0.1, 0.9)
@export var ring_height_offset: float = 0.05
@export var ring_segments: int = 48

var _line_mesh: MeshInstance3D
var _line_immediate: ImmediateMesh
var _ring_mesh: MeshInstance3D
var _ring_immediate: ImmediateMesh


func _ready() -> void:
	_build_line()
	_build_ring()


func _build_line() -> void:
	_line_mesh = MeshInstance3D.new()
	add_child(_line_mesh)

	_line_immediate = ImmediateMesh.new()
	_line_mesh.mesh = _line_immediate

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_line_mesh.material_override = mat
	_line_mesh.visible = false


func _build_ring() -> void:
	_ring_mesh = MeshInstance3D.new()
	add_child(_ring_mesh)

	_ring_immediate = ImmediateMesh.new()
	_ring_mesh.mesh = _ring_immediate

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_mesh.material_override = mat
	_ring_mesh.visible = false


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	var ability := _get_armed_area_ability()

	if not unit or not ability:
		_hide_all()
		return

	var hover_point = _get_mouse_ground_point()
	if hover_point == null:
		_hide_all()
		return

	_update_line(unit, ability, hover_point)
	_update_ring(ability, hover_point)


func _hide_all() -> void:
	if _line_mesh:
		_line_mesh.visible = false
	if _ring_mesh:
		_ring_mesh.visible = false


func _get_active_unit() -> Unit:
	return PlayerInteractionState.get_active_unit()


func _get_armed_area_ability() -> Ability:
	return PlayerInteractionState.get_armed_ability_of_targeting_type(AreaTargeting)


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


func _update_line(unit: Unit, ability: Ability, hover_point: Vector3) -> void:
	var targeting: AreaTargeting = ability.targeting

	var color: Color
	if unit.global_position.distance_to(hover_point) > targeting.max_range:
		color = out_of_range_color
	elif targeting.requires_line_of_sight and not LineOfSight.has_clear_shot_to_point(unit, hover_point, targeting.los_obstruction_mask, targeting.eye_height):
		color = blocked_color
	else:
		color = clear_color

	var from: Vector3 = unit.global_position + Vector3(0, line_height_offset, 0)
	var to: Vector3 = hover_point + Vector3(0, line_height_offset, 0)

	_line_immediate.clear_surfaces()
	_line_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(from)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(to)
	_line_immediate.surface_end()
	_line_mesh.visible = true


func _update_ring(ability: Ability, hover_point: Vector3) -> void:
	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		_ring_mesh.visible = false
		return

	_draw_ring(hover_point, targeting.radius)
	_ring_mesh.visible = true


func _draw_ring(center: Vector3, radius: float) -> void:
	_ring_immediate.clear_surfaces()
	_ring_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)

	for i in range(ring_segments + 1):
		var angle: float = (float(i) / ring_segments) * TAU
		var point: Vector3 = center + Vector3(cos(angle), 0.0, sin(angle)) * radius
		point.y += ring_height_offset
		_ring_immediate.surface_set_color(ring_color)
		_ring_immediate.surface_add_vertex(point)

	_ring_immediate.surface_end()

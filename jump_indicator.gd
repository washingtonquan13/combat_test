extends Node3D
## Jump arc preview, BG3-style — matches MoveCasterEffect's actual
## trajectory exactly (same arc math, same budget clamp, both called
## directly rather than reimplemented here) so what's shown is what will
## happen, not an approximation of it. Same principle as the movement
## path preview and the LoS indicator.
##
## Only shows during combat, for the unit whose turn it currently is,
## only when that unit is player-controlled, and only when the currently
## armed ability (see AbilityManager) uses GroundPointTargeting.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own line mesh in code. ground_collision_mask must match whatever
## physics layer your ground/terrain body is on (same requirement as
## movement_indicator.gd's hover raycast).

@export var ground_collision_mask: int = 1
@export var valid_color: Color = Color(1, 1, 1, 0.9)
@export var invalid_color: Color = Color(1, 0.2, 0.2, 0.9)
@export var arc_segments: int = 24

var _line_mesh: MeshInstance3D
var _line_immediate: ImmediateMesh


func _ready() -> void:
	_build_line()


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


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	var move_effect := _get_armed_move_effect()

	if not unit or not move_effect:
		_line_mesh.visible = false
		return

	var hover_point = _get_mouse_ground_point()
	if hover_point == null:
		_line_mesh.visible = false
		return

	_draw_arc(unit, AbilityManager.armed_ability, move_effect, hover_point)
	_line_mesh.visible = true


func _get_active_unit() -> Unit:
	if not CombatManager.in_combat:
		return null

	var unit: Unit = CombatManager.current_unit
	if not unit or not is_instance_valid(unit) or not unit.is_alive():
		return null
	if not unit.is_player_controlled():
		return null

	return unit


## The armed ability's own MoveCasterEffect instance (not a new one) —
## calling ITS arc_point()/clamp_to_budget() is what guarantees the
## preview matches whatever jump_duration/arc_height that SPECIFIC
## ability was actually configured with.
func _get_armed_move_effect() -> MoveCasterEffect:
	var ability: Ability = AbilityManager.armed_ability
	if not ability or not (ability.targeting is GroundPointTargeting):
		return null

	for effect in ability.effects:
		if effect is MoveCasterEffect:
			return effect

	return null


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


func _draw_arc(unit: Unit, ability: Ability, move_effect: MoveCasterEffect, hover_point: Vector3) -> void:
	# The REAL landing point after budget clamping, not just wherever the
	# mouse is — if there's not enough move_remaining to cover the full
	# distance, the actual jump lands short, so the preview should too.
	var landing_point: Vector3 = move_effect.clamp_to_budget(unit, hover_point)
	var valid: bool = ability.targeting.is_valid_target(unit, landing_point)
	var color: Color = valid_color if valid else invalid_color

	var start: Vector3 = unit.global_position

	_line_immediate.clear_surfaces()
	_line_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)

	for i in range(arc_segments + 1):
		var t: float = float(i) / arc_segments
		var point: Vector3 = move_effect.arc_point(start, landing_point, t)
		_line_immediate.surface_set_color(color)
		_line_immediate.surface_add_vertex(point)

	_line_immediate.surface_end()

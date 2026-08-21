class_name AreaIndicator
extends IndicatorBase
## AoE ability preview, BG3-style: a line from caster to the hovered
## point (colored by range/line-of-sight, same states as
## line_of_sight_indicator.gd), plus a RING outline at that point sized
## to the real blast radius — read directly from the armed ability's own
## AreaTargeting, not a duplicated/guessed value, same WYSIWYG principle
## as the other indicators. A ring rather than a filled disc
## deliberately — an outline shows exactly what's inside the blast
## without obscuring it, and matches how every other indicator in this
## project draws via line primitives rather than solid meshes.
##
## FLOOR-ONLY — the center always sits wherever the ground raycast hit,
## with no way to lift it. Deliberate: this indicator is for abilities
## where an airborne blast center wouldn't make sense (Grease, which
## spawns a ground-hugging Surface — see SpawnSurfaceEffect/Surface,
## detection_height=0.05 on grease.tres's own Surface sub-resource). For
## an ability that genuinely CAN be aimed in open 3D space (Fireball),
## see aerial_area_indicator.gd/AerialAreaTargeting instead — this
## indicator explicitly EXCLUDES those (see _get_armed_area_ability) so
## the two never both show for the same armed ability.
##
## Only shows during combat, for the unit whose turn it currently is,
## only when player-controlled, and only when the currently armed
## ability uses AreaTargeting (but not AerialAreaTargeting).
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own visuals in code. ground_collision_mask (see IndicatorBase)
## must match whatever physics layer your ground/terrain body is on.

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
	var line_built: Dictionary = _create_line_mesh()
	_line_mesh = line_built.mesh_instance
	_line_immediate = line_built.immediate

	var ring_built: Dictionary = _create_line_mesh()
	_ring_mesh = ring_built.mesh_instance
	_ring_immediate = ring_built.immediate


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


## Excludes AerialAreaTargeting even though it IS an AreaTargeting (see
## this file's header) — aerial_area_indicator.gd shows the 3D-aware
## preview for those instead, and the two would otherwise both draw for
## the same armed ability.
func _get_armed_area_ability() -> Ability:
	var ability := PlayerInteractionState.get_armed_ability_of_targeting_type(AreaTargeting)
	if ability and ability.targeting is AerialAreaTargeting:
		return null
	return ability


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

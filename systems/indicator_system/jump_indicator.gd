extends IndicatorBase
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
## its own line mesh in code. ground_collision_mask (see IndicatorBase)
## must match whatever physics layer your ground/terrain body is on.

@export var valid_color: Color = Color(1, 1, 1, 0.9)
@export var invalid_color: Color = Color(1, 0.2, 0.2, 0.9)
@export var arc_segments: int = 24

var _line_mesh: MeshInstance3D
var _line_immediate: ImmediateMesh


func serves() -> StringName:
	return &"jump"


func _ready() -> void:
	super()
	var built: Dictionary = _create_line_mesh()
	_line_mesh = built.mesh_instance
	_line_immediate = built.immediate


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	var ability: Ability = AbilityManager.armed_ability
	var move_effect: MoveCasterEffect = ability.get_move_caster_effect() if ability else null

	if not unit or not move_effect:
		_line_mesh.visible = false
		return

	var hover_point = _get_mouse_ground_point()
	if hover_point == null:
		_line_mesh.visible = false
		return

	_draw_arc(unit, ability, move_effect, hover_point)
	_line_mesh.visible = true


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

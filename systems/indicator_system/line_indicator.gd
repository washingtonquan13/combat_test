class_name LineIndicator
extends IndicatorBase
## LineTargeting preview (Wall of Fire). Before the first click: a line
## from the caster to the hovered point, colored by range/line of sight
## like area_indicator.gd's, for where the line may start. After it: the
## wall's outline standing from the held start to where the second click
## would end it — pulled in to max_length by LineTargeting.end_for(), the
## same call the click makes, and as tall as the armed ability's wall
## surface — colored by whether that line is a legal target.

@export var clear_color: Color = Color(1, 1, 1, 0.9)
@export var blocked_color: Color = Color(1, 0.2, 0.2, 0.9)
@export var out_of_range_color: Color = Color(0.5, 0.5, 0.5, 0.6)
@export var line_height_offset: float = 1.5
@export var wall_color: Color = Color(1, 0.5, 0.1, 0.9)
@export var ground_offset: float = 0.05

var _line_mesh: MeshInstance3D
var _line_immediate: ImmediateMesh


func serves() -> StringName:
	return &"line"


func _ready() -> void:
	super()
	var built: Dictionary = _create_line_mesh()
	_line_mesh = built.mesh_instance
	_line_immediate = built.immediate


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	var ability: Ability = AbilityManager.armed_ability
	var targeting: LineTargeting = ability.targeting as LineTargeting if ability else null
	var hover_point = _get_mouse_ground_point()
	if not unit or not targeting or hover_point == null:
		_line_mesh.visible = false
		return
	if AbilityManager.has_line_start:
		_draw_wall(unit, ability, targeting, AbilityManager.line_start, hover_point)
	else:
		_draw_aim(unit, targeting, hover_point)
	_line_mesh.visible = true


func _draw_aim(unit: Unit, targeting: LineTargeting, hover_point: Vector3) -> void:
	var color: Color = clear_color
	if unit.global_position.distance_to(hover_point) > targeting.max_range:
		color = out_of_range_color
	elif not targeting.can_reach(unit, hover_point):
		color = blocked_color
	var lift := Vector3(0, line_height_offset, 0)
	_strip([unit.global_position + lift, hover_point + lift], color)


func _draw_wall(unit: Unit, ability: Ability, targeting: LineTargeting, start: Vector3, hover_point: Vector3) -> void:
	var end: Vector3 = targeting.end_for(start, hover_point)
	var legal: bool = targeting.is_valid_target(unit, LineTarget.new(start, end))
	var up := Vector3(0, _wall_height(ability), 0)
	var lift := Vector3(0, ground_offset, 0)
	_strip([start + lift, end + lift, end + up, start + up, start + lift], wall_color if legal else blocked_color)


func _strip(points: Array[Vector3], color: Color) -> void:
	_line_immediate.clear_surfaces()
	_line_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for point in points:
		_line_immediate.surface_set_color(color)
		_line_immediate.surface_add_vertex(point)
	_line_immediate.surface_end()


## The wall's height, from the surface the ability raises — no separate
## preview value to drift from it.
func _wall_height(ability: Ability) -> float:
	for effect in ability.effects:
		if effect is SpawnSurfaceEffect and effect.surface:
			return effect.surface.wall_height
	return 0.0

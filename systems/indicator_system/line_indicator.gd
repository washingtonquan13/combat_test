class_name LineIndicator
extends IndicatorBase
## LineTargeting preview (Wall of Fire). Before the first click: a line
## from the caster to the hovered point, colored by range/line of sight
## like area_indicator.gd's, for where the line may start. After it: the
## wall's outline standing from the held start to where the second click
## would end it — pulled in to max_length by LineTargeting.end_for(), the
## same call the click makes, and as tall as the armed ability's wall
## surface — colored by whether that line is a legal target. Ctrl-drag
## lifts the hovered point into the air; Aim.point arrives already lifted
## (LineTargeting.resolve_target_point, the same call the click makes),
## so the click takes that height too. The aim line's colour is
## LineTargeting.check_point(), the rule both clicks share.

@export var clear_color: Color = IndicatorPalette.OK
@export var blocked_color: Color = IndicatorPalette.BLOCKED
@export var out_of_range_color: Color = IndicatorPalette.OUT_OF_REACH
@export var line_height_offset: float = 1.5
## A legal wall's outline. It was orange, which sat right beside the red
## of a refused one; the outline IS the answer to "can I end it here",
## so it takes the answer colour.
@export var wall_color: Color = IndicatorPalette.OK
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


func draw(aim: Aim) -> void:
	var unit: Unit = aim.caster
	var ability: Ability = aim.ability
	var targeting: LineTargeting = ability.targeting as LineTargeting if ability else null
	var hover_point = aim.point
	if not unit or not targeting or hover_point == null:
		_line_mesh.visible = false
		return
	if AbilityManager.has_line_start:
		_draw_wall(unit, ability, targeting, AbilityManager.line_start, hover_point)
	else:
		_draw_aim(unit, targeting, hover_point)
	_line_mesh.visible = true


func _draw_aim(unit: Unit, targeting: LineTargeting, hover_point: Vector3) -> void:
	# BLOCKED and INVALID both mean "this click is refused".
	var color: Color
	match targeting.check_point(unit, hover_point):
		AbilityTargeting.Reach.OK:
			color = clear_color
		AbilityTargeting.Reach.OUT_OF_RANGE:
			color = out_of_range_color
		_:
			color = blocked_color
	var lift := Vector3(0, line_height_offset, 0)
	_strip([unit.global_position + lift, hover_point + lift], color)


func _draw_wall(unit: Unit, ability: Ability, targeting: LineTargeting, start: Vector3, hover_point: Vector3) -> void:
	var end: Vector3 = targeting.end_for(start, hover_point)
	var legal: bool = targeting.is_valid_target(unit, LineTarget.new(start, end))
	var up := Vector3(0, _wall_height(ability), 0)
	var lift := Vector3(0, ground_offset, 0)
	_strip([start + lift, end + lift, end + up, start + up, start + lift], wall_color if legal else blocked_color)


## Camera-facing: both the aim line and the wall's posts stand in the
## air, where a flat ribbon would be seen edge-on.
func _strip(points: Array[Vector3], color: Color) -> void:
	_line_immediate.clear_surfaces()
	_add_ribbon(_line_immediate, PackedVector3Array(points), PackedColorArray([color]), LINE_WIDTH, LINE_EDGE, true)


## The wall's height, from the surface the ability raises — no separate
## preview value to drift from it.
func _wall_height(ability: Ability) -> float:
	for effect in ability.effects:
		if effect is SpawnSurfaceEffect and effect.surface:
			return effect.surface.wall_height
	return 0.0

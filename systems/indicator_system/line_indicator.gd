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
## LineTargeting.check_point(), the rule both clicks share. The wall
## itself is an AoeShell BOX, neutral when the second click is legal and
## the refused colour when not, and everyone it would stand on is
## outlined.

@export var clear_color: Color = IndicatorPalette.OK
@export var blocked_color: Color = IndicatorPalette.BLOCKED
@export var out_of_range_color: Color = IndicatorPalette.OUT_OF_REACH
@export var line_height_offset: float = 1.5
## A legal wall's shell: the neutral AoE tint every area preview shares.
## A refused one takes blocked_color, the answer to "can I end it here".
@export var wall_color: Color = IndicatorPalette.AOE

## The aim line's end fades; the wall outline has none.
const AIM_FADE: float = 0.3

var _line_mesh: PathTube
var _shell: AoeShell
## Height over the floor of the point being aimed (the line's start
## before the first click, its end after), when that is in the air.
var _altitude: AltitudeMarker


func serves() -> StringName:
	return &"line"


func _ready() -> void:
	super()
	_line_mesh = _create_tube()
	_shell = AoeShell.new()
	add_child(_shell)
	_owned_meshes.append(_shell)
	_altitude = _create_altitude_marker()


func draw(aim: Aim) -> void:
	var unit: Unit = aim.caster
	var ability: Ability = aim.ability
	var targeting: LineTargeting = ability.targeting as LineTargeting if ability else null
	var hover_point = aim.point
	if not unit or not targeting or hover_point == null:
		hide_visuals()
		return
	if AbilityManager.has_line_start:
		_line_mesh.visible = false
		var end: Vector3 = targeting.end_for(AbilityManager.line_start, hover_point)
		_draw_wall(unit, ability, targeting, AbilityManager.line_start, hover_point)
		_altitude.show_at(end, AltitudeMarker.floor_under(aim, end), wall_color)
	else:
		_shell.visible = false
		_set_targets([])
		_draw_aim(unit, targeting, hover_point)
		_altitude.show_at(hover_point, AltitudeMarker.floor_under(aim, hover_point), clear_color)


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
	_line_mesh.fade_start = AIM_FADE
	_line_mesh.fade_end = AIM_FADE
	_line_mesh.show_line(PackedVector3Array([unit.global_position + lift, hover_point + lift]), color)


func _draw_wall(unit: Unit, ability: Ability, targeting: LineTargeting, start: Vector3, hover_point: Vector3) -> void:
	var end: Vector3 = targeting.end_for(start, hover_point)
	var legal: bool = targeting.is_valid_target(unit, LineTarget.new(start, end))
	_shell.set_tint(wall_color if legal else blocked_color)
	_shell.show_box(start, end, _wall_height(ability), SurfaceManager.WALL_HALF_THICKNESS)
	# A spawned surface filters no one: everyone it stands on is caught.
	_set_targets(UnitQuery.line_affected(unit.get_tree(), unit, start, end, SurfaceManager.WALL_HALF_THICKNESS))


## The wall's height, from the surface the ability raises — no separate
## preview value to drift from it.
func _wall_height(ability: Ability) -> float:
	for effect in ability.effects:
		if effect is SpawnSurfaceEffect and effect.surface:
			return effect.surface.wall_height
	return 0.0

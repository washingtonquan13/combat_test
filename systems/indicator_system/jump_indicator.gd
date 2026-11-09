extends IndicatorBase
## Flight arc preview, BG3-style: the curve a Jump flies its caster along,
## or a Shove flies its target along, drawn with the same ArcFlight curve
## and the same landing rules the flight itself uses (landing_for and
## check() for a jump, KnockbackEffect.landing_point for a shove), called
## rather than reimplemented, so what's shown is what will happen.
##
## A curve that runs into a wall is drawn only up to the wall
## (ArcFlight.clear_fraction), never through it. A jump that hits one is
## refused, so its stub shows red; a shove already stops at the wall, so
## its arc ends there anyway.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own line mesh in code. The hovered point and unit come from the Aim
## ClickRouter hands draw(); nothing here raycasts.

@export var valid_color: Color = IndicatorPalette.OK
## The landing is refused (check() not OK) — not merely short: a jump
## past the budget lands short and is still valid.
@export var invalid_color: Color = IndicatorPalette.BLOCKED
@export var arc_segments: int = 24

var _line_mesh: PathTube


func serves() -> StringName:
	return &"flight"


func _ready() -> void:
	super()
	_line_mesh = _create_tube()


func draw(aim: Aim) -> void:
	var unit: Unit = aim.caster
	var ability: Ability = aim.ability
	if not unit or not ability:
		_line_mesh.visible = false
		return
	if ability.has_move_caster_effect() and aim.point is Vector3:
		_draw_jump(unit, ability, aim.point)
	elif ability.get_knockback_effect() and aim.cursor and is_instance_valid(aim.cursor.unit):
		_draw_shove(unit, ability, aim.cursor.unit)
	else:
		_line_mesh.visible = false


func _draw_jump(unit: Unit, ability: Ability, hover_point: Vector3) -> void:
	var targeting: GroundPointTargeting = ability.targeting
	# The REAL landing point after budget clamping, not just wherever the
	# mouse is: short of move, the jump lands short, so the preview does.
	var landing: Vector3 = targeting.landing_for(unit, hover_point)
	var valid: bool = targeting.check(unit, landing) == AbilityTargeting.Reach.OK
	_draw_arc(unit, unit.global_position, landing, MoveCasterEffect.arc_height_of(ability, unit, landing), valid)


## The target's flight, while the shove can reach it from here (out of
## reach, the caster would walk first and shove from somewhere else).
func _draw_shove(unit: Unit, ability: Ability, target: Unit) -> void:
	var effect: KnockbackEffect = ability.get_knockback_effect()
	var landing = effect.landing_point(unit, target) if target != unit and ability.is_in_range(unit, target) else null
	if not landing is Vector3 or target.global_position.distance_to(landing) < 0.05:
		_line_mesh.visible = false
		return
	_draw_arc(target, target.global_position, landing, effect.arc_height, true)


## The curve flier flies from start to landing, cut where it meets a wall.
func _draw_arc(flier: Unit, start: Vector3, landing: Vector3, height: float, valid: bool) -> void:
	var reach: float = ArcFlight.clear_fraction(flier, start, landing, height)
	var points := PackedVector3Array()
	var steps: int = maxi(ceili(arc_segments * reach), 1)
	for i in range(steps + 1):
		points.append(ArcFlight.point(start, landing, height, reach * float(i) / steps))
	_line_mesh.show_line(points, valid_color if valid else invalid_color)

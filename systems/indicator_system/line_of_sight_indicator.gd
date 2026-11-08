extends IndicatorBase
## Ranged-ability line-of-sight preview, BG3-style. Only shows during
## combat, for the unit whose turn it currently is, only when that unit
## is player-controlled, and only when the currently armed ability (see
## AbilityManager) is a ranged one — melee abilities don't need this,
## since melee range is a pure distance check with no obstruction concept.
##
## The line continuously tracks the cursor, not just when precisely
## hovering a unit — aiming at open ground still draws a line to that
## point (no_target_color), same as BG3's targeting line following your
## mouse everywhere rather than only snapping on over a valid target.
## Colors:
##   - clear_color        — hovering a hostile unit, in range, clear LoS
##   - blocked_color       — hovering a hostile unit, in range, but blocked
##   - out_of_range_color   — hovering a hostile unit, but too far away
##   - no_target_color        — not hovering any (hostile) unit at all
##
## Range and LoS come from the armed RangedEnemyTargeting's own check() —
## the same rule is_valid_target() (and so the cast) is built on, which
## tells "out of range" and "blocked" apart as AbilityTargeting.Reach.
## This used to duplicate that rule here, because a single bool couldn't
## distinguish the two visual states, and had to be kept in sync by hand.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own MeshInstance3D in code. The hovered hostile and ground point
## come from the Aim ClickRouter hands draw(); nothing here raycasts.
##
## Drawn as a PathTube, the one look every indicator line shares.

@export var clear_color: Color = IndicatorPalette.OK
@export var blocked_color: Color = IndicatorPalette.BLOCKED
@export var out_of_range_color: Color = IndicatorPalette.OUT_OF_REACH
@export var no_target_color: Color = IndicatorPalette.NO_TARGET
## Where the line is drawn is not a number here at all: it is
## LineOfSight.shot_from/shot_to, the segment the rule traces.

var _line_mesh: PathTube


func serves() -> StringName:
	return &"line_of_sight"


func _ready() -> void:
	super()
	_line_mesh = _create_tube()


func draw(aim: Aim) -> void:
	var unit: Unit = aim.caster
	var ability: Ability = aim.ability

	# `as`, not a typed assignment: a guard against being handed an Aim
	# whose ability isn't ranged. The router now applies the intent before
	# it draws, so this shouldn't happen, but a wrong-shaped ability must
	# hide the line rather than error.
	if not unit or not ability or (ability.targeting as RangedEnemyTargeting) == null:
		_line_mesh.visible = false
		return

	var hovered_unit: Unit = aim.hostile
	var aim_point = hovered_unit if hovered_unit else aim.point
	if aim_point == null:
		_line_mesh.visible = false
		return

	_draw_line(unit, aim_point, hovered_unit, ability)


func _draw_line(unit: Unit, aim_point, hovered_unit: Unit, ability: Ability) -> void:
	var color: Color
	# A ground-aimable shot colours its line to the spot as it does to a
	# unit: the click would fire there.
	var target = hovered_unit if hovered_unit else (aim_point if ability.targeting.aims_at_ground else null)
	if target == null:
		color = no_target_color
	else:
		match ability.targeting.check(unit, target):
			AbilityTargeting.Reach.OK:
				color = clear_color
			AbilityTargeting.Reach.OUT_OF_RANGE:
				color = out_of_range_color
			AbilityTargeting.Reach.BLOCKED:
				color = blocked_color
			_:
				color = no_target_color

	# The segment check() traced: eye to the part of the hovered body it
	# can see, or to the aimed spot itself.
	var mask: int = ability.targeting.los_obstruction_mask if "los_obstruction_mask" in ability.targeting else 1
	_show_shot(_line_mesh, LineOfSight.shot_from(unit), LineOfSight.shot_to(aim_point, unit, mask), color)

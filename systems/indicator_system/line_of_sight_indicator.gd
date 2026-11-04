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
## Note: like the movement indicator, this draws a 1-pixel unshaded line
## (ImmediateMesh, LINE_STRIP) — fine for a first pass, thicker lines
## would need an actual ribbon mesh.

@export var clear_color: Color = Color(1, 1, 1, 0.9)
@export var blocked_color: Color = Color(1, 0.2, 0.2, 0.9)
@export var out_of_range_color: Color = Color(0.5, 0.5, 0.5, 0.6)
@export var no_target_color: Color = Color(0.7, 0.7, 0.7, 0.35)
## Where the line is drawn is no longer a number here at all: it comes from
## the same eye anchor LineOfSight traces from, so the two cannot disagree.
##
## They DID disagree. This was 1.5 to match LineOfSight's default, said so
## in its own comment — and MainRoot.tscn then overrode it to 2.0, so the
## line every player saw was half a metre above the ray actually being
## tested. Exactly the kind of drift a shared constant invites and an
## anchor makes impossible.

var _line_mesh: MeshInstance3D
var _line_immediate: ImmediateMesh


func serves() -> StringName:
	return &"line_of_sight"


func _ready() -> void:
	super()
	var built: Dictionary = _create_line_mesh()
	_line_mesh = built.mesh_instance
	_line_immediate = built.immediate


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
	var aim_point = hovered_unit.global_position if hovered_unit else aim.point
	if aim_point == null:
		_line_mesh.visible = false
		return

	_draw_line(unit, aim_point, hovered_unit, ability)
	_line_mesh.visible = true


func _draw_line(unit: Unit, aim_point: Vector3, hovered_unit: Unit, ability: Ability) -> void:
	var color: Color
	if hovered_unit == null:
		color = no_target_color
	else:
		match ability.targeting.check(unit, hovered_unit):
			AbilityTargeting.Reach.OK:
				color = clear_color
			AbilityTargeting.Reach.OUT_OF_RANGE:
				color = out_of_range_color
			AbilityTargeting.Reach.BLOCKED:
				color = blocked_color
			_:
				color = no_target_color

	var eye: Vector3 = unit.anchor(CharacterModel.Anchor.EYE)
	var lift: float = eye.y - unit.global_position.y
	var from: Vector3 = unit.global_position + Vector3(0, lift, 0)
	var to: Vector3 = aim_point + Vector3(0, lift, 0)

	_line_immediate.clear_surfaces()
	_line_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(from)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(to)
	_line_immediate.surface_end()

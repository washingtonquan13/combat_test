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
## Range and LoS are checked here the same way Ability.is_in_range() does
## internally for RANGED_ENEMY — duplicated rather than called through
## that single bool-returning method, since this needs to tell "out of
## range" and "blocked" apart as two different visual states, which a
## single true/false can't distinguish. If Ability's own range/LoS logic
## changes, this needs to be kept in sync with it.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own MeshInstance3D in code. unit_collision_mask/ground_collision_mask
## (see IndicatorBase) must match your Units'/ground's actual physics
## layers.
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


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	var ability: Ability = AbilityManager.armed_ability

	# `as`, not a typed assignment: the router applies a new intent on
	# ITS _process, and this node can run first in the same frame with a
	# freshly armed non-ranged ability still in hand.
	if not unit or not ability or (ability.targeting as RangedEnemyTargeting) == null:
		_line_mesh.visible = false
		return

	var hovered_unit: Unit = _get_hovered_hostile(unit)
	var aim_point = hovered_unit.global_position if hovered_unit else _get_mouse_ground_point()
	if aim_point == null:
		_line_mesh.visible = false
		return

	_draw_line(unit, aim_point, hovered_unit, ability)
	_line_mesh.visible = true


func _draw_line(unit: Unit, aim_point: Vector3, hovered_unit: Unit, ability: Ability) -> void:
	var targeting := ability.targeting as RangedEnemyTargeting

	var color: Color
	if hovered_unit == null:
		color = no_target_color
	elif unit.edge_distance_to(hovered_unit) > targeting.max_range:
		color = out_of_range_color
	elif targeting.requires_line_of_sight and not LineOfSight.has_clear_shot(unit, hovered_unit, targeting.los_obstruction_mask):
		color = blocked_color
	else:
		color = clear_color

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

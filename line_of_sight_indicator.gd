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
## Roughly chest/eye height — a line drawn at ground level reads poorly
## against 3D geometry; this matches LineOfSight's own default eye_height
## so the drawn line reflects where the raycast actually checks.
@export var height_offset: float = 1.5

var _line_mesh: MeshInstance3D
var _line_immediate: ImmediateMesh


func _ready() -> void:
	var built: Dictionary = _create_line_mesh()
	_line_mesh = built.mesh_instance
	_line_immediate = built.immediate


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	var ability := _get_armed_ranged_ability()

	if not unit or not ability:
		_line_mesh.visible = false
		return

	var hovered_unit: Unit = _get_hovered_hostile(unit)
	var aim_point = hovered_unit.global_position if hovered_unit else _get_mouse_ground_point()
	if aim_point == null:
		_line_mesh.visible = false
		return

	_draw_line(unit, aim_point, hovered_unit, ability)
	_line_mesh.visible = true


func _get_active_unit() -> Unit:
	return PlayerInteractionState.get_active_unit()


func _get_armed_ranged_ability() -> Ability:
	return PlayerInteractionState.get_armed_ability_of_targeting_type(RangedEnemyTargeting)


## Filters IndicatorBase._get_hovered_unit() down to "alive AND hostile
## to unit" — this indicator only cares about valid attack targets, not
## just whatever's under the cursor.
func _get_hovered_hostile(unit: Unit) -> Unit:
	var hovered := _get_hovered_unit()
	if not hovered or not hovered.is_alive():
		return null
	if not unit.is_hostile_to(hovered):
		return null
	return hovered


## Reads range/LoS off ability.targeting directly (cast to
## RangedEnemyTargeting — safe since _get_armed_ranged_ability already
## confirmed it's that type). This is a legitimate, narrow exception to
## staying fully generic about targeting components: this indicator's
## whole purpose is showing distinct visual states an "is it valid" bool
## can't distinguish, so it needs the concrete field values, not just a
## yes/no.
func _draw_line(unit: Unit, aim_point: Vector3, hovered_unit: Unit, ability: Ability) -> void:
	var targeting: RangedEnemyTargeting = ability.targeting

	var color: Color
	if hovered_unit == null:
		color = no_target_color
	elif unit.edge_distance_to(hovered_unit) > targeting.max_range:
		color = out_of_range_color
	elif targeting.requires_line_of_sight and not LineOfSight.has_clear_shot(unit, hovered_unit, targeting.los_obstruction_mask):
		color = blocked_color
	else:
		color = clear_color

	var from: Vector3 = unit.global_position + Vector3(0, height_offset, 0)
	var to: Vector3 = aim_point + Vector3(0, height_offset, 0)

	_line_immediate.clear_surfaces()
	_line_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(from)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(to)
	_line_immediate.surface_end()

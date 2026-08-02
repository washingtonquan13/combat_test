extends Node3D
## Ranged-ability line-of-sight preview, BG3-style. Only shows during
## combat, for the unit whose turn it currently is, only when that unit
## is player-controlled, and only when the currently armed ability (see
## AbilityManager) is a ranged one — melee abilities don't need this,
## since melee range is a pure distance check with no obstruction concept.
##
## While hovering over a hostile unit, draws a line from the attacker to
## that unit, colored:
##   - clear_color        — in range AND clear line of sight (valid shot)
##   - blocked_color       — in range, but something's in the way
##   - out_of_range_color  — out of range entirely (LoS not even checked)
##
## Range and LoS are checked here the same way Ability.is_in_range() does
## internally for RANGED_ENEMY — duplicated rather than called through
## that single bool-returning method, since this needs to tell "out of
## range" and "blocked" apart as two different visual states, which a
## single true/false can't distinguish. If Ability's own range/LoS logic
## changes, this needs to be kept in sync with it.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own MeshInstance3D in code. unit_collision_mask must match
## whatever physics layer your Units' CollisionShape3D bodies are
## actually on, so hovering can detect them via raycast.
##
## Note: like the movement indicator, this draws a 1-pixel unshaded line
## (ImmediateMesh, LINE_STRIP) — fine for a first pass, thicker lines
## would need an actual ribbon mesh.

@export var unit_collision_mask: int = 1
@export var clear_color: Color = Color(1, 1, 1, 0.9)
@export var blocked_color: Color = Color(1, 0.2, 0.2, 0.9)
@export var out_of_range_color: Color = Color(0.5, 0.5, 0.5, 0.6)
## Roughly chest/eye height — a line drawn at ground level reads poorly
## against 3D geometry; this matches LineOfSight's own default eye_height
## so the drawn line reflects where the raycast actually checks.
@export var height_offset: float = 1.5

var _line_mesh: MeshInstance3D
var _line_immediate: ImmediateMesh


func _ready() -> void:
	_build_line()


func _build_line() -> void:
	_line_mesh = MeshInstance3D.new()
	add_child(_line_mesh)

	_line_immediate = ImmediateMesh.new()
	_line_mesh.mesh = _line_immediate

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_line_mesh.material_override = mat
	_line_mesh.visible = false


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	if not unit:
		_line_mesh.visible = false
		return

	var ability := _get_armed_ranged_ability()
	if not ability:
		_line_mesh.visible = false
		return

	var target := _get_hovered_hostile(unit)
	if not target:
		_line_mesh.visible = false
		return

	_draw_line(unit, target, ability)
	_line_mesh.visible = true


func _get_active_unit() -> Unit:
	if not CombatManager.in_combat:
		return null

	var unit: Unit = CombatManager.current_unit
	if not unit or not is_instance_valid(unit) or not unit.is_alive():
		return null
	if not unit.is_player_controlled():
		return null

	return unit


func _get_armed_ranged_ability() -> Ability:
	var ability: Ability = AbilityManager.armed_ability
	if not ability or not (ability.targeting is RangedEnemyTargeting):
		return null
	return ability


func _get_hovered_hostile(unit: Unit) -> Unit:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = from + dir * 1000.0

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = unit_collision_mask
	var result := space_state.intersect_ray(query)

	if result.is_empty():
		return null

	var hovered := result.get("collider") as Unit
	if not hovered or not hovered.is_alive():
		return null
	if not unit.is_hostile_to(hovered):
		return null

	return hovered


## Reads range/LoS off ability.targeting directly (cast to
## RangedEnemyTargeting — safe since _get_armed_ranged_ability already
## confirmed it's that type). This is a legitimate, narrow exception to
## staying fully generic about targeting components: this indicator's
## whole purpose is showing three distinct visual states an "is it
## valid" bool can't distinguish (too far vs. blocked), so it needs the
## concrete field values, not just a yes/no. Most other ability-aware
## code (hotbar tooltips, CombatAI's approach distance) never needs this
## and stays fully polymorphic instead.
func _draw_line(unit: Unit, target: Unit, ability: Ability) -> void:
	var targeting: RangedEnemyTargeting = ability.targeting

	var color: Color
	if unit.edge_distance_to(target) > targeting.max_range:
		color = out_of_range_color
	elif targeting.requires_line_of_sight and not LineOfSight.has_clear_shot(unit, target, targeting.los_obstruction_mask):
		color = blocked_color
	else:
		color = clear_color

	var from: Vector3 = unit.global_position + Vector3(0, height_offset, 0)
	var to: Vector3 = target.global_position + Vector3(0, height_offset, 0)

	_line_immediate.clear_surfaces()
	_line_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(from)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(to)
	_line_immediate.surface_end()

extends Node3D
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
## its own MeshInstance3D in code. unit_collision_mask must match
## whatever physics layer your Units' CollisionShape3D bodies are on
## (for detecting a hovered unit); ground_collision_mask must match your
## ground/terrain body's layer (for the fallback ground point, so the
## line has somewhere to point when no unit is under the cursor).
##
## Note: like the movement indicator, this draws a 1-pixel unshaded line
## (ImmediateMesh, LINE_STRIP) — fine for a first pass, thicker lines
## would need an actual ribbon mesh.

@export var unit_collision_mask: int = 1
@export var ground_collision_mask: int = 1
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
	var ability := _get_armed_ranged_ability()

	if not unit or not ability:
		_line_mesh.visible = false
		return

	var aim_point = _get_aim_point()
	if aim_point == null:
		_line_mesh.visible = false
		return

	var hovered_unit: Unit = _get_hovered_hostile(unit)
	_draw_line(unit, aim_point, hovered_unit, ability)
	_line_mesh.visible = true


## Only the acting unit, only if player-controlled, and only if not
## currently busy — consistent with jump_indicator.gd's same fix. No
## async ranged effect exists yet to actually trigger this today, but
## without the check here too, the same "preview lingers through an
## action that's still resolving" bug would silently reappear the moment
## one does.
func _get_active_unit() -> Unit:
	if not CombatManager.in_combat:
		return null

	var unit: Unit = CombatManager.current_unit
	if not unit or not is_instance_valid(unit) or not unit.is_alive():
		return null
	if not unit.is_player_controlled():
		return null
	if unit.is_busy():
		return null

	return unit


func _get_armed_ranged_ability() -> Ability:
	var ability: Ability = AbilityManager.armed_ability
	if not ability or not (ability.targeting is RangedEnemyTargeting):
		return null
	return ability


## Where the line should point to: a hovered hostile unit's position if
## there is one, otherwise the ground point under the cursor — this is
## what keeps the line following the mouse continuously instead of
## disappearing whenever the cursor isn't precisely over a unit.
func _get_aim_point():
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = from + dir * 1000.0

	var space_state := get_world_3d().direct_space_state

	var unit_query := PhysicsRayQueryParameters3D.create(from, to)
	unit_query.collision_mask = unit_collision_mask
	var unit_result := space_state.intersect_ray(unit_query)
	if not unit_result.is_empty():
		var hovered := unit_result.get("collider") as Unit
		if hovered:
			return hovered.global_position

	var ground_query := PhysicsRayQueryParameters3D.create(from, to)
	ground_query.collision_mask = ground_collision_mask
	var ground_result := space_state.intersect_ray(ground_query)
	if ground_result.is_empty():
		return null
	return ground_result.position


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

extends IndicatorBase
## Targeting preview for "seeking" abilities (see Ability.
## has_pathed_projectile) — Magic Missile and anything else whose
## impact_vfx includes a PathedProjectileStep. Same philosophy as
## movement_indicator.gd: instead of a straight aim line (what
## line_of_sight_indicator.gd draws for every other ranged ability),
## this queries NavigationGrid.find_path() and previews the REAL bent
## route the projectile will fly — this preview IS what will happen, not
## an approximation of it, the same principle movement_indicator.gd's
## own header states. Reads its query parameters (radius/avoidance_
## margin/height/flying/launch_height_offset/corner rounding) directly
## off the armed ability's own PathedProjectileStep instance rather than
## duplicating guessed values — same WYSIWYG convention area_indicator.gd
## uses reading AreaTargeting.radius directly.
##
## Only shows during combat, for the unit whose turn it currently is,
## only when player-controlled, and only when the currently armed
## ability has a PathedProjectileStep. line_of_sight_indicator.gd
## explicitly stands down for these same abilities (see its own
## _get_armed_ranged_ability), so exactly one of the two ever draws for
## a given armed ability.
##
## Colors and the hovered-hostile-or-ground-point aiming behavior match
## line_of_sight_indicator.gd exactly — this replaces that indicator's
## DISPLAY for seeking abilities, not its meaning. Drawn as the same
## plain colored line (PRIMITIVE_LINE_STRIP) line_of_sight_indicator.gd
## uses, not movement_indicator.gd's glowing ribbon shader — the ask was
## to become NavigationGrid-aware and corner-rounded like that indicator,
## not to take on its visual treatment too.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own MeshInstance3D in code, nothing else needs wiring.

@export var clear_color: Color = Color(1, 1, 1, 0.9)
@export var blocked_color: Color = Color(1, 0.2, 0.2, 0.9)
@export var out_of_range_color: Color = Color(0.5, 0.5, 0.5, 0.6)
@export var no_target_color: Color = Color(0.7, 0.7, 0.7, 0.35)

var _line_mesh: MeshInstance3D
var _line_immediate: ImmediateMesh

## Same query-caching idea as movement_indicator.gd's _last_query_* —
## NavigationGrid.find_path is a real search, not free, and most frames
## the mouse hasn't moved to a different cell at all. Keyed on the
## PathedProjectileStep instance itself rather than a separate `flying`
## flag — step.flying is static for the duration of one preview, unlike
## movement_indicator.gd's unit which can actually take off/land mid-hover.
var _last_query_unit: Unit = null
var _last_query_step: PathedProjectileStep = null
var _last_query_start_cell: Vector3i
var _last_query_dest_cell: Vector3i
var _last_waypoints: PackedVector3Array = PackedVector3Array()


func _ready() -> void:
	var built: Dictionary = _create_line_mesh()
	_line_mesh = built.mesh_instance
	_line_immediate = built.immediate


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	var ability := PlayerInteractionState.get_armed_seeking_ability()

	if not unit or not ability:
		_line_mesh.visible = false
		return

	var step: PathedProjectileStep = ability.get_pathed_projectile_step()

	var hovered_unit: Unit = _get_hovered_hostile(unit)
	var aim_point = hovered_unit.global_position if hovered_unit else _get_mouse_ground_point()
	if aim_point == null:
		_line_mesh.visible = false
		return

	_update_path_preview(unit, ability, step, aim_point, hovered_unit)
	_line_mesh.visible = true


func _get_active_unit() -> Unit:
	return PlayerInteractionState.get_active_unit()


## Filters IndicatorBase._get_hovered_unit() down to "alive AND hostile
## to unit" — same as line_of_sight_indicator.gd's identically-named
## method, this indicator only cares about valid attack targets.
func _get_hovered_hostile(unit: Unit) -> Unit:
	var hovered := _get_hovered_unit()
	if not hovered or not hovered.is_alive():
		return null
	if not unit.is_hostile_to(hovered):
		return null
	return hovered


func _update_path_preview(unit: Unit, ability: Ability, step: PathedProjectileStep, aim_point: Vector3, hovered_unit: Unit) -> void:
	var launch_point: Vector3 = unit.global_position + Vector3(0, step.launch_height_offset, 0)

	var start_cell: Vector3i = NavigationGrid.world_to_cell(launch_point)
	var dest_cell: Vector3i = NavigationGrid.world_to_cell(aim_point)
	var query_unchanged: bool = (
		unit == _last_query_unit
		and step == _last_query_step
		and start_cell == _last_query_start_cell
		and dest_cell == _last_query_dest_cell
	)

	var waypoints: PackedVector3Array
	if query_unchanged:
		waypoints = _last_waypoints
	else:
		# Same empty-result fallback as PathedProjectileStep.play() itself
		# (see that file) — keeps this preview honest about what will
		# actually be flown even when find_path can't route it.
		waypoints = NavigationGrid.find_path(unit.get_tree(), launch_point, aim_point, step, step.flying)
		if waypoints.size() < 2:
			waypoints = PackedVector3Array([launch_point, aim_point])
		_last_query_unit = unit
		_last_query_step = step
		_last_query_start_cell = start_cell
		_last_query_dest_cell = dest_cell
		_last_waypoints = waypoints

	var rounded := PathCornerRounding.round_corners(waypoints, step.corner_round_radius, step.corner_round_segments)
	_draw_path(rounded, _color_for(unit, ability, hovered_unit))


## Same range/LoS decision line_of_sight_indicator.gd makes, reading off
## the same RangedEnemyTargeting fields — see that file's own comment for
## why this duplicates rather than calls through Ability.is_in_range():
## a single bool can't distinguish "out of range" from "blocked" as two
## different visual states. Falls back to no_target_color if a future
## seeking ability doesn't use RangedEnemyTargeting — this was built for
## the one shape that exists today, not a guess at every shape that
## might exist later.
func _color_for(unit: Unit, ability: Ability, hovered_unit: Unit) -> Color:
	if hovered_unit == null:
		return no_target_color
	var targeting := ability.targeting as RangedEnemyTargeting
	if not targeting:
		return no_target_color
	if unit.edge_distance_to(hovered_unit) > targeting.max_range:
		return out_of_range_color
	if targeting.requires_line_of_sight and not LineOfSight.has_clear_shot(unit, hovered_unit, targeting.los_obstruction_mask):
		return blocked_color
	return clear_color


func _draw_path(points: PackedVector3Array, color: Color) -> void:
	_line_immediate.clear_surfaces()
	if points.size() < 2:
		return

	_line_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in points:
		_line_immediate.surface_set_color(color)
		_line_immediate.surface_add_vertex(p)
	_line_immediate.surface_end()

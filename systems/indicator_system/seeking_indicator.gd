extends IndicatorBase
## Targeting preview for "seeking" abilities (see Ability.
## has_pathed_projectile) — Magic Missile and anything else whose
## cast_vfx includes a PathedProjectileStep. Same philosophy as
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
## explicitly stands down for these same abilities (see Ability.
## indicator_ids, which names &"seeking" instead of &"line_of_sight" for
## them), so exactly one of the two ever draws for a given armed ability.
##
## Colors and the hovered-hostile-or-ground-point aiming behavior match
## line_of_sight_indicator.gd exactly — this replaces that indicator's
## DISPLAY for seeking abilities, not its meaning. Drawn as the same
## thin camera-facing ribbon line_of_sight_indicator.gd uses (the route
## flies at launch height, so a flat one would be seen edge-on), not
## movement_indicator.gd's wider ground ribbon.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own MeshInstance3D in code, nothing else needs wiring. The hovered
## hostile and ground point come from the Aim ClickRouter hands draw().

@export var clear_color: Color = IndicatorPalette.OK
@export var blocked_color: Color = IndicatorPalette.BLOCKED
@export var out_of_range_color: Color = IndicatorPalette.OUT_OF_REACH
@export var no_target_color: Color = IndicatorPalette.NO_TARGET

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


func serves() -> StringName:
	return &"seeking"


func _ready() -> void:
	super()
	var built: Dictionary = _create_line_mesh()
	_line_mesh = built.mesh_instance
	_line_immediate = built.immediate


func draw(aim: Aim) -> void:
	var unit: Unit = aim.caster
	var ability: Ability = aim.ability

	if not unit or not ability or ability.get_pathed_projectile_step() == null:
		_line_mesh.visible = false
		return

	var step: PathedProjectileStep = ability.get_pathed_projectile_step()

	var hovered_unit: Unit = aim.hostile
	var aim_point = hovered_unit.global_position if hovered_unit else aim.point
	if aim_point == null:
		_line_mesh.visible = false
		return

	_update_path_preview(unit, ability, step, aim_point, hovered_unit)
	_line_mesh.visible = true


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


## Same range/LoS decision line_of_sight_indicator.gd makes: the armed
## targeting's own check(), the rule the cast itself uses, which tells
## "out of range" and "blocked" apart as AbilityTargeting.Reach. Falls
## back to no_target_color when there's no targeting or check() calls the
## hovered unit INVALID — this was built for the one shape that exists
## today (RangedEnemyTargeting), not a guess at every shape that might
## exist later.
func _color_for(unit: Unit, ability: Ability, hovered_unit: Unit) -> Color:
	if hovered_unit == null or ability.targeting == null:
		return no_target_color
	match ability.targeting.check(unit, hovered_unit):
		AbilityTargeting.Reach.OK:
			return clear_color
		AbilityTargeting.Reach.OUT_OF_RANGE:
			return out_of_range_color
		AbilityTargeting.Reach.BLOCKED:
			return blocked_color
	return no_target_color


func _draw_path(points: PackedVector3Array, color: Color) -> void:
	_line_immediate.clear_surfaces()
	_add_ribbon(_line_immediate, points, PackedColorArray([color]), LINE_WIDTH, LINE_EDGE, true)

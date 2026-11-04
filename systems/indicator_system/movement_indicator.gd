extends IndicatorBase
## Movement path preview, BG3-style. Drawn only — ClickRouter decides
## when it is live (the "movement" intent) and hands it the frame's Aim
## through draw(); it never reads the mouse, raycasts, or handles the
## Ctrl altitude drag (that is IdleIntent.steer's).
##
## Scene setup: attach this script to any plain Node3D in your main scene
## — it builds its own child visuals in code, nothing else needs to be
## wired up.
##
## A ribbon follows the route from Unit.preview_route() — the same route
## choice Unit.move_to() makes, ladder journeys included, over a route
## from NavigationGrid.find_path() that's already avoidance-correct
## against every other unit's footprint and real level geometry, and
## through the same RoutePlanner.plan budget/cost planner — from the unit
## to the aimed point. Because the preview and the move share one route
## rule over the same grid state, this preview IS what will happen — not
## an approximation of it.
##
## What it shows, all from that one route:
## - the ribbon, IndicatorPalette.OK up to Unit.move_budget() and
##   OUT_OF_REACH past it (grey, not red: red means "refused" everywhere
##   else, and a path past the budget isn't refused, the unit just stops
##   short);
## - a ring where the unit will actually stop (the budget point, or the
##   route's end when it all fits);
## - the route's cost as a billboard readout at the end, "4.5 m", or
##   "7.5 / 6.0 m" in combat (cost / move_remaining).
##
## The ribbon is a solid core with a dark IndicatorPalette.EDGE rim
## (IndicatorBase._add_ribbon), lying flat on the waypoints at their own
## heights — climbs, ladders and flight included — so it reads as a trail
## painted on the route rather than an effect that swivels with the
## camera. It replaced a 5 cm additive glow, which was one or two pixels
## at tactical zoom.

## Lifts the ribbon slightly above the ground to avoid z-fighting with
## terrain geometry.
@export var height_offset: float = 0.05
## Purely visual corner rounding for the drawn ribbon — see
## PathCornerRounding. The taut path RoutePlanner produces is optimal but
## not smooth: real corners at real angles, which read as jagged when
## drawn as-is. This never touches the actual path/cost/collision data.
@export var corner_round_radius: float = 0.35
@export var corner_round_segments: int = 6
## Ribbon core width (meters); the dark rim is added on either side.
@export var line_width: float = 0.2
@export var edge_width: float = 0.03
@export var path_in_range_color: Color = IndicatorPalette.OK
@export var path_out_of_range_color: Color = IndicatorPalette.OUT_OF_REACH
## The stop ring: radius and ribbon width in meters.
@export var stop_marker_radius: float = 0.3
@export var stop_marker_width: float = 0.08
## How far above the route's end the cost readout floats.
@export var readout_height: float = 0.6

var _path_mesh: MeshInstance3D
var _path_immediate: ImmediateMesh
## A Label3D, not a mesh, so IndicatorBase's _owned_meshes doesn't know
## about it: hide_visuals/is_showing_anything are extended below.
var _readout: Label3D


func serves() -> StringName:
	return &"movement"


func _ready() -> void:
	super()
	var built: Dictionary = _create_line_mesh()
	_path_mesh = built.mesh_instance
	_path_immediate = built.immediate

	# Billboarded and screen-constant so it reads the same at any zoom;
	# no depth test so the wall the route turns behind can't hide it.
	_readout = Label3D.new()
	_readout.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_readout.fixed_size = true
	_readout.pixel_size = 0.0012
	_readout.font_size = 28
	_readout.outline_size = 8
	_readout.outline_modulate = IndicatorPalette.EDGE
	_readout.no_depth_test = true
	_readout.visible = false
	add_child(_readout)


func hide_visuals() -> void:
	super()
	if _readout:
		_readout.visible = false


func is_showing_anything() -> bool:
	return super() or (_readout != null and _readout.visible)


## Draws the route the caster would take to aim.point — from
## Unit.preview_route(), the same route choice move_to() makes (ladder
## journeys included), planned in full so _draw_path can grey the part
## beyond Unit.move_budget() (move_remaining in combat, INF out of it).
## Nothing to draw without a caster or a ground point under the cursor,
## nor over a unit or interactable - clicking those doesn't move, so the
## path must not point at them.
func draw(aim: Aim) -> void:
	if aim.caster == null or aim.point == null:
		_hide_all()
		return
	if aim.cursor and (aim.cursor.unit or aim.cursor.interactable):
		_hide_all()
		return

	var planned: Dictionary = aim.caster.preview_route(aim.point)
	if planned.path.size() < 2:
		_hide_all()
		return

	_draw_path(planned.path, planned.cumulative_cost, aim.caster.move_budget())
	_path_mesh.visible = true
	_readout.visible = true


func _hide_all() -> void:
	if _path_mesh:
		_path_mesh.visible = false
	if _readout:
		_readout.visible = false


## Rebuilds the ribbon, stop ring and readout each frame. The route is
## split at the budget by COST, read straight from RoutePlanner.plan's
## own cumulative_cost rather than re-summed from segment lengths, so
## difficult terrain's multipliers put the split exactly where the real
## move will run out. The split point is interpolated along whichever
## segment crosses the budget, not snapped to a vertex.
##
## Each half is corner-rounded separately (PathCornerRounding keeps
## endpoints exact), so the split point — and the stop ring on it —
## stays at the true budget edge rather than being rounded away from it.
func _draw_path(path: PackedVector3Array, cumulative_cost: PackedFloat32Array, budget: float) -> void:
	_path_immediate.clear_surfaces()

	var split_index: int = path.size()
	var split_point: Vector3 = path[path.size() - 1]
	if budget <= 0.0:
		split_index = 0
		split_point = path[0]
	elif is_inf(budget):
		# Out of combat (Unit.move_budget) - no budget edge anywhere, the
		# whole path is in range. Skipped explicitly so an INF cost on the
		# route can't make INF - INF / INF / INF produce a NaN split.
		pass
	else:
		for i in range(1, path.size()):
			if cumulative_cost[i] >= budget:
				var segment_cost: float = cumulative_cost[i] - cumulative_cost[i - 1]
				var remaining: float = budget - cumulative_cost[i - 1]
				var t: float = (remaining / segment_cost) if segment_cost > 0.0 else 0.0
				split_point = path[i - 1].lerp(path[i], t)
				split_index = i
				break

	var lift := Vector3(0, height_offset, 0)

	var in_range := PackedVector3Array()
	for i in range(0, split_index):
		in_range.append(path[i] + lift)
	if split_index < path.size():
		in_range.append(split_point + lift)

	var out_of_range := PackedVector3Array()
	if split_index < path.size():
		out_of_range.append(split_point + lift)
		for i in range(split_index, path.size()):
			out_of_range.append(path[i] + lift)

	_add_ribbon(_path_immediate, PathCornerRounding.round_corners(in_range, corner_round_radius, corner_round_segments),
		PackedColorArray([path_in_range_color]), line_width, edge_width)
	_add_ribbon(_path_immediate, PathCornerRounding.round_corners(out_of_range, corner_round_radius, corner_round_segments),
		PackedColorArray([path_out_of_range_color]), line_width, edge_width)

	# Drawn after the ribbon so it sits over it where they cross. Lifted a
	# hair more than the ribbon: both are transparent, so it is draw order,
	# not depth, that keeps the ring on top — the lift is only for slopes.
	var stop: Vector3 = split_point + lift * 1.5
	_add_ribbon(_path_immediate, _ring_points(stop, stop_marker_radius, 32),
		PackedColorArray([path_in_range_color]), stop_marker_width, edge_width)

	_update_readout(path[path.size() - 1], cumulative_cost[cumulative_cost.size() - 1], budget)


## Cost, not straight-line distance: it's what the budget is spent in,
## so "x / y" compares like with like. Greyed with the ribbon's own
## out-of-range colour when the route doesn't fit.
func _update_readout(end: Vector3, total_cost: float, budget: float) -> void:
	_readout.global_position = end + Vector3(0, readout_height, 0)
	if is_inf(budget):
		_readout.text = "%.1f m" % total_cost
		_readout.modulate = path_in_range_color
	else:
		_readout.text = "%.1f / %.1f m" % [total_cost, maxf(budget, 0.0)]
		_readout.modulate = path_in_range_color if total_cost <= budget else path_out_of_range_color

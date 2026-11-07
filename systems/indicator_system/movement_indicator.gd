extends IndicatorBase
## Movement path preview, remade after BG3's AiPath. Drawn only:
## ClickRouter decides when it is live (the "movement" intent) and hands
## it the frame's Aim through draw(). It never reads the mouse, raycasts,
## or handles the Ctrl altitude drag (that is IdleIntent.steer's).
##
## Scene setup: attach this script to any plain Node3D in the main scene.
## It builds its own child visuals in code.
##
## The route is Unit.preview_route(), the same route choice move_to()
## makes over the same grid, so the preview is what will happen. It is
## corner-rounded (drawing only), cut into short pieces, and each piece
## becomes one box ray-traced as a thin glowing tube by
## movement_path_tube.gdshader (through PathTube, the node every
## indicator line uses). The values are BG3's
## (Shared/GUI/AiPathSettings.lsx), studied for reference only:
## - a 2.5 cm wide tube, centre bright, edges falling to nothing;
## - white within the move budget, crimson past it, cut at the exact
##   cost where the budget runs out;
## - cyan over a harmless surface, yellow over a hazard (a status, extra
##   movement cost, or a sight-blocking cloud);
## - fades in over the first metre and out over the last;
## - dashes where the route is obscured, scrolling along it: lightly
##   (0.2 on, 0.2 off) or heavily (0.05 on, 0.15 off);
## - a slow pulse, and 10% visibility through walls.
## The distance readout floats over the route's end.
##
## When it draws (BG3's rules):
## - in combat, before the click: the hover preview, route + readout;
## - in combat, once the unit is walking: the route it committed to,
##   whole, and nothing else (no readout, the cursor ignored) until it
##   arrives; then the hover preview returns;
## - out of combat: nothing (the click marker, ClickFeedback, is the
##   feedback), unless select_additive (Shift) is held, which shows the
##   hover preview to plan around a hazard.

## BG3 AiPathSettings RegularColor / ColorPastLimit.
@export var path_in_range_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var path_out_of_range_color: Color = Color(0.788, 0.0, 0.188, 1.0)
## BG3 AiPathColor for surfaces you can cross harmlessly (water, blood)
## and for hazards (grease, fire, fog).
@export var harmless_surface_color: Color = Color(0.0, 1.0, 1.0, 1.0)
@export var hazard_surface_color: Color = Color(1.0, 1.0, 0.0, 1.0)
## Full tube width in metres (BG3 Width).
@export var tube_width: float = 0.025
## The tube never draws thinner than this many pixels in radius; past
## that it widens and dims instead of breaking into dots.
@export var min_pixel_radius: float = 0.9
## Additive brightness. Above the WorldEnvironment glow threshold, so it
## blooms a little.
@export var brightness: float = 2.0
## Lift above the ground so the tube rides on it, not in it.
@export var height_offset: float = 0.05
## Fade in / fade out lengths (BG3 AttenuationDistanceStart/End).
@export var fade_start: float = 1.0
@export var fade_end: float = 1.0
## Dash scroll speed (BG3 AnimationSpeed) and the pulse (Pulsation*).
@export var anim_speed: float = 1.0
@export var pulse_limits: Vector2 = Vector2(0.1, 0.4)
@export var pulse_speed: float = 1.0
## Drawing-only corner rounding; never touches the real route.
@export var corner_round_radius: float = 0.35
@export var corner_round_segments: int = 6
## Longest piece; surfaces and obscurity are sampled once per piece.
## Matches SurfaceGrid.CELL so colour changes land on the cell edges.
@export var max_piece_length: float = 0.25
## How far above the route's end the cost readout floats.
@export var readout_height: float = 0.6

## (on, off) metres; off 0 is solid (BG3 PatternClear / Lightly /
## HeavilyObscured).
const PATTERN_CLEAR := Vector2(1.0, 0.0)
const PATTERN_LIGHT := Vector2(0.2, 0.2)
const PATTERN_HEAVY := Vector2(0.05, 0.15)

var _tube: PathTube
## A Label3D, not a mesh, so IndicatorBase's _owned_meshes doesn't know
## about it: hide_visuals/is_showing_anything are extended below.
var _readout: Label3D

## What the current mesh was built from, so an unchanged route isn't
## rebuilt every frame (the per-frame pulse and scroll are TIME in the
## shader).
var _built_path := PackedVector3Array()
var _built_cost := -1.0
var _built_budget := -1.0


func serves() -> StringName:
	return &"movement"


func _ready() -> void:
	super()
	_tube = _create_tube(fade_start)
	_apply_uniforms()

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


func _apply_uniforms() -> void:
	_tube.width = tube_width
	_tube.min_pixel_radius = min_pixel_radius
	_tube.fade_start = fade_start
	_tube.fade_end = fade_end
	_tube.anim_speed = anim_speed
	_tube.pulse_limits = pulse_limits
	_tube.pulse_speed = pulse_speed
	_tube.brightness = brightness


func hide_visuals() -> void:
	super()
	if _readout:
		_readout.visible = false


func is_showing_anything() -> bool:
	return super() or (_readout != null and _readout.visible)


## Draws the route the caster would take to aim.point, planned in full
## so the part beyond Unit.move_budget() (move_remaining in combat, INF
## out of it) can be drawn past-limit; or, while it walks in combat, the
## route it is walking (see the header for when). The preview has
## nothing to draw without a ground point, nor over a unit or
## interactable: clicking those doesn't move, so the path must not point
## at them.
func draw(aim: Aim) -> void:
	if aim.caster == null:
		_hide_all()
		return
	var in_combat: bool = aim.caster.in_combat()
	if in_combat and aim.caster.is_moving():
		_show_route(aim.caster, aim.caster.current_route(), false)
		return
	if not in_combat and not Input.is_action_pressed(&"select_additive"):
		_hide_all()
		return
	if aim.point == null:
		_hide_all()
		return
	if aim.cursor and (aim.cursor.unit or aim.cursor.interactable):
		_hide_all()
		return

	# The same ignore list the move order will route with, so a group's
	# preview doesn't detour around members about to walk off with it.
	_show_route(aim.caster, aim.caster.preview_route(aim.point, FormationPlanner.move_ignore(ClickRouter.move_order_units())), true)


## Draws planned (preview_route()'s shape) for caster, with the cost
## readout or without it.
func _show_route(caster: Unit, planned: Dictionary, with_readout: bool) -> void:
	var path: PackedVector3Array = planned.get("path", PackedVector3Array())
	var cost: PackedFloat32Array = planned.get("cumulative_cost", PackedFloat32Array())
	if path.size() < 2 or cost.size() != path.size():
		_hide_all()
		return

	var total_cost: float = cost[cost.size() - 1]
	var budget: float = caster.move_budget()
	if path != _built_path or total_cost != _built_cost or budget != _built_budget:
		_build(path, cost, budget, WorldManager.context_for(caster))
		_built_path = path
		_built_cost = total_cost
		_built_budget = budget
	_tube.visible = true
	if with_readout:
		_update_readout(path[path.size() - 1], total_cost, budget)
	_readout.visible = with_readout


func _hide_all() -> void:
	if _tube:
		_tube.visible = false
	if _readout:
		_readout.visible = false


## Rebuilds the tube mesh for a route. The budget split is found in COST
## (RoutePlanner's own cumulative_cost, so difficult terrain is priced
## exactly as the move will be), interpolated inside the crossing
## segment, and each side is rounded separately so the split stays put.
func _build(path: PackedVector3Array, cost: PackedFloat32Array, budget: float, context: WorldContext) -> void:
	var split_index: int = path.size()
	var split_point: Vector3 = path[path.size() - 1]
	if budget <= 0.0:
		split_index = 0
		split_point = path[0]
	elif not is_inf(budget):
		for i in range(1, path.size()):
			if cost[i] >= budget:
				var segment_cost: float = cost[i] - cost[i - 1]
				var t: float = (budget - cost[i - 1]) / segment_cost if segment_cost > 0.0 else 0.0
				split_point = path[i - 1].lerp(path[i], t)
				split_index = i
				break

	var inside := PackedVector3Array()
	for i in range(split_index):
		inside.append(path[i])
	var outside := PackedVector3Array()
	if split_index < path.size():
		inside.append(split_point)
		outside.append(split_point)
		for i in range(split_index, path.size()):
			outside.append(path[i])

	var points := PathCornerRounding.round_corners(inside, corner_round_radius, corner_round_segments)
	var split_at: float = _length_of(points)
	if outside.size() >= 2:
		var rounded_out := PathCornerRounding.round_corners(outside, corner_round_radius, corner_round_segments)
		if points.is_empty():
			points = rounded_out
		else:
			for i in range(1, rounded_out.size()):
				points.append(rounded_out[i])
	else:
		split_at = INF

	_fill_mesh(points, split_at, context)


func _length_of(points: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total


## The route lifted onto the ground and cut into pieces, then one colour
## per piece (its midpoint's surface, or crimson past the split) and one
## dash pattern per point (how obscured it is there).
func _fill_mesh(points: PackedVector3Array, split_at: float, context: WorldContext) -> void:
	var pieces: PackedVector3Array = PathTube.cut(points, max_piece_length, Vector3(0.0, height_offset, 0.0))
	var colors := PackedColorArray()
	var patterns := PackedVector2Array()
	var distance := 0.0
	for i in range(pieces.size()):
		patterns.append(_pattern_at(pieces[i], context))
		if i == 0:
			continue
		var length: float = pieces[i - 1].distance_to(pieces[i])
		var past_limit: bool = distance + length * 0.5 >= split_at
		colors.append(_color_at(pieces[i - 1].lerp(pieces[i], 0.5), past_limit, context))
		distance += length
	_tube.build(pieces, colors, patterns)


## Past the budget is crimson whatever is underfoot (it is the answer
## "you can't get there this turn"); within it a surface tints the line.
func _color_at(point: Vector3, past_limit: bool, context: WorldContext) -> Color:
	if past_limit:
		return path_out_of_range_color
	var surface: Surface = SurfaceManager.cloud_at(point, context)
	if surface == null:
		surface = SurfaceManager.surface_at(point, context)
	if surface == null:
		return path_in_range_color
	if not surface.status_effects.is_empty() or surface.movement_cost_multiplier > 1.0 or surface.blocks_sight:
		return hazard_surface_color
	return harmless_surface_color


## Dash pattern for how obscured a point is: DetectionManager's light
## model, and any sight-blocking cloud counts as heavily obscured.
func _pattern_at(point: Vector3, context: WorldContext) -> Vector2:
	var cloud: Surface = SurfaceManager.cloud_at(point, context)
	if cloud and cloud.blocks_sight:
		return PATTERN_HEAVY
	match DetectionManager.obscurity_at(point):
		UnitAwareness.Obscurity.HEAVY:
			return PATTERN_HEAVY
		UnitAwareness.Obscurity.LIGHT:
			return PATTERN_LIGHT
	return PATTERN_CLEAR


## Cost, not straight-line distance: it's what the budget is spent in,
## so "x / y" compares like with like. Crimson when the route doesn't
## fit.
func _update_readout(end: Vector3, total_cost: float, budget: float) -> void:
	_readout.global_position = end + Vector3(0, readout_height, 0)
	if is_inf(budget):
		_readout.text = "%.1f m" % total_cost
		_readout.modulate = path_in_range_color
	else:
		_readout.text = "%.1f / %.1f m" % [total_cost, maxf(budget, 0.0)]
		_readout.modulate = path_in_range_color if total_cost <= budget else path_out_of_range_color

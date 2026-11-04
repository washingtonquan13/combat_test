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
## movement_path_tube.gdshader. The values are BG3's
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

const TUBE_SHADER: Shader = preload("res://systems/indicator_system/movement_path_tube.gdshader")

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

## One box: 8 corners, 12 triangles. Corner i's bits are (end, side, up).
const BOX_INDICES: PackedInt32Array = [
	0, 1, 3, 0, 3, 2, 4, 6, 7, 4, 7, 5,
	0, 4, 5, 0, 5, 1, 2, 3, 7, 2, 7, 6,
	0, 2, 6, 0, 6, 4, 1, 5, 7, 1, 7, 3,
]

var _tube: MeshInstance3D
var _mesh := ArrayMesh.new()
var _material := ShaderMaterial.new()
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
	var built: Dictionary = _create_line_mesh()
	_tube = built.mesh_instance
	_tube.mesh = _mesh
	# The boxes are built in world space.
	_tube.top_level = true
	_tube.global_transform = Transform3D.IDENTITY
	_tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Boxes are rebuilt in the shader around their axis; keep the culling
	# box from dropping a piece the camera can see.
	_tube.extra_cull_margin = 1.0

	_material.shader = TUBE_SHADER
	# Over clouds and fire, which draw in the same transparent pass.
	_material.render_priority = 20
	_tube.material_override = _material
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
	_material.set_shader_parameter("radius", tube_width * 0.5)
	_material.set_shader_parameter("min_pixel_radius", min_pixel_radius)
	_material.set_shader_parameter("fade_start", fade_start)
	_material.set_shader_parameter("fade_end", fade_end)
	_material.set_shader_parameter("anim_speed", anim_speed)
	_material.set_shader_parameter("pulse_limits", pulse_limits)
	_material.set_shader_parameter("pulse_speed", pulse_speed)
	_material.set_shader_parameter("brightness", brightness)


func hide_visuals() -> void:
	super()
	if _readout:
		_readout.visible = false


func is_showing_anything() -> bool:
	return super() or (_readout != null and _readout.visible)


## Draws the route the caster would take to aim.point, planned in full
## so the part beyond Unit.move_budget() (move_remaining in combat, INF
## out of it) can be drawn past-limit. Nothing to draw without a caster
## or a ground point, nor over a unit or interactable: clicking those
## doesn't move, so the path must not point at them.
func draw(aim: Aim) -> void:
	if aim.caster == null or aim.point == null:
		_hide_all()
		return
	if aim.cursor and (aim.cursor.unit or aim.cursor.interactable):
		_hide_all()
		return

	var planned: Dictionary = aim.caster.preview_route(aim.point)
	var path: PackedVector3Array = planned.path
	if path.size() < 2:
		_hide_all()
		return

	var cost: PackedFloat32Array = planned.cumulative_cost
	var total_cost: float = cost[cost.size() - 1]
	var budget: float = aim.caster.move_budget()
	_update_readout(path[path.size() - 1], total_cost, budget)
	if path != _built_path or total_cost != _built_cost or budget != _built_budget:
		_build(path, cost, budget, WorldManager.context_for(aim.caster))
		_built_path = path
		_built_cost = total_cost
		_built_budget = budget
	_tube.visible = true
	_readout.visible = true


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

	_fill_mesh(_pieces(points), split_at, context)


func _length_of(points: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total


## The polyline lifted and cut into pieces no longer than
## max_piece_length, dropping zero-length steps.
func _pieces(points: PackedVector3Array) -> PackedVector3Array:
	var lift := Vector3(0.0, height_offset, 0.0)
	var out := PackedVector3Array()
	if points.is_empty():
		return out
	out.append(points[0] + lift)
	for i in range(1, points.size()):
		var a: Vector3 = points[i - 1] + lift
		var b: Vector3 = points[i] + lift
		var length: float = a.distance_to(b)
		if length < 0.001:
			continue
		var count: int = maxi(1, ceili(length / max_piece_length))
		for k in range(1, count + 1):
			out.append(a.lerp(b, float(k) / float(count)))
	return out


## One box per piece, every corner carrying the piece's data (see the
## layout at the top of movement_path_tube.gdshader).
func _fill_mesh(points: PackedVector3Array, split_at: float, context: WorldContext) -> void:
	_mesh.clear_surfaces()
	var count: int = points.size() - 1
	if count < 1:
		return

	var dirs := PackedVector3Array()
	var distance := PackedFloat32Array([0.0])
	for i in range(count):
		var d: Vector3 = points[i + 1] - points[i]
		dirs.append(d.normalized())
		distance.append(distance[i] + d.length())
	var total: float = distance[count]
	_material.set_shader_parameter("total_length", total)

	# Obscurity per piece end, so a dash pattern can blend across a piece.
	var patterns: Array[Vector2] = []
	for i in range(points.size()):
		patterns.append(_pattern_at(points[i], context))

	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var c2 := PackedFloat32Array()
	var c3 := PackedFloat32Array()
	var indices := PackedInt32Array()

	var radius: float = tube_width * 0.5
	for i in range(count):
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var u: Vector3 = dirs[i]
		var n0: Vector3 = _miter(dirs[i - 1], u) if i > 0 else u
		var n1: Vector3 = _miter(u, dirs[i + 1]) if i < count - 1 else u
		var mid_distance: float = (distance[i] + distance[i + 1]) * 0.5
		var color: Color = _color_at(a.lerp(b, 0.5), mid_distance >= split_at, context).srgb_to_linear()

		# Corner positions only tell the vertex shader which end and
		# which side each corner is; it sizes the box itself.
		var side: Vector3 = u.cross(Vector3.UP)
		side = Vector3.RIGHT if side.length() < 0.001 else side.normalized()
		var up: Vector3 = side.cross(u)
		var base: int = vertices.size()
		for corner in 8:
			var end: Vector3 = b if corner & 4 else a
			var sx: float = 1.0 if corner & 2 else -1.0
			var sy: float = 1.0 if corner & 1 else -1.0
			vertices.append(end + side * sx * radius + up * sy * radius)
			colors.append(color)
			uvs.append(patterns[i])
			uv2s.append(patterns[i + 1])
			c0.append_array([a.x, a.y, a.z, distance[i]])
			c1.append_array([b.x, b.y, b.z, distance[i + 1]])
			c2.append_array([n0.x, n0.y, n0.z, 0.0])
			c3.append_array([n1.x, n1.y, n1.z, 0.0])
		for index in BOX_INDICES:
			indices.append(base + index)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_CUSTOM2] = c2
	arrays[Mesh.ARRAY_CUSTOM3] = c3
	arrays[Mesh.ARRAY_INDEX] = indices
	var format: int = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, format)


## The plane two pieces share at a joint: its normal bisects their
## directions, so each piece keeps exactly its own side. A near-reversal
## has no sensible bisector; the pieces then just butt-join.
func _miter(dir_in: Vector3, dir_out: Vector3) -> Vector3:
	var n: Vector3 = dir_in + dir_out
	if n.length() < 0.3:
		return dir_out
	return n.normalized()


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
	if surface.status_effect != null or surface.movement_cost_multiplier > 1.0 or surface.blocks_sight:
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

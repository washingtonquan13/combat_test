class_name PathTube
extends MeshInstance3D
## One BG3-style line: a thin ray-traced glowing tube along a polyline,
## drawn by movement_path_tube.gdshader. Every indicator line uses this
## (movement path, aim lines, jump arc, seeking route, wall outline, a
## flier's drop line), so they share one look: centre-bright, faded in
## and out at the ends, a slow pulse, 10% through walls, never thinner
## than a pixel.
##
## Give it world-space points and colours (one for the whole line, or one
## per piece); optionally a dash pattern per point. The caller decides
## what the colours mean; this only draws. Each tube owns its material,
## since the fade needs the line's own total length.
##
## IndicatorBase._create_tube() makes one already registered with the
## indicator's _owned_meshes, so hide_visuals/is_showing_anything see it.

const TUBE_SHADER: Shader = preload("res://systems/indicator_system/movement_path_tube.gdshader")

## (on, off) metres; off 0 is solid (BG3 PatternClear).
const PATTERN_CLEAR := Vector2(1.0, 0.0)

## One box: 8 corners, 12 triangles. Corner i's bits are (end, side, up).
const BOX_INDICES: PackedInt32Array = [
	0, 1, 3, 0, 3, 2, 4, 6, 7, 4, 7, 5,
	0, 4, 5, 0, 5, 1, 2, 3, 7, 2, 7, 6,
	0, 2, 6, 0, 6, 4, 1, 5, 7, 1, 7, 3,
]

## Full tube width in metres (BG3 Width).
var width: float = 0.025
## Never thinner than this many pixels in radius; past that it widens
## and dims instead of breaking into dots.
var min_pixel_radius: float = 0.9
## Above the WorldEnvironment glow threshold, so it blooms a little.
var brightness: float = 2.0
## Fade in from the first point / out to the last (BG3
## AttenuationDistanceStart/End). 0 draws the ends at full strength.
var fade_start: float = 1.0
var fade_end: float = 1.0
## Dash scroll speed (BG3 AnimationSpeed) and the pulse (Pulsation*).
var anim_speed: float = 1.0
var pulse_limits: Vector2 = Vector2(0.1, 0.4)
var pulse_speed: float = 1.0

var _mesh := ArrayMesh.new()
var _material := ShaderMaterial.new()


func _init() -> void:
	mesh = _mesh
	# The boxes are built in world space.
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Boxes are rebuilt in the shader around their axis; keep the culling
	# box from dropping a piece the camera can see.
	extra_cull_margin = 1.0
	_material.shader = TUBE_SHADER
	# Over clouds and fire, which draw in the same transparent pass.
	_material.render_priority = 20
	material_override = _material
	visible = false


## Draws `points` in one colour and shows the tube. Hides it when there
## is nothing to draw (fewer than two distinct points).
func show_line(points: PackedVector3Array, color: Color) -> void:
	build(points, PackedColorArray([color]))
	visible = _mesh.get_surface_count() > 0


## Rebuilds the mesh. `piece_colors` (sRGB) is one colour, or one per
## piece (points.size() - 1). `patterns` is empty (solid) or one (on, off)
## per point, blended along each piece. A line whose last point is its
## first closes: its joint there is mitred like any other.
func build(points: PackedVector3Array, piece_colors: PackedColorArray, patterns: PackedVector2Array = PackedVector2Array()) -> void:
	_mesh.clear_surfaces()
	_apply_uniforms()
	points = _without_repeats(points)
	var count: int = points.size() - 1
	if count < 1 or piece_colors.is_empty():
		return
	var per_piece: bool = piece_colors.size() == count
	var per_point: bool = patterns.size() == points.size()
	var closed: bool = count > 2 and points[0].distance_squared_to(points[count]) < 0.000001

	var dirs := PackedVector3Array()
	var distance := PackedFloat32Array([0.0])
	for i in range(count):
		var d: Vector3 = points[i + 1] - points[i]
		dirs.append(d.normalized())
		distance.append(distance[i] + d.length())
	_material.set_shader_parameter("total_length", distance[count])

	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var c2 := PackedFloat32Array()
	var c3 := PackedFloat32Array()
	var indices := PackedInt32Array()

	var radius: float = width * 0.5
	for i in range(count):
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var u: Vector3 = dirs[i]
		var n0: Vector3 = u
		if i > 0:
			n0 = _miter(dirs[i - 1], u)
		elif closed:
			n0 = _miter(dirs[count - 1], u)
		var n1: Vector3 = u
		if i < count - 1:
			n1 = _miter(u, dirs[i + 1])
		elif closed:
			n1 = _miter(u, dirs[0])
		var color: Color = (piece_colors[i] if per_piece else piece_colors[0]).srgb_to_linear()
		var pattern_a: Vector2 = patterns[i] if per_point else PATTERN_CLEAR
		var pattern_b: Vector2 = patterns[i + 1] if per_point else PATTERN_CLEAR

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
			uvs.append(pattern_a)
			uv2s.append(pattern_b)
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


## The polyline lifted by `lift` and cut into pieces no longer than
## `max_length`, so per-piece colours and per-point patterns can change
## along it.
static func cut(points: PackedVector3Array, max_length: float, lift: Vector3 = Vector3.ZERO) -> PackedVector3Array:
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
		var count: int = maxi(1, ceili(length / max_length))
		for k in range(1, count + 1):
			out.append(a.lerp(b, float(k) / float(count)))
	return out


func _apply_uniforms() -> void:
	_material.set_shader_parameter("radius", width * 0.5)
	_material.set_shader_parameter("min_pixel_radius", min_pixel_radius)
	# The shader divides by these; 0 means "no fade".
	_material.set_shader_parameter("fade_start", maxf(fade_start, 0.0001))
	_material.set_shader_parameter("fade_end", maxf(fade_end, 0.0001))
	_material.set_shader_parameter("anim_speed", anim_speed)
	_material.set_shader_parameter("pulse_limits", pulse_limits)
	_material.set_shader_parameter("pulse_speed", pulse_speed)
	_material.set_shader_parameter("brightness", brightness)


## Zero-length steps have no direction to mitre or trace.
static func _without_repeats(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for point in points:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(point) >= 0.000001:
			out.append(point)
	return out


## The plane two pieces share at a joint: its normal bisects their
## directions, so each piece keeps exactly its own side. A near-reversal
## has no sensible bisector; the pieces then just butt-join.
static func _miter(dir_in: Vector3, dir_out: Vector3) -> Vector3:
	var n: Vector3 = dir_in + dir_out
	if n.length() < 0.3:
		return dir_out
	return n.normalized()

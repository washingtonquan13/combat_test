class_name RibbonTrail
extends MeshInstance3D
## A camera-facing ribbon left behind its parent as it moves: the
## parent's recent positions, newest widest and brightest, narrowing and
## fading as they age out. Drawn in world space (top_level), so it stays
## where the parent was rather than riding along with it.
##
## Set emitting false to stop laying new points; what is there ages out.

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform vec4 tint : source_color = vec4(1.0);
uniform float energy = 3.0;
void fragment() {
	float across = abs(UV.x * 2.0 - 1.0);
	float soft = 1.0 - across * across;
	ALBEDO = tint.rgb * mix(vec3(1.0), vec3(1.6), COLOR.a * (1.0 - across)) * energy;
	ALPHA = clamp(soft * COLOR.a * tint.a, 0.0, 1.0);
}
"""

static var _shader: Shader

@export var lifetime: float = 0.15
@export var width: float = 0.08
@export var color: Color = Color.WHITE
@export var energy: float = 3.0
## A jump longer than this in one frame (the parent placed, not moving)
## starts the ribbon over instead of drawing a streak across it.
@export var max_step: float = 3.0

var emitting: bool = true

var _points: PackedVector3Array = PackedVector3Array()
var _ages: PackedFloat32Array = PackedFloat32Array()
var _strip := ImmediateMesh.new()


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = _strip
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	var material := ShaderMaterial.new()
	material.shader = _shader
	material.set_shader_parameter(&"tint", color)
	material.set_shader_parameter(&"energy", energy)
	material_override = material


func is_empty() -> bool:
	return _points.is_empty()


func _process(delta: float) -> void:
	for i in _ages.size():
		_ages[i] += delta
	while not _ages.is_empty() and _ages[0] > lifetime:
		_ages.remove_at(0)
		_points.remove_at(0)
	var parent := get_parent() as Node3D
	if emitting and parent and parent.is_visible_in_tree():
		var here: Vector3 = parent.global_position
		if not _points.is_empty() and _points[-1].distance_to(here) > max_step:
			_points.clear()
			_ages.clear()
		_points.append(here)
		_ages.append(0.0)
	_rebuild()


func _rebuild() -> void:
	_strip.clear_surfaces()
	var count: int = _points.size()
	var camera := get_viewport().get_camera_3d()
	if count < 2 or camera == null:
		return
	var eye: Vector3 = camera.global_position
	_strip.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in count:
		var p: Vector3 = _points[i]
		var tangent: Vector3 = _points[min(i + 1, count - 1)] - _points[max(i - 1, 0)]
		var side: Vector3 = tangent.cross(eye - p)
		if side.length_squared() < 1e-10:
			side = Vector3.RIGHT
		var life: float = clamp(1.0 - _ages[i] / lifetime, 0.0, 1.0)
		side = side.normalized() * width * 0.5 * life
		var shade := Color(1, 1, 1, life * life)
		_strip.surface_set_color(shade)
		_strip.surface_set_uv(Vector2(0.0, float(i) / (count - 1)))
		_strip.surface_add_vertex(p + side)
		_strip.surface_set_color(shade)
		_strip.surface_set_uv(Vector2(1.0, float(i) / (count - 1)))
		_strip.surface_add_vertex(p - side)
	_strip.surface_end()

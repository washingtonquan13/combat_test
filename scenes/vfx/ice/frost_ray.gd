extends Node3D
## Visual for Ray of Frost (BeamStep, abilities/ray_of_frost.tres): a
## pale-blue beam held from the caster's hand to the target - a white-hot
## core in a ragged, streaming cold halo, frost motes drifting off it -
## with a cold glow at the hand and, where it hits, a burst of hoarfrost
## sparkle and a puff of frost mist. It shoots out, holds, and thins
## away; the hit lands when it arrives (BeamStep). No ice crystals: the
## frost look is hoarfrost and mist, as on the Ice surface.
##
## The beam follows the hand while it holds, so it stays in the cast
## pose's hand. Built in code like the other spell visuals (see VfxBits).

const BEAM_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform vec4 core_color : source_color = vec4(0.92, 0.98, 1.0, 1.0);
uniform vec4 halo_color : source_color = vec4(0.35, 0.72, 1.0, 1.0);
uniform float energy = 2.6;
uniform float fade = 1.0;
uniform float beam_length = 10.0;
uniform float scroll = 7.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	float x = UV.x * 2.0 - 1.0;
	float metres = UV.y * beam_length;
	float n = noise(vec2(metres * 1.6 - TIME * scroll, x * 2.5 + TIME * 0.7)) * 0.6
		+ noise(vec2(metres * 4.5 - TIME * scroll * 1.6, x * 5.0 - TIME)) * 0.4;
	float edge = abs(x) + (n - 0.5) * 0.45;
	float core = exp(-x * x * 45.0);
	float halo = exp(-edge * edge * 5.0) * (0.3 + 0.7 * n);
	float ends = smoothstep(0.0, 0.25, metres) * smoothstep(0.0, 0.15, beam_length - metres);
	vec3 col = core_color.rgb * core * 1.6 + halo_color.rgb * halo;
	ALBEDO = col * energy;
	ALPHA = clamp((core + halo) * ends * fade, 0.0, 1.0);
}
"""

static var _beam_shader: Shader

@export var beam_width: float = 0.34
@export var hold_time: float = 0.55
@export var fade_time: float = 0.2
@export var halo_color: Color = Color(0.35, 0.72, 1.0)
@export var frost_color: Color = Color(0.82, 0.93, 1.0)

var _caster: Unit
var _launch_from: CharacterModel.Anchor = CharacterModel.Anchor.HAND
var _from: Vector3
var _to: Vector3
var _reach: float = 0.0
var _fade: float = 1.0
var _strip := ImmediateMesh.new()
var _material: ShaderMaterial
var _hand: Node3D
var _hand_glow: MeshInstance3D
var _motes: GPUParticles3D
var _light: OmniLight3D


func _ready() -> void:
	top_level = true
	if _beam_shader == null:
		_beam_shader = Shader.new()
		_beam_shader.code = BEAM_SHADER_CODE
	_material = ShaderMaterial.new()
	_material.shader = _beam_shader
	_material.set_shader_parameter(&"halo_color", halo_color)
	var beam := MeshInstance3D.new()
	beam.mesh = _strip
	beam.material_override = _material
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beam)
	beam.top_level = true
	beam.global_transform = Transform3D.IDENTITY

	_hand = Node3D.new()
	add_child(_hand)
	_hand.top_level = true
	_hand_glow = VfxBits.glow(_hand, halo_color, 0.45, 2.2, 2.0)

	_motes = VfxBits.particles(self, Color.WHITE, 0.04, 3.0, 60, 0.6)
	_motes.top_level = true
	var process := _motes.process_material as ParticleProcessMaterial
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.direction = Vector3.UP
	process.spread = 180.0
	process.initial_velocity_min = 0.1
	process.initial_velocity_max = 0.5
	process.gravity = Vector3(0.0, -0.4, 0.0)
	process.scale_min = 0.5
	process.scale_max = 1.3
	process.scale_curve = VfxBits.size_curve(1.0, 0.2)
	process.color_ramp = VfxBits.ramp(PackedColorArray([
		Color(1.4, 1.5, 1.6, 1.0), Color(frost_color, 0.8), Color(halo_color, 0.0)]))

	_light = OmniLight3D.new()
	_light.light_color = halo_color
	_light.light_energy = 0.0
	_light.omni_range = 4.0
	add_child(_light)
	_light.top_level = true


## Shoots the beam from `from` to `to` over reach_time, holds it and
## fades it, then frees itself.
func fire(from: Vector3, to: Vector3, reach_time: float, caster: Unit, launch_from: CharacterModel.Anchor) -> void:
	_from = from
	_to = to
	_caster = caster
	_launch_from = launch_from
	_motes.emitting = true
	var tween := create_tween()
	tween.tween_property(self, "_reach", 1.0, max(reach_time, 0.01))
	tween.tween_callback(_hit)
	tween.tween_interval(hold_time)
	tween.tween_property(self, "_fade", 0.0, fade_time)
	tween.tween_callback(func(): _motes.emitting = false)
	tween.tween_interval(0.7)
	tween.tween_callback(queue_free)


## Where it lands: hoarfrost sparkle thrown out, a puff of frost mist, a
## cold flash.
func _hit() -> void:
	VfxBits.flash(_to, frost_color, 1.0, 2.2, 0.3)
	VfxBits.light_flash(_to, halo_color, 2.5, 4.0, hold_time + fade_time)
	VfxBits.burst(_to, PackedColorArray([Color(1.5, 1.6, 1.7, 1.0), frost_color, Color(halo_color, 0.0)]),
		0.05, 3.0, 36, 0.7, Vector2(1.5, 3.5), -1.5, 4.0)
	VfxBits.burst(_to, PackedColorArray([Color(frost_color, 0.0), Color(frost_color, 0.35), Color(halo_color, 0.0)]),
		0.7, 0.6, 8, 0.9, Vector2(0.3, 0.9), 0.3, 2.0)


func _process(_delta: float) -> void:
	if is_instance_valid(_caster) and _launch_from != CharacterModel.Anchor.GROUND:
		_from = _caster.anchor(_launch_from)
	var tip: Vector3 = _from.lerp(_to, _reach)
	_hand.global_position = _from
	_hand_glow.scale = Vector3.ONE * _fade
	_material.set_shader_parameter(&"fade", _fade)
	_material.set_shader_parameter(&"beam_length", max(_from.distance_to(tip), 0.01))
	_place_motes(_from, tip)
	_light.global_position = tip
	_light.light_energy = 1.6 * _fade
	_draw_beam(_from, tip, beam_width * (0.6 + 0.4 * _fade))


## The motes come off the whole length of the beam.
func _place_motes(a: Vector3, b: Vector3) -> void:
	var length: float = a.distance_to(b)
	if length < 0.05:
		return
	var mid: Vector3 = (a + b) * 0.5
	_motes.global_transform = Transform3D(Basis.looking_at(b - a, _up_for(b - a)), mid)
	(_motes.process_material as ParticleProcessMaterial).emission_box_extents = Vector3(0.06, 0.06, length * 0.5)


## A camera-facing strip from a to b, UV.x across and UV.y along.
func _draw_beam(a: Vector3, b: Vector3, width: float) -> void:
	_strip.clear_surfaces()
	var camera := get_viewport().get_camera_3d()
	if camera == null or a.distance_to(b) < 0.01:
		return
	var along: Vector3 = b - a
	var side: Vector3 = along.cross(camera.global_position - (a + b) * 0.5)
	if side.length_squared() < 1e-10:
		side = along.cross(_up_for(along))
	side = side.normalized() * width * 0.5
	_strip.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	_strip.surface_set_uv(Vector2(0.0, 0.0))
	_strip.surface_add_vertex(a + side)
	_strip.surface_set_uv(Vector2(1.0, 0.0))
	_strip.surface_add_vertex(a - side)
	_strip.surface_set_uv(Vector2(0.0, 1.0))
	_strip.surface_add_vertex(b + side)
	_strip.surface_set_uv(Vector2(1.0, 1.0))
	_strip.surface_add_vertex(b - side)
	_strip.surface_end()


func _up_for(direction: Vector3) -> Vector3:
	return Vector3.RIGHT if abs(direction.normalized().y) > 0.99 else Vector3.UP

extends Node3D
## A cone of frost blasted from this node's position, for a cone attack
## like ConeTargeting's (pass its length and half_angle()). The ice
## counterpart of lightning_cone.gd.
##
##  - a cold mist rolling out from the hand, filling the cone
##    (frost_mist.gdshader, raymarched like the electric cone's body);
##  - a spray of glittering frost blown along it.
## One cold light. Plays once and frees itself.
##
## Visual only: what is hit, and the damage, is the ability's business,
## and so is the frost it leaves on the ground (the Ice surface,
## SpawnSurfaceEffect, whose front_seconds matches the mist's reveal).

const MIST_SHADER: Shader = preload("res://scenes/vfx/ice/frost_mist.gdshader")

## How long the cone sprays.
@export var hold_seconds: float = 0.6
## How long the mist takes to clear after the spray stops.
@export var mist_fade_seconds: float = 0.6
## Seconds the mist takes to reach the cone's end.
@export var reveal_seconds: float = 0.25
@export var mist_strength: float = 0.5
@export var light_energy: float = 2.5
@export var light_color: Color = Color(0.55, 0.8, 1.0)

var _mist: MeshInstance3D
var _mist_material: ShaderMaterial
var _spray: CPUParticles3D
var _light: OmniLight3D
var _direction: Vector3 = Vector3.FORWARD
var _length: float = 9.0
var _half_angle: float = 0.45
var _age: float = 0.0
var _playing: bool = false


func _ready() -> void:
	_mist_material = ShaderMaterial.new()
	_mist_material.shader = MIST_SHADER
	var noise := NoiseTexture3D.new()
	noise.width = 64
	noise.height = 64
	noise.depth = 64
	noise.seamless = true
	var fast := FastNoiseLite.new()
	fast.frequency = 0.05
	fast.fractal_octaves = 3
	noise.noise = fast
	_mist_material.set_shader_parameter("noise", noise)
	_mist = MeshInstance3D.new()
	# A unit box; the shader stretches it around the cone.
	_mist.mesh = BoxMesh.new()
	_mist.material_override = _mist_material
	_mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mist)
	_spray = _make_spray()
	add_child(_spray)
	_light = OmniLight3D.new()
	_light.light_color = light_color
	_light.light_energy = 0.0
	add_child(_light)
	_mist.visible = _playing
	if _playing:
		_start()
	set_process(_playing)


## Starts the blast. `direction` is the cone's axis in world space.
## `_targets` is unused: the same signature as lightning_cone.gd's.
func play(direction: Vector3, length: float, half_angle: float, _targets: PackedVector3Array = PackedVector3Array()) -> void:
	_direction = direction.normalized()
	_length = length
	_half_angle = half_angle
	_age = 0.0
	_playing = true
	if is_node_ready():
		_start()


func _start() -> void:
	set_process(true)
	_mist.visible = true
	_shape_mist()
	var axis: Vector3 = (global_basis.inverse() * _direction).normalized()
	_spray.direction = axis
	_spray.spread = rad_to_deg(_half_angle) * 0.8
	_spray.emitting = true
	_light.position = axis * _length * 0.3
	_light.omni_range = _length
	_process(0.0)


func _process(delta: float) -> void:
	if not _playing:
		return
	_age += delta
	var mist_life: float = hold_seconds + mist_fade_seconds
	if _age >= maxf(mist_life, hold_seconds + _spray.lifetime):
		queue_free()
		return
	if _age >= hold_seconds:
		_spray.emitting = false
	var mist: float = smoothstep(0.0, 0.08, _age) * (1.0 - smoothstep(hold_seconds, mist_life, _age))
	_mist.visible = mist > 0.0
	_mist_material.set_shader_parameter("time", _age)
	_mist_material.set_shader_parameter("reveal", clampf(_age / reveal_seconds, 0.0, 1.0) * 1.2)
	_mist_material.set_shader_parameter("strength", mist_strength * mist)
	_light.light_energy = light_energy * (1.0 - smoothstep(hold_seconds * 0.5, mist_life, _age)) * randf_range(0.9, 1.0)


## Sizes and aims the mist to the cone being played.
func _shape_mist() -> void:
	var r: float = tan(_half_angle) * _length * 1.02
	# The shader moves the box's corners, so culling needs the real size.
	_mist.custom_aabb = AABB(Vector3(-r, -r, -_length), Vector3(2.0 * r, 2.0 * r, _length))
	_mist_material.set_shader_parameter("cone_length", _length)
	_mist_material.set_shader_parameter("half_angle", _half_angle)
	_mist_material.set_shader_parameter("noise_offset", Vector3(randf(), randf(), randf()))
	var axis: Vector3 = (global_basis.inverse() * _direction).normalized()
	var up: Vector3 = Vector3.UP if absf(axis.y) < 0.99 else Vector3.RIGHT
	# The mist's -Z runs along the cone, its origin at the hand.
	_mist.transform = Transform3D(Basis.looking_at(axis, up), Vector3.ZERO)


## Glittering frost blown along the cone.
func _make_spray() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.amount = 400
	p.lifetime = 0.7
	p.local_coords = false
	p.initial_velocity_min = 7.0
	p.initial_velocity_max = 14.0
	p.damping_min = 6.0
	p.damping_max = 10.0
	p.gravity = Vector3(0.0, -0.6, 0.0)
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.2
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.3))
	grow.add_point(Vector2(0.3, 1.0))
	grow.add_point(Vector2(1.0, 1.6))
	p.scale_amount_curve = grow
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.95, 0.98, 1.0, 1.0))
	ramp.set_color(1, Color(0.5, 0.75, 1.0, 0.0))
	p.color_ramp = ramp
	var quad := QuadMesh.new()
	quad.size = Vector2(0.08, 0.08)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _soft_dot()
	material.albedo_color = Color(1.4, 1.6, 2.0)
	quad.material = material
	p.mesh = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


func _soft_dot() -> Texture2D:
	var dot := GradientTexture2D.new()
	dot.width = 32
	dot.height = 32
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(0.5, 0.0)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.add_point(0.25, Color(1, 1, 1, 0.6))
	g.set_color(g.get_point_count() - 1, Color(1, 1, 1, 0))
	dot.gradient = g
	return dot

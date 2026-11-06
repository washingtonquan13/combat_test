extends Node3D
## Visual for Fire Bolt (ProjectileStep, abilities/fire_bolt.tres): a
## fast, straight streak of flame - a white-hot churning core drawn out
## along the flight in a flickering orange glow, a hot inner tail inside a
## wider flame tail, shedding embers - kicked off by a flash at the hand
## and bursting in a hard splash of fire and embers on the hit. Smaller
## than the Fireball (scenes/vfx/fireball), but it should hit like a shot,
## not drift like a spark. Built in code like the other spell visuals (see VfxBits).

const CORE_SHADER: Shader = preload("res://scenes/vfx/fireball/fireball_core.gdshader")

@export var flame_color: Color = Color(1.0, 0.45, 0.08)
@export var hot_color: Color = Color(1.0, 0.85, 0.45)
@export var core_radius: float = 0.09

var _core: MeshInstance3D
var _glow: MeshInstance3D
var _tail: RibbonTrail
var _hot_tail: RibbonTrail
var _hot_glow: MeshInstance3D
var _embers: GPUParticles3D
var _light: OmniLight3D
var _clock: float = 0.0


func _ready() -> void:
	_core = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = core_radius
	sphere.height = core_radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var material := ShaderMaterial.new()
	material.shader = CORE_SHADER
	material.set_shader_parameter(&"intensity", 4.0)
	material.set_shader_parameter(&"churn_speed", 6.0)
	material.set_shader_parameter(&"churn_amount", 0.03)
	material.set_shader_parameter(&"churn_scale", 40.0)
	sphere.material = material
	_core.mesh = sphere
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Drawn out a little along the flight (-Z), the way a fast flame streaks.
	_core.scale = Vector3(1.0, 1.0, 2.6)
	add_child(_core)

	_glow = VfxBits.glow(self, flame_color, 0.85, 2.2, 2.2)
	_hot_glow = VfxBits.glow(self, hot_color, 0.32, 3.0, 2.5)

	# Two tails: a wide flame one, and a short white-hot one inside it.
	_tail = RibbonTrail.new()
	_tail.lifetime = 0.17
	_tail.width = 0.3
	_tail.color = flame_color
	_tail.energy = 2.6
	add_child(_tail)
	_hot_tail = RibbonTrail.new()
	_hot_tail.lifetime = 0.07
	_hot_tail.width = 0.11
	_hot_tail.color = hot_color
	_hot_tail.energy = 3.5
	add_child(_hot_tail)

	_embers = VfxBits.particles(self, Color.WHITE, 0.055, 3.2, 90, 0.45)
	var process := _embers.process_material as ParticleProcessMaterial
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = core_radius
	process.direction = Vector3.UP
	process.spread = 180.0
	process.initial_velocity_min = 0.2
	process.initial_velocity_max = 0.9
	process.gravity = Vector3(0.0, 1.2, 0.0)
	process.scale_min = 0.5
	process.scale_max = 1.2
	process.scale_curve = VfxBits.size_curve(1.0, 0.1)
	process.color_ramp = VfxBits.ramp(PackedColorArray([
		Color(1.4, 1.1, 0.6, 1.0), flame_color, Color(0.6, 0.1, 0.02, 0.0)]))
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 0.6
	_embers.emitting = true

	_light = OmniLight3D.new()
	_light.light_color = flame_color
	_light.light_energy = 2.5
	_light.omni_range = 4.0
	add_child(_light)
	_launch.call_deferred(global_position)


## The kick at the hand: a hot flash and a few sparks.
func _launch(at: Vector3) -> void:
	VfxBits.flash(at, hot_color, 0.7, 3.0, 0.12)
	VfxBits.light_flash(at, flame_color, 3.0, 3.5, 0.15)
	VfxBits.burst(at, PackedColorArray([Color(1.6, 1.3, 0.7, 1.0), flame_color, Color(0.6, 0.1, 0.02, 0.0)]),
		0.04, 3.0, 14, 0.25, Vector2(1.5, 3.5), 0.0, 6.0)


## The flicker: the glow and light breathe on two out-of-step waves.
func _process(delta: float) -> void:
	_clock += delta
	var flicker: float = 0.85 + 0.1 * sin(_clock * 37.0) + 0.08 * sin(_clock * 23.0 + 1.3)
	_glow.scale = Vector3.ONE * flicker
	_hot_glow.scale = Vector3(1.0, 1.0, 1.8) * (1.6 - flicker * 0.6)
	_light.light_energy = 2.5 * flicker


## Goes out in a splash of fire and a spray of embers falling away.
func arrive() -> void:
	var at: Vector3 = global_position
	_core.visible = false
	_glow.visible = false
	_hot_glow.visible = false
	_light.visible = false
	_tail.emitting = false
	_hot_tail.emitting = false
	_embers.emitting = false
	VfxBits.flash(at, hot_color, 0.9, 4.0, 0.12)
	VfxBits.flash(at, flame_color, 1.9, 3.2, 0.35)
	VfxBits.light_flash(at, flame_color, 7.0, 6.0, 0.4)
	# The splash: soft flame puffs swelling out and up.
	VfxBits.burst(at, PackedColorArray([Color(1.5, 1.0, 0.5, 0.9), flame_color, Color(0.4, 0.06, 0.0, 0.0)]),
		0.45, 1.9, 16, 0.45, Vector2(1.0, 2.8), 1.5, 5.0)
	# The embers: small and quick, thrown out and falling.
	VfxBits.burst(at, PackedColorArray([Color(1.6, 1.3, 0.7, 1.0), flame_color, Color(0.7, 0.12, 0.02, 0.0)]),
		0.055, 3.2, 55, 0.7, Vector2(2.5, 7.0), -6.0, 2.5)
	await get_tree().create_timer(0.5).timeout

extends Node3D
## Visual for Fire Bolt (ProjectileStep, abilities/fire_bolt.tres): a
## small, fast mote of flame - a white-hot churning core in a flickering
## orange glow, shedding embers and a short flame tail - that bursts in
## a quick splash of fire and embers on the hit. Kept well under the
## Fireball's size (scenes/vfx/fireball), so the cantrip reads as the
## small one. Built in code like the other spell visuals (see VfxBits).

const CORE_SHADER: Shader = preload("res://scenes/vfx/fireball/fireball_core.gdshader")

@export var flame_color: Color = Color(1.0, 0.45, 0.08)
@export var core_radius: float = 0.07

var _core: MeshInstance3D
var _glow: MeshInstance3D
var _tail: RibbonTrail
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
	material.set_shader_parameter(&"intensity", 3.2)
	material.set_shader_parameter(&"churn_speed", 6.0)
	material.set_shader_parameter(&"churn_amount", 0.03)
	material.set_shader_parameter(&"churn_scale", 40.0)
	sphere.material = material
	_core.mesh = sphere
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Drawn out a little along the flight (-Z), the way a fast flame streaks.
	_core.scale = Vector3(1.0, 1.0, 1.6)
	add_child(_core)

	_glow = VfxBits.glow(self, flame_color, 0.55, 1.8, 2.2)

	_tail = RibbonTrail.new()
	_tail.lifetime = 0.09
	_tail.width = 0.14
	_tail.color = flame_color
	_tail.energy = 2.2
	add_child(_tail)

	_embers = VfxBits.particles(self, Color.WHITE, 0.05, 3.0, 40, 0.4)
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
	_light.light_energy = 1.5
	_light.omni_range = 3.0
	add_child(_light)


## The flicker: the glow and light breathe on two out-of-step waves.
func _process(delta: float) -> void:
	_clock += delta
	var flicker: float = 0.85 + 0.1 * sin(_clock * 37.0) + 0.08 * sin(_clock * 23.0 + 1.3)
	_glow.scale = Vector3.ONE * flicker
	_light.light_energy = 1.5 * flicker


## Goes out in a splash of fire and a spray of embers falling away.
func arrive() -> void:
	var at: Vector3 = global_position
	_core.visible = false
	_glow.visible = false
	_light.visible = false
	_tail.emitting = false
	_embers.emitting = false
	VfxBits.flash(at, flame_color, 1.3, 3.0, 0.3)
	VfxBits.light_flash(at, flame_color, 4.0, 5.0, 0.35)
	# The splash: soft flame puffs swelling out and up.
	VfxBits.burst(at, PackedColorArray([Color(1.5, 1.0, 0.5, 0.9), flame_color, Color(0.4, 0.06, 0.0, 0.0)]),
		0.35, 1.6, 10, 0.35, Vector2(0.8, 2.0), 1.5, 5.0)
	# The embers: small and quick, thrown out and falling.
	VfxBits.burst(at, PackedColorArray([Color(1.6, 1.3, 0.7, 1.0), flame_color, Color(0.7, 0.12, 0.02, 0.0)]),
		0.05, 3.0, 30, 0.6, Vector2(2.0, 5.5), -6.0, 2.5)
	await get_tree().create_timer(0.45).timeout

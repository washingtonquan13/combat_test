extends DecalSurface
## The Fire visual: DecalSurface draws the ground burning - a looping
## glow under dark crust - and charring as it goes out. On top, Flames
## burn across the patch, Sparks fly up, Smoke rises, Haze shimmers the
## air and the Light flickers orange over it. Expiry stops the emitters
## and fades the light and haze, then the scorch recedes as any film does.

## How thickly the flames stand, sized to the patch.
@export var flames_per_square_meter: float = 3.0
@export var sparks_per_square_meter: float = 6.0
@export var smoke_per_square_meter: float = 1.0
## How far the light's energy swings either side of its authored value.
@export var flicker: float = 0.3

@onready var _flames: GPUParticles3D = $Flames
@onready var _sparks: GPUParticles3D = $Sparks
@onready var _smoke: GPUParticles3D = $Smoke
@onready var _haze: MeshInstance3D = $Haze
@onready var _light: OmniLight3D = $Light

var _light_energy: float
var _burning: float = 1.0


func _ready() -> void:
	super()
	_light_energy = _light.light_energy
	# Deferred: SurfaceManager scales this to the radius after add_child.
	_fit_to_size.call_deferred()


## Undoes the patch's scale on what burns above it, and spreads each
## over it in meters.
func _fit_to_size() -> void:
	var radius_m: float = size.x * 0.5 * scale.x * 0.7
	var unscale := Vector3(1.0 / scale.x, 1.0 / scale.y, 1.0 / scale.z)
	var area: float = PI * radius_m * radius_m
	for emitter: GPUParticles3D in [_flames, _sparks, _smoke]:
		emitter.scale = unscale
		var process := emitter.process_material.duplicate() as ParticleProcessMaterial
		process.emission_ring_radius = radius_m
		emitter.process_material = process
	_flames.amount = maxi(8, roundi(area * flames_per_square_meter))
	_sparks.amount = maxi(6, roundi(area * sparks_per_square_meter))
	_smoke.amount = maxi(4, roundi(area * smoke_per_square_meter))
	_smoke.position.y *= unscale.y
	_haze.scale = unscale
	var quad := _haze.mesh.duplicate() as QuadMesh
	quad.size.x = radius_m * 2.2
	_haze.mesh = quad
	_light.scale = unscale
	_light.omni_range = radius_m * 2.5


func _process(delta: float) -> void:
	super(delta)
	var t: float = Time.get_ticks_msec() / 1000.0
	var swing: float = sin(t * 11.0) * 0.5 + sin(t * 17.3 + 1.3) * 0.3 + sin(t * 29.1 + 2.1) * 0.2
	_light.light_energy = _light_energy * (1.0 + swing * flicker) * _burning
	_haze.set_instance_shader_parameter("burning", _burning)


func dissipate() -> void:
	for emitter: GPUParticles3D in [_flames, _sparks, _smoke]:
		emitter.emitting = false
	create_tween().tween_property(self, "_burning", 0.0, recede_seconds * 0.6)
	super()

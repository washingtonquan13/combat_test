extends DecalSurface
## The Fire visual: DecalSurface draws the scorched ground with glowing
## embers; on top, the Flames particles burn across the patch and the
## Light flickers orange over it. Expiry puts the flames out and fades
## the light, then the scorch recedes as any film does.

## How thickly the flames stand, sized to the patch.
@export var flames_per_square_meter: float = 4.0
## How far the light's energy swings either side of its authored value.
@export var flicker: float = 0.3

@onready var _flames: GPUParticles3D = $Flames
@onready var _light: OmniLight3D = $Light

var _light_energy: float
var _burning: float = 1.0


func _ready() -> void:
	super()
	_light_energy = _light.light_energy
	# Deferred: SurfaceManager scales this to the radius after add_child.
	_fit_to_size.call_deferred()


## Undoes the patch's scale on the flames and light, and spreads them
## over it in meters.
func _fit_to_size() -> void:
	var radius_m: float = size.x * 0.5 * scale.x * 0.7
	var unscale := Vector3(1.0 / scale.x, 1.0 / scale.y, 1.0 / scale.z)
	_flames.scale = unscale
	_light.scale = unscale
	var process := _flames.process_material.duplicate() as ParticleProcessMaterial
	process.emission_ring_radius = radius_m
	process.emission_ring_inner_radius = 0.0
	_flames.process_material = process
	_flames.amount = maxi(8, roundi(PI * radius_m * radius_m * flames_per_square_meter))
	_light.omni_range = radius_m * 2.5


func _process(_delta: float) -> void:
	var t: float = Time.get_ticks_msec() / 1000.0
	var swing: float = sin(t * 11.0) * 0.5 + sin(t * 17.3 + 1.3) * 0.3 + sin(t * 29.1 + 2.1) * 0.2
	_light.light_energy = _light_energy * (1.0 + swing * flicker) * _burning


func dissipate() -> void:
	_flames.emitting = false
	create_tween().tween_property(self, "_burning", 0.0, recede_seconds * 0.6)
	super()

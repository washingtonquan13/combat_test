extends "res://systems/surface_system/fog_cloud.gd"
## Electrified Steam: the steam cloud, tinted, with lightning inside it
## the way a thundercloud has it: no bolts, the cloud lit blue from
## within. Strikes go off at the cubes still shown, flash and fade, now
## and then flashing again; the puffs near a strike glow from their cores
## (fog_puff.gdshader) and one light under the cloud flashes with them,
## so the ground lights in step. Cubes that recede carry no more charge;
## as the cloud burns off the strikes die away with it.

## Strikes started per second while the cloud is fully charged.
@export var strikes_per_second: float = 2.5
## Chance a strike flashes again as it fades.
@export var restrike_chance: float = 0.55
## How fast a flash fades, per second.
@export var strike_fade: float = 9.0
@export var light_energy: float = 2.5
@export var light_color: Color = Color(0.55, 0.7, 1.0)

## Two strikes at most at once: where (xyz) and how bright (w).
var _strikes: Array[Vector4] = [Vector4.ZERO, Vector4.ZERO]
## Flashes each strike has still to come.
var _restrikes: Array[int] = [0, 0]
var _strength: float = 1.0
var _light: OmniLight3D


func _ready() -> void:
	super()
	_light = OmniLight3D.new()
	_light.light_color = light_color
	_light.light_energy = 0.0
	_light.omni_range = 4.0
	_light.shadow_enabled = false
	# Placed in world space: the cloud billows and drifts, the cubes don't.
	_light.top_level = true
	add_child(_light)


func dissipate() -> void:
	super()
	create_tween().tween_property(self, "_strength", 0.0, seconds * 0.4)


## On the physics tick: fog_cloud.gd turns its own _process off and on.
func _physics_process(delta: float) -> void:
	for i in _strikes.size():
		var s: Vector4 = _strikes[i]
		s.w *= exp(-strike_fade * delta)
		if s.w < 0.12 and _restrikes[i] > 0:
			_restrikes[i] -= 1
			s.w = randf_range(0.5, 1.0) * _strength
		_strikes[i] = s
	if not _points.is_empty() and randf() < strikes_per_second * _strength * delta:
		_strike()
	var brightest: Vector4 = _strikes[0] if _strikes[0].w >= _strikes[1].w else _strikes[1]
	_light.light_energy = light_energy * brightest.w
	if brightest.w > 0.01:
		_light.global_position = Vector3(brightest.x, brightest.y, brightest.z)
	for layer in _layers:
		layer.set_instance_shader_parameter("strike_a", _strikes[0])
		layer.set_instance_shader_parameter("strike_b", _strikes[1])
		layer.set_instance_shader_parameter("flicker", flicker * _strength)


## Starts a strike somewhere in a shown cube, in the dimmer slot.
func _strike() -> void:
	var keys: Array = _points.keys()
	var cube: Vector3 = CloudGrid.centre_of(keys[randi() % keys.size()])
	var at: Vector3 = cube + Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * CloudGrid.CELL
	var slot: int = 0 if _strikes[0].w <= _strikes[1].w else 1
	_strikes[slot] = Vector4(at.x, at.y, at.z, randf_range(0.6, 1.0) * _strength)
	_restrikes[slot] = 0
	while _restrikes[slot] < 3 and randf() < restrike_chance:
		_restrikes[slot] += 1

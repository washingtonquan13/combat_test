extends Node3D
## Fire Breath's gust (fire_breath.gdshader): one live volume of fire
## streaming out along the cone it was breathed in, set by breathe().
## The Light rides out with the front, flaring, and dies with it. When
## the tail has chased the fire out and what is left has burnt out, it
## frees itself.

const VOLUME_SHADER: Shader = preload("res://systems/surface_system/fire_breath.gdshader")

## The tiling noise the fire streams through.
@export var noise: Texture3D
## How far past the cone, sideways, behind and up, the fire's box reaches.
@export var box_margin: float = 0.6
## Seconds the front takes to reach the end, holds there, and how fast
## (meters a second) the tail chases it out.
@export var front_seconds: float = 0.35
@export var hold_seconds: float = 0.5
@export var tail_speed: float = 13.0
## Meters the far end rises.
@export var lift: float = 0.9
## How long what is left takes to burn out once the tail reaches the end.
@export var burnout_seconds: float = 0.4

@onready var _volume: MeshInstance3D = $Volume
@onready var _light: OmniLight3D = $Light

var _material: ShaderMaterial
var _length: float = 9.0
var _age: float = 0.0
var _life: float = 1.0
var _light_energy: float


func _ready() -> void:
	_light_energy = _light.light_energy
	_light.light_energy = 0.0
	set_process(false)


## Breathes the fire out from apex along direction (a unit vector), as
## far as length, within half_angle of it. Called once, right after it is
## added to the tree.
func breathe(apex: Vector3, direction: Vector3, length: float, half_angle: float) -> void:
	_length = length
	var along := direction.normalized()
	var side := along.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	side = side.normalized()
	var frame := Basis(along, side.cross(along), side)
	global_transform = Transform3D(frame, apex)
	var radius: float = length * tan(half_angle)
	var up_local: Vector3 = frame.inverse() * Vector3.UP
	var low := Vector3(-box_margin, -radius - box_margin, -radius - box_margin)
	var high := Vector3(length + box_margin, radius + box_margin, radius + box_margin)
	# Room for the far end to rise into.
	low = low.min(low + up_local * lift)
	high = high.max(high + up_local * lift)
	var size := high - low
	var centre := (low + high) * 0.5
	var mesh := BoxMesh.new()
	mesh.size = size
	_material = ShaderMaterial.new()
	_material.shader = VOLUME_SHADER
	_material.render_priority = 1
	_material.set_shader_parameter("noise", noise)
	_material.set_shader_parameter("box_size", size)
	_material.set_shader_parameter("apex_local", -centre)
	_material.set_shader_parameter("up_local", up_local)
	_material.set_shader_parameter("world_offset", Vector3(randf(), randf(), randf()) * 10.0)
	_material.set_shader_parameter("cone_length", length)
	_material.set_shader_parameter("half_angle", half_angle)
	_material.set_shader_parameter("front_seconds", front_seconds)
	_material.set_shader_parameter("hold_seconds", hold_seconds)
	_material.set_shader_parameter("tail_speed", tail_speed)
	_material.set_shader_parameter("lift", lift)
	mesh.material = _material
	_volume.mesh = mesh
	_volume.position = centre
	# On the units' layer, which the burning ground's decal leaves out.
	_volume.layers = 1 << (Unit.RENDER_LAYER - 1)
	_life = front_seconds + hold_seconds + length / tail_speed + burnout_seconds
	_light.omni_range = radius + 3.0
	set_process(true)
	_process(0.0)


func _process(delta: float) -> void:
	_age += delta
	_material.set_shader_parameter("age", _age)
	var out: float = clampf((_life - _age) / burnout_seconds, 0.0, 1.0)
	_material.set_shader_parameter("strength", out)
	var reach: float = clampf(_age / front_seconds, 0.0, 1.0)
	_light.position = Vector3(_length * 0.5 * reach, 0.0, 0.0)
	_light.light_energy = _light_energy * (1.0 + 0.5 * (1.0 - reach)) * reach * out
	if _age >= _life:
		queue_free()

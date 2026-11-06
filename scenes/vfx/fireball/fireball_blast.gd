extends MeshInstance3D
## Explosive Fireball's blast (fireball_blast.gdshader): one live volume
## of fire bursting out from this node to radius, in the explosion's
## space (fireball_explosion.tscn, scaled to the ability's radius by its
## SpawnParticleStep, so it is authored for 3 m). It plays on its own
## from the moment it enters the tree and hides itself once burnt out;
## the explosion is freed when its AnimationPlayer finishes.

const VOLUME_SHADER: Shader = preload("res://scenes/vfx/fireball/fireball_blast.gdshader")

## The tiling noise the fire churns through.
@export var noise: Texture3D
@export var radius: float = 3.0
## Seconds the front takes to reach radius, the ball burns whole, and
## what is left takes to burn out. front_seconds matches the burning
## ground's (SpawnSurfaceEffect.front_seconds in explosive_fireball.tres),
## so the ground catches as the front reaches it.
@export var front_seconds: float = 0.3
@export var hold_seconds: float = 0.35
@export var burnout_seconds: float = 0.9
## Meters the ball rises over its life.
@export var lift: float = 0.9
## How far past radius the box reaches, sideways and down.
@export var box_margin: float = 0.4

var _material: ShaderMaterial
var _age: float = 0.0
var _life: float = 1.0


func _ready() -> void:
	_life = front_seconds + hold_seconds + burnout_seconds
	var reach: float = radius * 1.25 + box_margin
	# Room above for the ball to rise into.
	var low := Vector3(-reach, -reach, -reach)
	var high := Vector3(reach, reach + lift, reach)
	var size := high - low
	var centre := (low + high) * 0.5
	var box := BoxMesh.new()
	box.size = size
	_material = ShaderMaterial.new()
	_material.shader = VOLUME_SHADER
	_material.render_priority = 1
	_material.set_shader_parameter("noise", noise)
	_material.set_shader_parameter("box_size", size)
	_material.set_shader_parameter("centre_local", -centre)
	_material.set_shader_parameter("world_offset", Vector3(randf(), randf(), randf()) * 10.0)
	_material.set_shader_parameter("radius", radius)
	_material.set_shader_parameter("front_seconds", front_seconds)
	_material.set_shader_parameter("hold_seconds", hold_seconds)
	_material.set_shader_parameter("burnout_seconds", burnout_seconds)
	_material.set_shader_parameter("lift", lift)
	box.material = _material
	mesh = box
	position += centre
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# On the units' layer, which the burning ground's decal leaves out.
	layers = 1 << (Unit.RENDER_LAYER - 1)
	_process(0.0)


func _process(delta: float) -> void:
	_age += delta
	_material.set_shader_parameter("age", _age)
	_material.set_shader_parameter("strength", clampf((_life - _age) / 0.25, 0.0, 1.0))
	if _age >= _life:
		visible = false
		set_process(false)

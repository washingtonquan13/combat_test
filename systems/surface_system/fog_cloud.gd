extends Node3D
## The Fog Cloud visual. Expiry calls dissipate() instead of freeing it:
## the cloud spreads a little, lifts, and thins away from its edges in,
## the way real fog burns off, then frees itself. Sight is already clear
## by then; this is only the look. The colors are per scene, and every
## GPUParticles3D child gets them and the dissipate, so Darkness is this
## cloud inked, plus a layer of tendrils (darkness_tendril.gdshader).

@export var lit_color: Color = Color(0.86, 0.88, 0.9)
@export var shade_color: Color = Color(0.52, 0.56, 0.62)
@export var opacity: float = 0.6
@export var seconds: float = 3.5
@export var spread: float = 1.35
@export var lift: float = 0.6

var _layers: Array[GPUParticles3D] = []


func _ready() -> void:
	_layers.assign(find_children("*", "GPUParticles3D", false))
	for layer in _layers:
		layer.set_instance_shader_parameter("lit_color", lit_color)
		layer.set_instance_shader_parameter("shade_color", shade_color)
		layer.set_instance_shader_parameter("opacity", opacity)


## The puffs keep living (no emitting = false): their own lifetime fades
## would run on a clock of their own and pop puffs out mid-drift.
func dissipate() -> void:
	var tween := create_tween()
	tween.tween_method(_set_progress.bind(scale, position.y), 0.0, 1.0, seconds)
	tween.tween_callback(queue_free)


## Drift decelerates (fast at first, like a gust lifting it) while the
## shader thins at the same rate, so nothing sits still waiting.
func _set_progress(t: float, start_scale: Vector3, start_y: float) -> void:
	var drift: float = 1.0 - (1.0 - t) * (1.0 - t)
	scale = start_scale * lerpf(1.0, spread, drift)
	position.y = start_y + lift * start_scale.y * drift
	for layer in _layers:
		layer.set_instance_shader_parameter("dissipate", t)

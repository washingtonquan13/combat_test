extends Node3D
## The Fog Cloud visual. Expiry calls dissipate() instead of freeing it:
## the cloud spreads a little, lifts, and thins away from its edges in,
## the way real fog burns off, then frees itself. Sight is already clear
## by then; this is only the look.

@export var seconds: float = 3.0
@export var spread: float = 1.35
@export var lift: float = 0.6

@onready var _puffs: GPUParticles3D = $Puffs


func dissipate() -> void:
	_puffs.emitting = false
	var tween := create_tween().set_parallel()
	tween.tween_method(_set_dissipate, 0.0, 1.0, seconds).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "scale", scale * spread, seconds).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	tween.tween_property(self, "position:y", position.y + lift * scale.y, seconds).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	tween.chain().tween_callback(queue_free)


func _set_dissipate(amount: float) -> void:
	_puffs.set_instance_shader_parameter("dissipate", amount)

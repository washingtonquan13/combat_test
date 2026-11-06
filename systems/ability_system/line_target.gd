class_name LineTarget
extends RefCounted
## The target of a LineTargeting ability: a line on the ground from one
## click to the next (Wall of Fire). Ends are ground points.

var from: Vector3
var to: Vector3


func _init(p_from: Vector3, p_to: Vector3) -> void:
	from = p_from
	to = p_to


## Where the caster faces and the cast effects play: the line's middle.
func centre() -> Vector3:
	return from.lerp(to, 0.5)

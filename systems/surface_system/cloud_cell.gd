class_name CloudCell
extends RefCounted
## One CloudGrid cube filled by a cloud. Ages on its own, so a cloud
## topped up by a second cast runs out unevenly, oldest part first.

var surface: Surface
var key: Vector3i
## Rounds left; -1 never runs out.
var rounds: int
var patch: CloudPatch


func _init(p_surface: Surface, p_key: Vector3i, p_rounds: int) -> void:
	surface = p_surface
	key = p_key
	rounds = p_rounds


func centre() -> Vector3:
	return CloudGrid.centre_of(key)

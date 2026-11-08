class_name CloudCell
extends RefCounted
## One CloudGrid cube filled by a cloud. Ages on its own, so a cloud
## topped up by a second cast runs out unevenly, oldest part first.

var surface: Surface
var key: Vector3i
## Rounds left; -1 never runs out.
var rounds: int
## The patch this cell belongs to. Held weakly: the patch lists its
## cells, and a strong link back made each pair keep the other alive
## after the grid let go - surface, visual resources and all.
var patch: CloudPatch:
	get:
		return _patch.get_ref() if _patch else null
	set(value):
		_patch = weakref(value) if value else null
var _patch: WeakRef


func _init(p_surface: Surface, p_key: Vector3i, p_rounds: int) -> void:
	surface = p_surface
	key = p_key
	rounds = p_rounds


func centre() -> Vector3:
	return CloudGrid.centre_of(key)

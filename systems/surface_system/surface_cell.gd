class_name SurfaceCell
extends RefCounted
## One SurfaceGrid square covered by a surface. Ages on its own, so a
## patch topped up by a second cast runs out unevenly, oldest part first.

var surface: Surface
var key: Vector2i
## The floor's height here.
var y: float
## Rounds left; -1 never runs out.
var rounds: int
var patch: SurfacePatch


func _init(p_surface: Surface, p_key: Vector2i, p_y: float, p_rounds: int) -> void:
	surface = p_surface
	key = p_key
	y = p_y
	rounds = p_rounds


func centre() -> Vector3:
	return SurfaceGrid.centre_of(key, y)

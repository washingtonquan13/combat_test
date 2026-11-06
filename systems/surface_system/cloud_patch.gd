class_name CloudPatch
extends RefCounted
## The cubes one cast filled and still holds, drawn by one visual. Only a
## drawing group: cubes a later cast of the same cloud tops up stay with
## the visual already showing them, so overlapping casts read as one
## cloud without any puff popping. Every rule reads the cubes themselves.

var surface: Surface
var cells: Array[CloudCell] = []
## A fog_cloud.gd visual, shown the cubes through show_cubes()/recede_cubes().
var visual: Node3D
var context: WorldContext


func _init(p_surface: Surface, p_context: WorldContext) -> void:
	surface = p_surface
	context = p_context


func centroid(of: Array[CloudCell]) -> Vector3:
	var sum := Vector3.ZERO
	for cell in of:
		sum += cell.centre()
	return sum / maxf(of.size(), 1.0)

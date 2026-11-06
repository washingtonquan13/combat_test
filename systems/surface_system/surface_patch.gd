class_name SurfacePatch
extends RefCounted
## Cells of one surface that touch, drawn as one film: what two
## overlapping Grease casts merge into. Only a drawing group — every rule
## (status, cost, aging) reads the cells themselves.

var surface: Surface
var cells: Array[SurfaceCell] = []
## A DecalSurface, shown the cells through show_cells()/recede_cells().
var visual: Node3D
var context: WorldContext


func _init(p_surface: Surface, p_context: WorldContext) -> void:
	surface = p_surface
	context = p_context


func centroid(of: Array[SurfaceCell]) -> Vector3:
	var sum := Vector3.ZERO
	for cell in of:
		sum += cell.centre()
	return sum / maxf(of.size(), 1.0)

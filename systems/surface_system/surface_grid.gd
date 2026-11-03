class_name SurfaceGrid
extends RefCounted
## One world's ground surfaces, BG3's way: the floor is split into
## CELL-sized squares and each square holds at most one surface per floor
## — Grease OR Fire, never both. A cast fills cells (see SurfaceManager.
## spill), a later cast of another kind overwrites them, and cells of the
## same kind that touch are one SurfacePatch, drawn as one film. Clouds
## (Fog, Darkness) are not cells: they stay ActiveSurface spheres.
##
## Sparse: only covered cells exist. A column can hold several floors (a
## deck over a street), told apart by height — two cells closer than
## SAME_FLOOR in y are the same cell.

const CELL: float = 0.5
const SAME_FLOOR: float = 1.0
const NEIGHBOURS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## Vector2i -> Array of SurfaceCell, one per floor in that column.
var cells: Dictionary = {}
var patches: Array[SurfacePatch] = []


static func key_of(point: Vector3) -> Vector2i:
	return Vector2i(floori(point.x / CELL), floori(point.z / CELL))


static func centre_of(key: Vector2i, y: float) -> Vector3:
	return Vector3((key.x + 0.5) * CELL, y, (key.y + 0.5) * CELL)


func cell_at(key: Vector2i, y: float) -> SurfaceCell:
	for cell: SurfaceCell in cells.get(key, []):
		if absf(cell.y - y) < SAME_FLOOR:
			return cell
	return null


## The cell under a point on the floor, or null.
func cell_under(point: Vector3) -> SurfaceCell:
	return cell_at(key_of(point), point.y)


func add(cell: SurfaceCell) -> void:
	if not cells.has(cell.key):
		cells[cell.key] = []
	cells[cell.key].append(cell)


func remove(cell: SurfaceCell) -> void:
	var column: Array = cells.get(cell.key, [])
	column.erase(cell)
	if column.is_empty():
		cells.erase(cell.key)


func is_empty() -> bool:
	return cells.is_empty()


func clear() -> void:
	cells.clear()
	patches.clear()

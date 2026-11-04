class_name CloudGrid
extends RefCounted
## One world's clouds (Fog, Darkness), the 3D counterpart of SurfaceGrid:
## the air is split into CELL-sized cubes and each cube holds at most one
## cloud — Fog OR Darkness, never both. A cast fills the cubes it can
## reach (see SurfaceManager._fill), so walls, floors and ceilings stop
## it; a later cast of another kind overwrites cubes, one of the same kind
## tops them up. Every rule (sight, status, cost, ageing) reads the cubes.
##
## Sparse: only covered cubes exist.

## The same 0.25 m the navigation grid and the surface grid use.
const CELL: float = 0.25
const NEIGHBOURS: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
		Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

var cells: Dictionary[Vector3i, CloudCell] = {}
var patches: Array[CloudPatch] = []


static func key_of(point: Vector3) -> Vector3i:
	return Vector3i(floori(point.x / CELL), floori(point.y / CELL), floori(point.z / CELL))


static func centre_of(key: Vector3i) -> Vector3:
	return (Vector3(key) + Vector3.ONE * 0.5) * CELL


func cell_at(point: Vector3) -> CloudCell:
	return cells.get(key_of(point))


func add(cell: CloudCell) -> void:
	cells[cell.key] = cell


func remove(cell: CloudCell) -> void:
	if cells.get(cell.key) == cell:
		cells.erase(cell.key)


func is_empty() -> bool:
	return cells.is_empty()


func clear() -> void:
	cells.clear()
	patches.clear()


## The cubes a segment passes through, from `from` to `to` (a 3D DDA, so
## none is skipped however thin the slice it clips).
func cells_along(from: Vector3, to: Vector3) -> Array[CloudCell]:
	var found: Array[CloudCell] = []
	if cells.is_empty():
		return found
	var key: Vector3i = key_of(from)
	var last: Vector3i = key_of(to)
	var delta: Vector3 = to - from
	var step := Vector3i.ZERO
	var t_max := Vector3.ZERO
	var t_delta := Vector3.ZERO
	for axis in 3:
		if is_zero_approx(delta[axis]):
			t_max[axis] = INF
			t_delta[axis] = INF
			continue
		step[axis] = 1 if delta[axis] > 0.0 else -1
		var boundary: float = (key[axis] + (1 if delta[axis] > 0.0 else 0)) * CELL
		t_max[axis] = (boundary - from[axis]) / delta[axis]
		t_delta[axis] = CELL / absf(delta[axis])
	while true:
		var cell: CloudCell = cells.get(key)
		if cell:
			found.append(cell)
		if key == last:
			break
		var axis: int = t_max.min_axis_index()
		if t_max[axis] > 1.0:
			break
		key[axis] += step[axis]
		t_max[axis] += t_delta[axis]
	return found


## The cubes touching an upright capsule: a segment from `low` to `high`,
## `radius` thick (a unit's body, feet to eyes).
func cells_touching(low: Vector3, high: Vector3, radius: float) -> Array[CloudCell]:
	var found: Array[CloudCell] = []
	if cells.is_empty():
		return found
	var reach := Vector3.ONE * radius
	var from: Vector3i = key_of(low.min(high) - reach)
	var to: Vector3i = key_of(low.max(high) + reach)
	var samples: int = maxi(1, ceili(low.distance_to(high) / 0.25))
	for x in range(from.x, to.x + 1):
		for y in range(from.y, to.y + 1):
			for z in range(from.z, to.z + 1):
				var cell: CloudCell = cells.get(Vector3i(x, y, z))
				if cell == null:
					continue
				var box_low := Vector3(x, y, z) * CELL
				var box_high := box_low + Vector3.ONE * CELL
				for i in samples + 1:
					var point: Vector3 = low.lerp(high, float(i) / samples)
					if point.clamp(box_low, box_high).distance_to(point) <= radius:
						found.append(cell)
						break
	return found

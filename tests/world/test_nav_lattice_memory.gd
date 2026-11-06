extends AiTestCase
## The navigation lattice is fixed in the world, and a short route only
## pays for the chunks it walks.
##
## The floor sits well away from the origin on purpose. With the origin
## taken straight from the geometry's minimum, the world origin falls at
## some arbitrary cell; anchored to whole 8 m chunks, it falls on a chunk
## corner, so its cell is a multiple of 32 on every axis. And the floor is
## big, so search scratch sized to the whole volume (21 bytes a cell) is
## far more than a few chunks' pages and bakes.

const FLOOR_CENTRE := Vector3(101.3, 3.7, -57.9)
const FLOOR_SIZE := Vector3(120.0, 1.0, 120.0)
const CHUNK_CELLS := 32
## What the grid adds around the geometry (BOUNDS_MARGIN) and the flight
## ceiling it always reaches (FLIGHT_CEILING_HEIGHT + margin).
const MARGIN := 2.0
const CEILING := 14.0


func run() -> void:
	for child in _root.get_children():
		if child is StaticBody3D:
			child.free()
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = FLOOR_SIZE
	shape.shape = box
	body.add_child(shape)
	_root.add_child(body)
	body.global_position = FLOOR_CENTRE

	var top: float = FLOOR_CENTRE.y + FLOOR_SIZE.y * 0.5
	var from := Vector3(FLOOR_CENTRE.x - 1.5, top + 0.05, FLOOR_CENTRE.z)
	var to := Vector3(FLOOR_CENTRE.x + 1.5, top + 0.05, FLOOR_CENTRE.z)
	var walker: Unit = spawn_brute(from.x, from.z)
	walker.global_position = from

	NavigationGrid.invalidate()
	for i in 4:
		await get_tree().physics_frame

	var path: PackedVector3Array = NavigationGrid.find_path(get_tree(), from, to, walker, false)
	var origin_cell: Vector3i = NavigationGrid.world_to_cell(Vector3.ZERO)
	var anchored: bool = origin_cell.x % CHUNK_CELLS == 0 \
		and origin_cell.y % CHUNK_CELLS == 0 and origin_cell.z % CHUNK_CELLS == 0

	# The fewest cells the bounds can hold; snapping only adds to it.
	var cell: float = NavigationGrid.CELL_SIZE
	var lo_y: float = FLOOR_CENTRE.y - FLOOR_SIZE.y * 0.5 - MARGIN
	var cells: float = ceilf((FLOOR_SIZE.x + 2.0 * MARGIN) / cell) \
		* ceilf((maxf(top + MARGIN, CEILING) - lo_y) / cell) \
		* ceilf((FLOOR_SIZE.z + 2.0 * MARGIN) / cell)
	var bytes: int = NavigationGrid.debug_memory_bytes()

	check("an off-origin floor routes, on a world-anchored lattice, for a fraction of a volume-sized scratch",
		path.size() > 0 and anchored and bytes < cells * 21.0 / 4.0,
		"path %d points, origin cell %s, %d bytes vs volume scratch %d" % [path.size(), origin_cell, bytes, int(cells * 21.0)])

	NavigationGrid.invalidate()

class_name NavigationGrid
extends RefCounted
## Replaces the earlier NavigationServer3D/Recast-navmesh approach entirely
## (see git history around "Final navigation change before abandon" and
## HANDOFF.md) — a hand-authored empty air layer that ignored obstacles,
## then a real-geometry-scanned bake that fixed that but introduced a
## region-overlap crash, then a query-snap/height-mismatch bug, then
## finally a whole-map navigation outage (the air layer's invisible
## bake-source plate polluting the GROUND layer's own geometry scan, since
## both bakes shared the same scan root). Every one of those was the
## navmesh bake/sync pipeline itself being fought, not this game's actual
## movement rules.
##
## Ground and flight share ONE 3D grid instead of two NavigationMaps that
## need reconciling — "grounded" vs "flying" is a different traversal RULE
## over the same grid (a grounded search only steps onto a cell with solid
## support directly beneath it; a flying search doesn't care, only that
## it's within the flight altitude envelope), not a second data structure.
## That's what makes vertical and horizontal movement actually seamless: a
## climbing/descending flight path is just an ordinary 3D route through
## this one grid, not a 2D shape baked at a fixed height and reinterpreted.
##
## Two grids, two different lifetimes:
##  - STATIC solid grid (_solid): baked ONCE, lazily, from real level
##    geometry (every StaticBody3D's CollisionShape3D under the current
##    scene) — which cells are physically inside solid geometry. Level
##    geometry never moves mid-match, so there is no per-turn re-bake, no
##    "needs a real physics frame before it's queryable" sync gap, no
##    NavigationServer3D lifecycle to manage at all.
##  - DYNAMIC occupancy overlay (_occupied): which cells are currently
##    filled by a living unit's footprint. Rebuilt every turn (see
##    update_occupancy) by writing directly into a Dictionary this class
##    owns — synchronous, no bake, safe to call and immediately query in
##    the same frame.
##
## CELL_SIZE is deliberately much smaller than a unit's own footprint — a
## unit occupies a small disc of cells, not one cell each ("atomic" cells,
## per the design discussion this followed) — which is what keeps this
## closer to the old continuous/free-altitude feel than a traditional
## coarse tactics grid, while staying a plain array/Dictionary a script can
## read and write directly instead of an opaque server-side bake.

const CELL_SIZE: float = 0.25
const FLIGHT_MIN_ALTITUDE := 1.0
const FLIGHT_CEILING_HEIGHT := 12.0
## Extra world-space margin added around the union of all static geometry's
## AABBs when sizing the grid — lets a unit path a little past the tightest
## bounding box of the level's own geometry instead of the grid itself
## becoming an invisible hard wall exactly at the geometry's edge.
const BOUNDS_MARGIN: float = 2.0
## Circuit breaker on A* node expansions, not a normal limit — ordinary
## moves in a modest arena resolve in the hundreds. Exists so a genuinely
## unreachable destination (or a much larger future map) fails fast with
## "no path" instead of exhaustively flooding the whole grid.
const MAX_EXPANSIONS: int = 30000

static var _bounds_origin: Vector3
static var _grid_size: Vector3i
static var _solid: PackedByteArray
static var _baked: bool = false
## Vector3i cell -> Unit currently filling it. Cleared and rebuilt whole
## each update_occupancy call rather than incrementally patched — cheap at
## this scale (one pass over the "units" group), and immune to drift from
## a missed removal the way incremental bookkeeping could accumulate.
static var _occupied: Dictionary = {}

static var _neighbor_offsets: Array[Vector3i] = []


## --- Setup / bake -----------------------------------------------------

static func ensure_baked(tree: SceneTree) -> void:
	if _baked:
		return
	_bake_static(tree)
	_baked = true


## Scans every StaticBody3D's CollisionShape3D under the current scene
## (units are CharacterBody3D, never picked up here, same as the old
## navmesh scan never picking them up) and rasterizes each into the solid
## grid. BoxShape3D — everything this project's level geometry actually
## uses — is rasterized exactly (an oriented-box test per candidate cell,
## bounded to that shape's own AABB, not the whole grid). Any other shape
## type falls back to its axis-aligned bounding box via
## Shape3D.get_debug_mesh() — a coarser approximation (a sphere becomes a
## solid cube), acceptable since nothing in this project currently uses a
## non-box collider for level geometry; worth revisiting only if that
## changes.
static func _bake_static(tree: SceneTree) -> void:
	var shapes: Array[CollisionShape3D] = []
	_collect_static_shapes(tree.current_scene, shapes)

	var world_min: Vector3 = Vector3.ZERO
	var world_max: Vector3 = Vector3.ZERO
	var have_bounds: bool = false
	for collision_shape in shapes:
		var aabb: AABB = _shape_global_aabb(collision_shape)
		if not have_bounds:
			world_min = aabb.position
			world_max = aabb.position + aabb.size
			have_bounds = true
		else:
			world_min = world_min.min(aabb.position)
			world_max = world_max.max(aabb.position + aabb.size)

	if not have_bounds:
		# No static geometry at all — degenerate, but a minimal placeholder
		# volume keeps every query well-defined ("no path") instead of a
		# division/allocation by zero elsewhere.
		world_min = Vector3(-1.0, -1.0, -1.0)
		world_max = Vector3(1.0, 1.0, 1.0)

	world_min -= Vector3.ONE * BOUNDS_MARGIN
	world_max += Vector3.ONE * BOUNDS_MARGIN
	world_max.y = max(world_max.y, FLIGHT_CEILING_HEIGHT + BOUNDS_MARGIN)

	_bounds_origin = world_min
	var extent: Vector3 = world_max - world_min
	_grid_size = Vector3i(ceili(extent.x / CELL_SIZE), ceili(extent.y / CELL_SIZE), ceili(extent.z / CELL_SIZE))
	_solid = PackedByteArray()
	_solid.resize(_grid_size.x * _grid_size.y * _grid_size.z)

	for collision_shape in shapes:
		_rasterize_shape(collision_shape)


static func _collect_static_shapes(node: Node, out: Array[CollisionShape3D]) -> void:
	if node is StaticBody3D:
		for child in node.get_children():
			if child is CollisionShape3D and child.shape:
				out.append(child)
	for child in node.get_children():
		_collect_static_shapes(child, out)


static func _shape_global_aabb(collision_shape: CollisionShape3D) -> AABB:
	var shape: Shape3D = collision_shape.shape
	var local_aabb: AABB
	if shape is BoxShape3D:
		local_aabb = AABB(-shape.size * 0.5, shape.size)
	else:
		local_aabb = shape.get_debug_mesh().get_aabb()
	return _transform_aabb(collision_shape.global_transform, local_aabb)


static func _transform_aabb(t: Transform3D, aabb: AABB) -> AABB:
	var result := AABB(t * aabb.position, Vector3.ZERO)
	for i in 8:
		var corner: Vector3 = aabb.position + Vector3(
			aabb.size.x if i & 1 else 0.0,
			aabb.size.y if i & 2 else 0.0,
			aabb.size.z if i & 4 else 0.0
		)
		result = result.expand(t * corner)
	return result


static func _rasterize_shape(collision_shape: CollisionShape3D) -> void:
	var shape: Shape3D = collision_shape.shape
	var global_transform: Transform3D = collision_shape.global_transform
	var aabb: AABB = _shape_global_aabb(collision_shape)

	var min_cell: Vector3i = world_to_cell(aabb.position)
	var max_cell: Vector3i = world_to_cell(aabb.position + aabb.size)
	var is_box: bool = shape is BoxShape3D
	var half_size: Vector3 = shape.size * 0.5 if is_box else Vector3.ZERO
	var inverse: Transform3D = global_transform.affine_inverse()

	for x in range(max(min_cell.x, 0), min(max_cell.x + 1, _grid_size.x)):
		for y in range(max(min_cell.y, 0), min(max_cell.y + 1, _grid_size.y)):
			for z in range(max(min_cell.z, 0), min(max_cell.z + 1, _grid_size.z)):
				var cell := Vector3i(x, y, z)
				var world_point: Vector3 = cell_center(cell)
				var inside: bool
				if is_box:
					var local: Vector3 = inverse * world_point
					inside = absf(local.x) <= half_size.x and absf(local.y) <= half_size.y and absf(local.z) <= half_size.z
				else:
					inside = aabb.has_point(world_point)
				if inside:
					_solid[_cell_index(cell)] = 1


## --- Cell <-> world -----------------------------------------------------

static func world_to_cell(pos: Vector3) -> Vector3i:
	var local: Vector3 = pos - _bounds_origin
	return Vector3i(floori(local.x / CELL_SIZE), floori(local.y / CELL_SIZE), floori(local.z / CELL_SIZE))


static func cell_center(cell: Vector3i) -> Vector3:
	return _bounds_origin + Vector3(cell) * CELL_SIZE + Vector3.ONE * (CELL_SIZE * 0.5)


static func _cell_index(cell: Vector3i) -> int:
	return cell.x + cell.y * _grid_size.x + cell.z * _grid_size.x * _grid_size.y


static func _in_bounds(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.z >= 0 and cell.x < _grid_size.x and cell.y < _grid_size.y and cell.z < _grid_size.z


static func is_solid(cell: Vector3i) -> bool:
	if not _in_bounds(cell):
		return true
	return _solid[_cell_index(cell)] != 0


static func has_support(cell: Vector3i) -> bool:
	return is_solid(cell + Vector3i(0, -1, 0))


## --- Dynamic occupancy --------------------------------------------------

## Rebuilds which cells are currently filled by a living unit's footprint —
## called once per turn-start/turn-end/free-roam move order, the same
## cadence the old per-turn navmesh rebake used (see call sites in
## combat_manager.gd/ground_click_target.gd), never continuously. Unlike
## the old bake this is a synchronous Dictionary write with no server-side
## sync gap, so there is no coalescing/deferred-frame machinery needed
## here — every call site that used to call NavigationCarving.
## request_rebake() to avoid one full geometry bake per event now just
## calls this directly and cheaply, event by event.
##
## `movers` are excluded from occupying their OWN footprint — a unit can't
## have its own standing position block a path query starting from itself.
##
## Also marks any corpse in the "blocking_corpses" group (see
## Unit._handle_death/corpse_blocks_movement) as occupied — a dead unit
## leaves the "units" group immediately on death, so without this a corpse
## that's meant to keep blocking movement (terrain-like debris) would stop
## being avoided by PLANNING the instant it died, even though it still
## physically collides via move_and_slide.
static func update_occupancy(tree: SceneTree, movers: Array) -> void:
	ensure_baked(tree)
	_occupied.clear()
	for node in tree.get_nodes_in_group("units"):
		var unit := node as Unit
		if not unit or not unit.is_alive():
			continue
		if unit in movers:
			continue
		for offset in _disc_offsets(unit.radius + unit.avoidance_margin):
			_occupied[world_to_cell(unit.global_position) + offset] = unit
	for node in tree.get_nodes_in_group("blocking_corpses"):
		var corpse := node as Unit
		if not corpse:
			continue
		for offset in _disc_offsets(corpse.radius + corpse.avoidance_margin):
			_occupied[world_to_cell(corpse.global_position) + offset] = corpse


## Flat horizontal disc of cell offsets (Y always 0) around a footprint's
## own center — Y ignored deliberately, same reasoning the old carving
## polygon used: a unit's footprint is a flat ring around its own origin,
## not a stack extending up/down.
static func _disc_offsets(clearance: float) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var reach: int = ceili(clearance / CELL_SIZE)
	for dx in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			if Vector2(dx * CELL_SIZE, dz * CELL_SIZE).length() > clearance:
				continue
			result.append(Vector3i(dx, 0, dz))
	return result


static func _is_free(cell: Vector3i, offsets: Array[Vector3i], self_unit: Unit) -> bool:
	for offset in offsets:
		var c: Vector3i = cell + offset
		if is_solid(c):
			return false
		var occupant = _occupied.get(c)
		if occupant and occupant != self_unit:
			return false
	return true


## Whether `cell` is a legal place for a mover to actually be, under
## `flying`'s traversal rule — see this file's header. Grounded requires
## solid support directly beneath; flying requires being within the flight
## altitude envelope instead (no physical geometry above/below cares).
static func _is_valid_cell(cell: Vector3i, offsets: Array[Vector3i], flying: bool, self_unit: Unit = null) -> bool:
	if not _in_bounds(cell):
		return false
	if flying:
		var world_y: float = cell_center(cell).y
		if world_y < FLIGHT_MIN_ALTITUDE or world_y > FLIGHT_CEILING_HEIGHT:
			return false
	elif not has_support(cell):
		return false
	return _is_free(cell, offsets, self_unit)


## --- Nearest-valid-point utility ----------------------------------------

## Finds the nearest legal cell to `point` (see _is_valid_cell) within a
## growing cube search, shell by shell. Replaces every former
## NavigationServer3D.map_get_closest_point() call site (Unit.land() was
## already exempt — it uses a physics raycast, for the same
## no-navigation_layers-parameter reason that used to make
## map_get_closest_point unsafe once ground and air shared a map; that
## reasoning is moot now, there's only one grid, but the raycast approach
## stays since it's still correct and unrelated to this rework).
## `exclude_unit` lets a unit's own current footprint not block a search
## for its own nearby destination (KnockbackEffect searching near its
## target's current position, notably).
static func nearest_valid_point(tree: SceneTree, point: Vector3, clearance: float, flying: bool, exclude_unit: Unit = null, max_radius_cells: int = 12) -> Dictionary:
	ensure_baked(tree)
	var offsets: Array[Vector3i] = _disc_offsets(clearance)
	var snap: Dictionary = _find_nearest_free_cell(world_to_cell(point), offsets, flying, exclude_unit, max_radius_cells)
	if not snap.found:
		return {"found": false, "point": point}
	return {"found": true, "point": cell_center(snap.cell)}


static func _find_nearest_free_cell(cell: Vector3i, offsets: Array[Vector3i], flying: bool, self_unit: Unit, max_radius: int) -> Dictionary:
	if _is_valid_cell(cell, offsets, flying, self_unit):
		return {"found": true, "cell": cell}
	for radius in range(1, max_radius + 1):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				for dz in range(-radius, radius + 1):
					if maxi(absi(dx), maxi(absi(dy), absi(dz))) != radius:
						continue  # only this shell — smaller radii already tried
					var candidate: Vector3i = cell + Vector3i(dx, dy, dz)
					if _is_valid_cell(candidate, offsets, flying, self_unit):
						return {"found": true, "cell": candidate}
	return {"found": false, "cell": cell}


## --- Pathfinding ----------------------------------------------------------

## Finds a route from `start` to `destination` over the shared grid for
## `unit`, under the grounded or flying traversal rule (see this file's
## header). Returns an empty array if no path exists — mirrors
## NavigationServer3D.map_get_path's "empty means no path" contract so
## call sites keep their existing `waypoints.size() < 2` check unchanged.
##
## Unlike the old air-layer approach, a flying query needs no separate
## bake-at-one-height-then-reinterpret-Y step: this is a genuine 3D A*
## between the unit's real current position and the destination (XZ from
## wherever was clicked, Y from Unit.flight_target_altitude), so the
## returned path already climbs/descends realistically around real
## obstacles at each height along the way — remap_flight_altitude and
## everything that fed it no longer exist because there's nothing left for
## them to do.
static func find_path(tree: SceneTree, start: Vector3, destination: Vector3, unit: Unit, flying: bool) -> PackedVector3Array:
	ensure_baked(tree)

	var clearance: float = unit.radius + unit.avoidance_margin
	var offsets: Array[Vector3i] = _disc_offsets(clearance)
	_ensure_neighbor_offsets()

	var start_cell: Vector3i = world_to_cell(start)
	if not _in_bounds(start_cell):
		return PackedVector3Array()

	var goal_snap: Dictionary = _find_nearest_free_cell(world_to_cell(destination), offsets, flying, unit, 12)
	if not goal_snap.found:
		return PackedVector3Array()
	var goal_cell: Vector3i = goal_snap.cell

	if start_cell == goal_cell:
		return PackedVector3Array([start, cell_center(goal_cell)])

	var raw: PackedVector3Array = _a_star(start, start_cell, goal_cell, offsets, flying, unit)
	if raw.size() < 2:
		return raw
	return _smooth_path(raw, offsets, flying, unit)


static func _ensure_neighbor_offsets() -> void:
	if not _neighbor_offsets.is_empty():
		return
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				_neighbor_offsets.append(Vector3i(dx, dy, dz))


static func _heuristic(a: Vector3i, b: Vector3i) -> float:
	return Vector3(a - b).length() * CELL_SIZE


## 26-connected A* (includes vertical and 3D-diagonal steps — what keeps a
## flying path from being forced into an axis-aligned staircase). The
## start cell's own validity is never checked (a unit is wherever it
## already is, even if that's mid-air between cells); only cells being
## stepped INTO are gated by _is_valid_cell.
static func _a_star(start: Vector3, start_cell: Vector3i, goal_cell: Vector3i, offsets: Array[Vector3i], flying: bool, unit: Unit) -> PackedVector3Array:
	var came_from: Dictionary = {}
	var g_score: Dictionary = {start_cell: 0.0}
	var closed: Dictionary = {}
	var open_heap := _MinHeap.new()
	open_heap.push(start_cell, _heuristic(start_cell, goal_cell))
	var expansions: int = 0

	while not open_heap.is_empty():
		var current: Vector3i = open_heap.pop()
		if closed.has(current):
			continue
		closed[current] = true
		if current == goal_cell:
			return _reconstruct_path(came_from, start, start_cell, goal_cell)

		expansions += 1
		if expansions > MAX_EXPANSIONS:
			break

		for offset in _neighbor_offsets:
			var neighbor: Vector3i = current + offset
			if closed.has(neighbor):
				continue
			if not _is_valid_cell(neighbor, offsets, flying, unit):
				continue
			var step_cost: float = Vector3(offset).length() * CELL_SIZE
			var tentative: float = g_score[current] + step_cost
			if tentative < g_score.get(neighbor, INF):
				g_score[neighbor] = tentative
				came_from[neighbor] = current
				open_heap.push(neighbor, tentative + _heuristic(neighbor, goal_cell))

	return PackedVector3Array()


static func _reconstruct_path(came_from: Dictionary, start: Vector3, start_cell: Vector3i, goal_cell: Vector3i) -> PackedVector3Array:
	var cells: Array[Vector3i] = [goal_cell]
	var cur: Vector3i = goal_cell
	while cur != start_cell:
		cur = came_from[cur]
		cells.append(cur)
	cells.reverse()

	var result: PackedVector3Array = PackedVector3Array([start])
	for i in range(1, cells.size()):
		result.append(cell_center(cells[i]))
	return result


## Removes redundant intermediate waypoints wherever a straight line
## between two non-adjacent points stays entirely inside valid cells —
## turns the grid's inherently stairstepped raw output into a small number
## of smooth line segments. RoutePlanner.plan already subdivides each
## remaining segment into short steps for terrain-cost sampling, so this
## only removes redundant path VERTICES, not sampling granularity.
static func _smooth_path(path: PackedVector3Array, offsets: Array[Vector3i], flying: bool, unit: Unit) -> PackedVector3Array:
	if path.size() <= 2:
		return path
	var result: PackedVector3Array = PackedVector3Array([path[0]])
	var anchor: int = 0
	var probe: int = 2
	while probe < path.size():
		if _line_clear(path[anchor], path[probe], offsets, flying, unit):
			probe += 1
		else:
			result.append(path[probe - 1])
			anchor = probe - 1
			probe += 1
	result.append(path[path.size() - 1])
	return result


static func _line_clear(a: Vector3, b: Vector3, offsets: Array[Vector3i], flying: bool, unit: Unit) -> bool:
	var length: float = a.distance_to(b)
	var steps: int = max(1, ceili(length / CELL_SIZE))
	for i in range(1, steps):
		var t: float = float(i) / float(steps)
		if not _is_valid_cell(world_to_cell(a.lerp(b, t)), offsets, flying, unit):
			return false
	return true


## Minimal binary min-heap keyed by float priority — GDScript has no
## built-in priority queue. Lazy-deletion pattern (a cell can be pushed
## more than once at different priorities; the `closed` check in _a_star
## discards stale pops) rather than a decrease-key operation, which a
## plain array-backed heap can't do efficiently anyway.
class _MinHeap:
	var _items: Array = []  # each entry: [priority: float, cell: Vector3i]

	func is_empty() -> bool:
		return _items.is_empty()

	func push(cell: Vector3i, priority: float) -> void:
		_items.append([priority, cell])
		var i: int = _items.size() - 1
		while i > 0:
			var parent: int = (i - 1) / 2
			if _items[parent][0] <= _items[i][0]:
				break
			var tmp = _items[parent]
			_items[parent] = _items[i]
			_items[i] = tmp
			i = parent

	func pop() -> Vector3i:
		var top: Vector3i = _items[0][1]
		var last: int = _items.size() - 1
		_items[0] = _items[last]
		_items.remove_at(last)
		var i: int = 0
		while true:
			var left: int = i * 2 + 1
			var right: int = i * 2 + 2
			var smallest: int = i
			if left < _items.size() and _items[left][0] < _items[smallest][0]:
				smallest = left
			if right < _items.size() and _items[right][0] < _items[smallest][0]:
				smallest = right
			if smallest == i:
				break
			var tmp = _items[smallest]
			_items[smallest] = _items[i]
			_items[i] = tmp
			i = smallest
		return top

extends AiTestCase
## One navigation grid per world, proven by geometry that differs between
## them.
##
## This is the only assertion that can tell a per-world grid from a shared
## one. Every other property — paths are found, units block cells, bounds
## are sane — reads identically either way, because the game loads one
## world and a shared grid is CORRECT for one world. So the fixture is two
## live World3Ds at IDENTICAL coordinates with a wall in exactly one of
## them, and the question is whether the other world can walk through
## where that wall is.
##
## Identical coordinates are the point, not a convenience: every area in
## this project is authored around the origin, so two resident worlds
## genuinely do overlap in raw position. A grid that mixed them would not
## produce a subtly worse route, it would produce a route through the
## other level's walls.
##
## A mistake here is a segfault rather than a failed check — the grid
## holds raw CollisionShape3D pointers into world geometry. If this suite
## reports fewer checks than usual with no FAIL line, the run died
## mid-suite; compare the count, not the word PASSED.

const FLOOR_HALF: float = 20.0
const WEST := Vector3(-12.0, 0.0, 0.0)
const EAST := Vector3(12.0, 0.0, 0.0)
## Clear of world A's wall on purpose: a point inside it is unwalkable in A
## for reasons that have nothing to do with occupancy, which would make the
## occupancy check below pass without testing anything.
const SPOT_B := Vector3(8.0, 0.0, 14.0)

var _viewport_a: SubViewport
var _viewport_b: SubViewport
var _root_a: Node3D
var _root_b: Node3D
var _unit_a: Unit
var _unit_b: Unit


func run() -> void:
	await _build_two_worlds()
	if _root_a == null:
		check("SETUP: two worlds built", false, "viewport setup failed")
		return

	_geometry_does_not_leak_between_worlds()
	_occupancy_does_not_leak_between_worlds()
	_world_pure_queries_are_unaffected()
	await _registration_is_symmetric()

	_teardown_worlds()
	await _a_real_authored_area_still_bakes()


## Two SubViewports with own_world_3d, each holding a world root with a
## floor. Only world A gets a wall, and it spans further than the floor
## does, so in A there is no route from one side to the other at all —
## a binary outcome rather than a path-length comparison that a tolerance
## could paper over.
func _build_two_worlds() -> void:
	_viewport_a = _make_world_viewport()
	_viewport_b = _make_world_viewport()
	await get_tree().process_frame

	_root_a = _make_world_root(_viewport_a)
	_root_b = _make_world_root(_viewport_b)

	_add_box(_root_a, Vector3(0.0, 3.0, 0.0), Vector3(2.0, 6.0, FLOOR_HALF * 2.4))

	# Physics frames, not process frames: the shapes have to be live in
	# each world's physics space before anything scans them.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_unit_a = _spawn_in(_root_a, WEST)
	_unit_b = _spawn_in(_root_b, WEST)
	await get_tree().physics_frame

	# Each world announces itself; until one does, the grid behaves as the
	# single-world singleton it has always been.
	NavigationGrid.register_world(_root_a)
	NavigationGrid.register_world(_root_b)


func _make_world_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	_root.add_child(viewport)
	return viewport


func _make_world_root(viewport: SubViewport) -> Node3D:
	var root := Node3D.new()
	viewport.add_child(root)
	_add_box(root, Vector3(0.0, -0.5, 0.0), Vector3(FLOOR_HALF * 2.0, 1.0, FLOOR_HALF * 2.0))
	return root


func _add_box(parent: Node3D, position: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = position


func _spawn_in(root: Node3D, position: Vector3) -> Unit:
	var unit: Unit = load("res://unit.tscn").instantiate()
	root.add_child(unit)
	unit.faction = &"player"
	unit.strength = 12
	unit.dexterity = 12
	unit.maximum_hp = 20
	unit.current_hp = 20
	var abilities: Array[Ability] = [melee()]
	unit.abilities = abilities
	unit.global_position = position
	unit.reset_turn_actions()
	return unit


## THE CENTREPIECE. World A is walled in half; world B is open. Both are
## asked for the same route between the same two coordinates.
func _geometry_does_not_leak_between_worlds() -> void:
	check("setup: the two worlds really are separate World3Ds",
		_root_a.get_world_3d() != _root_b.get_world_3d())

	var path_b: PackedVector3Array = NavigationGrid.find_path(
		get_tree(), WEST, EAST, _unit_b, false)
	check("the OPEN world finds a route straight across",
		path_b.size() > 0, "empty path in the unwalled world")

	var path_a: PackedVector3Array = NavigationGrid.find_path(
		get_tree(), WEST, EAST, _unit_a, false)
	check("the WALLED world does not — its wall is real",
		path_a.size() == 0, "walked through a wall (%d points)" % path_a.size())

	# The other direction of the same claim. If the grid were shared, the
	# order of these two queries would decide the answer: whichever world
	# baked last would be the one both units path through. Asking B again
	# AFTER A has baked is what catches that.
	var path_b_again: PackedVector3Array = NavigationGrid.find_path(
		get_tree(), WEST, EAST, _unit_b, false)
	check("and the open world is still open after the walled one has baked",
		path_b_again.size() > 0, "the wall leaked from one world into the other")

	check("both worlds' routes agree with themselves on a re-ask",
		NavigationGrid.find_path(get_tree(), WEST, EAST, _unit_a, false).size() == 0)


## Units live in one global "units" group with no world in it, so the
## occupancy sweep sees every world's units at once. Both these units
## stand at the same coordinates, so a sweep that didn't filter would
## stamp two occupants into one grid.
func _occupancy_does_not_leak_between_worlds() -> void:
	_unit_a.global_position = EAST
	_unit_b.global_position = SPOT_B

	var clearance: float = _unit_a.radius + _unit_a.avoidance_margin

	# B stamped first, then A. exclude_unit is null in both, so each
	# query sees its OWN unit as a blocker and must not see the other's.
	NavigationGrid.update_occupancy(get_tree(), [], _root_b)
	var b_at_east: Dictionary = NavigationGrid.nearest_valid_point(
		get_tree(), EAST, clearance, false, null, 0, _root_b)
	check("one world leaves the cell the OTHER world's unit stands in walkable",
		b_at_east.found, "a foreign unit blocked a cell")

	NavigationGrid.update_occupancy(get_tree(), [], _root_a)
	var a_at_own: Dictionary = NavigationGrid.nearest_valid_point(
		get_tree(), EAST, clearance, false, null, 0, _root_a)
	check("but a world does see its OWN unit standing there",
		not a_at_own.found, "own-world occupancy went missing")

	var a_at_b_spot: Dictionary = NavigationGrid.nearest_valid_point(
		get_tree(), SPOT_B, clearance, false, null, 0, _root_a)
	check("and symmetrically from the other side",
		a_at_b_spot.found, "a foreign unit blocked a cell")

	# Excluding the occupant has to keep working per-world, since that is
	# how a moving unit ignores itself.
	var excluded: Dictionary = NavigationGrid.nearest_valid_point(
		get_tree(), EAST, clearance, false, _unit_a, 0, _root_a)
	check("exclude_unit still frees the excluded unit's own cell",
		excluded.found)


## CELL_SIZE and the flight limits are global game rules and must not have
## been dragged into the registry.
##
## world_to_cell is a different matter, and this suite corrected the plan
## for this pass on it: that plan listed world_to_cell among the "pure —
## no world at all" calls, and it is not. It subtracts bounds_origin,
## which is per-world, so two worlds of different extents number the same
## world point differently.
##
## Not a live bug, because both callers use it the only way it can be
## used: movement_indicator and seeking_indicator each take two cells
## back-to-back and compare them ("has the hovered cell changed"), with
## one world loaded throughout. The constraint is that a cell number is
## meaningless outside the world it was taken in — so a future caller that
## stores one across a world switch should fail here rather than in play.
func _world_pure_queries_are_unaffected() -> void:
	check("CELL_SIZE is a game rule, not per-world state",
		NavigationGrid.CELL_SIZE > 0.0)
	check("and so are the flight limits",
		NavigationGrid.FLIGHT_CEILING_HEIGHT > 0.0
			and NavigationGrid.FLIGHT_MIN_ALTITUDE > 0.0)

	NavigationGrid.find_path(get_tree(), WEST, EAST, _unit_a, false)
	var in_a: Vector3i = NavigationGrid.world_to_cell(SPOT_B)
	check("world_to_cell is stable while one world stays loaded",
		NavigationGrid.world_to_cell(SPOT_B) == in_a)

	NavigationGrid.find_path(get_tree(), WEST, EAST, _unit_b, false)
	check("but it is relative to the loaded world, not absolute — cells do "
			+ "not survive a world switch",
		NavigationGrid.world_to_cell(SPOT_B) != in_a,
		"both worlds happened to share bounds; the claim is untested, not false")


## Registration has to be reversible, because that is what makes a grid
## die with its world instead of outliving it holding pointers into freed
## geometry — the native crash invalidate() was written to paper over.
func _registration_is_symmetric() -> void:
	NavigationGrid.unregister_world(_root_a)

	var still_b: PackedVector3Array = NavigationGrid.find_path(
		get_tree(), WEST, EAST, _unit_b, false)
	check("unregistering one world leaves the other's queries working",
		still_b.size() > 0)

	# Re-registering starts that world from nothing rather than resurrecting
	# stale state, so it re-scans and finds its wall again.
	NavigationGrid.register_world(_root_a)
	await get_tree().physics_frame
	var re_a: PackedVector3Array = NavigationGrid.find_path(
		get_tree(), WEST, EAST, _unit_a, false)
	check("re-registering re-scans rather than resurrecting stale state",
		re_a.size() == 0, "the wall was forgotten (%d points)" % re_a.size())

	# A world nobody registered must fail safely. This is the path a bug
	# elsewhere would take, so it has to be a harmless no-op rather than a
	# query against some other world's grid.
	var orphan := Node3D.new()
	_viewport_b.add_child(orphan)
	NavigationGrid.unregister_world(orphan)
	check("unregistering a world that was never registered is harmless",
		NavigationGrid.find_path(get_tree(), WEST, EAST, _unit_b, false).size() > 0)
	orphan.queue_free()


func _teardown_worlds() -> void:
	NavigationGrid.unregister_world(_root_a)
	NavigationGrid.unregister_world(_root_b)

	for unit in [_unit_a, _unit_b]:
		if is_instance_valid(unit):
			if unit.is_in_group("units"):
				unit.remove_from_group("units")
			unit.get_parent().remove_child(unit)
			unit.queue_free()
	for viewport in [_viewport_a, _viewport_b]:
		if is_instance_valid(viewport):
			_root.remove_child(viewport)
			viewport.queue_free()

	# Nothing is registered now, so the grid is back to its single-world
	# self — and it is still holding whichever world it last scanned.
	NavigationGrid.invalidate()


## The live path, which two synthetic worlds cannot cover. In the game a
## world root is an AUTHORED AREA, and the geometry scan now starts there
## instead of at the whole current scene. If any area kept static geometry
## outside its own root, the narrower scan would silently lose it — no
## error, just an area whose routes run through its walls.
##
## Uses the real test_arena rather than a stand-in, because what is being
## checked is precisely whether authored content sits where the new scan
## looks. Constructed the way the game constructs it: a WorldContext over
## the area root, which is what registers the world.
func _a_real_authored_area_still_bakes() -> void:
	var area: Node3D = load("res://test_arena.tscn").instantiate()
	_root.add_child(area)
	# Its own units come with it and land in the global "units" group;
	# they are harmless here (nothing calls update_occupancy) but must not
	# outlive this case.
	await get_tree().physics_frame
	await get_tree().physics_frame

	var context := WorldContext.new(area)
	add_child(context)
	check("a real area registers as a world",
		context.world_root == area and context.world_3d != null)

	var walker: Unit = _spawn_in(area, Vector3(0.0, 1.0, -6.0))
	await get_tree().physics_frame

	var route: PackedVector3Array = NavigationGrid.find_path(
		get_tree(), walker.global_position, Vector3(0.0, 1.0, 6.0), walker, false)
	check("and its authored floor is still found by a scan rooted at the area",
		route.size() > 0,
		"empty route across test_arena — geometry lives outside the area root")

	if walker.is_in_group("units"):
		walker.remove_from_group("units")
	area.remove_child(walker)
	walker.queue_free()

	context.dispose()
	context.queue_free()

	for node in get_tree().get_nodes_in_group("units"):
		if node.is_inside_tree() and area.is_ancestor_of(node):
			node.remove_from_group("units")

	# The arena registers its authored party with PartyManager on _ready.
	# Freeing the area does not unregister them, so without this the next
	# suite inherits four freed Units in PartyManager.members — invisible
	# until something iterates them, which residency (capture() on leaving
	# a world) is the first thing to do.
	PartyManager.clear_members()
	_root.remove_child(area)
	area.queue_free()
	await get_tree().process_frame
	NavigationGrid.invalidate()

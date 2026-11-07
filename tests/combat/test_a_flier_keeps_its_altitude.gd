extends AiTestCase
## A flier's path stays FLIGHT_MIN_ALTITUDE clear of the ground: a goal
## too close to the floor is lifted to the flight floor, not flown to.


func run() -> void:
	var flier: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3(0, 2, 0))
	var tree := get_tree()
	var floor_y: float = NavigationGrid.flight_floor_at(tree, Vector3(4, 0, 0), flier)
	var path: PackedVector3Array = NavigationGrid.find_path(tree, flier.global_position, Vector3(4, 0.3, 0), flier, true)
	check("a path is found", path.size() > 0)
	if path.size() > 0:
		var end: Vector3 = path[path.size() - 1]
		check("it ends at the flight floor, not 0.3 m up", end.y >= floor_y - 0.01,
			"end %.2f, floor %.2f, path %s" % [end.y, floor_y, path])
	free_spawned()

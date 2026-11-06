extends AiTestCase
## A flier's ceiling rides on the ground under it, like its floor: over a
## rooftop at y=15 it may hover 3 m up, which a ceiling fixed at world
## y=12 would forbid.


func run() -> void:
	var roof := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.0, 1.0, 6.0)
	shape.shape = box
	roof.add_child(shape)
	_root.add_child(roof)
	roof.global_position = Vector3(8.0, 14.5, 0.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	NavigationGrid.invalidate()

	var flier: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3(0, 2, 0))
	var clearance: float = flier.radius + flier.avoidance_margin
	var above_roof: Dictionary = NavigationGrid.nearest_valid_point(
		get_tree(), Vector3(8.0, 18.1, 0.0), clearance, true, flier, 0)
	check("a flier may hover 3 m over a rooftop at y=15", above_roof.found,
		"ceiling there %.2f" % NavigationGrid.flight_ceiling_at(get_tree(), Vector3(8.0, 18.1, 0.0), flier))
	free_spawned()
	roof.queue_free()

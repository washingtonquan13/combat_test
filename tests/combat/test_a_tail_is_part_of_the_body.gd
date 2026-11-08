extends AiTestCase
## A unit is hit as its whole body (UnitBody), not as a disc round its
## feet: an SM 4 dragon's tail, 7 m behind it, is struck by a blast or a
## blade that never comes near its column. And a humanoid, which authors
## no hit shapes, is exactly its column - nothing about it changed.


func run() -> void:
	var dragon: Unit = spawn_demon("dragon", Vector3.ZERO)
	var man: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3(0.0, 0.0, 40.0))
	# Settled first: both drop onto the floor, and every point below is
	# read in the same frame it is tested in.
	for i in 3:
		await get_tree().physics_frame
	var body: UnitBody = dragon.body_shape()
	var capsules: Array = body.capsules()
	check("the dragon is a column and two hit capsules", capsules.size() == 2, "%d capsules" % capsules.size())

	var tip: Vector3 = _tail_tip(dragon, capsules)
	var behind: float = Vector2(tip.x - dragon.global_position.x, tip.z - dragon.global_position.z).length()
	check("its tail reaches far past its column", behind > dragon.radius + 3.0,
		"tip %.2f m out, column %.2f" % [behind, dragon.radius])
	check("and a point at the tail tip is ON the body", body.distance_to_point(tip) < 0.05,
		"%.3f m off" % body.distance_to_point(tip))

	var hit: Array[Unit] = UnitQuery.area_affected(get_tree(), man, tip, 1.0, true, true)
	check("a 1 m blast on the tail catches the dragon", hit.has(dragon), "caught %d" % hit.size())

	man.global_position = Vector3(tip.x + 1.0, dragon.global_position.y, tip.z)
	check("a man beside the tail is in reach of it", man.edge_distance_to(dragon) < 1.0,
		"gap %.2f m" % man.edge_distance_to(dragon))
	check("and the tail reaches him back - the dragon's whole body reaches", dragon.edge_distance_to(man) < 1.0,
		"gap %.2f m" % dragon.edge_distance_to(man))

	# The movement collider fits inside the circle the grid keeps clear.
	var clearance: float = dragon.radius + dragon.avoidance_margin
	var own := dragon.get_node("CollisionShape3D") as CollisionShape3D
	var box: AABB = own.transform * own.shape.get_debug_mesh().get_aabb()
	var widest: float = maxf(maxf(absf(box.position.x), absf(box.end.x)), maxf(absf(box.position.z), absf(box.end.z)))
	check("and it collides inside the clearance it plans with", widest <= clearance + 0.01,
		"collider %.2f m out, clearance %.2f" % [widest, clearance])

	check("a man has no hit capsules - his body is his column", man.body_shape().capsules().is_empty())
	var chest: Vector3 = man.anchor(CharacterModel.Anchor.CHEST) + Vector3(man.radius + 0.5, 0.0, 0.0)
	check_equalf("and is measured from it", man.body_shape().distance_to_point(chest), 0.5, 0.01)
	free_spawned()


func _tail_tip(dragon: Unit, capsules: Array) -> Vector3:
	var feet := Vector2(dragon.global_position.x, dragon.global_position.z)
	var far: Vector3 = dragon.global_position
	for capsule in capsules:
		for end: Vector3 in [capsule[0], capsule[1]]:
			if Vector2(end.x, end.z).distance_to(feet) > Vector2(far.x, far.z).distance_to(feet):
				far = end
	return far

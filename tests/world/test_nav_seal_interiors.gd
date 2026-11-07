extends AiTestCase
## Air the outside cannot reach is inside geometry: a room with four walls
## and a roof and no way in has no floor anyone can stand on. The grid used
## to take each shape's shell as the whole story, so the sealed floor was
## open and nearest_valid_point snapped units into it.

const CENTRE := Vector3(20.0, 0.05, 20.0)


func run() -> void:
	var room := StaticBody3D.new()
	_root.add_child(room)
	# 24 m long, so its far end lies chunks away from the probe at CENTRE.
	_add_box(room, Vector3(15.75, 1.5, 20.0), Vector3(0.5, 3.5, 9.0))
	var east: CollisionShape3D = _add_box(room, Vector3(40.25, 1.5, 20.0), Vector3(0.5, 3.5, 9.0))
	_add_box(room, Vector3(28.0, 1.5, 15.75), Vector3(25.0, 3.5, 0.5))
	_add_box(room, Vector3(28.0, 1.5, 24.25), Vector3(25.0, 3.5, 0.5))
	_add_box(room, Vector3(28.0, 3.25, 20.0), Vector3(25.0, 0.5, 9.0))
	NavigationGrid.invalidate()
	for i in 4:
		await get_tree().physics_frame

	var r: Dictionary = NavigationGrid.nearest_valid_point(get_tree(), CENTRE, 0.5, false, null, 12)
	var p: Vector3 = r.point
	var inside: bool = p.x > 16.0 and p.x < 24.0 and p.z > 16.0 and p.z < 24.0 and p.y < 3.0
	check("a sealed room's floor is not a place to stand", not r.found or not inside,
		"snapped to %s" % p)

	# A moved prop re-bakes only its own region, but whether a room is
	# sealed is decided by the whole world: re-baking chunks inside the room
	# must keep it sealed, and taking a wall away must open it.
	NavigationGrid.invalidate_region(room, AABB(Vector3(18.0, 0.0, 18.0), Vector3(4.0, 3.0, 4.0)))
	var kept: bool = not _stands_inside()
	# The far wall goes: its region's chunks are 16 m from the probe, so the
	# probe's chunk opens only if the seal is recomputed for the world.
	east.free()
	await get_tree().physics_frame
	NavigationGrid.invalidate_region(room, AABB(Vector3(40.0, -0.25, 15.5), Vector3(0.5, 3.5, 9.0)))
	var opened: bool = _stands_inside()
	check("a scoped re-bake keeps the room sealed, and opening a wall unseals it", kept and opened,
		"sealed after re-bake %s, open after the wall went %s" % [kept, opened])


func _stands_inside() -> bool:
	var r: Dictionary = NavigationGrid.nearest_valid_point(get_tree(), CENTRE, 0.5, false, null, 12)
	var p: Vector3 = r.point
	return r.found and p.x > 16.0 and p.x < 24.0 and p.z > 16.0 and p.z < 24.0 and p.y < 3.0


func _add_box(body: StaticBody3D, centre: Vector3, size: Vector3) -> CollisionShape3D:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = centre
	body.add_child(shape)
	return shape

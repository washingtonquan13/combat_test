extends AiTestCase
## Air the outside cannot reach is inside geometry: a room with four walls
## and a roof and no way in has no floor anyone can stand on. The grid used
## to take each shape's shell as the whole story, so the sealed floor was
## open and nearest_valid_point snapped units into it.

const CENTRE := Vector3(20.0, 0.05, 20.0)


func run() -> void:
	var room := StaticBody3D.new()
	_root.add_child(room)
	_add_box(room, Vector3(15.75, 1.5, 20.0), Vector3(0.5, 3.5, 9.0))
	_add_box(room, Vector3(24.25, 1.5, 20.0), Vector3(0.5, 3.5, 9.0))
	_add_box(room, Vector3(20.0, 1.5, 15.75), Vector3(9.0, 3.5, 0.5))
	_add_box(room, Vector3(20.0, 1.5, 24.25), Vector3(9.0, 3.5, 0.5))
	_add_box(room, Vector3(20.0, 3.25, 20.0), Vector3(9.0, 0.5, 9.0))

	NavigationGrid.invalidate()
	for i in 4:
		await get_tree().physics_frame

	var r: Dictionary = NavigationGrid.nearest_valid_point(get_tree(), CENTRE, 0.5, false, null, 12)
	var p: Vector3 = r.point
	var inside: bool = p.x > 16.0 and p.x < 24.0 and p.z > 16.0 and p.z < 24.0 and p.y < 3.0
	check("a sealed room's floor is not a place to stand", not r.found or not inside,
		"snapped to %s" % p)


func _add_box(body: StaticBody3D, centre: Vector3, size: Vector3) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = centre
	body.add_child(shape)

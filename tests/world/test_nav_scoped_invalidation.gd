extends AiTestCase
## A wall put down across a warm route, with only its own box invalidated
## (invalidate_region, as a moved prop does), is routed around: the chunks
## under it re-bake even though the rest of the grid stays baked.

const FROM := Vector3(-6.0, 0.05, 0.0)
const TO := Vector3(6.0, 0.05, 0.0)


func run() -> void:
	# A post taller than the wall, off the route: the grid's top rides on
	# the tallest geometry, so without it the wall would grow the bounds and
	# invalidate_region would fall back to a full rescan, which hides
	# whether the scoped un-bake works.
	_add_box(Vector3(8.0, 2.0, 8.0), Vector3(1.0, 4.0, 1.0))
	var walker: Unit = spawn_brute(FROM.x, FROM.z)
	await get_tree().physics_frame
	var before: PackedVector3Array = NavigationGrid.find_path(get_tree(), FROM, TO, walker, false)
	check("the open floor routes straight across", before.size() >= 2, "path %s" % before)

	var wall := _add_box(Vector3(0.0, 1.0, 0.0), Vector3(1.0, 2.0, 12.0))
	await get_tree().physics_frame
	NavigationGrid.invalidate_region(wall, AABB(Vector3(-0.5, 0.0, -6.0), Vector3(1.0, 2.0, 12.0)))

	var after: PackedVector3Array = NavigationGrid.find_path(get_tree(), FROM, TO, walker, false)
	var crossings: Array = _samples(after).filter(func(p: Vector3) -> bool:
		return absf(p.x) < 0.5 and absf(p.z) < 6.0)
	check("after the wall's region is invalidated the route goes around it",
		after.size() >= 2 and after[after.size() - 1].distance_to(TO) < 0.8 and crossings.is_empty(),
		"path %s" % after)


func _samples(path: PackedVector3Array) -> Array:
	var out: Array = []
	for i in path.size() - 1:
		var steps: int = maxi(1, ceili(path[i].distance_to(path[i + 1]) / 0.25))
		for k in steps:
			out.append(path[i].lerp(path[i + 1], float(k) / steps))
	return out


func _add_box(centre: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_root.add_child(body)
	body.global_position = centre
	return body

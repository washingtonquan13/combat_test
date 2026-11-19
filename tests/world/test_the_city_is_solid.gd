extends AiTestCase
## The Morrow overworld stands on solid ground: a ray dropped from the sky
## lands on the terrain at the start spawn, on a roof downtown, on a tree in
## the Greywood, and the map's edge is walled.
##
## The other overworld suites load this scene but never touch its ground,
## so they stay green with the ground taken out of it. This suite does not.
## The map is world/morrow_overworld.tscn, written by
## tools/blockout/morrow_overworld.py. The building is read from stage 3's
## lots (world/morrow/city.json, which MorrowCity builds from) and the tree
## from the scene's own collision shapes (not its MultiMeshes, which the
## headless renderer leaves empty), so a regenerated map needs no new
## coordinates here.

const SCENE := "res://world/morrow_overworld.tscn"
const CITY := "res://world/morrow/city.json"
## Above every roof in Morrow.
const SKY: float = 400.0
## The map is lifted clear of the test runner's own floor at y 0.
const LIFT: float = 100.0


func run() -> void:
	var area: Node3D = load(SCENE).instantiate()
	# The ground is the subject, not the overworld's avatar and camera.
	area.set_script(null)
	area.position.y = LIFT
	_root.add_child(area)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var start: Node3D = area.get_node(^"SpawnPoints/Start")
	var street := _drop(area, start.global_position.x, start.global_position.z)
	check("a ray at the start spawn lands on the floor", _under(area, ^"Ground", street), _say(street))
	if not street.is_empty():
		# Start stands half a metre over the terrain (morrow_overworld.py).
		check("and the ground is just under the start", absf(street.position.y - (start.global_position.y - 0.5)) < 0.2,
			_say(street))

	var city: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CITY))
	var block: Dictionary = {}
	for b in city.buildings:
		if b.roof == "flat":
			block = b
			break
	check("stage 3 wrote a flat-roofed building", not block.is_empty())
	if not block.is_empty():
		var at := Vector2.ZERO
		for p in block.points:
			at += Vector2(p[0], p[1])
		at /= block.points.size()
		var roof := _drop(area, at.x, at.y)
		check("a ray on a building lands on its solid", _under(area, ^"City/Solid", roof), _say(roof))
		if not roof.is_empty():
			var top: float = LIFT + block.floor + city.ground_floor + (block.storeys - 1) * city.storey
			check("at its roof", absf(roof.position.y - top) < 0.5, "%s, roof at %.1f" % [_say(roof), top])

	var tree: Node3D = area.get_node(^"Wilds/TreeTrunks/Trunk0")
	var trunk := _drop(area, tree.global_position.x, tree.global_position.z)
	check("a ray on a tree lands on its trunk", _under(area, ^"Wilds/TreeTrunks", trunk), _say(trunk))

	var edge := area.get_node_or_null(^"Edge") as StaticBody3D
	check("the map's edge is walled", edge != null and edge.get_child_count() == 4,
		"%d wall(s)" % (edge.get_child_count() if edge else 0))
	area.free()


func _drop(area: Node3D, x: float, z: float) -> Dictionary:
	var from := Vector3(x, SKY + LIFT, z)
	var query := PhysicsRayQueryParameters3D.create(from, from - Vector3(0.0, SKY + 50.0, 0.0))
	return area.get_world_3d().direct_space_state.intersect_ray(query)


func _under(area: Node3D, path: NodePath, hit: Dictionary) -> bool:
	var owner_node := area.get_node_or_null(path)
	return not hit.is_empty() and owner_node != null \
		and (hit.collider == owner_node or owner_node.is_ancestor_of(hit.collider))


func _say(hit: Dictionary) -> String:
	if hit.is_empty():
		return "nothing hit"
	return "hit %s at %s" % [hit.collider.get_path(), hit.position]

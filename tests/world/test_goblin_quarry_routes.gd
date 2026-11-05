extends AiTestCase
## The demo quarry's geometry gives the routes it was blocked out for: the
## town walks down the ramp to the pit camp, both ends of the ladder are
## standable, and the shaman's ledge can only be reached by Jump.
##
## Only LevelGeometry is lifted out of the scene, so no area script, party
## bootstrap or unit runs, and the harness floor is removed first.

const QUARRY := "res://world/goblin_quarry.tscn"
const TOWN := Vector3(4.0, 0.05, 30.0)
const CAMP := Vector3(0.0, -5.95, -44.0)
const LEDGE := Vector3(0.0, -2.95, -58.0)


func run() -> void:
	var scene: Node = (load(QUARRY) as PackedScene).instantiate()
	var geometry: Node3D = scene.get_node("LevelGeometry")
	scene.remove_child(geometry)
	scene.free()
	# The harness's bare floor is a slab at y=0 that would roof the pit.
	for child in _root.get_children():
		if child is StaticBody3D:
			child.free()
	_root.add_child(geometry)
	var ladder: Ladder = geometry.get_node("Ladder")
	var walker: Unit = spawn_brute(0.0, 30.0)

	NavigationGrid.invalidate()
	for i in 10:
		await get_tree().physics_frame

	var down: PackedVector3Array = _route(walker, TOWN, CAMP)
	check("the town routes down to the pit camp", _arrives(down, CAMP), "path %s" % down)
	check("and that route goes by the ramp on the east side",
		Array(down).any(func(p: Vector3) -> bool: return p.x > 9.0 and p.y < -1.0 and p.y > -5.0),
		"path %s" % down)
	var top: Vector3 = ladder.top_position()
	var base: Vector3 = ladder.base_position()
	check("the ladder's top is reachable from the town", _arrives(_route(walker, TOWN, top), top),
		"top %s" % top)
	check("the ladder's base is reachable from the camp", _arrives(_route(walker, CAMP, base), base),
		"base %s" % base)
	check("the shaman's ledge does not route on foot (Jump only)",
		not _arrives(_route(walker, CAMP, LEDGE), LEDGE))


func _route(walker: Unit, from: Vector3, to: Vector3) -> PackedVector3Array:
	return NavigationGrid.find_path(get_tree(), from, to, walker, false)


func _arrives(path: PackedVector3Array, to: Vector3) -> bool:
	return path.size() >= 2 and path[path.size() - 1].distance_to(to) < 0.8

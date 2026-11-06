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
		_samples(down).any(func(p: Vector3) -> bool: return p.x > 9.0 and p.y < -1.0 and p.y > -5.0),
		"path %s" % down)
	check("and the ramp is one smoothed run, not a stair of waypoints",
		Array(down).filter(func(p: Vector3) -> bool: return p.y < -0.5 and p.y > -5.5).size() <= 1,
		"path %s" % down)
	var top: Vector3 = ladder.top_position()
	var base: Vector3 = ladder.base_position()
	check("the ladder's top is reachable from the town", _arrives(_route(walker, TOWN, top), top),
		"top %s" % top)
	check("the ladder's base is reachable from the camp", _arrives(_route(walker, CAMP, base), base),
		"base %s" % base)
	check("the shaman's ledge does not route on foot (Jump only)",
		not _arrives(_route(walker, CAMP, LEDGE), LEDGE))
	# Sealed off is answered by connectivity, not by a search that runs to
	# its expansion cap (~160 ms) to find out. Second call: bakes are warm.
	var t0: int = Time.get_ticks_usec()
	var sealed: PackedVector3Array = _route(walker, CAMP, LEDGE)
	var failed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	_route(walker, TOWN, CAMP)
	var routed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	print("  ledge (sealed) %.2f ms, town->camp %.2f ms" % [failed_ms, routed_ms])
	check("and that answer is quick", sealed.is_empty() and failed_ms < 20.0, "%.1f ms" % failed_ms)

	# Walked, not just routed: from the pit floor beside the ramp, a path
	# that steps onto the ramp's side face strands the walker at its foot.
	var rim := Vector3(12.0, 0.05, -30.0)
	walker.global_position = Vector3(6.0, -5.95, -40.0)
	walker.velocity = Vector3.ZERO
	for i in 15:
		await get_tree().physics_frame
	walker.move_to(rim)
	for i in 1500:
		await get_tree().physics_frame
		if not walker.is_moving():
			break
	check("a unit on the pit floor walks up the ramp, not into its side",
		walker.global_position.distance_to(rim) < 1.0, "ended %s" % walker.global_position)

	# A flier low in the pit, hovering the rim above its altitude: the
	# query lifts to the rim. It used to look for a floor at the flier's
	# altitude inside the rim's rock, found a sealed pocket there, and
	# every hovered cell cost a failed 160 ms search.
	walker.apply_status(load("res://data/statuses/flying.tres"))
	walker.global_position = Vector3(0.0, -3.0, -44.0)
	walker.flight_target_altitude = -3.0
	var over_rim := Vector3(1.8, 0.0, -24.7)
	var preview: Dictionary = walker.preview_route(over_rim)
	var flown: PackedVector3Array = preview.get("path", PackedVector3Array())
	check("a flier in the pit routes to rim ground above its altitude",
		flown.size() >= 2 and flown[flown.size() - 1].y > 0.5, "path %s" % flown)


func _route(walker: Unit, from: Vector3, to: Vector3) -> PackedVector3Array:
	return NavigationGrid.find_path(get_tree(), from, to, walker, false)


## Points every 0.5 m along the path, since a smoothed ramp has no waypoint
## halfway down it.
func _samples(path: PackedVector3Array) -> Array:
	var out: Array = []
	for i in path.size() - 1:
		var steps: int = maxi(1, ceili(path[i].distance_to(path[i + 1]) / 0.5))
		for k in steps:
			out.append(path[i].lerp(path[i + 1], float(k) / steps))
	return out


func _arrives(path: PackedVector3Array, to: Vector3) -> bool:
	return path.size() >= 2 and path[path.size() - 1].distance_to(to) < 0.8

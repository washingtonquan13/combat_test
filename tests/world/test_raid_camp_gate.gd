extends AiTestCase
## The quarry camp's north gate: shut, a body outside goes round to the south
## opening; smashed (the quarry's smash_gate), it walks straight in through
## it. The rampart walk is reached up a ladder.
##
## Only LevelGeometry is lifted out of the quarry, so no area script, party
## bootstrap or unit runs. Points are in the camp's own frame.

const QUARRY := "res://world/goblin_quarry.tscn"
const QuarryArea := preload("res://world/goblin_quarry.gd")
const OUTSIDE := Vector2(0.0, -24.0)
const INSIDE := Vector2(0.0, -8.0)
const RAMPART := Vector3(-9.0, 2.25, -14.2)

var _camp: Node3D


func run() -> void:
	var scene: Node = (load(QUARRY) as PackedScene).instantiate()
	var geometry: Node3D = scene.get_node("LevelGeometry")
	scene.remove_child(geometry)
	scene.free()
	for child in _root.get_children():
		if child is StaticBody3D:
			child.free()
	_root.add_child(geometry)
	_camp = geometry.get_node("RaidCamp")
	NavigationGrid.invalidate()
	for i in 10:
		await get_tree().physics_frame
	var outside := _ground(OUTSIDE)
	var inside := _ground(INSIDE)
	var rampart := _camp.to_global(RAMPART)
	var walker: Unit = spawn_brute(outside.x, outside.z)
	walker.global_position = outside
	await get_tree().physics_frame

	var shut: PackedVector3Array = NavigationGrid.find_path(get_tree(), outside, inside, walker, false)
	check("shut, the way in goes round the walls", shut.size() >= 2 and _length(shut) > 40.0
		and not _through_gate(shut), "length %.1f" % _length(shut))

	var along_to := _camp.to_global(RAMPART + Vector3(5.0, 0.0, 0.0))
	var along: PackedVector3Array = NavigationGrid.find_path(get_tree(), rampart, along_to, walker, false)
	check("the rampart walk is walkable along its top", along.size() >= 2 and _length(along) < 7.0
		and absf(along[along.size() - 1].y - rampart.y) < 0.3, "path %s" % along)
	walker.global_position = inside
	await get_tree().physics_frame
	var up: Dictionary = Ladder.find_route(walker, rampart)
	check("the rampart walk is reached from inside up a ladder", not up.is_empty()
		and (up.far as Vector3).distance_to(rampart) < 6.0, "route %s" % up)

	var was: AABB = QuarryArea.smash_gate(_camp.get_node("Gate"))
	NavigationGrid.invalidate_region(_root, was)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var open: PackedVector3Array = NavigationGrid.find_path(get_tree(), outside, inside, walker, false)
	check("broken, the way in is through the gate", open.size() >= 2 and _length(open) < 20.0
		and _through_gate(open), "length %.1f" % _length(open))


## The ground under a camp-frame (x, z), just above it, in world space.
func _ground(at: Vector2) -> Vector3:
	var top := _camp.to_global(Vector3(at.x, 20.0, at.y))
	var hit := _camp.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(top, top + Vector3.DOWN * 60.0))
	return (hit.position as Vector3) + Vector3.UP * 0.05 if hit else top


func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in path.size() - 1:
		total += path[i].distance_to(path[i + 1])
	return total if path.size() >= 2 else INF


func _through_gate(path: PackedVector3Array) -> bool:
	for i in path.size() - 1:
		var steps: int = maxi(1, ceili(path[i].distance_to(path[i + 1]) / 0.25))
		for k in steps:
			var p: Vector3 = _camp.to_local(path[i].lerp(path[i + 1], float(k) / steps))
			if absf(p.x) < 2.0 and absf(p.z + 15.0) < 0.5:
				return true
	return false

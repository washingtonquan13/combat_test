extends AiTestCase
## The raid camp's north gate: shut, a body outside goes round to the south
## opening; smashed (break_gate), it walks straight in through it. The
## rampart walk is reached up a ladder.

const CAMP: PackedScene = preload("res://world/raid_camp.tscn")
const OUTSIDE := Vector3(0.0, 0.05, -24.0)
const INSIDE := Vector3(0.0, 0.05, -8.0)
const RAMPART := Vector3(-9.0, 2.25, -14.2)


func run() -> void:
	FlagManager.clear_flag(RaidCamp.GATE_BROKEN)
	var camp: RaidCamp = CAMP.instantiate()
	for unit in camp.find_children("*", "Unit", true, false):
		unit.get_parent().remove_child(unit)
		unit.free()
	_root.add_child(camp)
	await get_tree().physics_frame
	await get_tree().physics_frame
	NavigationGrid.invalidate()
	var walker: Unit = spawn_brute(OUTSIDE.x, OUTSIDE.z)
	await get_tree().physics_frame

	var shut: PackedVector3Array = NavigationGrid.find_path(get_tree(), OUTSIDE, INSIDE, walker, false)
	check("shut, the way in goes round the walls", shut.size() >= 2 and _length(shut) > 40.0
		and not _through_gate(shut), "length %.1f" % _length(shut))

	var along: PackedVector3Array = NavigationGrid.find_path(get_tree(), RAMPART, RAMPART + Vector3(5.0, 0.0, 0.0), walker, false)
	check("the rampart walk is walkable along its top", along.size() >= 2 and _length(along) < 7.0
		and absf(along[along.size() - 1].y - RAMPART.y) < 0.3, "path %s" % along)
	walker.global_position = INSIDE
	await get_tree().physics_frame
	var up: Dictionary = Ladder.find_route(walker, RAMPART)
	check("the rampart walk is reached from inside up a ladder", not up.is_empty()
		and (up.far as Vector3).distance_to(RAMPART) < 6.0, "route %s" % up)

	camp.break_gate()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var open: PackedVector3Array = NavigationGrid.find_path(get_tree(), OUTSIDE, INSIDE, walker, false)
	check("broken, the way in is through the gate", open.size() >= 2 and _length(open) < 20.0
		and _through_gate(open), "length %.1f" % _length(open))
	FlagManager.clear_flag(RaidCamp.GATE_BROKEN)


func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in path.size() - 1:
		total += path[i].distance_to(path[i + 1])
	return total if path.size() >= 2 else INF


func _through_gate(path: PackedVector3Array) -> bool:
	for i in path.size() - 1:
		var steps: int = maxi(1, ceili(path[i].distance_to(path[i + 1]) / 0.25))
		for k in steps:
			var p: Vector3 = path[i].lerp(path[i + 1], float(k) / steps)
			if absf(p.x) < 2.0 and absf(p.z + 15.0) < 0.5:
				return true
	return false

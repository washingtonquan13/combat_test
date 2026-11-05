extends AiTestCase
## A ladder climb is part of the one walked route (unit_movement.gd's
## _ladder_route): no cost accrues on it (BG3's rule), it takes time at
## Ladder.climb_speed rather than snapping, and a stop ordered mid-climb
## takes effect at the far end, so no unit is ever left on the rungs.
##
## Uses the demo quarry's ladder; only LevelGeometry is lifted out.

const QUARRY := "res://world/goblin_quarry.tscn"

var _saved_factions: Array = []


func run() -> void:
	_saved_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []
	var scene: Node = (load(QUARRY) as PackedScene).instantiate()
	var geometry: Node3D = scene.get_node("LevelGeometry")
	scene.remove_child(geometry)
	scene.free()
	for child in _root.get_children():
		if child is StaticBody3D:
			child.free()
	_root.add_child(geometry)
	var ladder: Ladder = geometry.get_node("Ladder")
	var top: Vector3 = ladder.top_position()
	var base: Vector3 = ladder.base_position()
	var walker: Unit = spawn_brute(top.x, top.z)
	walker.global_position = top
	NavigationGrid.invalidate()
	for i in 15:
		await get_tree().physics_frame

	check("SETUP: move_to the base starts a move", walker.move_to(base))
	var route: Dictionary = walker.current_route()
	var path: PackedVector3Array = route.get("path", PackedVector3Array())
	var cost: PackedFloat32Array = route.get("cumulative_cost", PackedFloat32Array())
	var vertical_cost: float = 0.0
	var has_vertical: bool = false
	for i in range(1, path.size()):
		if Vector2(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z).length() < 0.01 \
				and absf(path[i].y - path[i - 1].y) > 1.0:
			has_vertical = true
			vertical_cost += cost[i] - cost[i - 1]
	check("the climb is in the walked route", has_vertical, "path %s" % path)
	check("and costs nothing", is_zero_approx(vertical_cost), "cost %s" % cost)

	var start_frame: int = Engine.get_physics_frames()
	var guard: int = 0
	while not walker.is_climbing() and guard < 300:
		await get_tree().physics_frame
		guard += 1
	check("the unit gets onto the ladder", walker.is_climbing())
	var climb_frame: int = Engine.get_physics_frames()
	for i in 20:
		await get_tree().physics_frame
	walker.stop_moving()
	check("a stop mid-climb does not leave it on the rungs", walker.is_moving() and walker.is_climbing())
	guard = 0
	while walker.is_moving() and guard < 1200:
		await get_tree().physics_frame
		guard += 1
	var seconds: float = float(Engine.get_physics_frames() - climb_frame) / Engine.physics_ticks_per_second
	var climb_length: float = 0.0
	var climb: PackedVector3Array = Ladder.climb_waypoints(base, top)
	for i in range(1, climb.size()):
		climb_length += climb[i].distance_to(climb[i - 1])
	check("it finishes the climb at the base", walker.global_position.distance_to(base) < 0.6,
		"ended %s, base %s" % [walker.global_position, base])
	check("at climb speed, not a snap (%.1fs for %.1fm)" % [seconds, climb_length],
		seconds > 0.7 * climb_length / ladder.climb_speed)

	var enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], base + Vector3(0.0, 0.0, -8.0))
	await get_tree().physics_frame
	var fight: Encounter = CombatManager.start_combat([walker, enemy] as Array[Unit])
	await get_tree().process_frame
	guard = 0
	while fight.is_running and fight.current_unit != walker and guard < 6:
		CombatManager.end_turn(fight.current_unit)
		await get_tree().process_frame
		guard += 1
	check("SETUP: the walker's turn", fight.is_running and fight.current_unit == walker)
	var before: float = walker.move_remaining
	walker.move_to(top)
	guard = 0
	while walker.is_moving() and guard < 1200:
		await get_tree().physics_frame
		guard += 1
	check("in combat it climbs up", walker.global_position.distance_to(top) < 0.6,
		"ended %s" % walker.global_position)
	check("and the Move budget pays only the walk (%.2f spent)" % (before - walker.move_remaining),
		before - walker.move_remaining < 1.0)

	if fight.is_running:
		fight.finish(&"")
	CombatAi.ai_factions = _saved_factions

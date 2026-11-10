extends AiTestCase
## A ladder climb is part of the one walked route (unit_movement.gd's
## _ladder_route): no cost accrues on it (BG3's rule), it takes time at
## Ladder.climb_speed rather than snapping, and a stop ordered mid-climb
## takes effect at the far end, so no unit is ever left on the rungs. A
## destination anywhere routes by the ladder when that is the cheaper way.
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

	# A pit-floor spot nowhere near the base: on foot it is the long way
	# round by the east ramp, so the ladder is the cheaper route.
	check("the AI's route query sees the same ladder",
		_climb_cost(walker.plan_route(base + Vector3(3.0, 0.0, 2.0))) >= 0.0)
	walker.move_to(base + Vector3(3.0, 0.0, 2.0))
	check("a destination away from the ladder still routes by it",
		_climb_cost(walker.current_route()) >= 0.0, "path %s" % walker.current_route().get("path"))
	walker.stop_moving()
	await get_tree().physics_frame

	check("SETUP: move_to the base starts a move", walker.move_to(base))
	var route: Dictionary = walker.current_route()
	var vertical_cost: float = _climb_cost(route)
	check("the climb is in the walked route", vertical_cost >= 0.0, "path %s" % route.get("path"))
	check("and costs nothing", is_zero_approx(vertical_cost), "cost %s" % route.get("cumulative_cost"))

	var start_frame: int = Engine.get_physics_frames()
	var guard: int = 0
	while not walker.is_climbing() and guard < 300:
		await get_tree().physics_frame
		guard += 1
	check("the unit gets onto the ladder", walker.is_climbing())
	var climb_frame: int = Engine.get_physics_frames()
	guard = 0
	while walker.climbing_over() == 0 and guard < 300:
		await get_tree().physics_frame
		guard += 1
	await get_tree().physics_frame
	check("it gets on over the top edge with its own clip",
		String(_animation_player(walker).current_animation) == "Ladder/Climb_On_Top",
		"playing %s" % _animation_player(walker).current_animation)
	guard = 0
	while walker.climb_direction() == 0 and guard < 600:
		await get_tree().physics_frame
		guard += 1
	for i in 20:
		await get_tree().physics_frame
	check("it faces the way the ladder does", walker.visual_forward().dot(ladder.facing()) > 0.9,
		"faces %s, ladder %s" % [walker.visual_forward(), ladder.facing()])
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

	var enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], base - ladder.facing() * 8.0)
	await get_tree().physics_frame
	check("the AI knows a grounded foe can climb up to the top",
		AiScorer._can_ever_reach(enemy, top, melee()))
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

	# Two going down together: one on the rungs at a time, the other
	# waits off the foot, and both get down.
	var second: Unit = spawn_brute(top.x, top.z)
	# Behind the top, away from the drop: (top - base) points onto the landing.
	var onto_landing: Vector3 = Vector3(top.x - base.x, 0.0, top.z - base.z).normalized()
	second.global_position = top + onto_landing * 0.9
	await get_tree().physics_frame
	var pair: Array = [walker, second]
	walker.move_to(base + Vector3(3.0, 0.0, 2.0), pair)
	second.move_to(base + Vector3(3.0, 0.0, 3.5), pair)
	var most_on_rungs: int = 0
	var both_used: Dictionary = {}
	guard = 0
	while (walker.is_moving() or second.is_moving()) and guard < 3000:
		await get_tree().physics_frame
		guard += 1
		var on: int = 0
		for unit: Unit in pair:
			if unit.climbing_ladder() == ladder:
				on += 1
				both_used[unit] = true
		most_on_rungs = maxi(most_on_rungs, on)
	check("SETUP: both took the ladder", both_used.size() == 2,
		"used %s; walker %s, second %s" % [both_used.size(), walker.global_position, second.global_position])
	check("one climber at a time", most_on_rungs == 1, "%d on the rungs at once" % most_on_rungs)
	check("and both get down", walker.global_position.y < base.y + 0.5 and second.global_position.y < base.y + 0.5,
		"walker %s, second %s" % [walker.global_position, second.global_position])
	CombatAi.ai_factions = _saved_factions


## What the route's vertical segments cost, or -1 when it has none.
func _climb_cost(route: Dictionary) -> float:
	var path: PackedVector3Array = route.get("path", PackedVector3Array())
	var cost: PackedFloat32Array = route.get("cumulative_cost", PackedFloat32Array())
	var total: float = -1.0
	for i in range(1, path.size()):
		if Vector2(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z).length() < 0.01 \
				and absf(path[i].y - path[i - 1].y) > 1.0:
			total = maxf(total, 0.0) + cost[i] - cost[i - 1]
	return total


static func _animation_player(unit: Unit) -> AnimationPlayer:
	return unit.find_child("AnimationPlayer", true, false) as AnimationPlayer

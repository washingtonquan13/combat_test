extends "res://tools/tier3_demo.gd"
## Recorded showcase of the ladder climb as part of the move - NOT a test.


func _look(point: Vector3, distance: float, yaw: float) -> void:
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	if not _marker.is_inside_tree():
		WorldManager.spawn_parent().add_child(_marker)
	_marker.global_position = point
	camera.focus_target = _marker
	camera.target_anchor_offset = Vector3.ZERO
	camera.target_distance = distance
	camera.target_yaw = yaw


func _until_still(limit: float = 15.0) -> void:
	var t := 0.0
	while _hero.is_moving() and t < limit:
		await _wait(0.1)
		t += 0.1


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	CombatAi.ai_factions = []
	var ladder: Ladder = get_tree().get_first_node_in_group("ladders")
	var base: Vector3 = ladder.base_position()
	var top: Vector3 = ladder.top_position()
	_hero.global_position = base + Vector3(3.0, 0.0, -3.0)
	await _wait(0.5)
	var mid := (base + top) * 0.5
	_look(mid, 9.0, 35.0)
	await _wait(1.5)
	_say("Climb up: CMU mocap rung cycle, 0.75 m/s")
	await _click(_screen(top + Vector3(0.0, 0.0, 1.0)))
	while not _hero.is_climbing():
		await _wait(0.05)
	_look(_hero.global_position + Vector3(0, 1, 0), 6.0, 35.0)
	while _hero.is_climbing():
		_marker.global_position = _hero.global_position + Vector3(0, 1, 0)
		await _wait(0.03)
	await _until_still()
	await _wait(1.0)
	_say("Climb down: the same cycle backwards")
	await _click(_screen(base + Vector3(3.0, 0.0, -3.0)))
	while not _hero.is_climbing():
		await _wait(0.05)
	while _hero.is_climbing():
		_marker.global_position = _hero.global_position + Vector3(0, 1, 0)
		await _wait(0.03)
	await _until_still()
	await _wait(1.0)
	get_tree().quit()

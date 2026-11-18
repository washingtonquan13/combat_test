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


## Keeps the camera on the hero until the move is over.
func _follow(limit: float = 30.0) -> void:
	var t := 0.0
	while _hero.is_moving() and t < limit:
		_marker.global_position = _hero.global_position + Vector3(0, 1, 0)
		await _wait(0.03)
		t += 0.03


func _run() -> void:
	# LADDER_YAW turns the camera (a side-on look at the mount, say).
	var yaw: float = float(OS.get_environment("LADDER_YAW")) if OS.has_environment("LADDER_YAW") else 35.0
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	CombatAi.ai_factions = []
	# The quarry's own ladder (LevelGeometry/Ladder), not the camp's
	# rampart one, which is walled in.
	var ladder: Ladder = get_tree().get_first_node_in_group("ladders")
	for node: Node in get_tree().get_nodes_in_group("ladders"):
		if node.name == "Ladder" and node.get_parent().name == "LevelGeometry":
			ladder = node
	var base: Vector3 = ladder.base_position()
	var top: Vector3 = ladder.top_position()
	# On the pit floor in front of it (facing() points into the wall).
	var ground: Vector3 = base - ladder.facing() * 3.0
	_hero.global_position = ground
	await _wait(0.5)
	# The click is framed on the whole ladder (close in, the palisade
	# hides the top); then the camera follows the hero in.
	var mid := (base + top) * 0.5
	_look(mid, 9.0, 35.0)
	await _wait(1.5)
	_say("Up: Mixamo mount at the foot, the rung cycle, over the top")
	var onto_landing: Vector3 = Vector3(top.x - base.x, 0.0, top.z - base.z).normalized()
	await _click(_screen(top + onto_landing * 1.0))
	_look(_hero.global_position + Vector3(0, 1, 0), 6.0, yaw)
	await _follow()
	await _wait(1.0)
	_say("Down: on over the top, the rungs backwards, the mount reversed")
	_look(mid, 9.0, 35.0)
	await _wait(1.0)
	await _click(_screen(ground))
	_look(_hero.global_position + Vector3(0, 1, 0), 6.0, yaw)
	await _follow()
	await _wait(1.0)
	get_tree().quit()

extends Node
## Standalone walkthrough — NOT a test, NOT part of tests/run.sh.
## Starts a new game in the goblin quarry and saves stills of the camp on
## the rise from a few places to user://raid_camp_shots/, then quits.
##
##   Godot --resolution 1600x900 res://tools/raid_camp_demo.tscn

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
## The camp's origin in the quarry: VIEWS are in its frame.
const CAMP_O := Vector3(66.0, 3.0, -6.0)
## [camera position, point looked at, name].
const VIEWS: Array = [
	[Vector3(0, 30, 38), Vector3(0, 0, -8), "overview"],
	[Vector3(0, 6, -38), Vector3(0, 2, -14), "gate_from_road"],
	[Vector3(9, 5, -3), Vector3(-2, 1.5, -13), "inside_gate"],
	[Vector3(-4, 3.2, 6), Vector3(0, 0.8, -1), "campfire"],
	[Vector3(-12, 7, -40), Vector3(2, 1, -57), "goblins"],
]


func _ready() -> void:
	add_child(MainRootScene.instantiate())
	_run.call_deferred()


func _run() -> void:
	await _wait(1.0)
	get_tree().get_first_node_in_group("main_menu")._on_start_pressed()
	await _wait(1.0)
	var creation: Node = get_tree().get_first_node_in_group("character_creation")
	creation._on_auto_fill_pressed()
	await _wait(0.5)
	creation._on_confirm_pressed()
	var world: Node = await WorldManager.world_focused
	await _wait(3.0)
	for unit in world.find_children("*", "Unit", true, false):
		var ahead: Vector3 = unit.visual_forward()
		print("DEMO facing %s %.0f deg (authored %.0f)" % [unit.name,
			rad_to_deg(atan2(ahead.x, ahead.z)), rad_to_deg(unit.rotation.y)])
	await _measure("tactical camera")
	var camera := Camera3D.new()
	camera.fov = 55.0
	world.add_child(camera)
	camera.make_current()
	DirAccess.make_dir_recursive_absolute("user://raid_camp_shots")
	for view in VIEWS:
		camera.global_position = CAMP_O + view[0]
		camera.look_at(CAMP_O + view[1])
		await _wait(0.6)
		var image: Image = camera.get_viewport().get_texture().get_image()
		image.save_png("user://raid_camp_shots/%s.png" % view[2])
		print("DEMO shot ", view[2])
	camera.global_position = CAMP_O + Vector3(0, 9, -26)
	camera.look_at(CAMP_O + Vector3(0, 1, -2))
	await _measure("whole camp in view")
	print("DEMO world ", world, " dir ", ProjectSettings.globalize_path("user://raid_camp_shots"))
	get_tree().quit()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## Frame times over five seconds: the mean and the worst.
func _measure(what: String) -> void:
	await _wait(1.0)
	var times: Array[float] = []
	var last: int = Time.get_ticks_usec()
	var until: int = last + 5000000
	while last < until:
		await get_tree().process_frame
		var now: int = Time.get_ticks_usec()
		times.append((now - last) / 1000.0)
		last = now
	times.sort()
	var mean: float = times.reduce(func(a: float, b: float) -> float: return a + b, 0.0) / times.size()
	print("DEMO frames %s: %d units, mean %.1f ms (%.0f fps), 95th %.1f ms, worst %.1f ms" % [what,
		get_tree().get_nodes_in_group("units").size(), mean, 1000.0 / mean,
		times[int(times.size() * 0.95)], times[-1]])

extends SceneTree

# Renders contact sheets of the flight clips: one row per clip, one column
# per moment, from the side and from three-quarters front.
#   godot --path . --rendering-driver opengl3 -s res://tools/_probe/flight_capture.gd -- --out=<dir>

const CELL := Vector2i(220, 300)
const CLIPS := [
	["Flight/Takeoff", [0.0, 0.1, 0.18, 0.27, 0.36, 0.5, 0.65, 0.8]],
	["Flight/Hover", [0.0, 0.375, 0.75, 1.125, 1.5, 1.875, 2.25, 2.625]],
	["Flight/Fly_Fwd", [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4]],
	["Flight/Land", [0.0, 0.08, 0.16, 0.25, 0.35, 0.45, 0.55, 0.7]],
]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var out := "res://"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.substr(6)
	root.size = CELL

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.32, 0.34, 0.38)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(sun)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = PlaneMesh.new()
	floor_mesh.mesh.size = Vector2(4, 4)
	root.add_child(floor_mesh)

	var model: Node3D = load("res://scenes/character_models/placeholder_model.tscn").instantiate()
	root.add_child(model)
	var player: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	var library: AnimationLibrary = load("res://assets/flight_animations.tres")
	if player.has_animation_library("Flight"):
		player.remove_animation_library("Flight")
	player.add_animation_library("Flight", library)

	var camera := Camera3D.new()
	camera.fov = 40
	root.add_child(camera)

	for view in [["side", Vector3(4.6, 1.2, 0)], ["front", Vector3(2.4, 1.3, 3.8)]]:
		camera.position = view[1]
		camera.look_at(Vector3(0, 1.0, 0))
		var sheet := Image.create(CELL.x * 8, CELL.y * CLIPS.size(), false, Image.FORMAT_RGBA8)
		for row in CLIPS.size():
			var clip: String = CLIPS[row][0]
			var times: Array = CLIPS[row][1]
			for col in times.size():
				player.play(clip)
				player.seek(times[col], true)
				player.pause()
				await process_frame
				await process_frame
				await RenderingServer.frame_post_draw
				var shot := root.get_texture().get_image()
				shot.convert(Image.FORMAT_RGBA8)
				sheet.blit_rect(shot, Rect2i(Vector2i.ZERO, CELL), Vector2i(col * CELL.x, row * CELL.y))
		var path: String = out.path_join("flight_%s.png" % view[0])
		sheet.save_png(path)
		print("flight capture: ", path)
	quit()

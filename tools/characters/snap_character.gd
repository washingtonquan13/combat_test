extends SceneTree

# Close-up pictures of a character model under the quarry's light, to judge
# a change to skin, hair or face without playing.
#
#   godot --path . -s tools/characters/snap_character.gd -- --out <dir>
#       [--model res://scenes/character_models/cc_male_model.tscn]
#       [--tag after] [--light soft] [--wear res://...wearable.tres ...]
#
# Needs a window: headless Godot draws nothing.

const ENV := "res://world/goblin_quarry/quarry_environment.tres"
# name, camera offset from the head (in the model's frame, +z its front),
# look offset from the head, fov.
const VIEWS := [
	["face", Vector3(0.0, 0.02, 0.55), Vector3(0.0, 0.0, 0.0), 30.0],
	["eyes", Vector3(0.1, 0.0, 0.4), Vector3(0.03, -0.005, 0.07), 9.0],
	["eye_side", Vector3(0.4, 0.0, 0.26), Vector3(0.035, -0.005, 0.1), 7.0],
	["three_quarter", Vector3(0.38, 0.04, 0.42), Vector3(0.0, -0.01, 0.0), 30.0],
	["profile_back", Vector3(-0.5, 0.06, -0.25), Vector3(0.0, 0.0, 0.0), 32.0],
	["bust", Vector3(0.25, -0.05, 1.3), Vector3(0.0, -0.25, 0.0), 32.0],
	["body", Vector3(0.6, -0.6, 3.2), Vector3(0.0, -0.75, 0.0), 35.0],
	["feet", Vector3(0.5, -1.2, 1.0), Vector3(0.0, -1.5, 0.0), 30.0],
	["feet_side", Vector3(1.1, -1.45, 0.1), Vector3(0.0, -1.5, 0.0), 30.0],
]


func _initialize() -> void:
	_run.call_deferred()


func _arg(name: String, fallback := "") -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _run() -> void:
	var out := _arg("--out", "user://")
	var tag := _arg("--tag", "snap")
	var model_path := _arg("--model", "res://scenes/character_models/cc_male_model.tscn")
	root.size = Vector2i(1200, 900)

	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = load(ENV)
	world.add_child(env)
	# The quarry's sun (see bake_goblin_quarry.gd), turned so it lights the
	# face from the camera's side.
	var sun := DirectionalLight3D.new()
	sun.basis = Basis.from_euler(Vector3(deg_to_rad(-38.0), deg_to_rad(28.0), 0.0))
	sun.light_color = Color(1, 0.93, 0.8)
	sun.light_energy = 2.3
	sun.shadow_blur = 1.5
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.92
	sun.directional_shadow_max_distance = 20.0
	world.add_child(sun)
	# --light soft adds a fill and a rim, as a portrait or dialogue shot would,
	# to tell a lighting problem from a mesh or shading one.
	if _arg("--light") == "soft":
		sun.shadow_blur = 4.0
		sun.shadow_opacity = 0.7
		var fill := DirectionalLight3D.new()
		fill.basis = Basis.from_euler(Vector3(deg_to_rad(-15.0), deg_to_rad(-60.0), 0.0))
		fill.light_color = Color(0.85, 0.9, 1.0)
		fill.light_energy = 0.8
		world.add_child(fill)
		var rim := DirectionalLight3D.new()
		rim.basis = Basis.from_euler(Vector3(deg_to_rad(-25.0), deg_to_rad(160.0), 0.0))
		rim.light_energy = 1.2
		world.add_child(rim)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.32, 0.29, 0.24)
	ground_mat.roughness = 1.0
	ground.material_override = ground_mat
	world.add_child(ground)

	var model: Node3D = (load(model_path) as PackedScene).instantiate()
	world.add_child(model)
	# The highlight is hidden in play until hovered.
	for hidden in ["HighlightMesh"]:
		if model.has_node(hidden):
			(model.get_node(hidden) as Node3D).visible = false
	# --wear dresses the model, once per item given, as UnitWearables would.
	var worn: Array[Wearable] = []
	var args := OS.get_cmdline_user_args()
	for k in args.size() - 1:
		if args[k] == "--wear":
			worn.append(load(args[k + 1]) as Wearable)
	for child in model.get_children():
		if child is CCLook:
			child.wear(worn)
	var player := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player and player.has_animation("Idle"):
		player.play("Idle")
	var skeleton := model.find_child("GeneralSkeleton", true, false) as Skeleton3D
	for i in 8:
		await process_frame
	var head := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
	# The face sits a little above and in front of the head bone.
	var face := head.origin + Vector3(0.0, 0.03, 0.04)

	var cam := Camera3D.new()
	cam.near = 0.02
	world.add_child(cam)
	cam.make_current()
	for view: Array in VIEWS:
		cam.fov = view[3]
		cam.look_at_from_position(face + view[1], face + view[2])
		# Shadows, fog and the temporal effects need a few frames to settle.
		for i in 24:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		var path := out.path_join("%s_%s_%s.png" % [model.name, view[0], tag])
		img.save_png(path)
		print("saved ", path)
	quit(0)

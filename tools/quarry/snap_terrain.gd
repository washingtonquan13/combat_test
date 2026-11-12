extends SceneTree

# Pictures of the baked quarry ground from a few fixed cameras, to judge a
# change to the ground's look without playing.
#
#   godot --path . -s tools/quarry/snap_terrain.gd -- --out <dir> [--tag after]
#       [--maps <dir>]   read terrain_relief.png and terrain_masks.png from
#                        here rather than the imported ones
#       [--plain]        the ground without the relief maps
#
# Needs a window: headless Godot draws nothing.

const TERRAIN := "res://world/goblin_quarry/terrain.scn"
const ENV := "res://world/goblin_quarry/quarry_environment.tres"
# x0, z0, width, depth of the maps, metres: the bake's height grid.
const RECT := Rect2(-64.0, -104.0, 128.0, 188.0)
# name, camera, target.
const VIEWS := [
	["field", Vector3(-3.0, 8.5, -1.0), Vector3(-4.5, -2.8, -14.0)],
	["camp", Vector3(5.0, 5.0, -37.0), Vector3(0.0, -6.1, -48.0)],
	["rim", Vector3(34.0, 14.0, 8.0), Vector3(0.0, -4.0, -32.0)],
	["low", Vector3(-22.0, 0.2, -5.0), Vector3(2.0, -3.0, -19.0)],
	["ramp", Vector3(24.0, 4.0, -28.0), Vector3(11.0, -5.0, -44.0)],
	["south", Vector3(6.0, 6.0, -56.0), Vector3(-6.0, -5.0, -70.0)],
]


func _initialize() -> void:
	_run.call_deferred()


func _arg(name: String, fallback := "") -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _map(dir: String, file: String) -> Texture2D:
	if dir == "":
		return load("res://world/goblin_quarry/" + file)
	var img := Image.load_from_file(dir.path_join(file))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _run() -> void:
	var out := _arg("--out", "user://")
	var tag := _arg("--tag", "snap")
	var plain := OS.get_cmdline_user_args().has("--plain")
	root.size = Vector2i(1600, 900)

	var world := Node3D.new()
	root.add_child(world)
	var terrain: Node3D = (load(TERRAIN) as PackedScene).instantiate()
	world.add_child(terrain)
	var env := WorldEnvironment.new()
	env.environment = load(ENV)
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.basis = Basis.from_euler(Vector3(deg_to_rad(-38.0), deg_to_rad(-62.0), 0.0))
	sun.light_color = Color(1, 0.93, 0.8)
	sun.light_energy = 2.3
	sun.light_angular_distance = 1.0
	sun.light_volumetric_fog_energy = 1.4
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.92
	sun.directional_shadow_max_distance = 75.0
	world.add_child(sun)

	# The ground's material and the grass's, which read the same maps.
	var mats: Array[ShaderMaterial] = [(terrain.get_node("Ground").get_child(0) as MeshInstance3D).material_override]
	for patch in terrain.get_node("Grass").get_children():
		var m := (patch as MultiMeshInstance3D).multimesh.mesh.surface_get_material(0) as ShaderMaterial
		if m and not mats.has(m):
			mats.append(m)
	var maps := _arg("--maps")
	var relief := null if plain else _map(maps, "terrain_relief.png")
	var masks := null if plain else _map(maps, "terrain_masks.png")
	for mat in mats:
		if not plain:
			mat.set_shader_parameter("terrain_relief", relief)
			mat.set_shader_parameter("terrain_masks", masks)
			mat.set_shader_parameter("relief_rect", Vector4(RECT.position.x, RECT.position.y, 1.0 / RECT.size.x, 1.0 / RECT.size.y))
		for p in ["relief_amount", "occlusion_amount", "shape_paint"]:
			mat.set_shader_parameter(p, 0.0 if plain else float(_arg("--" + p, "1.0")))

	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.far = 400.0
	world.add_child(cam)
	cam.make_current()
	for view: Array in VIEWS:
		cam.look_at_from_position(view[1], view[2])
		# Shadows, fog and the temporal effects need a few frames to settle.
		for i in 24:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		var path := out.path_join("%s_%s.png" % [view[0], tag])
		img.save_png(path)
		print("saved ", path)
	quit(0)

extends SceneTree

# Pictures of the baked cave rock from a few fixed cameras, under the area
# scene's own lights and fog, to judge a change to the rock's look without
# playing.
#
#   godot --path . -s tools/cave/snap_cave.gd -- --out <dir> [--tag after]
#
# Needs a window: headless Godot draws nothing.

const ROCK := "res://world/spider_cave/rock.scn"
# name, camera, target.
const VIEWS := [
	["chamber", Vector3(4.0, 2.2, 3.0), Vector3(-2.0, 2.5, -14.0)],
	["ledge", Vector3(-5.0, 3.0, -11.0), Vector3(-14.0, 3.6, -4.0)],
	["tunnel", Vector3(0.0, 2.0, 23.0), Vector3(0.0, 1.5, 8.0)],
	["wall", Vector3(5.0, 1.8, -7.0), Vector3(15.0, 3.5, -10.0)],
	["roof", Vector3(-1.0, 1.5, -4.0), Vector3(4.0, 10.0, -12.0)],
	["squeeze", Vector3(13.0, 1.4, 11.0), Vector3(13.5, 1.2, 2.0)],
]
# The area scene's lights: position, colour, energy, range, attenuation.
const FUNGUS := [
	Vector3(-14.5, 4.4, -6.0), Vector3(11.0, 0.6, -22.0), Vector3(-11.0, 3.2, 14.0),
	Vector3(13.5, 0.8, 7.0), Vector3(-4.0, 0.6, -15.0),
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
	root.size = Vector2i(1600, 900)

	var world := Node3D.new()
	root.add_child(world)
	world.add_child((load(ROCK) as PackedScene).instantiate())

	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.01, 0.012, 0.015)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.32, 0.36, 0.42)
	e.ambient_light_energy = 1.0
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.1
	e.ssao_enabled = true
	e.glow_enabled = true
	e.glow_intensity = 0.6
	e.glow_bloom = 0.05
	e.volumetric_fog_enabled = true
	e.volumetric_fog_density = 0.012
	e.volumetric_fog_albedo = Color(0.8, 0.82, 0.85)
	e.volumetric_fog_length = 48.0
	var env := WorldEnvironment.new()
	env.environment = e
	world.add_child(env)

	var sky := SpotLight3D.new()
	sky.transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3(6.6, 14.6, -13.6))
	sky.light_color = Color(1, 0.94, 0.82)
	sky.light_energy = 9.0
	sky.shadow_enabled = true
	sky.spot_range = 22.0
	sky.spot_attenuation = 0.4
	sky.spot_angle = 24.0
	sky.spot_angle_attenuation = 0.6
	world.add_child(sky)
	var day := OmniLight3D.new()
	day.position = Vector3(0, 2.2, 29)
	day.light_color = Color(1, 0.93, 0.8)
	day.light_energy = 2.5
	day.light_volumetric_fog_energy = 2.0
	day.shadow_enabled = true
	day.omni_range = 13.0
	day.omni_attenuation = 1.6
	world.add_child(day)
	for p: Vector3 in FUNGUS:
		var f := OmniLight3D.new()
		f.position = p
		f.light_color = Color(0.35, 1, 0.75)
		f.light_energy = 1.6
		f.omni_range = 6.0
		f.omni_attenuation = 1.4
		world.add_child(f)

	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.far = 200.0
	world.add_child(cam)
	cam.make_current()
	for view: Array in VIEWS:
		cam.look_at_from_position(view[1], view[2])
		for i in 24:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := out.path_join("%s_%s.png" % [view[0], tag])
		root.get_texture().get_image().save_png(path)
		print("saved ", path)
	quit(0)

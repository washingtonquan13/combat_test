extends Node3D
## Ruins kit test: pieces from assets/level/ruins_kit/pieces kitbashed by hand
## in ruins_test.tscn, lit and framed. Play the scene to look at it (the camera
## orbits); run with `-- <dir>` to save two shots there and quit.

var _cam: Camera3D
var _t := 0.0
var _out := ""


func _ready() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.36, 0.37, 0.3)
	gm.roughness = 1.0
	ground.material_override = gm
	ground.position = Vector3(7, -0.01, -4)
	add_child(ground)
	_cam = Camera3D.new()
	_cam.fov = 50
	add_child(_cam)
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_aim(0.6)


func _aim(a: float) -> void:
	var c := Vector3(7, 2.5, -4)
	_cam.position = c + Vector3(sin(a) * 19.0, 8.0, cos(a) * 19.0)
	_cam.look_at(c)


func _process(delta: float) -> void:
	_t += delta
	if _out == "":
		_aim(0.6 + _t * 0.25)
		return
	if Engine.get_process_frames() == 30:
		get_viewport().get_texture().get_image().save_png(_out.path_join("ruins_a.png"))
		_aim(0.6 + PI)
	elif Engine.get_process_frames() == 60:
		get_viewport().get_texture().get_image().save_png(_out.path_join("ruins_b.png"))
		get_tree().quit()

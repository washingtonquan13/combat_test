extends Node3D
## Side by side, NOT a test: the hero on the current idle (Mixamo's Standing
## Idle, left) and on the Motifect pack's idle_neutral (right), both raw
## from their retargeted takes (tools/locomotion/takes/), looping, so the two
## can be judged by eye before anything lands in the game's set.
##   Open tools/idle_compare_demo.tscn and run it (F6). Mouse wheel zooms,
##   left/right arrows orbit, 1/2/3 pick both / Mixamo / Motifect close up.

const MODEL := "res://scenes/character_models/cc_male_model.tscn"
const TAKES := {
	"Mixamo  (current)": ["res://tools/locomotion/takes/mixamo.glb", "idle"],
	"Motifect  idle_neutral": ["res://tools/locomotion/takes/motifect.glb", "idle"],
}
const GAP := 1.6

var _camera: Camera3D
var _yaw := 0.0
var _distance := 3.6
var _focus := Vector3(0, 1.0, 0)


func _ready() -> void:
	_stage()
	var i := 0
	for label: String in TAKES:
		var x := (i - 0.5) * GAP
		_hero(label, TAKES[label][0], TAKES[label][1], Vector3(x, 0, 0))
		i += 1
	_place_camera()


func _hero(label: String, takes_path: String, clip: String, at: Vector3) -> void:
	var model: Node3D = (load(MODEL) as PackedScene).instantiate()
	add_child(model)
	model.position = at
	var player: AnimationPlayer = model.find_children("*", "AnimationPlayer", true, false)[0]
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	var takes: Node = (load(takes_path) as PackedScene).instantiate()
	var take_player: AnimationPlayer = takes.find_children("*", "AnimationPlayer", true, false)[0]
	var anim: Animation = take_player.get_animation(clip).duplicate()
	takes.free()
	# The take's tracks name its own skeleton; point them at the hero's.
	var to_skeleton := str(player.get_node(player.root_node).get_path_to(skeleton))
	for t in anim.get_track_count():
		var path := anim.track_get_path(t)
		anim.track_set_path(t, NodePath(to_skeleton + ":" + path.get_concatenated_subnames()))
	anim.loop_mode = Animation.LOOP_LINEAR
	var library := AnimationLibrary.new()
	library.add_animation(&"idle", anim)
	player.add_animation_library(&"Compare", library)
	player.play(&"Compare/idle")
	var text := Label3D.new()
	text.text = "%s\n%.1f s loop" % [label, anim.length]
	text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	text.font_size = 32
	text.pixel_size = 0.004
	text.position = at + Vector3(0, 2.05, 0)
	add_child(text)


func _stage() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.32, 0.34, 0.38)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.57, 0.62)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(12, 12)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.42, 0.4)
	ground.material_override = mat
	add_child(ground)
	_camera = Camera3D.new()
	_camera.fov = 40
	add_child(_camera)


func _place_camera() -> void:
	var dir := Vector3(sin(deg_to_rad(_yaw)), 0.12, cos(deg_to_rad(_yaw))).normalized()
	_camera.position = _focus + dir * _distance
	_camera.look_at(_focus)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(0.8, _distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(10.0, _distance / 0.9)
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_LEFT: _yaw -= 15.0
			KEY_RIGHT: _yaw += 15.0
			KEY_1: _focus = Vector3(0, 1.0, 0); _distance = 3.6
			KEY_2: _focus = Vector3(-GAP * 0.5, 1.0, 0); _distance = 2.0
			KEY_3: _focus = Vector3(GAP * 0.5, 1.0, 0); _distance = 2.0
	_place_camera()

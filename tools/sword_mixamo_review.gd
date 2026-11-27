extends Node3D

# Review reel for the one-handed sword candidates from Mixamo's Sword And
# Shield Pack (tools/locomotion/takes/mixamo_duel.glb, made by
# tools/locomotion/mixamo_retarget.py with DUEL=1): one clip a page on
# the male hero in the Ranger's Garb with the iron sword in hand, each page played from the
# front three-quarter, from the side and from behind; then quits. The
# takes keep their own travel here; the camera follows the body.
#
#   tools/render_movie.sh res://tools/sword_mixamo_review.tscn recordings/sword/mixamo_review.avi

const TAKES := "res://tools/locomotion/takes/mixamo_duel.glb"
const MODEL := "res://scenes/character_models/cc_male_model.tscn"
const SWORD := "res://scenes/weapons/iron_sword.tscn"
const YAWS := [-35.0, 90.0, 160.0]
const MAX_LEN := 6.0

const GARB := "res://data/items/ranger_garb.tres"
const CLIPS := ["ss_slash_1", "ss_slash_2", "ss_slash_3", "ss_slash_4", "ss_slash_5",
	"ss_attack_1", "ss_attack_2", "ss_attack_3", "ss_attack_4", "thrust_stabbing", "ss_idle_1", "ss_idle_3"]

var _lib: AnimationLibrary
var _title: Label3D
var _cam: Camera3D


func _ready() -> void:
	var src: Node = (load(TAKES) as PackedScene).instantiate()
	var player: AnimationPlayer = src.find_children("*", "AnimationPlayer", true, false)[0]
	_lib = AnimationLibrary.new()
	for lib_name in player.get_animation_library_list():
		var lib := player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			var anim: Animation = lib.get_animation(anim_name).duplicate()
			for t in anim.get_track_count():
				var path := String(anim.track_get_path(t))
				anim.track_set_path(t, NodePath("%GeneralSkeleton:" + path.get_slice(":", 1)))
			anim.loop_mode = Animation.LOOP_NONE
			_lib.add_animation(anim_name, anim)
	src.free()
	print("REVIEW clips: ", _lib.get_animation_list())

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.32, 0.34, 0.38)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment.ambient_light_energy = 0.7
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.45, 0.42)
	ground.material_override = mat
	add_child(ground)
	_cam = Camera3D.new()
	_cam.fov = 40
	add_child(_cam)
	_title = Label3D.new()
	_title.font_size = 96
	_title.pixel_size = 0.004
	_title.outline_size = 16
	add_child(_title)

	for clip: String in CLIPS:
		await _show(clip)
	get_tree().quit()


func _show(clip: String) -> void:
	var model: CharacterModel = (load(MODEL) as PackedScene).instantiate()
	add_child(model)
	for child in model.get_children():
		if child is CCLook:
			var worn: Array[Wearable] = [(load(GARB) as GearItem).wearable]
			child.wear(worn)
	if is_instance_valid(model.main_hand_grip):
		model.main_hand_grip.add_child((load(SWORD) as PackedScene).instantiate())
	var player: AnimationPlayer = model.get_node("Body/AnimationPlayer")
	player.add_animation_library("review", _lib)
	var skeleton: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	var hips := skeleton.find_bone("Hips")
	var length := minf(_lib.get_animation(clip).length, MAX_LEN)
	print("REVIEW ", clip, " length ", _lib.get_animation(clip).length)
	player.play("review/" + clip)
	player.seek(0.0, true)
	await get_tree().process_frame
	for yaw: float in YAWS:
		model.rotation_degrees.y = yaw
		player.stop()
		player.play("review/" + clip)
		player.seek(0.0, true)
		var clock := 0.0
		while clock < length + 0.4:
			var at: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(hips).origin
			at.y = 0.0
			_cam.position = at + Vector3(0, 1.5, 5.2)
			_cam.look_at(at + Vector3(0, 0.95, 0))
			_title.text = clip
			_title.position = at + Vector3(0, 2.45, 0)
			await get_tree().process_frame
			clock += get_process_delta_time()
	model.queue_free()

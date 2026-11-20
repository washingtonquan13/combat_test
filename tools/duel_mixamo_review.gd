extends Node3D

# Review reel for the duel's Mixamo candidates (tools/locomotion/takes/
# mixamo_duel.glb, made by tools/locomotion/mixamo_retarget.py with DUEL=1):
# each page shows one part of the duel, every candidate side by side on the
# male CC body with its name over it, played twice; then quits.
#
#   tools/render_movie.sh res://tools/duel_mixamo_review.tscn recordings/bg3/mixamo_review.avi
#
# No sword in the hand: this is for judging the body.

const TAKES := "res://tools/locomotion/takes/mixamo_duel.glb"
const MODEL := "res://scenes/character_models/cc_male_model.tscn"
const SPACING := 2.2
const PLAYS := 2
const MAX_LEN := 6.0

const PAGES := [
	["The attacker's chop", ["gs_downward_slash", "ss_slash_1", "ss_slash_3", "ss_slash_5", "ss_attack_4"]],
	["More attacks (some travel)", ["ss_attack_1", "ss_attack_2", "ss_attack_3", "ss_slash_2", "ss_slash_4"]],
	["The hero's thrust", ["thrust_stabbing", "ss_kick_1"]],
	["The attacker's death", ["death_back", "death_fwd", "death_fall_fwd", "ss_death_1", "ss_death_2"]],
	["The victim", ["victim_terrified", "ss_impact_1", "ss_impact_2", "ss_impact_3"]],
	["The hero's leap", ["gs_jump_attack", "ss_jump_1", "ss_jump_2"]],
	["Idles", ["ss_idle_1", "ss_idle_2", "ss_idle_3", "ss_idle_4"]],
]

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

	for page in PAGES:
		await _show(page[0], page[1])
	get_tree().quit()


func _show(title: String, clips: Array) -> void:
	var holder := Node3D.new()
	add_child(holder)
	var width := (clips.size() - 1) * SPACING
	var length := 0.0
	var players: Array[AnimationPlayer] = []
	for i in clips.size():
		var model: Node3D = (load(MODEL) as PackedScene).instantiate()
		holder.add_child(model)
		model.position = Vector3(i * SPACING - width / 2.0, 0, 0)
		var player: AnimationPlayer = model.get_node("Body/AnimationPlayer")
		if not player.has_animation_library("review"):
			player.add_animation_library("review", _lib)
		players.append(player)
		length = maxf(length, minf(_lib.get_animation(clips[i]).length, MAX_LEN))
		var label := Label3D.new()
		label.text = clips[i]
		label.font_size = 64
		label.pixel_size = 0.004
		label.outline_size = 12
		label.position = model.position + Vector3(0, 2.15, 0)
		holder.add_child(label)
	_title.text = title
	_title.position = Vector3(0, 2.55, 0)
	var dist := maxf(5.0, width * 0.78 + 2.6)
	_cam.position = Vector3(0, 1.6, dist)
	_cam.look_at(Vector3(0, 0.95, 0))
	await get_tree().process_frame
	for _play in PLAYS:
		for i in clips.size():
			players[i].stop()
			players[i].play("review/" + clips[i])
			players[i].seek(0.0, true)
		await get_tree().create_timer(length + 0.6).timeout
	holder.queue_free()
	await get_tree().process_frame

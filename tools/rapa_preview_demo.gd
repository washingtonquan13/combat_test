extends Node3D

# Preview of the Rapamotion mage clips on our mannequin, side by side.

const DIR := "res://assets/rapamotion/"
const MODEL := "res://scenes/character_models/placeholder_model.tscn"

var _longest := 0.0


func _ready() -> void:
	var files := Array(DIR_files())
	var env := WorldEnvironment.new(); env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.32, 0.36, 0.42)
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.75); env.environment.ambient_light_energy = 0.6
	add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); sun.shadow_enabled = true; add_child(sun)
	var floor := MeshInstance3D.new(); var pm := PlaneMesh.new(); pm.size = Vector2(30, 30); floor.mesh = pm; add_child(floor)
	var model: Node3D = (load(MODEL) as PackedScene).instantiate()
	add_child(model)
	var sk: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	var skpath := String(model.get_path_to(sk))
	for p in model.find_children("*", "AnimationPlayer", true, false): p.stop(); p.active = false
	for t in model.find_children("*", "AnimationTree", true, false): t.active = false
	var lib := AnimationLibrary.new()
	var player := AnimationPlayer.new(); model.add_child(player)
	player.root_node = NodePath("..")
	var label := Label3D.new(); label.pixel_size = 0.0035; label.position = Vector3(0, 2.25, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED; label.outline_size = 10; add_child(label)
	var anims := []
	for i in files.size():
		var f: String = files[i]
		var src: Node = (load(DIR + f) as PackedScene).instantiate()
		var sp: AnimationPlayer = src.find_children("*", "AnimationPlayer", true, false)[0]
		var anim: Animation = sp.get_animation(sp.get_animation_list()[0]).duplicate(true)
		src.free()
		for tr in range(anim.get_track_count() - 1, -1, -1):
			var bone := String(anim.track_get_path(tr)).get_slice(":", 1)
			if sk.find_bone(bone) < 0 or bone == "Root":
				anim.remove_track(tr); continue
			anim.track_set_path(tr, NodePath(skpath + ":" + bone))
		lib.add_animation(StringName("c%d" % i), anim)
		anims.append([f.trim_prefix("AS_Mage_").trim_suffix("_UE4.fbx"), anim.length])
	player.add_animation_library(&"", lib)
	var cam := Camera3D.new(); add_child(cam)
	cam.position = Vector3(3.2, 1.6, 3.4); cam.look_at(Vector3(0, 1.0, 0)); cam.fov = 50; cam.make_current()
	for i in anims.size():
		label.text = "%d. %s" % [i + 1, anims[i][0]]
		player.play(StringName("c%d" % i))
		await get_tree().create_timer(anims[i][1]).timeout
	get_tree().quit()


func DIR_files() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(DIR):
		if f.ends_with(".fbx"): out.append(f)
	return out

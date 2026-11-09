extends SceneTree

# Puts the approved clips from assets/humanoid/humanoid_clips.glb into the
# animation libraries the model already plays, replacing the entry of the same
# name, so no scene or motion key has to change. export_humanoid.py makes the
# glb; carried_clips.py names the clips.
#
#   godot --headless --path . -s res://tools/humanoid/carry_clips.gd
#
# A replaced clip keeps the tracks and loop mode of the one it replaces: every
# bone's rotation and the hips' position. The glb keys every channel of every
# bone, but position and scale on the other bones only restate the rest pose.

const BAKED: String = "res://assets/humanoid/humanoid_clips.glb"
const MOMENTS: String = "res://assets/humanoid/humanoid_clips_moments.json"
const MODEL: String = "res://assets/UAL1_Standard.glb"
const TARGETS: Dictionary = {
	"res://assets/flight_animations.tres": ["Hover", "Fly_Fwd", "Takeoff", "Land"],
	"res://assets/weapon_animations.tres": [
		"Breath", "Breath_Hold", "Breath_Out", "Punch", "Claw",
		"Stance_Bow", "Bow_Shot",
		"Stance_Crossbow", "Crossbow_Shot", "Reload_Crossbow",
		"Stance_Longgun", "Rifle_Burst", "Reload_Rifle",
	],
}

func _init() -> void:
	var baked: AnimationLibrary = load(BAKED)
	var moments: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MOMENTS))
	var model: Node = (load(MODEL) as PackedScene).instantiate()
	var skeleton: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	var failed := false
	for path: String in TARGETS:
		var library: AnimationLibrary = load(path)
		for clip: String in TARGETS[path]:
			var old := library.get_animation(clip)
			var made := _carried(baked.get_animation(clip), old, skeleton, clip)
			failed = failed or made == null
			if made == null:
				continue
			print("CARRY   old methods ", _methods(old), " new moments ", moments.get(clip, {}))
			for method: String in moments.get(clip, {}):
				_key_method(made, method, moments[clip][method])
			library.remove_animation(clip)
			library.add_animation(clip, made)
		if failed:
			push_error("carry_clips: not saving %s" % path)
			continue
		print("CARRY saved ", path, " err ", _save_keeping_uid(library, path))
	model.free()
	quit()


# A save from a script drops the file's uid, and scenes refer to the file by it.
func _save_keeping_uid(library: AnimationLibrary, path: String) -> Error:
	var uid := FileAccess.get_file_as_string(path).get_slice("
", 0).get_slice(" uid=", 1).trim_suffix("]")
	var err := ResourceSaver.save(library, path)
	var text := FileAccess.get_file_as_string(path)
	var end := text.find("]")
	if err == OK and uid != "" and not text.substr(0, end).contains(" uid="):
		FileAccess.open(path, FileAccess.WRITE).store_string(text.insert(end, " uid=" + uid))
	return err


# A copy of the baked clip with exactly the old clip's bone tracks.
func _carried(baked: Animation, old: Animation, skeleton: Skeleton3D, clip: String) -> Animation:
	var made := Animation.new()
	made.length = baked.length
	made.loop_mode = old.loop_mode
	var worst := 0.0
	for track in baked.get_track_count():
		var type := baked.track_get_type(track)
		var path := baked.track_get_path(track)
		if old.find_track(path, type) >= 0:
			var at := made.add_track(type)
			made.track_set_path(at, path)
			made.track_set_interpolation_type(at, baked.track_get_interpolation_type(track))
			for key in baked.track_get_key_count(track):
				made.track_insert_key(at, baked.track_get_key_time(track, key), baked.track_get_key_value(track, key))
		elif type == Animation.TYPE_POSITION_3D:
			worst = maxf(worst, _drift(baked, track, skeleton))
	var missing := 0
	for track in old.get_track_count():
		if old.track_get_type(track) != Animation.TYPE_METHOD and made.find_track(old.track_get_path(track), old.track_get_type(track)) < 0:
			missing += 1
			push_error("carry_clips: %s has no %s" % [clip, old.track_get_path(track)])
	print("CARRY ", clip, " length ", made.length, " loop ", made.loop_mode, " tracks ", made.get_track_count(), " missing ", missing, " dropped-position drift ", snappedf(worst, 0.0001))
	return null if missing > 0 else made


func _methods(anim: Animation) -> Dictionary:
	var found := {}
	for track in anim.get_track_count():
		if anim.track_get_type(track) == Animation.TYPE_METHOD:
			for key in anim.track_get_key_count(track):
				var name: String = anim.method_track_get_name(track, key)
				found[name] = found.get(name, []) + [snappedf(anim.track_get_key_time(track, key), 0.001)]
	return found


# How far a dropped position track strays from the bone's rest position.
func _drift(baked: Animation, track: int, skeleton: Skeleton3D) -> float:
	var bone := skeleton.find_bone(String(baked.track_get_path(track).get_subname(0)))
	if bone < 0:
		return 0.0
	var rest := skeleton.get_bone_rest(bone).origin
	var worst := 0.0
	for key in baked.track_get_key_count(track):
		worst = maxf(worst, rest.distance_to(baked.track_get_key_value(track, key)))
	return worst


func _key_method(anim: Animation, method: String, times: Array) -> void:
	var track := anim.find_track(NodePath(".."), Animation.TYPE_METHOD)
	if track < 0:
		track = anim.add_track(Animation.TYPE_METHOD)
		anim.track_set_path(track, NodePath(".."))
	for time in times:
		anim.track_insert_key(track, float(time), {"method": StringName(method), "args": []})

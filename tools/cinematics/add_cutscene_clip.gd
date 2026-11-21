extends SceneTree
## Puts one clip from an imported FBX into assets/cutscene_animations.tres,
## the `Cutscene` library the character models carry, so a cutscene's
## Animation Playback track can name it (`Cutscene/<name>`).
##
## The FBX must already import onto the humanoid skeleton (a BoneMap in its
## import settings, as assets/cinematics/clips/*.fbx.import has).
##
## The clip is made in place: the hips' sideways and forward travel is taken
## out, so the role's own position keys decide where the body goes. A clip that
## falls by itself (it starts standing above its own ground) takes
## `drop=<takeoff>,<landing>,<metres>`: that height is taken out between those
## two times, so the feet are on the role's node before the takeoff and after
## the landing, and the role's keys carry the whole fall.
##
##   godot --headless --path . -s res://tools/cinematics/add_cutscene_clip.gd -- \
##       res://assets/cinematics/clips/jump_down_menacing.fbx jump_down drop=0.45,1.35,0.85

const LIBRARY_PATH := "res://assets/cutscene_animations.tres"


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <fbx> <clip name> [drop=<takeoff>,<landing>,<metres>]")
		quit(1)
		return
	var takeoff: float = -1.0
	var landing: float = -1.0
	var fall: float = 0.0
	for a in args.slice(2):
		if a.begins_with("drop="):
			var parts: PackedStringArray = a.trim_prefix("drop=").split(",")
			takeoff = parts[0].to_float()
			landing = parts[1].to_float()
			fall = parts[2].to_float()

	var scene: Node = (load(args[0]) as PackedScene).instantiate()
	var player: AnimationPlayer = scene.find_child("AnimationPlayer", true, false)
	var source: Animation = player.get_animation(player.get_animation_list()[0])
	var clip: Animation = source.duplicate(true)
	clip.resource_name = args[1]
	clip.loop_mode = Animation.LOOP_NONE
	_make_in_place(clip, fall, takeoff, landing)
	scene.free()

	var library: AnimationLibrary
	if ResourceLoader.exists(LIBRARY_PATH):
		library = load(LIBRARY_PATH)
	else:
		library = AnimationLibrary.new()
	if library.has_animation(args[1]):
		library.remove_animation(args[1])
	library.add_animation(args[1], clip)
	var err: Error = ResourceSaver.save(library, LIBRARY_PATH)
	print("%s: %s (%s, %.2f s)" % [LIBRARY_PATH, error_string(err), args[1], clip.length])
	quit(0 if err == OK else 1)


func _make_in_place(clip: Animation, fall: float, takeoff: float, landing: float) -> void:
	for track in clip.get_track_count():
		if clip.track_get_type(track) != Animation.TYPE_POSITION_3D:
			continue
		if not String(clip.track_get_path(track)).ends_with(":Hips"):
			continue
		var first: Vector3 = clip.track_get_key_value(track, 0)
		for key in clip.track_get_key_count(track):
			var time: float = clip.track_get_key_time(track, key)
			var value: Vector3 = clip.track_get_key_value(track, key)
			value.z = first.z
			if takeoff >= 0.0:
				var fallen: float = clampf(inverse_lerp(takeoff, landing, time), 0.0, 1.0)
				value.y -= fall * (1.0 - fallen)
			clip.track_set_key_value(track, key, value)

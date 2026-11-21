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
## `range=<from>,<to>` keeps only that part of the clip (times in the FBX's
## own clip, as `drop=` is), so one take can be split into parts a timeline
## keys one after another: a jump as takeoff, fall and landing, where the fall
## lasts as long as the role's keys say.
##
## `pose=<time>` makes a looping clip that holds the pose at that time: the
## middle of a jump, which then lasts as long as the timeline leaves it.
##
##   godot --headless --path . -s res://tools/cinematics/add_cutscene_clip.gd -- \
##       res://assets/cinematics/clips/jump_down_menacing.fbx jump_down drop=0.45,1.3,0.85
##   ... jump_fall drop=0.45,1.3,0.85 range=0.45,1.3

const LIBRARY_PATH := "res://assets/cutscene_animations.tres"


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <fbx> <clip name> [drop=<takeoff>,<landing>,<metres>] [range=<from>,<to> | pose=<time>]")
		quit(1)
		return
	var takeoff: float = -1.0
	var landing: float = -1.0
	var fall: float = 0.0
	var from: float = -1.0
	var to: float = -1.0
	var pose: float = -1.0
	for a in args.slice(2):
		if a.begins_with("drop="):
			var parts: PackedStringArray = a.trim_prefix("drop=").split(",")
			takeoff = parts[0].to_float()
			landing = parts[1].to_float()
			fall = parts[2].to_float()
		elif a.begins_with("pose="):
			pose = a.trim_prefix("pose=").to_float()
		elif a.begins_with("range="):
			var ends: PackedStringArray = a.trim_prefix("range=").split(",")
			from = ends[0].to_float()
			to = ends[1].to_float()

	var scene: Node = (load(args[0]) as PackedScene).instantiate()
	var player: AnimationPlayer = scene.find_child("AnimationPlayer", true, false)
	var source: Animation = player.get_animation(player.get_animation_list()[0])
	var clip: Animation = source.duplicate(true)
	clip.resource_name = args[1]
	clip.loop_mode = Animation.LOOP_NONE
	_make_in_place(clip, fall, takeoff, landing)
	if from >= 0.0:
		clip = _part(clip, from, to)
		clip.resource_name = args[1]
	elif pose >= 0.0:
		clip = _part(clip, pose, pose)
		clip.resource_name = args[1]
		clip.length = 0.5
		clip.loop_mode = Animation.LOOP_LINEAR
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


## The clip between two of its times, as a clip of its own starting at 0.
func _part(clip: Animation, from: float, to: float) -> Animation:
	var part := Animation.new()
	part.length = to - from
	part.loop_mode = Animation.LOOP_NONE
	for track in clip.get_track_count():
		var type: Animation.TrackType = clip.track_get_type(track)
		var copy: int = part.add_track(type)
		part.track_set_path(copy, clip.track_get_path(track))
		part.track_set_interpolation_type(copy, clip.track_get_interpolation_type(track))
		part.track_insert_key(copy, 0.0, _value_at(clip, track, type, from))
		for key in clip.track_get_key_count(track):
			var time: float = clip.track_get_key_time(track, key)
			if time > from and time < to:
				part.track_insert_key(copy, time - from, clip.track_get_key_value(track, key))
		part.track_insert_key(copy, to - from, _value_at(clip, track, type, to))
	return part


func _value_at(clip: Animation, track: int, type: Animation.TrackType, time: float) -> Variant:
	match type:
		Animation.TYPE_POSITION_3D:
			return clip.position_track_interpolate(track, time)
		Animation.TYPE_ROTATION_3D:
			return clip.rotation_track_interpolate(track, time)
		Animation.TYPE_SCALE_3D:
			return clip.scale_track_interpolate(track, time)
		Animation.TYPE_BLEND_SHAPE:
			return clip.blend_shape_track_interpolate(track, time)
	return clip.value_track_interpolate(track, time)

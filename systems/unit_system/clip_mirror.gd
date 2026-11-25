class_name ClipMirror
extends RefCounted
## A humanoid clip played by the other side of the body: what the right
## hand did the left does, reflected through the body's middle. For a
## one-handed weapon held in the hand its clip wasn't keyed for (a pistol
## in the off hand). AnimationPhase.mirrored asks for it; UnitAnimator
## puts it in each body's "Mirrored" library, built once per skeleton shape.
##
## Mirrors in model space, through the skeleton's rests, so a rig whose
## left and right bone frames aren't reflections of each other still
## comes out right. Each sampled frame: pose every bone, take its skin
## transform (posed global x rest global inverse), reflect the one of its
## mirror bone (Left <-> Right) across X, put the rest back, and read the
## locals off through the parents. Method tracks (release, impact) and
## anything not on the skeleton are kept as they are.

const REFLECT := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
const FPS := 30.0

## Built mirrors, shared by every body whose skeleton has the same bones and
## rests: clip instance id + skeleton signature -> Animation.
static var _cache := {}


## The mirror of `clip` on `skeleton`, whose bones its tracks name as
## "<path to skeleton>:<bone>". Built once per clip and skeleton shape.
static func mirrored(clip: Animation, skeleton: Skeleton3D) -> Animation:
	var names: Array[String] = []
	var rests: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(bone))
		rests.append(skeleton.get_bone_rest(bone))
	var key := "%d:%d" % [clip.get_instance_id(), str([names, rests]).hash()]
	if not _cache.has(key):
		_cache[key] = _build(clip, skeleton)
	return _cache[key]


static func _build(clip: Animation, skeleton: Skeleton3D) -> Animation:
	var out: Animation = clip.duplicate(true)
	var count: int = skeleton.get_bone_count()
	var tracked := {}  # bone index -> true, for a bone or its mirror tracked
	var has_position := {}
	var bone_tracks: Array[int] = []
	var track_bone := {}  # track index -> bone index, in `clip`
	var prefix: String = ""
	for track in clip.get_track_count():
		var type: Animation.TrackType = clip.track_get_type(track)
		if type != Animation.TYPE_ROTATION_3D and type != Animation.TYPE_POSITION_3D:
			continue
		var path: NodePath = clip.track_get_path(track)
		var bone: int = skeleton.find_bone(path.get_concatenated_subnames())
		if bone == -1:
			continue
		prefix = String(path).get_slice(":", 0)
		bone_tracks.append(track)
		track_bone[track] = bone
		for side in [bone, _mirror_of(skeleton, bone)]:
			tracked[side] = true
			if type == Animation.TYPE_POSITION_3D:
				has_position[side] = true
	# Bone tracks are rebuilt from the samples; the rest are kept.
	bone_tracks.sort()
	for i in range(bone_tracks.size() - 1, -1, -1):
		out.remove_track(bone_tracks[i])

	var rest_global: Array[Transform3D] = []
	rest_global.resize(count)
	for bone in count:
		var parent: int = skeleton.get_bone_parent(bone)
		var rest: Transform3D = skeleton.get_bone_rest(bone)
		rest_global[bone] = rest_global[parent] * rest if parent != -1 else rest

	var rotation_track := {}
	var position_track := {}
	for bone in tracked:
		var path := NodePath("%s:%s" % [prefix, skeleton.get_bone_name(bone)])
		var r: int = out.add_track(Animation.TYPE_ROTATION_3D)
		out.track_set_path(r, path)
		rotation_track[bone] = r
		if has_position.has(bone):
			var p: int = out.add_track(Animation.TYPE_POSITION_3D)
			out.track_set_path(p, path)
			position_track[bone] = p

	var frames: int = maxi(1, ceili(clip.length * FPS))
	for frame in frames + 1:
		var time: float = minf(frame / FPS, clip.length)
		var local: Array[Transform3D] = _sample(clip, skeleton, track_bone, time)
		var global: Array[Transform3D] = []
		global.resize(count)
		for bone in count:
			var parent: int = skeleton.get_bone_parent(bone)
			global[bone] = global[parent] * local[bone] if parent != -1 else local[bone]
		var mirrored_global: Array[Transform3D] = []
		mirrored_global.resize(count)
		for bone in count:
			var other: int = _mirror_of(skeleton, bone)
			var skin: Transform3D = global[other] * rest_global[other].affine_inverse()
			var reflected := Transform3D(REFLECT * skin.basis * REFLECT, REFLECT * skin.origin)
			mirrored_global[bone] = reflected * rest_global[bone]
		for bone in tracked:
			var parent: int = skeleton.get_bone_parent(bone)
			var pose: Transform3D = mirrored_global[bone]
			if parent != -1:
				pose = mirrored_global[parent].affine_inverse() * pose
			out.rotation_track_insert_key(rotation_track[bone], time, pose.basis.orthonormalized().get_rotation_quaternion())
			if position_track.has(bone):
				out.position_track_insert_key(position_track[bone], time, pose.origin)
	return out


## Every bone's local pose at `time`: the clip's where it has a track,
## the rest where it doesn't.
static func _sample(clip: Animation, skeleton: Skeleton3D, track_bone: Dictionary, time: float) -> Array[Transform3D]:
	var local: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		local.append(skeleton.get_bone_rest(bone))
	for track in track_bone:
		var bone: int = track_bone[track]
		var type: Animation.TrackType = clip.track_get_type(track)
		if type == Animation.TYPE_ROTATION_3D:
			local[bone].basis = Basis(clip.rotation_track_interpolate(track, time))
		else:
			local[bone].origin = clip.position_track_interpolate(track, time)
	return local


## The bone on the other side (LeftHand <-> RightHand, thigh_l <-> thigh_r),
## or itself for one down the middle.
static func _mirror_of(skeleton: Skeleton3D, bone: int) -> int:
	var name: String = skeleton.get_bone_name(bone)
	for pair in [["Left", "Right"], ["Right", "Left"], ["_l", "_r"], ["_r", "_l"], [".L", ".R"], [".R", ".L"]]:
		if name.contains(pair[0]):
			var other: int = skeleton.find_bone(name.replace(pair[0], pair[1]))
			if other != -1:
				return other
	return bone

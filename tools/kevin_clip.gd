extends RefCounted

# Reading Kevin Iglesias' clips (assets/kevin_soldier, assets/kevin_melee)
# onto the mannequin: their imports retarget the rig to the humanoid profile,
# so the tracks name our bones; only the hips stand higher.

const PoseBuilder := preload("res://tools/pose_builder.gd")

# Their hips stand 0.980 high, ours 0.917.
const HIPS_SCALE := 0.936


static func source(path: String) -> Animation:
	var scene: Node = (load(path) as PackedScene).instantiate()
	var player: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
	var anim: Animation = player.get_animation(player.get_animation_list()[0]).duplicate(true)
	scene.free()
	return anim


# The clip's frame at t as a pose.
static func frame(poses: PoseBuilder, anim: Animation, t: float) -> Dictionary:
	var pose := {}
	for track in anim.get_track_count():
		var bone := String(anim.track_get_path(track)).get_slice(":", 1)
		match anim.track_get_type(track):
			Animation.TYPE_ROTATION_3D:
				if poses._skeleton.find_bone(bone) >= 0:
					poses._set_local(pose, bone, Basis(anim.rotation_track_interpolate(track, t)))
			Animation.TYPE_POSITION_3D:
				if bone == "Hips":
					pose["_hips"] = anim.position_track_interpolate(track, t) * HIPS_SCALE \
						- poses._bases["neutral"]["hips"]
	return pose


# Which way the clip bends the `side` elbow: from the shoulder-wrist line out
# to the elbow.
static func pole(poses: PoseBuilder, resolved: Dictionary, side: String) -> Vector3:
	var shoulder := poses.bone_transform(resolved, side + "UpperArm").origin
	var elbow := poses.bone_transform(resolved, side + "LowerArm").origin
	var wrist := poses.bone_transform(resolved, side + "Hand").origin
	var line := (wrist - shoulder).normalized()
	var out := elbow - shoulder
	return out - line * out.dot(line)

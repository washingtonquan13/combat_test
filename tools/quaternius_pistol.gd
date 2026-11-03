extends RefCounted

# The pistol's stance, shot and reload, from the Quaternius pack's pistol
# clips (UAL1), fitted to our pistol. The clips' hand holds a gun of its own
# pitched up from the way ours sits on the grip, the support hand cupped
# under the wrist; so each frame is the artist's pose with the right hand
# turned to hold ours level where it held theirs, and the left hand carried
# with it, held to the gun as the artist held it to theirs. Where the clip's
# left hand leaves the gun (the reload) it is left where the artist put it.
# The stance is a low ready: Pistol_Idle with the gun and both hands swung
# down about the right shoulder, the body left as it stands; a shot
# comes up from it to Pistol_Shoot's aim and its recoil.

const PoseBuilder := preload("res://tools/pose_builder.gd")

const UAL1 := "res://assets/unit_animations.tres"
# How far the low ready points the gun down from the aim, in degrees.
const READY_DROP := 40.0
# The left hand is on the gun within NEAR of where the clip holds it, off
# it past FAR.
const NEAR := 0.05
const FAR := 0.15

var _poses: PoseBuilder
var _ual1: AnimationLibrary
# Our gun turned in the right hand to lie as the clips' does, measured from
# Pistol_Idle's first frame: the barrel level along the clip's aim.
var _turn: Basis
# Where the clip's left hand is in the right hand's grip space when it holds
# the gun: cupped under the wrist.
var _clip_off_hand: Transform3D


func _init(poses: PoseBuilder) -> void:
	_poses = poses
	_ual1 = load(UAL1)
	var aim := _frame(_sample("Pistol_Idle", 0.0))
	var grip := _poses.grip_transform(aim, "Right")
	var barrel := Vector3(grip.basis.z.x, 0, grip.basis.z.z).normalized()
	var x := Vector3.UP.cross(barrel).normalized()
	_turn = grip.basis.inverse() * Basis(x, barrel.cross(x), barrel)
	_clip_off_hand = grip.affine_inverse() * _poses.grip_transform(aim, "Left")


# The low ready, breathing with Pistol_Idle.
func stance() -> Animation:
	var idle := _ual1.get_animation("Pistol_Idle")
	return _poses.clip(idle.length, true, func(t: float, _length: float) -> Dictionary:
		return _fit(_frame(_sample("Pistol_Idle", t)), READY_DROP))


# The stance's first frame: where a shot is raised from and lowered to.
func ready() -> Dictionary:
	return _fit(_frame(_sample("Pistol_Idle", 0.0)), READY_DROP)


# Pistol_Shoot's aim `since` seconds after a shot, the arms kicked up by the
# recoil and settled by 0.25.
func aimed(since: float) -> Dictionary:
	return _fit(_frame(_sample("Pistol_Shoot", clampf(since, 0.0, 0.25))))


func reload() -> Animation:
	var anim := _ual1.get_animation("Pistol_Reload")
	return _poses.clip(anim.length, false, func(t: float, _length: float) -> Dictionary:
		return _fit(_frame(_sample("Pistol_Reload", t))))


# A clip's frame at t: bone -> local rotation, and the Hips position.
func _sample(clip: String, t: float) -> Dictionary:
	var anim := _ual1.get_animation(clip)
	var out := {}
	for track in anim.get_track_count():
		var bone := String(anim.track_get_path(track)).get_slice(":", 1)
		match anim.track_get_type(track):
			Animation.TYPE_ROTATION_3D:
				out[bone] = anim.rotation_track_interpolate(track, t)
			Animation.TYPE_POSITION_3D:
				if bone == "Hips":
					out["_hips"] = anim.position_track_interpolate(track, t)
	return out


# A sample as a pose.
func _frame(sample: Dictionary) -> Dictionary:
	var pose := {}
	for bone: String in sample:
		if bone == "_hips":
			pose["_hips"] = sample["_hips"] - _poses._bases["neutral"]["hips"]
		elif _poses._skeleton.find_bone(bone) >= 0:
			_poses._set_local(pose, bone, Basis(sample[bone]))
	return pose


# The frame with our gun in the right hand and the left on it, the gun and
# both hands swung `drop` degrees down about the right shoulder.
func _fit(pose: Dictionary, drop := 0.0) -> Dictionary:
	var resolved := _poses.resolve(pose)
	var grip := _poses.grip_transform(pose, "Right")
	var shoulder := _poses.bone_transform(resolved, "RightUpperArm").origin
	var swing := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(drop)), shoulder) * Transform3D(Basis(), -shoulder)
	var gun := swing * Transform3D(grip.basis * _turn, grip.origin)
	var left := _poses.grip_transform(pose, "Left")
	var right_pole := _pole(resolved, "Right")
	var left_pole := _pole(resolved, "Left")
	var on := 1.0 - smoothstep(NEAR, FAR, left.origin.distance_to((grip * _clip_off_hand).origin))
	var held := gun * _clip_off_hand
	_poses.grasp(pose, "Right", gun.origin, gun.basis.z, gun.basis.y, right_pole)
	_poses.grasp(pose, "Left", left.origin.lerp(held.origin, on),
		left.basis.z.lerp(held.basis.z, on), left.basis.y.lerp(held.basis.y, on), left_pole)
	return pose


# Which way the clip bends the `side` elbow: from the shoulder-wrist line out
# to the elbow.
func _pole(resolved: Dictionary, side: String) -> Vector3:
	var shoulder := _poses.bone_transform(resolved, side + "UpperArm").origin
	var elbow := _poses.bone_transform(resolved, side + "LowerArm").origin
	var wrist := _poses.bone_transform(resolved, side + "Hand").origin
	var line := (wrist - shoulder).normalized()
	var out := elbow - shoulder
	return out - line * out.dot(line)


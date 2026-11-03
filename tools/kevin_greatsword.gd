extends RefCounted

# The greatsword's stance and two-handed cut, from Kevin Iglesias' Human
# Melee Animations FREE (assets/kevin_melee), fitted to our sword. The clips
# hold a sword of their own with a longer grip, the hands further apart; so
# each frame is the artist's pose with the right hand kept as the clip has
# it, the blade along its grip, and the left hand a hand's width below it
# on the hilt, turned as the clip turns it.

const PoseBuilder := preload("res://tools/pose_builder.gd")
const KevinClip := preload("res://tools/kevin_clip.gd")

const DIR := "res://assets/kevin_melee/"
# From the right grip down the hilt to the left, as _greatsword_stance had it.
const SPACING := 0.11
# The thrust's moments in AttackPolearm01, in seconds: the hands are on
# the thrust's grip by ARMED, the point home at THRUST_IMPACT, and back on
# the guard's grip from DISARMED to the clip's end.
const ARMED := 0.12
const THRUST_IMPACT := 0.45
const DISARMED := 1.0
# Where the target is: ahead, chest high.
const TARGET := Vector3(0, 1.2, 1.8)
# The hilt from where the spear's front hand is, in to the middle: the rear
# hand winds back past the shoulder, which a sword's point aimed ahead would
# run through the body to follow.
const HILT_SHIFT := Vector3(0.15, 0.05, 0)
# How far each hand is turned on the hilt from where its wrist rests, in
# degrees about the blade: the turns that bend the wrists least through the
# drive (tools/_probe/roll_sweep.gd).
const LEFT_ROLL := -135.0
const RIGHT_ROLL := -30.0
var _poses: PoseBuilder


func _init(poses: PoseBuilder) -> void:
	_poses = poses


# The two-handed guard, looping.
func stance() -> Animation:
	return _fitted("HumanM@CombatIdle2H01", true)


# The cut: raised over the right shoulder, down across to the left, and
# back to the guard.
func swing() -> Animation:
	return _fitted("HumanM@Attack2H01", false)


# The thrust, from the pack's spear attack (AttackPolearm01), which starts
# and ends on the guard's feet: wound back, the front foot stepped in, and
# driven home. The body is the artist's; both hands are on our hilt where
# the spear's front hand is, the point on TARGET, eased from the guard's grip
# at the start and back to it at the end.
func thrust() -> Animation:
	var spear := KevinClip.source(DIR + "HumanM@AttackPolearm01.fbx")
	var guard := KevinClip.frame(_poses, KevinClip.source(DIR + "HumanM@CombatIdle2H01.fbx"), 0.0)
	var guarded := _poses.resolve(guard)
	var right := _poses.grip_transform(guard, "Right")
	var rest := {
		"hilt": right.origin,
		"blade": right.basis.y.normalized(),
		"Right": KevinClip.pole(_poses, guarded, "Right"),
		"Left": KevinClip.pole(_poses, guarded, "Left"),
	}
	rest["right_edge"] = _across(right.basis.z, rest["blade"])
	rest["left_edge"] = _across(_poses.grip_transform(guard, "Left").basis.z, rest["blade"])
	return _poses.clip(spear.length, false, func(t: float, length: float) -> Dictionary:
		var on := smoothstep(0.0, ARMED, t) * (1.0 - smoothstep(DISARMED, length, t))
		return _thrusting(KevinClip.frame(_poses, spear, t), rest, on))


# The spear clip's frame `pose` with the hands on our hilt: `on` of the way
# from the guard's grip `rest` to the thrust's.
func _thrusting(pose: Dictionary, rest: Dictionary, on: float) -> Dictionary:
	var resolved := _poses.resolve(pose)
	var held := _poses.bone_transform(resolved, "LeftHand").origin + HILT_SHIFT
	var hilt: Vector3 = rest["hilt"].lerp(held, on)
	var blade: Vector3 = rest["blade"].slerp((TARGET - held).normalized(), on)
	var poles := {}
	for side: String in ["Left", "Right"]:
		poles[side] = rest[side].lerp(KevinClip.pole(_poses, resolved, side), on)
	# Each hand turned on the blade from where its wrist points it with the
	# arm out at the hilt.
	_poses.reach(pose, "Right", hilt, poles["Right"])
	var edge := _across(_poses.grip_transform(pose, "Right").basis.z, blade).rotated(blade, deg_to_rad(RIGHT_ROLL))
	edge = _across(rest["right_edge"], blade).lerp(edge, on)
	_poses.reach(pose, "Left", hilt - blade * SPACING, poles["Left"])
	var left_edge := _across(_poses.grip_transform(pose, "Left").basis.z, blade).rotated(blade, deg_to_rad(LEFT_ROLL))
	left_edge = _across(rest["left_edge"], blade).lerp(left_edge, on)
	_poses.grasp(pose, "Right", hilt, edge, blade, poles["Right"])
	_poses.grasp(pose, "Left", hilt - blade * SPACING, left_edge, blade, poles["Left"])
	return pose


func _fitted(file: String, loops: bool) -> Animation:
	var anim := KevinClip.source(DIR + file + ".fbx")
	return _poses.clip(anim.length, loops, func(t: float, _length: float) -> Dictionary:
		return _fit(KevinClip.frame(_poses, anim, t)))


func _fit(pose: Dictionary) -> Dictionary:
	var resolved := _poses.resolve(pose)
	var right := _poses.grip_transform(pose, "Right")
	var left := _poses.grip_transform(pose, "Left")
	var blade := right.basis.y.normalized()
	var right_pole := KevinClip.pole(_poses, resolved, "Right")
	var left_pole := KevinClip.pole(_poses, resolved, "Left")
	_poses.grasp(pose, "Right", right.origin, _across(right.basis.z, blade), blade, right_pole)
	_poses.grasp(pose, "Left", right.origin - blade * SPACING, _across(left.basis.z, blade), blade, left_pole)
	return pose


# `z` with its part along the blade taken out.
static func _across(z: Vector3, blade: Vector3) -> Vector3:
	return z - blade * z.dot(blade)

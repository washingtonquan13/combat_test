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
# The thrust's moments, in seconds: drawn back, the point home, held there,
# back on guard.
const DRAWN := 0.32
const THRUST_IMPACT := 0.48
const HELD := 0.62
const THRUST_LENGTH := 1.3
# Where the target is: ahead, chest high.
const TARGET := Vector3(0, 1.2, 1.8)
# The right elbow out and up behind the hilt, so the wrist can lie the blade
# along the forearm onto the target.
const RIGHT_POLE := Vector3(-1, 0.5, 0.5)
# How far each hand is turned on the hilt from where its wrist rests, in
# degrees about the blade.
const LEFT_ROLL := 45.0
const RIGHT_ROLL := 10.0

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


# The thrust, built on the guard since the pack has none: the hilt drawn
# back to the right hip, point on the target, then driven home with both
# hands, the hips sinking and following it in, the feet where they stood.
func thrust() -> Animation:
	var source := KevinClip.source(DIR + "HumanM@CombatIdle2H01.fbx")
	var guard := _fit(KevinClip.frame(_poses, source, 0.0))
	var drawn := _thrusting(KevinClip.frame(_poses, source, 0.0), Vector3(0, -0.03, -0.05),
		{"Spine": Vector3(-4, -12, 0), "Chest": Vector3(-2, -10, 0)}, Vector3(-0.2, 0.9, 0.25))
	var home := _thrusting(KevinClip.frame(_poses, source, 0.0), Vector3(0, -0.08, 0.16),
		{"Spine": Vector3(10, 10, 0), "Chest": Vector3(6, 8, 0)}, Vector3(-0.05, 0.9, 0.75))
	return _poses.clip(THRUST_LENGTH, false, func(t: float, _length: float) -> Dictionary:
		return _poses.keyed(t, [
			[0.0, guard],
			[DRAWN, drawn],
			[THRUST_IMPACT, home],
			[HELD, home],
			[THRUST_LENGTH, guard],
		]))


# The guard frame `pose` with the hips moved by `hips` and the body turned by
# `turns`, the feet left where they stood, and the hilt held at `hilt` with
# the point on TARGET, both elbows bending as elbows do.
func _thrusting(pose: Dictionary, hips: Vector3, turns: Dictionary, hilt: Vector3) -> Dictionary:
	var resolved := _poses.resolve(pose)
	var feet := {}
	for side: String in ["Left", "Right"]:
		feet[side] = [_poses.bone_transform(resolved, side + "Foot"), _knee(resolved, side)]
	var arms := {"Left": KevinClip.pole(_poses, resolved, "Left"), "Right": RIGHT_POLE}
	pose["_hips"] = pose.get("_hips", Vector3.ZERO) + hips
	for bone: String in turns:
		PoseBuilder.add(pose, bone, turns[bone])
	for side: String in feet:
		_poses.plant(pose, side, feet[side][0], feet[side][1])
	# Each hand turned on the blade from where its wrist points it with the
	# arm out at the hilt.
	_poses.reach(pose, "Right", hilt, arms["Right"], true)
	var natural := _poses.grip_transform(pose, "Right").basis
	var blade := (TARGET - hilt).normalized()
	var edge := _across(natural.z, blade).rotated(blade, deg_to_rad(RIGHT_ROLL))
	_poses.reach(pose, "Left", hilt - blade * SPACING, arms["Left"], true)
	var left_edge := _across(_poses.grip_transform(pose, "Left").basis.z, blade).rotated(blade, deg_to_rad(LEFT_ROLL))
	_poses.grasp(pose, "Right", hilt, edge, blade, arms["Right"], true)
	_poses.grasp(pose, "Left", hilt - blade * SPACING, left_edge, blade, arms["Left"], true)
	return pose


# Which way the guard bends the `side` knee.
func _knee(resolved: Dictionary, side: String) -> Vector3:
	var hip := _poses.bone_transform(resolved, side + "UpperLeg").origin
	var knee := _poses.bone_transform(resolved, side + "LowerLeg").origin
	var ankle := _poses.bone_transform(resolved, side + "Foot").origin
	var line := (ankle - hip).normalized()
	var out := knee - hip
	return out - line * out.dot(line)


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

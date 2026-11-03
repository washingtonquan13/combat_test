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

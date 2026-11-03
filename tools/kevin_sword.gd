extends RefCounted

# The one-handed sword's stance, cut and thrust, from Kevin Iglesias' Human
# Melee Animations FREE (assets/kevin_melee). The clips' right hand holds our
# sword the way it holds theirs, the blade out of the fist where theirs is,
# so each frame is the artist's as it stands.

const PoseBuilder := preload("res://tools/pose_builder.gd")
const KevinClip := preload("res://tools/kevin_clip.gd")

const DIR := "res://assets/kevin_melee/"
# The blade straight ahead mid-sweep in Attack1H01_L, in seconds.
const SWING_IMPACT := 0.30
# The arm all the way out in Attack1H01_R.
const THRUST_IMPACT := 0.35

var _poses: PoseBuilder


func _init(poses: PoseBuilder) -> void:
	_poses = poses


# The low guard, the sword at the right hip, point up and ahead; looping.
func stance() -> Animation:
	return _clip("HumanM@CombatIdle1H01", true)


# Stepped in, the blade swept across from the left to the right.
func swing() -> Animation:
	return _clip("HumanM@Attack1H01_L", false)


# A long lunge onto the front foot, the arm and blade straight out at the
# target.
func thrust() -> Animation:
	return _clip("HumanM@Attack1H01_R", false)


func _clip(file: String, loops: bool) -> Animation:
	var anim := KevinClip.source(DIR + file + ".fbx")
	return _poses.clip(anim.length, loops, func(t: float, _length: float) -> Dictionary:
		return KevinClip.frame(_poses, anim, t))

extends RefCounted

# The one-handed sword's stance and thrust, from Kevin Iglesias' Human Melee
# Animations FREE (assets/kevin_melee). The clips' right hand holds our sword
# the way it holds theirs, the blade out of the fist where theirs is, so each
# frame is the artist's as it stands. The pack has no one-handed cut (its
# Attack1H01_L is an off-hand strike), so the cut is Quaternius'
# Sword_Attack, eased in from Kevin's guard and back out to it.

const PoseBuilder := preload("res://tools/pose_builder.gd")
const KevinClip := preload("res://tools/kevin_clip.gd")

const DIR := "res://assets/kevin_melee/"
# The blade come down in front in Sword_Attack, in seconds.
const SWING_IMPACT := 0.45
# The cut's moments in Sword_Attack: off the guard by WOUND, back on its own
# idle from SETTLED, and back on the guard at the end.
const WOUND := 0.1
const SETTLED := 1.2
# The arm all the way out in Attack1H01_R.
const THRUST_IMPACT := 0.35

var _poses: PoseBuilder


func _init(poses: PoseBuilder) -> void:
	_poses = poses


# The low guard, the sword at the right hip, point up and ahead; looping.
func stance() -> Animation:
	return _clip("HumanM@CombatIdle1H01", true)


# Raised over the right shoulder, stepped in and cut down across to the
# left, stepped back: `cut` (Sword_Attack) as `frame` reads it, `on` of the
# way from Kevin's guard.
func swing(cut: Animation, frame: Callable) -> Animation:
	var guard := _poses.resolve(KevinClip.frame(_poses, KevinClip.source(DIR + "HumanM@CombatIdle1H01.fbx"), 0.0))
	return _poses.clip(cut.length, false, func(t: float, length: float) -> Dictionary:
		var on := smoothstep(0.0, WOUND, t) * (1.0 - smoothstep(SETTLED, length, t))
		return _poses._blend(guard, _poses.resolve(frame.call(cut, t)), on))


# A long lunge onto the front foot, the arm and blade straight out at the
# target.
func thrust() -> Animation:
	return _clip("HumanM@Attack1H01_R", false)


func _clip(file: String, loops: bool) -> Animation:
	var anim := KevinClip.source(DIR + file + ".fbx")
	return _poses.clip(anim.length, loops, func(t: float, _length: float) -> Dictionary:
		return KevinClip.frame(_poses, anim, t))

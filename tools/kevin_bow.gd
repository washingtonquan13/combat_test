extends RefCounted

# The longbow's stance and shot, from Kevin Iglesias' Human Archer Animations
# FREE (assets/kevin_archer), fitted to our bow. The clips hold a bow of their
# own, turned in the left hand from the way ours sits on the grip; so each
# frame is the artist's pose with the left hand turned by one constant
# GRIP_TURN, measured at full draw: our bow upright, its face along the
# arrow, from the string hand to the bow hand.

const PoseBuilder := preload("res://tools/pose_builder.gd")
const KevinClip := preload("res://tools/kevin_clip.gd")

const DIR := "res://assets/kevin_archer/"
# The shot: eased up from the stance to the Load clip's first frame over
# RAISE, the Load clip to DRAWN (the string at the cheek and held), then the
# Release clip, the string leaving the fingers LOOSE into it, the bow lowered
# back to the stance by its end.
const RAISE := 0.35
const DRAWN := 0.5
const LOOSE := 0.05

var _poses: PoseBuilder
var _idle: Animation
var _load: Animation
var _release: Animation
var _turn: Basis


func _init(poses: PoseBuilder) -> void:
	_poses = poses
	_idle = _source("HumanM@BowIdle02")
	_load = _source("HumanM@BowShot01_Load")
	_release = _source("HumanM@BowShot01_Release")
	var drawn := _frame(_release, 0.0)
	var grip := _poses.grip_transform(drawn, "Left")
	var string := _poses.bone_transform(_poses.resolve(drawn), "RightHand").origin
	var z := (grip.origin - string).normalized()
	var x := Vector3.UP.cross(z).normalized()
	_turn = grip.basis.orthonormalized().inverse() * Basis(x, z.cross(x), z)


# The bow low in front, an arrow on the string, looping.
func stance() -> Animation:
	return _poses.clip(_idle.length, true, func(t: float, _length: float) -> Dictionary:
		return _fit(_frame(_idle, t)))


# When the string leaves the fingers, in seconds into shot().
func release_time() -> float:
	return RAISE + DRAWN + LOOSE


func shot() -> Animation:
	var rest := _fit(_frame(_idle, 0.0))
	var raised := _fit(_frame(_load, 0.0))
	return _poses.clip(RAISE + DRAWN + _release.length, false, func(t: float, _length: float) -> Dictionary:
		if t < RAISE:
			return _poses.keyed(t, [[0.0, rest], [RAISE, raised]])
		if t < RAISE + DRAWN:
			return _fit(_frame(_load, t - RAISE))
		return _fit(_frame(_release, t - RAISE - DRAWN)))


func _source(file: String) -> Animation:
	return KevinClip.source(DIR + file + ".fbx")


func _frame(anim: Animation, t: float) -> Dictionary:
	return KevinClip.frame(_poses, anim, t)


func _fit(pose: Dictionary) -> Dictionary:
	var bow := _poses.grip_transform(pose, "Left").basis.orthonormalized() * _turn
	_poses.hold(pose, "Left", bow.z, bow.y)
	return pose

extends RefCounted

# The long gun's stance, aim and reload, from Kevin Iglesias' Human Soldier
# Animations FREE (assets/kevin_soldier), fitted to our rifle: the stance and
# reload from the assault rifle set, held low; the aim a shot is fired from
# the rifle set's, the stock at the shoulder and the gun level. The clips hold
# a gun of their own, turned in the right hand from the way ours sits on the
# grip, with a longer handguard; so each frame is the artist's pose with both
# arms bent back onto our gun: the right hand turned to hold it the way the
# clip's hand holds theirs, the left hand on the gun scene's OffHand mark. Where the
# clip's left hand leaves the gun (the reload's trip to the belt) it is left
# where the artist put it.

const PoseBuilder := preload("res://tools/pose_builder.gd")

const DIR := "res://assets/kevin_soldier/"
# Their hips stand 0.980 high, ours 0.917.
const HIPS_SCALE := 0.936
# How the assault rifle set's gun sits in the right hand, turned from ours on
# the grip, in degrees: measured from where their left palm and the gun's top
# are. The rifle set's hand already holds ours level at the shoulder.
const GRIP_TURN := Vector3(38.96, 3.81, 0.66)
const RAISED_TURN := Vector3.ZERO
# Where the clip's left hand holds the clip's gun, in the same space: under
# the handguard, where rifle.tscn's OffHand mark is. The left hand is on the
# gun within NEAR of it, off it past FAR.
const CLIP_OFF_HAND := Vector3(0, 0.1, 0.3)
const NEAR := 0.1
const FAR := 0.22
const FINGERS := ["Index", "Middle", "Ring", "Little"]

var _poses: PoseBuilder
var _aim: Animation
var _raised: Animation
# Where the off hand holds the gun, in its grip space.
var _off_hand: Vector3


func _init(poses: PoseBuilder, gun: PackedScene) -> void:
	_poses = poses
	var scene: Node3D = gun.instantiate()
	_off_hand = (scene.get_node("OffHand") as Node3D).position
	scene.free()
	_aim = _source("HumanM@AssaultRifle_Aim01")
	_raised = _source("HumanM@Rifle_Aim01")


# The shouldered aim, looping: the stance a unit stands in with a long gun.
func stance() -> Animation:
	return _poses.clip(_aim.length, true, func(t: float, _length: float) -> Dictionary:
		return _fit(_frame(_aim, t)))


func reload() -> Animation:
	var anim := _source("HumanM@AssaultRifle_Reload01")
	return _poses.clip(anim.length, false, func(t: float, _length: float) -> Dictionary:
		return _fit(_frame(anim, t)))


# The stance's first frame: where a shot is raised from and lowered to.
func aimed() -> Dictionary:
	return _fit(_frame(_aim, 0.0))


# Shouldered to fire, the chest rocked back `kick` degrees by a shot, the
# gun carried with it.
func raised(kick := 0.0) -> Dictionary:
	var pose := _frame(_raised, 0.0)
	PoseBuilder.add(pose, "Chest", Vector3(-kick, 0, 0))
	return _fit(pose, RAISED_TURN)


func _source(file: String) -> Animation:
	var scene: Node = (load(DIR + file + ".fbx") as PackedScene).instantiate()
	var player: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
	var anim: Animation = player.get_animation(player.get_animation_list()[0]).duplicate(true)
	scene.free()
	return anim


# The clip's frame at t as a pose.
func _frame(anim: Animation, t: float) -> Dictionary:
	var pose := {}
	for track in anim.get_track_count():
		var bone := String(anim.track_get_path(track)).get_slice(":", 1)
		match anim.track_get_type(track):
			Animation.TYPE_ROTATION_3D:
				if _poses._skeleton.find_bone(bone) >= 0:
					_poses._set_local(pose, bone, Basis(anim.rotation_track_interpolate(track, t)))
			Animation.TYPE_POSITION_3D:
				if bone == "Hips":
					pose["_hips"] = anim.position_track_interpolate(track, t) * HIPS_SCALE \
						- _poses._bases["neutral"]["hips"]
	return pose


func _fit(pose: Dictionary, grip_turn := GRIP_TURN) -> Dictionary:
	var resolved := _poses.resolve(pose)
	var turn := Basis.from_euler(grip_turn * PI / 180.0)
	var gun := _poses.grip_transform(pose, "Right") * Transform3D(turn, Vector3.ZERO)
	var left := _poses.grip_transform(pose, "Left")
	var right_pole := _pole(resolved, "Right")
	var left_pole := _pole(resolved, "Left")
	var mark := gun * _off_hand
	var on := 1.0 - smoothstep(NEAR, FAR, left.origin.distance_to(gun * CLIP_OFF_HAND))
	_poses.grasp(pose, "Right", gun.origin, gun.basis.z, gun.basis.y, right_pole)
	_curl(pose, on)
	_poses.grasp(pose, "Left", left.origin.lerp(mark, on), left.basis.z, left.basis.y, left_pole)
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


# The left fingers closed round the handguard, as far as the hand is on it.
static func _curl(pose: Dictionary, on: float) -> void:
	for finger: String in FINGERS:
		PoseBuilder.add(pose, "Left%sProximal" % finger, Vector3(0, 0, -40 * on))
		PoseBuilder.add(pose, "Left%sIntermediate" % finger, Vector3(0, 0, -50 * on))
		PoseBuilder.add(pose, "Left%sDistal" % finger, Vector3(0, 0, -30 * on))

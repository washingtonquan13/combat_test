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
const KevinClip := preload("res://tools/kevin_clip.gd")

const DIR := "res://assets/kevin_soldier/"
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
# The crossbow's string pull, in seconds: the muzzle down TIP degrees and the
# body leaned LEAN over it, the left hand on the string by HOOKED, a beat
# till GRABBED, back at the latch by HAULED; then the rifle reload from
# CLIP_FROM (its left hand leaving the gun), the tip and lean gone by SETTLE.
# Where the string is hooked and where the latch holds it, and the groove
# the bolt is laid in, in the gun's space (crossbow.glb: the prod's tips
# 0.28 up the stock, the lock block 0 to 0.12, 0.12 high).
const TIP := 35.0
const LEAN := 12.0
const HOOKED := 0.4
const GRABBED := 0.55
const HAULED := 1.0
const CLIP_FROM := 0.25
const SETTLE := 0.35
const STRING := Vector3(0, 0.07, 0.3)
const LATCH := Vector3(0, 0.14, 0.13)
const GROOVE := Vector3(0, 0.09, 0.22)
# In the rifle reload's own time: the left hand comes back from the belt and
# lays the bolt in the groove, LAY_FROM to LAY_AT, held LAY_HOLD, then on
# to the forestock by LAY_DONE.
const LAY_FROM := 1.0
const LAY_AT := 1.2
const LAY_HOLD := 0.1
const LAY_DONE := 1.5

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


# The crossbow's reload: the muzzle tipped down, the left hand hooks the
# string at the prod and hauls it back to the latch, then the rifle reload's
# trip to the belt from where it leaves the gun, fetching a bolt, which is
# laid along the top of the stock on the way back to the forestock.
func hauled_reload() -> Animation:
	var anim := _source("HumanM@AssaultRifle_Reload01")
	var resume := HAULED - CLIP_FROM
	return _poses.clip(HAULED + anim.length - CLIP_FROM, false, func(t: float, _length: float) -> Dictionary:
		if t < HAULED:
			var down := smoothstep(0.0, HOOKED, t)
			var drawn := smoothstep(GRABBED, HAULED, t)
			var pose := _frame(anim, 0.0)
			PoseBuilder.add(pose, "Spine", Vector3(LEAN * down, 0, 0))
			var at := _off_hand.lerp(STRING, down).lerp(LATCH, drawn)
			return _fit_to(pose, GRIP_TURN, TIP * down, at, 1.0)
		var c := t - resume
		var back := smoothstep(HAULED, HAULED + SETTLE, t)
		var pose := _frame(anim, c)
		PoseBuilder.add(pose, "Spine", Vector3(LEAN * (1.0 - back), 0, 0))
		var laying := smoothstep(LAY_FROM, LAY_AT, c) * (1.0 - smoothstep(LAY_AT + LAY_HOLD, LAY_DONE, c))
		var at := LATCH.lerp(_off_hand, back).lerp(GROOVE, laying)
		return _fit_to(pose, GRIP_TURN, TIP * (1.0 - back), at, maxf(1.0 - back, laying)))


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
	return KevinClip.source(DIR + file + ".fbx")


func _frame(anim: Animation, t: float) -> Dictionary:
	return KevinClip.frame(_poses, anim, t)


func _fit(pose: Dictionary, grip_turn := GRIP_TURN) -> Dictionary:
	return _fit_to(pose, grip_turn, 0.0, _off_hand, 0.0)


# As _fit, the gun's muzzle tipped `tip` degrees down about the grip and the
# left hand at `off_hand` in the gun's space; `held` of the way to on the gun
# wherever the clip's left hand is.
func _fit_to(pose: Dictionary, grip_turn: Vector3, tip: float, off_hand: Vector3, held: float) -> Dictionary:
	var resolved := _poses.resolve(pose)
	var turn := Basis.from_euler(grip_turn * PI / 180.0) * Basis(Vector3.RIGHT, deg_to_rad(tip))
	var gun := _poses.grip_transform(pose, "Right") * Transform3D(turn, Vector3.ZERO)
	var left := _poses.grip_transform(pose, "Left")
	var right_pole := KevinClip.pole(_poses, resolved, "Right")
	var left_pole := KevinClip.pole(_poses, resolved, "Left")
	var mark := gun * off_hand
	var on := lerpf(1.0 - smoothstep(NEAR, FAR, left.origin.distance_to(gun * CLIP_OFF_HAND)), 1.0, held)
	_poses.grasp(pose, "Right", gun.origin, gun.basis.z, gun.basis.y, right_pole)
	_curl(pose, on)
	_poses.grasp(pose, "Left", left.origin.lerp(mark, on), left.basis.z, left.basis.y, left_pole)
	return pose


# The left fingers closed round the handguard, as far as the hand is on it.
static func _curl(pose: Dictionary, on: float) -> void:
	for finger: String in FINGERS:
		PoseBuilder.add(pose, "Left%sProximal" % finger, Vector3(0, 0, -40 * on))
		PoseBuilder.add(pose, "Left%sIntermediate" % finger, Vector3(0, 0, -50 * on))
		PoseBuilder.add(pose, "Left%sDistal" % finger, Vector3(0, 0, -30 * on))

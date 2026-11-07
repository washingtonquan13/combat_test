extends RefCounted

# Blocking for the rifle: the key poses only, stepped, before any
# breakdowns. The body leans into the gun instead of standing upright over
# it, so the arms reach it without wringing the wrists.

const PoseBuilder := preload("res://tools/pose_builder.gd")

const FINGERS := ["Index", "Middle", "Ring", "Little"]

# Where the off hand holds the rifle, in the gun's grip space: rifle.tscn's
# OffHand mark, under the handguard.
const OFF_HAND := Vector3(0, 0.1, 0.3)

var _poses: PoseBuilder


func build(poses: PoseBuilder) -> Dictionary:
	_poses = poses
	return {
		"stance": {"length": 3.0, "loops": true, "keys": _stance()},
		"reload": {"length": 1.6, "loops": false, "keys": _reload()},
	}


func _stance() -> Array:
	return [
		[0.0, "exhale", _ready(0.0)],
		[1.5, "inhale", _ready(1.0)],
	]


# The relaxed carry from the reference photos: squared up with the feet a
# little staggered, knees soft, the chest a touch over the hips and the
# shoulders down, the head up and looking out past the muzzle.
func _body(breath: float) -> Dictionary:
	var pose := {
		"_hips": Vector3(0, -0.02, 0),
		"Hips": Vector3(0, -12, 0),
		"Spine": Vector3(8, -4, 0),
		"Chest": Vector3(6, -6, 0),
		"Neck": Vector3(-3, 3, 0),
		"Head": Vector3(-4, 3, 0),
		"LeftShoulder": Vector3(-10, -20, 0),
		"LeftUpperLeg": Vector3(-8, 12, 4),
		"LeftLowerLeg": Vector3(10, 0, 0),
		"RightUpperLeg": Vector3(4, 12, -4),
		"RightLowerLeg": Vector3(8, 0, 0),
	}
	_fingers(pose, "Right", 0.8)
	_fingers(pose, "Left", 0.6)
	_breathe(pose, breath)
	return pose


# The gun across the body: the stock under the right armpit, the muzzle
# down and to the left - flatter than the photos, the mannequin's arms being
# short for its height - the right hand on the grip at the belly with the
# elbow at the ribs, its left side turned out.
const CARRY_BARREL := Vector3(0.45, -0.45, 0.75)
const CARRY_TOP := Vector3(0, 1, 0.3)


func _ready(breath: float) -> Dictionary:
	var pose := _body(breath)
	_two_hands(pose, _at(pose, "RightUpperArm") + Vector3(0.1, -0.28, 0.22), CARRY_BARREL, CARRY_TOP)
	return pose


# From the ready: the gun rolled toward the left hand and the head down to
# it, the empty magazine stripped, a fresh one from the belt, driven home and
# slapped, then back to the ready.
func _reload() -> Array:
	var ready := _ready(0.0)
	var tipped := _body(0.0)
	PoseBuilder.add(tipped, "Spine", Vector3(4, 6, 0))
	PoseBuilder.add(tipped, "Chest", Vector3(4, 6, 0))
	tipped["Neck"] = Vector3(10, 4, 0)
	tipped["Head"] = Vector3(12, 4, 0)
	var grip := _at(tipped, "RightUpperArm") + Vector3(0.16, -0.18, 0.24)
	var barrel := Vector3(-0.2, -0.25, 1)
	var top := Vector3(-0.7, 0.7, 0)
	# The magazine well: just ahead of the grip, under the gun.
	var well := grip + barrel.normalized() * 0.1 - top.normalized() * 0.12
	var hands := func(body: Dictionary, left_at: Vector3, curl: float) -> Dictionary:
		var pose := body.duplicate()
		_fingers(pose, "Left", curl - 0.6)
		_poses.grasp(pose, "Right", grip, barrel, top)
		_support(pose, left_at, barrel, top)
		return pose
	var strip: Dictionary = hands.call(tipped, well, 0.9)
	# The torso turns and dips to the left to bring the belt to the hand.
	var dipped := tipped.duplicate()
	PoseBuilder.add(dipped, "Spine", Vector3(4, -6, 8))
	PoseBuilder.add(dipped, "Chest", Vector3(2, -4, 4))
	var belt: Dictionary = hands.call(dipped, _at(dipped, "Hips") + Vector3(0.2, -0.02, 0.06), 0.9)
	var insert: Dictionary = hands.call(tipped, well - top.normalized() * 0.04, 0.9)
	var slap: Dictionary = hands.call(tipped, well + top.normalized() * 0.03, 0.2)
	return [
		[0.0, "ready", ready],
		[0.3, "strip", strip],
		[0.55, "belt", belt],
		[0.95, "insert", insert],
		[1.1, "slap", slap],
		[1.6, "ready", ready],
	]


# Both hands on the rifle lying along `barrel`, its top toward `top`: the
# right on the grip at `grip`, the left on the OffHand mark.
func _two_hands(pose: Dictionary, grip: Vector3, barrel: Vector3, top: Vector3) -> void:
	var z := barrel.normalized()
	var x := top.cross(z).normalized()
	var gun := Basis(x, z.cross(x), z)
	_poses.grasp(pose, "Right", grip, barrel, top)
	_support(pose, grip + gun * OFF_HAND, barrel, top)


# The off hand under the handguard at `at`: palm up, the fingers wrapped
# across it from the left and up its right side, the thumb along the barrel.
# A grip's +Z runs along the fingers and +Y along the thumb.
func _support(pose: Dictionary, at: Vector3, barrel: Vector3, top: Vector3) -> void:
	var across := barrel.cross(top).normalized()
	# Palm up, the forearm supinated: the elbow hangs by the ribs, not off
	# the thumb as a handshake grip would put it.
	_poses.grasp(pose, "Left", at, across + top.normalized() * 0.4, barrel, Vector3(0.3, -1, -0.3))


func _at(pose: Dictionary, bone: String) -> Vector3:
	return _poses.bone_transform(_poses.resolve(pose), bone).origin


static func _fingers(pose: Dictionary, side: String, curl: float) -> void:
	var roll := curl if side == "Right" else -curl
	for finger: String in FINGERS:
		PoseBuilder.add(pose, "%s%sProximal" % [side, finger], Vector3(0, 0, 55 * roll))
		PoseBuilder.add(pose, "%s%sIntermediate" % [side, finger], Vector3(0, 0, 75 * roll))
		PoseBuilder.add(pose, "%s%sDistal" % [side, finger], Vector3(0, 0, 45 * roll))


static func _breathe(pose: Dictionary, breath: float) -> void:
	PoseBuilder.add(pose, "Chest", Vector3(-1.5 * breath, 0, 0))
	PoseBuilder.add(pose, "Head", Vector3(1.0 * breath, 0, 0))
	pose["_hips"] = pose.get("_hips", Vector3.ZERO) + Vector3(0, 0.004 * breath, 0)

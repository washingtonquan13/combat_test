extends SceneTree

# Generates assets/fireball_animations.tres: a right-handed caster's Fireball,
# keyed onto the UAL mannequin's GeneralSkeleton.
#
#   godot --headless --path . -s res://tools/make_fireball_animations.gd
#
# The fireball is not thrown. It is called up above the shoulder and sent out
# by will, the arm only aiming it:
#
#   Arm      standing -> the hand rises above the shoulder, fingers curled,
#            and a flick of the wrist snaps them open: the flame lights
#   Hold     the flame held above the shoulder, palm up, looping
#   Disarm   the hand closes on the flame, snuffing it, and drops to standing
#   Cast     a small draw back, then the arm extends straight at the target,
#            palm open (the fireball leaves the hand at RELEASE); the aim is
#            held a beat, then back to standing
#
# The clips chain because their ends are shared poses: Arm ends on Hold's
# first frame, Cast and Disarm start on it, and Disarm and Cast end on
# standing, the Idle clip's first frame. UnitAnimator crossfades into each of
# them, which covers the cases that cut in mid-clip (disarming before Arm
# finishes, casting from the middle of a Hold loop).
#
# Poses are built with tools/pose_builder.gd, whose header explains the
# bases and how a turn is given. Retune by editing the poses below and
# running this again; the clips are data the game reads. Moving RELEASE means
# moving the matching delay in explosive_fireball.tres too (its cast_vfx
# DelayStep and the launch sound's delay).

const PoseBuilder := preload("res://tools/pose_builder.gd")

const OUT := "res://assets/fireball_animations.tres"

const HOLD_LENGTH := 2.4
# When the arm reaches full extension, in seconds into Cast.
const RELEASE := 0.3

const FINGERS := ["Index", "Middle", "Ring", "Little"]

var _poses: PoseBuilder


func _init() -> void:
	_poses = PoseBuilder.new()
	var library := AnimationLibrary.new()
	library.add_animation("Arm", _poses.clip(0.75, false, _arm))
	library.add_animation("Hold", _poses.clip(HOLD_LENGTH, true, _hold))
	library.add_animation("Disarm", _poses.clip(0.55, false, _disarm))
	library.add_animation("Cast", _poses.clip(1.25, false, _cast))
	var err := ResourceSaver.save(library, OUT)
	print("fireball animations: saved %s (%s)" % [OUT, error_string(err)])
	_poses.free_model()
	quit(0 if err == OK else 1)


# --- Poses -------------------------------------------------------------

# Curls the right hand's fingers toward the palm: 0 open, 1 a loose fist.
# A negative curl bends them back, the fingers splayed.
func _right_fingers(pose: Dictionary, curl: float) -> void:
	for finger: String in FINGERS:
		PoseBuilder.add(pose, "Right%sProximal" % finger, Vector3(0, 0, 55 * curl))
		PoseBuilder.add(pose, "Right%sIntermediate" % finger, Vector3(0, 0, 75 * curl))
		PoseBuilder.add(pose, "Right%sDistal" % finger, Vector3(0, 0, 45 * curl))
	PoseBuilder.add(pose, "RightThumbProximal", Vector3(0, -30 * curl, 20 * curl))
	PoseBuilder.add(pose, "RightThumbDistal", Vector3(0, 0, 30 * curl))


# A composed caster: feet apart, left a little ahead, chin level. The right
# hand is up beside the head, above the shoulder, palm to the sky, the flame
# sitting on it; the left hangs easy, a little out from the hip.
func _ready_pose() -> Dictionary:
	var pose := {
		"_hips": Vector3(0, -0.02, 0),
		"Hips": Vector3(0, -8, 0),
		"Spine": Vector3(2, 2, 0),
		"Chest": Vector3(-2, 2, 0),
		"Neck": Vector3(0, 2, 0),
		"Head": Vector3(-2, 4, 0),
		"LeftUpperLeg": Vector3(-10, 6, 5),
		"LeftLowerLeg": Vector3(8, 0, 0),
		"RightUpperLeg": Vector3(6, 6, -5),
		"RightLowerLeg": Vector3(8, 0, 0),
		"RightFoot": Vector3(-6, 0, 0),
		"LeftUpperArm": Vector3(-8, 0, -8),
		"LeftLowerArm": Vector3(-30, 0, 0),
		"LeftHand": Vector3(0, 0, -10),
		"RightUpperArm": Vector3(-14, 0, -62),
		"RightLowerArm": Vector3(-6, 0, -100),
		"RightHand": Vector3(0, 0, -80),
	}
	_right_fingers(pose, 0.15)
	return pose


func _hold(t: float, length: float) -> Dictionary:
	var pose := _ready_pose()
	var w := TAU * t / length
	# Breathing; the flame bobs on the palm and the fingers stir under it.
	pose["_hips"] += Vector3(0, 0.01 * sin(w), 0)
	PoseBuilder.add(pose, "Spine", Vector3(1.2 * sin(w - 0.5), 0, 0))
	PoseBuilder.add(pose, "Chest", Vector3(0.8 * sin(w - 0.9), 0, 0))
	PoseBuilder.add(pose, "RightUpperArm", Vector3(2.5 * sin(w), 0, 2 * cos(w)))
	PoseBuilder.add(pose, "RightLowerArm", Vector3(-4 * sin(w - 0.6), 0, 0))
	PoseBuilder.add(pose, "RightHand", Vector3(5 * sin(2 * w), 0, 4 * cos(2 * w)))
	_right_fingers(pose, 0.08 * sin(2 * w + 1.0))
	PoseBuilder.add(pose, "LeftUpperArm", Vector3(1.5 * sin(w - 1.2), 0, 0))
	return pose


# The hand come up to the shoulder, the wrist cocked down and the fingers
# curled in, ready to snap.
func _cocked_pose() -> Dictionary:
	var pose := _ready_pose()
	pose["RightUpperArm"] = Vector3(-10, 0, -56)
	pose["RightLowerArm"] = Vector3(-6, 0, -110)
	pose["RightHand"] = Vector3(0, 0, 35)
	pose["Head"] = Vector3(4, 10, 0)
	_right_fingers(pose, 0.85)
	return pose


# The flick: the wrist snaps over past the hold and the fingers fly open,
# splayed.
func _flick_pose() -> Dictionary:
	var pose := _ready_pose()
	pose["RightUpperArm"] = Vector3(-14, 0, -66)
	pose["RightHand"] = Vector3(0, 0, -100)
	pose["Head"] = Vector3(0, 8, 0)
	_right_fingers(pose, -0.3)
	return pose


func _arm(t: float, _length: float) -> Dictionary:
	return _poses.keyed(t, [
		[0.0, _poses.standing()],
		[0.3, _cocked_pose()],
		[0.4, _flick_pose()],
		[0.75, _hold(0.0, HOLD_LENGTH)],
	])


func _disarm(t: float, _length: float) -> Dictionary:
	# The fingers close over the flame, then the fist drops.
	var snuffed := _ready_pose()
	snuffed["RightHand"] = Vector3(0, 0, -50)
	_right_fingers(snuffed, 1.0)
	return _poses.keyed(t, [
		[0.0, _hold(0.0, HOLD_LENGTH)],
		[0.18, snuffed],
		[0.55, _poses.standing()],
	])


# A small draw before the push: the hand lifts and comes back a little, the
# chest opening.
func _draw_pose() -> Dictionary:
	var pose := _ready_pose()
	pose["RightUpperArm"] = Vector3(6, 0, -66)
	pose["RightLowerArm"] = Vector3(-4, 0, -112)
	pose["Chest"] = Vector3(-4, -4, 0)
	pose["Head"] = Vector3(-2, 8, 0)
	return pose


# The arm straight out at the target, shoulder high, the palm open toward it
# and the fingers spread; the body leans into it a touch, the left hand
# drawing back to the hip.
func _extend_pose() -> Dictionary:
	var pose := _ready_pose()
	pose["_hips"] = Vector3(0, -0.03, 0.03)
	pose["Hips"] = Vector3(2, 4, 0)
	pose["Spine"] = Vector3(5, 4, 0)
	pose["Chest"] = Vector3(2, 4, 0)
	pose["Head"] = Vector3(-4, -2, 0)
	pose["RightUpperArm"] = Vector3(-86, 12, -6)
	pose["RightLowerArm"] = Vector3(-4, 0, 0)
	pose["RightHand"] = Vector3(-70, 0, 0)
	pose["LeftUpperArm"] = Vector3(12, 0, -12)
	pose["LeftLowerArm"] = Vector3(-40, 0, 0)
	_right_fingers(pose, -0.25)
	return pose


func _cast(t: float, _length: float) -> Dictionary:
	var aim := _extend_pose()
	PoseBuilder.add(aim, "RightUpperArm", Vector3(4, 0, 0))
	PoseBuilder.add(aim, "RightHand", Vector3(10, 0, 0))
	_right_fingers(aim, 0.3)
	return _poses.keyed(t, [
		[0.0, _hold(0.0, HOLD_LENGTH)],
		[0.12, _draw_pose()],
		[RELEASE, _extend_pose()],
		[0.65, aim],
		[1.25, _poses.standing()],
	])

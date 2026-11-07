extends SceneTree

# Generates assets/flight_animations.tres: a humanoid's levitation clips,
# keyed onto the UAL mannequin's GeneralSkeleton.
#
#   godot --headless --path . -s res://tools/make_flight_animations.gd
#
# Poses are built with tools/pose_builder.gd, whose header explains the
# bases and how a turn is given. Standing (the first frame of Takeoff, the
# last of Land) is the Idle clip's first frame exactly, so they join it
# without a pop.
#
# Retune by editing the poses below and running this again; the clips are
# data the game reads, so nothing else needs rebuilding.

const PoseBuilder := preload("res://tools/pose_builder.gd")

const OUT := "res://assets/flight_animations.tres"

var _poses: PoseBuilder


func _init() -> void:
	_poses = PoseBuilder.new()

	var library := AnimationLibrary.new()
	library.add_animation("Takeoff", _poses.clip(0.8, false, _takeoff))
	library.add_animation("Hover", _poses.clip(3.0, true, _hover))
	library.add_animation("Fly_Fwd", _poses.clip(1.6, true, _fly_fwd))
	library.add_animation("Land", _poses.clip(0.7, false, _land))
	var err := ResourceSaver.save(library, OUT)
	print("flight animations: saved %s (%s)" % [OUT, error_string(err)])
	_poses.free_model()
	quit(0 if err == OK else 1)


# --- Poses -------------------------------------------------------------

func _standing() -> Dictionary:
	return _poses.standing()


# Upright, weight hanging from the chest: thighs a little forward so the
# bent knees leave the shins hanging under the body, not trailing behind it,
# toes pointed, arms a little out from the body for balance.
func _hover_pose() -> Dictionary:
	return {
		"Spine": Vector3(4, 0, 0),
		"Head": Vector3(-4, 0, 0),
		"LeftUpperLeg": Vector3(-24, 0, 3),
		"LeftLowerLeg": Vector3(34, 0, 0),
		"LeftFoot": Vector3(38, 0, 0),
		"RightUpperLeg": Vector3(-16, 0, -2),
		"RightLowerLeg": Vector3(40, 0, 0),
		"RightFoot": Vector3(40, 0, 0),
		"LeftUpperArm": Vector3(-8, 0, 22),
		"LeftLowerArm": Vector3(-28, 0, 0),
		"RightUpperArm": Vector3(-8, 0, -22),
		"RightLowerArm": Vector3(-28, 0, 0),
	}


func _hover(t: float, length: float) -> Dictionary:
	var pose := _hover_pose()
	var w := TAU * t / length
	pose["_hips"] = Vector3(0, 0.035 * sin(w), 0)
	PoseBuilder.add(pose, "Spine", Vector3(1.5 * sin(w - 0.4), 0, 0))
	PoseBuilder.add(pose, "LeftUpperLeg", Vector3(4 * sin(w - 0.7), 0, 0))
	PoseBuilder.add(pose, "LeftLowerLeg", Vector3(5 * sin(w - 1.2), 0, 0))
	PoseBuilder.add(pose, "RightUpperLeg", Vector3(3 * sin(w - 1.0), 0, 0))
	PoseBuilder.add(pose, "RightLowerLeg", Vector3(5 * sin(w - 1.6), 0, 0))
	PoseBuilder.add(pose, "LeftUpperArm", Vector3(0, 0, 4 * sin(w - 0.9)))
	PoseBuilder.add(pose, "RightUpperArm", Vector3(0, 0, -4 * sin(w - 0.9)))
	PoseBuilder.add(pose, "LeftLowerArm", Vector3(-4 * sin(w - 1.4), 0, 0))
	PoseBuilder.add(pose, "RightLowerArm", Vector3(-4 * sin(w - 1.4), 0, 0))
	return pose


# Leaning into the direction of travel from the hips, legs trailing in line
# with the body, arms swept well back (the lean alone leaves hanging arms
# pointing straight down); the head comes up to keep looking ahead.
func _fly_fwd(t: float, length: float) -> Dictionary:
	var w := TAU * t / length
	var pose := {
		"_hips": Vector3(0, 0.03 * sin(2 * w), 0),
		"Hips": Vector3(28, 0, 0),
		"Spine": Vector3(4, 0, 0),
		"Chest": Vector3(-6, 0, 0),
		"Neck": Vector3(-10, 0, 0),
		"Head": Vector3(-14, 0, 0),
		"LeftUpperLeg": Vector3(-8, 0, 4),
		"LeftLowerLeg": Vector3(16, 0, 0),
		"LeftFoot": Vector3(45, 0, 0),
		"RightUpperLeg": Vector3(-2, 0, -3),
		"RightLowerLeg": Vector3(26, 0, 0),
		"RightFoot": Vector3(45, 0, 0),
		"LeftUpperArm": Vector3(55, 0, 12),
		"LeftLowerArm": Vector3(-8, 0, 0),
		"RightUpperArm": Vector3(55, 0, -12),
		"RightLowerArm": Vector3(-8, 0, 0),
	}
	PoseBuilder.add(pose, "LeftUpperLeg", Vector3(3 * sin(w), 0, 0))
	PoseBuilder.add(pose, "LeftLowerLeg", Vector3(5 * sin(w - 0.8), 0, 0))
	PoseBuilder.add(pose, "RightUpperLeg", Vector3(3 * sin(w + PI), 0, 0))
	PoseBuilder.add(pose, "RightLowerLeg", Vector3(5 * sin(w + PI - 0.8), 0, 0))
	PoseBuilder.add(pose, "LeftUpperArm", Vector3(3 * sin(2 * w - 0.5), 0, 0))
	PoseBuilder.add(pose, "RightUpperArm", Vector3(3 * sin(2 * w - 0.5), 0, 0))
	PoseBuilder.add(pose, "Spine", Vector3(1.5 * sin(2 * w - 0.3), 0, 0))
	return pose


# Feet flat, hips dropped, arms back: the instant before the push.
func _crouch_pose(depth: float) -> Dictionary:
	return {
		"_hips": Vector3(0, -0.15 * depth, 0.02 * depth),
		"Spine": Vector3(14, 0, 0) * depth,
		"Head": Vector3(-10, 0, 0) * depth,
		"LeftUpperLeg": Vector3(-40, 0, 0) * depth,
		"LeftLowerLeg": Vector3(70, 0, 0) * depth,
		"LeftFoot": Vector3(-30, 0, 0) * depth,
		"RightUpperLeg": Vector3(-40, 0, 0) * depth,
		"RightLowerLeg": Vector3(70, 0, 0) * depth,
		"RightFoot": Vector3(-30, 0, 0) * depth,
		"LeftUpperArm": Vector3(28, 0, 10) * depth,
		"RightUpperArm": Vector3(28, 0, -10) * depth,
	}


# Legs straight and toes pointed, arms flung up and out, chest open.
func _launch_pose() -> Dictionary:
	return {
		"_hips": Vector3(0, 0.04, 0),
		"Spine": Vector3(-6, 0, 0),
		"Chest": Vector3(-4, 0, 0),
		"Head": Vector3(-12, 0, 0),
		"LeftUpperLeg": Vector3(4, 0, 2),
		"LeftLowerLeg": Vector3(6, 0, 0),
		"LeftFoot": Vector3(45, 0, 0),
		"RightUpperLeg": Vector3(8, 0, -2),
		"RightLowerLeg": Vector3(12, 0, 0),
		"RightFoot": Vector3(45, 0, 0),
		"LeftUpperArm": Vector3(-20, 0, 55),
		"LeftLowerArm": Vector3(-10, 0, 0),
		"RightUpperArm": Vector3(-20, 0, -55),
		"RightLowerArm": Vector3(-10, 0, 0),
	}


func _takeoff(t: float, _length: float) -> Dictionary:
	return _poses.keyed(t, [
		[0.0, _standing()],
		[0.18, _crouch_pose(1.0)],
		[0.36, _launch_pose()],
		[0.8, _hover(0.0, 3.0)],
	])


# Played on touchdown: the feet reach the floor, the knees take the weight,
# and the body comes up to stand.
func _land(t: float, _length: float) -> Dictionary:
	var reach := _hover_pose()
	reach["_hips"] = Vector3(0, 0.06, 0)
	for bone in ["LeftUpperLeg", "LeftLowerLeg", "RightUpperLeg", "RightLowerLeg"]:
		reach[bone] = reach[bone] * 0.3
	reach["LeftFoot"] = Vector3(15, 0, 0)
	reach["RightFoot"] = Vector3(15, 0, 0)
	var absorb := _crouch_pose(0.75)
	absorb["LeftUpperArm"] = Vector3(-6, 0, 24)
	absorb["RightUpperArm"] = Vector3(-6, 0, -24)
	return _poses.keyed(t, [
		[0.0, reach],
		[0.16, absorb],
		[0.7, _standing()],
	])

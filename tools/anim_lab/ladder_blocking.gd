extends RefCounted

# Blocking for getting off the ladder at the top: the key poses only,
# stepped, before any breakdowns. The rails stop at the landing's edge, so
# the way off is a climb-over: the climb stops with the hips about level
# with the landing, the hands go flat on it, a knee comes up onto the edge,
# then a foot, and the climber stands.
#
# Poses are in the frame of the climb's last point, the root still: what the
# root's walk onto the landing covers comes off the hips when the clip is
# played (see the generator).

const PoseBuilder := preload("res://tools/pose_builder.gd")

const FINGERS := ["Index", "Middle", "Ring", "Little"]
const HANDS_APART := 0.22
# The grip point's height over the palm laid flat.
const POLE_OUT := 4.0
const POLE_DOWN := -0.3
const PALM := 0.035
# A kneeling shin: its length from knee to ankle along the floor, and how
# high the ankle rides off it.
const SHIN := 0.42
const SHIN_ON_FLOOR := 0.06
# The kneeling foot laid on its instep, the toes pointing back.
const KNEEL_FOOT_PITCH := 180.0

var _poses: PoseBuilder
## The climb cycle these poses start from, and the height one cycle
## climbs (its "rise" metadata). Unset, the saved Climb_Up; the generator
## sets the one it has just built, so a rebuilt climb never pairs with a
## stale one.
var climb_clip: Animation


func build(poses: PoseBuilder) -> Dictionary:
	_poses = poses
	if climb_clip == null:
		climb_clip = (load("res://assets/ladder_animations.tres") as AnimationLibrary).get_animation("Climb_Up")
	# Both feet on one rung, the left hand high on the rungs, the right on
	# its rail: where the cycle starts.
	poses.add_clip_base("climb", climb_clip, 0.0)
	return {
		"climb_over_top": {"length": 2.4, "loops": false, "eased": false, "keys": _climb_over()},
		"climb_on_top": {"length": 2.4, "loops": false, "eased": false, "keys": _reversed(_climb_over(), 2.4)},
	}


# Getting on at the top is getting off run backwards: back to the drop,
# down onto a knee, hands flat, a foot lowered to find a rung.
static func _reversed(keys: Array, length: float) -> Array:
	var out := []
	for i in range(keys.size() - 1, -1, -1):
		var k: Array = keys[i]
		out.append([length - k[0], k[1], k[2]])
	return out


func _climb_over() -> Array:
	var rise: float = climb_clip.get_meta("rise")
	# The climb stops Ladder.OVER_RUNGS below the landing, the hips about
	# level with its floor, so the hands can go flat on it.
	var landing := Ladder.OVER_RUNGS * rise
	var climb := {"_base": "climb"}
	var left_rung := _foot(climb, "Left")
	var right_rung := _foot(climb, "Right")
	var climb_hips := _at(climb, "Hips")

	# Both hands off the rungs and flat on the landing, the chest coming
	# over the edge.
	var reach := {"_base": "climb"}
	_hips_to(reach, climb_hips + Vector3(0, 0.05, 0.08))
	PoseBuilder.add(reach, "Spine", Vector3(15, 0, 0))
	_plant_both(reach, left_rung, right_rung)
	_flat_hands(reach, landing, 0.5)

	# The right foot a rung higher, the arms pushing the body up over the
	# hands.
	var push := {"_base": "climb"}
	_hips_to(push, Vector3(0, climb_hips.y + 0.24, 0.08))
	PoseBuilder.add(push, "Spine", Vector3(45, 0, 0))
	_plant_both(push, left_rung, _up(right_rung, rise))
	_flat_hands(push, landing, 0.45)

	# The right knee onto the landing, the shin along the floor and the
	# toes over the edge; the left foot two rungs up, the hands walked on.
	var knee_down := _knee_on_floor("Right", landing, Vector3(-0.1, 0, 0.68))
	var kneel := {"_base": "climb"}
	_hips_to(kneel, Vector3(-0.03, landing + 0.3, 0.5))
	PoseBuilder.add(kneel, "Spine", Vector3(40, 0, 0))
	_plant_both(kneel, _up(left_rung, 2.0 * rise), knee_down)
	_flat_hands(kneel, landing, 0.85)

	# Breakdowns. The hands off the rungs, going up and over the edge.
	var lift := {"_base": "climb"}
	_hips_to(lift, climb_hips + Vector3(0, 0.02, 0.03))
	PoseBuilder.add(lift, "Spine", Vector3(8, 0, 0))
	_plant_both(lift, left_rung, right_rung)
	_flat_hands(lift, landing + 0.12, 0.3)

	# The right knee drawn up past the edge, the foot off its rung and
	# pitching back to lie on its instep.
	var knee_up := {"_base": "climb"}
	_hips_to(knee_up, Vector3(-0.02, landing + 0.25, 0.3))
	PoseBuilder.add(knee_up, "Spine", Vector3(45, 0, 0))
	var foot_swing := _foot(_poses.standing(), "Right")
	foot_swing.origin = Vector3(-0.1, landing + 0.12, 0.12)
	foot_swing.basis = Basis(Vector3.RIGHT, deg_to_rad(KNEEL_FOOT_PITCH * 0.5)) * foot_swing.basis
	_poses.plant(knee_up, "Left", _up(left_rung, rise), Vector3(0.2, 0, 1))
	_poses.plant(knee_up, "Right", foot_swing, Vector3(-0.2, 0, 1))
	_flat_hands(knee_up, landing, 0.6)

	# The left foot lifted over the edge, on its way to the floor.
	var foot_over := {"_base": "climb"}
	_hips_to(foot_over, Vector3(0, landing + 0.33, 0.6))
	PoseBuilder.add(foot_over, "Spine", Vector3(32, 0, 0))
	_poses.plant(foot_over, "Left", _on_floor("Left", Vector3(0.3, landing + 0.12, 0.42)), Vector3(0.5, 0, 1))
	_poses.plant(foot_over, "Right", knee_down, Vector3(-0.2, -1, 1))
	_flat_hands(foot_over, landing, 0.85)

	# The left foot up onto the landing beside the hands, the body rising
	# off them, the right knee still down.
	var rise_up := {"_base": "idle"}
	_hips_to(rise_up, Vector3(0.02, landing + 0.42, 0.72))
	PoseBuilder.add(rise_up, "Spine", Vector3(20, 0, 0))
	_poses.plant(rise_up, "Left", _on_floor("Left", Vector3(0.13, landing, 0.95)), Vector3(0.2, 0, 1))
	_poses.plant(rise_up, "Right", knee_down, Vector3(-0.2, -1, 1))

	# Standing on the landing, clear of the edge: Idle exactly, its soles
	# on the landing as Idle's are on any floor, so the walk on picks it up
	# without a pop.
	var stand := {"_base": "idle"}
	_hips_to(stand, _at(stand, "Hips") + Vector3(0, landing, Ladder.OVER_REACH))

	return [
		[0.0, "climb", climb],
		[0.22, "lift", lift],
		[0.45, "reach", reach],
		[0.9, "push", push],
		[1.12, "knee up", knee_up],
		[1.35, "kneel", kneel],
		[1.6, "foot over", foot_over],
		[1.85, "rise", rise_up],
		[2.4, "stand", stand],
	]


# The foot `by` higher, on the rung above.
static func _up(foot: Transform3D, by: float) -> Transform3D:
	foot.origin.y += by
	return foot


# Puts the pose's hips at `at`, in the skeleton's space.
func _hips_to(pose: Dictionary, at: Vector3) -> void:
	pose["_hips"] = at - _at({"_base": pose["_base"]}, "Hips")


# The `side` foot where the knee is down at `knee` on the floor at height
# `floor_y` and the shin lies back along it, the instep on the floor.
func _knee_on_floor(side: String, floor_y: float, knee: Vector3) -> Transform3D:
	var foot := _foot(_poses.standing(), side)
	foot.origin = Vector3(knee.x, floor_y + SHIN_ON_FLOOR, knee.z - SHIN)
	foot.basis = Basis(Vector3.RIGHT, deg_to_rad(KNEEL_FOOT_PITCH)) * foot.basis
	return foot


# Each palm flat on the floor at height `floor_y`, `ahead` of the climb
# line, the fingers forward and a little out.
func _flat_hands(pose: Dictionary, floor_y: float, ahead: float) -> void:
	for side: String in ["Left", "Right"]:
		var sign := 1.0 if side == "Left" else -1.0
		var at := Vector3(sign * HANDS_APART, floor_y + PALM, ahead)
		var fingers := Vector3(sign * 0.25, 0, 1).normalized()
		_fingers(pose, side, 0.1)
		# The rest pose is a T-pose, palms down, the hands out along X: the
		# hand turned about the vertical till it points along `fingers`.
		var skeleton: Skeleton3D = _poses._skeleton
		var rest := skeleton.get_bone_global_rest(skeleton.find_bone(side + "Hand")).basis.orthonormalized()
		var out := Vector3(sign, 0, 0)
		var turned := Basis(Quaternion(out, fingers)) * rest
		var grip: Node3D = _poses._model.main_hand_grip if side == "Right" else _poses._model.off_hand_grip
		var wanted := turned * grip.transform.basis.orthonormalized()
		_poses.grasp(pose, side, at, wanted.z, wanted.y, Vector3(sign * POLE_OUT, POLE_DOWN, -1), true)


func _foot(pose: Dictionary, side: String) -> Transform3D:
	return _poses.bone_transform(_poses.resolve(pose), side + "Foot")


# The `side` foot flat on the floor at `at` (its ankle's spot over the
# floor), as Idle stands it.
func _on_floor(side: String, at: Vector3) -> Transform3D:
	var foot := _foot(_poses.standing(), side)
	foot.origin = Vector3(at.x, foot.origin.y + at.y, at.z)
	return foot


func _plant_both(pose: Dictionary, left: Transform3D, right: Transform3D) -> void:
	_poses.plant(pose, "Left", left, Vector3(0.2, 0, 1))
	_poses.plant(pose, "Right", right, Vector3(-0.2, 0, 1))


func _at(pose: Dictionary, bone: String) -> Vector3:
	return _poses.bone_transform(_poses.resolve(pose), bone).origin


static func _fingers(pose: Dictionary, side: String, curl: float) -> void:
	var roll := curl if side == "Right" else -curl
	for finger: String in FINGERS:
		PoseBuilder.add(pose, "%s%sProximal" % [side, finger], Vector3(0, 0, 55 * roll))
		PoseBuilder.add(pose, "%s%sIntermediate" % [side, finger], Vector3(0, 0, 75 * roll))
		PoseBuilder.add(pose, "%s%sDistal" % [side, finger], Vector3(0, 0, 45 * roll))



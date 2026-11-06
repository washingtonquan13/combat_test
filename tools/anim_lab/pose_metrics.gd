extends RefCounted

# Measures a posed GeneralSkeleton the way an animator checks a pose: where
# the weight is over the feet, how far each joint is bent against what a
# body allows, how the torso leans and twists. Everything is in the
# character's frame (the model faces +Z, its left is +X, Y up), read from
# the skeleton's current bone poses, so it measures whatever set them: a
# clip, a key pose, the game.
#
# The joint frames come from the rest pose, a T-pose with the palms down and
# the thumbs forward: each elbow and knee's hinge, each palm and thumb, is
# taken there in its bone's own frame and carried along with the bone. A
# hinge that ends up bending another way than its bone says, or a hand
# twisted on its forearm, is what a mesh shows as a broken elbow or a
# candy-wrapped wrist.

# Segment masses as fractions of the body (Dempster), and where along each
# segment its centre lies, from the proximal end.
const SEGMENTS := [
	# [from, to, mass, along]
	["Hips", "Neck", 0.497, 0.5],
	["Neck", "_head_top", 0.081, 0.5],
	["LeftUpperArm", "LeftLowerArm", 0.028, 0.436],
	["RightUpperArm", "RightLowerArm", 0.028, 0.436],
	["LeftLowerArm", "LeftHand", 0.016, 0.43],
	["RightLowerArm", "RightHand", 0.016, 0.43],
	["LeftHand", "LeftMiddleProximal", 0.006, 0.5],
	["RightHand", "RightMiddleProximal", 0.006, 0.5],
	["LeftUpperLeg", "LeftLowerLeg", 0.1, 0.433],
	["RightUpperLeg", "RightLowerLeg", 0.1, 0.433],
	["LeftLowerLeg", "LeftFoot", 0.0465, 0.433],
	["RightLowerLeg", "RightFoot", 0.0465, 0.433],
	["LeftFoot", "ball_leaf_l", 0.0145, 0.5],
	["RightFoot", "ball_leaf_r", 0.0145, 0.5],
]

# Joint limits, degrees.
const ELBOW_MAX := 150.0
const KNEE_MAX := 140.0
const HYPEREXTEND := -5.0
# Palm flexion / extension, radial / ulnar deviation.
const WRIST_FLEX := 70.0
const WRIST_EXTEND := 60.0
const WRIST_RADIAL := 20.0
const WRIST_ULNAR := 35.0
# The hand turned about its length against the forearm bone: there is no
# twist bone, so past this the wrist's mesh wrings.
const WRIST_TWIST := 40.0
# Pronation from the handshake (thumb up), either way.
const PRONATION := 90.0
# A bend whose plane is this far off its hinge reads as a broken joint.
const HINGE_OFF := 30.0
# The off hand this far from its mark on the weapon is not holding it.
const CONTACT := 0.03
const HEAD_ABOVE_NECK := 0.2

var _skeleton: Skeleton3D
# Rest-pose frames, each in its bone's own space.
var _hinge := {}
var _palm := {}
var _thumb := {}
var _length_axis := {}


func _init(skeleton: Skeleton3D) -> void:
	_skeleton = skeleton
	for side: String in ["Left", "Right"]:
		var out := 1.0 if side == "Left" else -1.0
		var upper := _rest(side + "UpperArm")
		# The arm out along X: the elbow brings the forearm forward, so the
		# hinge is arm x forward.
		_hinge[side + "Arm"] = upper.inverse() * Vector3(out, 0, 0).cross(Vector3.FORWARD * -1.0).normalized()
		# The leg down: the knee takes the shin back, -Y x -Z = +X.
		_hinge[side + "Leg"] = _rest(side + "UpperLeg").inverse() * Vector3.RIGHT
		var hand := _rest(side + "Hand")
		var along := (_rest_origin(side + "MiddleProximal") - _rest_origin(side + "Hand")).normalized()
		var palm := (Vector3.DOWN - along * Vector3.DOWN.dot(along)).normalized()
		_length_axis[side] = hand.inverse() * along
		_palm[side] = hand.inverse() * palm
		_thumb[side] = hand.inverse() * along.cross(palm).normalized() * (1.0 if side == "Right" else -1.0)
		_palm[side + "Fore"] = _rest(side + "LowerArm").inverse() * palm


func _rest(bone: String) -> Basis:
	return _skeleton.get_bone_global_rest(_skeleton.find_bone(bone)).basis.orthonormalized()


func _rest_origin(bone: String) -> Vector3:
	return _skeleton.get_bone_global_rest(_skeleton.find_bone(bone)).origin


# A bone's current transform in the skeleton's space. "_head_top" is a point
# above the head, for the head's segment.
func pose_of(bone: String) -> Transform3D:
	if bone == "_head_top":
		var head := pose_of("Head")
		return Transform3D(head.basis, head.origin + head.basis.orthonormalized().y * HEAD_ABOVE_NECK)
	return _skeleton.get_bone_global_pose(_skeleton.find_bone(bone))


func at(bone: String) -> Vector3:
	return pose_of(bone).origin


func centre_of_mass() -> Vector3:
	var sum := Vector3.ZERO
	var mass := 0.0
	for s: Array in SEGMENTS:
		sum += at(s[0]).lerp(at(s[1]), s[3]) * s[2]
		mass += s[2]
	return sum / mass


# Each foot's sole as four corners on the ground: heel behind the ankle,
# toe past the ball, the foot's width either side.
func foot_corners(side: String) -> PackedVector3Array:
	var s := "l" if side == "Left" else "r"
	var ankle := at(side + "Foot")
	var ball := at("ball_leaf_" + s)
	var along := Vector3(ball.x - ankle.x, 0, ball.z - ankle.z)
	var forward := along.normalized()
	var across := forward.cross(Vector3.UP) * 0.045
	var heel := Vector3(ankle.x, 0, ankle.z) - forward * 0.06
	var toe := Vector3(ball.x, 0, ball.z) + forward * 0.03
	return PackedVector3Array([heel - across, toe - across, toe + across, heel + across])


# The support polygon: the hull of both soles, on the ground. A foot lifted
# more than a few centimetres bears nothing and is left out.
func support() -> PackedVector2Array:
	var points := PackedVector2Array()
	for side: String in ["Left", "Right"]:
		if _sole_height(side) > 0.04:
			continue
		for c in foot_corners(side):
			points.append(Vector2(c.x, c.z))
	return Geometry2D.convex_hull(points) if points.size() >= 3 else points


func _sole_height(side: String) -> float:
	var s := "l" if side == "Left" else "r"
	# The ankle bone sits above the sole; the ball leaf is on it.
	return minf(at(side + "Foot").y - _rest_origin(side + "Foot").y, at("ball_leaf_" + s).y - _rest_origin("ball_leaf_" + s).y)


# Bend at a hinge: positive the way it bends, negative past straight, and
# how far the bend's plane is off the hinge its bone carries.
func _hinge_bend(upper: String, lower: String, end: String, hinge_key: String) -> Vector2:
	var a := at(upper)
	var b := at(lower)
	var c := at(end)
	var u := (b - a).normalized()
	var f := (c - b).normalized()
	var angle := rad_to_deg(u.angle_to(f))
	var hinge: Vector3 = pose_of(upper).basis.orthonormalized() * _hinge[hinge_key]
	var axis := u.cross(f)
	if axis.length() < 0.05:
		return Vector2(angle, 0.0)
	axis = axis.normalized()
	var off := rad_to_deg(axis.angle_to(hinge))
	if off > 90.0:
		return Vector2(-angle, 180.0 - off)
	return Vector2(angle, off)


# The wrist: flexion (+ toward the palm), deviation (+ toward the thumb),
# the hand's twist on the forearm bone, and pronation from the handshake.
func _wrist(side: String) -> Dictionary:
	var hand := pose_of(side + "Hand").basis.orthonormalized()
	var h: Vector3 = hand * _length_axis[side]
	var p: Vector3 = hand * _palm[side]
	var r: Vector3 = hand * _thumb[side]
	var f := (at(side + "Hand") - at(side + "LowerArm")).normalized()
	var flex := rad_to_deg(atan2(-f.dot(p), f.dot(h)))
	var dev := rad_to_deg(atan2(-f.dot(r), f.dot(h)))
	var fore_palm: Vector3 = pose_of(side + "LowerArm").basis.orthonormalized() * _palm[side + "Fore"]
	var twist := rad_to_deg(_about(fore_palm, p, h))
	# Handshake: the thumb the way the forearm flexes (hinge x forearm), palm
	# facing in. The T-pose's palms-down, thumbs-forward hand is that.
	var hinge: Vector3 = pose_of(side + "UpperArm").basis.orthonormalized() * _hinge[side + "Arm"]
	var neutral := hinge.cross(f)
	var pron := rad_to_deg(_about(neutral, r, f))
	return {"flex": flex, "dev": dev, "twist": twist, "pron": pron}


# The signed angle from a to b turning about axis, both flattened onto the
# plane across it.
static func _about(a: Vector3, b: Vector3, axis: Vector3) -> float:
	var a2 := (a - axis * a.dot(axis)).normalized()
	var b2 := (b - axis * b.dot(axis)).normalized()
	return atan2(axis.dot(a2.cross(b2)), a2.dot(b2))


static func _yaw(v: Vector3) -> float:
	return rad_to_deg(atan2(-v.z, v.x))


# Everything measured, and a line for each limit broken. `contact`, if
# given, is [where the off hand's grip is, where it should be], both in
# skeleton space.
func measure(contact: Array = []) -> Dictionary:
	var m := {}
	var flags: Array[String] = []
	var com := centre_of_mass()
	m["com"] = com
	var hull := support()
	var com2 := Vector2(com.x, com.z)
	m["support"] = hull
	m["inside"] = hull.size() >= 3 and Geometry2D.is_point_in_polygon(com2, hull)
	m["margin"] = _edge_distance(com2, hull) * (1.0 if m["inside"] else -1.0)
	if not m["inside"]:
		flags.append("COM outside the feet by %.0f cm" % (-m["margin"] * 100.0))
	var left := at("LeftFoot")
	var right := at("RightFoot")
	var span := Vector2(left.x - right.x, left.z - right.z)
	var share := clampf(Vector2(com.x - right.x, com.z - right.z).dot(span) / maxf(span.length_squared(), 1e-6), 0.0, 1.0)
	m["weight_left"] = share
	for side: String in ["Left", "Right"]:
		var elbow := _hinge_bend(side + "UpperArm", side + "LowerArm", side + "Hand", side + "Arm")
		var knee := _hinge_bend(side + "UpperLeg", side + "LowerLeg", side + "Foot", side + "Leg")
		var wrist := _wrist(side)
		m[side + "Elbow"] = elbow
		m[side + "Knee"] = knee
		m[side + "Wrist"] = wrist
		if elbow.x > ELBOW_MAX or elbow.x < HYPEREXTEND:
			flags.append("%s elbow %.0f deg" % [side, elbow.x])
		if elbow.x > 15.0 and elbow.y > HINGE_OFF:
			flags.append("%s elbow bends %.0f deg off its hinge" % [side, elbow.y])
		if knee.x > KNEE_MAX or knee.x < HYPEREXTEND:
			flags.append("%s knee %.0f deg" % [side, knee.x])
		if knee.x > 15.0 and knee.y > HINGE_OFF:
			flags.append("%s knee bends %.0f deg off its hinge" % [side, knee.y])
		if wrist["flex"] > WRIST_FLEX or wrist["flex"] < -WRIST_EXTEND:
			flags.append("%s wrist flexion %.0f" % [side, wrist["flex"]])
		if wrist["dev"] > WRIST_RADIAL or wrist["dev"] < -WRIST_ULNAR:
			flags.append("%s wrist deviation %.0f" % [side, wrist["dev"]])
		if absf(wrist["twist"]) > WRIST_TWIST:
			flags.append("%s hand twisted %.0f on the forearm" % [side, wrist["twist"]])
		if absf(wrist["pron"]) > PRONATION:
			flags.append("%s forearm turned %.0f past the handshake" % [side, wrist["pron"]])
		var sole := _sole_height(side)
		m[side + "Sole"] = sole
		if sole < -0.015:
			flags.append("%s foot %.0f cm in the ground" % [side, -sole * 100.0])
	if m["LeftSole"] > 0.02 and m["RightSole"] > 0.02:
		flags.append("both feet off the ground")
	# The trunk: lean of hips-to-neck, and the shoulders' turn on the hips.
	var trunk := at("Neck") - at("Hips")
	m["lean_forward"] = rad_to_deg(atan2(trunk.z, trunk.y))
	m["lean_side"] = rad_to_deg(atan2(trunk.x, trunk.y))
	var hips_yaw := _yaw(at("LeftUpperLeg") - at("RightUpperLeg"))
	var shoulders_yaw := _yaw(at("LeftUpperArm") - at("RightUpperArm"))
	m["hips_yaw"] = hips_yaw
	m["shoulders_yaw"] = shoulders_yaw
	var head := pose_of("Head").basis.orthonormalized() * (_rest("Head").inverse() * Vector3.BACK)
	m["head_pitch"] = rad_to_deg(asin(clampf(-head.y, -1.0, 1.0)))
	m["head_yaw"] = rad_to_deg(atan2(head.x, head.z))
	if absf(wrapf(m["head_yaw"] - (shoulders_yaw), -180.0, 180.0)) > 75.0:
		flags.append("head turned %.0f on the shoulders" % wrapf(m["head_yaw"] - shoulders_yaw, -180.0, 180.0))
	if contact.size() == 2:
		var miss: float = (contact[0] as Vector3).distance_to(contact[1])
		m["contact"] = miss
		if miss > CONTACT:
			flags.append("off hand %.0f cm from the weapon" % (miss * 100.0))
	m["flags"] = flags
	return m


static func _edge_distance(p: Vector2, hull: PackedVector2Array) -> float:
	if hull.size() < 2:
		return 0.0
	var best := INF
	for i in hull.size():
		var a := hull[i]
		var b := hull[(i + 1) % hull.size()]
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


# The measures as lines of text for a readout.
static func report(m: Dictionary) -> String:
	var lines: Array[String] = []
	var com: Vector3 = m["com"]
	lines.append("COM  x %+.0f  y %.0f  z %+.0f cm   margin %+.0f cm" % [com.x * 100, com.y * 100, com.z * 100, m["margin"] * 100])
	lines.append("weight  L %.0f%%  R %.0f%%" % [m["weight_left"] * 100, (1.0 - m["weight_left"]) * 100])
	lines.append("trunk lean  fwd %+.0f  side %+.0f" % [m["lean_forward"], m["lean_side"]])
	lines.append("yaw  hips %+.0f  shoulders %+.0f  head %+.0f (pitch %+.0f)" % [m["hips_yaw"], m["shoulders_yaw"], m["head_yaw"], m["head_pitch"]])
	for side: String in ["Left", "Right"]:
		var e: Vector2 = m[side + "Elbow"]
		var k: Vector2 = m[side + "Knee"]
		var w: Dictionary = m[side + "Wrist"]
		lines.append("%s  elbow %.0f (off %.0f)  knee %.0f (off %.0f)" % [side[0], e.x, e.y, k.x, k.y])
		lines.append("   wrist flex %+.0f dev %+.0f twist %+.0f pron %+.0f  sole %+.1f cm" % [w["flex"], w["dev"], w["twist"], w["pron"], m[side + "Sole"] * 100])
	if m.has("contact"):
		lines.append("off hand to mark  %.1f cm" % (m["contact"] * 100))
	var flags: Array = m["flags"]
	lines.append("")
	lines.append("FLAGS: none" if flags.is_empty() else "FLAGS:")
	for f: String in flags:
		lines.append("  ! " + f)
	return "\n".join(lines)

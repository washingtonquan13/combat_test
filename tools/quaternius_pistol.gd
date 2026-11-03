extends RefCounted

# The pistol's stance, shot and reload, from the Quaternius pack (UAL1),
# fitted to our pistol, held in the right hand alone. At rest the unit
# stands square in the pack's Idle, the gun hanging at the right thigh, the
# forearm supinated, palm forward, the muzzle down and out from the body. To fire it shifts into the pack's one-handed stance,
# Spell_Simple_Idle, which the artist made for the left hand, mirrored - the
# body bladed, the right shoulder forward, the left arm low - with the arm
# straight out from the shoulder along the unit's facing, the gun level,
# kicked up by Pistol_Shoot's recoil. The hand is closed round the grip as
# Pistol_Idle's is. The reload is two handed, Pistol_Reload with the left
# hand carried with the gun as the artist held it, blended in from the rest
# and back out to it.

const PoseBuilder := preload("res://tools/pose_builder.gd")

const UAL1 := "res://assets/unit_animations.tres"
const REST := "Idle"
const ONE_HAND := "Spell_Simple_Idle"
# How far the hanging gun's muzzle is tipped out from straight down, away
# from the leg, in degrees.
const HANG_TIP := 40.0
# How much of the hanging hand's turn the upper arm takes, rolled out at the
# shoulder, in degrees; the forearm supinates the rest.
const SHOULDER_TURN := 85.0
# How far below level the arm is on its way up, in degrees.
const LIFT_DIP := 40.0
# Where the elbow of the gun arm points: down and out when aiming, back and
# out when hanging.
const GUN_POLE := Vector3(-0.5, -1.0, 0.0)
const HANG_POLE := Vector3(-0.3, 0.0, -1.0)
# The hanging arm: from the shoulder along HANG_ARM, a little out from the
# thigh, at HANG_REACH of its full length - straight, the elbow just soft.
const HANG_ARM := Vector3(-0.18, -1.0, 0.02)
const HANG_REACH := 0.98
# The left hand is on the gun within NEAR of where the reload clip holds it,
# off it past FAR.
const NEAR := 0.05
const FAR := 0.15
# How long the reload takes to come in from the stance and go back to it.
const BLEND := 0.3

var _poses: PoseBuilder
var _ual1: AnimationLibrary
# Our gun turned in the right hand to lie as the pistol clips' does, measured
# from Pistol_Idle's first frame: the barrel level along the clip's aim.
var _turn: Basis
# Where the reload clip's left hand is in the right hand's grip space when it
# holds the gun: cupped under the wrist.
var _clip_off_hand: Transform3D
# Pistol_Idle's right fingers, closed round its grip.
var _closed: Dictionary
# How far Pistol_Shoot's barrel is pitched up from its aim, in degrees.
var _aim_pitch: float
# The right elbow's hinge in the upper arm's space: with the arm out to the
# side the elbow brings the forearm forward.
var _hinge: Vector3


func _init(poses: PoseBuilder) -> void:
	_poses = poses
	_ual1 = load(UAL1)
	var idle := _sample("Pistol_Idle", 0.0)
	var aim := _frame(idle)
	var grip := _poses.grip_transform(aim, "Right")
	var barrel := Vector3(grip.basis.z.x, 0, grip.basis.z.z).normalized()
	var x := Vector3.UP.cross(barrel).normalized()
	_turn = grip.basis.inverse() * Basis(x, barrel.cross(x), barrel)
	_clip_off_hand = grip.affine_inverse() * _poses.grip_transform(aim, "Left")
	for bone: String in idle:
		if bone.begins_with("Right") and _is_finger(bone):
			_closed[bone] = idle[bone]
	_aim_pitch = _pitch(0.0)
	var skeleton := _poses._skeleton
	var upper := skeleton.get_bone_global_rest(skeleton.find_bone("RightUpperArm")).basis.orthonormalized()
	_hinge = upper.inverse() * Vector3.LEFT.cross(Vector3.BACK).normalized()


# Standing square, the gun hanging at the thigh.
func stance() -> Animation:
	var anim := _ual1.get_animation(REST)
	return _poses.clip(anim.length, true, func(t: float, _length: float) -> Dictionary:
		return _hang(t))


# The stance's first frame: where a shot is raised from and lowered to.
func ready() -> Dictionary:
	return _hang(0.0)


# Halfway up: turned into the firing stance, the arm out low ahead.
func lifted() -> Dictionary:
	return _aim(-LIFT_DIP)


# The firing stance `since` seconds after a shot, the arm kicked up by the
# recoil and settled by 0.25.
func aimed(since: float) -> Dictionary:
	return _aim(_pitch(clampf(since, 0.0, 0.25)) - _aim_pitch)


func reload() -> Animation:
	var anim := _ual1.get_animation("Pistol_Reload")
	var from := _poses.resolve(ready())
	return _poses.clip(anim.length, false, func(t: float, length: float) -> Dictionary:
		var pose := _poses.resolve(_fit(_frame(_sample("Pistol_Reload", t))))
		var stance_weight := 1.0 - smoothstep(0.0, BLEND, t) + smoothstep(length - BLEND, length, t)
		return _poses._blend(pose, from, stance_weight))


# The Idle at t, the right hand closed on the gun where it hangs, the
# muzzle down and tipped a little forward, the top of the gun forward.
func _hang(t: float) -> Dictionary:
	var anim := _ual1.get_animation(REST)
	var sample := _sample(REST, fmod(t, anim.length))
	sample.merge(_closed, true)
	var pose := _frame(sample)
	var resolved := _poses.resolve(pose)
	var shoulder := _poses.bone_transform(resolved, "RightUpperArm").origin
	var elbow := _poses.bone_transform(resolved, "RightLowerArm").origin
	var wrist := _poses.bone_transform(resolved, "RightHand").origin
	var grip := _poses.grip_transform(pose, "Right").origin
	var length := shoulder.distance_to(elbow) + elbow.distance_to(wrist) + wrist.distance_to(grip)
	var hand := shoulder + HANG_ARM.normalized() * length * HANG_REACH
	# The character's right is -X: the thumb, and the gun's top, turned out
	# there by the whole arm, the shoulder rolling it out SHOULDER_TURN and
	# the forearm supinating the rest.
	var tip := Basis(Vector3.FORWARD, deg_to_rad(HANG_TIP))
	var neutral := Basis(Vector3.UP, -deg_to_rad(SHOULDER_TURN)) * Vector3.BACK
	_hold_gun(pose, hand, tip * Vector3.DOWN, tip * Vector3.LEFT, HANG_POLE, neutral)
	return pose


# The mirrored one-handed stance, the arm straight out from the shoulder
# along the unit's facing (+Z), the gun level, kicked `kick` degrees up.
func _aim(kick: float) -> Dictionary:
	var sample := _mirror(_sample(ONE_HAND, 0.0))
	sample.merge(_closed, true)
	var pose := _frame(sample)
	var shoulder := _poses.bone_transform(_poses.resolve(pose), "RightUpperArm").origin
	var reach := shoulder.distance_to(_poses.grip_transform(pose, "Right").origin)
	var up := Basis(Vector3.LEFT, deg_to_rad(kick))
	_hold_gun(pose, shoulder + up * Vector3.BACK * reach, up * Vector3.BACK, up * Vector3.UP, GUN_POLE)
	return pose


# The right hand on the gun's grip at `at`, the barrel along `barrel`, its
# top toward `top`, the elbow toward `pole`, the arm turned to a handshake
# on it - or, given `neutral`, to where the thumb would point in a handshake,
# the rest of the hand's turn taken by the forearm.
func _hold_gun(pose: Dictionary, at: Vector3, barrel: Vector3, top: Vector3, pole: Vector3,
		neutral := Vector3.ZERO) -> void:
	_poses.grasp(pose, "Right", at, barrel, top, pole)
	_roll_arm(pose, top if neutral == Vector3.ZERO else neutral)
	_poses.hold(pose, "Right", barrel, top)


# The arm turned from the Spell clip's open palm-out reach to a handshake
# on the grip: swivelled about the shoulder-wrist line so the elbow bends
# the way the thumb points, then the hand's remaining twist on the forearm
# taken by the forearm, which is where the wrist's roll lives.
func _roll_arm(pose: Dictionary, thumb: Vector3) -> void:
	var skeleton := _poses._skeleton
	var resolved := _poses.resolve(pose)
	var upper := _poses.bone_transform(resolved, "RightUpperArm")
	var lower := _poses.bone_transform(resolved, "RightLowerArm")
	var wrist := _poses.bone_transform(resolved, "RightHand").origin
	var line := (wrist - upper.origin).normalized()
	var fore := (wrist - lower.origin).normalized()
	var hinge := upper.basis * _hinge
	var wanted := fore.cross(thumb)
	var from := (hinge - line * hinge.dot(line)).normalized()
	var to := (wanted - line * wanted.dot(line)).normalized()
	var swivel := Basis(line, from.signed_angle_to(to, line))
	var parent := _poses.bone_transform(resolved, skeleton.get_bone_name(
		skeleton.get_bone_parent(skeleton.find_bone("RightUpperArm")))).basis
	_poses._set_local(pose, "RightUpperArm", parent.inverse() * swivel * upper.basis)
	resolved = _poses.resolve(pose)
	var upper_basis := _poses.bone_transform(resolved, "RightUpperArm").basis
	var lower_basis := _poses.bone_transform(resolved, "RightLowerArm").basis
	var hand := _poses.bone_transform(resolved, "RightHand").basis
	var along := skeleton.get_bone_rest(skeleton.find_bone("RightHand")).origin.normalized()
	var q := (lower_basis.inverse() * hand).get_rotation_quaternion()
	var p := along * Vector3(q.x, q.y, q.z).dot(along)
	var twist := Quaternion(p.x, p.y, p.z, q.w).normalized()
	_poses._set_local(pose, "RightLowerArm", upper_basis.inverse() * lower_basis * Basis(twist))


# Pistol_Shoot's barrel pitch at t, in degrees.
func _pitch(t: float) -> float:
	var grip := _poses.grip_transform(_frame(_sample("Pistol_Shoot", t)), "Right")
	return rad_to_deg(asin(clampf(grip.basis.z.y, -1.0, 1.0)))


# A sample mirrored left for right: the character's left is +X.
static func _mirror(sample: Dictionary) -> Dictionary:
	var out := {}
	for bone: String in sample:
		if bone == "_hips":
			var hips: Vector3 = sample[bone]
			out[bone] = Vector3(-hips.x, hips.y, hips.z)
			continue
		var q: Quaternion = sample[bone]
		var other := bone.replace("Left", "@").replace("Right", "Left").replace("@", "Right")
		out[other] = Quaternion(q.x, -q.y, -q.z, q.w)
	return out


static func _is_finger(bone: String) -> bool:
	for finger: String in ["Thumb", "Index", "Middle", "Ring", "Little"]:
		if bone.contains(finger):
			return true
	return false


# A clip's frame at t: bone -> local rotation, and the Hips position.
func _sample(clip: String, t: float) -> Dictionary:
	var anim := _ual1.get_animation(clip)
	var out := {}
	for track in anim.get_track_count():
		var bone := String(anim.track_get_path(track)).get_slice(":", 1)
		match anim.track_get_type(track):
			Animation.TYPE_ROTATION_3D:
				out[bone] = anim.rotation_track_interpolate(track, t)
			Animation.TYPE_POSITION_3D:
				if bone == "Hips":
					out["_hips"] = anim.position_track_interpolate(track, t)
	return out


# A sample as a pose.
func _frame(sample: Dictionary) -> Dictionary:
	var pose := {}
	for bone: String in sample:
		if bone == "_hips":
			pose["_hips"] = sample["_hips"] - _poses._bases["neutral"]["hips"]
		elif _poses._skeleton.find_bone(bone) >= 0:
			_poses._set_local(pose, bone, Basis(sample[bone]))
	return pose


# The pistol clip's frame with our gun in the right hand and the left hand
# on it where the clip's is near its gun; elsewhere the left arm is left as
# the frame has it.
func _fit(pose: Dictionary) -> Dictionary:
	var resolved := _poses.resolve(pose)
	var grip := _poses.grip_transform(pose, "Right")
	var gun := Transform3D(grip.basis * _turn, grip.origin)
	var left := _poses.grip_transform(pose, "Left")
	var right_pole := _pole(resolved, "Right")
	var left_pole := _pole(resolved, "Left")
	var on := 1.0 - smoothstep(NEAR, FAR, left.origin.distance_to((grip * _clip_off_hand).origin))
	var held := gun * _clip_off_hand
	_poses.grasp(pose, "Right", gun.origin, gun.basis.z, gun.basis.y, right_pole)
	if on > 0.0:
		_poses.grasp(pose, "Left", left.origin.lerp(held.origin, on),
			left.basis.z.lerp(held.basis.z, on), left.basis.y.lerp(held.basis.y, on), left_pole)
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


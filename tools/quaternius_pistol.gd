extends RefCounted

# The pistol's stance, shot and reload, from the Quaternius pack (UAL1),
# fitted to our pistol. The pistol is held in the right hand alone, in the
# pack's one-handed stance: Spell_Simple_Idle, which the artist made for the
# left hand, mirrored - the body bladed, the right shoulder forward, the arm
# out at shoulder height and the left arm low. Its open hand is closed round
# the grip as Pistol_Idle's is and given our gun, the barrel along the arm,
# level. The low ready is that arm swung down about the shoulder; a shot is
# the arm raised to level with Pistol_Shoot's recoil kick. The reload is two
# handed, Pistol_Reload with the left hand carried with the gun as the artist
# held it, blended in from the stance and back out to it.

const PoseBuilder := preload("res://tools/pose_builder.gd")

const UAL1 := "res://assets/unit_animations.tres"
const ONE_HAND := "Spell_Simple_Idle"
# How far the low ready points the gun down from level, in degrees.
const READY_DROP := 45.0
# Where the elbow of the gun arm points: down and out.
const GUN_POLE := Vector3(-0.5, -1.0, 0.0)
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


# The low ready, breathing with the one-handed stance.
func stance() -> Animation:
	var anim := _ual1.get_animation(ONE_HAND)
	return _poses.clip(anim.length, true, func(t: float, _length: float) -> Dictionary:
		return _one_hand(t, READY_DROP))


# The stance's first frame: where a shot is raised from and lowered to.
func ready() -> Dictionary:
	return _one_hand(0.0, READY_DROP)


# The arm raised level `since` seconds after a shot, kicked up by the recoil
# and settled by 0.25.
func aimed(since: float) -> Dictionary:
	return _one_hand(0.0, -(_pitch(clampf(since, 0.0, 0.25)) - _aim_pitch))


func reload() -> Animation:
	var anim := _ual1.get_animation("Pistol_Reload")
	var from := _poses.resolve(ready())
	return _poses.clip(anim.length, false, func(t: float, length: float) -> Dictionary:
		var pose := _poses.resolve(_fit(_frame(_sample("Pistol_Reload", t))))
		var stance_weight := 1.0 - smoothstep(0.0, BLEND, t) + smoothstep(length - BLEND, length, t)
		return _poses._blend(pose, from, stance_weight))


# The one-handed stance at t, the arm level at shoulder height and the gun
# level along it, then swung `drop` degrees down about the shoulder.
func _one_hand(t: float, drop: float) -> Dictionary:
	var anim := _ual1.get_animation(ONE_HAND)
	var sample := _mirror(_sample(ONE_HAND, fmod(t, anim.length)))
	sample.merge(_closed, true)
	var pose := _frame(sample)
	var shoulder := _poses.bone_transform(_poses.resolve(pose), "RightUpperArm").origin
	var hand := _poses.grip_transform(pose, "Right").origin
	var barrel := Vector3(hand.x - shoulder.x, 0, hand.z - shoulder.z).normalized()
	var x := Vector3.UP.cross(barrel).normalized()
	# The clip's arm reaches a little above level; level it first.
	var reach := Vector2(hand.x - shoulder.x, hand.z - shoulder.z).length()
	var raised := atan2(hand.y - shoulder.y, reach)
	var swing := Transform3D(Basis(x, raised + deg_to_rad(drop)), shoulder) * Transform3D(Basis(), -shoulder)
	var gun := swing * Transform3D(Basis(x, Vector3.UP, barrel), hand)
	_poses.grasp(pose, "Right", gun.origin, gun.basis.z, gun.basis.y, GUN_POLE)
	_roll_arm(pose, gun.basis.y)
	_poses.hold(pose, "Right", gun.basis.z, gun.basis.y)
	return pose


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


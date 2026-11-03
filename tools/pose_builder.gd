extends RefCounted

# Builds procedural clips for the UAL mannequin's GeneralSkeleton from key
# poses. Shared by the clip generators (make_flight_animations.gd,
# make_fireball_animations.gd).
#
# Every pose is a base with some bones turned. The base is NEUTRAL - the rest
# pose with the arms lowered, symmetric - unless the pose names "_base":
# "idle", the Idle clip's first frame exactly, which is what a clip that meets
# the ground animations starts or ends on so they join without a pop. Idle
# itself is no base for the rest: it stands mid weight-shift, one foot forward
# and one back, and every pose built on it inherited a stride. A turn is
# given in the CHARACTER's frame, not the bone's: +X pitches about the
# character's left-right axis (an upward bone tips forward, a downward one
# swings back), +Z rolls toward the character's left, +Y yaws to its left.
# The model faces +Z. Each turn is relative to the bone's parent, so a shin's
# bend is a bend at the knee wherever the thigh has gone. "_hips" moves the
# Hips from the base's position.

const MODEL := "res://scenes/character_models/placeholder_model.tscn"
const FPS := 30.0

# The arms' turn down from the rest T-pose to hang at the sides.
const ARMS_DOWN := 72.0

var _model: Node3D
var _skeleton: Skeleton3D
# base name -> {"local": bone -> Quaternion, "global": bone -> Basis in model
# space, "hips": the Hips position}
var _bases := {}


func _init() -> void:
	_model = load(MODEL).instantiate()
	_skeleton = _model.find_child("GeneralSkeleton", true, false)
	var player: AnimationPlayer = _model.find_child("AnimationPlayer", true, false)
	_read_bases(player.get_animation("Idle"))


func free_model() -> void:
	_model.free()


func standing() -> Dictionary:
	return {"_base": "idle"}


static func add(pose: Dictionary, bone: String, turn: Vector3) -> void:
	pose[bone] = pose.get(bone, Vector3.ZERO) + turn


# Sets the pose's "<side>Hand" turn so that what the hand holds - the scene
# on CharacterModel's grip for that side - lies with its +Z along `z_to` and
# its +Y as near `y_to` as that allows, both in the character's frame. The
# rest of the pose is taken as it stands, so call this last. A gun's barrel,
# a bow's face and a blade's edge are each one of the held scene's axes.
func hold(pose: Dictionary, side: String, z_to: Vector3, y_to: Vector3) -> void:
	pose.erase(side + "Hand")
	var resolved := resolve(pose)
	var bone := side + "Hand"
	var parent := _skeleton.get_bone_parent(_skeleton.find_bone(bone))
	var parent_global := Basis()
	while parent >= 0:
		parent_global = Basis(resolved[_skeleton.get_bone_name(parent)]) * parent_global
		parent = _skeleton.get_bone_parent(parent)
	var grip: Node3D = _model.main_hand_grip if side == "Right" else _model.off_hand_grip
	var z := z_to.normalized()
	var x := y_to.cross(z).normalized()
	var wanted := Basis(x, z.cross(x), z)
	# Skeleton space: parent_global * local * grip = wanted.
	var local := parent_global.inverse() * wanted * grip.transform.basis.orthonormalized().inverse()
	var base: Dictionary = _bases[pose.get("_base", "neutral")]
	var g: Basis = base["global"][bone]
	var turn := g * (Basis(base["local"][bone]).inverse() * local) * g.inverse()
	var euler := turn.get_euler()
	pose[bone] = Vector3(rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z))


# Puts what the `side` hand holds at `at` - a point in the skeleton's space,
# the character's frame - and lies it along `z_to` / `y_to` as hold() does:
# the arm is bent to bring the wrist where the grip needs it, the elbow
# swung toward `pole` (default down, back and out). For two hands on one
# weapon, grasp each side at its own point along the weapon. Call it last.
# `hinged` as reach() has it.
func grasp(pose: Dictionary, side: String, at: Vector3, z_to: Vector3, y_to: Vector3, pole := Vector3.ZERO, hinged := false) -> void:
	var grip: Node3D = _model.main_hand_grip if side == "Right" else _model.off_hand_grip
	var z := z_to.normalized()
	var x := y_to.cross(z).normalized()
	var hand := Basis(x, z.cross(x), z) * grip.transform.basis.orthonormalized().inverse()
	if pole == Vector3.ZERO:
		pole = Vector3(-0.5 if side == "Right" else 0.5, -1.0, -0.6)
	reach(pose, side, at - hand * grip.transform.origin, pole, hinged)
	hold(pose, side, z_to, y_to)


# Bends the `side` arm so its wrist lands on `wrist`, in the skeleton's space,
# the elbow swung toward `pole`. Out of reach, the arm points at it straight.
# The upper arm keeps the roll it had unless `hinged`, when it is rolled so
# the elbow bends the way an elbow does: wanted where the pole is far from
# where the arm was, or the elbow reads bent backwards.
func reach(pose: Dictionary, side: String, wrist: Vector3, pole: Vector3, hinged := false) -> void:
	var hinge := Vector3.ZERO
	if hinged:
		# The arm out along X in the rest pose bends the forearm forward.
		var out := Vector3.LEFT if side == "Right" else Vector3.RIGHT
		hinge = _skeleton.get_bone_global_rest(_skeleton.find_bone(side + "UpperArm")).basis.orthonormalized().inverse() * out.cross(Vector3.BACK)
	_limb(pose, side + "UpperArm", side + "LowerArm", side + "Hand", wrist, pole, hinge)


# Sets the `side` foot down at `foot` - its transform in the skeleton's space,
# as another pose had it - the leg bent to reach it, the knee swung toward
# `pole`. Moving the hips then leaves the feet where they stood.
func plant(pose: Dictionary, side: String, foot: Transform3D, pole: Vector3) -> void:
	_limb(pose, side + "UpperLeg", side + "LowerLeg", side + "Foot", foot.origin, pole)
	var bone := side + "Foot"
	var parent := _skeleton.get_bone_name(_skeleton.get_bone_parent(_skeleton.find_bone(bone)))
	pose.erase(bone)
	_set_local(pose, bone, bone_transform(resolve(pose), parent).basis.inverse() * foot.basis)


# `hinge`, in the upper bone's own space, is the joint's axis to roll onto
# the bend; zero leaves the roll as it was.
func _limb(pose: Dictionary, upper: String, lower: String, end: String, wrist: Vector3, pole: Vector3, hinge := Vector3.ZERO) -> void:
	pose.erase(upper)
	pose.erase(lower)
	var resolved := resolve(pose)
	var shoulder := bone_transform(resolved, upper)
	var len1 := _skeleton.get_bone_rest(_skeleton.find_bone(lower)).origin.length()
	var len2 := _skeleton.get_bone_rest(_skeleton.find_bone(end)).origin.length()
	var to := wrist - shoulder.origin
	var d := clampf(to.length(), 0.05, (len1 + len2) * 0.999)
	var dir := to.normalized()
	var a := (len1 * len1 - len2 * len2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(len1 * len1 - a * a, 0.0))
	var bend := (pole - dir * pole.dot(dir)).normalized()
	var elbow := shoulder.origin + dir * a + bend * h
	# Each bone swung the shortest way from where it points onto its segment.
	var upper_global := _aimed(shoulder.basis, _skeleton.get_bone_rest(_skeleton.find_bone(lower)).origin,
		elbow - shoulder.origin)
	if hinge != Vector3.ZERO and h > 0.001:
		var along := (elbow - shoulder.origin).normalized()
		var across := along.cross(wrist - elbow).normalized()
		var now := upper_global * hinge
		now = (now - along * now.dot(along)).normalized()
		upper_global = (Basis(along, now.signed_angle_to(across, along)) * upper_global).orthonormalized()
	var lower_local: Basis = Basis(resolved[lower])
	var lower_global := _aimed(upper_global * lower_local,
		_skeleton.get_bone_rest(_skeleton.find_bone(end)).origin, shoulder.origin + dir * d - elbow)
	var parent_global := bone_transform(resolved, _skeleton.get_bone_name(
		_skeleton.get_bone_parent(_skeleton.find_bone(upper)))).basis
	_set_local(pose, upper, parent_global.inverse() * upper_global)
	_set_local(pose, lower, upper_global.inverse() * lower_global)


# Where the `side` hand's grip is in a pose, in the skeleton's space.
func grip_transform(pose: Dictionary, side: String) -> Transform3D:
	var grip: Node3D = _model.main_hand_grip if side == "Right" else _model.off_hand_grip
	return bone_transform(resolve(pose), side + "Hand") * grip.transform.orthonormalized()


# A bone's transform in the skeleton's space for a resolved pose.
func bone_transform(resolved: Dictionary, bone: String) -> Transform3D:
	var i := _skeleton.find_bone(bone)
	var chain: Array[int] = []
	while i >= 0:
		chain.push_front(i)
		i = _skeleton.get_bone_parent(i)
	var t := Transform3D()
	for b in chain:
		var name := _skeleton.get_bone_name(b)
		var origin: Vector3 = resolved["_hips"] if name == "Hips" else _skeleton.get_bone_rest(b).origin
		t = t * Transform3D(Basis(resolved[name]), origin)
	return t


# `global` turned the shortest way so its local `axis` points along `to`.
static func _aimed(global: Basis, axis: Vector3, to: Vector3) -> Basis:
	var from := (global * axis).normalized()
	var turn := Quaternion(from, to.normalized())
	return (Basis(turn) * global).orthonormalized()


# Stores a bone's local rotation as the pose's turn from its base.
func _set_local(pose: Dictionary, bone: String, local: Basis) -> void:
	var base: Dictionary = _bases[pose.get("_base", "neutral")]
	var g: Basis = base["global"][bone]
	var turn := g * (Basis(base["local"][bone]).inverse() * local.orthonormalized()) * g.inverse()
	var euler := turn.get_euler()
	pose[bone] = Vector3(rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z))


# Eases from each key pose to the next. Keys are resolved first, so a key on
# the Idle base blends with one on the neutral base.
func keyed(t: float, keys: Array) -> Dictionary:
	for i in range(keys.size() - 1):
		var a: Array = keys[i]
		var b: Array = keys[i + 1]
		if t <= b[0] or i == keys.size() - 2:
			var f := clampf((t - a[0]) / (b[0] - a[0]), 0.0, 1.0)
			return _blend(resolve(a[1]), resolve(b[1]), smoothstep(0.0, 1.0, f))
	return resolve(keys[-1][1])


# One continuous movement through the key poses, for a gesture that should
# not stop at each one the way keyed() does. The whole span follows a
# minimum-jerk profile (the speed curve of a human reach: no pause between
# keys, slow only at the ends), and each bone is splined through its keys
# rather than eased key to key. `lags` delays bones by name, in seconds, so
# the shoulder can lead and the wrist and fingers follow; a negative lag
# leads. Every bone still starts on the first key and ends on the last.
func flowing(t: float, length: float, keys: Array, lags := {}) -> Dictionary:
	var poses: Array[Dictionary] = []
	var times: Array[float] = []
	for key: Array in keys:
		poses.append(resolve(key[1]))
		times.append(key[0] / length)
	var out := {"_resolved": true, "_hips": _spline_hips(poses, times, _reach(t / length))}
	for bone: String in poses[0]:
		if bone.begins_with("_"):
			continue
		var lag: float = lags.get(bone, 0.0)
		var u := (t - lag) / (length - lag) if lag >= 0.0 else t / (length + lag)
		out[bone] = _spline_bone(poses, times, bone, _reach(clampf(u, 0.0, 1.0)))
	return out


# Minimum jerk: the position curve of a smooth human reach.
static func _reach(u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	return u * u * u * (10.0 + u * (-15.0 + 6.0 * u))


static func _segment(times: Array[float], s: float) -> int:
	for i in range(times.size() - 1):
		if s <= times[i + 1]:
			return i
	return times.size() - 2


func _spline_bone(poses: Array[Dictionary], times: Array[float], bone: String, s: float) -> Quaternion:
	var i := _segment(times, s)
	var n := poses.size()
	var a: Quaternion = poses[i][bone]
	var b: Quaternion = poses[i + 1][bone]
	var pre: Quaternion = poses[maxi(i - 1, 0)][bone]
	var post: Quaternion = poses[mini(i + 2, n - 1)][bone]
	var span := times[i + 1] - times[i]
	var pre_t := (times[maxi(i - 1, 0)] - times[i]) / span if i > 0 else -1.0
	var post_t := (times[mini(i + 2, n - 1)] - times[i]) / span if i + 2 < n else 2.0
	var f := clampf((s - times[i]) / span, 0.0, 1.0)
	return a.spherical_cubic_interpolate_in_time(b, pre, post, f, 1.0, pre_t, post_t).normalized()


func _spline_hips(poses: Array[Dictionary], times: Array[float], s: float) -> Vector3:
	var i := _segment(times, s)
	var n := poses.size()
	var span := times[i + 1] - times[i]
	var pre_t := (times[maxi(i - 1, 0)] - times[i]) / span if i > 0 else -1.0
	var post_t := (times[mini(i + 2, n - 1)] - times[i]) / span if i + 2 < n else 2.0
	var f := clampf((s - times[i]) / span, 0.0, 1.0)
	return (poses[i]["_hips"] as Vector3).cubic_interpolate_in_time(poses[i + 1]["_hips"],
		poses[maxi(i - 1, 0)]["_hips"], poses[mini(i + 2, n - 1)]["_hips"], f, 1.0, pre_t, post_t)


func _blend(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	var out := {"_resolved": true, "_hips": (a["_hips"] as Vector3).lerp(b["_hips"], f)}
	for bone: String in a:
		if not bone.begins_with("_"):
			out[bone] = (a[bone] as Quaternion).slerp(b[bone], f)
	return out


# A pose as every bone's local rotation and the Hips position.
func resolve(pose: Dictionary) -> Dictionary:
	if pose.has("_resolved"):
		return pose
	var base: Dictionary = _bases[pose.get("_base", "neutral")]
	var out := {"_resolved": true, "_hips": base["hips"] + pose.get("_hips", Vector3.ZERO)}
	for bone: String in base["local"]:
		out[bone] = _turned(base, bone, pose.get(bone, Vector3.ZERO))
	return out


func clip(length: float, loops: bool, pose_at: Callable) -> Animation:
	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = Animation.LOOP_LINEAR if loops else Animation.LOOP_NONE
	var frames := int(round(length * FPS))
	var hips_track := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(hips_track, NodePath("%GeneralSkeleton:Hips"))
	var tracks := {}
	for i in _skeleton.get_bone_count():
		var bone := _skeleton.get_bone_name(i)
		var track := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(track, NodePath("%GeneralSkeleton:" + bone))
		tracks[bone] = track
	# A loop's last frame is its first again; writing it would double it.
	var last := frames - 1 if loops else frames
	for f in range(last + 1):
		var t := minf(f / FPS, length)
		var pose := resolve(pose_at.call(t, length))
		anim.position_track_insert_key(hips_track, t, pose["_hips"])
		for bone: String in tracks:
			anim.rotation_track_insert_key(tracks[bone], t, pose[bone])
	return anim


# The bone's local rotation, relative to its parent, once turned `deg` from
# `base` about the character-frame axes described at the top.
func _turned(base: Dictionary, bone: String, deg: Vector3) -> Quaternion:
	var local: Quaternion = base["local"][bone]
	if deg == Vector3.ZERO:
		return local
	var turn := Basis.from_euler(Vector3(deg_to_rad(deg.x), deg_to_rad(deg.y), deg_to_rad(deg.z)))
	var g: Basis = base["global"][bone]
	return (Basis(local) * (g.inverse() * turn * g)).get_rotation_quaternion().normalized()


func _read_bases(idle: Animation) -> void:
	var idle_local := {}
	var rest_local := {}
	for i in _skeleton.get_bone_count():
		var bone := _skeleton.get_bone_name(i)
		rest_local[bone] = _skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
		idle_local[bone] = rest_local[bone]
		var track := idle.find_track(NodePath("%GeneralSkeleton:" + bone), Animation.TYPE_ROTATION_3D)
		if track >= 0:
			idle_local[bone] = idle.rotation_track_interpolate(track, 0.0)
	var rest_hips := _skeleton.get_bone_rest(_skeleton.find_bone("Hips")).origin
	var idle_hips := rest_hips
	var hips_track := idle.find_track(NodePath("%GeneralSkeleton:Hips"), Animation.TYPE_POSITION_3D)
	if hips_track >= 0:
		idle_hips = idle.position_track_interpolate(hips_track, 0.0)
	_bases["idle"] = _base(idle_local, idle_hips)
	# Neutral: the rest pose, symmetric, with the arms brought down to hang a
	# little out from the sides. Idle's hips height keeps the feet on the floor
	# the same way.
	var rest := _base(rest_local, Vector3(rest_hips.x, idle_hips.y, rest_hips.z))
	rest_local["LeftUpperArm"] = _turned(rest, "LeftUpperArm", Vector3(0, 0, -ARMS_DOWN))
	rest_local["RightUpperArm"] = _turned(rest, "RightUpperArm", Vector3(0, 0, ARMS_DOWN))
	_bases["neutral"] = _base(rest_local, rest["hips"])


func _base(local: Dictionary, hips: Vector3) -> Dictionary:
	var global := {}
	for i in _skeleton.get_bone_count():
		var bone := _skeleton.get_bone_name(i)
		var parent := _skeleton.get_bone_parent(i)
		var parent_basis: Basis = global[_skeleton.get_bone_name(parent)] if parent >= 0 else Basis()
		global[bone] = parent_basis * Basis(local[bone])
	return {"local": local, "global": global, "hips": hips}

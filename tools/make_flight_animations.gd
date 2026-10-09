extends SceneTree

# Generates assets/flight_animations.tres: a humanoid's levitation clips,
# keyed onto the UAL mannequin's GeneralSkeleton.
#
#   godot --headless --path . -s res://tools/make_flight_animations.gd
#
# Every pose is a base with some bones turned. The base is NEUTRAL - the rest
# pose with the arms lowered, symmetric - except where a clip meets the ground
# animations: standing (the first frame of Takeoff, the last of Land) is the
# Idle clip's first frame exactly, so they join it without a pop. Idle itself
# is no base for the rest: it stands mid weight-shift, one foot forward and one
# back, and every pose built on it inherited a stride. A turn is
# given in the CHARACTER's frame, not the bone's: +X pitches about the
# character's left-right axis (an upward bone tips forward, a downward one
# swings back), +Z rolls toward the character's left, +Y yaws to its left.
# The model faces +Z. Each turn is relative to the bone's parent, so a shin's
# bend is a bend at the knee wherever the thigh has gone.
#
# Retune by editing the poses below and running this again; the clips are
# data the game reads, so nothing else needs rebuilding.

const OUT := "res://assets/flight_animations.tres"
const MODEL := "res://scenes/character_models/placeholder_model.tscn"
const FPS := 30.0

# The arms' turn down from the rest T-pose to hang at the sides.
const ARMS_DOWN := 72.0

var _skeleton: Skeleton3D
# base name -> {"local": bone -> Quaternion, "global": bone -> Basis in model
# space, "hips": the Hips position}
var _bases := {}


func _init() -> void:
	var model: Node3D = load(MODEL).instantiate()
	_skeleton = model.find_child("GeneralSkeleton", true, false)
	var player: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	_read_bases(player.get_animation("Idle"))

	var library := AnimationLibrary.new()
	library.add_animation("Takeoff", _clip(0.8, false, _takeoff))
	library.add_animation("Hover", _clip(3.0, true, _hover))
	library.add_animation("Fly_Fwd", _clip(1.6, true, _fly_fwd))
	library.add_animation("Land", _clip(0.7, false, _land))
	var err := ResourceSaver.save(library, OUT)
	print("flight animations: saved %s (%s)" % [OUT, error_string(err)])
	model.free()
	quit(0 if err == OK else 1)


# --- Poses -------------------------------------------------------------

func _standing() -> Dictionary:
	return {"_base": "idle"}


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
	_add(pose, "Spine", Vector3(1.5 * sin(w - 0.4), 0, 0))
	_add(pose, "LeftUpperLeg", Vector3(4 * sin(w - 0.7), 0, 0))
	_add(pose, "LeftLowerLeg", Vector3(5 * sin(w - 1.2), 0, 0))
	_add(pose, "RightUpperLeg", Vector3(3 * sin(w - 1.0), 0, 0))
	_add(pose, "RightLowerLeg", Vector3(5 * sin(w - 1.6), 0, 0))
	_add(pose, "LeftUpperArm", Vector3(0, 0, 4 * sin(w - 0.9)))
	_add(pose, "RightUpperArm", Vector3(0, 0, -4 * sin(w - 0.9)))
	_add(pose, "LeftLowerArm", Vector3(-4 * sin(w - 1.4), 0, 0))
	_add(pose, "RightLowerArm", Vector3(-4 * sin(w - 1.4), 0, 0))
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
	_add(pose, "LeftUpperLeg", Vector3(3 * sin(w), 0, 0))
	_add(pose, "LeftLowerLeg", Vector3(5 * sin(w - 0.8), 0, 0))
	_add(pose, "RightUpperLeg", Vector3(3 * sin(w + PI), 0, 0))
	_add(pose, "RightLowerLeg", Vector3(5 * sin(w + PI - 0.8), 0, 0))
	_add(pose, "LeftUpperArm", Vector3(3 * sin(2 * w - 0.5), 0, 0))
	_add(pose, "RightUpperArm", Vector3(3 * sin(2 * w - 0.5), 0, 0))
	_add(pose, "Spine", Vector3(1.5 * sin(2 * w - 0.3), 0, 0))
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
	return _keyed(t, [
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
	return _keyed(t, [
		[0.0, reach],
		[0.16, absorb],
		[0.7, _standing()],
	])


# --- Building --------------------------------------------------------------

func _add(pose: Dictionary, bone: String, turn: Vector3) -> void:
	pose[bone] = pose.get(bone, Vector3.ZERO) + turn


# Eases from each key pose to the next. Keys are resolved first, so a key on
# the Idle base blends with one on the neutral base.
func _keyed(t: float, keys: Array) -> Dictionary:
	for i in range(keys.size() - 1):
		var a: Array = keys[i]
		var b: Array = keys[i + 1]
		if t <= b[0] or i == keys.size() - 2:
			var f := clampf((t - a[0]) / (b[0] - a[0]), 0.0, 1.0)
			return _blend(_resolve(a[1]), _resolve(b[1]), smoothstep(0.0, 1.0, f))
	return _resolve(keys[-1][1])


func _blend(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	var out := {"_resolved": true, "_hips": (a["_hips"] as Vector3).lerp(b["_hips"], f)}
	for bone: String in a:
		if not bone.begins_with("_"):
			out[bone] = (a[bone] as Quaternion).slerp(b[bone], f)
	return out


# A pose as every bone's local rotation and the Hips position.
func _resolve(pose: Dictionary) -> Dictionary:
	if pose.has("_resolved"):
		return pose
	var base: Dictionary = _bases[pose.get("_base", "neutral")]
	var out := {"_resolved": true, "_hips": base["hips"] + pose.get("_hips", Vector3.ZERO)}
	for bone: String in base["local"]:
		out[bone] = _turned(base, bone, pose.get(bone, Vector3.ZERO))
	return out


func _clip(length: float, loops: bool, pose_at: Callable) -> Animation:
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
		var pose := _resolve(pose_at.call(t, length))
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

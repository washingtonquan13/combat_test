class_name BodyInertia
extends SkeletonModifier3D
## How a body goes from one clip to the next: the new clip takes over at
## once, and the difference from the pose it left behind dies away on top
## of it (inertialization, as Gears of War 4 and most engines since do it).
##
## WHY NOT A CROSSFADE. A crossfade shows two clips at once for its whole
## length: the walk's legs half-way between two strides, the run's arms
## swinging at half their reach. Mixamo's clips are each clean alone; the
## mush is in the mix. Here only one clip ever drives the body. What is
## carried over is the old pose's offset from the new one, and how fast that
## offset was changing, so the limbs keep their momentum through the change
## and settle onto the new clip like a spring, instead of sliding between
## two poses at a fixed rate.
##
## HOW. BodyAnimationTree.play() calls capture() before handing the clip to
## the playback with no blend. capture() records each bone's pose as it is
## showing (the mixer's pose with any offset still dying away), and where it
## was a moment earlier, from the clip it was playing. Once the tree has
## applied the new clip (applied()), its pose is under the next
## modification: the offset is the old pose
## relative to it, as a rotation vector per bone (and a position offset per
## bone the clips move), with its velocity from the two captures. From
## there each offset follows a critically damped spring to zero that has
## all but gone at the blend time the play asked for.
##
## WHY A BONE MODIFIER. As BodyFlinch: the mixer is not deterministic, so
## nothing can be added to its pose inside the tree; a modifier works on the
## pose the mixer made, and the skeleton puts that pose back after drawing,
## so the offset never accumulates. It runs before BodyFlinch, so a hit
## lands on the settled pose and a clip change never captures a flinch.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion").

const NODE_NAME: StringName = &"BodyInertia"
## The spring is critically damped: (1 + w t) e^(-w t) is the share of the
## offset left after t. At w t = SETTLED this is 2%, so w = SETTLED / blend.
const SETTLED: float = 5.8
## Seconds back the old clip is sampled at, for its velocity.
const VELOCITY_STEP: float = 1.0 / 60.0
## The most an offset may be moving at the change, radians (or metres) per
## second, so one stray frame cannot fling a limb.
const VELOCITY_MOST: float = 12.0
## Offsets smaller than this are not carried at all.
const NEGLIGIBLE: float = 0.0005

## Whether clip changes go through this at all (false: plain crossfades).
var enabled: bool = true

## Waiting for the new clip's first pose to measure the offsets against,
## and whether the tree has applied it yet.
var _pending: bool = false
var _applied: bool = false
## The frame the offsets were measured in. A play is often followed by a
## seek that shows the clip again in the same frame, from another time: the
## offsets are measured again against each pose the tree applies in that
## frame, so they are always against the frame that is drawn.
var _measured_frame: int = -1
var _w: float = 0.0
var _time: float = 0.0
var _active: bool = false
## Captured at the change, per bone index: the pose shown, and a moment
## before it.
var _old_rot: Array[Quaternion] = []
var _old_rot_prev: Array[Quaternion] = []
var _old_pos: Array[Vector3] = []
var _old_pos_prev: Array[Vector3] = []
## The offsets: [bone, x0, v0] as rotation vectors and as positions.
var _rots: Array = []
var _poss: Array = []


## Puts one under `skeleton`, first among its modifiers, or returns the one
## already there.
static func attach(skeleton: Skeleton3D) -> BodyInertia:
	var there := skeleton.get_node_or_null(NodePath(NODE_NAME)) as BodyInertia
	if there == null:
		there = BodyInertia.new()
		there.name = NODE_NAME
		skeleton.add_child(there)
	skeleton.move_child(there, 0)
	return there


## Records the pose showing now, before `blend` seconds' change to another
## clip. `from` is the clip the body was showing, at `pos` and `speed`
## (seconds per second), for how the pose was moving; null for none.
func capture(blend: float, from: Animation, pos: float, speed: float) -> void:
	var skeleton: Skeleton3D = get_parent() as Skeleton3D
	if skeleton == null or blend <= 0.0:
		return
	_w = SETTLED / blend
	if _pending:
		# Two clips in one frame: the pose to leave is still the first one's.
		return
	var count: int = skeleton.get_bone_count()
	_old_rot.resize(count)
	_old_rot_prev.resize(count)
	_old_pos.resize(count)
	_old_pos_prev.resize(count)
	var at: float = _time
	for bone in count:
		var rot: Quaternion = skeleton.get_bone_pose_rotation(bone)
		var pos3: Vector3 = skeleton.get_bone_pose_position(bone)
		_old_rot[bone] = rot
		_old_rot_prev[bone] = rot
		_old_pos[bone] = pos3
		_old_pos_prev[bone] = pos3
	if from != null and not is_zero_approx(speed):
		_sample_back(skeleton, from, pos, speed)
	# An offset still dying away is part of what shows, now and a moment ago.
	if _active:
		for entry: Array in _rots:
			var bone: int = entry[0]
			_old_rot[bone] = _old_rot[bone] * _rotation(_spring(entry, at))
			_old_rot_prev[bone] = _old_rot_prev[bone] * _rotation(_spring(entry, at - VELOCITY_STEP))
		for entry: Array in _poss:
			var bone: int = entry[0]
			_old_pos[bone] += _spring(entry, at)
			_old_pos_prev[bone] += _spring(entry, at - VELOCITY_STEP)
	_pending = true
	_applied = false


## The tree has applied a pose since the capture: the next modification
## sees the new clip.
func applied() -> void:
	if _pending or Engine.get_process_frames() == _measured_frame:
		_applied = true


## Whether an offset is still dying away (or waiting to be measured).
func is_settling() -> bool:
	return _pending or _active


## The old clip a moment back, against where it is: the bones it keys move
## from there by the same amount the clip does.
func _sample_back(skeleton: Skeleton3D, clip: Animation, pos: float, speed: float) -> void:
	var back: float = pos - VELOCITY_STEP * speed
	if clip.loop_mode == Animation.LOOP_LINEAR and clip.length > 0.0:
		back = fposmod(back, clip.length)
	else:
		back = clampf(back, 0.0, clip.length)
	for track in clip.get_track_count():
		var type: Animation.TrackType = clip.track_get_type(track)
		if type != Animation.TYPE_ROTATION_3D and type != Animation.TYPE_POSITION_3D:
			continue
		var bone: int = skeleton.find_bone(clip.track_get_path(track).get_concatenated_subnames())
		if bone == -1:
			continue
		if type == Animation.TYPE_ROTATION_3D:
			var now: Quaternion = clip.rotation_track_interpolate(track, pos)
			var then: Quaternion = clip.rotation_track_interpolate(track, back)
			_old_rot_prev[bone] = _old_rot[bone] * (now.inverse() * then)
		else:
			var now3: Vector3 = clip.position_track_interpolate(track, pos)
			var then3: Vector3 = clip.position_track_interpolate(track, back)
			_old_pos_prev[bone] = _old_pos[bone] + (then3 - now3)


func _process(delta: float) -> void:
	if _active:
		_time += delta
		if (1.0 + _w * _time) * exp(-_w * _time) < 0.002:
			_active = false
			_rots.clear()
			_poss.clear()


func _process_modification() -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	var frame: int = Engine.get_process_frames()
	if _applied and (_pending or frame == _measured_frame):
		_pending = false
		_applied = false
		_measured_frame = frame
		_measure(skeleton)
	if not _active:
		return
	for entry: Array in _rots:
		var bone: int = entry[0]
		skeleton.set_bone_pose_rotation(bone,
			skeleton.get_bone_pose_rotation(bone) * _rotation(_spring(entry, _time)))
	for entry: Array in _poss:
		var bone: int = entry[0]
		skeleton.set_bone_pose_position(bone,
			skeleton.get_bone_pose_position(bone) + _spring(entry, _time))


## The new clip's first pose is under us: each bone's offset from the old
## one, and how fast it was moving.
func _measure(skeleton: Skeleton3D) -> void:
	_rots.clear()
	_poss.clear()
	_time = 0.0
	if not enabled:
		_active = false
		return
	var count: int = mini(skeleton.get_bone_count(), _old_rot.size())
	for bone in count:
		var rot: Quaternion = skeleton.get_bone_pose_rotation(bone)
		var x0: Vector3 = _vector(rot.inverse() * _old_rot[bone])
		var xp: Vector3 = _vector(rot.inverse() * _old_rot_prev[bone])
		var v0: Vector3 = ((x0 - xp) / VELOCITY_STEP).limit_length(VELOCITY_MOST)
		if x0.length() > NEGLIGIBLE or v0.length() * VELOCITY_STEP > NEGLIGIBLE:
			_rots.append([bone, x0, v0])
		var pos3: Vector3 = skeleton.get_bone_pose_position(bone)
		var p0: Vector3 = _old_pos[bone] - pos3
		var pv: Vector3 = ((_old_pos[bone] - _old_pos_prev[bone]) / VELOCITY_STEP).limit_length(VELOCITY_MOST)
		if p0.length() > NEGLIGIBLE * 0.2 or pv.length() * VELOCITY_STEP > NEGLIGIBLE * 0.2:
			_poss.append([bone, p0, pv])
	_active = not (_rots.is_empty() and _poss.is_empty())


## A critically damped spring from x0 moving at v0, toward zero, at `t`.
func _spring(entry: Array, t: float) -> Vector3:
	var x0: Vector3 = entry[1]
	var v0: Vector3 = entry[2]
	t = maxf(t, 0.0)
	return (x0 + (v0 + x0 * _w) * t) * exp(-_w * t)


## The rotation a rotation vector names (axis times angle).
static func _rotation(v: Vector3) -> Quaternion:
	var angle: float = v.length()
	if angle < 0.000001:
		return Quaternion.IDENTITY
	return Quaternion(v / angle, angle)


## A rotation as a rotation vector, the short way round.
static func _vector(q: Quaternion) -> Vector3:
	q = q.normalized()
	if q.w < 0.0:
		q = -q
	var s: float = Vector3(q.x, q.y, q.z).length()
	if s < 0.000001:
		return Vector3.ZERO
	return Vector3(q.x, q.y, q.z) / s * (2.0 * atan2(s, q.w))

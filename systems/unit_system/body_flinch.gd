class_name BodyFlinch
extends SkeletonModifier3D
## A hit shown on top of whatever the body is doing: the motion of a hit
## clip, added to the walk or the cast instead of replacing it.
##
## WHY A BONE MODIFIER AND NOT A TREE NODE. An AnimationTree has an Add2
## node for exactly this, but it only adds when the tree is deterministic.
## A body's player is not (Godot's default), and BodyAnimationTree copies
## that because a deterministic mixer pulls every bone a clip leaves out
## back to rest. Non-deterministic, the mixer divides each bone by the sum
## of its weights, so an added clip at weight w would shrink the walk under
## it to 1/(1+w) of itself. A modifier runs after the mixer, on the pose it
## made, and the skeleton puts that pose back after drawing, so the flinch
## can never stay behind.
##
## WHAT IS ADDED. For each bone the clip turns, how far it has turned since
## the clip's first frame: frame_t relative to frame_0, in the bone's own
## space. A hit clip starts from a standing pose and recoils from it, so
## that difference is the recoil and nothing else. Only rotations: a hit's
## root and hip travel would drag a walker off its line.
##
## WHERE IT RUNS. First among the skeleton's modifiers, so a head turned to
## look at something keeps looking at it while the chest takes the blow.

const NODE_NAME: StringName = &"BodyFlinch"
## Seconds to come in and to let go, so a short clip does not snap.
const EASE_IN: float = 0.05
const EASE_OUT: float = 0.2

## How much of the recoil shows, 1 being all of it.
var strength: float = 1.0

var _clip: Animation = null
var _time: float = 0.0
## [track, bone, first-frame rotation] for each bone the clip turns.
var _turns: Array = []


## Puts one under `skeleton`, first among its modifiers, or returns the one
## already there.
static func attach(skeleton: Skeleton3D) -> BodyFlinch:
	var there := skeleton.get_node_or_null(NodePath(NODE_NAME)) as BodyFlinch
	if there:
		return there
	var made := BodyFlinch.new()
	made.name = NODE_NAME
	skeleton.add_child(made)
	skeleton.move_child(made, 0)
	return made


## Shows `clip` on top of the pose, on `bones` (names; empty means every
## bone the clip turns but the root and hips). A flinch already showing
## gives way to the new one.
func flinch(clip: Animation, bones: Dictionary = {}) -> void:
	var skeleton: Skeleton3D = get_parent() as Skeleton3D
	if clip == null or skeleton == null:
		return
	_turns = []
	for track in clip.get_track_count():
		if clip.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var bone_name: StringName = StringName(clip.track_get_path(track).get_concatenated_subnames())
		if bones.is_empty():
			if bone_name in [&"Root", &"Hips"]:
				continue
		elif not bones.has(bone_name):
			continue
		var bone: int = skeleton.find_bone(bone_name)
		if bone == -1:
			continue
		_turns.append([track, bone, clip.rotation_track_interpolate(track, 0.0)])
	_clip = clip if not _turns.is_empty() else null
	_time = 0.0


func is_flinching() -> bool:
	return _clip != null


func _process(delta: float) -> void:
	if _clip == null:
		return
	_time += delta
	if _time >= _clip.length:
		_clip = null


func _process_modification() -> void:
	if _clip == null:
		return
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	var weight: float = strength * minf(1.0, _time / EASE_IN) \
		* minf(1.0, (_clip.length - _time) / EASE_OUT)
	if weight <= 0.0:
		return
	for turn: Array in _turns:
		var first: Quaternion = turn[2]
		var now: Quaternion = _clip.rotation_track_interpolate(turn[0], _time)
		var recoil: Quaternion = Quaternion.IDENTITY.slerp(first.inverse() * now, weight)
		skeleton.set_bone_pose_rotation(turn[1],
			skeleton.get_bone_pose_rotation(turn[1]) * recoil)

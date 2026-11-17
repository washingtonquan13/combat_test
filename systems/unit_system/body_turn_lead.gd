class_name BodyTurnLead
extends SkeletonModifier3D
## The head and chest leading into a turn while the body walks or runs: the
## eyes go to where the route is going before the feet do, and the chest
## follows the head part of the way.
##
## WHY. The walk and run loops are straight; a route that bends only turns
## the whole unit (face_direction) and leans it (UnitLocomotion._lean_into).
## Without a lead the body looks where its hips point, which reads as a
## cart on rails. A person turning looks first, then turns the shoulders,
## then the hips.
##
## WHAT. `lead` is a yaw (radians, positive left) that UnitLocomotion sets
## each tick: the angle from the unit's facing to a point a little way ahead
## along its route. It is eased here and spread up the spine, each bone
## turning its share about the body's up axis, so Head ends up turned by the
## whole of it and Spine by a little. Bones the rig lacks are skipped.
##
## WHERE IT RUNS. After BodyInertia and BodyFlinch, before the gaze
## (LookAtModifier3D): a unit looking at someone keeps looking at them, the
## gaze working from the turned neck. While a gaze holds (any
## LookAtModifier3D on the skeleton with influence), the lead keeps to the
## spine and chest and leaves the neck and head to it.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion").

const NODE_NAME: StringName = &"BodyTurnLead"
## Each bone's share of the lead, from the bottom up. They sum to 1.
const SHARES := {
	&"Spine": 0.10, &"Chest": 0.15, &"UpperChest": 0.15, &"Neck": 0.25, &"Head": 0.35,
}
const HEAD_BONES := [&"Neck", &"Head"]
## Most it turns at all, and how fast it follows (1/s).
const MOST := deg_to_rad(35.0)
const RATE := 5.0

## The lead asked for, radians, positive to the left.
var lead: float = 0.0
var _shown: float = 0.0
## [bone, share] for the bones this rig has.
var _bones: Array = []


## Puts one under `skeleton`, after the inertia and the flinch, or returns
## the one already there.
static func attach(skeleton: Skeleton3D) -> BodyTurnLead:
	var there := skeleton.get_node_or_null(NodePath(NODE_NAME)) as BodyTurnLead
	if there == null:
		there = BodyTurnLead.new()
		there.name = NODE_NAME
		skeleton.add_child(there)
		var after: int = 0
		for name: StringName in [BodyInertia.NODE_NAME, BodyFlinch.NODE_NAME]:
			var node: Node = skeleton.get_node_or_null(NodePath(name))
			if node:
				after = maxi(after, node.get_index() + 1)
		skeleton.move_child(there, after)
	there._find_bones(skeleton)
	return there


func _find_bones(skeleton: Skeleton3D) -> void:
	_bones.clear()
	for name: StringName in SHARES:
		var bone: int = skeleton.find_bone(name)
		if bone != -1:
			_bones.append([bone, SHARES[name], name in HEAD_BONES])


func _process(delta: float) -> void:
	_shown = lerpf(_shown, clampf(lead, -MOST, MOST), 1.0 - exp(-RATE * delta))


func _process_modification() -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null or absf(_shown) < 0.002 or _bones.is_empty():
		return
	# The body's up, in skeleton space (the skeleton may be scaled or turned
	# under the model root).
	var up: Vector3 = (skeleton.global_basis.inverse() * Vector3.UP).normalized()
	var head_free: bool = not _gazing(skeleton)
	for entry: Array in _bones:
		if entry[2] and not head_free:
			continue
		var bone: int = entry[0]
		var parent: int = skeleton.get_bone_parent(bone)
		var parent_basis := Basis.IDENTITY
		if parent != -1:
			parent_basis = skeleton.get_bone_global_pose(parent).basis.orthonormalized()
		# The turn about `up`, in the parent's space, applied before the pose.
		var axis: Vector3 = (parent_basis.inverse() * up).normalized()
		var turn := Quaternion(axis, _shown * float(entry[1]))
		skeleton.set_bone_pose_rotation(bone, turn * skeleton.get_bone_pose_rotation(bone))


func _gazing(skeleton: Skeleton3D) -> bool:
	for child in skeleton.get_children():
		var gaze := child as LookAtModifier3D
		if gaze and gaze.active and gaze.influence > 0.01:
			return true
	return false

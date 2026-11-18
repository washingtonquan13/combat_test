class_name SocketSpec
extends Resource

## One place on a body where something attaches, said by the body's own
## landmarks rather than in metres, so the same spec fits every body of a
## kind: a weapon grip, the casting hand, the head, a sheath. CharacterModel
## builds it at load (SocketProfile), on a BoneAttachment3D riding `bones`.
##
## The frame is the landmark's rest origin plus `offset` measured in units of
## the length from `measure_from` to `measure_to` (the hand's length for a
## grip, hips to head for the torso), so it scales with the body. With
## `bone_frame` the offset and `axes` are in the landmark bone's own rest
## axes, which a retargeted humanoid has the same on every body
## (SkeletonProfileHumanoid normalizes them); without, in the character's
## frame (skeleton space: facing +Z, its left +X).

## The CharacterModel export it fills when that export is unset:
## main_hand_grip, off_hand_grip, hand_anchor, head_anchor, off_hand_anchor,
## back_sheath_a, back_sheath_b, hip_sheath_main, hip_sheath_off.
@export var socket: StringName
## The bone it rides, the first of these the skeleton has.
@export var bones: Array[StringName] = []
## Whose rest origin the offset starts from. Empty: the ridden bone.
@export var landmark: StringName
## Offset and axes in the landmark bone's rest axes, not the character's.
@export var bone_frame: bool = true
## The socket's axes in that frame.
@export var axes: Basis = Basis.IDENTITY
## From the landmark, in units of the measured length (metres if unmeasured).
@export var offset: Vector3 = Vector3.ZERO
@export var measure_from: StringName
@export var measure_to: StringName
## Slide the socket along its +X, which points away from the body, onto the
## body's skin at rest, wherever the offset left it: a sheath sits on the
## back or hip of this body, however thick it is, not of the one it was
## measured on.
@export var onto_surface: bool = false


## {"bone": the ridden bone's index, "wanted": the socket's transform in
## skeleton space at rest}, or {} when the skeleton lacks a bone it names.
func place(skeleton: Skeleton3D) -> Dictionary:
	var bone: int = -1
	for bone_name: StringName in bones:
		bone = skeleton.find_bone(bone_name)
		if bone != -1:
			break
	if bone == -1:
		return {}
	var base: int = bone if landmark == &"" else skeleton.find_bone(landmark)
	if base == -1:
		return {}
	var unit: float = 1.0
	if measure_from != &"" or measure_to != &"":
		var from: int = skeleton.find_bone(measure_from)
		var to: int = skeleton.find_bone(measure_to)
		if from == -1 or to == -1:
			return {}
		unit = skeleton.get_bone_global_rest(from).origin.distance_to(skeleton.get_bone_global_rest(to).origin)
	var rest: Transform3D = skeleton.get_bone_global_rest(base)
	var frame: Basis = rest.basis.orthonormalized() if bone_frame else Basis.IDENTITY
	var wanted := Transform3D((frame * axes).orthonormalized(), rest.origin + frame * (offset * unit))
	return {"bone": bone, "wanted": wanted}

class_name FaceJaw
extends SkeletonModifier3D
## Turns the jaw bone open by however far the face's shapes say, after the
## animation has posed the body.
##
## WHY. A Character Creator mouth shape is two things in CC: a morph and a
## jaw bone turn (V_Open is the lips plus 16 degrees of jaw; Jaw_Open is
## 31). The .fbx keeps only the morph, so without this the lips move and
## the teeth, tongue and chin stay shut. The degrees are CC's own, read from
## each body's export JSON into FaceShapeNames.jaw_degrees; FaceDriver sums
## them by shape weight into `degrees`.
##
## THE AXIS. CC turns the bone about its own local Z, but the import's rest
## fixer rewrote the bone's axes, so CC's local Z is not ours. The turn is
## made about the skeleton's left-right axis seen from the bone (the axis
## CC's Z is: the JSON turns carry no other component), in the sense that
## takes the lower teeth down.
##
## WHERE IT RUNS. Last among the skeleton's modifiers; nothing else turns
## the jaw.

const NODE_NAME: StringName = &"FaceJaw"

## How far open the jaw is, in degrees.
var degrees: float = 0.0
var bone_name: StringName = &"Jaw"

var _bone: int = -1
var _axis: Vector3 = Vector3.RIGHT


## The one under `skeleton`, put there if it has none. A stand-in's copy
## brings its body's along.
static func attach(skeleton: Skeleton3D, jaw_bone: StringName) -> FaceJaw:
	var there := skeleton.get_node_or_null(NodePath(NODE_NAME)) as FaceJaw
	if there == null:
		there = FaceJaw.new()
		there.name = NODE_NAME
		skeleton.add_child(there)
	there.bone_name = jaw_bone
	there._find_axis(skeleton)
	return there


func _find_axis(skeleton: Skeleton3D) -> void:
	_bone = skeleton.find_bone(bone_name)
	if _bone == -1:
		return
	var rest: Transform3D = skeleton.get_bone_global_rest(_bone)
	_axis = (rest.basis.inverse() * Vector3.RIGHT).normalized()
	# The way round that drops the chin: a bone hanging from the jaw (teeth,
	# tongue) goes down, not up.
	for child: int in skeleton.get_bone_children(_bone):
		var reach: Vector3 = skeleton.get_bone_rest(child).origin
		if reach.length() < 0.001:
			continue
		var turned: Vector3 = rest.basis * (Basis(_axis, deg_to_rad(10.0)) * reach)
		if turned.y > (rest.basis * reach).y:
			_axis = -_axis
		break


func _process_modification() -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null or _bone == -1 or absf(degrees) < 0.01:
		return
	skeleton.set_bone_pose_rotation(_bone, skeleton.get_bone_pose_rotation(_bone)
		* Quaternion(_axis, deg_to_rad(degrees)))

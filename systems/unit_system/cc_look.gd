class_name CCLook
extends Node
## Puts Character Creator's look on a CC base: its materials (CCMaterials,
## from the JSON CC exported beside the FBX), the hairstyle and the tints of
## its CharacterPreset. CharacterLook's counterpart for CC bodies: a sibling
## of the model's Body.
##
## Runs again on a StandIn's copy of the body (a duplicate). Materials and
## tints are set again, which changes nothing; the hair is attached only if
## the copy did not bring the original's.
##
## What the body wears goes on with wear(): each Wearable's fit for this
## body_type (a .glb from tools/armor_fit/, fitted to this base in Blender),
## bound to the body's skeleton by CCWear. CC's own clothed exports stay
## retired (2026-11-21) for what they cost the editor and the loads. The
## skin under it is hidden by bone (Wearable.hides), not by a covers mask:
## cc_skin's hidden_binds drops the body's skin, and underwear (CC's Boxers,
## Bra, Underwear_Bottoms) mostly under hidden bones is not shown.

## The base's JSON, beside its FBX.
@export_file("*.json") var body_json: String = ""
## Set by CharacterPreset.make_body() before the body enters the tree. Null
## is the bare base: CC's materials, no hair, no tints.
@export var preset: CharacterPreset
## Which fit of a Wearable this body takes (Wearable.meshes): one per CC
## base, &"cc_male" or &"cc_female".
@export var body_type: StringName

const HAIR_META := &"cc_hair"

## What wear() put on.
var _worn: Array[Node3D] = []


## Dresses the body in items, in place of what it wore. An item with no fit
## for this body_type shows nothing.
func wear(items: Array[Wearable]) -> void:
	for mesh in _worn:
		if is_instance_valid(mesh):
			# Out of the tree now, so a re-worn piece keeps its name (Armor_cuirass, not @MeshInstance3D@…).
			mesh.get_parent().remove_child(mesh)
			mesh.queue_free()
	_worn.clear()
	var character := get_parent() as Node3D
	var hides: Array[StringName] = []
	for item in items:
		var scene: PackedScene = item.meshes.get(body_type)
		if scene:
			_worn.append_array(CCWear.attach(character, scene))
			hides.append_array(item.hides)
	_hide_under(character, hides)


## Hides the skin under the bones named (and every bone below them): the
## body's through its shader, any other skinned mesh of the body (underwear)
## whole when most of its weight lies on them. Shows them all again when
## nothing is named.
func _hide_under(character: Node3D, bones: Array[StringName]) -> void:
	var body := CCMaterials._body(character)
	if body == null or body.skin == null:
		return
	var skeleton := body.get_node(body.skeleton) as Skeleton3D
	var hidden := {}
	for bone in bones:
		var b := skeleton.find_bone(bone)
		if b < 0:
			push_warning("CCLook: no bone %s to hide the skin under." % bone)
			continue
		var stack: Array[int] = [b]
		while not stack.is_empty():
			var at: int = stack.pop_back()
			hidden[at] = true
			stack.append_array(skeleton.get_bone_children(at))
	var mask := Vector4i()
	for i in mini(body.skin.get_bind_count(), 128):
		if hidden.has(_bind_bone(body.skin, i, skeleton)):
			mask[i / 32] |= 1 << (i % 32)
	body.set_instance_shader_parameter(&"hidden_binds", mask)
	for mesh: MeshInstance3D in skeleton.find_children("*", "MeshInstance3D", false, false):
		if mesh != body and mesh.skin != null and not _worn.has(mesh) and not mesh.has_meta(HAIR_META):
			mesh.visible = hidden.is_empty() or _hidden_share(mesh, hidden, skeleton) < 0.5


## The skeleton bone a skin's bind i drives.
static func _bind_bone(skin: Skin, i: int, skeleton: Skeleton3D) -> int:
	var name := skin.get_bind_name(i)
	return skeleton.find_bone(name) if name != &"" else skin.get_bind_bone(i)


## The share of a skinned mesh's weight that lies on hidden bones.
static func _hidden_share(mesh: MeshInstance3D, hidden: Dictionary, skeleton: Skeleton3D) -> float:
	var on := PackedByteArray()
	on.resize(mesh.skin.get_bind_count())
	var any := false
	for i in on.size():
		if hidden.has(_bind_bone(mesh.skin, i, skeleton)):
			on[i] = 1
			any = true
	if not any:
		return 0.0
	var total := 0.0
	var under := 0.0
	for s in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(s)
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var w: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		for k in mini(idx.size(), w.size()):
			total += w[k]
			if idx[k] < on.size() and on[idx[k]] == 1:
				under += w[k]
	return under / total if total > 0.0 else 0.0


func _ready() -> void:
	var body := get_parent().get_node_or_null("Body") as Node3D
	if body == null:
		push_warning("CCLook: no Body beside it.")
		return
	CCMaterials.fix_shape_tangents(body)
	CCMaterials.apply(body, body_json)
	if preset == null:
		return
	if preset.hair_scene != "" and not _has_hair(body):
		var hair := CCMaterials.attach_hair(body, preset.hair_scene, preset.hair_json())
		if hair:
			hair.set_meta(HAIR_META, true)
	CCMaterials.set_tints(body, preset.skin_tint, preset.iris_tint)
	CCMaterials.set_hair_color(body, preset.hair_color)


func _has_hair(body: Node) -> bool:
	for mesh in body.find_children("*", "MeshInstance3D", true, false):
		if mesh.has_meta(HAIR_META):
			return true
	return false

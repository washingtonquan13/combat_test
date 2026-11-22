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
## retired (2026-11-21) for what they cost the editor and the loads. No
## covers mask: the skin under a garment still draws.

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
var _worn: Array[MeshInstance3D] = []


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
	for item in items:
		var scene: PackedScene = item.meshes.get(body_type)
		if scene:
			_worn.append_array(CCWear.attach(character, scene))


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

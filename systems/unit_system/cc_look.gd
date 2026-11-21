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
## A CC body wears no clothes: CC's clothed exports were retired
## (2026-11-21) for what they cost the editor and the loads.

## The base's JSON, beside its FBX.
@export_file("*.json") var body_json: String = ""
## Set by CharacterPreset.make_body() before the body enters the tree. Null
## is the bare base: CC's materials, no hair, no tints.
@export var preset: CharacterPreset

const HAIR_META := &"cc_hair"


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

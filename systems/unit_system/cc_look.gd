class_name CCLook
extends Node
## Puts Character Creator's look on a CC base: its materials (CCMaterials,
## from the JSON CC exported beside the FBX), the hairstyle and the tints of
## its CharacterPreset. CharacterLook's counterpart for CC bodies: a sibling
## of the model's Body.
##
## Runs again on a StandIn's copy of the body (a duplicate). Materials and
## tints are set again, which changes nothing; the hair is attached only if
## the copy did not bring the original's, and the copy keeps the covers its
## original wore (its garments come with it).
##
## Clothes (wear()) are the garments of clothes_scene, the base dressed in
## CC and exported whole: an item's Wearable.cc_part names its mesh there.
## Under each, the skin it hides is dropped, by the covers mask
## tools/characters/cc_covers.gd baked from that export into covers/<part>.png
## beside it. CC's layers sit through each other (the base's underwear
## through anything, a sweater through an apron's bib): by Wearable.cc_layer,
## the one beneath loses what the one over it hides (_drop_under).

## The base's JSON, beside its FBX.
@export_file("*.json") var body_json: String = ""
## Set by CharacterPreset.make_body() before the body enters the tree. Null
## is the bare base: CC's materials, no hair, no tints.
@export var preset: CharacterPreset
## This base dressed in CC's clothes and exported (its JSON beside it, same
## name). Empty: the body wears nothing.
@export_file("*.fbx") var clothes_scene: String = ""

const HAIR_META := &"cc_hair"
const GARMENT_META := &"cc_garment"
## The clothed exports' underwear: never worn, never a garment.
const UNDERWEAR := ["boxers", "bra", "underwear_bottoms"]
## The CC body's UV tiles (u 0-6: head, body, arm, leg, nails, eyelashes),
## side by side in a covers mask (cc_skin.gdshaderinc's COVERS_TILES).
const COVERS_TILES := 6.0
## Marks a skin material duplicated for this character's covers.
const OWN_META := &"cc_covers_own"
## A layer's mesh before CCMaterials.uncovered() dropped what is under.
const OWN_MESH_META := &"cc_own_mesh"
## A garment's Wearable.cc_layer; the base's underwear is under every one.
const LAYER_META := &"cc_layer"


func _ready() -> void:
	var body := get_parent().get_node_or_null("Body") as Node3D
	if body == null:
		push_warning("CCLook: no Body beside it.")
		return
	CCMaterials.fix_shape_tangents(body)
	var inherited := _covers(body)
	CCMaterials.apply(body, body_json)
	_show_covers(body, inherited)
	if preset == null:
		return
	if preset.hair_scene != "" and not _has_hair(body):
		var hair := CCMaterials.attach_hair(body, load(preset.hair_scene), preset.hair_json())
		if hair:
			hair.set_meta(HAIR_META, true)
	CCMaterials.set_tints(body, preset.skin_tint, preset.iris_tint)
	CCMaterials.set_hair_color(body, preset.hair_color)


func _has_hair(body: Node) -> bool:
	for mesh in body.find_children("*", "MeshInstance3D", true, false):
		if mesh.has_meta(HAIR_META):
			return true
	return false


## Dresses the body in items, in place of what it wore. An item whose
## cc_part this body's clothes lack shows nothing.
func wear(items: Array[Wearable]) -> void:
	var body := get_parent().get_node_or_null("Body") as Node3D
	if body == null:
		return
	for mesh in body.find_children("*", "MeshInstance3D", true, false):
		if mesh.has_meta(GARMENT_META):
			mesh.get_parent().remove_child(mesh)
			mesh.queue_free()
	var masks: Array[Texture2D] = []
	var garments: Array[MeshInstance3D] = []
	if clothes_scene != "":
		var clothes: PackedScene = load(clothes_scene)
		var json := clothes_scene.get_basename() + ".json"
		for item in items:
			if item.cc_part == &"":
				continue
			var garment := CCMaterials.attach_garment(body, clothes, json, item.cc_part)
			if garment == null:
				continue
			garment.set_meta(GARMENT_META, true)
			garment.set_meta(OWN_MESH_META, garment.mesh)
			garment.set_meta(LAYER_META, item.cc_layer)
			garments.append(garment)
			var mask := clothes_scene.get_base_dir().path_join("covers/%s.png" % String(item.cc_part).to_lower())
			if ResourceLoader.exists(mask):
				masks.append(load(mask))
	_show_covers(body, CharacterLook.joined_covers(masks))
	_drop_under(body, garments)


## Each layer (the base's underwear, every garment) loses the triangles
## hidden by the garments worn over it (a higher Wearable.cc_layer), and
## those behind a garment level with it, at rest (CCMaterials.uncovered).
func _drop_under(body: Node3D, garments: Array[MeshInstance3D]) -> void:
	var layers: Array[MeshInstance3D] = garments.duplicate()
	for mesh: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
		if String(mesh.name).to_lower() in UNDERWEAR and not mesh.has_meta(GARMENT_META):
			if not mesh.has_meta(OWN_MESH_META):
				mesh.set_meta(OWN_MESH_META, mesh.mesh)
			layers.append(mesh)
	for layer in layers:
		var covers := []
		var level: int = layer.get_meta(LAYER_META, -1)
		for g in garments:
			var over: int = g.get_meta(LAYER_META)
			if g != layer and over >= level:
				covers.append([g.get_meta(OWN_MESH_META), g.get_meta(CCMaterials.OFFSET_META), over == level])
		var offset: Vector3 = layer.get_meta(CCMaterials.OFFSET_META, Vector3.ZERO)
		if layer.has_meta(GARMENT_META):
			layer.mesh = CCMaterials.uncovered(layer.get_meta(OWN_MESH_META), offset, covers)
		else:
			layer.mesh = CCMaterials.uncovered(layer.get_meta(OWN_MESH_META), offset, covers,
					CCMaterials.UNDERWEAR_SIDE, CCMaterials.UNDERWEAR_DEPTH)


## The skin's materials on the body mesh, every pass.
func _skin_passes(body: Node3D) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	var mesh := CCMaterials._body(body)
	if mesh == null:
		return out
	for s in mesh.mesh.get_surface_count():
		var material := mesh.get_surface_override_material(s) as ShaderMaterial
		while material:
			var file := material.shader.resource_path.get_file() if material.shader else ""
			if file.begins_with("cc_skin") or file.begins_with("cc_head"):
				out.append(material)
			material = material.next_pass as ShaderMaterial
	return out


func _covers(body: Node3D) -> Texture2D:
	for material in _skin_passes(body):
		return material.get_shader_parameter("covers") as Texture2D
	return null


## Hands covers to the skin, on materials of this character's own (CCMaterials
## shares one set per JSON).
func _show_covers(body: Node3D, covers: Texture2D) -> void:
	var mesh := CCMaterials._body(body)
	if mesh == null:
		return
	for s in mesh.mesh.get_surface_count():
		var material := mesh.get_surface_override_material(s) as ShaderMaterial
		if material == null or not _skin_passes_in(material):
			continue
		if covers == null and not material.has_meta(OWN_META):
			continue
		if not material.has_meta(OWN_META):
			material = _own_copy(material)
			material.set_meta(OWN_META, true)
			mesh.set_surface_override_material(s, material)
		while material:
			if _skin_passes_in(material):
				material.set_shader_parameter("covers", covers)
			material = material.next_pass as ShaderMaterial


## material and its next passes copied, their shaders shared: a copied
## Shader loses its path, and with it the #include of its .gdshaderinc.
func _own_copy(material: Material) -> Material:
	if material == null:
		return null
	var copy := material.duplicate() as Material
	copy.next_pass = _own_copy(material.next_pass)
	return copy


func _skin_passes_in(material: ShaderMaterial) -> bool:
	var file := material.shader.resource_path.get_file() if material.shader else ""
	return file.begins_with("cc_skin") or file.begins_with("cc_head")

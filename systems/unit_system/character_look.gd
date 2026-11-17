class_name CharacterLook
extends Node
## Puts the character shaders on a baked MPFB human in place of the plain
## materials its .glb imports with: HumanShaders' skin on the body
## (human_skin.gdshader, over the body's own diffuse map), and so on. Each
## gets the imported material's own texture where it takes one, so one
## template serves every character.
##
## A sibling of the model's Body; it finds the surfaces by the names
## tools/characters/bake_character.py gives their materials: "<name>.body".
##
## A character baked with a hairstyle has hair cards (tools/characters/
## groom.py), "<name>.groom", which get groom.gdshader, and a hull over them,
## "<name>.hair_shell", kept for the outline bake and hidden. The cards draw
## their own strands, baked with them; the scalp texture turns the skin to
## short hair where the hair grows.
##
## The eyes ("<name>.high-poly") get HumanShaders' eye (human_eye.gdshader,
## with its own sclera and iris maps), and the lashes
## ("<name>.eyelashes..") lash.gdshader, coloured from hair_color.
##
## What the body wears goes on with wear(): each Wearable's fit for this
## body_type, skinned to the body's skeleton, and its covers mask on the
## skin, which drops the skin under it.

const SKIN := preload("res://assets/characters/shaders/human_skin.tres")
const GROOM := preload("res://assets/characters/shaders/groom.tres")
const EYE := preload("res://assets/characters/shaders/human_eye.tres")
const LASH := preload("res://assets/characters/shaders/lash.tres")

## The hair's colour: the cards', the scalp's and the lashes'.
@export var hair_color: Color = Color(0.25, 0.17, 0.11)
## Multiplies the skin's diffuse map.
@export var skin_tint: Color = Color.WHITE
## Where the groom's hair grows on the skin, baked with it; none without one.
@export var scalp_texture: Texture2D
## The groom's cards' strands ("<name>_strands.png"), baked with them.
@export var strands_texture: Texture2D
## Which fit of a Wearable this body takes (Wearable.meshes). Each baked
## character is its own body type for now: its recipe's name.
@export var body_type: StringName

## The skin's materials, every pass, to hand the covers mask to.
var _skin_passes: Array[ShaderMaterial] = []
## What wear() put on: the items' meshes and their outline hulls.
var _worn: Array[Node] = []
## The joined covers of what is worn; null for none.
var _covers: Texture2D


func _ready() -> void:
	var skin := _skin()
	var groom := _groom()
	var lash := LASH.duplicate() as ShaderMaterial
	lash.set_shader_parameter("hair_color", hair_color)
	for mesh: MeshInstance3D in get_parent().find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null:
			continue
		for i in mesh.mesh.get_surface_count():
			var imported := mesh.mesh.surface_get_material(i) as BaseMaterial3D
			if imported == null:
				continue
			var part := imported.resource_name.get_extension()
			if part == "hair_shell":
				mesh.visible = false
			elif part == "groom":
				mesh.set_surface_override_material(i, groom)
			elif part == "body":
				var material := _with_texture(skin, imported, "texture_albedo")
				mesh.set_surface_override_material(i, material)
				while material:
					_skin_passes.append(material)
					material = material.next_pass as ShaderMaterial
			elif part == "high-poly":
				mesh.set_surface_override_material(i, EYE.duplicate())
			elif part.begins_with("eyelashes"):
				mesh.set_surface_override_material(i, _with_texture(lash, imported))
	_show_covers()


## Dresses the body in items, in place of what it wore. An item with no fit
## for this body_type shows nothing. Each item's meshes go on the body's
## skeleton, each with an outline hull under the model's outline mesh, so
## the hover outline follows the clothes; the skin under them is dropped.
func wear(items: Array[Wearable]) -> void:
	for node in _worn:
		if is_instance_valid(node):
			node.queue_free()
	_worn.clear()
	var skeleton := _skeleton()
	var model := get_parent() as CharacterModel
	var outline: MeshInstance3D = model.outline_mesh if model else null
	var masks: Array[Texture2D] = []
	for item in items:
		var scene: PackedScene = item.meshes.get(body_type)
		if scene == null or skeleton == null:
			continue
		if item.covers:
			masks.append(item.covers)
		var fitted: Node = scene.instantiate()
		for mesh: MeshInstance3D in fitted.find_children("*", "MeshInstance3D", true, false):
			mesh.get_parent().remove_child(mesh)
			mesh.owner = null
			skeleton.add_child(mesh)
			mesh.skeleton = mesh.get_path_to(skeleton)
			mesh.layers = _body_layers(skeleton)
			_worn.append(mesh)
			if outline:
				var hull := MeshInstance3D.new()
				hull.mesh = mesh.mesh
				hull.skin = mesh.skin
				hull.material_override = outline.material_override
				hull.layers = outline.layers
				outline.add_child(hull)
				hull.skeleton = hull.get_path_to(skeleton)
				_worn.append(hull)
		fitted.free()
	_covers = _joined(masks)
	_show_covers()


func _show_covers() -> void:
	for material in _skin_passes:
		material.set_shader_parameter("covers", _covers)


func _skeleton() -> Skeleton3D:
	var found: Array[Node] = get_parent().find_children("*", "Skeleton3D", true, false)
	return found[0] as Skeleton3D if found else null


## The render layers the body draws on (Unit.wear_render_layer), for the
## items to draw on too.
func _body_layers(skeleton: Skeleton3D) -> int:
	for child in skeleton.get_children():
		if child is MeshInstance3D and not _worn.has(child):
			return (child as MeshInstance3D).layers
	return 1


## The masks laid over each other: what any of them covers.
static func _joined(masks: Array[Texture2D]) -> Texture2D:
	if masks.size() <= 1:
		return masks[0] if masks else null
	var joined: Image = null
	for mask in masks:
		var image: Image = mask.get_image()
		if image.is_compressed():
			image.decompress()
		image.convert(Image.FORMAT_RGBA8)
		if joined == null:
			joined = image
			continue
		if image.get_size() != joined.get_size():
			image.resize(joined.get_width(), joined.get_height(), Image.INTERPOLATE_NEAREST)
		joined.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
	return ImageTexture.create_from_image(joined)


func _skin() -> ShaderMaterial:
	var skin := SKIN.duplicate() as ShaderMaterial
	skin.set_shader_parameter("albedo", skin_tint)
	if scalp_texture:
		skin.set_shader_parameter("scalp_texture", scalp_texture)
		skin.set_shader_parameter("scalp_color", hair_color)
	return skin


## The hair's material and its edges pass (groom.tres), copied together so
## each character's hair has its own colour and strands.
func _groom() -> ShaderMaterial:
	var groom := GROOM.duplicate(true) as ShaderMaterial
	var material := groom
	while material:
		material.set_shader_parameter("hair_color", hair_color)
		if strands_texture:
			material.set_shader_parameter("strands", strands_texture)
		material = material.next_pass as ShaderMaterial
	return groom


## material, or a copy of it per texture, carrying the imported texture on
## every pass, as its uniform texture_name.
func _with_texture(material: ShaderMaterial, imported: BaseMaterial3D,
		texture_name := "albedo_texture") -> ShaderMaterial:
	var out := material.duplicate() as ShaderMaterial
	if out.next_pass:
		out.next_pass = out.next_pass.duplicate()
	var pass_material := out
	while pass_material:
		pass_material.set_shader_parameter(texture_name, imported.albedo_texture)
		pass_material = pass_material.next_pass as ShaderMaterial
	return out

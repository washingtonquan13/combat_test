class_name CharacterLook
extends Node
## Puts the character shaders on a baked MPFB human in place of the plain
## materials its .glb imports with: skin.gdshader on the body and the hair
## shaders on its hair. Each gets the imported material's own texture, so one
## pair of templates serves every character.
##
## A sibling of the model's Body; it finds the surfaces by the names
## tools/characters/bake_character.py gives their materials, "<name>.body"
## and "<name>.<hair>", where <hair> is the recipe's hair.

const SKIN := preload("res://assets/characters/shaders/skin.tres")
const HAIR := preload("res://assets/characters/shaders/hair.tres")

## The recipe's hair, as its material is named ("short02", "ponytail01").
@export var hair_part: String = ""
## The hair's colour once dyed; see dye.
@export var hair_color: Color = Color(0.25, 0.17, 0.11)
## 0 keeps the hair texture's own colour, 1 dyes it fully to hair_color.
@export_range(0.0, 1.0, 0.05) var dye: float = 0.0
## Multiplies the skin's diffuse map.
@export var skin_tint: Color = Color.WHITE


func _ready() -> void:
	var skin := _skin()
	var hair := _hair()
	for mesh: MeshInstance3D in get_parent().find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null:
			continue
		for i in mesh.mesh.get_surface_count():
			var imported := mesh.mesh.surface_get_material(i) as BaseMaterial3D
			if imported == null:
				continue
			var part := imported.resource_name.get_extension()
			if part == "body":
				mesh.set_surface_override_material(i, _with_texture(skin, imported))
			elif hair_part != "" and part == hair_part:
				mesh.set_surface_override_material(i, _with_texture(hair, imported))


func _skin() -> ShaderMaterial:
	var skin := SKIN.duplicate() as ShaderMaterial
	skin.set_shader_parameter("tint", skin_tint)
	return skin


func _hair() -> ShaderMaterial:
	var hair := HAIR.duplicate() as ShaderMaterial
	hair.next_pass = hair.next_pass.duplicate()
	for pass_material: ShaderMaterial in [hair, hair.next_pass]:
		pass_material.set_shader_parameter("hair_color", hair_color)
		pass_material.set_shader_parameter("dye", dye)
	return hair


## material, or a copy of it per texture, carrying the imported texture on
## every pass.
func _with_texture(material: ShaderMaterial, imported: BaseMaterial3D) -> ShaderMaterial:
	var out := material.duplicate() as ShaderMaterial
	if out.next_pass:
		out.next_pass = out.next_pass.duplicate()
	var pass_material := out
	while pass_material:
		pass_material.set_shader_parameter("albedo_texture", imported.albedo_texture)
		pass_material = pass_material.next_pass as ShaderMaterial
	return out

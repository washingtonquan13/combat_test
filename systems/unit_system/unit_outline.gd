class_name UnitOutline
extends RefCounted
## The hover outline of one body (owner: the unit system; driven by
## UnitSelection.update_highlight). Drawn by the body's own meshes: each
## surface's material gets outline_pass.gdshader appended to the end of its
## next_pass chain, once, and lit() sets the pass's colour on the mesh as a
## per-instance shader parameter. Shared materials are fine, then: another
## mesh drawing the same material keeps alpha 0, which the pass draws as
## nothing.
##
## What it outlines: every MeshInstance3D under the CharacterModel, so the
## body, what it wears and what it holds, but not the ring (highlight_mesh)
## nor the parts inside or flat on the head (INSIDE_THE_HEAD, by the names
## tools/characters/bake_character.py gives their materials), which add
## nothing to the silhouette and would draw lines across the face. A mesh
## put on while the outline shows (a weapon drawn, CharacterLook.wear) is
## caught as it enters the tree.

const PASS := preload("res://assets/characters/shaders/outline_pass.tres")
const PARAMETER := &"outline_color"
const INSIDE_THE_HEAD: Array[String] = ["eyebrow", "eyelash", "groom", "high-poly", "hair_shell", "teeth", "tongue"]
## WORKAROUND: the hull mesh of the old outline, drawn with this shader
## as its material_override. placeholder_model.tscn still carries one
## ("OutlineMesh"), because that scene has local edits and is not committed
## with this change; such a hull is hidden and left out. Logged in
## docs/systems/unit.md; goes when that scene drops the node.
const OLD_HULL := preload("res://systems/unit_system/outline.gdshader")

var _model: Node3D
var _skip: MeshInstance3D
var _color := Color(0, 0, 0, 0)
var _lit: Array[MeshInstance3D] = []


func _init(model: Node3D, skip: MeshInstance3D) -> void:
	_model = model
	_skip = skip
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var hull := (node as MeshInstance3D).material_override as ShaderMaterial
		if hull and hull.shader == OLD_HULL:
			(node as MeshInstance3D).visible = false


## Shows the outline in `color` (alpha 0 hides it).
func lit(color: Color) -> void:
	if not is_instance_valid(_model):
		return
	_color = color
	var tree := _model.get_tree()
	var watching: bool = tree != null and tree.node_added.is_connected(_on_node_added)
	if color.a > 0.0:
		for node in _model.find_children("*", "MeshInstance3D", true, false):
			_light(node as MeshInstance3D)
		if tree and not watching:
			tree.node_added.connect(_on_node_added)
	else:
		for mesh in _lit:
			if is_instance_valid(mesh):
				mesh.set_instance_shader_parameter(PARAMETER, color)
		_lit.clear()
		if watching:
			tree.node_added.disconnect(_on_node_added)


## Hides every outline on `model`, and on a copy of one: a duplicate takes
## its meshes' instance parameters with it (StandIn).
static func clear(model: Node) -> void:
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.get_instance_shader_parameter(PARAMETER) != null:
			mesh.set_instance_shader_parameter(PARAMETER, Color(0, 0, 0, 0))


func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D and is_instance_valid(_model) and _model.is_ancestor_of(node):
		# Its surfaces' materials may still be set by whoever added it.
		_light.call_deferred(node)


func _light(mesh: MeshInstance3D) -> void:
	if not is_instance_valid(mesh) or mesh == _skip or mesh.mesh == null or _color.a <= 0.0:
		return
	var hull := mesh.material_override as ShaderMaterial
	if hull and hull.shader == OLD_HULL:
		return
	var any: bool = false
	for i in mesh.mesh.get_surface_count():
		if _inside_the_head(mesh.mesh.surface_get_material(i)):
			continue
		var material: Material = mesh.get_active_material(i)
		if material == null:
			continue
		_append(material)
		any = true
	if any:
		mesh.set_instance_shader_parameter(PARAMETER, _color)
		if not _lit.has(mesh):
			_lit.append(mesh)


static func _inside_the_head(imported: Material) -> bool:
	if imported == null:
		return false
	var part: String = imported.resource_name.get_extension()
	return INSIDE_THE_HEAD.any(func(word: String) -> bool: return word in part)


static func _append(material: Material) -> void:
	var last: Material = material
	while last.next_pass:
		if last.next_pass == PASS:
			return
		last = last.next_pass
	last.next_pass = PASS

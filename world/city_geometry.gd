@tool
extends Node3D
## The city's baked fields, handed to its shaders. tools/blockout/city_gltf.py
## writes the city as city.glb with shore.png (metres to the nearest bank
## and how open the water is, for city_water.gdshader), edge.exr (signed
## metres to the city line, for the fog wall in city_edge_fog.gdshaderinc)
## and city.json saying where in the world each field lies. The materials
## are shared .tres files that cannot know which city is loaded, so the
## fields are global shader parameters, and this script, on the glb's
## instance in the overworld scene, sets them whenever its city is the one
## in play. @tool, so the editor shows the edge fog and the shore too.

## The folder holding city.json; empty for the folder this scene's glb is in.
@export_dir var data_dir: String = ""


func _enter_tree() -> void:
	_apply()
	if not Engine.is_editor_hint() and not WorldManager.world_focused.is_connected(_on_world_focused):
		WorldManager.world_focused.connect(_on_world_focused)


func _exit_tree() -> void:
	if not Engine.is_editor_hint() and WorldManager.world_focused.is_connected(_on_world_focused):
		WorldManager.world_focused.disconnect(_on_world_focused)
	RenderingServer.global_shader_parameter_set(&"city_has_edge", false)
	RenderingServer.global_shader_parameter_set(&"city_has_shore", false)


func _on_world_focused(world: Node) -> void:
	# Global to every world, so set again whenever this city comes back.
	if world.is_ancestor_of(self):
		_apply()


func _apply() -> void:
	var dir := data_dir if data_dir != "" else scene_file_path.get_base_dir()
	var file := FileAccess.open(dir.path_join("city.json"), FileAccess.READ)
	if file == null:
		push_warning("CityGeometry: no city.json in %s; the city has no edge fog or shore" % dir)
		return
	var meta: Variant = JSON.parse_string(file.get_as_text())
	_set_field(meta.get("edge"), dir, &"city_edge_tex", &"city_edge_origin", &"city_edge_size", &"city_has_edge")
	_set_field(meta.get("shore"), dir, &"city_shore_tex", &"city_shore_origin", &"city_shore_size", &"city_has_shore")


func _set_field(field: Variant, dir: String, tex: StringName, origin: StringName, size: StringName, has: StringName) -> void:
	if field == null:
		RenderingServer.global_shader_parameter_set(has, false)
		return
	var texture: Texture2D = load(dir.path_join(field.file))
	if texture == null:
		push_warning("CityGeometry: %s missing in %s" % [field.file, dir])
		RenderingServer.global_shader_parameter_set(has, false)
		return
	RenderingServer.global_shader_parameter_set(tex, texture)
	RenderingServer.global_shader_parameter_set(origin, Vector2(field.origin[0], field.origin[1]))
	RenderingServer.global_shader_parameter_set(size, Vector2(field.size[0], field.size[1]))
	RenderingServer.global_shader_parameter_set(has, true)

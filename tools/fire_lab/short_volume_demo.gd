extends "res://tools/surfaces_look_demo.gd"
## Lab comparison, NOT a test: the Fire surface as built, or (user arg
## "volume") the same patch with its flame particles swapped for a short
## raymarched volume over its cells. Prints GPU time for each view.

const FIRE: PackedScene = preload("res://systems/surface_system/fire.tscn")
const VOLUME_SHADER: Shader = preload("res://systems/surface_system/fire_volume.gdshader")
const WALL: PackedScene = preload("res://systems/surface_system/fire_wall.tscn")

var _volume_mode: bool = "volume" in OS.get_cmdline_user_args()


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.deselect_all()
	var spot: Vector3 = _spot(-12.0, 0.0)
	_frame(spot, 14.0)
	await _wait(1.0)
	RenderingServer.viewport_set_measure_render_time(WorldManager.focused_viewport().get_viewport_rid(), true)
	var patch: SurfacePatch = SurfaceManager.spawn(_ground(FIRE), spot, 2.5, _hero)
	if _volume_mode:
		await get_tree().process_frame
		patch.visual.get_node("Flames").visible = false
		_add_volume(patch)
		if "nochar" in OS.get_cmdline_user_args():
			(patch.visual as Decal).cull_mask = 0
	_say("Short volume" if _volume_mode else "Current fire")
	await _view("game distance", spot, 14.0, 6.0)
	await _view("mid", spot, 8.0, 5.0)
	await _view("close", spot, 4.0, 5.0)
	print("DEMO RESULT: done")
	get_tree().quit()


func _view(label: String, spot: Vector3, distance: float, seconds: float) -> void:
	_frame(spot, distance)
	await _wait(seconds * 0.5)
	var rid: RID = WorldManager.focused_viewport().get_viewport_rid()
	var total: float = 0.0
	for i in 30:
		await get_tree().process_frame
		total += RenderingServer.viewport_get_measured_render_time_gpu(rid)
	print("GPU %s: %.2f ms" % [label, total / 30.0])
	await _wait(seconds * 0.5)


## A short box of fire_volume over the patch's cells.
func _add_volume(patch: SurfacePatch) -> void:
	var low := Vector2i(1 << 30, 1 << 30)
	var high := -low
	var floor_y: float = INF
	for cell: SurfaceCell in patch.cells:
		low = Vector2i(mini(low.x, cell.key.x), mini(low.y, cell.key.y))
		high = Vector2i(maxi(high.x, cell.key.x), maxi(high.y, cell.key.y))
		floor_y = minf(floor_y, cell.y)
	var first := low - Vector2i.ONE
	var count := high - low + Vector2i(3, 3)
	var height: float = float(OS.get_environment("SV_HEIGHT")) if OS.has_environment("SV_HEIGHT") else 0.7
	var image := Image.create(count.x, count.y, false, Image.FORMAT_RGBAF)
	var box_low := Vector3(first.x * SurfaceGrid.CELL, floor_y - 0.05, first.y * SurfaceGrid.CELL)
	var size := Vector3(count.x * SurfaceGrid.CELL, height + 0.3, count.y * SurfaceGrid.CELL)
	var centre := box_low + size * 0.5
	for cell: SurfaceCell in patch.cells:
		var foot: float = cell.y - centre.y
		image.set_pixelv(cell.key - first, Color(1.0, foot, foot + height, 1.0))
	var texture := ImageTexture.create_from_image(image)
	var material := ShaderMaterial.new()
	material.shader = VOLUME_SHADER
	material.render_priority = 1
	var noise: Texture3D = WALL.instantiate().noise
	material.set_shader_parameter("noise", noise)
	material.set_shader_parameter("columns_soft", texture)
	material.set_shader_parameter("columns", texture)
	material.set_shader_parameter("columns_origin", Vector2(-size.x, -size.z) * 0.5)
	material.set_shader_parameter("columns_count", Vector2(count) * SurfaceGrid.CELL)
	material.set_shader_parameter("box_size", size)
	material.set_shader_parameter("box_offset", Vector3.ZERO)
	material.set_shader_parameter("world_offset", centre)
	# Short and sparse: fewer steps, finer tongues, more noise needed to burn.
	material.set_shader_parameter("steps", 20)
	material.set_shader_parameter("rise", 1.6)
	material.set_shader_parameter("tongue_scale", Vector2(0.7, 0.35))
	material.set_shader_parameter("detail_scale", Vector2(1.8, 1.0))
	material.set_shader_parameter("warp", 0.5)
	material.set_shader_parameter("contrast", 6.0)
	material.set_shader_parameter("foot_threshold", 0.58)
	material.set_shader_parameter("top_threshold", 0.82)
	material.set_shader_parameter("emission", 3.0)
	material.set_shader_parameter("absorption", 3.0)
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var volume := MeshInstance3D.new()
	volume.mesh = mesh
	volume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	volume.layers = 1 << (Unit.RENDER_LAYER - 1)
	patch.visual.get_parent().add_child(volume)
	volume.global_position = centre

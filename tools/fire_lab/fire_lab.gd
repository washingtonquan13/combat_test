extends Node3D
## Lab for the wall's main mass alone - NOT a test, NOT game code: a bare
## ground, a few strips of the baked wall sheet, and a camera that looks
## from the side, close, and straight down. Record with --write-movie.

const SHEET: Shader = preload("res://tools/fire_lab/fire_sheet.gdshader")
const VOLUME: Shader = preload("res://tools/fire_lab/fire_volume.gdshader")
const PROCEDURAL: Shader = preload("res://tools/fire_lab/fire_procedural.gdshader")
const VOLUME_DATA := "res://assets/vfx/fire_wall_volume.bin"

@export var flipbook: Texture2D = preload("res://assets/vfx/fire_wall_flipbook.png")
@export var wall_length: float = 8.0
@export var wall_height: float = 5.5
## One tile's width in meters: the bake's section, stretched by the same
## factor its fire height was stretched to wall_height.
@export var tile_width: float = 4.73
## Strips, front to back: z offset, time offset (frames), tile offset, brightness.
@export var strips: Array[Vector4] = [Vector4(-0.45, 0.0, 0.0, 0.8), Vector4(-0.3, 37.0, 0.53, 0.9), Vector4(-0.15, 11.0, 0.21, 1.0), Vector4(0.0, 23.0, 0.37, 1.0), Vector4(0.15, 51.0, 0.86, 1.0), Vector4(0.3, 5.0, 0.64, 0.9), Vector4(0.45, 41.0, 0.71, 0.8)]

## Raymarched volume instead of the strips.
@export var use_volume: bool = true
@export var volume_size: Vector3 = Vector3(8.0, 4.4, 2.4)
## Live noise volume instead of the baked one.
@export var procedural: bool = true

var _camera: Camera3D
var _label: Label


func _ready() -> void:
	_build_stage()
	if use_volume:
		add_child(_procedural() if procedural else _volume())
	else:
		for strip in strips:
			add_child(_strip(strip))
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_run()


func _build_stage() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.07)
	env.ambient_light_color = Color(0.25, 0.25, 0.3)
	env.glow_enabled = true
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 0.4
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.2, 0.18)
	plane.material = mat
	ground.mesh = plane
	add_child(ground)
	var light := OmniLight3D.new()
	light.light_color = Color(1, 0.55, 0.2)
	light.light_energy = 3.0
	light.omni_range = 9.0
	light.position = Vector3(0, 1.5, 0)
	add_child(light)
	_camera = Camera3D.new()
	add_child(_camera)
	var layer := CanvasLayer.new()
	_label = Label.new()
	_label.position = Vector2(24, 20)
	_label.add_theme_font_size_override("font_size", 28)
	layer.add_child(_label)
	add_child(layer)


## A ribbon along x, wall_height tall, its UV.x counted in tiles.
func _strip(strip: Vector4) -> MeshInstance3D:
	const STEP := 0.25
	var count := ceili(wall_length / STEP)
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for i in count + 1:
		var x := -wall_length * 0.5 + i * STEP
		# A gentle wave, so the strip isn't a ruled line from above.
		var z := strip.x + sin(x * 0.9 + strip.y) * 0.3
		for top in 2:
			vertices.append(Vector3(x, top * wall_height, z))
			uvs.append(Vector2(i * STEP / tile_width, 1.0 - top))
	for i in count:
		var a := i * 2
		indices.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := ShaderMaterial.new()
	material.shader = SHEET
	material.set_shader_parameter("flipbook", flipbook)
	material.set_shader_parameter("time_offset", strip.y)
	material.set_shader_parameter("tile_offset", strip.z)
	material.set_shader_parameter("intensity", 0.9 * strip.w)
	material.set_shader_parameter("opacity", 0.3)
	material.set_shader_parameter("length_tiles", wall_length / tile_width)
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	return instance


## A box of fire_volume.gdshader over the sim's flame, its tile scaled by
## how much taller the box is than the sim.
func _volume() -> MeshInstance3D:
	var info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(VOLUME_DATA + ".json"))
	var data := FileAccess.get_file_as_bytes(VOLUME_DATA)
	var w: int = info.x
	var h: int = info.y
	var slice := w * h
	var images: Array[Image] = []
	for i in data.size() / slice:
		images.append(Image.create_from_data(w, h, false, Image.FORMAT_R8, data.slice(i * slice, (i + 1) * slice)))
	var texture := ImageTexture3D.new()
	texture.create(Image.FORMAT_R8, w, h, images.size(), false, images)
	var scale: float = volume_size.y / info.size_m[1]
	var box := BoxMesh.new()
	box.size = volume_size
	var material := ShaderMaterial.new()
	material.shader = VOLUME
	material.set_shader_parameter("volume", texture)
	material.set_shader_parameter("frames", int(info.frames))
	material.set_shader_parameter("thickness", int(info.z))
	material.set_shader_parameter("box_size", volume_size)
	material.set_shader_parameter("tile_width", info.size_m[0] * scale)
	box.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = box
	instance.position.y = volume_size.y * 0.5
	return instance


## A box of fire_procedural.gdshader over a tiling noise texture.
func _procedural() -> MeshInstance3D:
	var source := FastNoiseLite.new()
	source.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	source.frequency = 0.06
	source.fractal_octaves = 3
	var texture := ImageTexture3D.new()
	var images := source.get_seamless_image_3d(64, 64, 64)
	texture.create(images[0].get_format(), 64, 64, 64, false, images)
	var box := BoxMesh.new()
	box.size = volume_size
	var material := ShaderMaterial.new()
	material.shader = PROCEDURAL
	material.set_shader_parameter("noise", texture)
	material.set_shader_parameter("box_size", volume_size)
	box.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = box
	instance.position.y = volume_size.y * 0.5
	return instance


func _look(label: String, from: Vector3, seconds: float) -> void:
	_label.text = label
	_camera.position = from
	_camera.look_at(Vector3(0, 1.5, 0) if from.y < 14.0 else Vector3.ZERO, Vector3.UP if from.y < 14.0 else Vector3.FORWARD)
	await get_tree().create_timer(seconds * 0.5).timeout
	var rid := get_viewport().get_viewport_rid()
	var total := 0.0
	var count := 0
	while count < 30:
		await get_tree().process_frame
		total += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		count += 1
	print("GPU %s: %.2f ms" % [label, total / count])
	await get_tree().create_timer(seconds * 0.5 - 1.0).timeout


func _run() -> void:
	await _look("Side, game distance", Vector3(3, 11, 12), 7.0)
	await _look("Close", Vector3(1.5, 4, 7), 6.0)
	await _look("Along the wall", Vector3(9, 5, 5), 5.0)
	await _look("From above", Vector3(0, 15, 0.01), 5.0)
	print("DEMO RESULT: done")
	get_tree().quit()

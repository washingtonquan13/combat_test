extends Node
## Builds a city overworld from a directory made by osm_city.py.
##
##   godot --headless --path . res://tools/blockout/build_osm_city.tscn -- \
##       --src=res://data/blockouts/nola --out=res://world/nola --scale=0.125
##
## Writes <out>/city_geometry.scn, binary because it holds every block of
## the city as mesh and collision, and <out>/../<name>_overworld.tscn, the
## editable area that instances it, but only when that scene does not
## exist yet: doors and spawn points placed by hand survive a rebuild.
##
## --scale shrinks the city horizontally (0.125 is 1:8); --vscale is the
## scale for heights, larger than --scale so blocks still read as
## buildings and not kerbs once the streets are a few metres wide.
##
## Map data (c) OpenStreetMap contributors, ODbL 1.0.

## Vertex colours by triangle kind, in osm_city.py's order.
const GROUND_COLORS := [
	Color8(150, 150, 146), Color8(92, 108, 88), Color8(98, 124, 84), Color8(150, 150, 144),
	Color8(92, 86, 80), Color8(78, 80, 84), Color8(64, 66, 70), Color8(52, 78, 96),
]
const BUILDING_COLORS := [Color(0.80, 0.78, 0.74), Color(0.55, 0.54, 0.52)]
const BLOCKS_SHADER := "res://world/city_blocks.gdshader"
const WATER_SHADER := "res://world/city_water.gdshader"
const FOG_SHADER := "res://world/city_fog.gdshader"
## The ground class osm_city.py gives water.
const WATER := 7
## Real metres of one storey (as in osm_city.py) and one window bay.
const LEVEL_HEIGHT := 3.4
const BAY_WIDTH := 3.6
const EDGE_WALL := 4.0
## The fog past the city's boundary: sheets at these heights in world
## units, the metres inside the boundary where each starts to thicken,
## less for higher sheets so the bank rises outward, and the world units
## the sheets run on past the map so its edge never shows.
const FOG_HEIGHTS := [0.6, 3.0, 7.0]
const FOG_REACH := [260.0, 170.0, 90.0]
const FOG_MARGIN := 600.0
## The scene's haze, which the fog matches.
const HAZE := Color(0.72, 0.76, 0.80)
## The SMT IV framing: steep, far back, the avatar small against the
## city. CAMERA_RANGE is metres from camera to avatar along the view.
const CAMERA_PITCH := 70.0
const CAMERA_RANGE := 170.0
const AVATAR_SPEED_SCALE := 2.0
const AVATAR_ICON_SCALE := 12.0

var _scale := 0.125
var _vscale := 0.25


func _ready() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var src: String = args.get("src", "")
	var out: String = args.get("out", "")
	_scale = float(args.get("scale", str(_scale)))
	_vscale = float(args.get("vscale", str(_vscale)))
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(src + "/city.json"))
	DirAccess.make_dir_recursive_absolute(out)

	var geometry := Node3D.new()
	geometry.name = "CityGeometry"
	geometry.set_meta("osm_attribution", meta.attribution)
	geometry.set_meta("osm_bbox", meta.bbox)
	geometry.set_meta("scale", _scale)

	var size := Vector2(meta.extent[0], meta.extent[1]) * _scale
	var corner := Vector2(meta.corner[0], meta.corner[1]) * _scale
	_build_ground(geometry, corner, size)

	var blocks_mat := ShaderMaterial.new()
	blocks_mat.shader = load(BLOCKS_SHADER)
	blocks_mat.set_shader_parameter("storey", LEVEL_HEIGHT * _vscale)
	blocks_mat.set_shader_parameter("bay", BAY_WIDTH * _scale)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.vertex_color_use_as_albedo = true
	ground_mat.vertex_color_is_srgb = true
	ground_mat.roughness = 1.0
	var water_mat := ShaderMaterial.new()
	water_mat.shader = load(WATER_SHADER)
	water_mat.set_shader_parameter("units_per_metre", _scale)
	if meta.has("shore"):
		# The data directory is .gdignore'd, so the file is read as plain
		# image data and embedded in the geometry scene.
		var shore := Image.load_from_file(src + "/" + meta.shore.file)
		# Two channels are all the shader reads; half the memory of RGBA.
		shore.convert(Image.FORMAT_RG8)
		shore.generate_mipmaps()
		water_mat.set_shader_parameter("shore_tex", ImageTexture.create_from_image(shore))
		water_mat.set_shader_parameter("shore_origin", corner)
		water_mat.set_shader_parameter("shore_size", Vector2(shore.get_width(), shore.get_height()) * meta.shore.res * _scale)
		water_mat.set_shader_parameter("has_shore", true)
	if meta.has("boundary"):
		_build_boundary(geometry, meta, src, corner, size)
	var tris := 0
	for tile in meta.tiles:
		var body := StaticBody3D.new()
		body.name = "Tile_%d_%d" % [tile.x, tile.z]
		geometry.add_child(body)
		var faces := PackedVector3Array()
		if tile.has("ground"):
			var ground := _load_tris(src + "/tiles/" + tile.ground, GROUND_COLORS, WATER)
			var mi := _mesh_instance("Ground", ground.mesh, null)
			for i in ground.mesh.get_surface_count():
				mi.set_surface_override_material(i, water_mat if i == ground.get("apart_surface", -1) else ground_mat)
			body.add_child(mi)
		if tile.has("blocks"):
			var blocks := _load_tris(src + "/tiles/" + tile.blocks, BUILDING_COLORS)
			tris += blocks.count
			body.add_child(_mesh_instance("Blocks", blocks.mesh, blocks_mat))
			faces.append_array(blocks.faces)
		if tile.has("water"):
			faces.append_array(_load_tris(src + "/tiles/" + tile.water, []).faces)
		if faces.is_empty():
			continue
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		var col := CollisionShape3D.new()
		col.name = "Collision"
		col.shape = shape
		body.add_child(col)

	for node in geometry.get_children():
		_own(node, geometry)
	var scene := PackedScene.new()
	var err := scene.pack(geometry)
	var geometry_path := out + "/city_geometry.scn"
	if err == OK:
		err = ResourceSaver.save(scene, geometry_path, ResourceSaver.FLAG_COMPRESS)
	print("city: %d tiles, %d building triangles -> %s (%s)" % [meta.tiles.size(), tris, geometry_path, error_string(err)])
	geometry.free()

	var area_path := out.get_base_dir() + "/" + out.get_file() + "_overworld.tscn"
	if err == OK and not ResourceLoader.exists(area_path):
		err = _write_area(area_path, geometry_path, meta)
	get_tree().quit(0 if err == OK else 1)


func _own(node: Node, owner_node: Node) -> void:
	node.owner = owner_node
	for child in node.get_children():
		_own(child, owner_node)


## A slab under the ground meshes to stand on, and a wall round the edge
## of the map.
func _build_ground(parent: Node3D, corner: Vector2, size: Vector2) -> void:
	var centre := corner + size * 0.5
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.position = Vector3(centre.x, -0.5, centre.y)
	parent.add_child(floor_body)
	_add_box(floor_body, Vector3.ZERO, Vector3(size.x, 1.0, size.y))
	var h := EDGE_WALL
	_add_box(floor_body, Vector3(0, h * 0.5, -size.y * 0.5), Vector3(size.x, h, 1.0))
	_add_box(floor_body, Vector3(0, h * 0.5, size.y * 0.5), Vector3(size.x, h, 1.0))
	_add_box(floor_body, Vector3(-size.x * 0.5, h * 0.5, 0), Vector3(1.0, h, size.y))
	_add_box(floor_body, Vector3(size.x * 0.5, h * 0.5, 0), Vector3(1.0, h, size.y))


## The edge of a city with a boundary: a wall along it, and the fog that
## hides everything past it.
func _build_boundary(parent: Node3D, meta: Dictionary, src: String, corner: Vector2, size: Vector2) -> void:
	var faces := PackedVector3Array()
	for ring in meta.boundary:
		for i in ring.size():
			var a := Vector3(ring[i][0], 0.0, ring[i][1]) * _scale
			var b := Vector3(ring[(i + 1) % ring.size()][0], 0.0, ring[(i + 1) % ring.size()][1]) * _scale
			var up := Vector3(0.0, EDGE_WALL, 0.0)
			faces.append_array([a, b, b + up, a, b + up, a + up])
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var wall := StaticBody3D.new()
	wall.name = "BoundaryWall"
	parent.add_child(wall)
	var col := CollisionShape3D.new()
	col.shape = shape
	wall.add_child(col)

	if not meta.has("edge"):
		return
	var edge := Image.load_from_file(src + "/" + meta.edge.file)
	var edge_tex := ImageTexture.create_from_image(edge)
	var fog := Node3D.new()
	fog.name = "BoundaryFog"
	parent.add_child(fog)
	var plane := PlaneMesh.new()
	plane.size = size + Vector2.ONE * FOG_MARGIN * 2.0
	for i in FOG_HEIGHTS.size():
		var mat := ShaderMaterial.new()
		mat.shader = load(FOG_SHADER)
		mat.set_shader_parameter("fog_color", HAZE)
		mat.set_shader_parameter("edge_tex", edge_tex)
		mat.set_shader_parameter("edge_origin", corner)
		mat.set_shader_parameter("edge_size", Vector2(edge.get_width(), edge.get_height()) * meta.edge.res * _scale)
		mat.set_shader_parameter("edge_step", meta.edge.step)
		mat.set_shader_parameter("units_per_metre", _scale)
		mat.set_shader_parameter("reach_in", FOG_REACH[i])
		mat.set_shader_parameter("seed", float(i))
		# Higher sheets draw over lower ones.
		mat.render_priority = i
		var sheet := _mesh_instance("Sheet%d" % i, plane, mat)
		sheet.position = Vector3(corner.x + size.x * 0.5, FOG_HEIGHTS[i], corner.y + size.y * 0.5)
		sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fog.add_child(sheet)


func _add_box(body: StaticBody3D, at: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = at
	body.add_child(col)


func _mesh_instance(node_name: String, mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	return mi


## A tile file as a mesh and as collision faces, both already scaled.
## colors maps a triangle's kind to its vertex colour; UV2 carries the
## kind and tint themselves for shaders. Triangles of kind apart go in a
## surface of their own, whose index is apart_surface.
func _load_tris(path: String, colors: Array, apart := -1) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	var n := bytes.decode_s32(0)
	var floats := bytes.slice(4, 4 + n * 36).to_float32_array()
	var kinds := bytes.slice(4 + n * 36, 4 + n * 37)
	var tints := bytes.slice(4 + n * 37, 4 + n * 38)
	var verts := PackedVector3Array()
	verts.resize(n * 3)
	for v in n * 3:
		verts[v] = Vector3(floats[v * 3] * _scale, floats[v * 3 + 1] * _vscale, floats[v * 3 + 2] * _scale)
	# The file winds counter-clockwise from outside; Godot's front faces
	# are clockwise.
	var faces := PackedVector3Array()
	faces.resize(n * 3)
	var normals := PackedVector3Array()
	normals.resize(n * 3)
	var cols := PackedColorArray()
	var uv2 := PackedVector2Array()
	if not colors.is_empty():
		cols.resize(n * 3)
		uv2.resize(n * 3)
	for t in n:
		var a := verts[t * 3]
		var b := verts[t * 3 + 1]
		var c := verts[t * 3 + 2]
		var nrm := (b - a).cross(c - a).normalized()
		faces[t * 3] = a
		faces[t * 3 + 1] = c
		faces[t * 3 + 2] = b
		for k in 3:
			normals[t * 3 + k] = nrm
		if not colors.is_empty():
			var col: Color = colors[kinds[t]]
			var uv := Vector2(kinds[t], tints[t] / 255.0)
			for k in 3:
				cols[t * 3 + k] = col
				uv2[t * 3 + k] = uv
	var result := {"faces": faces, "count": n}
	if colors.is_empty():
		return result
	var keep := PackedInt32Array()
	var split := PackedInt32Array()
	for t in n:
		if kinds[t] == apart:
			split.append(t)
		else:
			keep.append(t)
	var mesh := ArrayMesh.new()
	if split.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(faces, normals, cols, uv2))
	else:
		for tris in [keep, split]:
			if tris.is_empty():
				continue
			if tris == split:
				result.apart_surface = mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _pick(tris, faces, normals, cols, uv2))
	result.mesh = mesh
	return result


func _arrays(faces: PackedVector3Array, normals: PackedVector3Array, cols: PackedColorArray, uv2: PackedVector2Array) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = faces
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	return arrays


## The surface arrays of only the triangles tris.
func _pick(tris: PackedInt32Array, faces: PackedVector3Array, normals: PackedVector3Array, cols: PackedColorArray, uv2: PackedVector2Array) -> Array:
	var f := PackedVector3Array()
	var nr := PackedVector3Array()
	var c := PackedColorArray()
	var u := PackedVector2Array()
	for t in tris:
		for k in 3:
			f.append(faces[t * 3 + k])
			nr.append(normals[t * 3 + k])
			c.append(cols[t * 3 + k])
			u.append(uv2[t * 3 + k])
	return _arrays(f, nr, c, u)


## The editable overworld: the shared overworld script, its camera framed
## the SMT IV way, light, and a Start spawn in Jackson Square. Doors are placed by hand.
func _write_area(path: String, geometry_path: String, meta: Dictionary) -> Error:
	var root := Node3D.new()
	root.name = path.get_file().get_basename().to_pascal_case()
	root.set_script(load("res://world/overworld.gd"))
	root.set_meta("osm_attribution", meta.attribution)
	root.avatar_speed_scale = AVATAR_SPEED_SCALE
	root.avatar_icon_scale = AVATAR_ICON_SCALE

	var city: Node3D = load(geometry_path).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	root.add_child(city)
	city.owner = root

	var spawns := Node3D.new()
	spawns.name = "SpawnPoints"
	root.add_child(spawns)
	spawns.owner = root
	var start := Marker3D.new()
	start.name = "Start"
	start.position = _local(meta, 29.9574, -90.0630) + Vector3(0, 0.5, 0)
	spawns.add_child(start)
	start.owner = root

	var camera: Node = load("res://systems/camera_system/overworld_camera.tscn").instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	camera.pitch_degrees = CAMERA_PITCH
	var slope := tan(deg_to_rad(CAMERA_PITCH))
	var along := cos(deg_to_rad(CAMERA_PITCH))
	camera.distance = CAMERA_RANGE * along
	camera.height = camera.distance * slope
	camera.min_distance = CAMERA_RANGE * 0.5 * along
	camera.max_distance = CAMERA_RANGE * 1.5 * along
	camera.zoom_step = CAMERA_RANGE * 0.125 * along
	root.add_child(camera)
	camera.owner = root

	# A hazy afternoon: the far city fades into the sky colour, contact
	# shadows ground the blocks, and filmic tonemapping keeps the pale
	# concrete from clipping.
	var haze := HAZE
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = haze
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.84, 0.95)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_radius = 2.5
	env.ssao_intensity = 2.5
	env.ssao_detail = 0.5
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = haze
	env.fog_depth_begin = CAMERA_RANGE * 1.5
	env.fog_depth_end = CAMERA_RANGE * 9.0
	env.fog_depth_curve = 1.6
	env.fog_sky_affect = 1.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 0.92
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	root.add_child(world_env)
	world_env.owner = root

	var sun := DirectionalLight3D.new()
	sun.name = "DirectionalLight3D"
	sun.rotation_degrees = Vector3(-50, -40, 0)
	sun.light_color = Color(1.0, 0.94, 0.84)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.shadow_blur = 1.5
	sun.directional_shadow_max_distance = CAMERA_RANGE * 3.0
	root.add_child(sun)
	sun.owner = root

	var scene := PackedScene.new()
	var err := scene.pack(root)
	if err == OK:
		err = ResourceSaver.save(scene, path)
	print("overworld -> %s (%s)" % [path, error_string(err)])
	root.free()
	return err


## A lat/lon as a point on the scaled map.
func _local(meta: Dictionary, lat: float, lon: float) -> Vector3:
	var lat0: float = meta.origin[0]
	var lon0: float = meta.origin[1]
	var m_lat := 111320.0
	var m_lon := 111320.0 * cos(deg_to_rad(lat0))
	return Vector3((lon - lon0) * m_lon, 0.0, -(lat - lat0) * m_lat) * _scale

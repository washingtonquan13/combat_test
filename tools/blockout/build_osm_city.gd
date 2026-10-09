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
	Color8(178, 168, 150), Color8(100, 120, 96), Color8(112, 140, 92), Color8(170, 170, 160),
	Color8(110, 100, 92), Color8(122, 120, 118), Color8(96, 94, 96), Color8(64, 92, 112),
]
const BUILDING_COLORS := [Color(0.80, 0.78, 0.74), Color(0.55, 0.54, 0.52)]
const EDGE_WALL := 4.0
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

	var blocks_mat := StandardMaterial3D.new()
	blocks_mat.vertex_color_use_as_albedo = true
	blocks_mat.vertex_color_is_srgb = true
	blocks_mat.roughness = 0.9
	var ground_mat := StandardMaterial3D.new()
	ground_mat.vertex_color_use_as_albedo = true
	ground_mat.vertex_color_is_srgb = true
	ground_mat.roughness = 1.0
	var tris := 0
	for tile in meta.tiles:
		var body := StaticBody3D.new()
		body.name = "Tile_%d_%d" % [tile.x, tile.z]
		geometry.add_child(body)
		var faces := PackedVector3Array()
		if tile.has("ground"):
			var ground := _load_tris(src + "/tiles/" + tile.ground, GROUND_COLORS)
			body.add_child(_mesh_instance("Ground", ground.mesh, ground_mat))
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
## kind and tint themselves for shaders.
func _load_tris(path: String, colors: Array) -> Dictionary:
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
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = faces
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	result.mesh = mesh
	return result


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

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.1, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	root.add_child(world_env)
	world_env.owner = root

	var sun := DirectionalLight3D.new()
	sun.name = "DirectionalLight3D"
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.shadow_enabled = true
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

extends Node
## Builds a blockout scene from a file made by osm_to_local.py and a
## hand-written terrain sidecar (<name>.terrain.json beside it).
##
##   godot --headless --path . res://tools/blockout/build_osm_blockout.tscn -- \
##       --src=res://data/blockouts/jackson_square.json --out=res://world/jackson_square.tscn
##
## A scene rather than a -s script so the autoloads exist: the area and
## camera scripts it attaches name them, and without them fail to compile.
##
## Buildings are CSGPolygon3D, so a footprint can be reshaped in the editor.
## Their collision is separate: a box along every wall, because
## NavigationGrid reads only BoxShape3D exactly and treats any other shape
## as its bounding box, which for an L-shaped building would block the
## street beside it. Reshaping a building in the editor therefore does not
## move its walls; re-run this, or move the wall boxes too.
##
## Map data (c) OpenStreetMap contributors, ODbL 1.0.

const WALL_THICKNESS := 0.6
## Longest piece a street or fence is cut into where the ground under it slopes.
const MAX_SLOPED_PIECE := 2.0
const GRID_TEXTURE := "res://assets/placeholder_grid.png"

var _root: Node3D
var _terrain: Dictionary
var _origin: Vector2
var _along: Vector2
var _across: Vector2
var _materials := {}
var _names := {}


func _ready() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var src: String = args.get("src", "")
	var out: String = args.get("out", "")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(src))
	_terrain = JSON.parse_string(FileAccess.get_file_as_string(src.get_basename() + ".terrain.json"))
	_origin = _v2(_terrain.frame.origin)
	_along = _v2(_terrain.frame.along).normalized()
	_across = Vector2(-_along.y, _along.x)

	_root = Node3D.new()
	_root.name = out.get_file().get_basename().to_pascal_case()
	_root.set_script(load("res://systems/world_system/game_area.gd"))
	_root.set_meta("osm_attribution", data.attribution)
	_root.set_meta("osm_bbox", data.bbox)

	var replaced := {}
	for deck in _terrain.decks:
		replaced[deck.replaces] = true
	_build_ground(data.half_extent)
	_build_areas(data.areas)
	_build_lines(data.lines)
	_build_buildings(data.buildings.filter(func(b): return not replaced.has(b.osm)))
	_build_trees(data.trees)
	_build_landmarks(data.landmarks)
	_build_staging(data.half_extent)

	var scene := PackedScene.new()
	var err := scene.pack(_root)
	if err == OK:
		err = ResourceSaver.save(scene, out)
	print("blockout: %s -> %s (%s)" % [src, out, error_string(err)])
	_root.free()
	get_tree().quit(0 if err == OK else 1)


# --- Ground shape -------------------------------------------------------------

## (along, across) of a map point in the terrain frame.
func _frame(p: Vector2) -> Vector2:
	var rel := p - _origin
	return Vector2(rel.dot(_along), rel.dot(_across))


func _height_at(p: Vector2) -> float:
	var f := _frame(p)
	var levee: Dictionary = _terrain.levee
	var h: float = clampf(inverse_lerp(levee.bank_from, levee.bank_to, f.y), 0.0, 1.0) * levee.top
	for deck in _terrain.decks:
		if f.x < deck.u[0] or f.x > deck.u[1]:
			continue
		if f.y >= deck.d[0] and f.y <= deck.d[1]:
			h = maxf(h, deck.top)
		elif f.y >= deck.ramp_from_d and f.y < deck.d[0]:
			h = maxf(h, inverse_lerp(deck.ramp_from_d, deck.d[0], f.y) * deck.top)
	return h


## A 3D point in the terrain frame: along, height, across.
func _frame_point(u: float, y: float, d: float) -> Vector3:
	var p := _origin + _along * u + _across * d
	return Vector3(p.x, y, p.y)


func _build_ground(half_extent: Array) -> void:
	var ground := _group(_root, "Ground")
	var size := Vector3(half_extent[0] * 2.0 + 20.0, 1.0, half_extent[1] * 2.0 + 20.0)
	_box(ground, "Street", Vector3(0, -0.5, 0), Basis(), size, _mat("asphalt"), true)

	var levee: Dictionary = _terrain.levee
	var length: float = levee.u_to - levee.u_from
	var mid_u: float = (levee.u_from + levee.u_to) * 0.5
	var basis := Basis(Vector3(_along.x, 0, _along.y), Vector3.UP, Vector3(_across.x, 0, _across.y))
	# The bank: a slab tilted so its top runs from the street up to the crest.
	var run: float = levee.bank_to - levee.bank_from
	var slope: float = atan2(levee.top, run)
	var slab := 2.0
	var tilt: Basis = basis * Basis(Vector3.RIGHT, -slope)
	var centre := _frame_point(mid_u, levee.top * 0.5, (levee.bank_from + levee.bank_to) * 0.5)
	centre -= tilt.y * slab * 0.5
	_box(ground, "LeveeBank", centre, tilt, Vector3(length, slab, Vector2(run, levee.top).length() + 0.5), _mat("levee"), true)
	var crest_depth: float = levee.far - levee.bank_to
	_box(ground, "LeveeCrest", _frame_point(mid_u, levee.top * 0.5, levee.bank_to + crest_depth * 0.5), basis,
		Vector3(length, levee.top, crest_depth), _mat("levee"), true)

	for deck in _terrain.decks:
		var du: float = deck.u[1] - deck.u[0]
		var dd: float = deck.d[1] - deck.d[0]
		var mu: float = (deck.u[0] + deck.u[1]) * 0.5
		_box(ground, deck.name, _frame_point(mu, deck.top * 0.5, deck.d[0] + dd * 0.5), basis,
			Vector3(du, deck.top, dd), _mat("deck"), true)
		var ramp_run: float = deck.d[0] - deck.ramp_from_d
		var ramp_tilt: Basis = basis * Basis(Vector3.RIGHT, -atan2(deck.top, ramp_run))
		var ramp_centre: Vector3 = _frame_point(mu, deck.top * 0.5, deck.ramp_from_d + ramp_run * 0.5) - ramp_tilt.y * slab * 0.5
		_box(ground, deck.name + "Steps", ramp_centre, ramp_tilt,
			Vector3(du, slab, Vector2(ramp_run, deck.top).length() + 0.5), _mat("deck"), true)


# --- Map features ---------------------------------------------------------------

func _build_areas(areas: Array) -> void:
	var group := _group(_root, "Parks")
	for area in areas:
		var poly := _poly(area.poly)
		var csg := _extrusion(group, _name(area.name if area.name else area.kind), poly, 0.03, 0.0)
		csg.material = _mat("grass" if area.kind in ["park", "grass", "garden"] else "paving")


func _build_lines(lines: Array) -> void:
	var streets := _group(_root, "Streets")
	var barriers := _group(_root, "Barriers")
	for line in lines:
		var pts: Array = line.pts
		var parent := barriers if line.kind == "barrier" else streets
		var holder := _group(parent, _name(line.name if line.name else line.type))
		for i in pts.size() - 1:
			var a := _v2(pts[i])
			var b := _v2(pts[i + 1])
			if a.distance_to(b) < 0.05:
				continue
			# A segment only knows the ground at its two ends, so one that
			# crosses the levee bank or a ramp is cut short enough to follow
			# it instead of cutting through.
			var pieces := 1
			for t in [0.25, 0.5, 0.75, 1.0]:
				if not is_equal_approx(_height_at(a), _height_at(a.lerp(b, t))):
					pieces = ceili(a.distance_to(b) / MAX_SLOPED_PIECE)
					break
			for k in pieces:
				var pa := a.lerp(b, float(k) / pieces)
				var pb := a.lerp(b, float(k + 1) / pieces)
				var ya := _height_at(pa)
				var yb := _height_at(pb)
				if line.kind == "barrier":
					var h: float = line.height
					_segment(holder, pa, pb, ya + h * 0.5, yb + h * 0.5, Vector2(line.width, h), _mat("barrier"), true)
				else:
					var mat := _mat({"rail": "rail", "steps": "steps"}.get(line.kind, "footway" if line.width < 5.0 else "road"))
					_segment(holder, pa, pb, ya + 0.02, yb + 0.02, Vector2(line.width, 0.04), mat, false)
		if holder.get_child_count() == 0:
			holder.free()


func _build_buildings(buildings: Array) -> void:
	var group := _group(_root, "Buildings")
	for building in buildings:
		var outer := _poly(building.outer)
		var base := INF
		for p in outer:
			base = minf(base, _height_at(p))
		var height: float = building.height
		var node := _group(group, _name(building.name))
		node.set_meta("osm", building.osm)
		node.set_meta("height_source", building.height_source)
		var csg := _extrusion(node, "Shape", outer, height, base)
		csg.material = _mat("landmark" if not building.name.begins_with("Building") else "building")
		for i in building.inners.size():
			var cut := _extrusion(csg, "Courtyard%d" % (i + 1), _poly(building.inners[i]), height + 2.0, 0.0)
			cut.operation = CSGShape3D.OPERATION_SUBTRACTION
			cut.position = Vector3(0, 0, 1.0)
		var walls := StaticBody3D.new()
		walls.name = "Walls"
		_add(node, walls)
		for ring in [outer] + building.inners.map(_poly):
			for i in ring.size():
				var a: Vector2 = ring[i]
				var b: Vector2 = ring[(i + 1) % ring.size()]
				if a.distance_to(b) >= 0.05:
					_segment_shape(walls, a, b, base + height * 0.5, Vector2(WALL_THICKNESS, height))


func _build_trees(trees: Array) -> void:
	var group := _group(_root, "Trees")
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.2
	trunk_mesh.bottom_radius = 0.3
	trunk_mesh.height = 3.5
	var canopy_mesh := SphereMesh.new()
	canopy_mesh.radius = 2.4
	canopy_mesh.height = 3.6
	var trunk_shape := BoxShape3D.new()
	trunk_shape.size = Vector3(0.5, 3.5, 0.5)
	for t in trees:
		var p := _v2(t)
		var tree := StaticBody3D.new()
		tree.name = _name("Tree")
		tree.position = Vector3(p.x, _height_at(p), p.y)
		_add(group, tree)
		_mesh(tree, "Trunk", trunk_mesh, Vector3(0, 1.75, 0), _mat("trunk"))
		_mesh(tree, "Canopy", canopy_mesh, Vector3(0, 4.6, 0), _mat("canopy"))
		var shape := CollisionShape3D.new()
		shape.name = "Collision"
		shape.shape = trunk_shape
		shape.position = Vector3(0, 1.75, 0)
		_add(tree, shape)


func _build_landmarks(landmarks: Array) -> void:
	var group := _group(_root, "Landmarks")
	for mark in landmarks:
		var size: Vector3 = {"monument": Vector3(3, 7, 3), "cannon": Vector3(1, 1, 2.5)}.get(mark.kind, Vector3.ZERO)
		if size == Vector3.ZERO:
			continue
		var p := _v2(mark.pos)
		_box(group, _name(mark.name), Vector3(p.x, _height_at(p) + size.y * 0.5, p.y), Basis(), size, _mat("landmark"), true)


func _build_staging(half_extent: Array) -> void:
	var spawn := Marker3D.new()
	spawn.name = "PartySpawnPoint"
	var s := _v2(_terrain.spawn)
	spawn.position = Vector3(s.x, _height_at(s) + 0.5, s.y)
	_add(_root, spawn)

	var camera: Node3D = load("res://systems/camera_system/crpg_camera.tscn").instantiate()
	camera.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-45.0)), spawn.position + Vector3(0, 8, 8))
	camera.set("max_pan_radius", maxf(half_extent[0], half_extent[1]))
	_add(_root, camera)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.62, 0.7)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.66, 0.72)
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	_add(_root, world_env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	sun.basis = Basis.from_euler(Vector3(deg_to_rad(-50.0), deg_to_rad(30.0), 0.0))
	_add(_root, sun)


# --- Node helpers ----------------------------------------------------------------

func _add(parent: Node, node: Node) -> void:
	parent.add_child(node)
	node.owner = _root


func _group(parent: Node, group_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = group_name
	_add(parent, node)
	return node


## Node names must be unique among siblings; numbering them by hand keeps
## the editor's tree readable instead of Godot's "@Node3D@12" fallback.
func _name(raw: String) -> String:
	var base := raw.validate_node_name().replace(" ", "")
	if base.is_empty():
		base = "Feature"
	_names[base] = _names.get(base, 0) + 1
	return base if _names[base] == 1 else "%s%d" % [base, _names[base]]


## A footprint stood up: the polygon is drawn in the XZ plane and extruded
## upward from base by height.
func _extrusion(parent: Node, node_name: String, poly: PackedVector2Array, height: float, base: float) -> CSGPolygon3D:
	var csg := CSGPolygon3D.new()
	csg.name = node_name
	csg.polygon = poly
	csg.depth = height
	# CSGPolygon3D draws in its XY plane and extrudes along -Z; turning it
	# +90 degrees about X lays XY onto the ground and points -Z up.
	csg.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
	csg.position = Vector3(0, base, 0)
	_add(parent, csg)
	return csg


func _box(parent: Node, node_name: String, centre: Vector3, basis: Basis, size: Vector3, material: Material, collide: bool) -> Node3D:
	var node: Node3D = StaticBody3D.new() if collide else Node3D.new()
	node.name = node_name
	node.transform = Transform3D(basis, centre)
	_add(parent, node)
	var mesh := BoxMesh.new()
	mesh.size = size
	_mesh(node, "Mesh", mesh, Vector3.ZERO, material)
	if collide:
		var shape := BoxShape3D.new()
		shape.size = size
		var cs := CollisionShape3D.new()
		cs.name = "Collision"
		cs.shape = shape
		_add(node, cs)
	return node


func _mesh(parent: Node, node_name: String, mesh: Mesh, at: Vector3, material: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.position = at
	mi.material_override = material
	_add(parent, mi)


## A box laid from a to b: section.x wide, section.y tall, its centre at
## ya at a and yb at b, so it follows the ground up a slope.
func _segment(parent: Node, a: Vector2, b: Vector2, ya: float, yb: float, section: Vector2, material: Material, collide: bool) -> void:
	var from := Vector3(a.x, ya, a.y)
	var to := Vector3(b.x, yb, b.y)
	var dir := (to - from).normalized()
	var side := dir.cross(Vector3.UP).normalized()
	var basis := Basis(dir, side.cross(dir), side)
	var length := from.distance_to(to)
	_box(parent, "Segment%d" % parent.get_child_count(), (from + to) * 0.5, basis,
		Vector3(length + section.x * 0.5, section.y, section.x), material, collide)


func _segment_shape(body: StaticBody3D, a: Vector2, b: Vector2, y: float, section: Vector2) -> void:
	var dir := Vector3(b.x - a.x, 0, b.y - a.y)
	var length := dir.length()
	dir /= length
	var shape := BoxShape3D.new()
	shape.size = Vector3(length + section.x, section.y, section.x)
	var cs := CollisionShape3D.new()
	cs.name = "Wall%d" % body.get_child_count()
	cs.shape = shape
	cs.transform = Transform3D(Basis(dir, Vector3.UP, dir.cross(Vector3.UP)), Vector3((a.x + b.x) * 0.5, y, (a.y + b.y) * 0.5))
	_add(body, cs)


func _mat(kind: String) -> StandardMaterial3D:
	if _materials.has(kind):
		return _materials[kind]
	var colors := {
		"asphalt": Color(0.27, 0.27, 0.29), "road": Color(0.33, 0.33, 0.35), "footway": Color(0.62, 0.6, 0.55),
		"paving": Color(0.66, 0.62, 0.55), "steps": Color(0.75, 0.72, 0.64), "rail": Color(0.35, 0.28, 0.22),
		"grass": Color(0.36, 0.5, 0.3), "levee": Color(0.42, 0.52, 0.33), "deck": Color(0.7, 0.66, 0.58),
		"building": Color(0.8, 0.77, 0.72), "landmark": Color(0.86, 0.7, 0.55), "barrier": Color(0.2, 0.2, 0.22),
		"trunk": Color(0.35, 0.26, 0.18), "canopy": Color(0.25, 0.42, 0.22),
	}
	var mat := StandardMaterial3D.new()
	mat.resource_name = kind
	mat.albedo_color = colors[kind]
	if kind not in ["canopy", "trunk", "barrier"]:
		mat.albedo_texture = load(GRID_TEXTURE)
		mat.uv1_triplanar = true
		mat.uv1_scale = Vector3(0.5, 0.5, 0.5)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_materials[kind] = mat
	return mat


func _v2(a: Array) -> Vector2:
	return Vector2(a[0], a[1])


func _poly(points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(_v2(p))
	return out

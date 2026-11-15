extends SceneTree

# Bakes the raid camp: a palisade square on open ground at dusk, with a gate
# in the north wall, a postern in the south, a fighting walk inside the logs
# reached by ladders, tents, crates and a fire, and a road up from the north
# with cover along it. Writes world/raid_camp.tscn and its meshes, materials
# and environment under world/raid_camp/. Everything about the camp is
# authored here; the scene file is output, rerun this to change it.
#
#   godot --path . -s tools/camp/bake_raid_camp.gd
#
# Collision is boxes only, each a CollisionShape3D straight under a
# StaticBody3D, which is what the nav grid reads: the logs, the walk (its top
# is the floor up there), tents, crates, cover. The fire and the road have
# none.

const SCENE := "res://world/raid_camp.tscn"
const OUT := "res://world/raid_camp/"
const QUARRY_PROPS := "res://world/goblin_quarry/props/"
const T := "res://assets/level/quarry/textures/"
const M := "res://assets/level/quarry/models/"

const UNIT := "res://systems/unit_system/unit.tscn"
const LADDER := "res://world/ladder.tscn"
const CAMERA := "res://systems/camera_system/crpg_camera.tscn"
const AREA_SCRIPT := "res://world/raid_camp.gd"
const FLICKER := "res://world/goblin_quarry/fire_flicker.gd"

# The logs stand on a square this far out from the middle, and the walk
# inside them is this wide and this high.
const HALF := 15.0
const LOG_DEPTH := 0.4
const WALK := 1.4
const WALK_TOP := 2.2
const WALL_TOP := 3.6
# The gate's opening in the north wall and the postern's in the south.
const GATE_HALF := 2.0
const POSTERN_HALF := 1.2

const ROAD := [Vector2(0, -14), Vector2(0.6, -22), Vector2(-1.4, -32), Vector2(1.0, -42), Vector2(3.0, -55), Vector2(4.5, -72)]
const PATH_SOUTH := [Vector2(0, 14), Vector2(-0.5, 22), Vector2(1.5, 34), Vector2(0.5, 50)]

const ENEMY_HOVER := Color(1, 0, 0, 0.501961)
const ENEMY_SELECTED := Color(1, 0, 0, 0.627451)

var g
var camp: Node3D


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT + "props")
	g = load("res://tools/quarry/prop_gen.gd").new()
	for key in ["planks", "beam", "stone", "canvas", "dark"]:
		var path: String = QUARRY_PROPS + "mat_%s.tres" % key
		if ResourceLoader.exists(path):
			g._mats[key] = load(path)

	camp = Node3D.new()
	camp.name = "RaidCamp"
	camp.set_script(load(AREA_SCRIPT))
	var level := _node(Node3D.new(), "LevelGeometry", camp)

	_ground(level)
	_palisade(level)
	_gate()
	_ladders()
	_camp(level)
	_approach(level)
	_fire()
	_units()
	_lighting()

	var spawn := _node(Marker3D.new(), "PartySpawnPoint", camp)
	spawn.position = Vector3(0, 0, 24)
	var camera: Node3D = _instance(CAMERA, "CRPGCamera", camp)
	camera.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(-45), 0, 0)), Vector3(0, 12, 34))
	camera.set("max_pan_radius", 60.0)
	camp.set("party_spawn_point", spawn)

	var packed := PackedScene.new()
	var err := packed.pack(camp)
	if err == OK:
		err = ResourceSaver.save(packed, SCENE)
	print("raid camp: pack/save err %d" % err)
	quit(0 if err == OK else 1)


# ---------------------------------------------------------------- the ground

func _ground(level: Node3D) -> void:
	var ground := _node(StaticBody3D.new(), "Ground", level)
	_box_shape(ground, Vector3(0, -1, 0), Vector3(180, 2, 180))
	var plane := PlaneMesh.new()
	# Wider than the collision: the fog hides where the ground ends, not
	# the edge of a square.
	plane.size = Vector2(600, 600)
	_mesh_node(ground, "Mesh", plane, _ground_mat("forest_ground_04", 5.0, "ground"))

	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(HALF * 2, HALF * 2)
	var floor_node: MeshInstance3D = _mesh_node(level, "CampFloor", floor_mesh, _ground_mat("dirt_floor", 3.5, "camp_floor"))
	floor_node.position.y = 0.012
	_mesh_node(level, "Road", _strip(ROAD, 3.4, 0.022), _ground_mat("grass_path_2", 4.0, "road"))
	_mesh_node(level, "PathSouth", _strip(PATH_SOUTH, 2.2, 0.022), load(OUT + "props/mat_road.tres"))


## Textured in world space, so a plane of any size and the road strip all
## have the same texel density and no seams.
func _ground_mat(set_name: String, metres: float, key: String) -> Material:
	var path := OUT + "props/mat_%s.tres" % key
	var m := ORMMaterial3D.new()
	m.albedo_texture = load(T + set_name + "_diff_2k.jpg")
	m.normal_enabled = true
	m.normal_texture = load(T + set_name + "_nor_gl_2k.jpg")
	m.orm_texture = load(T + set_name + "_arm_2k.jpg")
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE / metres
	ResourceSaver.save(m, path)
	return load(path)


## A flat ribbon `width` wide along `points`, `lift` above the ground.
func _strip(points: Array, width: float, lift: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	var left: Array[Vector3] = []
	var right: Array[Vector3] = []
	for i in points.size():
		var prev: Vector2 = points[maxi(i - 1, 0)]
		var next: Vector2 = points[mini(i + 1, points.size() - 1)]
		var along := (next - prev).normalized()
		var side := Vector2(-along.y, along.x) * width * 0.5
		var p: Vector2 = points[i]
		left.append(Vector3(p.x + side.x, lift, p.y + side.y))
		right.append(Vector3(p.x - side.x, lift, p.y - side.y))
	for i in points.size() - 1:
		for v in [left[i], right[i], right[i + 1], left[i], right[i + 1], left[i + 1]]:
			st.add_vertex(v)
	st.generate_tangents()
	return st.commit()


# ---------------------------------------------------------------- the wall

func _palisade(level: Node3D) -> void:
	var wall := _node(Node3D.new(), "Palisade", level)
	var trim := HALF + LOG_DEPTH * 0.5 - (HALF - LOG_DEPTH * 0.5 - WALK)
	var corner := HALF + LOG_DEPTH * 0.5
	var north_len := corner - GATE_HALF
	var south_len := corner - POSTERN_HALF
	# [name, middle of the log line, length, inward, walk trimmed at -x end, at +x end] (local x).
	var plan := [
		["NorthWest", Vector3(-(GATE_HALF + north_len * 0.5), 0, -HALF), north_len, Vector3.BACK, trim, 0.0],
		["NorthEast", Vector3(GATE_HALF + north_len * 0.5, 0, -HALF), north_len, Vector3.BACK, 0.0, trim],
		["SouthWest", Vector3(-(POSTERN_HALF + south_len * 0.5), 0, HALF), south_len, Vector3.FORWARD, 0.0, trim],
		["SouthEast", Vector3(POSTERN_HALF + south_len * 0.5, 0, HALF), south_len, Vector3.FORWARD, trim, 0.0],
		["West", Vector3(-HALF, 0, 0), 2.0 * (HALF - LOG_DEPTH * 0.5), Vector3.RIGHT, 0.0, 0.0],
		["East", Vector3(HALF, 0, 0), 2.0 * (HALF - LOG_DEPTH * 0.5), Vector3.LEFT, 0.0, 0.0],
	]
	var seed := 100
	for row in plan:
		seed += 1
		_wall_segment(wall, row[0], row[1], row[2], row[3], row[4], row[5], seed)
	# Gate and postern posts.
	for row in [["GatePosts", -HALF, GATE_HALF, 0.26, 4.8], ["PosternPosts", HALF, POSTERN_HALF, 0.2, 4.0]]:
		var body := _node(StaticBody3D.new(), row[0], wall)
		body.position = Vector3(0, 0, row[1])
		for s in [-1.0, 1.0]:
			var x: float = s * (row[2] + row[3] - 0.05)
			g.cyl("beam", g._xf(Vector3(x, row[4] * 0.5, 0)), row[3], row[4], 12)
			_box_shape(body, Vector3(x, row[4] * 0.5, 0), Vector3(row[3] * 2, row[4], row[3] * 2))
		var top: float = row[4] - 0.35
		g.beam("beam", Vector3(-(row[2] + 0.5), top, 0), Vector3(row[2] + 0.5, top, 0), 0.26)
		_mesh_node(body, "Mesh", _save(g.commit(), row[0]))


## One straight run of logs with the walk along its inside. The node sits on
## the middle of the log line, local +z inward, local x along the wall.
func _wall_segment(parent: Node3D, seg_name: String, at: Vector3, length: float, inward: Vector3,
		trim_a: float, trim_b: float, seed: int) -> void:
	g.rng.seed = seed
	var body := _node(StaticBody3D.new(), seg_name, parent)
	var along := Vector3.UP.cross(inward)
	body.transform = Transform3D(Basis(along, Vector3.UP, inward), at)

	var count := int(round(length / 0.31))
	for i in count:
		var x := -length * 0.5 + (i + 0.5) * length / count
		var r: float = g.rng.randf_range(0.14, 0.17)
		var h: float = g.rng.randf_range(WALL_TOP - 0.15, WALL_TOP + 0.2)
		var z: float = g.rng.randf_range(-0.04, 0.04)
		g.cyl("beam", g._xf(Vector3(x, (h - 0.3) * 0.5, z), g.rng.randf() * TAU, g.rng.randf_range(-0.015, 0.015), g.rng.randf_range(-0.015, 0.015)), r, h + 0.3, 7, false)
		_point(Vector3(x, h, z), r, g.rng.randf_range(0.25, 0.4))
	# Rails lashing the logs, outside and in.
	for y in [0.9, 2.9]:
		for s in [-1.0, 1.0]:
			g.beam("beam", Vector3(-length * 0.5, y, s * 0.2), Vector3(length * 0.5, y, s * 0.2), 0.12)
	_box_shape(body, Vector3(0, WALL_TOP * 0.5, 0), Vector3(length, WALL_TOP, LOG_DEPTH))

	var x0 := -length * 0.5 + trim_a
	var x1 := length * 0.5 - trim_b
	var mid := (x0 + x1) * 0.5
	var span := x1 - x0
	var z_mid := LOG_DEPTH * 0.5 + WALK * 0.5
	var z_face := LOG_DEPTH * 0.5 + WALK
	g.box("planks", g._xf(Vector3(mid, WALK_TOP - 0.04, z_mid)), Vector3(span, 0.08, WALK), 2)
	g.box("planks", g._xf(Vector3(mid, WALK_TOP * 0.5, z_face - 0.03)), Vector3(span, WALK_TOP, 0.06), 1)
	g.box("dark", g._xf(Vector3(mid, WALK_TOP * 0.5, z_mid)), Vector3(span - 0.1, WALK_TOP - 0.2, WALK - 0.1))
	var posts := maxi(2, int(span / 2.2) + 1)
	for i in posts:
		var px := lerpf(x0 + 0.1, x1 - 0.1, float(i) / (posts - 1))
		g.box("beam", g._xf(Vector3(px, WALK_TOP * 0.5, z_face + 0.03)), Vector3(0.18, WALK_TOP + 0.02, 0.12), 1)
	g.beam("beam", Vector3(x0, WALK_TOP - 0.12, z_face + 0.07), Vector3(x1, WALK_TOP - 0.12, z_face + 0.07), 0.14)
	_box_shape(body, Vector3(mid, WALK_TOP * 0.5, z_mid), Vector3(span, WALK_TOP, WALK))
	_mesh_node(body, "Mesh", _save(g.commit(), "palisade_" + seg_name.to_snake_case()))


## A log's sharpened top: a cone of `segs` sides from radius r.
func _point(at: Vector3, r: float, h: float, segs := 7) -> void:
	var tip := at + Vector3.UP * h
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var p0 := at + Vector3(cos(a0), 0, sin(a0)) * r
		var p1 := at + Vector3(cos(a1), 0, sin(a1)) * r
		var n := (p1 - p0).cross(tip - p0).normalized()
		if n.dot(Vector3(cos(a0 + PI / segs), 0, sin(a0 + PI / segs))) < 0.0:
			n = -n
		g.face("beam", [p0, p1, tip], n, p1 - p0)


# ---------------------------------------------------------------- the gate

## Shut, it is two leaves with collision. Broken, the leaves are smashed in
## and lying inside, and nothing stops a body; raid_camp.gd picks which is
## there from a flag.
func _gate() -> void:
	var gate := _node(Node3D.new(), "Gate", camp)
	gate.position = Vector3(0, 0, -HALF)
	var closed := _node(StaticBody3D.new(), "Closed", gate)
	var leaf_w := GATE_HALF - 0.03
	for s in [-1.0, 1.0]:
		_leaf(g._xf(Vector3(s * leaf_w * 0.5, 1.6, 0)), leaf_w, 3.2, s < 0.0)
		_box_shape(closed, Vector3(s * leaf_w * 0.5, 1.6, 0), Vector3(leaf_w, 3.2, 0.3))
	g.beam("beam", Vector3(-GATE_HALF, 1.4, -0.22), Vector3(GATE_HALF, 1.4, -0.22), 0.2)
	_mesh_node(closed, "Mesh", _save(g.commit(), "gate_closed"))

	var broken := _node(Node3D.new(), "Broken", gate)
	broken.visible = false
	# The west leaf torn off and lying flat; the east one hanging open off its
	# top hinge, twisted; the bar snapped.
	_leaf(Transform3D(Basis.from_euler(Vector3(deg_to_rad(-88), deg_to_rad(18), 0)), Vector3(-1.3, 0.14, 2.4)), leaf_w, 3.2, true)
	_leaf(Transform3D(Basis.from_euler(Vector3(deg_to_rad(-12), deg_to_rad(-62), deg_to_rad(9))), Vector3(GATE_HALF - 0.45, 1.55, 0.85)), leaf_w, 3.2, false)
	g.beam("beam", Vector3(-1.8, 0.1, 1.2), Vector3(-0.3, 0.12, 0.6), 0.2)
	g.beam("beam", Vector3(0.2, 0.1, 1.9), Vector3(1.4, 0.1, 2.9), 0.2)
	for i in 6:
		var p := Vector3(g.rng.randf_range(-1.5, 1.5), 0.04, g.rng.randf_range(0.3, 3.5))
		g.beam("planks", p, p + Vector3(g.rng.randf_range(-0.6, 0.6), 0.0, g.rng.randf_range(-0.6, 0.6)), 0.06, 0.18)
	_mesh_node(broken, "Mesh", _save(g.commit(), "gate_broken"))


## One leaf in the frame `xf` (its middle): vertical planks, two ledges and a
## brace, the hinge on the outer side.
func _leaf(xf: Transform3D, w: float, h: float, hinge_west: bool) -> void:
	var boards := int(round(w / 0.24))
	for i in boards:
		var x := -w * 0.5 + (i + 0.5) * w / boards
		g.box("planks", xf * g._xf(Vector3(x, g.rng.randf_range(-0.02, 0.04), 0)), Vector3(w / boards - 0.012, h, 0.08), 1)
	for y in [-h * 0.32, h * 0.32]:
		g.box("beam", xf * g._xf(Vector3(0, y, 0.09)), Vector3(w - 0.06, 0.18, 0.08), 0)
	var a := Vector3(-w * 0.45 if hinge_west else w * 0.45, -h * 0.3, 0.09)
	var b := Vector3(-a.x, h * 0.3, 0.09)
	g.beam("beam", xf * a, xf * b, 0.14, 0.07)


# ---------------------------------------------------------------- ladders

## Two up the north wall either side of the gate, one up the west wall.
func _ladders() -> void:
	var ladders := _node(Node3D.new(), "Ladders", camp)
	var foot := HALF - LOG_DEPTH * 0.5 - WALK - 0.7
	var plan := [
		["NorthWest", Vector3(-6, 0, -foot), PI],
		["NorthEast", Vector3(6, 0, -foot), PI],
		["West", Vector3(-foot, 0, 4), -PI * 0.5],
	]
	for row in plan:
		var ladder: Node3D = _instance(LADDER, row[0], ladders)
		ladder.transform = Transform3D(Basis(Vector3.UP, row[2]), row[1])
		camp.set_editable_instance(ladder, true)
		(ladder.get_node("Top") as Node3D).position = Vector3(0, WALK_TOP, 1.25)


# ---------------------------------------------------------------- the camp

func _camp(level: Node3D) -> void:
	var camp := _node(Node3D.new(), "Camp", level)
	var seed := 200
	for row in [
			["TentNorthWest", Vector3(-8.5, 0, -5.5), 90.0],
			["TentSouthWest", Vector3(-8.5, 0, 3.5), 90.0],
			["TentNorthEast", Vector3(8.5, 0, -5.5), 270.0],
			["TentSouthEast", Vector3(8.5, 0, 3.5), 270.0]]:
		seed += 1
		_prop(camp, row[0], row[1], Vector3(3.2, 2.4, 3.2), g.tent(Vector3(3.2, 2.4, 3.2), row[2], seed))
	for row in [
			["CratesGate", Vector3(4.6, 0, -11.0), Vector3(1.2, 1.2, 2.2)],
			["CrateGate", Vector3(6.2, 0, -10.6), Vector3(1.0, 1.0, 1.0)],
			["CratesStore", Vector3(-10.6, 0, 10.8), Vector3(1.2, 1.2, 2.2)],
			["CrateStore", Vector3(-12.0, 0, 9.4), Vector3(1.0, 1.0, 1.0)],
			["CrateFire", Vector3(-3.2, 0, 2.6), Vector3(0.9, 0.8, 0.9)]]:
		seed += 1
		_prop(camp, row[0], row[1], row[2], g.crate(row[2], seed))
	_prop(camp, "Cart", Vector3(10.4, 0, 10.2), Vector3(2.0, 1.2, 3.0), g.cart(Vector3(2.0, 1.2, 3.0), 230))
	_prop(camp, "Rack", Vector3(3.8, 0, 9.0), Vector3(5.0, 1.0, 0.3), g.fence(Vector3(5.0, 1.0, 0.3), 231))


## A generated prop filling a box that stands on the ground at `at`.
func _prop(parent: Node3D, prop_name: String, at: Vector3, size: Vector3, mesh: ArrayMesh) -> StaticBody3D:
	var body := _node(StaticBody3D.new(), prop_name, parent)
	body.position = at + Vector3.UP * size.y * 0.5
	_box_shape(body, Vector3.ZERO, size)
	_mesh_node(body, "Mesh", _save(mesh, prop_name.to_snake_case()))
	return body


# ---------------------------------------------------------------- the approach

func _approach(level: Node3D) -> void:
	var road := _node(Node3D.new(), "Approach", level)
	_prop(road, "LowWallWest", Vector3(-5.5, 0, -26.0), Vector3(5.0, 1.1, 0.6), g.low_wall(Vector3(5.0, 1.1, 0.6), 240))
	_prop(road, "LowWallEast", Vector3(6.0, 0, -31.5), Vector3(4.0, 1.1, 0.6), g.low_wall(Vector3(4.0, 1.1, 0.6), 241))
	_prop(road, "Cart", Vector3(-4.8, 0, -37.5), Vector3(2.0, 1.2, 3.0), g.cart(Vector3(2.0, 1.2, 3.0), 242))
	_rock(road, "RockNear", "rock_07", Vector3(7.5, 0, -21.5), 0.6, 2.4)
	_rock(road, "RockFar", "rock_09", Vector3(-8.5, 0, -44.0), 2.1, 2.8)
	_rock(road, "RockRoad", "rock_07", Vector3(6.0, 0, -46.5), 3.7, 1.9)
	_rock(road, "Stump", "tree_stump_01", Vector3(-3.4, 0, -19.5), 1.2, 1.1)
	_rock(road, "Trunk", "dead_tree_trunk_02", Vector3(10.5, 0, -39.0), 0.3, 6.0)


## A scanned model, turned by `yaw` and scaled so its widest side is `fit`
## metres, sunk a little, with one box round it.
func _rock(parent: Node3D, rock_name: String, model: String, at: Vector3, yaw: float, fit: float) -> void:
	var scene: Node3D = (load(M + model + ".glb") as PackedScene).instantiate()
	var box := _aabb(scene, Transform3D.IDENTITY)
	scene.free()
	var scale := fit / maxf(box.size.x, box.size.z)
	var body := _node(StaticBody3D.new(), rock_name, parent)
	body.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	var model_node: Node3D = _instance(M + model + ".glb", "Model", body)
	model_node.scale = Vector3.ONE * scale
	var sunk := 0.08 * box.size.y * scale
	model_node.position = Vector3(-box.get_center().x * scale, -box.position.y * scale - sunk, -box.get_center().z * scale)
	var size := box.size * scale - Vector3(0.1, sunk, 0.1)
	_box_shape(body, Vector3(0, size.y * 0.5, 0), size)


func _aabb(node: Node, xf: Transform3D) -> AABB:
	var box := AABB()
	var first := true
	var here: Transform3D = xf * (node.transform if node is Node3D else Transform3D.IDENTITY)
	if node is MeshInstance3D and node.mesh:
		box = here * node.mesh.get_aabb()
		first = false
	for child in node.get_children():
		var sub := _aabb(child, here)
		if sub.size != Vector3.ZERO:
			box = sub if first else box.merge(sub)
			first = false
	return box


# ---------------------------------------------------------------- the fire

func _fire() -> void:
	var fire := _node(Node3D.new(), "Campfire", camp)
	fire.position = Vector3(0, 0, -1.0)
	g.rng.seed = 300
	for i in 11:
		var a := TAU * i / 11.0
		g.box("stone", g._xf(Vector3(cos(a) * 0.62, 0.09, sin(a) * 0.62), -a, g.rng.randf_range(-0.2, 0.2)), Vector3(0.3, 0.2, 0.2))
	for i in 5:
		var a := TAU * i / 5.0 + 0.3
		g.beam("beam", Vector3(cos(a) * 0.45, 0.05, sin(a) * 0.45), Vector3(cos(a) * 0.05, 0.42, sin(a) * 0.05), 0.1)
	_mesh_node(fire, "Mesh", _save(g.commit(), "campfire"))

	var embers := SphereMesh.new()
	embers.radius = 0.32
	embers.height = 0.22
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.12, 0.04, 0.02)
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.36, 0.08)
	glow.emission_energy_multiplier = 3.0
	var ember_node: MeshInstance3D = _mesh_node(fire, "Embers", embers, glow)
	ember_node.position.y = 0.04

	var flames := GPUParticles3D.new()
	flames.amount = 40
	flames.lifetime = 0.7
	flames.position.y = 0.15
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.22
	process.direction = Vector3.UP
	process.spread = 12.0
	process.initial_velocity_min = 0.6
	process.initial_velocity_max = 1.3
	process.gravity = Vector3(0, 0.6, 0)
	process.scale_min = 0.6
	process.scale_max = 1.0
	var fade := Curve.new()
	fade.add_point(Vector2(0, 0.4))
	fade.add_point(Vector2(0.25, 1.0))
	fade.add_point(Vector2(1, 0))
	var fade_tex := CurveTexture.new()
	fade_tex.curve = fade
	process.scale_curve = fade_tex
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.85, 0.45, 1))
	ramp.set_color(1, Color(0.9, 0.18, 0.02, 0))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	process.color_ramp = ramp_tex
	flames.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.4, 0.55)
	var flame_mat := StandardMaterial3D.new()
	flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flame_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flame_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	flame_mat.vertex_color_use_as_albedo = true
	flame_mat.albedo_texture = _soft_dot()
	flame_mat.albedo_color = Color(1.6, 1.2, 1.0)
	quad.material = flame_mat
	flames.draw_pass_1 = quad
	_node(flames, "Flames", fire)

	var light := OmniLight3D.new()
	light.set_script(load(FLICKER))
	light.light_color = Color(1.0, 0.58, 0.28)
	light.light_energy = 1.8
	light.omni_range = 11.0
	light.shadow_enabled = true
	light.position.y = 0.9
	_node(light, "Light", fire)


func _soft_dot() -> Texture2D:
	var path := OUT + "props/flame_dot.tres"
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	ResourceSaver.save(tex, path)
	return load(path)


# ---------------------------------------------------------------- who is here

## The camp's people and the raiders, every one authored with an id so what
## happens to them is kept (spawned units are not). Goblins wait out of sight
## down the road; the raid is a scene that brings them up.
func _units() -> void:
	var watch := "res://data/units/npcs/quarry_watchman.tres"
	var towns := "res://data/units/npcs/townsperson.tres"
	var rogue := "res://data/units/demons/goblin_rogue.tres"
	var shaman := "res://data/units/demons/goblin_shaman.tres"
	var hob := "res://data/units/demons/hobgoblin.tres"
	var walk_y := WALK_TOP
	var walk_z := -(HALF - LOG_DEPTH * 0.5 - WALK * 0.5)
	# [node, definition, id, position, facing (degrees, 0 = +z)]
	var plan := [
		["Lookout", watch, "lookout", Vector3(-3.4, walk_y, walk_z), 180.0],
		["GuardGate", watch, "guard_gate", Vector3(2.6, 0, -9.0), 180.0],
		["GuardFire", watch, "guard_fire", Vector3(-1.8, 0, -2.6), 150.0],
		["CamperFire", towns, "camper_fire", Vector3(1.4, 0, 0.4), 200.0],
		["CamperTent", towns, "camper_tent", Vector3(6.2, 0, 4.0), 260.0],
		["Hobgoblin", hob, "hobgoblin", Vector3(1.5, 0, -56.0), 0.0],
		["RogueA", rogue, "rogue_a", Vector3(-1.0, 0, -54.0), 0.0],
		["RogueB", rogue, "rogue_b", Vector3(3.6, 0, -57.5), 0.0],
		["RogueC", rogue, "rogue_c", Vector3(-0.5, 0, -59.0), 0.0],
		["RogueD", rogue, "rogue_d", Vector3(4.6, 0, -53.0), 0.0],
		["ArcherWest", shaman, "archer_west", Vector3(-2.5, 0, -61.0), 0.0],
		["ArcherEast", shaman, "archer_east", Vector3(6.0, 0, -61.5), 0.0],
	]
	for row in plan:
		var unit: Node3D = _instance(UNIT, row[0], camp)
		unit.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(row[4])), row[3])
		unit.set("definition", load(row[1]))
		unit.set("persistent_id", StringName("raid_camp_" + row[2]))
		if row[1] in [rogue, shaman, hob]:
			unit.set("hover_color", ENEMY_HOVER)
			unit.set("selected_color", ENEMY_SELECTED)


# ---------------------------------------------------------------- dusk

func _lighting() -> void:
	var env: Environment = load("res://world/goblin_quarry/quarry_environment.tres").duplicate(true)
	var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
	sky_mat.sky_top_color = Color(0.16, 0.2, 0.36)
	sky_mat.sky_horizon_color = Color(0.92, 0.56, 0.36)
	sky_mat.ground_horizon_color = Color(0.34, 0.25, 0.2)
	sky_mat.ground_bottom_color = Color(0.08, 0.07, 0.06)
	sky_mat.sun_angle_max = 12.0
	env.ambient_light_energy = 0.5
	env.volumetric_fog_density = 0.011
	env.volumetric_fog_albedo = Color(1.0, 0.78, 0.6)
	var env_path := OUT + "raid_camp_environment.tres"
	ResourceSaver.save(env, env_path)
	var world_env := _node(WorldEnvironment.new(), "WorldEnvironment", camp)
	world_env.environment = load(env_path)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.64, 0.4)
	sun.light_energy = 1.7
	sun.light_volumetric_fog_energy = 1.6
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.9
	sun.shadow_blur = 1.5
	sun.directional_shadow_max_distance = 80.0
	# Low in the west, behind the left shoulder of someone looking up the road.
	var travel := Vector3(0.88, -0.2, 0.42).normalized()
	sun.transform = Transform3D(Basis.looking_at(travel, Vector3.UP), Vector3(0, 12, 0))
	_node(sun, "Sun", camp)


# ---------------------------------------------------------------- helpers

func _node(node: Node, node_name: String, parent: Node) -> Node:
	node.name = node_name
	parent.add_child(node)
	node.owner = camp
	return node


func _instance(path: String, node_name: String, parent: Node) -> Node:
	var node: Node = (load(path) as PackedScene).instantiate()
	return _node(node, node_name, parent)


func _box_shape(body: Node3D, at: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = at
	_node(col, "Shape%d" % body.get_child_count(), body)


func _mesh_node(parent: Node, node_name: String, mesh: Mesh, mat: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if mat:
		mi.material_override = mat
	return _node(mi, node_name, parent)


func _save(mesh: ArrayMesh, file: String) -> ArrayMesh:
	var path := OUT + "props/%s.res" % file
	ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
	return load(path)

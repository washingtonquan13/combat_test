extends RefCounted

# The palisade camp east of the quarry, built for tools/quarry/bake_goblin_quarry.gd:
# a square of logs with a gate in the north wall (toward -z), a postern in the
# south, a fighting walk inside the logs reached by ladders, tents, crates and
# a fire, and cover along the road up to the gate. The quarry bake levels the
# ground under it and paints the floor and the roads; this builds what stands
# on that ground and saves it as one scene the quarry instances.
#
# Everything here is in the camp's own space: the middle of the floor at the
# origin, the gate at -z. `ground` answers the terrain's height there, so logs,
# posts and props stand on the slope round the edge instead of floating on it.
#
# Collision is boxes only, each a CollisionShape3D straight under a
# StaticBody3D, which is what the nav grid reads: the logs, the walk (its top
# is the floor up there), tents, crates, cover. The fire has none.

const M := "res://assets/level/quarry/models/"
const LADDER := "res://world/ladder.tscn"
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
## How much of the ground's fall round the edge the log tops follow. The walk
## stays level, so all of it would leave too little wall above the walk.
const TOP_FOLLOW := 0.5

## The road up to the gate and the path out of the postern, camp-local. The
## quarry bake paints and flattens them; this only puts cover along the road.
const ROAD := [Vector2(0, -14), Vector2(0.6, -22), Vector2(-1.4, -32), Vector2(1.0, -42), Vector2(3.0, -55), Vector2(4.5, -72)]

## Where the camp's people stand and where the raiders wait, camp-local:
## [node, definition key, position, facing (degrees, 0 = +z)]. y is above the
## ground there, but for the lookout, who is on the walk.
const PEOPLE := [
	["Lookout", "watch", Vector3(-3.4, WALK_TOP, -(HALF - LOG_DEPTH * 0.5 - WALK * 0.5)), 180.0],
	["GuardGate", "watch", Vector3(2.6, 0, -9.0), 180.0],
	["GuardFire", "watch", Vector3(-1.8, 0, -2.6), 150.0],
	["CamperFire", "towns", Vector3(1.4, 0, 0.4), 200.0],
	["CamperTent", "towns", Vector3(6.2, 0, 4.0), 260.0],
	["Hobgoblin", "hob", Vector3(1.5, 0, -56.0), 0.0],
	["RogueA", "rogue", Vector3(-1.0, 0, -54.0), 0.0],
	["RogueB", "rogue", Vector3(3.6, 0, -57.5), 0.0],
	["RogueC", "rogue", Vector3(-0.5, 0, -59.0), 0.0],
	["RogueD", "rogue", Vector3(4.6, 0, -53.0), 0.0],
	["ArcherWest", "shaman", Vector3(-2.5, 0, -61.0), 0.0],
	["ArcherEast", "shaman", Vector3(6.0, 0, -61.5), 0.0],
]

## Places the quarry's clutter must leave alone, camp-local [centre, radius]:
## the approach cover and the raiders' ground.
const KEEP_OUT := [
	[Vector2(-5.5, -26.0), 3.2], [Vector2(6.0, -31.5), 2.8], [Vector2(-4.8, -37.5), 2.6],
	[Vector2(7.5, -21.5), 2.0], [Vector2(-8.5, -44.0), 2.2], [Vector2(6.0, -46.5), 1.8],
	[Vector2(-3.4, -19.5), 1.4], [Vector2(10.5, -39.0), 3.6],
	[Vector2(2.0, -57.0), 7.5],
]

var g
var root: Node3D
var ground: Callable
var out: String


## Builds the camp, saving its meshes under `out_dir`; `ground_fn(x, z)` is the
## terrain's height in camp space. The caller packs and frees what it returns.
func build(ground_fn: Callable, out_dir: String, mats_dir: String) -> Node3D:
	ground = ground_fn
	out = out_dir
	DirAccess.make_dir_recursive_absolute(out)
	g = load("res://tools/quarry/prop_gen.gd").new()
	for key in ["planks", "beam", "stone", "canvas", "dark"]:
		var path: String = mats_dir + "mat_%s.tres" % key
		if ResourceLoader.exists(path):
			g._mats[key] = load(path)

	root = Node3D.new()
	root.name = "RaidCamp"
	_palisade()
	_gate()
	_ladders()
	_camp()
	_approach()
	_fire()
	return root


func _gy(x: float, z: float) -> float:
	return ground.call(x, z)


## The lowest ground under a footprint `r` round (x, z).
func _low(x: float, z: float, r: float) -> float:
	var lo := _gy(x, z)
	for off: Vector2 in [Vector2(r, 0), Vector2(-r, 0), Vector2(0, r), Vector2(0, -r)]:
		lo = minf(lo, _gy(x + off.x, z + off.y))
	return lo


# ---------------------------------------------------------------- the wall

func _palisade() -> void:
	var wall := _node(Node3D.new(), "Palisade", root)
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
	# Gate and postern posts, each footed where it stands.
	for row in [["GatePosts", -HALF, GATE_HALF, 0.26, 4.8], ["PosternPosts", HALF, POSTERN_HALF, 0.2, 4.0]]:
		var body := _node(StaticBody3D.new(), row[0], wall)
		var base := _gy(0.0, row[1])
		body.position = Vector3(0, base, row[1])
		for s in [-1.0, 1.0]:
			var x: float = s * (row[2] + row[3] - 0.05)
			var foot := _low(x, row[1], row[3]) - base - 0.3
			var h: float = row[4] - foot
			g.cyl("beam", g._xf(Vector3(x, foot + h * 0.5, 0)), row[3], h, 12)
			_box_shape(body, Vector3(x, foot + h * 0.5, 0), Vector3(row[3] * 2, h, row[3] * 2))
		var top: float = row[4] - 0.35
		g.beam("beam", Vector3(-(row[2] + 0.5), top, 0), Vector3(row[2] + 0.5, top, 0), 0.26)
		_mesh_node(body, "Mesh", _save(g.commit(), row[0].to_snake_case()))


## One straight run of logs with the walk along its inside. The node sits on
## the middle of the log line at the camp's floor height, local +z inward,
## local x along the wall. Each log is footed in the ground under it and its
## top follows part of the ground's fall; the walk stays level, standing on
## posts and a front of boards down to the ground.
func _wall_segment(parent: Node3D, seg_name: String, at: Vector3, length: float, inward: Vector3,
		trim_a: float, trim_b: float, seed: int) -> void:
	g.rng.seed = seed
	var body := _node(StaticBody3D.new(), seg_name, parent)
	var along := Vector3.UP.cross(inward)
	body.transform = Transform3D(Basis(along, Vector3.UP, inward), at)
	var ground_at := func(lx: float, lz: float) -> float:
		var p := at + along * lx + inward * lz
		return _gy(p.x, p.z)

	var count := int(round(length / 0.31))
	var lowest := INF
	var low_top := INF
	for i in count:
		var x := -length * 0.5 + (i + 0.5) * length / count
		var r: float = g.rng.randf_range(0.14, 0.17)
		var z: float = g.rng.randf_range(-0.04, 0.04)
		var gy: float = minf(ground_at.call(x, -r), ground_at.call(x, r))
		var top: float = g.rng.randf_range(WALL_TOP - 0.15, WALL_TOP + 0.2) + minf(gy, 0.0) * TOP_FOLLOW
		var bottom := gy - 0.3
		lowest = minf(lowest, bottom)
		low_top = minf(low_top, top)
		g.cyl("beam", g._xf(Vector3(x, (top + bottom) * 0.5, z), g.rng.randf() * TAU, g.rng.randf_range(-0.015, 0.015), g.rng.randf_range(-0.015, 0.015)), r, top - bottom, 7, false)
		_point(Vector3(x, top, z), r, g.rng.randf_range(0.25, 0.4))
	# Rails lashing the logs, outside and in.
	for y in [0.9, 2.9]:
		for s in [-1.0, 1.0]:
			var ya: float = y + minf(ground_at.call(-length * 0.5, s * 0.2), 0.0) * TOP_FOLLOW
			var yb: float = y + minf(ground_at.call(length * 0.5, s * 0.2), 0.0) * TOP_FOLLOW
			g.beam("beam", Vector3(-length * 0.5, ya, s * 0.2), Vector3(length * 0.5, yb, s * 0.2), 0.12)
	_box_shape(body, Vector3(0, (low_top + lowest) * 0.5, 0), Vector3(length, low_top - lowest, LOG_DEPTH))

	var x0 := -length * 0.5 + trim_a
	var x1 := length * 0.5 - trim_b
	var mid := (x0 + x1) * 0.5
	var span := x1 - x0
	var z_mid := LOG_DEPTH * 0.5 + WALK * 0.5
	var z_face := LOG_DEPTH * 0.5 + WALK
	var under := INF
	for i in 9:
		var px := lerpf(x0, x1, i / 8.0)
		under = minf(under, minf(ground_at.call(px, z_face), ground_at.call(px, z_mid)))
	under -= 0.1
	var tall := WALK_TOP - under
	g.box("planks", g._xf(Vector3(mid, WALK_TOP - 0.04, z_mid)), Vector3(span, 0.08, WALK), 2)
	g.box("planks", g._xf(Vector3(mid, under + tall * 0.5, z_face - 0.03)), Vector3(span, tall, 0.06), 1)
	g.box("dark", g._xf(Vector3(mid, under + tall * 0.5, z_mid)), Vector3(span - 0.1, tall - 0.2, WALK - 0.1))
	var posts := maxi(2, int(span / 2.2) + 1)
	for i in posts:
		var px := lerpf(x0 + 0.1, x1 - 0.1, float(i) / (posts - 1))
		var foot: float = ground_at.call(px, z_face + 0.03) - 0.15
		g.box("beam", g._xf(Vector3(px, (WALK_TOP + 0.02 + foot) * 0.5, z_face + 0.03)), Vector3(0.18, WALK_TOP + 0.02 - foot, 0.12), 1)
	g.beam("beam", Vector3(x0, WALK_TOP - 0.12, z_face + 0.07), Vector3(x1, WALK_TOP - 0.12, z_face + 0.07), 0.14)
	_box_shape(body, Vector3(mid, under + tall * 0.5, z_mid), Vector3(span, tall, WALK))
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
## and lying inside, and nothing stops a body; the quarry's script picks which
## is there from a flag.
func _gate() -> void:
	var gate := _node(Node3D.new(), "Gate", root)
	var base := _gy(0.0, -HALF)
	gate.position = Vector3(0, base, -HALF)
	var closed := _node(StaticBody3D.new(), "Closed", gate)
	var leaf_w := GATE_HALF - 0.03
	for s in [-1.0, 1.0]:
		_leaf(g._xf(Vector3(s * leaf_w * 0.5, 1.6, 0)), leaf_w, 3.2, s < 0.0)
		_box_shape(closed, Vector3(s * leaf_w * 0.5, 1.6, 0), Vector3(leaf_w, 3.2, 0.3))
	g.beam("beam", Vector3(-GATE_HALF, 1.4, -0.22), Vector3(GATE_HALF, 1.4, -0.22), 0.2)
	_mesh_node(closed, "Mesh", _save(g.commit(), "gate_closed"))

	var broken := _node(Node3D.new(), "Broken", gate)
	broken.visible = false
	# Lying a couple of metres inside, where the floor is higher than the gap.
	broken.position.y = _gy(0.0, -HALF + 2.0) - base
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

## Two up the north wall either side of the gate, one up the west wall. Each
## stands on the ground at its foot; the top is the walk.
func _ladders() -> void:
	var ladders := _node(Node3D.new(), "Ladders", root)
	var foot := HALF - LOG_DEPTH * 0.5 - WALK - 0.7
	var plan := [
		["NorthWest", Vector2(-6, -foot), PI],
		["NorthEast", Vector2(6, -foot), PI],
		["West", Vector2(-foot, 4), -PI * 0.5],
	]
	for row in plan:
		var p: Vector2 = row[1]
		var y := _gy(p.x, p.y)
		var ladder: Node3D = _instance(LADDER, row[0], ladders)
		ladder.transform = Transform3D(Basis(Vector3.UP, row[2]), Vector3(p.x, y, p.y))
		root.set_editable_instance(ladder, true)
		(ladder.get_node("Top") as Node3D).position = Vector3(0, WALK_TOP - y, 1.25)


# ---------------------------------------------------------------- the camp

func _camp() -> void:
	var camp := _node(Node3D.new(), "Camp", root)
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


## A generated prop filling a box that stands on the lowest ground under it.
func _prop(parent: Node3D, prop_name: String, at: Vector3, size: Vector3, mesh: ArrayMesh) -> StaticBody3D:
	var body := _node(StaticBody3D.new(), prop_name, parent)
	var y := _low(at.x, at.z, minf(size.x, size.z) * 0.5) - 0.04
	body.position = Vector3(at.x, y + size.y * 0.5, at.z)
	_box_shape(body, Vector3.ZERO, size)
	_mesh_node(body, "Mesh", _save(mesh, prop_name.to_snake_case()))
	return body


# ---------------------------------------------------------------- the approach

func _approach() -> void:
	var road := _node(Node3D.new(), "Approach", root)
	_prop(road, "LowWallWest", Vector3(-5.5, 0, -26.0), Vector3(5.0, 1.1, 0.6), g.low_wall(Vector3(5.0, 1.1, 0.6), 240))
	_prop(road, "LowWallEast", Vector3(6.0, 0, -31.5), Vector3(4.0, 1.1, 0.6), g.low_wall(Vector3(4.0, 1.1, 0.6), 241))
	_prop(road, "RoadCart", Vector3(-4.8, 0, -37.5), Vector3(2.0, 1.2, 3.0), g.cart(Vector3(2.0, 1.2, 3.0), 242))
	_rock(road, "RockNear", "rock_07", Vector3(7.5, 0, -21.5), 0.6, 2.4)
	_rock(road, "RockFar", "rock_09", Vector3(-8.5, 0, -44.0), 2.1, 2.8)
	_rock(road, "RockRoad", "rock_07", Vector3(6.0, 0, -46.5), 3.7, 1.9)
	_rock(road, "Stump", "tree_stump_01", Vector3(-3.4, 0, -19.5), 1.2, 1.1)
	_rock(road, "Trunk", "dead_tree_trunk_02", Vector3(10.5, 0, -39.0), 0.3, 6.0)


## A scanned model, turned by `yaw` and scaled so its widest side is `fit`
## metres, sunk into the lowest ground under it, with one box round it.
func _rock(parent: Node3D, rock_name: String, model: String, at: Vector3, yaw: float, fit: float) -> void:
	var scene: Node3D = (load(M + model + ".glb") as PackedScene).instantiate()
	var box := _aabb(scene, Transform3D.IDENTITY)
	scene.free()
	var scale := fit / maxf(box.size.x, box.size.z)
	var body := _node(StaticBody3D.new(), rock_name, parent)
	var y := _low(at.x, at.z, fit * 0.5)
	body.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(at.x, y, at.z))
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
	var fire := _node(Node3D.new(), "Campfire", root)
	fire.position = Vector3(0, _gy(0.0, -1.0), -1.0)
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
	var path := out + "flame_dot.tres"
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


# ---------------------------------------------------------------- dusk

## The quarry's environment at dusk, for the raid: a warm low sky, thicker
## fog. Saved next to `day_path`; the sun for it is DUSK_SUN.
const DUSK_SUN := {color = Color(1.0, 0.64, 0.4), energy = 1.7, fog = 1.6, travel = Vector3(0.88, -0.2, 0.42)}


func save_dusk(day_path: String, dusk_path: String) -> void:
	var env: Environment = load(day_path).duplicate(true)
	var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
	sky_mat.sky_top_color = Color(0.16, 0.2, 0.36)
	sky_mat.sky_horizon_color = Color(0.92, 0.56, 0.36)
	sky_mat.ground_horizon_color = Color(0.34, 0.25, 0.2)
	sky_mat.ground_bottom_color = Color(0.08, 0.07, 0.06)
	sky_mat.sun_angle_max = 12.0
	env.ambient_light_energy = 0.5
	env.volumetric_fog_density = 0.011
	env.volumetric_fog_albedo = Color(1.0, 0.78, 0.6)
	ResourceSaver.save(env, dusk_path)


# ---------------------------------------------------------------- helpers

func _node(node: Node, node_name: String, parent: Node) -> Node:
	node.name = node_name
	parent.add_child(node)
	if node != root:
		node.owner = root
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
	var path := out + "%s.res" % file
	ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
	return load(path)

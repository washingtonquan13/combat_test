class_name MorrowTerrain
extends Node3D
## The Morrow overworld's ground, built on load from the heights stage 1
## wrote (tools/blockout/morrow_terrain.py): a grid of mesh tiles drawn with
## `material`, one heightmap collision shape, and the river's and the
## lake's water. The water is drawn with the quarry's water shader, which
## reads the flow from vertex colours: rg the direction (0.5 still), b the
## speed over its flow_max.
##
## Built at run time, not baked into the scene, so the scene stays text and
## the heights stay one small file. Each grid cell is two triangles split
## from (ix+1, iz) to (ix, iz+1), the way the generator's sampler reads them,
## so whatever it stood on the ground stands on this.
##
## Must stay under the overworld's Ground node: encounters spawn only on
## ground under it (overworld_encounters.gd `_spawn_spot`).

const DIR := "res://world/morrow/"
const TILE := 64   # cells a side per mesh tile

@export var material: Material
@export var water_material: Material
## Half-width of the river's water ribbon, metres.
@export var river_half_width := 7.0
## The river's flow speed as a fraction of the water shader's flow_max.
@export var river_flow := 0.6


func _ready() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIR + "terrain.json"))
	var n: int = meta.n
	var cell: float = meta.cell
	var x0: float = meta.x0
	var heights := FileAccess.get_file_as_bytes(DIR + "terrain_height.bin").to_float32_array()
	var normals := FileAccess.get_file_as_bytes(DIR + "terrain_normal.bin").to_float32_array()
	if heights.size() != n * n or normals.size() != n * n * 3:
		push_error("MorrowTerrain: the height files don't match terrain.json; run morrow_terrain.py")
		return
	_build_tiles(heights, normals, n, cell, x0)
	_build_collision(heights, n, cell, x0)
	_build_river(meta.river)
	if meta.has("lake"):
		_build_lake(meta.lake)


func _build_tiles(heights: PackedFloat32Array, normals: PackedFloat32Array, n: int, cell: float, x0: float) -> void:
	var side := TILE + 1
	var indices := PackedInt32Array()
	indices.resize(TILE * TILE * 6)
	var k := 0
	for j in TILE:
		for i in TILE:
			var a := j * side + i
			# (a, b, c) and (b, d, c): clockwise from above.
			indices[k] = a
			indices[k + 1] = a + 1
			indices[k + 2] = a + side
			indices[k + 3] = a + 1
			indices[k + 4] = a + side + 1
			indices[k + 5] = a + side
			k += 6
	var tiles := (n - 1) / TILE
	for tj in tiles:
		for ti in tiles:
			var verts := PackedVector3Array()
			var norms := PackedVector3Array()
			verts.resize(side * side)
			norms.resize(side * side)
			var v := 0
			for j in side:
				var row := (tj * TILE + j) * n + ti * TILE
				var z := x0 + (tj * TILE + j) * cell
				for i in side:
					var g := row + i
					verts[v] = Vector3(x0 + (ti * TILE + i) * cell, heights[g], z)
					norms[v] = Vector3(normals[g * 3], normals[g * 3 + 1], normals[g * 3 + 2])
					v += 1
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = verts
			arrays[Mesh.ARRAY_NORMAL] = norms
			arrays[Mesh.ARRAY_INDEX] = indices
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(0, material)
			var tile := MeshInstance3D.new()
			tile.name = "Tile%d_%d" % [ti, tj]
			tile.mesh = mesh
			add_child(tile)


func _build_collision(heights: PackedFloat32Array, n: int, cell: float, x0: float) -> void:
	# A heightmap shape is one unit a sample and centred on its node; scaled
	# by the cell size, so the heights go in divided by it.
	var data := heights.duplicate()
	for g in data.size():
		data[g] /= cell
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = data
	var body := StaticBody3D.new()
	body.name = "Collision"
	var col := CollisionShape3D.new()
	col.shape = shape
	var centre := x0 + (n - 1) * cell * 0.5
	col.transform = Transform3D(Basis.from_scale(Vector3.ONE * cell), Vector3(centre, 0.0, centre))
	body.add_child(col)
	add_child(body)


func _build_river(samples: Array) -> void:
	if samples.size() < 2:
		return
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	for s in samples.size():
		var p := Vector3(samples[s][0], samples[s][2], samples[s][1])
		var prev := Vector3(samples[maxi(s - 1, 0)][0], 0.0, samples[maxi(s - 1, 0)][1])
		var next := Vector3(samples[mini(s + 1, samples.size() - 1)][0], 0.0, samples[mini(s + 1, samples.size() - 1)][1])
		var across := (next - prev).normalized().cross(Vector3.UP) * river_half_width
		verts.append(p - across)
		verts.append(p + across)
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		# Downstream is the samples' order.
		var dir := (next - prev).normalized()
		var flow := Color(dir.x * 0.5 + 0.5, dir.z * 0.5 + 0.5, river_flow)
		colours.append(flow)
		colours.append(flow)
		if s > 0:
			var a := (s - 1) * 2
			# Wound to face up (clockwise from above).
			indices.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	_add_water("River", verts, norms, colours, indices)


## The lake: a still disc at its water level, its rim under the bowl's banks.
func _build_lake(lake: Dictionary) -> void:
	const SIDES := 64
	var centre := Vector3(lake.x, lake.water, lake.z)
	var radius: float = lake.radius
	var verts := PackedVector3Array([centre])
	var norms := PackedVector3Array([Vector3.UP])
	var colours := PackedColorArray([Color(0.5, 0.5, 0.0)])
	var indices := PackedInt32Array()
	for k in SIDES:
		var a := TAU * k / SIDES
		verts.append(centre + Vector3(cos(a), 0.0, sin(a)) * radius)
		norms.append(Vector3.UP)
		colours.append(Color(0.5, 0.5, 0.0))
		# Angle rises from +x towards +z: clockwise seen from above.
		indices.append_array([0, 1 + k, 1 + (k + 1) % SIDES])
	_add_water("Lake", verts, norms, colours, indices)


func _add_water(node_name: String, verts: PackedVector3Array, norms: PackedVector3Array, colours: PackedColorArray,
		indices: PackedInt32Array) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, water_material)
	var water := MeshInstance3D.new()
	water.name = node_name
	water.mesh = mesh
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)

class_name MorrowForest
extends Node3D
## The Morrow overworld's trees: the goblin quarry's generated firs and
## broadleaves (tools/quarry/bake_goblin_quarry.gd wrote the meshes), placed
## where tools/blockout/morrow_overworld.py put the grey-box trees. Built on
## load, so the scene stays text.
##
## The overworld camera never comes nearer than ~70 m, so every tree draws
## the quarry's coarse ("far") mesh, which also casts its shadow; the quarry's
## full meshes are three times the triangles for nothing seen from here.
## Trees are batched into CELL-metre squares, one MultiMesh per mesh per
## cell, so frustum culling and the visibility range drop whole cells.
## Collision stays the scene's Wilds/TreeTrunks cylinders.
##
## A woods tree with no other tree within ALONE metres grew up in the open,
## so it is drawn as a hero oak instead (docs/plans/bg3_foliage_study.md,
## change 8): about sixty landmarks across the map.

const MESHES := "res://world/goblin_quarry/meshes/"
const CELL := 64.0
## Cells further than this from the camera aren't drawn (faded out).
const RANGE_END := 520.0

## Five floats a tree: x, y (ground), z, scale (the grey box's 0.6–1.4),
## kind (0 woods, 1 park).
@export var trees := PackedFloat32Array()

# [mesh name, size per grey-box scale] for each kind.
const WOODS := [["gen_fir_0_far", 1.1], ["gen_fir_1_far", 1.1], ["gen_fir_2_far", 1.1],
		["gen_fir_3_far", 1.1], ["gen_firm_0_far", 1.9], ["gen_firm_1_far", 1.9], ["gen_firm_2_far", 1.9]]
const PARK := [["gen_isle_0_far", 2.0], ["gen_isle_1_far", 2.0], ["gen_isle_2_far", 2.0], ["gen_isle_3_far", 2.0]]
## The oaks are 22 m at size 1.
const OAK := [["gen_oak_0_far", 0.8], ["gen_oak_1_far", 0.8]]
const ALONE := 34.0


func _ready() -> void:
	var kinds := [WOODS, PARK]
	var lone := _lone_trees()
	var meshes := {}
	# cell key -> mesh name -> transforms
	var cells := {}
	for i in range(0, trees.size(), 5):
		var at := Vector3(trees[i], trees[i + 1], trees[i + 2])
		var s := trees[i + 3]
		var list: Array = OAK if lone.has(i) else kinds[int(trees[i + 4])]
		# A steady pick, yaw and size jitter from the position.
		var h := hash(Vector2i(roundi(at.x * 10.0), roundi(at.z * 10.0)))
		var pick: Array = list[h % list.size()]
		var yaw := float((h >> 8) % 6283) * 0.001
		var size: float = pick[1] * s
		var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * size), at - Vector3.UP * 0.1)
		var key := Vector2i(floori(at.x / CELL), floori(at.z / CELL))
		if not cells.has(key):
			cells[key] = {}
		var by_mesh: Dictionary = cells[key]
		if not by_mesh.has(pick[0]):
			by_mesh[pick[0]] = []
			if not meshes.has(pick[0]):
				meshes[pick[0]] = load(MESHES + pick[0] + ".res")
		by_mesh[pick[0]].append(xf)
	for key: Vector2i in cells:
		for mesh_name: String in cells[key]:
			var batch: Array = cells[key][mesh_name]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = meshes[mesh_name]
			mm.instance_count = batch.size()
			for k in batch.size():
				mm.set_instance_transform(k, batch[k])
			var inst := MultiMeshInstance3D.new()
			inst.name = "%s_%d_%d" % [mesh_name, key.x, key.y]
			inst.multimesh = mm
			inst.visibility_range_end = RANGE_END
			inst.visibility_range_end_margin = 40.0
			inst.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			add_child(inst)


func _lone_trees() -> Dictionary:
	# Woods trees (by their index in `trees`) with no other tree within ALONE
	# metres, found through a grid of ALONE-metre squares.
	var grid := {}
	for i in range(0, trees.size(), 5):
		var key := Vector2i(floori(trees[i] / ALONE), floori(trees[i + 2] / ALONE))
		if not grid.has(key):
			grid[key] = []
		grid[key].append(i)
	var lone := {}
	for i in range(0, trees.size(), 5):
		if int(trees[i + 4]) != 0:
			continue
		var at := Vector2(trees[i], trees[i + 2])
		var key := Vector2i(floori(at.x / ALONE), floori(at.y / ALONE))
		var alone := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				for j: int in grid.get(key + Vector2i(dx, dz), []):
					if j != i and at.distance_to(Vector2(trees[j], trees[j + 2])) < ALONE:
						alone = false
		if alone:
			lone[i] = true
	return lone

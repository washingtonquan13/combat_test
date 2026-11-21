extends SceneTree

# Remakes the generated plants and their leaf atlases in
# world/goblin_quarry/meshes/ in place, without a rebake of the quarry: the
# firs, broadleaves, bushes and ferns, from the same seeds, heights and detail
# levels as bake_goblin_quarry.gd, and the four leaf atlases from their PNGs.
# terrain.scn and morrow_forest.gd point at these files, so they pick the new
# ones up. Placement, collision and the vines' geometry stay as baked.
#
#   godot --headless --path . -s tools/quarry/regen_plants.gd

const OUT := "res://world/goblin_quarry/meshes/"
const F := "res://assets/level/forest/"
const FOLIAGE := "res://assets/level/quarry/foliage/"
const BAKE := preload("res://tools/quarry/bake_goblin_quarry.gd")

var gen = preload("res://tools/quarry/plant_gen.gd").new()


func _initialize() -> void:
	var fir_tex := F + "models/fir_tree_01_fir_tree_01_"
	var fir_leaf: Material = gen.leaf_material(_atlas(fir_tex + "twig_cards_diff_2k.png", "fir_cards"))
	var fir_bark: Material = gen.bark_material(load(fir_tex + "bark_diff_2k.jpg"), load(fir_tex + "bark_nor_gl_2k.jpg"))
	var isle_tex := F + "models/island_tree_01_island_tree_01_"
	var broad_leaf: Material = gen.leaf_material(_atlas(FOLIAGE + "broadleaf_cards.png", "broadleaf_cards"), _surface(FOLIAGE + "broadleaf_cards_surface.png", "broadleaf_cards_surface"))
	var broad_bark: Material = gen.bark_material(load(isle_tex + "diff_2k.jpg"), load(isle_tex + "nor_gl_2k.jpg"))
	var fern_leaf: Material = gen.leaf_material(_atlas(FOLIAGE + "fern_fronds.png", "fern_fronds"))
	_atlas(FOLIAGE + "vine_runs.png", "vine_runs")

	var seed := 7100
	for kind: String in BAKE.FIR_GEN:
		for v in int(BAKE.FIR_GEN[kind][1]):
			for lod in 2:
				_save(gen.mesh(gen.fir(seed, BAKE.FIR_GEN[kind][0], 1.0 if lod == 0 else 0.4), fir_bark, fir_leaf), kind, v, lod)
			seed += 1
	seed = 7200
	for kind: String in BAKE.BROAD_GEN:
		for v in int(BAKE.BROAD_GEN[kind][1]):
			for lod in 2:
				_save(gen.mesh(gen.broadleaf(seed, BAKE.BROAD_GEN[kind][0], 1.0 if lod == 0 else 0.4), broad_bark, broad_leaf), kind, v, lod)
			seed += 1
	for v in int(BAKE.BUSH_GEN[1]):
		for lod in 2:
			_save(gen.mesh(gen.bush(7300 + v, BAKE.BUSH_GEN[0], 1.0 if lod == 0 else 0.4), broad_bark, broad_leaf), "bush", v, lod)
	for v in int(BAKE.FERN_GEN[1]):
		for lod in 2:
			_save(gen.mesh(gen.fern(7400 + v, BAKE.FERN_GEN[0], 1.0 if lod == 0 else 0.5), null, fern_leaf), "fern", v, lod)
	quit()


func _atlas(png: String, name: String) -> Texture2D:
	var path := OUT + name + ".res"
	var atlas: Texture2D = gen.coverage_texture(png)
	atlas.take_over_path(path)
	var err := ResourceSaver.save(atlas, path, ResourceSaver.FLAG_COMPRESS)
	print("%s: err %d" % [name, err])
	return atlas


func _surface(png: String, name: String) -> Texture2D:
	var path := OUT + name + ".res"
	var tex: Texture2D = gen.surface_texture(png)
	tex.take_over_path(path)
	var err := ResourceSaver.save(tex, path, ResourceSaver.FLAG_COMPRESS)
	print("%s: err %d" % [name, err])
	return tex


func _save(m: ArrayMesh, kind: String, v: int, lod: int) -> void:
	var path := OUT + "gen_%s_%d_%s.res" % [kind, v, "near" if lod == 0 else "far"]
	m.take_over_path(path)
	var err := ResourceSaver.save(m, path, ResourceSaver.FLAG_COMPRESS)
	var tris := 0
	for s in m.get_surface_count():
		tris += m.surface_get_array_index_len(s) / 3
	print("%s: err %d, %d tris" % [path.get_file(), err, tris])

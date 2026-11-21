extends SceneTree

# Gives the generated plants already baked into world/goblin_quarry/meshes/
# (trees, bushes, ferns) Godot's LODs, in place, without a rebake. New bakes
# get them from plant_gen.gd's mesh(). Safe to run again: LODs are always
# made from the full mesh.
#
#   godot --headless --path . -s tools/quarry/add_plant_lods.gd

const DIR := "res://world/goblin_quarry/meshes/"
const GEN := preload("res://tools/quarry/plant_gen.gd")


func _initialize() -> void:
	for file in DirAccess.get_files_at(DIR):
		if not (file.begins_with("gen_") and file.ends_with(".res")):
			continue
		var path := DIR + file
		var old: ArrayMesh = load(path)
		var im: ImporterMesh = GEN.lod_importer(old)
		var m: ArrayMesh = im.get_mesh()
		m.resource_name = old.resource_name
		m.take_over_path(path)
		var err := ResourceSaver.save(m, path, ResourceSaver.FLAG_COMPRESS)
		var lods := []
		for s in im.get_surface_count():
			var levels := [m.surface_get_array_index_len(s) / 3]
			for l in im.get_surface_lod_count(s):
				levels.append(im.get_surface_lod_indices(s, l).size() / 3)
			lods.append(levels)
		print("%s: err %d, triangles per LOD %s" % [file, err, lods])
	quit()

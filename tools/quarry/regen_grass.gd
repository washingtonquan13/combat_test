extends "res://tools/quarry/bake_goblin_quarry.gd"

# Remakes only the quarry's grass, without a rebake: world/goblin_quarry/grass.scn
# and the two grass atlases in world/goblin_quarry/meshes/ (grass_tufts.res,
# meadow_plants.res). It runs the bake's own grass code (_save_grass) on the
# bake's own ground shape, tree plan and walk-in house, so placement is the
# bake's, clump for clump. terrain.scn instances grass.scn and picks the new
# one up. Terrain, collision, navigation, props and plants stay as baked.
#
#   godot --path . -s tools/quarry/regen_grass.gd
#
# Run it windowed: headless Godot saves every MultiMesh transform as zero.


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Run regen_grass.gd windowed: headless Godot saves every MultiMesh transform as zero.")
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	_shape()
	_plan_trees()
	_walk_in_house(load("res://tools/quarry/prop_gen.gd").new())
	_save_grass()
	print("regen_grass in %d ms" % (Time.get_ticks_msec() - t0))
	quit()

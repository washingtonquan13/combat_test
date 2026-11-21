extends SceneTree

# Applies the bake's low-shadow rule (bake_goblin_quarry.gd, casts_no_shadow)
# to a terrain.scn already baked, without a rebake: low stones and branches
# move out of their shadow-casting batches into shadowless ones, which fade at
# 60 m as the bake's shadowless batches do. Running it twice changes nothing.
#
#   godot --path . -s tools/quarry/drop_low_shadows.gd
#
# Run it windowed: headless Godot saves every MultiMesh transform as zero.

const BAKE := preload("res://tools/quarry/bake_goblin_quarry.gd")
const TERRAIN := "res://world/goblin_quarry/terrain.scn"


func _initialize() -> void:
	var root: Node = (load(TERRAIN) as PackedScene).instantiate()
	var moved := 0
	var batches := 0
	for inst: MultiMeshInstance3D in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mm := inst.multimesh
		if inst.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON or mm == null or mm.mesh == null:
			continue
		var keep: Array[Transform3D] = []
		var low: Array[Transform3D] = []
		for i in mm.instance_count:
			var xf := mm.get_instance_transform(i)
			(low if BAKE.casts_no_shadow(mm.mesh, xf) else keep).append(xf)
		if low.is_empty():
			continue
		moved += low.size()
		batches += 1
		# A rebake puts them in the same batch as the pebbles of that mesh and
		# cell that were already shadowless: join it if it exists.
		var ns_name := str(inst.name) + "_ns"
		var target := inst.get_parent().get_node_or_null(ns_name) as MultiMeshInstance3D
		if target:
			var have: Array[Transform3D] = []
			for i in target.multimesh.instance_count:
				have.append(target.multimesh.get_instance_transform(i))
			low = have + low
		elif keep.is_empty():
			target = inst
		else:
			target = MultiMeshInstance3D.new()
			target.multimesh = MultiMesh.new()
			target.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			target.multimesh.mesh = mm.mesh
			target.layers = inst.layers
			target.visibility_range_end = 60.0
			target.visibility_range_end_margin = 4.0
			target.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			inst.add_sibling(target)
			target.owner = root
		if target == inst:
			inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if inst.visibility_range_end <= 0.0:
				inst.visibility_range_end = 60.0
				inst.visibility_range_end_margin = 4.0
				inst.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		_fill(target.multimesh, low)
		target.name = ns_name
		if keep.is_empty() and target != inst:
			inst.get_parent().remove_child(inst)
			inst.free()
		elif not keep.is_empty():
			_fill(mm, keep)
	print("low shadows: %d pieces out of %d batches" % [moved, batches])
	if moved > 0:
		var packed := PackedScene.new()
		packed.pack(root)
		var err := ResourceSaver.save(packed, TERRAIN, ResourceSaver.FLAG_COMPRESS)
		print("saved ", TERRAIN, " err ", err)
	root.free()
	quit()


func _fill(mm: MultiMesh, xfs: Array[Transform3D]) -> void:
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])

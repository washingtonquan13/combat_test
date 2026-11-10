extends SceneTree

# Bakes the spider cave's rock: runs tools/cave/cave_volume.py to build the
# surface from its distance field, then writes world/spider_cave/rock.scn,
# the drawn mesh and its collision. The collision is the same triangles as
# the mesh, one-sided, so the nav grid reads floor, walls and roof exactly
# and a ray from the camera above the roof passes through it.
#
#   godot --path . -s tools/cave/bake_spider_cave.gd

const OUT := "res://world/spider_cave/"
const T := "res://assets/level/quarry/textures/"
const F := "res://assets/level/forest/textures/"


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var dir := OS.get_user_data_dir().path_join("cave_bake")
	var out: Array = []
	var code := OS.execute("python", ["-I", ProjectSettings.globalize_path("res://tools/cave/cave_volume.py"), dir], out, true)
	print("".join(out))
	if code != 0:
		push_error("cave_volume.py failed: %d" % code)
		quit(1)
		return
	var verts := FileAccess.get_file_as_bytes(dir.path_join("verts.bin")).to_float32_array()
	var normals := FileAccess.get_file_as_bytes(dir.path_join("normals.bin")).to_float32_array()
	var ao := FileAccess.get_file_as_bytes(dir.path_join("ao.bin")).to_float32_array()
	var index := FileAccess.get_file_as_bytes(dir.path_join("index.bin")).to_int32_array()
	var n := ao.size()
	var v := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	v.resize(n)
	nrm.resize(n)
	col.resize(n)
	for i in n:
		v[i] = Vector3(verts[i * 3], verts[i * 3 + 1], verts[i * 3 + 2])
		nrm[i] = Vector3(normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2])
		col[i] = Color(ao[i], ao[i], ao[i])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = index
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material())

	var root := Node3D.new()
	root.name = "CaveRock"
	var mi := MeshInstance3D.new()
	mi.name = "Rock"
	mi.mesh = mesh
	# The light down the skylight shaft falls on the roof's outside; its
	# back faces have to block it.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	root.add_child(mi)

	var faces := PackedVector3Array()
	faces.resize(index.size())
	for i in index.size():
		faces[i] = v[index[i]]
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = "RockBody"
	var cs := CollisionShape3D.new()
	cs.name = "Collision"
	cs.shape = shape
	body.add_child(cs)
	root.add_child(body)

	for child in root.get_children():
		child.owner = root
		for c in child.get_children():
			c.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, OUT + "rock.scn", ResourceSaver.FLAG_COMPRESS)
	print("rock.scn: err %d, %d verts, %d triangles, %d ms" % [err, n, index.size() / 3, Time.get_ticks_msec() - t0])
	root.free()
	quit(0 if err == OK else 1)


func _material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(OUT + "cave_rock.gdshader")
	for layer: Array in [["rock", T + "rock_face_03"], ["floor", T + "dirt_floor"], ["stones", F + "river_small_rocks"]]:
		mat.set_shader_parameter(layer[0] + "_albedo", load(layer[1] + "_diff_2k.jpg"))
		mat.set_shader_parameter(layer[0] + "_normal", load(layer[1] + "_nor_gl_2k.jpg"))
		mat.set_shader_parameter(layer[0] + "_arm", load(layer[1] + "_arm_2k.jpg"))
	return mat

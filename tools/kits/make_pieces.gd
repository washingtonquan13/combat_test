extends SceneTree
## Wraps each mesh of a kit's source glTF in its own piece scene,
## <out>/<name>.tscn: a StaticBody3D with the mesh and a trimesh collision.
## The glTF is Blender's re-export of a sourced kit, already cut and pivoted
## (see the kit folder's LICENSE.txt for the source and what was changed).
##   godot --headless --path . --script res://tools/kits/make_pieces.gd -- <src.gltf> <out dir> [scale] [materials dir]
## [scale] is baked into the vertices (tenement_kit: 1.25, its 2 m bays are 2.5 m).
## [materials dir]: a surface whose material is named X takes <dir>/X.tres
## instead, if it exists (medieval_kit: Poly Haven re-textures of the kit's
## stylized materials).
## Kits built with it: assets/level/ruins_kit, assets/level/tenement_kit,
## assets/level/medieval_kit.


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var src: String = args[0]
	var out: String = args[1].trim_suffix("/") + "/"
	var k := float(args[2]) if args.size() > 2 else 1.0
	var mats: String = args[3].trim_suffix("/") + "/" if args.size() > 3 else ""
	var kit: Node = (load(src) as PackedScene).instantiate()
	for mi: MeshInstance3D in kit.find_children("*", "MeshInstance3D", true, false):
		var name := String(mi.name)
		if mats != "":
			_override(mi.mesh, mats)
		ResourceSaver.save(_scaled(mi.mesh, k), out + name + ".mesh")
		var mesh: Mesh = load(out + name + ".mesh")
		var body := StaticBody3D.new()
		body.name = name.to_pascal_case()
		var m := MeshInstance3D.new()
		m.name = "Mesh"
		m.mesh = mesh
		body.add_child(m)
		m.owner = body
		ResourceSaver.save(mesh.create_trimesh_shape(), out + name + "_shape.res")
		var cs := CollisionShape3D.new()
		cs.name = "Collision"
		cs.shape = load(out + name + "_shape.res")
		body.add_child(cs)
		cs.owner = body
		var ps := PackedScene.new()
		ps.pack(body)
		ResourceSaver.save(ps, out + name + ".tscn")
		print("piece ", name, " ", mesh.get_aabb().size)
	kit.free()
	quit()


func _override(mesh: Mesh, dir: String) -> void:
	for i in mesh.get_surface_count():
		var cur := mesh.surface_get_material(i)
		var path := dir + (cur.resource_name if cur else "") + ".tres"
		if cur and ResourceLoader.exists(path):
			mesh.surface_set_material(i, load(path))


func _scaled(src: Mesh, k: float) -> Mesh:
	if is_equal_approx(k, 1.0):
		return src
	var dst := ArrayMesh.new()
	for i in src.get_surface_count():
		var arrays := src.surface_get_arrays(i)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for j in v.size():
			v[j] *= k
		arrays[Mesh.ARRAY_VERTEX] = v
		dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		dst.surface_set_material(i, src.surface_get_material(i))
		dst.surface_set_name(i, src.surface_get_name(i))
	return dst

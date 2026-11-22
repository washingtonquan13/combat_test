class_name CCWear
## Puts a fitted garment on a Character Creator body: CCLook.wear()'s
## binding. A garment is a .glb exported by tools/armor_fit/ from the CC
## base in Blender: its meshes skinned to CC's own bones (CC_Base_*), in the
## space the base had in Blender. The body in game is the base's FBX with
## the import's BoneMap renaming the humanoid bones (CC_Base_Hip -> Hips).
##
## Each garment mesh is rebound to the body's skeleton: its binds renamed
## through the BoneMap, and its mesh space carried onto the body mesh's by
## the scale + rotation + offset that best lays the garment's bone origins
## on the body's (the two exports agree on the bones up to that transform).

## FBX path -> {profile name: CC name}, read from its .import.
static var _maps := {}


## garment's meshes bound to `character`'s skeleton, beside its body mesh,
## drawn on the body's render layers. Empty if the character has no CC body.
static func attach(character: Node3D, garment: PackedScene) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var body := CCMaterials._body(character)
	if body == null or body.skin == null:
		return out
	var bs := body.get_node(body.skeleton) as Skeleton3D
	var rename := _bone_map(character)
	var unrename := {}
	for k: String in rename:
		unrename[rename[k]] = k
	# The body's binds under CC names, in the body mesh's space.
	var body_bind := {}
	for b in body.skin.get_bind_count():
		var bn := String(body.skin.get_bind_name(b))
		if bn == "":
			bn = bs.get_bone_name(body.skin.get_bind_bone(b))
		body_bind[rename.get(bn, bn)] = body.skin.get_bind_pose(b)
	var src := garment.instantiate()
	for g: MeshInstance3D in src.find_children("*", "MeshInstance3D", true, false):
		if g.skin == null:
			continue
		# Garment mesh space -> body mesh space, fitted on the bones both
		# bind (a bind's inverse is the bone in its mesh's space).
		var from := PackedVector3Array()
		var to := PackedVector3Array()
		for b in g.skin.get_bind_count():
			var name := String(g.skin.get_bind_name(b))
			if body_bind.has(name):
				from.append(g.skin.get_bind_pose(b).affine_inverse().origin)
				to.append((body_bind[name] as Transform3D).affine_inverse().origin)
		if from.size() < 3:
			push_warning("CCWear: %s shares too few bones with the body." % g.name)
			continue
		var m := similarity(from, to)
		var skin := Skin.new()
		for b in g.skin.get_bind_count():
			var name := String(g.skin.get_bind_name(b))
			if body_bind.has(name):
				skin.add_named_bind(unrename.get(name, name), (body_bind[name] as Transform3D) * m)
				continue
			# A bone the body mesh does not bind: body mesh space reaches it
			# through a bone the body does bind.
			var bb := bs.find_bone(unrename.get(name, name))
			if bb < 0 or not body_bind.has("CC_Base_Waist"):
				skin.add_named_bind(bs.get_bone_name(0), g.skin.get_bind_pose(b))
				continue
			var spine := bs.get_bone_global_rest(bs.find_bone(unrename.get("CC_Base_Waist", "CC_Base_Waist"))) \
					* (body_bind["CC_Base_Waist"] as Transform3D)
			skin.add_named_bind(bs.get_bone_name(bb), bs.get_bone_global_rest(bb).affine_inverse() * spine * m)
		var mi := MeshInstance3D.new()
		mi.name = g.name
		mi.mesh = g.mesh
		mi.skin = skin
		mi.layers = body.layers
		mi.set(&"light_group", body.get(&"light_group"))
		body.get_parent().add_child(mi)
		mi.transform = body.transform
		mi.skeleton = mi.get_path_to(bs)
		out.append(mi)
	src.free()
	return out


## The import BoneMap of the FBX the character's body was instanced from:
## humanoid profile name -> CC bone name.
static func _bone_map(character: Node) -> Dictionary:
	var body := character.get_node_or_null("Body")
	var fbx := body.scene_file_path if body else ""
	if _maps.has(fbx):
		return _maps[fbx]
	var map := {}
	var text := FileAccess.get_file_as_string(fbx + ".import") if fbx != "" else ""
	var re := RegEx.create_from_string("\"bone_map/(\\w+)\":&\"(\\w+)\"")
	for mt in re.search_all(text):
		map[mt.get_string(1)] = mt.get_string(2)
	if map.is_empty():
		push_warning("CCWear: no BoneMap for %s; garments bind by CC names." % fbx)
	_maps[fbx] = map
	return map


## The scale * rotation + offset that best takes a onto b (Umeyama; the
## rotation is the polar factor of the cross-covariance, by Newton steps).
static func similarity(a: PackedVector3Array, b: PackedVector3Array) -> Transform3D:
	var ca := Vector3.ZERO
	var cb := Vector3.ZERO
	for i in a.size():
		ca += a[i]
		cb += b[i]
	ca /= a.size()
	cb /= b.size()
	var h := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	var va := 0.0
	var vb := 0.0
	for i in a.size():
		var p := a[i] - ca
		var q := b[i] - cb
		va += p.length_squared()
		vb += q.length_squared()
		h.x += q * p.x
		h.y += q * p.y
		h.z += q * p.z
	var r := h
	for k in 60:
		var it := r.inverse().transposed()
		r = Basis((r.x + it.x) * 0.5, (r.y + it.y) * 0.5, (r.z + it.z) * 0.5)
	var basis := r * sqrt(vb / va)
	return Transform3D(basis, cb - basis * ca)

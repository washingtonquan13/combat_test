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

## Cloth bones a garment brings: chains Spring_<chain>_<joint>, each hanging
## from a body bone (D:/ai_motion/garment_tpl/scripts/cloth_bones.py rigs a
## skirt with them). attach() adds them to the body's skeleton and swings
## them with a SpringBoneSimulator3D, pushed off the legs by capsules.
const SPRING_PREFIX := "Spring_"
## Joint radius (m): how far a chain keeps off the leg capsules.
const SPRING_RADIUS := 0.04
const SPRING_STIFFNESS := 4.0
const SPRING_DRAG := 0.5
const SPRING_GRAVITY := 0.5
## Leg capsules: CC bone -> the CC bone it runs to, and its radius (m): the
## leg as worn under a skirt, not the bare leg. Measured on the robe's own
## trousers (90% of verts within 0.113 of the thigh) and knee boots (the
## cuff reaches 0.12 off the calf); thinner, the idle stance pokes the boot
## through the hem.
const LEG_CAPSULES := [
	["CC_Base_L_Thigh", "CC_Base_L_Calf", 0.115], ["CC_Base_R_Thigh", "CC_Base_R_Calf", 0.115],
	["CC_Base_L_Calf", "CC_Base_L_Foot", 0.11], ["CC_Base_R_Calf", "CC_Base_R_Foot", 0.11],
]


## garment's meshes bound to `character`'s skeleton, beside its body mesh,
## drawn on the body's render layers, and the spring simulator swinging its
## cloth bones if it has any. Empty if the character has no CC body.
static func attach(character: Node3D, garment: PackedScene) -> Array[Node3D]:
	var out: Array[Node3D] = []
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
	var springs := PackedStringArray()
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
		for name in _add_springs(bs, g, m, body_bind, unrename):
			if not springs.has(name):
				springs.append(name)
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
			skin.add_named_bind(bs.get_bone_name(bb),
					global_rest(bs, bb).affine_inverse() * _mesh_to_skeleton(bs, body_bind, unrename) * m)
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
	if not springs.is_empty():
		out.append(_spring_sim(bs, springs, unrename))
	return out


## Body mesh space -> skeleton space, through the waist (a bone every body
## binds). Identity if the body has no waist bind.
static func _mesh_to_skeleton(bs: Skeleton3D, body_bind: Dictionary, unrename: Dictionary) -> Transform3D:
	var waist := bs.find_bone(unrename.get("CC_Base_Waist", "CC_Base_Waist"))
	if waist < 0 or not body_bind.has("CC_Base_Waist"):
		return Transform3D.IDENTITY
	return global_rest(bs, waist) * (body_bind["CC_Base_Waist"] as Transform3D)


## Adds the garment mesh g's cloth bones the skeleton lacks, at the rest its
## binds give them (carried by m into body mesh space), under their parents
## in the garment's armature. A bone's Y runs down its chain, as in Blender.
## Returns the names of every cloth bone g binds.
static func _add_springs(bs: Skeleton3D, g: MeshInstance3D, m: Transform3D,
		body_bind: Dictionary, unrename: Dictionary) -> PackedStringArray:
	var names := PackedStringArray()
	var bind := {}
	for b in g.skin.get_bind_count():
		var name := String(g.skin.get_bind_name(b))
		if name.begins_with(SPRING_PREFIX):
			names.append(name)
			bind[name] = g.skin.get_bind_pose(b)
	if names.is_empty():
		return names
	var gs := g.get_node_or_null(g.skeleton) as Skeleton3D
	if gs == null:
		push_warning("CCWear: %s has cloth bones but no skeleton." % g.name)
		return PackedStringArray()
	var to_skel := _mesh_to_skeleton(bs, body_bind, unrename)
	# The garment skeleton lists parents before children.
	for gb in gs.get_bone_count():
		var name := gs.get_bone_name(gb)
		if not bind.has(name) or bs.find_bone(name) >= 0:
			continue
		var pname := gs.get_bone_name(gs.get_bone_parent(gb)) if gs.get_bone_parent(gb) >= 0 else ""
		var parent := bs.find_bone(unrename.get(pname, pname))
		if parent < 0:
			push_warning("CCWear: no parent %s for cloth bone %s." % [pname, name])
			continue
		var at := to_skel * m * (bind[name] as Transform3D).affine_inverse()
		var rest := Transform3D(at.basis.orthonormalized(), at.origin)
		var bone := bs.add_bone(name)
		bs.set_bone_parent(bone, parent)
		bs.set_bone_rest(bone, global_rest(bs, parent).affine_inverse() * rest)
		bs.reset_bone_pose(bone)
	return names


## A spring simulator on bs for the cloth bone chains named, the leg
## capsules its children.
static func _spring_sim(bs: Skeleton3D, names: PackedStringArray, unrename: Dictionary) -> SpringBoneSimulator3D:
	var ends := {}
	for name in names:
		var parts := name.trim_prefix(SPRING_PREFIX).split("_")
		var chain := SPRING_PREFIX + parts[0] + "_"
		ends[chain] = maxi(ends.get(chain, -1), parts[1].to_int())
	var sim := SpringBoneSimulator3D.new()
	sim.name = "ClothSprings"
	bs.add_child(sim)  # On the skeleton before naming bones, or the names do not resolve.
	sim.set_setting_count(ends.size())
	var i := 0
	for chain: String in ends:
		var end: String = chain + str(ends[chain])
		var e := bs.find_bone(end)
		sim.set_root_bone_name(i, chain + "0")
		sim.set_end_bone_name(i, end)
		# The last joint's own length: its chain's joints are evenly spaced.
		sim.set_extend_end_bone(i, true)
		sim.set_end_bone_direction(i, SpringBoneSimulator3D.BONE_DIRECTION_PLUS_Y)
		sim.set_end_bone_length(i, bs.get_bone_rest(e).origin.length())
		sim.set_radius(i, SPRING_RADIUS)
		sim.set_stiffness(i, SPRING_STIFFNESS)
		sim.set_drag(i, SPRING_DRAG)
		sim.set_gravity(i, SPRING_GRAVITY)
		sim.set_enable_all_child_collisions(i, true)
		# Swings in the skeleton's space, not the world's: walking does not
		# drag the hem behind the legs, only the body's sways swing it. Not a
		# bone's space (the hips'): 4.4's colliders put the capsules off the
		# legs under any centre but the skeleton's own (fixed in master,
		# SpringBoneCollision3D.get_transform_from_skeleton).
		sim.set_center_from(i, SpringBoneSimulator3D.CENTER_FROM_NODE)
		sim.set_center_node(i, NodePath(".."))
		i += 1
	for cap: Array in LEG_CAPSULES:
		var a := bs.find_bone(unrename.get(cap[0], cap[0]))
		var b := bs.find_bone(unrename.get(cap[1], cap[1]))
		if a < 0 or b < 0:
			continue
		# Along the bone, in its own frame: from its head to the next bone's.
		var run := global_rest(bs, a).affine_inverse() * global_rest(bs, b).origin
		var c := SpringBoneCollisionCapsule3D.new()
		c.name = "Capsule_" + bs.get_bone_name(a)
		sim.add_child(c)
		c.set_bone_name(bs.get_bone_name(a))
		c.set_position_offset(run * 0.5)
		c.set_rotation_offset(Quaternion(Vector3.UP, run.normalized()))
		c.set_radius(cap[2])
		c.set_height(run.length() + 2.0 * cap[2])
	return sim


## A bone's rest in skeleton space, composed from the local rests up its
## parents. Skeleton3D.get_bone_global_rest() is stale for bones added this
## frame (it read identity for the cloth bones), and wrong for their parents'
## frames until the skeleton updates.
static func global_rest(bs: Skeleton3D, bone: int) -> Transform3D:
	var t := Transform3D.IDENTITY
	while bone >= 0:
		t = bs.get_bone_rest(bone) * t
		bone = bs.get_bone_parent(bone)
	return t


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

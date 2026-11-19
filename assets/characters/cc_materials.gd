class_name CCMaterials
## Gives a Character Creator character the look CC gave it. Godot's FBX
## import keeps only the plain PBR maps; CC's skin, eye, eye occlusion, tear
## line and mouth shaders are lost. This rebuilds each from the JSON sidecar
## CC exports beside the FBX (its shader name, maps and settings) onto the
## ports in assets/characters/shaders/cc/.
##
## Surfaces are matched by their imported material's name, which is the
## JSON's. A surface whose material CC gave no custom shader (the eyeballs
## under the corneas, the tear ducts, underwear) keeps its imported material.
## Materials are built once per JSON and shared; each character's skin and
## iris tint are instance uniforms (set_tints).

const SHADERS := "res://assets/characters/shaders/cc/"

static var _cache := {}


## Puts the CC materials on `root` and every mesh under it, from `json_path`.
static func apply(root: Node, json_path: String) -> void:
	var mats := _materials(json_path)
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.append(root)
	for m: MeshInstance3D in meshes:
		for s in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(s)
			if src and mats.has(src.resource_name):
				m.set_surface_override_material(s, mats[src.resource_name])
		if m.name.contains("EyeOcclusion") or m.name.contains("TearLine"):
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## WORKAROUND: Godot 4.4's FBX import gives CC's blend shapes bad normals
## and tangents (each shape's tangent handedness is +1 everywhere, and about
## 60% of its tangents point elsewhere), so any expression smears a hard
## light or dark patch over one side of the face, with CC's materials or the
## imported ones. Each shape is given the base mesh's normals and tangents
## instead. The shapes move the skin a centimetre or two, so the base's are
## close; what is lost is the faint shading change of the expression itself. Runs
## once per mesh (shared by every instance) and needs a real renderer: the
## headless one keeps no blend shape data. The rebuilt mesh has no LODs.
static var _fixed := {}

static func fix_shape_tangents(root: Node) -> void:
	for m: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		var src := m.mesh as ArrayMesh
		if src == null or src.get_blend_shape_count() == 0 or _fixed.values().has(src):
			continue
		if not _fixed.has(src):
			_fixed[src] = _rebuild(src)
		if _fixed[src]:
			m.mesh = _fixed[src]


static func _rebuild(src: ArrayMesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	out.blend_shape_mode = src.blend_shape_mode
	for k in src.get_blend_shape_count():
		out.add_blend_shape(src.get_blend_shape_name(k))
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		var shapes := src.surface_get_blend_shape_arrays(s)
		if shapes.size() != src.get_blend_shape_count():
			push_warning("CCMaterials: no blend shape data on %s (headless?)" % src.resource_name)
			return null
		var tan = arrays[Mesh.ARRAY_TANGENT]
		var nrm = arrays[Mesh.ARRAY_NORMAL]
		for a: Array in shapes:
			a[Mesh.ARRAY_TANGENT] = tan
			a[Mesh.ARRAY_NORMAL] = nrm
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, shapes, {},
				src.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		out.surface_set_material(s, src.surface_get_material(s))
		out.surface_set_name(s, src.surface_get_name(s))
	out.resource_name = src.resource_name
	return out


## Back to the imported materials.
static func clear(root: Node) -> void:
	for m: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for s in m.mesh.get_surface_count():
			m.set_surface_override_material(s, null)
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


## Puts a CC hairstyle on a CC character. CC exports the hair on its own
## copy of the base body, with that copy's skeleton, so the hair mesh is moved
## onto `character`'s skeleton and each of its binds is rebound to the
## character's bone at the same place.
##
## WORKAROUND: the hair FBXs came from CC's Python export, which ignored its
## Y-up and bone-name options (Z up, Unreal-style names); the bases came from
## the export dialog. A Z-up hair skeleton is turned Y-up here. Exporting the
## hair from the dialog would make that step a no-op. Its blend shapes
## (CC's face morphs, there so the hair can follow brow and scalp shapes) are
## dropped: the hair does not follow expressions. Returns the hair mesh.
static func attach_hair(character: Node3D, hair: PackedScene, json_path: String) -> MeshInstance3D:
	var src := hair.instantiate() as Node3D
	var hs := src.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var bs := character.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var mesh: MeshInstance3D = null
	for m: MeshInstance3D in hs.find_children("*", "MeshInstance3D", false, false):
		var n := String(m.name).to_lower()
		if not (n.begins_with("cc_base") or n in ["boxers", "bra", "underwear_bottoms"]):
			mesh = m
	if mesh == null:
		src.free()
		push_warning("CCMaterials: no hair mesh in %s" % hair.resource_path)
		return null
	# From the hair skeleton's space to the character skeleton's.
	var to_base := _in_scene(bs).affine_inverse() * _in_scene(hs)
	var head := hs.get_bone_global_rest(hs.find_bone(mesh.skin.get_bind_name(0))).origin
	if head.z > head.y:
		to_base = to_base * Transform3D(Basis(Vector3.RIGHT, -PI / 2.0))
	var skin := Skin.new()
	for i in mesh.skin.get_bind_count():
		var hb := hs.find_bone(mesh.skin.get_bind_name(i))
		var at := to_base * hs.get_bone_global_rest(hb)
		var best := -1
		for b in bs.get_bone_count():
			if best < 0 or bs.get_bone_global_rest(b).origin.distance_to(at.origin) < bs.get_bone_global_rest(best).origin.distance_to(at.origin):
				best = b
		skin.add_named_bind(bs.get_bone_name(best),
				bs.get_bone_global_rest(best).affine_inverse() * at * mesh.skin.get_bind_pose(i))
	var plain := ArrayMesh.new()
	var am := mesh.mesh as ArrayMesh
	for s in am.get_surface_count():
		plain.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, am.surface_get_arrays(s), [], {},
				am.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		plain.surface_set_material(s, am.surface_get_material(s))
		plain.surface_set_name(s, am.surface_get_name(s))
	plain.resource_name = am.resource_name
	var out := MeshInstance3D.new()
	out.name = mesh.name
	out.mesh = plain
	out.skin = skin
	bs.add_child(out)
	out.skeleton = NodePath("..")
	src.free()
	apply(out, json_path)
	return out


## A node's transform relative to its scene's root.
static func _in_scene(n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	while n and n.owner != null:
		t = n.transform * t
		n = n.get_parent() as Node3D
	return t


## This character's hair colour; alpha 0 keeps CC's.
static func set_hair_color(root: Node, color: Color) -> void:
	for m: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for s in m.mesh.get_surface_count():
			var mat := m.get_surface_override_material(s) as ShaderMaterial
			var f := mat.shader.resource_path.get_file() if mat else ""
			if f.begins_with("cc_hair") or f.begins_with("cc_scalp"):
				m.set_instance_shader_parameter("hair_color", color)
				break


## This character's skin and iris colour, multiplied over CC's maps.
static func set_tints(root: Node, skin: Color, iris: Color) -> void:
	for m: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if m.name == "CC_Base_Body":
			m.set_instance_shader_parameter("skin_tint", skin)
		elif m.name == "CC_Base_Eye":
			m.set_instance_shader_parameter("iris_tint", iris)


static func _materials(json_path: String) -> Dictionary:
	if _cache.has(json_path):
		return _cache[json_path]
	var out := {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if data == null:
		push_warning("CCMaterials: can't read %s" % json_path)
		return out
	var files := {}
	_index(json_path.get_base_dir(), files)
	var found := []
	_find_materials(data, found)
	for list: Dictionary in found:
		for mat_name: String in list:
			var m := _build(mat_name, list[mat_name], files)
			if m:
				out[mat_name] = m
	_cache[json_path] = out
	return out


# Every PNG under the character's folder by file name: the JSON's paths are
# relative to the FBX and CC nests its folders oddly, but names are unique.
static func _index(dir: String, files: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == "png":
			files[f.to_lower()] = dir.path_join(f)
	for d in DirAccess.get_directories_at(dir):
		_index(dir.path_join(d), files)


static func _find_materials(o: Variant, found: Array) -> void:
	if o is Dictionary:
		for k: String in o:
			if k == "Materials":
				found.append(o[k])
			else:
				_find_materials(o[k], found)


static func _tex(files: Dictionary, entry: Variant) -> Texture2D:
	if not entry is Dictionary or str(entry.get("Texture Path", "")) == "":
		return null
	var key := str(entry["Texture Path"]).get_file().to_lower()
	if not files.has(key):
		push_warning("CCMaterials: missing texture %s" % entry["Texture Path"])
		return null
	return load(files[key])


static func _col(v: Variant) -> Color:
	return Color(v[0] / 255.0, v[1] / 255.0, v[2] / 255.0)


# CC hair's "<which> Reflection Offset X/Y/Z" as one vector.
static func _offset(v: Dictionary, which: String) -> Vector3:
	var k := which + " Reflection Offset "
	return Vector3(v.get(k + "X", 0.0), v.get(k + "Y", 0.0), v.get(k + "Z", 0.0))


static func _build(mat_name: String, m: Dictionary, files: Dictionary) -> Material:
	var cs: Dictionary = m.get("Custom Shader", {})
	var shader := str(cs.get("Shader Name", ""))
	var tex: Dictionary = m.get("Textures", {})
	var img: Dictionary = cs.get("Image", {})
	var v: Dictionary = cs.get("Variable", {})
	var base := _tex(files, tex.get("Base Color"))
	var normal := _tex(files, tex.get("Normal"))
	var ao := _tex(files, tex.get("AO"))
	if mat_name == "Std_Eyelash":
		var l := StandardMaterial3D.new()
		l.resource_name = mat_name
		l.albedo_texture = base
		l.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		l.cull_mode = BaseMaterial3D.CULL_DISABLED
		l.roughness = 0.7
		l.uv1_scale = Vector3.ONE
		if normal:
			l.normal_enabled = true
			l.normal_texture = normal
		if ao:
			l.ao_enabled = true
			l.ao_texture = ao
		return l
	var sm := ShaderMaterial.new()
	sm.resource_name = mat_name
	if shader == "" and m.get("Node Type", "") == "Hair":
		# The scalp cap under the hair cards: colour and opacity, no CC shader.
		if base == null:
			return null
		sm.shader = load(SHADERS + "cc_scalp.gdshader")
		sm.set_shader_parameter("base_map", base)
		sm.set_shader_parameter("opacity_map", _tex(files, tex.get("Opacity")))
		sm.render_priority = -1
		return sm
	match shader:
		"RLHair":
			sm.shader = load(SHADERS + "cc_hair.gdshader")
			var fringe := ShaderMaterial.new()
			fringe.shader = load(SHADERS + "cc_hair_fringe.gdshader")
			# CC's JSON names no ORM map; the export puts one beside the others.
			var p := {
				"opacity_map": _tex(files, tex.get("Opacity")),
				"root_map": _tex(files, img.get("Hair Root Map")),
				"id_map": _tex(files, img.get("Hair ID Map")),
				"flow_map": _tex(files, img.get("Hair Flow Map")),
				"blend_map": _tex(files, tex.get("Blend")),
				"orm_map": _tex(files, {"Texture Path": mat_name + "_ORM.png"}),
				"root_color": _col(v.get("RootColor", [8, 5, 3])),
				"tip_color": _col(v.get("TipColor", [25, 18, 13])),
				"strand_blend_mode": int(v.get("RootTipBlendMode", 1.0)),
				"strand_strength": v.get("UseRootTipColor", 1.0),
				"root_strength": v.get("RootColorStrength", 1.0),
				"tip_strength": v.get("TipColorStrength", 1.0),
				"invert_root_tip": v.get("InvertRootTip", 0.0),
				"diffuse_strength": v.get("Diffuse Strength", 1.0),
				"blend_map_strength": v.get("BaseColorMapStrength", 0.7),
				"vertex_gray_color": _col(v.get("VertexGrayToColor", [0, 0, 0])),
				"vertex_color_strength": v.get("VertexColorStrength", 0.0),
				"dyes_active": v.get("ActiveChangeHairColor", 1.0) > 0.5,
				"specular_strength": v.get("Specular Strength", 0.35),
				"secondary_specular_strength": v.get("Secondary Specular Strength", 0.5),
				"black_offset": _offset(v, "BlackColor"),
				"white_offset": _offset(v, "WhiteColor"),
				"spec_map_strength": v.get("Hair Specular Map Strength", 0.25),
				"roughness_map_strength": v.get("Hair Roughness Map Strength", 0.5),
				"flip_flow_y": v.get("TangentMapFlipGreen", 1.0) > 0.5,
				"has_flow_map": img.get("Hair Flow Map") is Dictionary and str(img["Hair Flow Map"].get("Texture Path", "")) != "",
				"tangent_vector_color": _col(v.get("TangentVectorColor", [255, 0, 0])),
				"specular_color": _col(m.get("Specular Color", [255, 255, 255])),
				"ao_light_affect": v.get("AO Map Occlude All Lighting", 1.0),
				"lit_back_face": v.get("No Back Face Triangles", 1.0),
				"transmission": v.get("Transmission Strength", 0.5),
			}
			for i in [1, 2]:
				var d := "_%s Dye " % ("1st" if i == 1 else "2nd")
				var r: Array = v.get(d + "Distribution from Grayscale", [0, 255, 255])
				var n := "1st" if i == 1 else "2nd"
				p["dye%d_color" % i] = _col(v.get(d + "Color", [0, 0, 0]))
				p["dye%d_strength" % i] = v.get(d + "Strength", 0.0)
				p["dye%d_range" % i] = Vector3(r[0], r[1], r[2]) / 255.0
				p["dye%d_blend_mode" % i] = int(v.get("_%s BlendMode" % n, 0.0))
				p["dye%d_end_overlap" % i] = v.get("Mask %s Dye by RootMap" % n, 0.0)
				p["dye%d_end_invert" % i] = v.get("Invert %s Dye RootMap Mask" % n, 0.0)
				p["dye%d_specular" % i] = v.get(d + "add Specular", 0.0)
			for k: String in p:
				sm.set_shader_parameter(k, p[k])
				fringe.set_shader_parameter(k, p[k])
			sm.next_pass = fringe
			return sm
		"RLSkin", "RLHead":
			if base == null or not img.has("SSS Map"):
				return null  # the tear ducts: base colour only, keep the import
			var head := shader == "RLHead"
			sm.shader = load(SHADERS + ("cc_head.gdshader" if head else "cc_skin.gdshader"))
			sm.set_shader_parameter("base_map", base)
			sm.set_shader_parameter("normal_map", normal)
			sm.set_shader_parameter("ao_map", ao)
			# CC's HDRP mask (A is smoothness) sits beside the other maps, unnamed in the JSON.
			sm.set_shader_parameter("hdrp_map", _tex(files, {"Texture Path": mat_name + "_HDRP.png"}))
			sm.set_shader_parameter("sss_map", _tex(files, img.get("SSS Map")))
			sm.set_shader_parameter("transmission_map", _tex(files, img.get("Transmission Map")))
			sm.set_shader_parameter("micro_normal_map", _tex(files, img.get("MicroNormal")))
			sm.set_shader_parameter("micro_normal_mask", _tex(files, img.get("MicroNormalMask")))
			sm.set_shader_parameter("micro_normal_tiling", v.get("MicroNormal Tiling", 25.0))
			sm.set_shader_parameter("micro_normal_strength", v.get("MicroNormal Strength", 0.8))
			sm.set_shader_parameter("flip_micro_normal_y", v.get("Flip MicroNormal Y", 1.0) > 0.5)
			sm.set_shader_parameter("original_roughness_strength", v.get("Original Roughness Strength", 0.85))
			sm.set_shader_parameter("micro_roughness_scale", v.get("Micro Roughness Scale", 0.055))
			sm.set_shader_parameter("edge_roughness_multiplier", v.get("Edge Roughness Multiplier", 0.044))
			sm.set_shader_parameter("unmasked_roughness_scale", v.get("Unmasked Roughness Scale", 0.0))
			sm.set_shader_parameter("unmasked_scatter_scale", v.get("Unmasked Scatter Scale", 1.0))
			sm.set_shader_parameter("specular", v.get("_Specular", 0.4))
			if m.has("Subsurface Scatter"):
				var sss: Dictionary = m["Subsurface Scatter"]
				if sss.has("Falloff"):
					sm.set_shader_parameter("scatter_color", _col(sss["Falloff"]))
			if head:
				sm.set_shader_parameter("spec_mask", _tex(files, img.get("Specular Mask")))
				sm.set_shader_parameter("cfulc_mask", _tex(files, img.get("Cheek Fore UpperLip Chin Mask")))
				sm.set_shader_parameter("nmuil_mask", _tex(files, img.get("Nose Mouth UpperInnerLid Mask")))
				sm.set_shader_parameter("en_mask", _tex(files, img.get("Ear Neck Mask")))
				sm.set_shader_parameter("cavity_mask", _tex(files, img.get("Mouth Cavity Mask and AO")))
				sm.set_shader_parameter("cfulc_roughness", _v4(v, ["Cheek", "Forehead", "UpperLip", "Chin"], " Roughness Scale", 0.0))
				sm.set_shader_parameter("nmuil_roughness", _v4(v, ["Nose", "Mouth", "UpperLid", "InnerLid"], " Roughness Scale", 0.0))
				sm.set_shader_parameter("en_roughness", Vector2(v.get("Ear Roughness Scale", 0.0), v.get("Neck Roughness Scale", 0.0)))
				sm.set_shader_parameter("cfulc_scatter", _v4(v, ["Cheek", "Forehead", "UpperLip", "Chin"], " Scatter Scale", 1.0))
				sm.set_shader_parameter("nmuil_scatter", _v4(v, ["Nose", "Mouth", "UpperLid", "InnerLid"], " Scatter Scale", 1.0))
				sm.set_shader_parameter("en_scatter", Vector2(v.get("Ear Scatter Scale", 1.0), v.get("Neck Scatter Scale", 1.0)))
				sm.set_shader_parameter("cavity_ao", Vector3(v.get("Inner Mouth Ao", 2.5), v.get("Nostril Ao", 3.5), v.get("Lips Gap Ao", 2.5)))
			else:
				sm.set_shader_parameter("rgba_mask", _tex(files, img.get("RGBA Area Mask")))
				sm.set_shader_parameter("rgba_roughness", _v4(v, ["R", "G", "B", "A"], " Channel Roughness Scale", 0.0))
				sm.set_shader_parameter("rgba_scatter", _v4(v, ["R", "G", "B", "A"], " Channel Scatter Scale", 1.0))
		"RLEye":
			sm.shader = load(SHADERS + "cc_eye.gdshader")
			sm.set_shader_parameter("eye_map", base)
			sm.set_shader_parameter("ao_map", ao)
			sm.set_shader_parameter("sclera_map", _tex(files, img.get("Sclera")))
			sm.set_shader_parameter("sclera_normal_map", _tex(files, img.get("Sclera Normal")))
			sm.set_shader_parameter("iris_uv_radius", v.get("Iris UV Radius", 0.16))
			sm.set_shader_parameter("limbus_uv_width", v.get("Limbus UV Width Color", 0.055))
			sm.set_shader_parameter("limbus_dark_scale", v.get("Limbus Dark Scale", 9.0))
			sm.set_shader_parameter("iris_depth_scale", v.get("Iris Depth Scale", 0.6))
			sm.set_shader_parameter("ior", v.get("_IoR", 1.4))
			sm.set_shader_parameter("pupil_scale", v.get("Pupil Scale", 1.0))
			sm.set_shader_parameter("iris_color", _col(v.get("Iris Color", [255, 255, 255])))
			sm.set_shader_parameter("iris_brightness", v.get("Iris Color Brightness", 1.0))
			sm.set_shader_parameter("sclera_brightness", v.get("ScleraBrightness", 0.65))
			sm.set_shader_parameter("sclera_roughness", v.get("Sclera Roughness", 0.2))
			sm.set_shader_parameter("sclera_flatten_normal", v.get("Sclera Flatten Normal", 0.9))
			sm.set_shader_parameter("sclera_normal_uv_scale", v.get("Sclera Normal UV Scale", 0.75))
			sm.set_shader_parameter("sclera_uv_radius", v.get("Sclera UV Radius", 0.9))
			sm.set_shader_parameter("corner_color", _col(v.get("Eye Corner Darkness Color", [255, 188, 179])))
			sm.set_shader_parameter("shadow_radius", v.get("Shadow Radius", 0.35))
			sm.set_shader_parameter("shadow_hardness", v.get("Shadow Hardness", 0.5))
			sm.set_shader_parameter("specular_scale", v.get("Specular Scale", 0.8))
		"RLEyeOcclusion":
			sm.shader = load(SHADERS + "cc_eye_occlusion.gdshader")
			var p := {"shadow_strength": "Shadow Strength", "shadow_top": "Shadow Top", "shadow_top_range": "Shadow Top Range",
					"shadow_top_arc": "Shadow Top Arc", "shadow_bottom": "Shadow Bottom", "shadow_bottom_range": "Shadow Bottom Range",
					"shadow_bottom_arc": "Shadow Bottom Arc", "shadow_inner": "Shadow Inner Corner", "shadow_inner_range": "Shadow Inner Corner Range",
					"shadow_outer": "Shadow Outer Corner", "shadow_outer_range": "Shadow Outer Corner Range", "shadow2_strength": "Shadow2 Strength",
					"shadow2_top": "Shadow2 Top", "shadow2_top_range": "Shadow2 Top Range", "top_contrast": "Top Blur Contrast",
					"bottom_contrast": "Bottom Blur Contrast", "outer_contrast": "Outer Corner Blur Contrast", "blur_strength": "Blur Strength",
					"tear_duct_position": "Tear Duct Position", "tear_duct_contrast": "Tear Duct Contrast"}
			for u: String in p:
				if v.has(p[u]):
					sm.set_shader_parameter(u, v[p[u]])
			if v.has("Shadow Color"):
				sm.set_shader_parameter("shadow_color", _col(v["Shadow Color"]))
			if v.has("Shadow2 Color"):
				sm.set_shader_parameter("shadow2_color", _col(v["Shadow2 Color"]))
		"RLEyeTearline":
			sm.shader = load(SHADERS + "cc_tearline.gdshader")
			sm.set_shader_parameter("roughness", v.get("_Roughness", 0.1))
			sm.set_shader_parameter("detail_amount", v.get("Detail Amount", 0.03))
			sm.set_shader_parameter("detail_scale", Vector2(v.get("Detail Scale U", 2.3), v.get("Detail Scale V", 0.12)))
			sm.set_shader_parameter("edge_fadeout", v.get("Edge Fadeout", 1.0))
		"RLTeethGum", "RLTongue":
			sm.shader = load(SHADERS + "cc_mouth.gdshader")
			sm.set_shader_parameter("base_map", base)
			sm.set_shader_parameter("normal_map", normal)
			sm.set_shader_parameter("ao_map", ao)
			sm.set_shader_parameter("micro_normal_map", _tex(files, img.get("MicroNormal")))
			sm.set_shader_parameter("grad_ao_map", _tex(files, img.get("Gradient AO")))
			sm.set_shader_parameter("flip_micro_normal_y", v.get("Flip MicroNormal Y", 1.0) > 0.5)
			if shader == "RLTongue":
				# B: the tongue's front-to-back gradient in the shared atlas.
				sm.set_shader_parameter("grad_channel", Vector4(0, 0, 1, 0))
				sm.set_shader_parameter("micro_normal_tiling", v.get("MicroNormal Tiling", 4.0))
				sm.set_shader_parameter("micro_normal_strength", v.get("MicroNormal Strength", 0.5))
				sm.set_shader_parameter("gums_brightness", v.get("_Brightness", 1.0))
				sm.set_shader_parameter("gums_desaturation", v.get("_Desaturation", 0.2))
				sm.set_shader_parameter("front_roughness", v.get("Front Roughness", 1.0))
				sm.set_shader_parameter("front_specular", v.get("Front Specular", 0.26))
				sm.set_shader_parameter("back_specular", v.get("Back Specular", 0.0))
				sm.set_shader_parameter("front_ao", v.get("Front AO", 1.0))
				sm.set_shader_parameter("back_ao", v.get("Back AO", 0.0))
				sm.set_shader_parameter("gums_scatter", v.get("_Scatter", 1.0))
			else:
				var upper: bool = v.get("Is Upper Teeth", 1.0) > 0.5
				# G for the upper teeth, R for the lower.
				sm.set_shader_parameter("grad_channel", Vector4(0, 1, 0, 0) if upper else Vector4(1, 0, 0, 0))
				sm.set_shader_parameter("gums_mask", _tex(files, img.get("Gums Mask")))
				sm.set_shader_parameter("micro_normal_tiling", v.get("Teeth MicroNormal Tiling", 10.0))
				sm.set_shader_parameter("micro_normal_strength", v.get("Teeth MicroNormal Strength", 0.3))
				sm.set_shader_parameter("teeth_brightness", v.get("Teeth Brightness", 0.7))
				sm.set_shader_parameter("teeth_desaturation", v.get("Teeth Desaturation", 0.1))
				sm.set_shader_parameter("gums_brightness", v.get("Gums Brightness", 0.9))
				sm.set_shader_parameter("gums_desaturation", v.get("Gums Desaturation", 0.0))
				sm.set_shader_parameter("front_roughness", v.get("Front Roughness", 0.4))
				sm.set_shader_parameter("front_specular", v.get("Front Specular", 0.1))
				sm.set_shader_parameter("back_specular", v.get("Back Specular", 0.0))
				sm.set_shader_parameter("front_ao", v.get("Front AO", 1.0))
				sm.set_shader_parameter("back_ao", v.get("Back AO", 0.0))
				sm.set_shader_parameter("teeth_scatter", v.get("Teeth Scatter", 0.5))
				sm.set_shader_parameter("gums_scatter", v.get("Gums Scatter", 1.0))
				if v.has("Teeth Edge Color"):
					sm.set_shader_parameter("teeth_edge_color", _col(v["Teeth Edge Color"]))
		_:
			return null
	return sm


static func _v4(v: Dictionary, names: Array, suffix: String, fallback: float) -> Vector4:
	return Vector4(v.get(names[0] + suffix, fallback), v.get(names[1] + suffix, fallback),
			v.get(names[2] + suffix, fallback), v.get(names[3] + suffix, fallback))

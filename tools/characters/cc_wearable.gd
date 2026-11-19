extends SceneTree
## Makes a garment fitted to a CC body outside CC (armour from elsewhere)
## wearable by CCLook.wear(): Wearable.cc_scene names what this writes.
##
## THE FIT. The garment comes as a glTF skinned to the body's skeleton,
## fitted in Blender to the body at its skeleton's rest (export_body.gd's
## round trip of the base). That rest is not the body's bind: the base's
## mesh is bound in CC's own space and pose. CCLook layers garments by
## comparing their meshes with the body's and each other's at bind
## (CCMaterials.uncovered, garment_offset), and binds every garment with the
## body's own binds (CCMaterials.garment_skin), as CC's exports are. So each
## vertex is carried from the garment's bind into the body's, by its own
## weights (vertex -> garment bind -> bone -> body bind, blended), and the
## garment is saved with the body's skin.
##
## THE COVERS. CC's exports drop the skin a garment hides, and cc_covers.gd
## reads the mask off that; here nothing is dropped, so the skin is hidden
## where it cannot be seen: a body triangle is hidden when every ray out of
## it, over its hemisphere (RAYS of them, out to SIGHT), is stopped by the
## garment or the body, at least one by the garment; or when it pokes out
## through the garment by up to UNDER. A neck inside an open hood sees out
## past the hood's opening and stays; a chest under a jerkin does not.
## This is judged at bind and again in each of POSES (body and garment
## skinned on the CPU): skin covered in any of them is hidden, so skin the
## arms-down idle pushes through a sleeve's padding is hidden though the
## bind's A-pose bares it under the arm.
##
## Run with a renderer (the headless one keeps no mesh arrays):
##
##   godot --path . -s tools/characters/cc_wearable.gd -- <garment .glb> <part> [base fbx]
##
## Writes <garment dir>/<part>.scn and <garment dir>/covers/<part>.png.

const BASE := "res://assets/characters/cc/male/cc_base_male.fbx"
## Pixels per UV tile, each way (cc_covers.gd's).
const TILE := 512
## UV tiles side by side in the mask (CCLook.COVERS_TILES; CCLook itself
## does not compile under -s, its dependencies need the autoloads).
const TILES := 6
## Rays cast out of each body triangle.
const RAYS := 32
## Metres a ray goes before it counts as seen from outside.
const SIGHT := 0.4
## Rays allowed out before a triangle counts as seen (gaps between plates).
const SEEN := 1
## Metres in: skin poking through the garment by up to this is hidden too.
const UNDER := 0.02
## Triangles: a patch of skin left seen this small, ringed by hidden skin,
## is a speck seen through a crack in the garment, and is hidden too.
const SPECK := 24
## Clips (on MODEL's AnimationPlayer, at POSE_T seconds) the skin is also
## judged in.
const POSES: Array[String] = ["Locomotion/idle"]
const POSE_T := 0.5
const MODEL := "res://scenes/character_models/cc_male_model.tscn"
## Collision layers of the bake's ray world.
const GARMENT_LAYER := 1
const BODY_LAYER := 2


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	await _make(args[0], StringName(args[1]), args[2] if args.size() > 2 else BASE)
	quit()


func _make(garment_path: String, part: StringName, base_path: String) -> void:
	var base: Node = load(base_path).instantiate()
	var source: Node = load(garment_path).instantiate()
	var body: MeshInstance3D = CCMaterials._body(base)
	var garment: MeshInstance3D = null
	for m: MeshInstance3D in source.find_children("*", "MeshInstance3D", true, false):
		if String(m.name).to_lower() == String(part).to_lower():
			garment = m
	assert(garment != null and garment.skin != null, "no skinned %s in %s" % [part, garment_path])

	var mesh := _rebound(garment.mesh as ArrayMesh, garment.skin, body.skin)
	var root := Node3D.new()
	root.name = String(part)
	var out := MeshInstance3D.new()
	out.name = String(part)
	out.mesh = mesh
	out.skin = body.skin.duplicate()
	root.add_child(out)
	out.owner = root
	var scene := PackedScene.new()
	scene.pack(root)
	var scene_path := garment_path.get_base_dir().path_join(String(part).to_lower() + ".scn")
	var err := ResourceSaver.save(scene, scene_path)
	assert(err == OK, "can't save %s" % scene_path)
	print("%s -> %s, offset now %s" % [garment_path.get_file(), scene_path,
			CCMaterials.garment_offset(out.skin, body.skin)])

	await _bake_covers(body, mesh, garment_path.get_base_dir().path_join("covers/%s.png" % String(part).to_lower()))
	root.free()
	base.free()
	source.free()


## mesh, bound by `from`, carried into the space `to` binds and indexed by
## to's binds. Bones are matched by name; every bone the garment weights
## must be one the body binds.
func _rebound(mesh: ArrayMesh, from: Skin, to: Skin) -> ArrayMesh:
	var by_name := {}
	for j in to.get_bind_count():
		by_name[to.get_bind_name(j)] = j
	var index := PackedInt32Array()
	var carry: Array[Transform3D] = []
	for i in from.get_bind_count():
		var j: int = by_name.get(from.get_bind_name(i), -1)
		index.append(j)
		carry.append(to.get_bind_pose(j).affine_inverse() * from.get_bind_pose(i) if j >= 0 else Transform3D())
	var out := ArrayMesh.new()
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		var eight := mesh.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		var per := 8 if eight else 4
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var t: PackedFloat32Array = a[Mesh.ARRAY_TANGENT] if a[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
		var bones: PackedInt32Array = a[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS]
		for k in v.size():
			var p := Vector3.ZERO
			var q := Vector3.ZERO
			var r := Vector3.ZERO
			var tangent := Vector3(t[k * 4], t[k * 4 + 1], t[k * 4 + 2]) if t.size() else Vector3.ZERO
			for w in per:
				var weight := weights[k * per + w]
				var b := bones[k * per + w]
				if weight <= 0.0:
					bones[k * per + w] = 0
					continue
				assert(index[b] >= 0, "%s is weighted to %s, which the body does not bind" % [
						mesh.resource_name, from.get_bind_name(b)])
				p += carry[b] * v[k] * weight
				q += carry[b].basis * n[k] * weight
				r += carry[b].basis * tangent * weight
				bones[k * per + w] = index[b]
			v[k] = p
			n[k] = q.normalized()
			if t.size():
				var tn := r.normalized()
				t[k * 4] = tn.x
				t[k * 4 + 1] = tn.y
				t[k * 4 + 2] = tn.z
		a[Mesh.ARRAY_VERTEX] = v
		a[Mesh.ARRAY_NORMAL] = n
		if t.size():
			a[Mesh.ARRAY_TANGENT] = t
		a[Mesh.ARRAY_BONES] = bones
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a, [], {}, eight)
		out.surface_set_material(s, mesh.surface_get_material(s))
		out.surface_set_name(s, mesh.surface_get_name(s))
	out.resource_name = mesh.resource_name
	return out


## Writes the covers mask of `garment` (in the body's bind space) to path.
func _bake_covers(body: MeshInstance3D, garment: ArrayMesh, path: String) -> void:
	var fan := _fan()
	var shapes: Array = [[body.mesh as ArrayMesh, garment]]
	for clip in POSES:
		var skeleton := await _posed_skeleton(clip)
		shapes.append([_skinned(body.mesh as ArrayMesh, body.skin, skeleton),
				_skinned(garment, body.skin, skeleton)])
		(skeleton.get_meta(&"bake_model") as Node).queue_free()
	var bind_arrays := []
	var covered_by_surface: Array[PackedByteArray] = []
	for s in body.mesh.get_surface_count():
		bind_arrays.append(body.mesh.surface_get_arrays(s))
		var none := PackedByteArray()
		none.resize(bind_arrays[s][Mesh.ARRAY_INDEX].size() / 3)
		covered_by_surface.append(none)
	for pair in shapes:
		var world := Node3D.new()
		root.add_child(world)
		_solid(world, pair[1], GARMENT_LAYER)
		_solid(world, pair[0], BODY_LAYER)
		await physics_frame
		await physics_frame
		var space := world.get_world_3d().direct_space_state
		var ray := PhysicsRayQueryParameters3D.new()
		ray.hit_back_faces = true
		for s in body.mesh.get_surface_count():
			var a: Array = (pair[0] as ArrayMesh).surface_get_arrays(s)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			var covered := covered_by_surface[s]
			for i in range(0, idx.size(), 3):
				if covered[i / 3]:
					continue
				var c := (v[idx[i]] + v[idx[i + 1]] + v[idx[i + 2]]) / 3.0
				var out := (n[idx[i]] + n[idx[i + 1]] + n[idx[i + 2]]).normalized()
				if _covered(space, ray, fan, c, out):
					covered[i / 3] = 1
			covered_by_surface[s] = covered
		world.queue_free()

	var image := Image.create(TILE * TILES, TILE, false, Image.FORMAT_LA8)
	var hidden := 0
	var total := 0
	var specks := 0
	for s in body.mesh.get_surface_count():
		var a: Array = bind_arrays[s]
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		var covered := covered_by_surface[s]
		total += covered.size()
		specks += _hide_specks(v, idx, covered)
		for t in covered.size():
			if covered[t]:
				hidden += 1
				_fill(image, uv[idx[t * 3]], uv[idx[t * 3 + 1]], uv[idx[t * 3 + 2]])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	image.save_png(ProjectSettings.globalize_path(path))
	print("  %d of %d body triangles hidden (%d in specks), at bind and in %s -> %s" % [
			hidden, total, specks, POSES, path])


## MODEL's body skeleton, posed by clip at POSE_T (the model stays in the
## tree till the caller frees its meta bake_model).
func _posed_skeleton(clip: String) -> Skeleton3D:
	var model: Node3D = load(MODEL).instantiate()
	root.add_child(model)
	await process_frame
	var player := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	assert(player != null and player.has_animation(clip), "%s has no %s" % [MODEL, clip])
	player.play(clip)
	player.seek(POSE_T, true)
	player.pause()
	var skeleton: Skeleton3D = CCMaterials._body(model).get_node(CCMaterials._body(model).skeleton)
	skeleton.force_update_all_bone_transforms()
	skeleton.set_meta(&"bake_model", model)
	return skeleton


## mesh (bound by skin) skinned on the CPU by skeleton's pose: vertices and
## normals, in the skeleton's space.
func _skinned(mesh: ArrayMesh, skin: Skin, skeleton: Skeleton3D) -> ArrayMesh:
	var by_bind: Array[Transform3D] = []
	for j in skin.get_bind_count():
		var bone := skeleton.find_bone(skin.get_bind_name(j))
		assert(bone >= 0, "posed skeleton lacks %s" % skin.get_bind_name(j))
		by_bind.append(skeleton.get_bone_global_pose(bone) * skin.get_bind_pose(j))
	var out := ArrayMesh.new()
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		var per := 8 if mesh.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS else 4
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var bones: PackedInt32Array = a[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS]
		for k in v.size():
			var p := Vector3.ZERO
			var q := Vector3.ZERO
			for w in per:
				var weight := weights[k * per + w]
				if weight > 0.0:
					var t := by_bind[bones[k * per + w]]
					p += t * v[k] * weight
					q += t.basis * n[k] * weight
			v[k] = p
			n[k] = q.normalized()
		var keep := []
		keep.resize(Mesh.ARRAY_MAX)
		keep[Mesh.ARRAY_VERTEX] = v
		keep[Mesh.ARRAY_NORMAL] = n
		keep[Mesh.ARRAY_INDEX] = a[Mesh.ARRAY_INDEX]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, keep)
	return out


## Hides (in covered, per triangle) each patch of seen triangles under SPECK
## big that touches hidden ones, triangles joined by edges (positions
## welded, so UV seams do not cut a patch). Returns how many it hid.
func _hide_specks(v: PackedVector3Array, idx: PackedInt32Array, covered: PackedByteArray) -> int:
	var by_edge := {}
	var weld := {}
	var key := func(i: int) -> Vector3i: return Vector3i((v[i] * 1e5).round())
	for t in covered.size():
		for e in 3:
			var a: Vector3i = key.call(idx[t * 3 + e])
			var b: Vector3i = key.call(idx[t * 3 + (e + 1) % 3])
			var k := [a, b] if a < b else [b, a]
			if not by_edge.has(k):
				by_edge[k] = []
			by_edge[k].append(t)
	var seen := {}
	var hid := 0
	for start in covered.size():
		if covered[start] or seen.has(start):
			continue
		var patch: Array[int] = [start]
		var touches := false
		seen[start] = true
		var k := 0
		while k < patch.size():
			var t := patch[k]
			k += 1
			for e in 3:
				var a: Vector3i = key.call(idx[t * 3 + e])
				var b: Vector3i = key.call(idx[t * 3 + (e + 1) % 3])
				for o: int in by_edge[[a, b] if a < b else [b, a]]:
					if covered[o]:
						touches = true
					elif not seen.has(o):
						seen[o] = true
						patch.append(o)
		if touches and patch.size() < SPECK:
			for t in patch:
				covered[t] = 1
			hid += patch.size()
	return hid


## Whether skin at c, facing out, is out of sight under the garment.
func _covered(space: PhysicsDirectSpaceState3D, ray: PhysicsRayQueryParameters3D, fan: Array[Vector3], c: Vector3, out: Vector3) -> bool:
	# Poking out through the garment by up to UNDER.
	ray.collision_mask = GARMENT_LAYER
	ray.from = c - out * UNDER
	ray.to = c + out * 0.001
	if not space.intersect_ray(ray).is_empty():
		return true
	ray.collision_mask = GARMENT_LAYER | BODY_LAYER
	var frame := Basis(out.cross(Vector3.UP if absf(out.y) < 0.9 else Vector3.RIGHT).normalized(), out, Vector3.ZERO)
	frame.z = frame.x.cross(frame.y)
	var start := c + out * 0.003
	var seen := 0
	var by_garment := false
	for d in fan:
		ray.from = start
		ray.to = start + frame * d * SIGHT
		var hit := space.intersect_ray(ray)
		if hit.is_empty():
			seen += 1
			if seen > SEEN:
				return false
		elif hit.collider.collision_layer == GARMENT_LAYER:
			by_garment = true
	return by_garment


## RAYS directions over the hemisphere about +Y, cosine-weighted (a
## Fibonacci spiral), so they sample what the skin sees.
func _fan() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for k in RAYS:
		var r := sqrt((k + 0.5) / RAYS)
		var phi := k * PI * (3.0 - sqrt(5.0))
		out.append(Vector3(r * cos(phi), sqrt(1.0 - r * r), r * sin(phi)))
	return out


## A static body of mesh's triangles, on layer, under parent.
func _solid(parent: Node3D, mesh: ArrayMesh, layer: int) -> void:
	var faces := PackedVector3Array()
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		for i: int in a[Mesh.ARRAY_INDEX]:
			faces.append(v[i])
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var solid := StaticBody3D.new()
	solid.collision_layer = layer
	solid.collision_mask = 0
	var collider := CollisionShape3D.new()
	collider.shape = shape
	solid.add_child(collider)
	parent.add_child(solid)


## Paints a UV triangle opaque, half a pixel wider all round so triangles
## sharing an edge leave no crack (cc_covers.gd's).
func _fill(image: Image, a: Vector2, b: Vector2, c: Vector2) -> void:
	var size := Vector2(TILE, TILE)
	var pa := a * size
	var pb := b * size
	var pc := c * size
	var lo := pa.min(pb).min(pc).floor() - Vector2.ONE
	var hi := pa.max(pb).max(pc).ceil() + Vector2.ONE
	var area := (pb - pa).cross(pc - pa)
	if absf(area) < 1e-9:
		return
	var winding := signf(area)
	for y in range(maxi(int(lo.y), 0), mini(int(hi.y), image.get_height())):
		for x in range(maxi(int(lo.x), 0), mini(int(hi.x), image.get_width())):
			var p := Vector2(x + 0.5, y + 0.5)
			if _inside(p, pa, pb, winding) and _inside(p, pb, pc, winding) and _inside(p, pc, pa, winding):
				image.set_pixel(x, y, Color(1, 1, 1, 1))


func _inside(p: Vector2, a: Vector2, b: Vector2, winding: float) -> bool:
	var edge := b - a
	var length := edge.length()
	if length < 1e-9:
		return true
	return edge.cross(p - a) * winding / length >= -0.5

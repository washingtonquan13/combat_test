extends SceneTree
## Bakes the covers masks of a CC clothed export: for each garment, the skin
## it hides, as CCLook.wear() hands it to the skin (cc_skin.gdshaderinc's
## covers, one strip over the body's UV tiles).
##
## CC exported the clothed base with its hidden skin removed, so the skin a
## garment hides is the base body's triangles missing from the export's
## body: those with a vertex the export lacks (by place, not triangle: the
## export splits some quads along the other diagonal). Each goes to the
## garment nearest it, and to any other within
## SHARED_BY of that: skin under a shirt tucked into trousers is hidden by
## either. Run with a renderer (the headless one keeps no mesh arrays):
##
##   godot --path . -s tools/characters/cc_covers.gd
##
## Writes <clothes dir>/covers/<part>.png beside each export in BODIES.

## Base FBX -> its clothed export (CCLook.clothes_scene).
const BODIES := {
	"res://assets/characters/cc/male/cc_base_male.fbx": "res://assets/characters/cc/clothes/clothed_male/cc_clothed_male.fbx",
	"res://assets/characters/cc/female/cc_base_female.fbx": "res://assets/characters/cc/clothes/clothed_female/cc_clothed_female.fbx",
}
## Pixels per UV tile, each way.
const TILE := 512
## Metres: a vertex this near another is the same vertex.
const SAME := 0.0005
const SHARED_BY := 0.015
## Metres: skin farther than this from every garment is hidden by none.
const REACH := 0.1
const CELL := 0.02


func _init() -> void:
	for base in BODIES:
		_bake(base, BODIES[base])
	quit()


func _bake(base_path: String, clothes_path: String) -> void:
	var base: Node = load(base_path).instantiate()
	var clothes: Node = load(clothes_path).instantiate()
	var body: MeshInstance3D = CCMaterials._body(base)
	var cbody: MeshInstance3D = null
	var garments := {}
	for m: MeshInstance3D in clothes.find_children("*", "MeshInstance3D", true, false):
		var n := String(m.name).to_lower()
		if n == "cc_base_body":
			cbody = m
		elif not n.begins_with("cc_base") and not n in CCLook.UNDERWEAR:
			garments[n] = m
	var shift := CCMaterials.garment_offset(cbody.skin, body.skin)
	print("%s: shift %s, garments %s" % [clothes_path.get_file(), shift, garments.keys()])

	# The export's body vertices, in cells.
	var kept := {}
	for s in cbody.mesh.get_surface_count():
		for v: Vector3 in cbody.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			kept[Vector3i(((v + shift) / SAME).round())] = true
	# Each garment's vertices, in cells.
	var grids := {}
	for n in garments:
		var g := {}
		for s in garments[n].mesh.get_surface_count():
			for v: Vector3 in garments[n].mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				var p := v + shift
				var k := Vector3i((p / CELL).floor())
				if not g.has(k):
					g[k] = PackedVector3Array()
				g[k].append(p)
		grids[n] = g

	var images := {}
	for n in garments:
		images[n] = Image.create(TILE * int(CCLook.COVERS_TILES), TILE, false, Image.FORMAT_LA8)
	var hidden := 0
	var counts := {}
	for t in _triangles(body.mesh, Vector3.ZERO):
		var c: Vector3 = t[3]
		if _kept(kept, t[0]) and _kept(kept, t[1]) and _kept(kept, t[2]):
			continue
		hidden += 1
		var near := {}
		var nearest := INF
		for n in garments:
			near[n] = _distance(grids[n], c)
			nearest = min(nearest, near[n])
		if nearest > REACH:
			continue
		for n in garments:
			if near[n] <= nearest + SHARED_BY:
				_fill(images[n], t[4], t[5], t[6])
				counts[n] = counts.get(n, 0) + 1
	var dir := clothes_path.get_base_dir().path_join("covers")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for n in images:
		var path := dir.path_join(n + ".png")
		images[n].save_png(ProjectSettings.globalize_path(path))
		print("  %s: %d triangles -> %s" % [n, counts.get(n, 0), path])
	print("  %d of the base's triangles hidden" % hidden)
	base.free()
	clothes.free()


## Whether the export's body has a vertex at c (within SAME, across a
## rounding edge).
func _kept(kept: Dictionary, c: Vector3) -> bool:
	var k := c / SAME
	for x in [floor(k.x), ceil(k.x)]:
		for y in [floor(k.y), ceil(k.y)]:
			for z in [floor(k.z), ceil(k.z)]:
				if kept.has(Vector3i(x, y, z)):
					return true
	return false


## [a, b, c, centroid, uv_a, uv_b, uv_c] per triangle, positions shifted.
func _triangles(mesh: Mesh, shift: Vector3) -> Array:
	var out := []
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		for i in range(0, idx.size(), 3):
			var p0 := v[idx[i]] + shift
			var p1 := v[idx[i + 1]] + shift
			var p2 := v[idx[i + 2]] + shift
			out.append([p0, p1, p2, (p0 + p1 + p2) / 3.0, uv[idx[i]], uv[idx[i + 1]], uv[idx[i + 2]]])
	return out


## Metres from p to the nearest point in grid, or INF past REACH.
func _distance(grid: Dictionary, p: Vector3) -> float:
	var c := Vector3i((p / CELL).floor())
	var r := int(ceil(REACH / CELL))
	var best := INF
	for x in range(-r, r + 1):
		for y in range(-r, r + 1):
			for z in range(-r, r + 1):
				for q in grid.get(c + Vector3i(x, y, z), PackedVector3Array()):
					best = min(best, p.distance_squared_to(q))
	return sqrt(best)


## Paints a UV triangle opaque, half a pixel wider all round so triangles
## sharing an edge leave no crack.
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


## Whether p is on the inner side of edge a->b, or within half a pixel of it.
func _inside(p: Vector2, a: Vector2, b: Vector2, winding: float) -> bool:
	var edge := b - a
	var length := edge.length()
	if length < 1e-9:
		return true
	return edge.cross(p - a) * winding / length >= -0.5


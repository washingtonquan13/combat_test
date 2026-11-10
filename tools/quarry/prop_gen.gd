extends RefCounted

# Procedural village and camp props for the quarry bake: timber-frame cottages,
# a fence, a well, a cart, a dry-stone wall, tents and crates, built from boxes,
# prisms and cylinders and textured with Poly Haven sets.
#
# Each prop fills the box the blockout gave it (origin at the box centre, the
# box bottom at -size.y / 2) so the blockout's collision, and with it the nav
# grid and cover, stay as they were. Roofs and chimneys may rise above the box;
# nothing reaches past its footprint, except foundations, which go below it to
# meet ground that falls away.
#
# UVs are in metres divided by each material's tile size, so texel density is
# the same on a crate and a house wall.

const T := "res://assets/level/quarry/textures/"

# key: [texture set, metres per repeat, tint]
const SETS := {
	"planks": ["weathered_brown_planks", 2.0, Color(1, 1, 1)],
	"beam": ["weathered_brown_planks", 2.0, Color(0.5, 0.42, 0.36)],
	"roof": ["grey_roof_tiles_02", 2.6, Color(1, 1, 1)],
	"plaster": ["white_rough_plaster", 2.5, Color(0.93, 0.89, 0.8)],
	"stone": ["rustic_stone_wall_02", 2.2, Color(1, 1, 1)],
	"canvas": ["hessian_230", 1.2, Color(1, 0.95, 0.85)],
}

var rng := RandomNumberGenerator.new()
var _mats := {}
var _st := {}
var _root := Basis.IDENTITY


func material(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m: BaseMaterial3D
	if SETS.has(key):
		var s: Array = SETS[key]
		var o := ORMMaterial3D.new()
		o.albedo_texture = load(T + s[0] + "_diff_2k.jpg")
		o.albedo_color = s[2]
		o.normal_enabled = true
		o.normal_texture = load(T + s[0] + "_nor_gl_2k.jpg")
		o.orm_texture = load(T + s[0] + "_arm_2k.jpg")
		o.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		m = o
	else:
		m = StandardMaterial3D.new()
		match key:
			"dark":
				m.albedo_color = Color(0.035, 0.03, 0.028)
				m.roughness = 1.0
			"water":
				m.albedo_color = Color(0.02, 0.035, 0.035)
				m.roughness = 0.08
			"glass":
				m.albedo_color = Color(0.06, 0.07, 0.07)
				m.roughness = 0.25
	_mats[key] = m
	return m


# ---------------------------------------------------------------- primitives

func _surf(key: String) -> SurfaceTool:
	if not _st.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[key] = st
	return _st[key]


func _tile(key: String) -> float:
	return SETS[key][1] if SETS.has(key) else 1.0


## A flat convex polygon. `u` is the direction the texture's U runs along.
func face(key: String, pts: Array, n: Vector3, u: Vector3, off := Vector2.ZERO) -> void:
	var st := _surf(key)
	var nn := (_root * n).normalized()
	var uu := (_root * u).normalized()
	var vv := nn.cross(uu)
	var tile := _tile(key)
	var p: Array[Vector3] = []
	for q: Vector3 in pts:
		p.append(_root * q)
	var flip := (p[1] - p[0]).cross(p[2] - p[0]).dot(nn) > 0.0
	for i in range(1, p.size() - 1):
		var tri := [p[0], p[i + 1], p[i]] if flip else [p[0], p[i], p[i + 1]]
		for q: Vector3 in tri:
			st.set_normal(nn)
			st.set_uv(Vector2(q.dot(uu), -q.dot(vv)) / tile + off)
			st.add_vertex(q)


## A box of `size` placed by `xf`. Texture U follows `grain` (0 x, 1 y, 2 z)
## where it lies in a face; by default the longest axis.
func box(key: String, xf: Transform3D, size: Vector3, grain := -1) -> void:
	if grain < 0:
		grain = 0
		for a in 3:
			if size[a] > size[grain]:
				grain = a
	var h := size * 0.5
	var off := Vector2(rng.randf(), rng.randf())
	for axis in 3:
		var a := (axis + 1) % 3
		var b := (axis + 2) % 3
		var ua := grain if grain != axis else (0 if axis != 0 else 2)
		if ua == 1 and axis != 1 and grain != 1:
			ua = a if a != 1 else b
		var va := a if ua == b else b
		for sgn in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = sgn
			var eu := Vector3.ZERO
			eu[ua] = 1.0
			var ev := Vector3.ZERO
			ev[va] = 1.0
			var c := n * h[axis]
			var pts := []
			for s: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				pts.append(xf * (c + eu * s.x * h[ua] + ev * s.y * h[va]))
			face(key, pts, xf.basis * n, xf.basis * eu, off)


## A prism along local Y: `segs` sides of radius r, height h, centred.
func cyl(key: String, xf: Transform3D, r: float, h: float, segs := 10, caps := true) -> void:
	var off := Vector2(rng.randf(), rng.randf())
	var ring: Array[Vector3] = []
	for i in segs:
		var a := TAU * i / segs
		ring.append(Vector3(cos(a) * r, 0, sin(a) * r))
	for i in segs:
		var p0 := ring[i]
		var p1 := ring[(i + 1) % segs]
		var mid := ((p0 + p1) * 0.5).normalized()
		var q := [xf * (p0 + Vector3.DOWN * h * 0.5), xf * (p1 + Vector3.DOWN * h * 0.5),
				xf * (p1 + Vector3.UP * h * 0.5), xf * (p0 + Vector3.UP * h * 0.5)]
		face(key, q, xf.basis * mid, xf.basis * (p1 - p0), off)
	if caps:
		for sgn in [-1.0, 1.0]:
			var pts := []
			for p in ring:
				pts.append(xf * (p + Vector3.UP * h * 0.5 * sgn))
			face(key, pts, xf.basis * Vector3.UP * sgn, xf.basis * Vector3.RIGHT, off)


func _xf(at: Vector3, yaw := 0.0, pitch := 0.0, roll := 0.0) -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(pitch, yaw, roll)), at)


## A beam from a to b with a square section, grain along its length.
func beam(key: String, a: Vector3, b: Vector3, w: float, d := -1.0) -> void:
	var dir := b - a
	var y := dir.normalized()
	var x := Vector3.UP.cross(y)
	if x.length() < 0.01:
		x = Vector3.RIGHT
	x = x.normalized()
	var z := x.cross(y)
	box(key, Transform3D(Basis(x, y, z), (a + b) * 0.5), Vector3(w, dir.length(), w if d < 0 else d), 1)


func commit(yaw := 0.0) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for key: String in _st:
		var st: SurfaceTool = _st[key]
		st.index()
		st.generate_tangents()
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material(key))
	_st.clear()
	_root = Basis.IDENTITY
	return mesh


# ---------------------------------------------------------------- props

## Turns everything that follows by `yaw` (a multiple of 90 degrees), so a
## prop built facing +Z can face any side of its box.
func _face_to(yaw_deg: float) -> void:
	_root = Basis(Vector3.UP, deg_to_rad(yaw_deg))


## A cottage filling `size`, front door facing `yaw_deg` (0 = +Z). Built with
## the ridge along X and the door on the +Z side, then turned.
func cottage(size: Vector3, yaw_deg: float, plaster: bool, seed: int) -> ArrayMesh:
	rng.seed = seed
	_face_to(yaw_deg)
	var turned := int(round(yaw_deg / 90.0)) % 2 != 0
	var L := size.z if turned else size.x
	var Wd := size.x if turned else size.z
	var y0 := -size.y * 0.5
	var inset := 0.35
	var plinth := y0 + 0.55
	var top := y0 + clampf(size.y - 0.9, 2.9, 3.7)
	var hx := L * 0.5 - inset
	var hz := Wd * 0.5 - inset
	var pitch := minf(deg_to_rad(38.0), atan(2.3 / (Wd * 0.5)))
	var rise := hz * tan(pitch)
	var ridge := top + rise

	# Stone plinth, going down to meet a falling slope.
	box("stone", _xf(Vector3(0, (y0 - 0.9 + plinth) * 0.5, 0)), Vector3(hx * 2 + 0.16, plinth - y0 + 0.9, hz * 2 + 0.16))
	# Walls.
	box("plaster" if plaster else "planks", _xf(Vector3(0, (plinth + top) * 0.5, 0)), Vector3(hx * 2, top - plinth, hz * 2), 0 if not plaster else -1)
	# Gable ends.
	for sx in [-1.0, 1.0]:
		var x: float = sx * hx
		var tri := [Vector3(x, top, -hz), Vector3(x, top, hz), Vector3(x, ridge, 0)]
		face("plaster" if plaster else "planks", tri, Vector3(sx, 0, 0), Vector3(0, 0, 1))

	# Roof: two slabs from the ridge out to the footprint's edge.
	var reach := Wd * 0.5
	var drop := reach * tan(pitch)
	var slope := Vector2(reach, drop).length() + 0.12
	var th := 0.14
	for sz in [-1.0, 1.0]:
		var ang: float = sz * pitch
		var n := Vector3(0, cos(pitch), sz * sin(pitch))
		var mid := Vector3(0, ridge - drop * 0.5, sz * reach * 0.5) + n * th * 0.5
		box("roof", Transform3D(Basis(Vector3.RIGHT, ang), mid), Vector3(L, th, slope), 0)
		# Barge boards along the gable edges.
		for sx in [-1.0, 1.0]:
			beam("beam", Vector3(sx * (L * 0.5 - 0.06), ridge + 0.05, 0), Vector3(sx * (L * 0.5 - 0.06), ridge - drop + 0.05, sz * reach), 0.1, 0.22)
	beam("beam", Vector3(-L * 0.5, ridge + th + 0.04, 0), Vector3(L * 0.5, ridge + th + 0.04, 0), 0.2)

	# Door on the front, windows either side, more round the back and on one gable.
	var door_x := rng.randf_range(-0.4, 0.4) * (hx - 1.6)
	var opens: Array = []  # [face, u centre, width, bottom, top]
	opens.append(["front", door_x, 1.05, plinth, plinth + 1.95])
	var sill := plinth + 0.95
	for wx in [door_x - 1.7, door_x + 1.7]:
		if absf(wx) < hx - 0.7:
			opens.append(["front", wx, 0.8, sill, sill + 0.85])
	for i in maxi(1, int(L / 3.2)):
		var bx := lerpf(-hx + 1.2, hx - 1.2, (i + 0.5) / maxi(1, int(L / 3.2)))
		opens.append(["back", bx, 0.8, sill, sill + 0.85])
	opens.append(["east", 0.0, 0.8, sill, sill + 0.85])
	if top - plinth > 3.0:
		opens.append(["east", 0.0, 0.6, ridge - rise * 0.75, ridge - rise * 0.75 + 0.6])

	for o: Array in opens:
		_opening(o, hx, hz, o == opens[0])

	if plaster:
		_timber_frame(opens, hx, hz, plinth, top, ridge)
	else:
		for cx in [-1.0, 1.0]:
			for cz in [-1.0, 1.0]:
				beam("beam", Vector3(cx * hx, plinth, cz * hz), Vector3(cx * hx, top, cz * hz), 0.24)
	# Step in front of the door.
	box("stone", _xf(Vector3(door_x, plinth - 0.1, hz + 0.2), rng.randf_range(-0.05, 0.05)), Vector3(1.3, 0.3, 0.36))

	# Chimney on the west gable, half in the wall.
	var cz := rng.randf_range(-0.3, 0.3) * hz
	var cx0 := -L * 0.5 + 0.45
	box("stone", _xf(Vector3(cx0, (plinth + ridge + 0.9) * 0.5, cz)), Vector3(0.9, ridge + 0.9 - plinth, 0.9), 1)
	box("stone", _xf(Vector3(cx0, ridge + 0.95, cz)), Vector3(1.0, 0.14, 1.0))
	box("dark", _xf(Vector3(cx0, ridge + 1.025, cz)), Vector3(0.5, 0.02, 0.5))
	return commit()


## Where an opening sits: a point on the wall surface and the wall's outward axes.
func _wall_frame(face_name: String, u: float, hx: float, hz: float) -> Array:
	match face_name:
		"front":
			return [Vector3(u, 0, hz), Vector3(0, 0, 1), Vector3(1, 0, 0)]
		"back":
			return [Vector3(-u, 0, -hz), Vector3(0, 0, -1), Vector3(-1, 0, 0)]
		_:
			return [Vector3(hx, 0, -u), Vector3(1, 0, 0), Vector3(0, 0, -1)]


func _opening(o: Array, hx: float, hz: float, is_door: bool) -> void:
	var f := _wall_frame(o[0], o[1], hx, hz)
	var at: Vector3 = f[0]
	var n: Vector3 = f[1]
	var t: Vector3 = f[2]
	var w: float = o[2]
	var b: float = o[3]
	var top: float = o[4]
	var h := top - b
	var yaw := atan2(n.x, n.z)
	var c := at + Vector3.UP * (b + h * 0.5)
	if is_door:
		box("dark", _xf(c + n * 0.01, yaw), Vector3(w, h, 0.02))
		# Planked leaf, ajar.
		var hinge := c - t * w * 0.5 + n * 0.04
		var swing := deg_to_rad(rng.randf_range(15.0, 40.0))
		var leaf := Basis(Vector3.UP, yaw - swing)
		box("planks", Transform3D(leaf, hinge + leaf * Vector3(w * 0.47, 0, 0.03)), Vector3(w * 0.94, h - 0.04, 0.06), 1)
		for ly in [-0.6, 0.6]:
			box("beam", Transform3D(leaf, hinge + leaf * Vector3(w * 0.47, ly, 0.08)), Vector3(w * 0.9, 0.12, 0.04))
	else:
		box("glass", _xf(c + n * 0.015, yaw), Vector3(w, h, 0.02))
		box("beam", _xf(c + n * 0.06, yaw), Vector3(0.06, h, 0.04))
		box("beam", _xf(c + n * 0.06, yaw), Vector3(w, 0.06, 0.04))
		box("beam", _xf(at + Vector3.UP * b + n * 0.09 + Vector3.DOWN * 0.04, yaw), Vector3(w + 0.3, 0.08, 0.2))
		# Shutters, swung back against the wall at a slight angle.
		for s in [-1.0, 1.0]:
			var hinge: Vector3 = c + t * s * (w * 0.5 + 0.08) + n * 0.05
			var open := deg_to_rad(rng.randf_range(150.0, 172.0))
			var bs := Basis(Vector3.UP, yaw - s * (PI - open))
			box("planks", Transform3D(bs, hinge + bs * Vector3(s * w * 0.25, 0, 0.02)), Vector3(w * 0.5, h, 0.04), 1)
	# Frame: posts and a lintel.
	for s in [-1.0, 1.0]:
		beam("beam", at + t * s * (w * 0.5 + 0.06) + Vector3.UP * (b - (0.0 if is_door else 0.08)) + n * 0.05,
				at + t * s * (w * 0.5 + 0.06) + Vector3.UP * (top + 0.08) + n * 0.05, 0.12)
	box("beam", _xf(at + Vector3.UP * (top + 0.1) + n * 0.06, yaw), Vector3(w + 0.44, 0.16, 0.14))


## Oak framing proud of the plaster: sill, plate and corner posts, posts beside
## openings, a mid rail broken by them, and braces in the clear bays.
func _timber_frame(opens: Array, hx: float, hz: float, y0: float, y1: float, ridge: float) -> void:
	var proud := 0.05
	var w := 0.17
	for fname: String in ["front", "back", "east", "west"]:
		var span := hz if fname in ["east", "west"] else hx
		var f := _wall_frame(fname if fname != "west" else "east", 0.0, hx, hz)
		var at: Vector3 = f[0]
		var n: Vector3 = f[1]
		var t: Vector3 = f[2]
		if fname == "west":
			at = Vector3(-hx, 0, 0)
			n = Vector3(-1, 0, 0)
			t = Vector3(0, 0, 1)
		var o0 := at + n * proud
		beam("beam", o0 + t * -span + Vector3.UP * (y0 + w * 0.5), o0 + t * span + Vector3.UP * (y0 + w * 0.5), w)
		beam("beam", o0 + t * -span + Vector3.UP * (y1 - w * 0.5), o0 + t * span + Vector3.UP * (y1 - w * 0.5), w)
		var posts: Array[float] = [-span + w * 0.5, span - w * 0.5]
		var holes: Array = []
		for o: Array in opens:
			if o[0] == fname:
				var u: float = o[1]
				holes.append([u - o[2] * 0.5 - 0.15, u + o[2] * 0.5 + 0.15])
				posts.append(u - o[2] * 0.5 - 0.15)
				posts.append(u + o[2] * 0.5 + 0.15)
		posts.sort()
		# Fill wide bays with an extra post.
		var extra: Array[float] = []
		for i in posts.size() - 1:
			var gap := posts[i + 1] - posts[i]
			var inside := false
			for hh: Array in holes:
				if posts[i] >= hh[0] - 0.01 and posts[i + 1] <= hh[1] + 0.01:
					inside = true
			if gap > 2.2 and not inside:
				extra.append((posts[i] + posts[i + 1]) * 0.5)
		posts.append_array(extra)
		posts.sort()
		for u in posts:
			beam("beam", o0 + t * u + Vector3.UP * (y0 + w), o0 + t * u + Vector3.UP * (y1 - w), w)
		var mid := y0 + 1.0
		for i in posts.size() - 1:
			var a := posts[i]
			var b := posts[i + 1]
			if b - a < 0.4:
				continue
			var blocked := false
			for hh: Array in holes:
				if a < hh[1] - 0.01 and b > hh[0] + 0.01:
					blocked = true
			if blocked:
				continue
			beam("beam", o0 + t * a + Vector3.UP * mid, o0 + t * b + Vector3.UP * mid, w * 0.8)
			# A brace in the upper half of clear bays, leaning toward the nearer corner.
			if b - a > 0.9:
				var lean := 1.0 if (a + b) < 0.0 else -1.0
				var lo := o0 + n * 0.01 + t * (a if lean < 0 else b) + Vector3.UP * (mid + w * 0.4)
				var hi := o0 + n * 0.01 + t * (b if lean < 0 else a) + Vector3.UP * (y1 - w)
				beam("beam", lo, hi, w * 0.75)
		# King post up each gable.
		if fname in ["east", "west"]:
			beam("beam", o0 + Vector3.UP * y1, o0 + Vector3.UP * (ridge - 0.1), w)


func fence(size: Vector3, seed: int) -> ArrayMesh:
	rng.seed = seed
	var y0 := -size.y * 0.5
	var hx := size.x * 0.5 - 0.08
	var count := int(ceil(size.x / 1.5)) + 1
	var tops: Array[Vector3] = []
	for i in count:
		var x := lerpf(-hx, hx, float(i) / (count - 1))
		var h := y0 + size.y * rng.randf_range(0.95, 1.08)
		var tilt := rng.randf_range(-0.05, 0.05)
		box("beam", _xf(Vector3(x, (y0 - 0.3 + h) * 0.5, 0), rng.randf_range(-0.3, 0.3), tilt, rng.randf_range(-0.04, 0.04)), Vector3(0.13, h - y0 + 0.3, 0.13), 1)
		tops.append(Vector3(x, h, 0))
	for ry in [0.38, 0.78]:
		for i in count - 1:
			var a := Vector3(tops[i].x - 0.05, y0 + ry * size.y + rng.randf_range(-0.04, 0.04), 0.09)
			var b := Vector3(tops[i + 1].x + 0.05, y0 + ry * size.y + rng.randf_range(-0.04, 0.04), 0.09)
			beam("planks", a, b, 0.05, 0.14)
	return commit()


func well(radius: float, height: float, seed: int) -> ArrayMesh:
	rng.seed = seed
	var y0 := -height * 0.5
	var stones := 16
	for course in 4:
		var ch := (height + 0.25) / 4.0
		var cy := y0 - 0.2 + ch * (course + 0.5)
		for i in stones:
			var a := TAU * (i + 0.5 * (course % 2)) / stones
			var r := radius - 0.17
			var len := TAU * r / stones + 0.06
			box("stone", _xf(Vector3(cos(a) * r, cy, sin(a) * r), -a + PI * 0.5 + rng.randf_range(-0.04, 0.04), rng.randf_range(-0.03, 0.03)),
					Vector3(len, ch - 0.02, 0.34))
	# Cap stones.
	for i in stones:
		var a := TAU * (i + 0.25) / stones
		var r := radius - 0.16
		box("stone", _xf(Vector3(cos(a) * r, y0 + height + 0.06, sin(a) * r), -a + PI * 0.5, 0, rng.randf_range(-0.04, 0.04)),
				Vector3(TAU * r / stones + 0.04, 0.12, 0.4))
	cyl("water", _xf(Vector3(0, y0 + 0.25, 0)), radius - 0.32, 0.02, 16)
	cyl("dark", _xf(Vector3(0, y0 + 0.6, 0)), radius - 0.33, 0.7, 16, false)
	# Posts, windlass and a little roof.
	var top := y0 + 2.3
	for s in [-1.0, 1.0]:
		beam("beam", Vector3(s * (radius - 0.16), y0 + height, 0), Vector3(s * (radius - 0.16), top, 0), 0.15)
	cyl("beam", Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(0, y0 + 1.75, 0)), 0.09, radius * 2 - 0.3, 8)
	beam("planks", Vector3(radius - 0.12, y0 + 1.75, 0.0), Vector3(radius - 0.12, y0 + 1.5, 0.3), 0.05)
	beam("dark", Vector3(0, y0 + 1.7, 0.09), Vector3(0, y0 + 1.25, 0.09), 0.015)
	cyl("planks", _xf(Vector3(0, y0 + 1.1, 0.09)), 0.16, 0.3, 8)
	for sz in [-1.0, 1.0]:
		box("planks", Transform3D(Basis(Vector3.RIGHT, sz * deg_to_rad(35.0)), Vector3(0, top + 0.23, sz * 0.34)), Vector3(radius * 2 + 0.1, 0.06, 0.85), 0)
	beam("beam", Vector3(-radius - 0.05, top + 0.47, 0), Vector3(radius + 0.05, top + 0.47, 0), 0.1)
	return commit()


func cart(size: Vector3, seed: int) -> ArrayMesh:
	rng.seed = seed
	var y0 := -size.y * 0.5
	var bed := y0 + 0.62
	var hx := size.x * 0.5 - 0.3
	var z0 := -size.z * 0.5 + 0.05
	var z1 := size.z * 0.5 - 0.7
	var bz := (z0 + z1) * 0.5
	box("planks", _xf(Vector3(0, bed, bz)), Vector3(hx * 2, 0.07, z1 - z0), 2)
	for s in [-1.0, 1.0]:
		box("planks", _xf(Vector3(s * (hx - 0.03), bed + 0.22, bz)), Vector3(0.06, 0.38, z1 - z0), 2)
		beam("beam", Vector3(s * (hx - 0.1), bed - 0.08, z0), Vector3(s * 0.32, y0 + 0.05, size.z * 0.5 - 0.02), 0.09)
		for z in [z0 + 0.05, bz, z1 - 0.05]:
			beam("beam", Vector3(s * (hx + 0.01), bed, z), Vector3(s * (hx + 0.01), bed + 0.45, z), 0.08)
	for z in [z0 + 0.03, z1 - 0.03]:
		box("planks", _xf(Vector3(0, bed + 0.22, z)), Vector3(hx * 2, 0.38, 0.06), 0)
	box("beam", _xf(Vector3(0, bed - 0.07, bz - 0.2)), Vector3(hx * 2 + 0.4, 0.1, 0.1))
	# Wheels: rim, hub and spokes.
	var r := 0.55
	for s in [-1.0, 1.0]:
		var c := Vector3(s * (size.x * 0.5 - 0.1), y0 + r + 0.02, bz - 0.2)
		var spin := rng.randf() * TAU
		var axle := Basis(Vector3.BACK, PI * 0.5)
		cyl("beam", Transform3D(axle, c), 0.1, 0.22, 8)
		for i in 12:
			var a0 := spin + TAU * i / 12.0
			var a1 := spin + TAU * (i + 1) / 12.0
			beam("beam", c + Vector3(0, sin(a0), cos(a0)) * (r - 0.05), c + Vector3(0, sin(a1), cos(a1)) * (r - 0.05), 0.1, 0.09)
		for i in 6:
			var a := spin + TAU * i / 6.0
			beam("beam", c, c + Vector3(0, sin(a), cos(a)) * (r - 0.08), 0.05)
	# A load: sacks and a crate.
	for i in 3:
		var at := Vector3(rng.randf_range(-0.3, 0.3), bed + 0.17, z0 + 0.45 + i * 0.48)
		cyl("canvas", Transform3D(Basis(Vector3.BACK, PI * 0.5).rotated(Vector3.UP, rng.randf_range(-0.4, 0.4)).scaled(Vector3(1, 1, 0.8)), at), 0.2, 0.55, 8)
	box("planks", _xf(Vector3(0.1, bed + 0.3, z1 - 0.45), 0.2), Vector3(0.55, 0.5, 0.5))
	return commit()


func low_wall(size: Vector3, seed: int) -> ArrayMesh:
	rng.seed = seed
	var y0 := -size.y * 0.5
	var hx := size.x * 0.5
	var top := y0 + size.y * 0.86
	box("stone", _xf(Vector3(0, (y0 - 0.5 + top) * 0.5, 0)), Vector3(size.x - 0.1, top - y0 + 0.5, size.z - 0.12), 0)
	# Cap stones set on edge, uneven.
	var x := -hx + 0.08
	while x < hx - 0.15:
		var w := minf(rng.randf_range(0.14, 0.26), hx - 0.06 - x)
		var h := rng.randf_range(0.14, 0.24)
		box("stone", _xf(Vector3(x + w * 0.5, top + h * 0.5 - 0.03, rng.randf_range(-0.02, 0.02)), rng.randf_range(-0.08, 0.08), 0, rng.randf_range(-0.2, 0.2)),
				Vector3(w, h, size.z - rng.randf_range(0.04, 0.12)), 1)
		x += w + 0.01
	return commit()


func tent(size: Vector3, yaw_deg: float, seed: int) -> ArrayMesh:
	rng.seed = seed
	_face_to(yaw_deg)
	var y0 := -size.y * 0.5
	var hx := size.x * 0.5 - 0.1
	var hz := size.z * 0.5 - 0.1
	var ridge := y0 + size.y - 0.08
	var pitch := atan2(ridge - y0, hx)
	var slope := Vector2(hx, ridge - y0).length()
	for s in [-1.0, 1.0]:
		var n := Vector3(s * sin(pitch), cos(pitch), 0)
		var mid := Vector3(s * hx * 0.5, (ridge + y0) * 0.5, 0) + n * 0.02
		box("canvas", Transform3D(Basis(Vector3.BACK, -s * pitch), mid), Vector3(slope + 0.06, 0.03, hz * 2), 2)
	# Back closed, front a dark doorway between two tied-back flaps.
	var back := [Vector3(-hx, y0, -hz), Vector3(hx, y0, -hz), Vector3(0, ridge, -hz)]
	face("canvas", back, Vector3(0, 0, -1), Vector3(1, 0, 0))
	face("canvas", back, Vector3(0, 0, 1), Vector3(1, 0, 0))
	face("dark", [Vector3(-hx * 0.98, y0, hz - 0.3), Vector3(hx * 0.98, y0, hz - 0.3), Vector3(0, ridge - 0.02, hz - 0.3)], Vector3(0, 0, 1), Vector3(1, 0, 0))
	for s in [-1.0, 1.0]:
		var flap := [Vector3(s * hx, y0, hz), Vector3(s * hx * 0.45, y0, hz + 0.02), Vector3(0, ridge, hz)]
		face("canvas", flap, Vector3(0, 0, 1), Vector3(1, 0, 0))
		face("canvas", flap, Vector3(0, 0, -1), Vector3(1, 0, 0))
	for z in [-hz - 0.02, hz + 0.04]:
		beam("beam", Vector3(0, y0 - 0.1, z), Vector3(0, ridge + 0.12, z), 0.07)
	beam("beam", Vector3(0, ridge + 0.03, -hz - 0.05), Vector3(0, ridge + 0.03, hz + 0.07), 0.06)
	return commit()


func crate(size: Vector3, seed: int) -> ArrayMesh:
	rng.seed = seed
	var y0 := -size.y * 0.5
	if size.z > size.x * 1.5:
		# Two crates side by side, the second a little turned and smaller.
		var l := size.z * 0.5 - 0.04
		_one_crate(Vector3(0, y0, -size.z * 0.25), Vector3(size.x - 0.04, size.y - 0.02, l), 0.0)
		_one_crate(Vector3(0.02, y0, size.z * 0.25), Vector3(size.x - 0.2, size.y - 0.15, l - 0.18), rng.randf_range(0.06, 0.12))
	else:
		_one_crate(Vector3(0, y0, 0), size - Vector3(0.03, 0.02, 0.03), rng.randf_range(-0.05, 0.05))
	return commit()


func _one_crate(base: Vector3, s: Vector3, yaw: float) -> void:
	var b := Basis(Vector3.UP, yaw)
	var c := base + Vector3.UP * s.y * 0.5
	box("planks", Transform3D(b, c), s - Vector3(0.06, 0.06, 0.06), 0)
	var e := 0.09
	var h := s * 0.5 - Vector3(e, e, e) * 0.5
	for i in 2:
		for j in 2:
			var sx := -1.0 if i == 0 else 1.0
			var sy := -1.0 if j == 0 else 1.0
			box("beam", Transform3D(b, c + b * Vector3(0, sx * h.y, sy * h.z)), Vector3(s.x, e, e), 0)
			box("beam", Transform3D(b, c + b * Vector3(sx * h.x, 0, sy * h.z)), Vector3(e, s.y - 2 * e, e), 1)
			box("beam", Transform3D(b, c + b * Vector3(sx * h.x, sy * h.y, 0)), Vector3(e, e, s.z - 2 * e), 2)
	# Diagonal braces on the two long faces.
	for sz in [-1.0, 1.0]:
		var p0 := c + b * Vector3(-h.x + e * 0.5, -h.y + e * 0.5, sz * (h.z + 0.012))
		var p1 := c + b * Vector3(h.x - e * 0.5, h.y - e * 0.5, sz * (h.z + 0.012))
		beam("beam", p0, p1, 0.03, e * 0.8)

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
const SHADER := "res://assets/level/quarry/weathered.gdshader"

# key: [texture set, metres per repeat, tint]
const SETS := {
	"planks": ["weathered_brown_planks", 2.0, Color(1, 1, 1)],
	"beam": ["weathered_brown_planks", 2.0, Color(0.6, 0.5, 0.42)],
	"roof": ["grey_roof_tiles_02", 2.6, Color(0.74, 0.75, 0.78)],
	"plaster": ["white_rough_plaster", 2.5, Color(0.82, 0.76, 0.65)],
	"stone": ["rustic_stone_wall_02", 2.2, Color(1, 1, 1)],
	"canvas": ["hessian_230", 1.2, Color(1, 0.95, 0.85)],
}

var rng := RandomNumberGenerator.new()
var _mats := {}
var _st := {}
var _root := Basis.IDENTITY

# Weathering context, set per prop and cleared by commit(). Heights are local.
var _ground := -1e9      # grime rises from here
var _eave := 1e9         # vertical faces just under this sit in the eave's shade
var _ao := 1.0           # occlusion forced on what is drawn while it is below 1
var _moss := 1.0         # scales the moss mask (stone and roofs keep it, beams less)
# Deformation, applied to positions after UVs are taken so textures don't swim.
var _lean := Vector2.ZERO  # x, z drift per metre above _lean_from
var _lean_from := 0.0
var _sag := 0.0          # ridge sag at mid-length, fading out toward the eaves
var _sag_half := 1.0     # half-length the sag spans
var _sag_from := 1e9     # sag starts above this height
var _sag_to := 1e9       # and is full at this height
var _jitter := 0.0       # beam ends wander by up to this much
var bevel := 0.0         # chamfer on box edges, capped by the box's size
var _blk := Transform3D.IDENTITY  # frame of the building block being drawn, inside the prop

# Walk-in cottages. Set `interior` before cottage(): walls get thickness, an
# inside face and collision, the floor is planked, doors are full height with
# stairs, and roof, gables and gable windows go to `roof_mesh` instead, so the
# building can stop drawing them while someone is inside.
const WALL := 0.22
var interior := false
var roof_mesh: ArrayMesh   # set by commit(), null when nothing went to the roof
var colliders: Array = []  # [Transform3D, size] boxes in prop space
var rooms: Array[AABB] = []  # each block's inside, prop space
var _st_roof := {}
var _to_roof := false


func material(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	if SETS.has(key):
		var s: Array = SETS[key]
		var sm := ShaderMaterial.new()
		sm.shader = load(SHADER)
		sm.set_shader_parameter("albedo_tex", load(T + s[0] + "_diff_2k.jpg"))
		sm.set_shader_parameter("normal_tex", load(T + s[0] + "_nor_gl_2k.jpg"))
		sm.set_shader_parameter("orm_tex", load(T + s[0] + "_arm_2k.jpg"))
		var c: Color = s[2]
		sm.set_shader_parameter("tint", c)
		_mats[key] = sm
		return sm
	var m := StandardMaterial3D.new()
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
	var d := _st_roof if _to_roof else _st
	if not d.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		d[key] = st
	return d[key]


## A collision box placed by `xf` in the current block's frame (walk-in only).
func _collide(xf: Transform3D, size: Vector3) -> void:
	if interior:
		colliders.append([Transform3D(_root, Vector3.ZERO) * _blk * xf, size])


func _bake(d: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for key: String in d:
		var st: SurfaceTool = d[key]
		st.index()
		st.generate_tangents()
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material(key))
	d.clear()
	return mesh


func _tile(key: String) -> float:
	return SETS[key][1] if SETS.has(key) else 1.0


## A flat convex polygon. `u` is the direction the texture's U runs along.
func face(key: String, pts: Array, n: Vector3, u: Vector3, off := Vector2.ZERO) -> void:
	var st := _surf(key)
	var bn := (_blk.basis * n).normalized()
	var nn := (_root * bn).normalized()
	var uu := (_root * (_blk.basis * u)).normalized()
	var vv := nn.cross(uu)
	var tile := _tile(key)
	var p: Array[Vector3] = []  # prop space, undeformed
	for q: Vector3 in pts:
		p.append(_blk * q)
	var flip := (p[1] - p[0]).cross(p[2] - p[0]).dot(bn) > 0.0
	for i in range(1, p.size() - 1):
		var tri := [0, i + 1, i] if flip else [0, i, i + 1]
		for k: int in tri:
			var q: Vector3 = _root * p[k]
			st.set_normal(nn)
			st.set_uv(Vector2(q.dot(uu), -q.dot(vv)) / tile + off)
			st.set_color(_weather(p[k], bn))
			st.add_vertex(_root * _lean_at(_blk * _sag_at(pts[k])))


## Vertex-colour masks for weathered.gdshader, from a local point and normal.
func _weather(q: Vector3, n: Vector3) -> Color:
	var above := q.y - _ground
	var grime := clampf(1.0 - above / 1.1, 0.0, 1.0)
	grime *= grime
	var vertical := 1.0 - absf(n.y)
	var moss := (clampf(n.y, 0.0, 1.0) * 0.4 + grime * 0.4) * _moss
	var ao := 1.0
	ao -= 0.35 * clampf(1.0 - above / 0.35, 0.0, 1.0)
	ao -= 0.4 * vertical * clampf(1.0 - (_eave - q.y) / 0.8, 0.0, 1.0) * float(q.y < _eave + 0.05)
	ao -= 0.15 * clampf(-n.y, 0.0, 1.0)
	ao = minf(ao, _ao)
	return Color(grime, clampf(moss, 0.0, 1.0), vertical, clampf(ao, 0.2, 1.0))


## Lean, in prop space.
func _lean_at(q: Vector3) -> Vector3:
	var up := maxf(q.y - _lean_from, 0.0)
	q.x += _lean.x * up
	q.z += _lean.y * up
	return q


## Ridge sag, in the block's own frame (ridge along x).
func _sag_at(q: Vector3) -> Vector3:
	if _sag > 0.0 and q.y > _sag_from:
		var along := clampf(q.x / _sag_half, -1.0, 1.0)
		var high := clampf((q.y - _sag_from) / maxf(_sag_to - _sag_from, 0.01), 0.0, 1.0)
		q.y -= _sag * (1.0 - along * along) * high
	return q


## A box of `size` placed by `xf`. Texture U follows `grain` (0 x, 1 y, 2 z)
## where it lies in a face; by default the longest axis. Edges are chamfered by
## `bevel` (capped at a fifth of the smallest side). `off` fixes the texture
## offset; by default it is random.
func box(key: String, xf: Transform3D, size: Vector3, grain := -1, off := Vector2(-1, -1)) -> void:
	if grain < 0:
		grain = 0
		for a in 3:
			if size[a] > size[grain]:
				grain = a
	var h := size * 0.5
	if off.x < 0.0:
		off = Vector2(rng.randf(), rng.randf())
	var bv := minf(bevel, minf(size.x, minf(size.y, size.z)) * 0.2) if key not in ["dark", "glass", "water"] else 0.0
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
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
			var eu: Vector3 = axes[ua]
			var ev: Vector3 = axes[va]
			var c := n * h[axis]
			var pts := []
			for s: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				pts.append(xf * (c + eu * s.x * (h[ua] - bv) + ev * s.y * (h[va] - bv)))
			face(key, pts, xf.basis * n, xf.basis * eu, off)
	if bv <= 0.0:
		return
	# Chamfer strips along the 12 edges, then the 8 corner triangles.
	for k in 3:
		var i := (k + 1) % 3
		var j := (k + 2) % 3
		var ek: Vector3 = axes[k]
		for si in [-1.0, 1.0]:
			for sj in [-1.0, 1.0]:
				var ni: Vector3 = axes[i] * si
				var nj: Vector3 = axes[j] * sj
				var p_i: Vector3 = ni * h[i] + nj * (h[j] - bv)
				var p_j: Vector3 = ni * (h[i] - bv) + nj * h[j]
				var e := ek * (h[k] - bv)
				var pts := [xf * (p_i - e), xf * (p_j - e), xf * (p_j + e), xf * (p_i + e)]
				face(key, pts, xf.basis * (ni + nj).normalized(), xf.basis * ek, off)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var sg := Vector3(sx, sy, sz)
				var pts := []
				for ax in 3:
					var q := sg * (h - Vector3.ONE * bv)
					q[ax] = sg[ax] * h[ax]
					pts.append(xf * q)
				var cn := xf.basis * sg.normalized()
				face(key, pts, cn, cn.cross(xf.basis * Vector3.UP + Vector3(0.01, 0, 0)), off)


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
	if _jitter > 0.0:
		a += Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * _jitter
		b += Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * _jitter
	var dir := b - a
	var y := dir.normalized()
	var x := Vector3.UP.cross(y)
	if x.length() < 0.01:
		x = Vector3.RIGHT
	x = x.normalized()
	var z := x.cross(y)
	box(key, Transform3D(Basis(x, y, z), (a + b) * 0.5), Vector3(w, dir.length(), w if d < 0 else d), 1)


func commit(yaw := 0.0) -> ArrayMesh:
	var mesh := _bake(_st)
	roof_mesh = _bake(_st_roof) if not _st_roof.is_empty() else null
	_to_roof = false
	_root = Basis.IDENTITY
	_ground = -1e9
	_eave = 1e9
	_ao = 1.0
	_moss = 1.0
	_lean = Vector2.ZERO
	_lean_from = 0.0
	_sag = 0.0
	_sag_from = 1e9
	_sag_to = 1e9
	_jitter = 0.0
	bevel = 0.0
	_blk = Transform3D.IDENTITY
	return mesh


# ---------------------------------------------------------------- props

## Turns everything that follows by `yaw` (a multiple of 90 degrees), so a
## prop built facing +Z can face any side of its box.
func _face_to(yaw_deg: float) -> void:
	_root = Basis(Vector3.UP, deg_to_rad(yaw_deg))


## A cottage filling `size`, front door facing `yaw_deg` (0 = +Z), laid out
## by a small grammar: the footprint's shape and the box's height pick a plan,
## the plan splits the footprint into blocks (gabled ranges, lean-tos,
## dormers), and every facade is then filled with openings by rule, so walls
## buried in another block, chimneys and doors are kept clear. The seed picks
## the variants (which end a wing goes on, chimney, window size and rhythm,
## lean-to length). Blocks share one lean, and gabled ones sag.
##
##   deep footprint            -> cross-wing: a front-gabled wing at one end,
##                                a lower hall behind, a porch in the corner
##   tall box                  -> two storeys, door hood
##   long footprint            -> attic dormers in the front slope
##   otherwise                 -> lean-to outshot along part of the back
func cottage(size: Vector3, yaw_deg: float, plaster: bool, seed: int) -> ArrayMesh:
	rng.seed = seed
	_face_to(yaw_deg)
	colliders = []
	rooms = []
	var dw := 1.3 if interior else 1.05
	var dh := 2.2 if interior else 1.95
	var turned := int(round(yaw_deg / 90.0)) % 2 != 0
	var L := size.z if turned else size.x
	var Wd := size.x if turned else size.z
	var y0 := -size.y * 0.5
	var inset := 0.35
	var hx := L * 0.5 - inset
	var hz := Wd * 0.5 - inset
	var tall := size.y >= 4.6
	var plinth := y0 + 0.55
	var top := y0 + (clampf(size.y - 0.4, 4.2, 4.6) if tall else clampf(size.y - 0.6, 2.9, 3.4))
	var wall := "plaster" if plaster else "planks"

	_ground = y0
	bevel = 0.025
	_jitter = 0.01
	var lean_dir := rng.randf() * TAU
	_lean = Vector2(cos(lean_dir), sin(lean_dir)) * rng.randf_range(0.006, 0.013)
	_lean_from = plinth
	var sag := rng.randf_range(0.05, 0.1)

	# House style: one window size and rhythm for the whole house.
	var ww: float = [0.7, 0.8, 0.9][rng.randi() % 3]
	var wh := rng.randf_range(0.8, 0.95)
	var spacing := rng.randf_range(1.7, 2.4)
	var sill := plinth + 0.95
	var wtop := minf(sill + wh, top - 0.3)

	var plan := "outshot"
	if hz > hx * 1.05 and hx * 2.0 >= 4.6:
		plan = "wing"
	elif tall:
		plan = "tall"
	elif hx > hz * 1.45:
		plan = "dormers"

	var blocks: Array = []
	var main: Dictionary
	var door_face := "front"
	var porch := false
	match plan:
		"wing":
			var side := 1.0 if rng.randf() < 0.5 else -1.0
			var wing_w := minf(clampf(hx, 2.8, 3.6), hx * 2.0 - 1.8)
			var dm := minf(wing_w - 0.7, hz * 2.0 * 0.62)
			var pw := minf(deg_to_rad(40.0), atan(2.4 / (wing_w * 0.5)))
			var wing := _block(Vector3(side * (hx - wing_w * 0.5), 0, 0), PI * 0.5, hz, wing_w * 0.5, plinth, top, pw, y0)
			var x0 := -side * hx
			var x1 := side * (hx - wing_w)
			main = _block(Vector3((x0 + x1) * 0.5, 0, -hz + dm * 0.5), 0.0, absf(x1 - x0) * 0.5, dm * 0.5, plinth, top, pw, y0)
			main.skip = ["east" if side > 0.0 else "west"]
			if side > 0.0:
				main.ends.y = wing_w * 0.5
			else:
				main.ends.x = wing_w * 0.5
			blocks = [main, wing]
			porch = true
			if interior:
				# A doorway through the wing's wall into the hall.
				var mz: float = -hz + dm * 0.5
				wing.opens.append(["back" if side > 0.0 else "front", mz if side > 0.0 else -mz, dw, plinth, plinth + dh, true, false, true])
		"outshot":
			var dl := clampf(hz * 0.6, 1.4, 1.9)
			var dm := hz * 2.0 - dl
			var pm := minf(deg_to_rad(38.0), atan(2.3 / (dm * 0.5)))
			main = _block(Vector3(0, 0, hz - dm * 0.5), 0.0, hx, dm * 0.5, plinth, top, pm, y0)
			var lx := hx * rng.randf_range(0.55, 1.0)
			var lc := (hx - lx) * (1.0 if rng.randf() < 0.5 else -1.0)
			var lr := top - 0.55
			var lp := clampf(atan((lr - (plinth + 2.05)) / dl), deg_to_rad(10.0), deg_to_rad(35.0))
			var lean := _block(Vector3(lc, 0, -hz + dl * 0.5), 0.0, lx, dl * 0.5, plinth, lr - dl * tan(lp), lp, y0, "lean")
			lean.skip = ["front"]
			blocks = [main, lean]
		_:
			var pm := minf(deg_to_rad(38.0), atan(2.3 / hz))
			main = _block(Vector3.ZERO, 0.0, hx, hz, plinth, top, pm, y0)
			blocks = [main]
			if plan == "dormers":
				var dtop := top + 0.9
				var dhz := 0.62
				var pd := deg_to_rad(40.0)
				var dridge := dtop + dhz * tan(pd)
				var d := (dridge + 0.15 - top) / tan(pm)
				if d <= hz - 0.05 and dridge < main.ridge - 0.1:
					var n := 2 if hx >= 3.2 else 1
					for i in n:
						var dx := 0.0 if n == 1 else (-1.0 if i == 0 else 1.0) * hx * rng.randf_range(0.4, 0.5)
						var dm_ := _block(Vector3(dx, 0, hz - d * 0.5), PI * 0.5, d * 0.5, dhz, top, dtop, pd, y0, "dormer")
						dm_.skip = ["east"]
						dm_.ends = Vector2(0.3, 0.0)
						dm_.opens.append(["west", 0.0, 0.7, top + 0.2, dtop - 0.1, false, false])
						blocks.append(dm_)

	# Chimney, chosen among the places this plan leaves free.
	var spots: Array[String] = []
	for g: String in ["west", "east"]:
		if g not in main.skip:
			spots.append(g)
	spots.append("ridge")
	if plan != "outshot":
		spots.append("back")
	var chim: String = spots[rng.randi() % spots.size()]
	var chim_u: float = rng.randf_range(-0.3, 0.3) * main.hz if chim in ["west", "east"] else rng.randf_range(-0.5, 0.5) * main.hx
	var avoid: Array = []
	if chim in ["west", "east"]:
		avoid.append([main, chim, chim_u - 0.5, chim_u + 0.5])
	elif chim == "back":
		avoid.append([main, "back", -chim_u - 0.45, -chim_u + 0.45])

	# Door on the main block's front, clear of other blocks.
	var span: float = main.hx
	var door_u := 0.0
	for tries in 12:
		var u := rng.randf_range(-0.45, 0.45) * maxf(span - 1.0, 0.0)
		if _clear(blocks, main, door_face, u, dw * 0.5, plinth, plinth + dh, false, avoid):
			door_u = u
			break
	main.opens.push_front([door_face, door_u, dw, plinth, plinth + dh, true, false])

	# Windows, facade by facade.
	for b: Dictionary in blocks:
		if b.kind == "dormer":
			continue
		var small: bool = b.kind == "lean"
		for f: String in ["front", "back", "east", "west"]:
			if f in b.skip:
				continue
			var is_door_face: bool = b == main and f == door_face
			if not is_door_face and rng.randf() < 0.2:
				continue
			if small:
				_fill_row(blocks, b, f, plinth + 1.0, minf(plinth + 1.6, b.top - 0.25), 0.6, spacing, avoid)
			else:
				_fill_row(blocks, b, f, sill, wtop, ww, spacing, avoid)
		if tall:
			# Upper storey: windows over the ones below, and over the door.
			var s2 := plinth + 2.55
			var t2 := minf(s2 + wh * 0.9, b.top - 0.25)
			for o: Array in b.opens.duplicate():
				if o[3] < s2 and o[0] in ["front", "back"]:
					if _clear(blocks, b, o[0], o[1], ww * 0.5, s2, t2, true, avoid):
						b.opens.append([o[0], o[1], ww, s2, t2, false, true])
			for f: String in ["east", "west"]:
				if f not in b.skip and _clear(blocks, b, f, 0.0, ww * 0.5, s2, t2, true, avoid):
					b.opens.append([f, 0.0, ww, s2, t2, false, true])
		# A small window high in a gable, where the gable is tall enough.
		if b.kind == "gable":
			var rise: float = b.ridge - b.top
			var gb: float = b.ridge - rise * 0.75
			if rise > 1.25 and b.hz * (b.ridge - gb - 0.6) / rise > 0.45:
				for f: String in ["east", "west"]:
					var chim_here: bool = b == main and chim == f
					if f not in b.skip and not chim_here and rng.randf() < 0.7:
						b.opens.append([f, 0.0, 0.6, gb, gb + 0.6, false, false])

	for b: Dictionary in blocks:
		_sag = sag if b.kind == "gable" else 0.0
		_build_block(b, wall, plaster)
		if interior and b.kind != "dormer":
			var room := AABB()
			for k in 8:
				var c := Vector3(b.hx * (1 if k & 1 else -1), b.plinth - 0.3 if k & 2 else b.ridge, b.hz * (1 if k & 4 else -1))
				var q: Vector3 = _root * (b.xf * c)
				room = AABB(q, Vector3.ZERO) if k == 0 else room.expand(q)
			rooms.append(room)

	# Fittings, drawn straight and level.
	_sag = 0.0
	_blk = main.xf
	_eave = main.top
	if tall:
		for f: String in ["front", "back", "east", "west"]:
			if f in main.skip:
				continue
			var fr := _wall_frame(f, 0.0, main.hx, main.hz)
			var sp: float = main.hz if f in ["east", "west"] else main.hx
			var o0: Vector3 = fr[0] + fr[1] * 0.06 + Vector3.UP * (plinth + 2.3)
			beam("beam", o0 - fr[2] * (sp + 0.04), o0 + fr[2] * (sp + 0.04), 0.2)
	var door: Array = main.opens[0]
	if porch:
		var dfr := _wall_frame(door_face, door_u, main.hx, main.hz)
		var dp: Vector3 = main.xf * dfr[0]
		var lo := maxf(minf(main.xf.origin.x - main.hx, main.xf.origin.x + main.hx), dp.x - 1.3)
		var hi := minf(maxf(main.xf.origin.x - main.hx, main.xf.origin.x + main.hx), dp.x + 1.3)
		var depth := minf(1.8, hz - dp.z - 0.1)
		_blk = Transform3D.IDENTITY
		_porch(lo + 0.02, hi - 0.02, dp.z, dp.z + depth, plinth, minf(plinth + 2.45, top - 0.4), y0)
	else:
		var fr := _wall_frame(door[0], door[1], main.hx, main.hz)
		var n: Vector3 = fr[1]
		var turn := rng.randf_range(-0.05, 0.05)
		if interior:
			_stair(fr[0], n, dw + 0.3, plinth, y0)
		else:
			box("stone", _xf(fr[0] + n * 0.2 + Vector3.UP * (plinth - 0.1), atan2(n.x, n.z) + turn), Vector3(1.3, 0.3, 0.36))
		if top - door[4] >= 0.55:
			_door_hood(door, main.hx, main.hz, minf(door[4] + 0.42, top - 0.12))

	# Chimney stack with a pot.
	_blk = main.xf
	_sag = sag
	_sag_half = main.hx + 0.3
	_sag_from = main.top - 0.5
	_sag_to = main.ridge
	match chim:
		"west", "east":
			var sx := -1.0 if chim == "west" else 1.0
			_chimney(Vector3(sx * (main.hx - 0.1), 0, chim_u), 0.9, 0.9, plinth, main.ridge + 0.9)
		"ridge":
			_to_roof = interior
			_chimney(Vector3(chim_u, 0, 0), 0.75, 0.75, main.top - 0.3, main.ridge + 0.8)
			_to_roof = false
		"back":
			_chimney(Vector3(chim_u, 0, -main.hz + 0.05), 0.9, 0.8, plinth, main.ridge + 0.5)
	return commit()


## One building block: a box of walls in its own frame (ridge along local x,
## front +z), placed in the prop by `at` and `yaw`. Kind "gable" has a ridge
## roof, "lean" a single slope falling to -z (ridge on its +z edge), "dormer"
## a ridge roof on walls that start at the main roof's eave. `skip` lists
## walls that are buried in another block; `ends` is how far the roof runs
## past each gable (west, east): past 0.3 it runs on into another block's roof.
func _block(at: Vector3, yaw: float, hx: float, hz: float, plinth: float, top: float,
		pitch: float, ground: float, kind := "gable") -> Dictionary:
	return {
		xf = Transform3D(Basis(Vector3.UP, yaw), at), hx = hx, hz = hz,
		plinth = plinth, top = top, pitch = pitch, ground = ground, kind = kind,
		ridge = top + (hz * 2.0 if kind == "lean" else hz) * tan(pitch),
		skip = [], ends = Vector2(0.3, 0.3),
		opens = [],  # [face, u, width, bottom, top, is_door, shutters]
	}


func _inside(b: Dictionary, p: Vector3, grow: float) -> bool:
	var q: Vector3 = b.xf.affine_inverse() * p
	return absf(q.x) < b.hx + grow and absf(q.z) < b.hz + grow


## How far an opening's furniture reaches from its centre along the wall.
func _reach(w: float, shutters: bool) -> float:
	return w + 0.08 if shutters else w * 0.5 + 0.15


## Whether an opening of half-width hw fits at u on face `f` of block b: inside
## the wall's ends, clear of the face's other openings at the same height, of
## `avoid` spans, and not in front of another block.
func _clear(blocks: Array, b: Dictionary, f: String, u: float, hw: float, y_lo: float, y_hi: float,
		shutters: bool, avoid: Array) -> bool:
	var span: float = b.hz if f in ["east", "west"] else b.hx
	var r := _reach(hw * 2.0, shutters)
	if absf(u) > span - r - 0.2:
		return false
	for o: Array in b.opens:
		if o[0] == f and o[3] < y_hi + 0.2 and o[4] > y_lo - 0.2:
			if absf(o[1] - u) < r + _reach(o[2], o[6]) + 0.12:
				return false
	for a: Array in avoid:
		if a[0] == b and a[1] == f and u + hw + 0.2 > a[2] and u - hw - 0.2 < a[3]:
			return false
	var fr := _wall_frame(f, 0.0, b.hx, b.hz)
	for s in [-1.0, 0.0, 1.0]:
		var p: Vector3 = b.xf * (fr[0] + fr[2] * (u + s * (hw + 0.3)) + fr[1] * 0.05)
		for o: Dictionary in blocks:
			if o != b and o.kind != "dormer" and _inside(o, p, 0.05):
				return false
	return true


## One row of windows along a facade, `spacing` apart where the wall is free,
## centred when the whole row can move, with one sometimes left blind.
func _fill_row(blocks: Array, b: Dictionary, f: String, sill: float, wtop: float, w: float,
		spacing: float, avoid: Array) -> void:
	var span: float = b.hz if f in ["east", "west"] else b.hx
	var gap := maxf(spacing, _reach(w, true) * 2.0 + 0.12)
	var placed: Array[float] = []
	var u := -span + rng.randf_range(0.0, 0.4)
	while u <= span:
		if (placed.is_empty() or u - placed.back() >= gap) and _clear(blocks, b, f, u, w * 0.5, sill, wtop, true, avoid):
			placed.append(u)
			u += gap
		else:
			u += 0.1
	if placed.is_empty():
		return
	var shift: float = ((span - placed.back()) - (placed[0] + span)) * 0.5
	var ok := true
	for pu in placed:
		ok = ok and _clear(blocks, b, f, pu + shift, w * 0.5, sill, wtop, true, avoid)
	if placed.size() > 2 and rng.randf() < 0.35:
		placed.remove_at(rng.randi() % placed.size())
	for pu in placed:
		b.opens.append([f, pu + (shift if ok else 0.0), w, sill, wtop, false, true])


func _build_block(b: Dictionary, wall: String, plaster: bool) -> void:
	_blk = b.xf
	_eave = b.top
	_sag_half = b.hx + 0.3
	_sag_from = b.top - 0.5
	_sag_to = b.ridge
	var hx: float = b.hx
	var hz: float = b.hz
	var top: float = b.top
	var ridge: float = b.ridge
	var skip: Array = b.skip
	var lean: bool = b.kind == "lean"

	# Stone plinth, going down to meet a falling slope.
	if b.kind != "dormer":
		var g: float = b.ground
		box("stone", _xf(Vector3(0, (g - 0.9 + b.plinth) * 0.5, 0)), Vector3(hx * 2 + 0.16, b.plinth - g + 0.9, hz * 2 + 0.16))
		_collide(_xf(Vector3(0, (g - 0.9 + b.plinth) * 0.5, 0)), Vector3(hx * 2 + 0.16, b.plinth - g + 0.9, hz * 2 + 0.16))
		if interior:
			box("planks", _xf(Vector3(0, b.plinth, 0)), Vector3(hx * 2 - 0.1, 0.03, hz * 2 - 0.1), 0)

	for f: String in ["front", "back", "east", "west"]:
		if f not in skip:
			_wall(wall, f, b.opens, hx, hz, b.plinth, top, skip)
	_to_roof = interior
	for sx in [-1.0, 1.0]:
		if ("west" if sx < 0.0 else "east") in skip:
			continue
		var x: float = sx * hx
		var apex := Vector3(x, ridge, hz) if lean else Vector3(x, ridge, 0)
		face(wall, [Vector3(x, top, -hz), Vector3(x, top, hz), apex], Vector3(sx, 0, 0), Vector3(0, 0, 1))
		if interior:
			var xi: float = x - sx * WALL
			var ai := Vector3(xi, ridge, hz) if lean else Vector3(xi, ridge, 0)
			face(wall, [Vector3(xi, top, -hz), Vector3(xi, top, hz), ai], Vector3(-sx, 0, 0), Vector3(0, 0, 1))

	if lean:
		# The slope's high edge sits on the wall it leans on.
		_blk = b.xf * Transform3D(Basis.IDENTITY, Vector3(0, 0, hz))
		_roof(hx, hz * 2.0, top, ridge, b.pitch, [-1.0], false, b.ends)
		_blk = b.xf
	else:
		_roof(hx, hz, top, ridge, b.pitch, [-1.0, 1.0], true, b.ends)

	_to_roof = false
	for o: Array in b.opens:
		_to_roof = interior and o[3] >= top
		_opening(o, hx, hz, o[4] <= top)
		_to_roof = false

	if plaster and b.kind != "dormer":
		_timber_frame(b.opens, hx, hz, b.plinth, top, -1.0 if lean else ridge, skip)
	else:
		for cx in [-1.0, 1.0]:
			for cz in [-1.0, 1.0]:
				if ("west" if cx < 0.0 else "east") in skip or ("back" if cz < 0.0 else "front") in skip:
					continue
				beam("beam", Vector3(cx * hx, b.plinth, cz * hz), Vector3(cx * hx, top, cz * hz), 0.2 if b.kind == "dormer" else 0.24)


## One wall of a cottage, cut round its openings, with the openings' reveals
## lined back into the wall: deep for the door, shallow for windows. Openings
## above the wall top (gable windows) are left to sit on the gable.
func _wall(key: String, fname: String, opens: Array, hx: float, hz: float, y0: float, y1: float, skip := []) -> void:
	var span := hz if fname in ["east", "west"] else hx
	var f := _wall_frame(fname, 0.0, hx, hz)
	var at: Vector3 = f[0]
	var n: Vector3 = f[1]
	var t: Vector3 = f[2]
	var holes: Array = []
	for o: Array in opens:
		if o[0] == fname and o[4] <= y1:
			holes.append([o[1] - o[2] * 0.5, o[1] + o[2] * 0.5, o[3], o[4], WALL if interior else (0.45 if o[5] else 0.2)])
	var us: Array[float] = [-span, span]
	for hh: Array in holes:
		us.append(hh[0])
		us.append(hh[1])
	us.sort()
	for i in us.size() - 1:
		var u0 := us[i]
		var u1 := us[i + 1]
		if u1 - u0 < 0.001:
			continue
		var mid := (u0 + u1) * 0.5
		var ys: Array[float] = [y0]
		for hh: Array in holes:
			if mid > hh[0] and mid < hh[1]:
				ys.append(hh[2])
				ys.append(hh[3])
		ys.sort()
		ys.append(y1)
		for k in range(0, ys.size(), 2):
			if ys[k + 1] - ys[k] > 0.001:
				face(key, [at + t * u0 + Vector3.UP * ys[k], at + t * u1 + Vector3.UP * ys[k],
						at + t * u1 + Vector3.UP * ys[k + 1], at + t * u0 + Vector3.UP * ys[k + 1]], n, t)
				if interior:
					_wall_inside(key, fname, at, n, t, span, u0, u1, ys[k], ys[k + 1], skip)
	if interior:
		# The wall's top, mitred at corners it shares: a dark timber plate, so
		# with the roof hidden the cut reads as the wall's edge, not a slab.
		var ends := _inner_ends(fname, span, skip)
		var ai: Vector3 = at - n * WALL
		face("beam", [at + t * -span + Vector3.UP * y1, at + t * span + Vector3.UP * y1,
				ai + t * ends.y + Vector3.UP * y1, ai + t * ends.x + Vector3.UP * y1], Vector3.UP, t)
	_ao = 0.6
	for hh: Array in holes:
		var d: float = hh[4]
		var c00: Vector3 = at + t * hh[0] + Vector3.UP * hh[2]
		var c10: Vector3 = at + t * hh[1] + Vector3.UP * hh[2]
		var c01: Vector3 = at + t * hh[0] + Vector3.UP * hh[3]
		var c11: Vector3 = at + t * hh[1] + Vector3.UP * hh[3]
		face(key, [c00, c10, c10 - n * d, c00 - n * d], Vector3.UP, t)
		face(key, [c01, c11, c11 - n * d, c01 - n * d], Vector3.DOWN, t)
		face(key, [c00, c01, c01 - n * d, c00 - n * d], t, Vector3.UP)
		face(key, [c10, c11, c11 - n * d, c10 - n * d], -t, Vector3.UP)
	_ao = 1.0


## How far a wall's inside face runs each way along it: short of the corner
## by the wall's thickness, unless the wall it meets there is left out.
func _inner_ends(fname: String, span: float, skip: Array) -> Vector2:
	var ends := {front = ["west", "east"], back = ["east", "west"], west = ["back", "front"], east = ["front", "back"]}
	var e: Array = ends[fname]
	return Vector2(-span if e[0] in skip else -span + WALL, span if e[1] in skip else span - WALL)


## The inside of one piece of wall between openings, and its collision box.
func _wall_inside(key: String, fname: String, at: Vector3, n: Vector3, t: Vector3, span: float,
		u0: float, u1: float, ya: float, yb: float, skip: Array) -> void:
	_collide(Transform3D(Basis(t, Vector3.UP, n), at + t * (u0 + u1) * 0.5 - n * WALL * 0.5 + Vector3.UP * (ya + yb) * 0.5),
			Vector3(u1 - u0, yb - ya, WALL))
	var ends := _inner_ends(fname, span, skip)
	var a := maxf(u0, ends.x)
	var b := minf(u1, ends.y)
	if b - a < 0.001:
		return
	var ai: Vector3 = at - n * WALL
	face(key, [ai + t * a + Vector3.UP * ya, ai + t * b + Vector3.UP * ya,
			ai + t * b + Vector3.UP * yb, ai + t * a + Vector3.UP * yb], -n, t)


## Two stone steps down from y_hi at `at` (on the wall or deck edge) outward
## along n, with a ramp collider laid over their nosings: the nav grid climbs
## ramps but steps only a quarter metre at a time.
func _stair(at: Vector3, n: Vector3, w: float, y_hi: float, ground: float) -> void:
	var t := Vector3.UP.cross(n)
	var rise := (y_hi - ground) / 3.0
	var yaw := atan2(n.x, n.z)
	for k in 2:
		var top := y_hi - rise * (k + 1)
		var h := top - (ground - 0.25)
		box("stone", _xf(at + n * (0.35 * k + 0.18) + Vector3.UP * (top - h * 0.5), yaw + rng.randf_range(-0.02, 0.02)),
				Vector3(w + 0.1 * k, h, 0.36))
	var d := n * 1.05 + Vector3.DOWN * (y_hi - ground)
	var len := d.length()
	var up := d.normalized().cross(t)
	# A slab, not a sheet: the nav grid only turns solid cells under a ramp's
	# face into ground, and a sheet thinner than a cell has none.
	_collide(Transform3D(Basis(t, up, d.normalized()), at + Vector3.UP * y_hi + d * 0.5 - up * 0.3), Vector3(w, 0.6, len + 0.1))


## Slate courses over sheathing boards, carried on rafters whose tails show
## under the eaves, with barge boards on the gables and a ridge of round tiles.
## Each course's texture is shifted so a row of slates ends on its lower edge.
## `sides` picks the slopes (-1 back, 1 front); `ends` is the run past each
## gable, and an end that runs on into another roof gets no barge board.
func _roof(hx: float, hz: float, top: float, ridge: float, pitch: float, sides := [-1.0, 1.0],
		tiles := true, ends := Vector2(0.3, 0.3)) -> void:
	var ov := 0.45
	var x0 := -hx - ends.x
	var x1 := hx + ends.y
	var xm := (x0 + x1) * 0.5
	var tp := tan(pitch)
	var sheath := 0.03
	var th := 0.028
	var row := 2.6 / 9.0
	var lap := row * 1.7
	var slope := (hz + ov) / cos(pitch)
	var segs := maxi(2, int(ceil((x1 - x0) / 1.3)))
	var seg_len := (x1 - x0) / segs
	var keep_bevel := bevel
	for sz: float in sides:
		var up := Vector3(0, sin(pitch), -sz * cos(pitch))
		var n := Vector3(0, cos(pitch), sz * sin(pitch))
		var eave := Vector3(0, top - ov * tp, sz * (hz + ov))
		var bx: Vector3 = Vector3.RIGHT * sz
		bevel = 0.0
		for k in segs:
			var sx := Vector3(x0 + seg_len * (k + 0.5), 0, 0)
			box("planks", Transform3D(Basis(bx, n, bx.cross(n)), eave + up * slope * 0.5 + n * sheath * 0.5 + sx), Vector3(seg_len, sheath, slope), 0)
		var s0 := 0.0
		var i := 0
		while s0 < slope - 0.05:
			var len := minf(lap, slope - s0 + 0.04)
			var lift := th + (rng.randf_range(0.0, 0.006) if i > 0 else 0.0)
			var lo := eave + up * s0 + n * (sheath + lift)
			var hi := eave + up * (s0 + len) + n * sheath
			var dd := (hi - lo).normalized()
			var nn: Vector3 = bx.cross(dd).normalized()
			var bs := Basis(bx, nn, bx.cross(nn))
			var edge: Vector3 = lo + nn * th
			var off := Vector2(rng.randf(), edge.dot(nn.cross(bx)) / 2.6 - 0.004)
			for k in segs:
				var x := x0 + seg_len * (k + 0.5)
				box("roof", Transform3D(bs, (lo + hi) * 0.5 + nn * th * 0.5 + Vector3(x, 0, 0)), Vector3(seg_len + 0.002, th, (hi - lo).length()), 0, off)
			if i == 0:
				box("roof", Transform3D(bs, eave + up * row * 0.5 + n * (sheath + th * 0.5) + Vector3(xm, 0, 0)), Vector3(x1 - x0, th, row), 0)
			s0 += row
			i += 1
		bevel = keep_bevel
		# Rafter tails under the eave, along the wall.
		var count := maxi(1, int(hx * 2.0 / 0.6))
		for k in count + 1:
			var x := lerpf(-hx + 0.1, hx - 0.1, float(k) / count)
			var w := Vector3(x, top, sz * hz)
			beam("beam", w + up * (0.25 / cos(pitch)) - n * 0.075, w - up * ((ov - 0.05) / cos(pitch)) - n * 0.075, 0.09, 0.15)
		# Barge boards on the open verges.
		for e in 2:
			if ends[e] <= 0.0 or ends[e] > 0.31:
				continue
			var vx := Vector3((x0 + 0.03) if e == 0 else (x1 - 0.03), 0, 0)
			beam("beam", Vector3(0, ridge, 0) + vx - n * 0.09, eave + vx - n * 0.09 - up * 0.04, 0.06, 0.24)
	if not tiles:
		return
	# Ridge of round tiles, each a touch out of line.
	bevel = 0.0
	var x := x0
	while x < x1 - 0.05:
		var l := minf(0.42, x1 - x)
		var at := Vector3(x + l * 0.5, ridge + sheath + th + 0.03 + rng.randf_range(-0.008, 0.008), rng.randf_range(-0.01, 0.01))
		cyl("roof", Transform3D(Basis(Vector3.BACK, PI * 0.5).rotated(Vector3.UP, rng.randf_range(-0.02, 0.02)), at), 0.13, l - 0.01, 8)
		x += l
	bevel = keep_bevel


## A stack of `w` x `d` from y_from to y_to, with a capping course and a pot.
func _chimney(c: Vector3, w: float, d: float, y_from: float, y_to: float) -> void:
	box("stone", _xf(Vector3(c.x, (y_from + y_to) * 0.5, c.z)), Vector3(w, y_to - y_from, d), 1)
	if not _to_roof:
		_collide(_xf(Vector3(c.x, (y_from + y_to) * 0.5, c.z)), Vector3(w, y_to - y_from, d))
	box("stone", _xf(Vector3(c.x, y_to + 0.05, c.z)), Vector3(w + 0.1, 0.14, d + 0.1))
	var px := c.x + rng.randf_range(-0.15, 0.15) * w
	cyl("stone", _xf(Vector3(px, y_to + 0.28, c.z)), 0.13, 0.36, 8)
	box("dark", _xf(Vector3(px, y_to + 0.465, c.z)), Vector3(0.17, 0.01, 0.17))


## A pent hood over a door on two brackets, its top edge at `y` on the wall.
func _door_hood(o: Array, hx: float, hz: float, y: float) -> void:
	var f := _wall_frame(o[0], o[1], hx, hz)
	var at: Vector3 = f[0]
	var n: Vector3 = f[1]
	var t: Vector3 = f[2]
	var w: float = o[2] + 0.7
	var dep := 0.5
	var p := deg_to_rad(28.0)
	var bs := Basis(Vector3.UP, atan2(n.x, n.z)) * Basis(Vector3.RIGHT, p)
	var c := at + n * (dep * 0.5) + Vector3.UP * (y - dep * 0.5 * tan(p))
	box("planks", Transform3D(bs, c), Vector3(w, 0.04, dep / cos(p)), 0)
	box("roof", Transform3D(bs, c + bs.y * 0.035), Vector3(w + 0.04, 0.03, dep / cos(p) + 0.04), 0)
	for s in [-1.0, 1.0]:
		var side: Vector3 = t * s * (o[2] * 0.5 + 0.2)
		beam("beam", at + side + Vector3.UP * (o[4] - 0.3) + n * 0.03,
				at + side + n * (dep - 0.08) + Vector3.UP * (y - dep * tan(p) - 0.04), 0.08)


## An open porch in prop space, from the wall at z0 out to z1, between x0 and
## x1: a planked deck on stone with a step, two posts with knee braces, and a
## low pent roof from `y_hi` on the wall.
func _porch(x0: float, x1: float, z0: float, z1: float, y_floor: float, y_hi: float, ground: float) -> void:
	var p := deg_to_rad(12.0)
	var xm := (x0 + x1) * 0.5
	var wd := x1 - x0
	var deck_z1 := z1 - (0.7 if interior else 0.4)
	box("stone", _xf(Vector3(xm, (ground - 0.6 + y_floor - 0.06) * 0.5, (z0 + deck_z1) * 0.5)), Vector3(wd, y_floor - 0.06 - ground + 0.6, deck_z1 - z0))
	_collide(_xf(Vector3(xm, (ground - 0.6 + y_floor) * 0.5, (z0 + deck_z1) * 0.5)), Vector3(wd, y_floor - ground + 0.6, deck_z1 - z0))
	box("planks", _xf(Vector3(xm, y_floor - 0.03, (z0 + deck_z1) * 0.5)), Vector3(wd + 0.04, 0.06, deck_z1 - z0 + 0.04), 0)
	var step_h := (y_floor - ground) * 0.5
	var turn := rng.randf_range(-0.03, 0.03)
	if interior:
		_stair(Vector3(xm, 0, deck_z1), Vector3.BACK, minf(wd, 1.6), y_floor, ground)
	else:
		box("stone", _xf(Vector3(xm, ground + step_h * 0.5 - 0.1, (deck_z1 + z1) * 0.5), turn), Vector3(minf(wd, 1.4), step_h + 0.2, z1 - deck_z1 - 0.02))
	var zp := deck_z1 - 0.12
	var y_at := func(z: float) -> float: return y_hi - (z - z0) * tan(p)
	var ypost: float = y_at.call(zp) - 0.1
	for x in [x0 + 0.12, x1 - 0.12]:
		beam("beam", Vector3(x, y_floor, zp), Vector3(x, ypost, zp), 0.15)
		_collide(_xf(Vector3(x, (y_floor + ypost) * 0.5, zp)), Vector3(0.15, ypost - y_floor, 0.15))
		var inward := 1.0 if x < xm else -1.0
		beam("beam", Vector3(x, ypost - 0.45, zp), Vector3(x + inward * 0.45, ypost - 0.04, zp), 0.09)
	beam("beam", Vector3(x0, ypost + 0.04, zp), Vector3(x1, ypost + 0.04, zp), 0.15)
	beam("beam", Vector3(x0, y_hi - 0.1, z0 + 0.06), Vector3(x1, y_hi - 0.1, z0 + 0.06), 0.12)
	var dep := z1 - z0
	var bs := Basis(Vector3.RIGHT, p)
	var c := Vector3(xm, y_hi - dep * 0.5 * tan(p) + 0.02, z0 + dep * 0.5)
	# The pent roof hides with the house's, and standing on the deck counts
	# as inside, so the door it shades stays in view during a fight there.
	_to_roof = interior
	box("planks", Transform3D(bs, c), Vector3(wd + 0.2, 0.04, dep / cos(p)), 0)
	box("roof", Transform3D(bs, c + bs.y * 0.035), Vector3(wd + 0.24, 0.03, dep / cos(p) + 0.04), 0)
	_to_roof = false
	if interior:
		rooms.append(AABB(_root * Vector3(x0, y_floor - 0.3, z0), Vector3.ZERO)
				.expand(_root * Vector3(x1, y_hi, deck_z1)))


## Where an opening sits: a point on the wall surface and the wall's outward axes.
func _wall_frame(face_name: String, u: float, hx: float, hz: float) -> Array:
	match face_name:
		"front":
			return [Vector3(u, 0, hz), Vector3(0, 0, 1), Vector3(1, 0, 0)]
		"back":
			return [Vector3(-u, 0, -hz), Vector3(0, 0, -1), Vector3(-1, 0, 0)]
		"west":
			return [Vector3(-hx, 0, u), Vector3(-1, 0, 0), Vector3(0, 0, 1)]
		_:
			return [Vector3(hx, 0, -u), Vector3(1, 0, 0), Vector3(0, 0, -1)]


func _opening(o: Array, hx: float, hz: float, recessed := true) -> void:
	var is_door: bool = o[5]
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
		var swing := deg_to_rad(rng.randf_range(20.0, 45.0))
		var hinge := c - t * w * 0.5 - n * 0.1
		if interior:
			# Open: the leaf stands back against the inside wall.
			swing = PI - 0.12
			hinge = c - t * w * 0.5 - n * WALL
		else:
			box("dark", _xf(c - n * 0.45, yaw), Vector3(w, h, 0.02))
		# Planked leaf, swung in from a hinge in the reveal.
		var leaf := Basis(Vector3.UP, yaw + swing)
		if not (o.size() > 7 and o[7]):
			box("planks", Transform3D(leaf, hinge + leaf * Vector3(w * 0.47, 0, 0.05)), Vector3(w * 0.94, h - 0.04, 0.06), 1)
			for ly in [-0.6, 0.6]:
				box("beam", Transform3D(leaf, hinge + leaf * Vector3(w * 0.47, ly, 0.1)), Vector3(w * 0.9, 0.12, 0.04))
	else:
		var back := 0.13 if recessed else -0.015
		box("glass", _xf(c - n * back, yaw), Vector3(w, h, 0.02))
		box("beam", _xf(c - n * (back - 0.04), yaw), Vector3(0.06, h, 0.04))
		box("beam", _xf(c - n * (back - 0.04), yaw), Vector3(w, 0.06, 0.04))
		box("beam", _xf(at + Vector3.UP * b + n * 0.09 + Vector3.DOWN * 0.04, yaw), Vector3(w + 0.3, 0.08, 0.2))
		# Shutters, swung back against the wall at a slight angle.
		if o[6]:
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
## openings, a mid rail broken by them, and braces in the clear bays. A king
## post runs up each gable that has no window in it (ridge < 0: no gables).
func _timber_frame(opens: Array, hx: float, hz: float, y0: float, y1: float, ridge: float, skip := []) -> void:
	var proud := 0.05
	var w := 0.17
	for fname: String in ["front", "back", "east", "west"]:
		if fname in skip:
			continue
		var span := hz if fname in ["east", "west"] else hx
		var f := _wall_frame(fname, 0.0, hx, hz)
		var at: Vector3 = f[0]
		var n: Vector3 = f[1]
		var t: Vector3 = f[2]
		var o0 := at + n * proud
		beam("beam", o0 + t * -span + Vector3.UP * (y0 + w * 0.5), o0 + t * span + Vector3.UP * (y0 + w * 0.5), w)
		beam("beam", o0 + t * -span + Vector3.UP * (y1 - w * 0.5), o0 + t * span + Vector3.UP * (y1 - w * 0.5), w)
		var posts: Array[float] = [-span + w * 0.5, span - w * 0.5]
		var holes: Array = []
		var gable_window := false
		for o: Array in opens:
			if o[0] != fname:
				continue
			if o[3] >= y1:
				gable_window = true
				continue
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
		if fname in ["east", "west"] and ridge > y1 and not gable_window:
			_to_roof = interior
			beam("beam", o0 + Vector3.UP * y1, o0 + Vector3.UP * (ridge - 0.1), w)
			_to_roof = false


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

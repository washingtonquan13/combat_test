extends RefCounted

# Procedural plants for the quarry bake: a trunk and branches as bark tubes,
# foliage as cards cut from a Poly Haven atlas. One generator, presets by
# kind. Trees come out as ordinary ArrayMeshes the bake saves like any other.
#
# Every vertex carries what the wind and the lighting need, so the shaders
# need nothing per tree:
#   COLOR.r  ambient occlusion: dark deep in the crown and low down
#   COLOR.g  a per-branch random number, for tint
#   COLOR.a  height up the tree, 0..1
#   UV2.x    how far out from the trunk (metres); branches bend with it
#   UV2.y    a per-branch phase, so branches don't move in step
# Bark and the cards on a branch share the branch's phase, and the bend is a
# function of distance from the trunk, so cards stay on their branches.
#
# Foliage normals point out of the crown, not out of each card: a crown lights
# as one soft volume instead of hundreds of flat cards catching the sun.

const LEAF_SHADER := "res://world/goblin_quarry/tree_leaf.gdshader"
const BARK_SHADER := "res://world/goblin_quarry/tree_bark.gdshader"

var rng := RandomNumberGenerator.new()


class Surf:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()

	func vert(p: Vector3, nn: Vector3, t: Vector2, w: Vector2, c: Color) -> int:
		v.append(p)
		n.append(nn)
		uv.append(t)
		uv2.append(w)
		col.append(c)
		return v.size() - 1

	func tri(a: int, b: int, c: int) -> void:
		idx.append(a)
		idx.append(b)
		idx.append(c)

	func arrays() -> Array:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = v
		a[Mesh.ARRAY_NORMAL] = n
		a[Mesh.ARRAY_TEX_UV] = uv
		a[Mesh.ARRAY_TEX_UV2] = uv2
		a[Mesh.ARRAY_COLOR] = col
		a[Mesh.ARRAY_INDEX] = idx
		return a


# ---------------------------------------------------------------- fir

# Cells of the 4x4 twig atlas worth using; the bottom-left two are sparse.
const FIR_CELLS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 15]

var _h := 1.0
var _spine: Array[Vector3] = []
# Which atlas cells cards draw from, and the phase the next cards bob with.
var _cells: Array = FIR_CELLS
var _phase := 0.0
# Broadleaf crowns are lit and shaded as an ellipsoid instead of round the spine.
var _broad := false
var _cc := Vector3.ZERO
var _cr := Vector3.ONE


func fir(seed: int, height: float, detail := 1.0) -> Array:
	# Returns [bark Surf, leaf Surf]. `detail` below 1 makes a far version:
	# fewer, larger cards and no thin branches.
	_lite = detail < 1.0
	rng.seed = seed
	_h = height
	_broad = false
	_cells = FIR_CELLS
	_phase = 0.0
	var bark := Surf.new()
	var leaf := Surf.new()
	var r0 := height * 0.017 + 0.04
	_build_spine(height)
	_trunk(bark, r0, 20 if detail >= 1.0 else 8)

	var crown_base := height * rng.randf_range(0.12, 0.28)
	var crown_r := height * rng.randf_range(0.2, 0.25)
	var y := crown_base
	var turn := rng.randf() * TAU
	while y < height - 0.5:
		var t := (y - crown_base) / (height - crown_base)
		var spacing := lerpf(0.42, 0.3, t) * sqrt(height / 14.0)
		var count := rng.randi_range(4, 6)
		turn += rng.randf_range(0.5, 1.4)
		for k in count:
			var a := turn + TAU * k / count + rng.randf_range(-0.3, 0.3)
			var reach := crown_r * pow(1.0 - t, 0.9) * rng.randf_range(0.75, 1.1) + 0.25
			_fir_branch(bark, leaf, y + rng.randf_range(-0.08, 0.08), a, reach, t, r0, detail)
		y += spacing * rng.randf_range(0.8, 1.2)
	# Dead stubs below the crown.
	var stubs := rng.randi_range(4, 9)
	for k in stubs:
		var sy := rng.randf_range(height * 0.04, crown_base)
		_stub(bark, sy, rng.randf() * TAU, rng.randf_range(0.2, 0.7), r0)
	# The leader: a few upright sprays at the top.
	var top := _spine_at(height - 0.15)
	for k in 3:
		var up := (Vector3.UP + _h_dir(rng.randf() * TAU) * 0.35).normalized()
		var side := up.cross(_h_dir(rng.randf() * TAU)).normalized()
		_card(leaf, top - up * 0.2, up, side, 0.32 / sqrt(detail), 0.6 / sqrt(detail), rng.randi(), rng.randf(), 1.0)
	return [bark, leaf]


func _h_dir(a: float) -> Vector3:
	return Vector3(cos(a), 0.0, sin(a))


func _build_spine(height: float) -> void:
	# The trunk's centre line: a slow random walk, mostly straight.
	_spine.clear()
	var p := Vector3.ZERO
	var drift := Vector3.ZERO
	var steps := int(height / 0.5) + 1
	for i in steps + 1:
		_spine.append(p)
		drift += Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)) * 0.004
		drift *= 0.9
		p += Vector3.UP * (height / steps) + drift


func _spine_at(y: float) -> Vector3:
	var f := clampf(y / _h, 0.0, 1.0) * (_spine.size() - 1)
	var i := mini(int(f), _spine.size() - 2)
	return _spine[i].lerp(_spine[i + 1], f - i)


func _trunk_r(y: float, r0: float) -> float:
	return _trunk_core(y, r0) * (1.0 + _flare(y, r0) * 0.75)


func _trunk_core(y: float, r0: float) -> float:
	var t := clampf(y / _h, 0.0, 1.0)
	return r0 * lerpf(1.0, 0.08, pow(t, 0.85))


func _flare(y: float, r0: float) -> float:
	# How far the roots spread the trunk at height y, as a share of its radius.
	return exp(-maxf(y, 0.0) / (r0 * 2.6))


func _trunk(bark: Surf, r0: float, sides: int) -> void:
	var pts: Array[Vector3] = []
	var radii: Array[float] = []
	var flare: Array[float] = []
	var y := -0.3
	while y < _h:
		pts.append(_spine_at(maxf(y, 0.0)) + Vector3.DOWN * maxf(-y, 0.0))
		radii.append(_trunk_core(maxf(y, 0.0), r0))
		flare.append(_flare(y, r0))
		y += 0.12 if y < r0 * 3.0 else (0.25 if y < r0 * 8.0 else 0.6)
	pts.append(_spine_at(_h))
	radii.append(0.01)
	flare.append(0.0)
	_tube(bark, pts, radii, sides, 0.0, 1.0, r0 * TAU, flare)


# Root buttresses and an uneven girth for a trunk tube; see _tube().
var _lobes := 5
var _lobe_off := 0.0
var _girth_ph := Vector2.ZERO


func _bole_r(r: float, flare: float, a: float, y: float) -> float:
	# The flare gathers into `_lobes` roots of uneven size instead of a round
	# cone; the whole trunk bulges and narrows a little as it climbs.
	var lobe := pow(0.5 + 0.5 * cos(_lobes * a + _lobe_off), 1.6) * (1.0 + 0.4 * sin(a + _lobe_off * 1.7))
	var girth := 1.0 + 0.05 * sin(2.0 * a + y * 1.7 + _girth_ph.x) + 0.035 * sin(3.0 * a - y * 2.9 + _girth_ph.y)
	return r * (1.0 + flare * (0.3 + 1.1 * lobe)) * girth


func _tube(s: Surf, pts: Array[Vector3], radii: Array[float], sides: int, phase: float, ao: float, u_span: float, flare: Array[float] = []) -> void:
	# Bark tube along pts; texture u wraps once per u_span metres of girth.
	# With `flare` (a trunk) the rings are shaped by _bole_r() and the normals
	# follow the shape round the ring.
	var bole := not flare.is_empty()
	if bole:
		# Its own generator, so the roots don't shift every later branch.
		var r2 := RandomNumberGenerator.new()
		r2.seed = hash(rng.seed * 31 + 7)
		_lobes = r2.randi_range(4, 6)
		_lobe_off = r2.randf() * TAU
		_girth_ph = Vector2(r2.randf(), r2.randf()) * TAU
	var first := s.v.size()
	var ref := Vector3.RIGHT
	var along := 0.0
	for i in pts.size():
		var fwd := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
		if absf(fwd.dot(ref)) > 0.9:
			ref = Vector3.FORWARD
		var side := fwd.cross(ref).normalized()
		var up := side.cross(fwd).normalized()
		ref = up
		if i > 0:
			along += pts[i].distance_to(pts[i - 1])
		var u_wrap := maxf(1.0, roundf(radii[0] * TAU / u_span * 4.0)) / 4.0
		for k in sides + 1:
			var a := TAU * k / sides
			var dir := side * cos(a) + up * sin(a)
			var r := radii[i]
			var n := dir
			if bole:
				var y := pts[i].y
				r = _bole_r(radii[i], flare[i], a, y)
				# Normal from the shape: tilted round the ring by how fast the
				# radius changes with angle, and up the trunk by how fast it
				# narrows (the root flare's slope).
				var da := 0.01
				var dr_da := (_bole_r(radii[i], flare[i], a + da, y) - _bole_r(radii[i], flare[i], a - da, y)) / (2.0 * da)
				var j0 := maxi(i - 1, 0)
				var j1 := mini(i + 1, pts.size() - 1)
				var ds := maxf(pts[j1].distance_to(pts[j0]), 0.001)
				var dr_ds := (_bole_r(radii[j1], flare[j1], a, pts[j1].y) - _bole_r(radii[j0], flare[j0], a, pts[j0].y)) / ds
				var tang := -side * sin(a) + up * cos(a)
				n = (dir - tang * dr_da / maxf(r, 0.001) - fwd * dr_ds).normalized()
			var p := pts[i] + dir * r
			var w := Vector2(Vector2(p.x, p.z).length(), phase)
			var occl := ao * lerpf(0.7, 1.0, clampf(p.y / _h * 1.5, 0.0, 1.0))
			s.vert(p, n, Vector2(float(k) / sides * u_wrap, along / (radii[0] * TAU) * u_wrap * 0.5), w, Color(occl, phase, 0.0, clampf(p.y / _h, 0.0, 1.0)))
	for i in pts.size() - 1:
		for k in sides:
			var a := first + i * (sides + 1) + k
			var b := a + sides + 1
			# Clockwise seen from outside: Godot's front face.
			s.tri(a, a + 1, b)
			s.tri(a + 1, b + 1, b)


func _fir_branch(bark: Surf, leaf: Surf, y: float, ang: float, reach: float, t: float, r0: float, detail: float) -> void:
	var base := _spine_at(y)
	var dir := _h_dir(ang)
	var pitch := lerpf(-0.12, 0.45, t) + rng.randf_range(-0.1, 0.1)
	var droop := lerpf(0.32, 0.08, t) * rng.randf_range(0.7, 1.3)
	# Low limbs bend down but their tips stay clear of the ground.
	var drop := reach * (droop - sin(pitch))
	if drop > y - 0.7:
		droop -= (drop - maxf(y - 0.7, 0.0)) / reach
	var phase := rng.randf()
	_phase = phase
	var seg := 5
	var pts: Array[Vector3] = []
	var radii: Array[float] = []
	var br := minf(_trunk_r(y, r0) * 0.45, 0.012 + reach * 0.018)
	for i in seg + 1:
		var s := float(i) / seg
		var p := base + dir * reach * s * cos(pitch) + Vector3.UP * reach * (s * sin(pitch) - droop * s * s)
		pts.append(p)
		radii.append(lerpf(br, 0.004, s))
	if detail >= 1.0 or reach > 1.0:
		_tube(bark, pts, radii, 4 if reach < 1.5 else 5, phase, 0.6, 0.25)
	# Sprays in a fishbone along the branch, lying roughly flat, convex up.
	var tint := rng.randf()
	var card_l := clampf(reach * 0.45, 0.35, 0.8) / sqrt(detail)
	var step := card_l * 0.3
	var s := 0.18 + rng.randf() * 0.1
	var flip := 1.0 if rng.randf() < 0.5 else -1.0
	while s < 1.0:
		var p := _branch_at(pts, s)
		var fwd := (_branch_at(pts, minf(s + 0.05, 1.0)) - _branch_at(pts, maxf(s - 0.05, 0.0))).normalized()
		flip = -flip
		var yaw := flip * rng.randf_range(0.45, 1.0)
		var along := fwd.rotated(Vector3.UP, yaw)
		along = (along + Vector3.DOWN * rng.randf_range(0.0, 0.25)).normalized()
		var norm := Vector3.UP.rotated(along, rng.randf_range(-0.45, 0.45))
		norm = (norm - along * norm.dot(along)).normalized()
		var side := norm.cross(along).normalized()
		var len := card_l * lerpf(0.75, 1.0, s) * rng.randf_range(0.85, 1.15)
		_card(leaf, p, along, side, len * 0.7, len, rng.randi(), tint, lerpf(0.5, 1.0, s))
		# Branchlets hanging under the limb fill the gap between whorls.
		if rng.randf() < 0.55 * detail:
			var hang := (fwd.rotated(Vector3.UP, -yaw * 0.6) + Vector3.DOWN * rng.randf_range(0.6, 1.1)).normalized()
			var hside := Vector3.UP.cross(hang).normalized()
			if hside.length() < 0.5:
				hside = side
			_card(leaf, p, hang, hside, len * 0.5, len * 0.75, rng.randi(), tint, lerpf(0.4, 0.85, s))
		s += step / reach * rng.randf_range(0.8, 1.2)
	# One spray carrying the branch on past its tip.
	var tip := pts[seg]
	var tdir := (pts[seg] - pts[seg - 1]).normalized()
	var tside := Vector3.UP.cross(tdir).normalized()
	_card(leaf, tip - tdir * card_l * 0.3, tdir, tside, card_l * 0.6, card_l, rng.randi(), tint, 1.0)


func _branch_at(pts: Array[Vector3], s: float) -> Vector3:
	var f := clampf(s, 0.0, 1.0) * (pts.size() - 1)
	var i := mini(int(f), pts.size() - 2)
	return pts[i].lerp(pts[i + 1], f - i)


func _stub(bark: Surf, y: float, ang: float, reach: float, r0: float) -> void:
	var base := _spine_at(y)
	var dir := (_h_dir(ang) + Vector3.DOWN * rng.randf_range(0.0, 0.3)).normalized()
	var r := minf(_trunk_r(y, r0) * 0.3, 0.03)
	_tube(bark, [base, base + dir * reach * 0.5, base + dir * reach] as Array[Vector3], [r, r * 0.6, 0.004] as Array[float], 4, rng.randf(), 0.8, 0.25)


func _card(s: Surf, base: Vector3, along: Vector3, side: Vector3, w: float, l: float, pick: int, tint: float, ao: float) -> void:
	# A card in two halves folded down from its centre line, so a spray has
	# some body from the side. Its base sits on `base` and it grows `along`.
	var cell: int = _cells[pick % _cells.size()]
	var c0 := Vector2(cell % 4, cell / 4) * 0.25 + Vector2(0.004, 0.004)
	var c1 := c0 + Vector2(0.242, 0.242)
	var norm := along.cross(side).normalized()
	if norm.y < 0.0:
		norm = -norm
	var fold := norm * w * 0.18
	var start := base - along * l * 0.08
	# Far versions (`_lite`) get a flat quad: 2 triangles instead of 8.
	var rows := [start, start + along * l] if _lite else [start, start + along * l * 0.5 + norm * l * 0.03, start + along * l]
	var cols := 2 if _lite else 3
	var first := s.v.size()
	for r in rows.size():
		var p: Vector3 = rows[r]
		var v := lerpf(c1.y, c0.y, r / float(rows.size() - 1))
		for k in cols:
			var f := k / float(cols - 1)
			var q := p + side * (f * 2.0 - 1.0) * w * 0.5 - (fold if cols == 3 and k != 1 else Vector3.ZERO)
			s.vert(q, _crown_normal(q, norm), Vector2(lerpf(c0.x, c1.x, f), v),
				Vector2(Vector2(q.x, q.z).length(), _phase), Color(_crown_ao(q) * ao, tint, 0.0, clampf(q.y / _h, 0.0, 1.0)))
	for r in rows.size() - 1:
		for k in cols - 1:
			var a := first + r * cols + k
			s.tri(a, a + cols, a + 1)
			s.tri(a + 1, a + cols, a + cols + 1)


func _crown_normal(p: Vector3, card_n: Vector3) -> Vector3:
	# Out from the trunk with an upward bias, more so near the top.
	if _broad:
		var g := (p - _cc) / (_cr * _cr)
		var bn := (g.normalized() + Vector3.UP * 0.35).normalized()
		return (bn * 0.8 + card_n * 0.2).normalized()
	var axis := _spine_at(p.y)
	var out := Vector3(p.x - axis.x, 0.0, p.z - axis.z)
	var r := out.length()
	out = out / maxf(r, 0.001)
	var t := clampf(p.y / _h, 0.0, 1.0)
	var n := (out + Vector3.UP * lerpf(0.45, 1.2, t)).normalized()
	return (n * 0.8 + card_n * 0.2).normalized()


func _crown_ao(p: Vector3) -> float:
	if _broad:
		var e := ((p - _cc) / _cr).length()
		var up := clampf((p.y - (_cc.y - _cr.y)) / (2.0 * _cr.y), 0.0, 1.0)
		return lerpf(0.3, 1.0, smoothstep(0.25, 1.0, e)) * lerpf(0.7, 1.0, up)
	var axis := _spine_at(p.y)
	var r := Vector2(p.x - axis.x, p.z - axis.z).length()
	var t := clampf(p.y / _h, 0.0, 1.0)
	var out := clampf(r / maxf(_h * 0.22 * (1.0 - t) + 0.3, 0.3), 0.0, 1.0)
	return lerpf(0.35, 1.0, smoothstep(0.0, 1.0, out)) * lerpf(0.75, 1.0, t)


# ---------------------------------------------------------------- broadleaf

# Every cell of the leafy-twig atlas (tools/quarry/leaf_atlas.py) is usable.
const BROAD_CELLS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

var _leaf_l := 0.8
var _lite := false
var _depth_max := 3
var _tube_max := 2


func broadleaf(seed: int, height: float, detail := 1.0) -> Array:
	# A trunk that forks into limbs, each limb branching recursively into an
	# ellipsoid crown; twigs carry the leaf cards. Returns [bark, leaf] like
	# fir(). Below detail 1 the last level of twigs goes, and the cards on
	# what's left grow to keep the crown's cover.
	_lite = detail < 1.0
	rng.seed = seed
	_h = height
	_broad = true
	_cells = BROAD_CELLS
	_depth_max = 3 if detail >= 1.0 else 2
	_tube_max = 2 if detail >= 1.0 else 1
	_leaf_l = clampf(height * 0.1, 0.65, 1.2) / sqrt(detail)
	var bark := Surf.new()
	var leaf := Surf.new()
	var r0 := height * 0.02 + 0.05
	var fork := height * rng.randf_range(0.28, 0.4)
	var lean := _h_dir(rng.randf() * TAU) * rng.randf_range(0.0, 0.08)
	var top := Vector3(lean.x * fork, fork, lean.z * fork)
	var wide := height * rng.randf_range(0.36, 0.48)
	_cr = Vector3(wide, (height - fork) * 0.55, wide * rng.randf_range(0.85, 1.15))
	_cc = Vector3(top.x, height - _cr.y, top.z)

	_phase = 0.0
	var pts: Array[Vector3] = []
	var radii: Array[float] = []
	var flare: Array[float] = []
	var y := -0.3
	while true:
		var f := clampf(y / fork, 0.0, 1.0)
		pts.append(top * f + Vector3.DOWN * maxf(-y, 0.0))
		radii.append(r0 * lerpf(1.0, 0.8, f))
		flare.append(_flare(y, r0) * 1.1)
		if y >= fork:
			break
		y = minf(y + (0.1 if y < r0 * 3.0 else (0.2 if y < r0 * 6.0 else 0.5)), fork)
	# On past the fork, tapering inside the limbs so the joint has no rim.
	pts.append(top + Vector3.UP * r0 * 2.5)
	radii.append(r0 * 0.3)
	flare.append(0.0)
	_tube(bark, pts, radii, 20 if detail >= 1.0 else 8, 0.0, 1.0, r0 * TAU, flare)

	var limbs := rng.randi_range(2, 4)
	var turn := rng.randf() * TAU
	var rf := r0 * 0.8
	for i in limbs:
		var az := turn + TAU * i / limbs + rng.randf_range(-0.4, 0.4)
		var tilt := rng.randf_range(0.1, 0.25) if i == 0 else rng.randf_range(0.45, 0.85)
		var dir := (Vector3.UP * cos(tilt) + _h_dir(az) * sin(tilt)).normalized()
		var len := _to_envelope(top, dir) * rng.randf_range(0.8, 0.92)
		_phase = rng.randf()
		var r := rf * (0.9 if i == 0 else rng.randf_range(0.65, 0.8))
		_bough(bark, leaf, top + Vector3.DOWN * r0 * 1.5, dir, len + r0 * 1.5, r, 0, rng.randf(), r0 * TAU)
	_broad = false
	_cells = FIR_CELLS
	return [bark, leaf]


func bush(seed: int, height: float, detail := 1.0) -> Array:
	# No trunk: stems rise from one root crown and branch into a low, wide
	# ellipsoid that sits on the ground. Same boughs and cards as broadleaf();
	# the stems start a level down so they carry two levels of twigs.
	_lite = detail < 1.0
	rng.seed = seed
	_h = height
	_broad = true
	_cells = BROAD_CELLS
	# A bush is all twigs, so the far mesh keeps every level and saves on
	# bark and on fewer, bigger cards instead.
	_depth_max = 3
	_tube_max = 2 if detail >= 1.0 else 1
	_leaf_l = clampf(height * 0.22, 0.32, 0.6) / sqrt(detail)
	var bark := Surf.new()
	var leaf := Surf.new()
	var wide := height * rng.randf_range(0.6, 0.8)
	_cr = Vector3(wide, height * 0.55, wide * rng.randf_range(0.8, 1.2))
	_cc = Vector3(0.0, height * 0.45, 0.0)
	var r0 := height * 0.012 + 0.012
	var stems := rng.randi_range(4, 7) if detail >= 1.0 else rng.randi_range(3, 5)
	var turn := rng.randf() * TAU
	for i in stems:
		var az := turn + TAU * i / stems + rng.randf_range(-0.5, 0.5)
		var tilt := rng.randf_range(0.25, 0.9)
		var dir := (Vector3.UP * cos(tilt) + _h_dir(az) * sin(tilt)).normalized()
		var start := _h_dir(az) * rng.randf_range(0.0, r0 * 4.0) + Vector3.DOWN * 0.05
		var len := _to_envelope(start + Vector3.UP * 0.06, dir) * rng.randf_range(0.8, 0.95)
		_phase = rng.randf()
		_bough(bark, leaf, start, dir, len, r0 * rng.randf_range(0.8, 1.1), 1, rng.randf(), r0 * TAU * 4.0)
	_broad = false
	_cells = FIR_CELLS
	return [bark, leaf]



# ---------------------------------------------------------------- fern

# Cells of the frond atlas (tools/quarry/fern_atlas.py): the bottom row is
# browning, for the old outer fronds.
const FERN_GREEN := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
const FERN_OLD := [12, 13, 14, 15]


func fern(seed: int, height: float, detail := 1.0) -> Array:
	# A rosette of fronds from one crown, each a bent strip carrying one frond
	# card from the base of its cell to the tip, rising steeply and arching
	# over. Inner fronds stand tall, outer ones lie wide and low and are more
	# often browning. Returns [bark, leaf] like the others; bark is empty.
	_lite = detail < 1.0
	rng.seed = seed
	_h = height
	_broad = true
	var reach := height * 1.1
	_cr = Vector3(reach, height, reach)
	_cc = Vector3(0.0, -height * 0.15, 0.0)
	var leaf := Surf.new()
	var count := rng.randi_range(10, 15) if detail >= 1.0 else rng.randi_range(7, 9)
	var segs := 6 if detail >= 1.0 else 3
	var turn := rng.randf() * TAU
	for i in count:
		var outer := rng.randf()
		var az := turn + i * 2.39996 + rng.randf_range(-0.3, 0.3)
		var rise := lerpf(1.2, 0.55, outer) + rng.randf_range(-0.12, 0.12)
		var droop := lerpf(1.4, 2.1, outer) * rng.randf_range(0.85, 1.15)
		var l := height * lerpf(1.15, 1.6, outer) * rng.randf_range(0.85, 1.1)
		var cells: Array = FERN_OLD if outer > 0.7 and rng.randf() < 0.45 else FERN_GREEN
		_phase = rng.randf()
		_frond(leaf, az, rise, droop, l, segs, cells[rng.randi() % cells.size()], rng.randf())
	_broad = false
	return [Surf.new(), leaf]


func _frond(s: Surf, az: float, rise: float, droop: float, l: float, segs: int, cell: int, tint: float) -> void:
	# One strip, `segs` rows by three columns. The frond in its cell is about
	# 0.7 of the cell wide, so the strip only spans that much of it.
	var c0 := Vector2(cell % 4, cell / 4) * 0.25 + Vector2(0.004, 0.004)
	var c1 := c0 + Vector2(0.242, 0.242)
	var u0 := lerpf(c0.x, c1.x, 0.14)
	var u1 := lerpf(c0.x, c1.x, 0.86)
	var w := l * 0.72
	var out := _h_dir(az)
	var side := out.cross(Vector3.UP).normalized()
	var twist := rng.randf_range(-0.35, 0.35)
	var p := out * l * 0.02
	var first := s.v.size()
	for r in segs + 1:
		var t := float(r) / segs
		# Pitch falls along the frond: up at the crown, over and down at the tip.
		var pitch := rise - droop * t * t
		var d := (out * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
		var sd := side.rotated(d, twist * t)
		var norm := d.cross(sd).normalized()
		if norm.y < 0.0:
			norm = -norm
		# Pinnae hang a little either side of the rachis.
		var hang := norm * w * 0.12 * t
		var v := lerpf(c1.y, c0.y, t)
		for k in 3:
			var x := k - 1.0
			var q := p + sd * x * w * 0.5 * lerpf(0.6, 1.0, minf(t * 3.0, 1.0)) - (hang if k != 1 else Vector3.ZERO)
			s.vert(q, _crown_normal(q, norm), Vector2(lerpf(u0, u1, k / 2.0), v),
				Vector2(Vector2(q.x, q.z).length(), _phase), Color(_crown_ao(q), tint, 0.0, clampf(q.y / _h, 0.0, 1.0)))
		p += d * l / segs
	for r in segs:
		for k in 2:
			var a := first + r * 3 + k
			s.tri(a, a + 3, a + 1)
			s.tri(a + 1, a + 3, a + 4)

func _to_envelope(p: Vector3, d: Vector3) -> float:
	# Distance from p along d to the crown's surface; 0 if p is outside it.
	var q := (p - _cc) / _cr
	var e := d / _cr
	var a := e.dot(e)
	var b := 2.0 * q.dot(e)
	var c := q.dot(q) - 1.0
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return 0.0
	return maxf((-b + sqrt(disc)) / (2.0 * a), 0.0)


func _perp(t: Vector3, az: float) -> Vector3:
	var a := t.cross(Vector3.UP)
	if a.length() < 0.2:
		a = t.cross(Vector3.RIGHT)
	a = a.normalized()
	var b := t.cross(a).normalized()
	return a * cos(az) + b * sin(az)


func _bough(bark: Surf, leaf: Surf, start: Vector3, dir: Vector3, len: float, rad: float, depth: int, tint: float, u_span: float) -> void:
	# One branch and, recursively, its children. Limbs curve up toward the
	# light, small branches droop under their leaves.
	var seg := 6 if depth == 0 else (4 if depth == 1 else 3)
	var grav: float = [0.25, 0.05, -0.2, -0.3][depth]
	var wander := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)) * 0.25
	var terminal := depth >= _depth_max
	var pts: Array[Vector3] = [start]
	var radii: Array[float] = [rad]
	var d := dir
	for i in range(1, seg + 1):
		d = (d + (Vector3.UP * grav + wander) / seg).normalized()
		pts.append(pts[i - 1] + d * len / seg)
		radii.append(lerpf(rad, 0.003 if terminal else rad * 0.4, float(i) / seg))
	if depth <= _tube_max and rad > 0.004:
		var sides: int = [8, 6, 4, 3][depth]
		_tube(bark, pts, radii, sides, _phase, lerpf(0.6, 1.0, 1.0 - depth / 3.0), u_span)

	if not terminal:
		var count: int = [rng.randi_range(6, 8), rng.randi_range(5, 7), rng.randi_range(4, 6)][depth]
		var az := rng.randf() * TAU
		for k in count:
			var s := lerpf(0.25 if depth == 0 else 0.15, 0.97, (k + rng.randf_range(0.2, 0.8)) / count)
			var p := _branch_at(pts, s)
			var tan := (_branch_at(pts, minf(s + 0.05, 1.0)) - _branch_at(pts, maxf(s - 0.05, 0.0))).normalized()
			az += 2.39996 + rng.randf_range(-0.3, 0.3)
			var ang := rng.randf_range(0.6, 1.0) if depth < 2 else rng.randf_range(0.8, 1.25)
			var cd := (tan * cos(ang) + _perp(tan, az) * sin(ang)).normalized()
			var want := len * rng.randf_range(0.5, 0.7) * lerpf(1.0, 0.55, s)
			var room := _to_envelope(p, cd)
			var cl := minf(want, room * rng.randf_range(0.85, 1.0)) if room > want * 0.35 else want * 0.35
			var cr := minf(lerpf(rad, rad * 0.4, s) * 0.75, rad * pow(cl / len, 1.1))
			_bough(bark, leaf, p, cd, cl, maxf(cr, 0.003), depth + 1, tint if depth > 0 else rng.randf(), u_span)

	# Leaves on the last two levels: thick on twigs, sparse on what bears them.
	if depth >= _depth_max - 1:
		var step := _leaf_l * (0.38 if terminal else 0.7)
		var s := 0.35 + rng.randf() * 0.15
		while s < 1.0:
			var p := _branch_at(pts, s)
			var tan := (_branch_at(pts, minf(s + 0.05, 1.0)) - _branch_at(pts, maxf(s - 0.05, 0.0))).normalized()
			_broad_card(leaf, p, tan, tint)
			s += step / maxf(len, 0.1) * rng.randf_range(0.8, 1.2)
		_broad_card(leaf, pts[seg], (pts[seg] - pts[seg - 1]).normalized(), tint)


func _broad_card(leaf: Surf, p: Vector3, tan: Vector3, tint: float) -> void:
	var out := (p - _cc).normalized()
	var jitter := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
	var along := (tan * 0.6 + out * 0.5 + jitter * 0.35).normalized()
	var side := along.cross(Vector3.UP)
	if side.length() < 0.2:
		side = along.cross(Vector3.RIGHT)
	side = side.normalized().rotated(along, rng.randf_range(-0.8, 0.8))
	var l := _leaf_l * rng.randf_range(0.8, 1.2)
	_card(leaf, p, along, side, l * 0.95, l, rng.randi(), tint, 1.0)


# ---------------------------------------------------------------- output

# ---------------------------------------------------------------- vine

# Cells of the ivy atlas (tools/quarry/vine_atlas.py): young runs, then the
# darker old growth in the bottom row.
const VINE_YOUNG := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
const VINE_OLD := [12, 13, 14, 15]
const VINE_STEP := 0.12


func vine(leaf: Surf, seed: int, start: Vector3, pref: Vector3, length: float, surface: Callable, detail := 1.0) -> int:
	# Ivy that creeps over whatever `surface` describes. surface(p) returns
	# [point, normal] on the surface nearest p, or [] where there is none.
	# Unlike the other plants a vine is grown in place, so its cards are
	# appended to `leaf` in world space. `pref` is where it wants to go: up
	# for ivy climbing from a wall's foot, down for a curtain hanging off a
	# rim. Returns how many cards it laid.
	_lite = detail < 1.0
	rng.seed = seed
	_h = 1.0
	_phase = rng.randf()
	var hit: Array = surface.call(start)
	if hit.is_empty():
		return 0
	var tint := rng.randf()
	return _strand(leaf, hit[0], hit[1], pref, pref, length, surface, 0, tint, detail)


func _strand(leaf: Surf, p: Vector3, n: Vector3, dir: Vector3, pref: Vector3, length: float, surface: Callable, depth: int, tint: float, detail: float) -> int:
	# One stem, walked over the surface a step at a time: it keeps on, leans
	# toward `pref`, wanders, and is pulled back onto the surface after every
	# step. It stops where the surface ends, jumps, or flattens out for long
	# (ivy that tops a wall creeps only a little way onto the ground).
	var pts: Array[Vector3] = [p]
	var nrm: Array[Vector3] = [n]
	var d := (dir - n * dir.dot(n)).normalized()
	var flat := 0.0
	var walked := 0.0
	var forks: Array = []
	var flat_max := rng.randf_range(0.3, 0.9)
	while walked < length:
		var wander := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		d = d + pref * 0.22 + wander * 0.45
		d = (d - n * d.dot(n))
		if d.length() < 0.01:
			break
		d = d.normalized()
		var hit: Array = surface.call(p + d * VINE_STEP)
		if hit.is_empty():
			break
		var q: Vector3 = hit[0]
		if q.distance_to(p) > VINE_STEP * 2.5 or q.distance_to(p) < VINE_STEP * 0.2:
			break
		flat = flat + VINE_STEP if (hit[1] as Vector3).y > 0.85 else 0.0
		if flat > flat_max:
			break
		d = (q - p).normalized()
		p = q
		n = hit[1]
		pts.append(p)
		nrm.append(n)
		walked += VINE_STEP
		if depth < 2 and walked > 0.3 and rng.randf() < 0.08 * detail:
			forks.append([pts.size() - 1, (length - walked) * rng.randf_range(0.4, 0.8)])
	if pts.size() < 3:
		return 0
	var cards := _strand_cards(leaf, pts, nrm, depth, tint, detail)
	for f: Array in forks:
		var i: int = f[0]
		var side := 1.0 if rng.randf() < 0.5 else -1.0
		var along := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var fd := along.rotated(nrm[i], side * rng.randf_range(0.7, 1.3))
		cards += _strand(leaf, pts[i], nrm[i], fd, pref, f[1], surface, depth + 1, tint, detail)
	return cards


func _strand_cards(leaf: Surf, pts: Array[Vector3], nrm: Array[Vector3], depth: int, tint: float, detail: float) -> int:
	# Cards end to end along the stem, each a straight chord of it, so the
	# stem drawn in one card runs on into the next. Old growth near the root.
	var l := rng.randf_range(0.42, 0.55) / sqrt(detail)
	var total := (pts.size() - 1) * VINE_STEP
	var s := 0.0
	var count := 0
	while s < total - l * 0.3:
		var a := _path_at(pts, s / VINE_STEP)
		var b := _path_at(pts, minf(s + l, total) / VINE_STEP)
		var i := clampi(int(round(s / VINE_STEP)), 0, nrm.size() - 1)
		var along := b - a
		if along.length() < l * 0.3:
			break
		along = along.normalized()
		var n := nrm[i]
		var side := n.cross(along).normalized()
		n = along.cross(side).normalized()
		var old := depth == 0 and s < 0.8 and rng.randf() < 0.7
		var cell: int = (VINE_OLD if old else VINE_YOUNG)[rng.randi() % (4 if old else 12)]
		_vine_card(leaf, a, along, side, n, l, cell, tint, s, rng.randf() < 0.5)
		count += 1
		# Side shoots fill the run out into a mat, thickest low down where
		# the ivy is oldest.
		var fill := (0.75 if s < 1.5 else 0.4) * detail
		while rng.randf() < fill:
			fill -= 0.6
			var off := side * l * rng.randf_range(-0.45, 0.45)
			var tw := along.rotated(n, rng.randf_range(-0.9, 0.9))
			_vine_card(leaf, a + off, tw, n.cross(tw).normalized(), n, l * 0.9, VINE_YOUNG[rng.randi() % 12], tint, s, rng.randf() < 0.5)
			count += 1
		s += l * rng.randf_range(0.7, 0.85)
	return count


func _path_at(pts: Array[Vector3], f: float) -> Vector3:
	var i := clampi(int(floor(f)), 0, pts.size() - 2)
	return pts[i].lerp(pts[i + 1], clampf(f - i, 0.0, 1.0))


func _vine_card(leaf: Surf, base: Vector3, along: Vector3, side: Vector3, n: Vector3, l: float, cell: int, tint: float, reach: float, flip: bool) -> void:
	# A card lying on the surface: the stem line close to it, the leaf edges
	# standing off a little, as ivy leaves stand on their stalks. Normals are
	# the surface's with a lift toward the sky, so a wall of ivy lights as
	# one layer.
	var c0 := Vector2(cell % 4, cell / 4) * 0.25 + Vector2(0.004, 0.004)
	var c1 := c0 + Vector2(0.242, 0.242)
	if flip:
		var t := c0.x
		c0.x = c1.x
		c1.x = t
	var lift := n * 0.035
	var light := (n * 0.75 + Vector3.UP * 0.35).normalized()
	var first := leaf.v.size()
	for r in 3:
		var p := base + along * l * (r / 2.0 - 0.05) + lift
		var v := lerpf(c1.y, c0.y, r / 2.0)
		for k in 3:
			var x := k - 1.0
			var q := p + side * x * l * 0.6 + n * absf(x) * l * 0.1
			leaf.vert(q, light, Vector2(lerpf(c0.x, c1.x, k / 2.0), v), Vector2(0.15 + minf(reach, 3.0) * 0.1, _phase),
				Color(rng.randf_range(0.8, 1.0), tint, 0.0, 0.0))
	for r in 2:
		for k in 2:
			var a := first + r * 3 + k
			leaf.tri(a, a + 3, a + 1)
			leaf.tri(a + 1, a + 3, a + 4)


func mesh(parts: Array, bark_mat: Material, leaf_mat: Material) -> ArrayMesh:
	var m := ArrayMesh.new()
	# A plant with no wood (a fern) has an empty bark surface; skip it.
	for i in 2:
		var surf: Surf = parts[i]
		if surf.idx.is_empty():
			continue
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf.arrays())
		m.surface_set_material(m.get_surface_count() - 1, bark_mat if i == 0 else leaf_mat)
	return m


func leaf_material(atlas: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(LEAF_SHADER)
	m.set_shader_parameter("atlas", atlas)
	return m


func bark_material(albedo: Texture2D, normal: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(BARK_SHADER)
	m.set_shader_parameter("albedo", albedo)
	m.set_shader_parameter("normal_map", normal)
	return m


static func coverage_texture(path: String) -> ImageTexture:
	# Mipmaps that keep the share of opaque texels, so cut-out foliage keeps
	# its body with distance instead of thinning to nothing (alpha averages
	# down under the scissor threshold otherwise). Transparent texels take the
	# mean leaf colour, so the colour doesn't darken toward the edges either.
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var sum := Vector3.ZERO
	var opaque := 0
	for i in range(0, data.size(), 4):
		if data[i + 3] >= 128:
			sum += Vector3(data[i], data[i + 1], data[i + 2])
			opaque += 1
	var mean := sum / maxf(opaque, 1.0)
	for i in range(0, data.size(), 4):
		if data[i + 3] < 128:
			data[i] = int(mean.x)
			data[i + 1] = int(mean.y)
			data[i + 2] = int(mean.z)
	var w := img.get_width()
	var h := img.get_height()
	img = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)
	var cover := float(opaque) / (w * h)
	img.generate_mipmaps()
	data = img.get_data()
	var level := 1
	while true:
		var off := img.get_mipmap_offset(level)
		var lw := maxi(w >> level, 1)
		var lh := maxi(h >> level, 1)
		var count := lw * lh
		var alphas := PackedFloat32Array()
		alphas.resize(count)
		for i in count:
			alphas[i] = data[off + i * 4 + 3]
		alphas.sort()
		var q := alphas[clampi(int((1.0 - cover) * count), 0, count - 1)]
		var scale := 127.5 / maxf(q, 1.0)
		for i in count:
			data[off + i * 4 + 3] = clampi(int(data[off + i * 4 + 3] * scale), 0, 255)
		if lw == 1 and lh == 1:
			break
		level += 1
	img = Image.create_from_data(w, h, true, Image.FORMAT_RGBA8, data)
	img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	return ImageTexture.create_from_image(img)

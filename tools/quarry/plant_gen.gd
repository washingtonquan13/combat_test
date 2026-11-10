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


func fir(seed: int, height: float, detail := 1.0) -> Array:
	# Returns [bark Surf, leaf Surf]. `detail` below 1 makes a far version:
	# fewer, larger cards and no thin branches.
	rng.seed = seed
	_h = height
	var bark := Surf.new()
	var leaf := Surf.new()
	var r0 := height * 0.017 + 0.04
	_build_spine(height)
	_trunk(bark, r0, 10 if detail >= 1.0 else 6)

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
	var t := clampf(y / _h, 0.0, 1.0)
	var r := r0 * lerpf(1.0, 0.08, pow(t, 0.85))
	# Root flare.
	return r * (1.0 + 0.7 * exp(-y / (r0 * 2.2)))


func _trunk(bark: Surf, r0: float, sides: int) -> void:
	var pts: Array[Vector3] = []
	var radii: Array[float] = []
	var y := -0.3
	while y < _h:
		pts.append(_spine_at(maxf(y, 0.0)) + Vector3.DOWN * maxf(-y, 0.0))
		radii.append(_trunk_r(maxf(y, 0.0), r0))
		y += 0.25 if y < r0 * 4.0 else 0.6
	pts.append(_spine_at(_h))
	radii.append(0.01)
	_tube(bark, pts, radii, sides, 0.0, 1.0, r0 * TAU)


func _tube(s: Surf, pts: Array[Vector3], radii: Array[float], sides: int, phase: float, ao: float, u_span: float) -> void:
	# Bark tube along pts; texture u wraps once per u_span metres of girth.
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
			var p := pts[i] + dir * radii[i]
			var w := Vector2(Vector2(p.x, p.z).length(), phase)
			var occl := ao * lerpf(0.7, 1.0, clampf(p.y / _h * 1.5, 0.0, 1.0))
			s.vert(p, dir, Vector2(float(k) / sides * u_wrap, along / (radii[0] * TAU) * u_wrap * 0.5), w, Color(occl, phase, 0.0, clampf(p.y / _h, 0.0, 1.0)))
	for i in pts.size() - 1:
		for k in sides:
			var a := first + i * (sides + 1) + k
			var b := a + sides + 1
			s.tri(a, b, a + 1)
			s.tri(a + 1, b, b + 1)


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
	var cell: int = FIR_CELLS[pick % FIR_CELLS.size()]
	var c0 := Vector2(cell % 4, cell / 4) * 0.25 + Vector2(0.004, 0.004)
	var c1 := c0 + Vector2(0.242, 0.242)
	var norm := along.cross(side).normalized()
	if norm.y < 0.0:
		norm = -norm
	var fold := norm * w * 0.18
	var start := base - along * l * 0.08
	var rows := [start, start + along * l * 0.5 + norm * l * 0.03, start + along * l]
	var first := s.v.size()
	for r in 3:
		var p: Vector3 = rows[r]
		var v := lerpf(c1.y, c0.y, r / 2.0)
		for k in 3:
			var x := (k - 1.0)
			var q := p + side * x * w * 0.5 - (fold if k != 1 else Vector3.ZERO)
			s.vert(q, _crown_normal(q, norm), Vector2(lerpf(c0.x, c1.x, k / 2.0), v),
				Vector2(Vector2(q.x, q.z).length(), 0.0), Color(_crown_ao(q) * ao, tint, 0.0, clampf(q.y / _h, 0.0, 1.0)))
	for r in 2:
		for k in 2:
			var a := first + r * 3 + k
			s.tri(a, a + 3, a + 1)
			s.tri(a + 1, a + 3, a + 4)


func _crown_normal(p: Vector3, card_n: Vector3) -> Vector3:
	# Out from the trunk with an upward bias, more so near the top.
	var axis := _spine_at(p.y)
	var out := Vector3(p.x - axis.x, 0.0, p.z - axis.z)
	var r := out.length()
	out = out / maxf(r, 0.001)
	var t := clampf(p.y / _h, 0.0, 1.0)
	var n := (out + Vector3.UP * lerpf(0.45, 1.2, t)).normalized()
	return (n * 0.8 + card_n * 0.2).normalized()


func _crown_ao(p: Vector3) -> float:
	var axis := _spine_at(p.y)
	var r := Vector2(p.x - axis.x, p.z - axis.z).length()
	var t := clampf(p.y / _h, 0.0, 1.0)
	var out := clampf(r / maxf(_h * 0.22 * (1.0 - t) + 0.3, 0.3), 0.0, 1.0)
	return lerpf(0.35, 1.0, smoothstep(0.0, 1.0, out)) * lerpf(0.75, 1.0, t)


# ---------------------------------------------------------------- output

func mesh(parts: Array, bark_mat: Material, leaf_mat: Material) -> ArrayMesh:
	var m := ArrayMesh.new()
	var b: Surf = parts[0]
	var l: Surf = parts[1]
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, b.arrays())
	m.surface_set_material(0, bark_mat)
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, l.arrays())
	m.surface_set_material(1, leaf_mat)
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

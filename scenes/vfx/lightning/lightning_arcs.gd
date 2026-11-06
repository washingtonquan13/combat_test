extends MeshInstance3D
## The building block every electric effect draws with: a set of arcs,
## each a jagged polyline, drawn as camera-facing glowing ribbons by
## lightning_bolt.gdshader. The effects (lightning_strike.gd,
## lightning_cone.gd, ball_lightning.gd) only choose where arcs go and
## when, then call show_arcs(); this node owns the mesh and the material.
##
## channel() makes the jagged shape by midpoint displacement: the
## straight line from a to b is halved again and again, and each new
## midpoint is pushed sideways in proportion to its segment's length.
## fork() grows branches off an arc.

const BOLT_SHADER: Shader = preload("res://scenes/vfx/lightning/lightning_bolt.gdshader")


## One arc to draw.
class Arc:
	var points: PackedVector3Array
	## Ribbon half width (core plus halo), metres.
	var half_width: float = 0.2
	## Brightness relative to the rest of its kind.
	var weight: float = 1.0
	## Branches take the shader's branch_brightness, not main_brightness.
	var branch: bool = false
	## The shader's reveal coordinate at the arc's start and end: only
	## the part below `reveal` is drawn, so an arc can grow out.
	var reveal_from: float = 0.0
	var reveal_to: float = 0.0
	## Per-point reveal coordinates; when set, used instead of the lerp.
	var reveals: PackedFloat32Array = PackedFloat32Array()
	## Thin and fade toward the end, like a branch dying out.
	var tip_fade: bool = false
	## Fraction of the arc over which it fades in from its start.
	var root_fade: float = 0.0

	func _init(p_points: PackedVector3Array = PackedVector3Array(), p_half_width: float = 0.2) -> void:
		points = p_points
		half_width = p_half_width


var material: ShaderMaterial
## The widest half width shown, so culling leaves room for the ribbons.
var _widest: float = 0.0


func _init() -> void:
	material = ShaderMaterial.new()
	material.shader = BOLT_SHADER
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Midpoint displacement from a to b; 2^halvings + 1 points.
static func channel(a: Vector3, b: Vector3, halvings: int, roughness: float) -> PackedVector3Array:
	var points := PackedVector3Array([a, b])
	for g in halvings:
		var next := PackedVector3Array()
		for i in points.size() - 1:
			var p: Vector3 = points[i]
			var q: Vector3 = points[i + 1]
			var length: float = p.distance_to(q)
			var along: Vector3 = (q - p) / maxf(length, 1e-5)
			var push := Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0))
			push -= along * push.dot(along)
			next.append(p)
			next.append((p + q) * 0.5 + push.normalized() * randfn(0.0, 1.0) * length * roughness)
		next.append(points[points.size() - 1])
		points = next
	return points


## Branches off `parent` (two levels deep). `reach` is the longest
## branch from the parent's start; branches further along are shorter.
## `bias` bends them, e.g. down for a strike, outward for a cone.
static func fork(parent: Arc, chance: float, reach: float, halvings: int, roughness: float,
		half_width: float, bias: Vector3 = Vector3.ZERO, depth: int = 0) -> Array[Arc]:
	var out: Array[Arc] = []
	var pts: PackedVector3Array = parent.points
	var n: int = pts.size()
	for i in range(int(n * 0.08), int(n * 0.85)):
		if randf() >= chance:
			continue
		var t: float = float(i) / float(n - 1)
		var along: Vector3 = (pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var side := Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0))
		side = (side - along * side.dot(along)).normalized()
		var dir: Vector3 = (along + side * randf_range(0.6, 1.4) + bias).normalized()
		var length: float = randf_range(0.4, 1.0) * reach * (1.0 - t)
		var branch := Arc.new(channel(pts[i], pts[i] + dir * length, maxi(halvings - depth, 3), roughness * 1.2), half_width)
		branch.branch = true
		branch.tip_fade = true
		branch.weight = parent.weight
		branch.reveal_from = lerpf(parent.reveal_from, parent.reveal_to, t)
		# A branch grows about as fast as its parent does.
		var parent_len: float = _length(pts)
		var rate: float = (parent.reveal_to - parent.reveal_from) / maxf(parent_len, 1e-5)
		branch.reveal_to = branch.reveal_from + rate * _length(branch.points)
		out.append(branch)
		if depth == 0:
			out.append_array(fork(branch, chance * 1.5, length * 0.5, halvings, roughness, half_width * 0.6, bias, 1))
	return out


## Every point of `points` nudged by up to `amount` metres, the ends kept.
static func jittered(points: PackedVector3Array, amount: float) -> PackedVector3Array:
	var out: PackedVector3Array = points.duplicate()
	for i in range(1, out.size() - 1):
		out[i] += Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0)) * amount
	return out


static func _length(points: PackedVector3Array) -> float:
	var total: float = 0.0
	for i in points.size() - 1:
		total += points[i].distance_to(points[i + 1])
	return total


## Replaces what is drawn with `arcs`.
func show_arcs(arcs: Array[Arc]) -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	_widest = 0.0
	for arc in arcs:
		if arc.points.size() < 2:
			continue
		_widest = maxf(_widest, arc.half_width)
		var pts: PackedVector3Array = arc.points
		var n: int = pts.size()
		var first: int = verts.size()
		for i in n:
			var along: Vector3 = (pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]).normalized()
			var t: float = float(i) / float(n - 1)
			var weight: float = arc.weight
			var width: float = arc.half_width
			if arc.tip_fade:
				weight *= pow(1.0 - t, 0.8)
				width *= lerpf(1.0, 0.35, t)
			if arc.root_fade > 0.0:
				weight *= smoothstep(0.0, arc.root_fade, t)
			var reveal: float = arc.reveals[i] if arc.reveals.size() == n else lerpf(arc.reveal_from, arc.reveal_to, t)
			for s in [-1.0, 1.0]:
				verts.append(pts[i])
				normals.append(along)
				uvs.append(Vector2(s, t))
				uv2s.append(Vector2(width, 0.0))
				colours.append(Color(weight, reveal, 1.0 if arc.branch else 0.0, 1.0))
		for i in n - 1:
			var a: int = first + i * 2
			indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	if verts.is_empty():
		mesh = null
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	var built := ArrayMesh.new()
	built.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = built
	# The ribbons are pushed out sideways on the GPU, past the mesh's box.
	extra_cull_margin = _widest * 4.0


## Sets the shader's per-frame knobs.
func set_brightness(main: float, branches: float) -> void:
	material.set_shader_parameter("main_brightness", main)
	material.set_shader_parameter("branch_brightness", branches)


func set_reveal(reveal: float, tip: float) -> void:
	material.set_shader_parameter("reveal", reveal)
	material.set_shader_parameter("tip_strength", tip)

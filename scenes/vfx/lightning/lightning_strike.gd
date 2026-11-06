extends Node3D
## One lightning strike from the sky to this node's position, drawn by
## lightning_bolt.gdshader. It plays on its own from the moment it
## enters the tree and frees itself when it is done.
##
## A strike runs like real lightning:
##  1. The stepped leader: a dim, branching channel works its way down
##     from the cloud in jerky steps (leader_seconds).
##  2. The return stroke: when the leader touches the ground, the main
##     channel blazes, and a light flashes at the impact point.
##  3. Restrokes: one to three more flashes down the SAME channel,
##     each a little dimmer, with the fine kinks jittered so it crackles.
##     The branches go dark after the first stroke.
## The channel's shape is made by midpoint displacement: the straight
## line from cloud to ground is halved again and again, and each new
## midpoint is pushed sideways in proportion to its segment's length.

const BOLT_SHADER: Shader = preload("res://scenes/vfx/lightning/lightning_bolt.gdshader")

## Metres from the ground up to where the channel starts.
@export var height: float = 30.0
## How far sideways, at most, the top sits from the impact point.
@export var lean: float = 5.0
## Halvings of the main channel. 7 gives 129 points.
@export_range(3, 9) var generations: int = 7
## Sideways push of each midpoint, as a fraction of its segment's length.
@export var roughness: float = 0.22
## Half widths of the ribbons (core plus halo), metres.
@export var main_half_width: float = 0.35
@export var branch_half_width: float = 0.2
## Chance a point on the main channel forks a branch.
@export var branch_chance: float = 0.08
@export var leader_seconds: float = 0.3
## Main channel brightness at the peak of the first stroke.
@export var stroke_gain: float = 6.0
## Light energy at the peak of the first stroke.
@export var light_energy: float = 14.0
@export var light_range: float = 22.0
@export var light_color: Color = Color(0.75, 0.82, 1.0)

var _material: ShaderMaterial
var _bolt: MeshInstance3D
var _light: OmniLight3D
var _main: PackedVector3Array
var _branches: Array[PackedVector3Array] = []
var _leader_steps: PackedVector2Array  # (seconds, reveal)
var _strokes: PackedVector2Array  # (seconds, peak)
var _age: float = 0.0
var _life: float = 1.0
var _shown_stroke: int = -1


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = BOLT_SHADER
	_bolt = MeshInstance3D.new()
	_bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The ribbons are pushed out sideways on the GPU, past the mesh's box.
	_bolt.extra_cull_margin = main_half_width * 4.0
	_bolt.material_override = _material
	add_child(_bolt)
	_light = OmniLight3D.new()
	_light.position = Vector3(0.0, 1.5, 0.0)
	_light.omni_range = light_range
	_light.light_color = light_color
	_light.shadow_enabled = true
	_light.light_energy = 0.0
	add_child(_light)
	_plan()
	_rebuild(true, 0.0)
	_process(0.0)


## Shape and timeline for this strike.
func _plan() -> void:
	var angle: float = randf() * TAU
	var top := Vector3(cos(angle), 0.0, sin(angle)) * randf_range(0.3, 1.0) * lean
	top.y = height
	_main = _channel(top, Vector3.ZERO, generations, roughness)
	_branches.clear()
	_fork(_main, 0, branch_chance, main_half_width)
	# The leader comes down in irregular steps.
	_leader_steps = PackedVector2Array()
	var count: int = randi_range(9, 15)
	var weights: PackedFloat32Array = []
	var total: float = 0.0
	for i in count:
		var w: float = randf_range(0.4, 1.6)
		weights.append(w)
		total += w
	var reached: float = 0.0
	for i in count:
		reached += weights[i] / total
		_leader_steps.append(Vector2(leader_seconds * float(i) / float(count), reached))
	# The first stroke, then one to three more down the same channel.
	_strokes = PackedVector2Array([Vector2(leader_seconds, 1.0)])
	var t: float = leader_seconds
	var peak: float = 1.0
	for i in randi_range(1, 3):
		t += randf_range(0.06, 0.16)
		peak *= randf_range(0.55, 0.85)
		_strokes.append(Vector2(t, peak))
	_life = t + 0.6


## Midpoint displacement from a to b.
func _channel(a: Vector3, b: Vector3, halvings: int, rough: float) -> PackedVector3Array:
	var points := PackedVector3Array([a, b])
	for g in halvings:
		var next := PackedVector3Array()
		for i in points.size() - 1:
			var p: Vector3 = points[i]
			var q: Vector3 = points[i + 1]
			var length: float = p.distance_to(q)
			var along: Vector3 = (q - p) / length
			var push := Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0))
			push -= along * push.dot(along)
			next.append(p)
			next.append((p + q) * 0.5 + push.normalized() * randfn(0.0, 1.0) * length * rough)
		next.append(points[points.size() - 1])
		points = next
	return points


## Branches off `parent`, recursing one level into each branch.
func _fork(parent: PackedVector3Array, depth: int, chance: float, half_width: float) -> void:
	var n: int = parent.size()
	for i in range(int(n * 0.08), int(n * 0.85)):
		if randf() >= chance:
			continue
		var start: Vector3 = parent[i]
		var along: Vector3 = (parent[mini(i + 1, n - 1)] - parent[maxi(i - 1, 0)]).normalized()
		var out := Vector3(randfn(0.0, 1.0), 0.0, randfn(0.0, 1.0)).normalized()
		var dir: Vector3 = (along + out * randf_range(0.6, 1.4)).normalized()
		# Branches lean downward like the leader that made them.
		dir.y = minf(dir.y, -0.25)
		dir = dir.normalized()
		var reach: float = randf_range(0.12, 0.3) * height * (1.0 - float(i) / n) / (depth + 1.0)
		var end: Vector3 = start + dir * reach
		end.y = maxf(end.y, 0.3)
		var branch: PackedVector3Array = _channel(start, end, maxi(generations - 2 - depth, 3), roughness * 1.2)
		_branches.append(branch)
		if depth == 0:
			_fork(branch, 1, chance * 1.5, half_width * 0.6)


## Rebuilds the mesh. Restrokes jitter every point a little, and drop
## the branches.
func _rebuild(with_branches: bool, jitter: float) -> void:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	var main: PackedVector3Array = _main
	if jitter > 0.0:
		main = main.duplicate()
		for i in range(1, main.size() - 1):
			main[i] += Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0)) * jitter
	_strip(main, main_half_width, false, verts, normals, uvs, uv2s, colours, indices)
	if with_branches:
		for branch in _branches:
			_strip(branch, branch_half_width, true, verts, normals, uvs, uv2s, colours, indices)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_bolt.mesh = mesh


func _strip(points: PackedVector3Array, half_width: float, branch: bool,
		verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
		uv2s: PackedVector2Array, colours: PackedColorArray, indices: PackedInt32Array) -> void:
	var n: int = points.size()
	var first: int = verts.size()
	for i in n:
		var p: Vector3 = points[i]
		var along: Vector3 = (points[mini(i + 1, n - 1)] - points[maxi(i - 1, 0)]).normalized()
		var t: float = float(i) / float(n - 1)
		var drop: float = clampf(1.0 - p.y / height, 0.0, 1.0)
		var weight: float
		var width: float
		if branch:
			# Branches thin and fade toward their tips.
			weight = pow(1.0 - t, 0.8)
			width = half_width * lerpf(1.0, 0.35, t)
		else:
			# The main channel fades out into the cloud at the top.
			weight = smoothstep(0.0, 0.08, drop)
			width = half_width
		for s in [-1.0, 1.0]:
			verts.append(p)
			normals.append(along)
			uvs.append(Vector2(s, t))
			uv2s.append(Vector2(width, 0.0))
			colours.append(Color(weight, drop, 1.0 if branch else 0.0, 1.0))
	for i in n - 1:
		var a: int = first + i * 2
		indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])


func _process(delta: float) -> void:
	_age += delta
	if _age >= _life:
		queue_free()
		return
	# Which stroke is the latest one so far; a new one reshapes the bolt.
	var latest: int = -1
	for i in _strokes.size():
		if _age >= _strokes[i].x:
			latest = i
	if latest != _shown_stroke:
		_shown_stroke = latest
		if latest >= 1:
			_rebuild(false, 0.06)
	var flash: float = 0.0
	for i in latest + 1:
		var dt: float = _age - _strokes[i].x
		flash = maxf(flash, _strokes[i].y * (exp(-dt / 0.03) + 0.18 * exp(-dt / 0.15)))
	var reveal: float = 1.0
	var tip: float = 0.0
	var leader_glow: float = 0.0
	if latest < 0:
		reveal = 0.0
		for step in _leader_steps:
			if _age >= step.x:
				reveal = step.y
		tip = 2.0
		leader_glow = 0.35
	var first_dt: float = maxf(_age - leader_seconds, 0.0)
	var branch_glow: float = 0.35 if latest < 0 else 2.0 * exp(-first_dt / 0.05)
	_material.set_shader_parameter("reveal", reveal)
	_material.set_shader_parameter("tip_strength", tip)
	_material.set_shader_parameter("main_brightness", leader_glow + flash * stroke_gain)
	_material.set_shader_parameter("branch_brightness", branch_glow)
	# The leader flickers the light faintly; the strokes flash it.
	var leader_light: float = randf_range(0.2, 0.6) * reveal if latest < 0 else 0.0
	_light.light_energy = leader_light + flash * light_energy

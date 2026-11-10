extends Node3D

## Look test for one corner of the Old Quarry: visuals only, no collision, no
## gameplay. Follows the blockout's layout (pit x -14..14, z -60..-34, floor
## y -6, rim y 0, ramp x 10..14 from z -46 at the top to z -34 at the bottom).
## Records with --write-movie, or set QUARRY_PERF=1 to print frame times.

const M := "res://assets/level/quarry/models/"
const T := "res://assets/level/quarry/textures/"
const X_MIN := -30.0
const X_MAX := 48.0
const Z_MIN := -92.0
const Z_MAX := -16.0
const CELL := 0.35
const GRASS_CHUNK := 8.0
const GRASS_PER_M2 := 18.0

const SHOTS := [
	# [from, to, look_at_from, look_at_to, seconds]
	[Vector3(26, 16, -30), Vector3(14, 16, -28), Vector3(4, -5, -48), Vector3(4, -5, -46), 6.0],
	[Vector3(22, 6, -36), Vector3(18, 5, -40), Vector3(11, -3, -42), Vector3(9, -4, -40), 5.0],
	[Vector3(27, 10, -60), Vector3(21, 9, -55), Vector3(8, -4, -46), Vector3(6, -4, -48), 5.0],
	[Vector3(-5, 3, -36), Vector3(2, 3, -37), Vector3(4, -5.5, -52), Vector3(9, -5.5, -52), 5.0],
]

var _rng := RandomNumberGenerator.new()
var _warp := FastNoiseLite.new()
var _big := FastNoiseLite.new()
var _small := FastNoiseLite.new()
var _patch := FastNoiseLite.new()
var _camera: Camera3D
var _env: Environment
var _sun: DirectionalLight3D
var _fire: OmniLight3D
var _grass_root: Node3D
var _time := 0.0
var _open_cache := {}
var _shot := 0
var _perf := false
var _perf_stage := -1
var _perf_clock := 0.0
var _perf_frames := 0
var _perf_seconds := 0.0
const PERF_STAGES := ["everything", "no volumetric fog", "no SSAO", "no grass", "no shadows"]


func _ready() -> void:
	_perf = OS.get_environment("QUARRY_PERF") == "1"
	_rng.seed = 41
	_warp.seed = 3
	_warp.frequency = 0.09
	_big.seed = 8
	_big.frequency = 0.05
	_small.seed = 12
	_small.frequency = 0.35
	_patch.seed = 21
	_patch.frequency = 0.11
	_build_lighting()
	_build_ground()
	_dress_ground()
	_build_fire(Vector3(0, -6, -48))
	_build_grass()
	_add_people()
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.far = 300.0
	add_child(_camera)
	_place_camera()
	if _perf:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0


func _smooth(a: float, b: float, v: float) -> float:
	return smoothstep(a, b, v) if a < b else 1.0 - smoothstep(b, a, v)


func _rect_sdf(x: float, z: float, cx: float, cz: float, hx: float, hz: float) -> float:
	var dx := absf(x - cx) - hx
	var dz := absf(z - cz) - hz
	return Vector2(maxf(dx, 0.0), maxf(dz, 0.0)).length() + minf(maxf(dx, dz), 0.0)


func _pit_d(x: float, z: float) -> float:
	return _rect_sdf(x, z, 0.0, -47.0, 14.0, 13.0) + _warp.get_noise_2d(x, z) * 1.5 + _small.get_noise_2d(x * 1.3, z * 1.3) * 0.35


func _ramp_y(z: float) -> float:
	return -6.0 * clampf((z + 46.0) / 12.0, 0.0, 1.0)


func _on_ramp(x: float, z: float) -> float:
	var jx := x + _warp.get_noise_2d(x * 2.0, z * 2.0) * 0.8
	return _smooth(14.9, 14.0, jx) * _smooth(9.4, 10.0, jx) * _smooth(-47.5, -46.0, z) * _smooth(-32.8, -34.0, z)


func _path(x: float, z: float) -> float:
	# A worn track from the top of the ramp out across the east rim.
	var centre := -44.5 + sin(x * 0.22) * 1.4
	return _smooth(1.8, 0.6, absf(z - centre)) * _smooth(13.0, 14.5, x)


func _ground_y(x: float, z: float) -> float:
	var d := _pit_d(x, z)
	var floor_y := -6.0 + _big.get_noise_2d(x, z) * 0.2 + _small.get_noise_2d(x, z) * 0.04
	var rim_y := _big.get_noise_2d(x + 40.0, z) * 0.75 + _small.get_noise_2d(x, z) * 0.06
	var h := lerpf(floor_y, rim_y, smoothstep(-1.4, 0.4, d))
	var ledge := _rect_sdf(x, z, 0.0, -58.0, 5.0, 2.0) + _warp.get_noise_2d(x + 9.0, z) * 0.5
	h = maxf(h, lerpf(-6.5, -3.0 + _small.get_noise_2d(x, z) * 0.05, smoothstep(0.5, -0.5, ledge)))
	var ry := _ramp_y(z) + _small.get_noise_2d(x, z) * 0.08 + _big.get_noise_2d(x + 7.0, z) * 0.14
	var bank_window := _smooth(-47.5, -46.4, z) * _smooth(-32.8, -33.6, z)
	if bank_window > 0.0:
		var jx := x + _warp.get_noise_2d(x * 2.0, z * 2.0) * 0.8
		if jx < 10.0:
			h = lerpf(h, maxf(h, ry - (10.0 - jx) * 1.7), bank_window)
		h = lerpf(h, ry, _on_ramp(x, z))
	return h


func _normal_at(x: float, z: float) -> Vector3:
	var e := CELL
	return Vector3(_ground_y(x - e, z) - _ground_y(x + e, z), 2.0 * e, _ground_y(x, z - e) - _ground_y(x, z + e)).normalized()


func _grassiness(x: float, z: float) -> float:
	var d := _pit_d(x, z)
	var n := _patch.get_noise_2d(x, z)
	var rim := smoothstep(0.1, 1.5, d) * smoothstep(-0.35, 0.1, n)
	var pit := smoothstep(-2.0, -5.5, d) * smoothstep(0.2, 0.5, n) * 0.0
	var edge := smoothstep(-7.5, -3.0, d) * smoothstep(-1.0, -2.2, d) * smoothstep(0.05, 0.4, n)
	return clampf(maxf(maxf(rim, pit), edge) - _path(x, z) * 1.5 - _on_ramp(x, z) * 2.0, 0.0, 1.0)


func _splat(x: float, z: float, n: Vector3) -> Color:
	var d := _pit_d(x, z)
	var slope := 1.0 - n.y
	var rock := smoothstep(0.16, 0.36, slope)
	var ramp := _on_ramp(x, z)
	rock *= 1.0 - ramp
	var grass := _grassiness(x, z)
	var floor_zone := smoothstep(-1.2, -3.0, d) * (1.0 - grass)
	var mottle := smoothstep(-0.45, 0.45, _patch.get_noise_2d(x * 0.9 + 50.0, z * 0.9))
	var bedrock := smoothstep(0.26, 0.46, _patch.get_noise_2d(x * 0.8 - 30.0, z * 0.8)) * floor_zone
	rock = maxf(rock, bedrock * 0.8 * (1.0 - ramp))
	var dirt := maxf(maxf(ramp * lerpf(0.5, 1.0, mottle), _path(x, z)), floor_zone * lerpf(0.25, 1.0, mottle))
	var soil := clampf(1.0 - dirt - grass, 0.0, 1.0)
	return Color(rock, soil * (1.0 - rock), grass * (1.0 - rock), dirt * (1.0 - rock))


func _build_ground() -> void:
	var nx := int((X_MAX - X_MIN) / CELL) + 1
	var nz := int((Z_MAX - Z_MIN) / CELL) + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(nx * nz)
	norms.resize(nx * nz)
	colors.resize(nx * nz)
	var idx := 0
	for iz in nz:
		for ix in nx:
			var x := X_MIN + ix * CELL
			var z := Z_MIN + iz * CELL
			var n := _normal_at(x, z)
			verts[idx] = Vector3(x, _ground_y(x, z), z)
			norms[idx] = n
			colors[idx] = _splat(x, z, n)
			idx += 1
	var tris := PackedInt32Array()
	tris.resize((nx - 1) * (nz - 1) * 6)
	var t := 0
	for iz in nz - 1:
		for ix in nx - 1:
			var a := ix + iz * nx
			var b := a + 1
			var c := a + nx
			var d := c + 1
			tris[t] = a
			tris[t + 1] = b
			tris[t + 2] = c
			tris[t + 3] = b
			tris[t + 4] = d
			tris[t + 5] = c
			t += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = tris
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://world/goblin_quarry/quarry_ground.gdshader")
	for layer: Array in [["rock", "rock_face_03"], ["soil", "forest_ground_04"], ["grass", "grass_path_2"], ["dirt", "dirt_floor"]]:
		mat.set_shader_parameter(layer[0] + "_albedo", load(T + layer[1] + "_diff_2k.jpg"))
		mat.set_shader_parameter(layer[0] + "_normal", load(T + layer[1] + "_nor_gl_2k.jpg"))
		mat.set_shader_parameter(layer[0] + "_arm", load(T + layer[1] + "_arm_2k.jpg"))
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = mesh
	ground.material_override = mat
	add_child(ground)


## Every mesh in a model file, so a set of six rocks can be placed one at a time.
func _meshes_of(file: String) -> Array[Mesh]:
	var out: Array[Mesh] = []
	var scene: Node = (load(M + file + ".glb") as PackedScene).instantiate()
	for mi: Node in scene.find_children("*", "MeshInstance3D", true, false):
		out.append((mi as MeshInstance3D).mesh)
	scene.free()
	return out


func _place(mesh: Mesh, at: Vector3, yaw: float, size: float, tilt := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var b := Basis(Vector3.UP, yaw).rotated(Vector3.RIGHT.rotated(Vector3.UP, yaw), tilt).scaled(Vector3.ONE * size)
	var c := mesh.get_aabb().get_center()
	mi.transform = Transform3D(b, at - b * c)
	add_child(mi)
	return mi


## Which way the open side of a scanned shell faces: the middle of its bare
## edges, seen from the middle of the mesh. Seams are welded first.
func _open_dir(mesh: Mesh) -> Vector3:
	if _open_cache.has(mesh):
		return _open_cache[mesh]
	var arrays := mesh.surface_get_arrays(0)
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var ind: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var ids := PackedInt32Array()
	ids.resize(pos.size())
	var weld := {}
	var welded: Array[Vector3] = []
	var centre := Vector3.ZERO
	for i in pos.size():
		var key := Vector3i(pos[i] * 2000.0)
		if not weld.has(key):
			weld[key] = welded.size()
			welded.append(pos[i])
			centre += pos[i]
		ids[i] = weld[key]
	centre /= maxf(welded.size(), 1.0)
	var edges := {}
	for t in range(0, ind.size(), 3):
		for e in 3:
			var a := ids[ind[t + e]]
			var b := ids[ind[t + (e + 1) % 3]]
			var key := mini(a, b) * 100000 + maxi(a, b)
			edges[key] = edges.get(key, 0) + 1
	var sum := Vector3.ZERO
	var count := 0
	for key: int in edges:
		if edges[key] == 1:
			sum += welded[key / 100000] + welded[key % 100000]
			count += 2
	var dir := Vector3.DOWN if count == 0 else (sum / count - centre).normalized()
	_open_cache[mesh] = dir
	return dir


## Places a scan with its open side turned toward `away`. `sink` is how much of
## the height stays below `at`.
func _is_upright(mesh: Mesh, away: Vector3) -> bool:
	var size := (Transform3D(Basis(Quaternion(_open_dir(mesh), away.normalized())), Vector3.ZERO) * mesh.get_aabb()).size
	return size.y > 1.1 * minf(size.x, size.z)


func _place_shut(mesh: Mesh, at: Vector3, away: Vector3, roll: float, size: float, sink: float) -> MeshInstance3D:
	var turn := Basis(Quaternion(_open_dir(mesh), away.normalized()))
	var b := Basis(away.normalized(), roll) * turn
	b = b.scaled(Vector3.ONE * size)
	var aabb := mesh.get_aabb()
	var height := (Transform3D(b, Vector3.ZERO) * aabb).size.y
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = Transform3D(b, at + Vector3.UP * height * (0.5 - sink) - b * aabb.get_center())
	add_child(mi)
	return mi


func _dress_ground() -> void:
	var moss: Array[Mesh] = _meshes_of("rock_moss_set_01")
	moss.append_array(_meshes_of("rock_moss_set_02"))
	var fern: Array[Mesh] = _meshes_of("fern_02")
	var shrub: Array[Mesh] = _meshes_of("shrub_03")
	var stump: Mesh = _meshes_of("tree_stump_01")[0]
	var trunk: Mesh = _meshes_of("dead_tree_trunk_02")[0]
	var branches: Array[Mesh] = _meshes_of("dry_branches_medium_01")

	# Boulders in loose groups on the rim, at the wall foot and now and then on
	# the floor. Rocks that would stand on end are skipped.
	var groups: Array[Vector2] = []
	var tries := 0
	while groups.size() < 12 and tries < 400:
		tries += 1
		var c := Vector2(_rng.randf_range(-8.0, 36.0), _rng.randf_range(-70.0, -24.0))
		var d := _pit_d(c.x, c.y)
		var on_rim := d > 1.0 and d < 6.0
		if not (on_rim or absf(d + 2.6) < 0.9 or (d < -2.0 and _rng.randf() < 0.15)):
			continue
		if _on_ramp(c.x, c.y) > 0.05 or _path(c.x, c.y) > 0.1 or c.distance_to(Vector2(0, -48)) < 4.0:
			continue
		var clear := true
		for other: Vector2 in groups:
			if other.distance_to(c) < 6.5:
				clear = false
		if not clear:
			continue
		groups.append(c)
		var placed := 0
		var attempts := 0
		var want := _rng.randi_range(2, 4)
		while placed < want and attempts < 12:
			attempts += 1
			var m: Mesh = moss[_rng.randi() % moss.size()]
			var away := Vector3.DOWN + Vector3(_rng.randf_range(-0.15, 0.15), 0.0, _rng.randf_range(-0.15, 0.15))
			if _is_upright(m, away):
				continue
			var off := Vector2.ZERO if placed == 0 else Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(0.6, 1.3)
			var p := c + off
			var at := Vector3(p.x, _ground_y(p.x, p.y), p.y)
			var size: float
			if on_rim:
				size = _rng.randf_range(0.32, 0.5) if placed == 0 else _rng.randf_range(0.14, 0.26)
			else:
				size = _rng.randf_range(0.3, 0.42) if placed == 0 else _rng.randf_range(0.12, 0.22)
			_place_shut(m, at, away, _rng.randf() * TAU, size, 0.3)
			placed += 1

	# Loose stones on the worked floor.
	var stones: Array[Mesh] = _meshes_of("rock_07")
	stones.append_array(_meshes_of("rock_09"))
	for i in 34:
		var x := _rng.randf_range(-12.0, 13.0)
		var z := _rng.randf_range(-57.0, -35.0)
		var m: Mesh = stones[_rng.randi() % stones.size()]
		if _is_upright(m, Vector3.DOWN):
			continue
		var at := Vector3(x, _ground_y(x, z), z)
		_place_shut(m, at, Vector3.DOWN, _rng.randf() * TAU, _rng.randf_range(0.9, 2.6), 0.3)

	# Plants tucked against rock and in the grass, never in the open.
	for i in 260:
		var x := _rng.randf_range(-8.0, 36.0)
		var z := _rng.randf_range(-70.0, -24.0)
		var d := _pit_d(x, z)
		var near_wall := absf(d + 2.2) < 1.2 or absf(d - 1.2) < 1.0
		if _normal_at(x, z).y < 0.75 or _on_ramp(x, z) > 0.1 or _path(x, z) > 0.2:
			continue
		if not near_wall and _grassiness(x, z) < 0.4:
			continue
		if _rng.randf() < 0.55:
			continue
		var at := Vector3(x, _ground_y(x, z), z)
		if _rng.randf() < 0.45:
			var m: Mesh = fern[_rng.randi() % fern.size()]
			at.y += m.get_aabb().size.y * 0.45
			_place(m, at, _rng.randf() * TAU, _rng.randf_range(0.8, 1.3))
		else:
			var m: Mesh = shrub[_rng.randi() % shrub.size()]
			var size := _rng.randf_range(1.6, 2.8)
			at.y += m.get_aabb().size.y * size * 0.45
			_place(m, at, _rng.randf() * TAU, size)

	_place(stump, Vector3(19.0, _ground_y(19, -40) + 0.2, -40.0), 0.9, 1.0)
	_place(trunk, Vector3(23.5, _ground_y(23.5, -52) + 0.36, -52.0), 2.2, 1.15)
	_place(trunk, Vector3(6.0, -5.65, -37.8), 0.4, 0.8, 0.05)
	_place(branches[0], Vector3(21.5, _ground_y(21.5, -50.5) + 0.2, -50.5), 1.0, 1.1)
	_place(branches[1], Vector3(7.4, -5.8, -39.0), 2.5, 1.3)
	_place(branches[2], Vector3(17.5, _ground_y(17.5, -39) + 0.1, -39.0), 0.2, 1.3)


func _build_fire(at: Vector3) -> void:
	var stone07: Mesh = _meshes_of("rock_07")[0]
	var stone09: Mesh = _meshes_of("rock_09")[0]
	for i in 10:
		var a := TAU * i / 10.0
		var p := at + Vector3(cos(a), 0.0, sin(a)) * 0.62
		p.y = _ground_y(p.x, p.z) + 0.06
		_place(stone07 if i % 2 == 0 else stone09, p, _rng.randf() * TAU, _rng.randf_range(0.8, 1.15) if i % 2 == 0 else 2.0)
	var logs: Array[Mesh] = _meshes_of("dry_branches_medium_01")
	for i in 3:
		var p := at + Vector3(0, 0.12, 0)
		_place(logs[i % logs.size()], p, TAU * i / 3.0, 0.75, 0.12)

	_fire = OmniLight3D.new()
	_fire.position = at + Vector3(0, 0.7, 0)
	_fire.light_color = Color(1.0, 0.55, 0.22)
	_fire.light_energy = 1.8
	_fire.omni_range = 9.0
	_fire.omni_attenuation = 1.6
	_fire.shadow_enabled = true
	add_child(_fire)

	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.62, 0.2, 0.75))
	grad.set_color(1, Color(1.0, 0.25, 0.04, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex
	mat.albedo_color = Color(0.95, 0.62, 0.36)
	var quad := QuadMesh.new()
	quad.size = Vector2(0.42, 0.6)
	quad.material = mat
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 8.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.1
	pm.gravity = Vector3(0, 0.5, 0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.2
	pm.scale_min = 0.45
	pm.scale_max = 1.0
	var fade := CurveTexture.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.7))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1, 0.0))
	fade.curve = curve
	pm.scale_curve = fade
	var flame := GPUParticles3D.new()
	flame.amount = 14
	flame.lifetime = 0.9
	flame.preprocess = 2.0
	flame.process_material = pm
	flame.draw_pass_1 = quad
	flame.position = at + Vector3(0, 0.15, 0)
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flame)


func _blade_clump() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for b in 10:
		var yaw := rng.randf() * TAU
		var root := Vector3(rng.randf_range(-0.16, 0.16), 0.0, rng.randf_range(-0.16, 0.16))
		var height := rng.randf_range(0.15, 0.3)
		var lean := Vector3(cos(yaw), 0.0, sin(yaw)) * rng.randf_range(0.05, 0.14)
		var side := Vector3(-sin(yaw), 0.0, cos(yaw)) * 0.015
		var start := verts.size()
		for s in 3:
			var t := s / 2.0
			var c := root + Vector3.UP * height * t + lean * t * t
			var w := side * (1.0 - t * 0.9)
			verts.append(c - w)
			verts.append(c + w)
			uvs.append(Vector2(0.0, t))
			uvs.append(Vector2(1.0, t))
			norms.append(Vector3.UP)
			norms.append(Vector3.UP)
		for q: int in [0, 2]:
			idx.append_array([start + q, start + q + 1, start + q + 2, start + q + 1, start + q + 3, start + q + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_grass() -> void:
	_grass_root = Node3D.new()
	_grass_root.name = "Grass"
	add_child(_grass_root)
	var clump := _blade_clump()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://world/goblin_quarry/quarry_grass.gdshader")
	clump.surface_set_material(0, mat)
	var per_chunk := int(GRASS_CHUNK * GRASS_CHUNK * GRASS_PER_M2)
	var cx := X_MIN
	while cx < X_MAX:
		var cz := Z_MIN
		while cz < Z_MAX:
			var spots: Array[Transform3D] = []
			var tints: Array[Color] = []
			for i in per_chunk:
				var x := cx + _rng.randf() * GRASS_CHUNK
				var z := cz + _rng.randf() * GRASS_CHUNK
				var g := _grassiness(x, z)
				if g < 0.08 or g < _rng.randf() * 0.6:
					continue
				if _normal_at(x, z).y < 0.84:
					continue
				var size := _rng.randf_range(0.7, 1.35) * lerpf(0.5, 1.1, g)
				var b := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * size)
				spots.append(Transform3D(b, Vector3(x, _ground_y(x, z) - 0.02, z)))
				var v := _patch.get_noise_2d(x * 2.0, z * 2.0)
				tints.append(Color(1.0 + v * 0.3 + _rng.randf() * 0.1, 1.0 + _rng.randf() * 0.12, 0.85 + v * 0.2))
			if not spots.is_empty():
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_colors = true
				mm.mesh = clump
				mm.instance_count = spots.size()
				for i in spots.size():
					mm.set_instance_transform(i, spots[i])
					mm.set_instance_color(i, tints[i])
				var inst := MultiMeshInstance3D.new()
				inst.multimesh = mm
				inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				inst.visibility_range_end = 48.0
				_grass_root.add_child(inst)
			cz += GRASS_CHUNK
		cx += GRASS_CHUNK


func _add_people() -> void:
	for spot: Vector3 in [Vector3(11.8, -3.0, -40.0), Vector3(2.0, -5.95, -46.4), Vector3(18.0, 0.0, -44.2)]:
		var person: Node3D = (load("res://assets/UAL1_Standard.glb") as PackedScene).instantiate()
		spot.y = _ground_y(spot.x, spot.z)
		person.position = spot
		person.rotation.y = _rng.randf() * TAU
		add_child(person)
		var player: AnimationPlayer = person.find_child("AnimationPlayer", true, false)
		if player == null:
			continue
		for anim: StringName in player.get_animation_list():
			if String(anim).to_lower().begins_with("idle"):
				var a := player.get_animation(anim)
				a.loop_mode = Animation.LOOP_LINEAR
				player.play(anim)
				break


func _build_lighting() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.47, 0.72)
	sky_mat.sky_horizon_color = Color(0.78, 0.74, 0.66)
	sky_mat.ground_horizon_color = Color(0.45, 0.42, 0.36)
	sky_mat.ground_bottom_color = Color(0.2, 0.16, 0.11)
	sky_mat.sun_angle_max = 18.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.ambient_light_energy = 0.75
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	_env.tonemap_exposure = 1.0
	_env.tonemap_white = 6.0
	_env.ssao_enabled = true
	_env.ssao_radius = 1.4
	_env.ssao_intensity = 1.8
	_env.ssao_light_affect = 0.15
	_env.glow_enabled = true
	_env.glow_intensity = 0.5
	_env.glow_bloom = 0.03
	_env.glow_hdr_threshold = 1.1
	_env.volumetric_fog_enabled = true
	_env.volumetric_fog_density = 0.006
	_env.volumetric_fog_albedo = Color(1.0, 0.96, 0.9)
	_env.volumetric_fog_anisotropy = 0.55
	_env.volumetric_fog_length = 70.0
	_env.volumetric_fog_ambient_inject = 0.35
	_env.adjustment_enabled = true
	_env.adjustment_saturation = 1.0
	_env.adjustment_contrast = 1.04
	var world := WorldEnvironment.new()
	world.environment = _env
	add_child(world)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-38.0, -62.0, 0.0)
	_sun.light_color = Color(1.0, 0.93, 0.8)
	_sun.light_energy = 2.3
	_sun.light_angular_distance = 1.0
	_sun.shadow_enabled = true
	_sun.shadow_opacity = 0.92
	_sun.directional_shadow_max_distance = 75.0
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun.light_volumetric_fog_energy = 1.4
	add_child(_sun)


func _place_camera() -> void:
	var shot: Array = SHOTS[_shot]
	var t: float = clampf(_time / float(shot[4]), 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)
	var from: Vector3 = shot[0]
	var to: Vector3 = shot[1]
	var look_a: Vector3 = shot[2]
	var look_b: Vector3 = shot[3]
	_camera.look_at_from_position(from.lerp(to, t), look_a.lerp(look_b, t))


func _process(delta: float) -> void:
	if _fire != null:
		var t := Time.get_ticks_msec() * 0.001 if _perf else _time + _shot * 7.0
		_fire.light_energy = 1.8 + sin(t * 11.0) * 0.2 + sin(t * 23.0) * 0.14
	_time += delta
	if _perf:
		_run_perf(delta)
		return
	if _time >= float(SHOTS[_shot][4]):
		_time = 0.0
		_shot += 1
		if _shot >= SHOTS.size():
			get_tree().quit()
			return
	_place_camera()


## Holds the widest game-camera view and prints the cost of each feature.
func _run_perf(delta: float) -> void:
	_perf_clock += delta
	_shot = 0
	_time = minf(_time, 3.0)
	_place_camera()
	if _perf_stage < 0:
		if _perf_clock > 3.0:
			_next_perf_stage()
		return
	if _perf_clock > 1.0:
		_perf_frames += 1
		_perf_seconds += delta
	if _perf_clock > 6.0:
		var info := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		var calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		print("PERF %-20s %6.1f fps  %6.2f ms  tris %d  draws %d" % [PERF_STAGES[_perf_stage], _perf_frames / _perf_seconds, 1000.0 * _perf_seconds / _perf_frames, info, calls])
		_next_perf_stage()


func _next_perf_stage() -> void:
	_perf_stage += 1
	_perf_clock = 0.0
	_perf_frames = 0
	_perf_seconds = 0.0
	if _perf_stage >= PERF_STAGES.size():
		get_tree().quit()
		return
	_env.volumetric_fog_enabled = _perf_stage != 1
	_env.ssao_enabled = _perf_stage != 2
	_grass_root.visible = _perf_stage != 3
	_sun.shadow_enabled = _perf_stage != 4

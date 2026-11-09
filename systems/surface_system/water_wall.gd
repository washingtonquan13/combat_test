extends Node3D
## The Wall of Water visual, drawn to the CloudGrid cubes of one cast
## (show_cubes()): a tidal wave caught as it curls, a long slope rising
## out of the ground to a crest whose lip hooks out over the far side
## from its caster (lean_away_from()), above a steep hollow face. Water
## runs up its back, over the lip and down the face without end
## (water_wall.gdshader). It follows the cubes:
## stepping up a stair, cut where a wall stopped it, tapering at its ends,
## its crest swelling and sinking along its length. It rises from its
## middle out. Spray feathers off the crest and lip, and drops fall
## from its point. Columns run out recede (recede_cubes()): that stretch of the
## wave sinks over recede_seconds. When the last go, dissipate(): the wave
## collapses and fades, and it frees itself. The water left on the ground
## is Water's own visual.
##
## The mesh is built once, at full height; each frame only the stations'
## heights change (a one-row texture), and the shader settles the mesh to
## them (water_wall.gdshaderinc).

const SHEET_SHADER: Shader = preload("res://systems/surface_system/water_wall.gdshader")

## The wave's cross-section, x metres toward its front (away from its
## caster) from the wall's line, y its height as a fraction of the wall's:
## the back foot far behind, a long slope rising out of the ground, the
## crest, the lip hooked out over the front and down to a point, back
## under it into the hollow, down the steep concave face, and out along
## the trough in front.
const PROFILE: Array[Vector2] = [
	Vector2(-1.8, 0.0), Vector2(-1.3, 0.12), Vector2(-0.85, 0.32),
	Vector2(-0.45, 0.55), Vector2(-0.1, 0.75), Vector2(0.2, 0.9),
	Vector2(0.5, 0.98), Vector2(0.8, 1.0), Vector2(1.05, 0.96),
	Vector2(1.22, 0.88), Vector2(1.3, 0.8), Vector2(1.3, 0.72),
	Vector2(1.24, 0.67), Vector2(1.14, 0.7), Vector2(1.02, 0.76),
	Vector2(0.88, 0.79), Vector2(0.74, 0.77), Vector2(0.62, 0.7),
	Vector2(0.54, 0.58), Vector2(0.5, 0.44), Vector2(0.48, 0.3),
	Vector2(0.5, 0.16), Vector2(0.58, 0.06), Vector2(0.75, 0.01),
	Vector2(1.1, 0.0),
]
## How thick the water is at each of PROFILE's points, metres: deep in
## the body, thinning out to the lip's point.
const THICKNESS: Array[float] = [1.8,1.6,1.4,1.2,1.0,0.85,0.7,0.55,0.4,0.28,0.18,0.1,0.06,0.1,0.16,0.24,0.32,0.42,0.55,0.7,0.85,1.0,1.0,0.8,0.4]
## Which of PROFILE's points is the lip's point.
const TIP: int = 12
## Which of PROFILE's points the face under the lip runs between.
const BACK_WALL: Vector2i = Vector2i(19, 21)
## Points between each two of PROFILE's, smoothed through them.
const PROFILE_STEPS: int = 8
## Mesh rows between each two stations.
const ROWS_PER_STATION: int = 2
## The wall height PROFILE's 0..1 shares are laid out for.
const NOMINAL_HEIGHT: float = 4.0
## The tiling noise the water's streaks scroll through.
@export var streaks: Texture2D
## The ripples' normal map.
@export var ripples: Texture2D
@export var spray_per_metre: float = 6.0
@export var drips_per_metre: float = 3.0
## How long the wave takes to rise, and how long the rising takes to run
## from its middle out to its ends.
@export var rise_seconds: float = 0.9
@export var rise_spread: float = 0.35
## How long a receding stretch takes to sink.
@export var recede_seconds: float = 1.0
## How long the whole wave takes to collapse at the end.
@export var fade_seconds: float = 1.2
## How far in from each end the wave tapers down to nothing.
@export var taper: float = 1.6

## Which way each cube's wave faces, kept by cube so the wall a reaction
## turns it into (Electrified Wall of Water) faces the same way:
## key -> [the visual's instance id, the front as a world xz direction].
static var _fronts: Dictionary = {}

@onready var _sheet: MeshInstance3D = $Sheet
@onready var _spray: GPUParticles3D = $Spray
@onready var _drips: GPUParticles3D = $Drips

var _keys: Array[Vector3i] = []
## Each column's cubes still standing.
var _columns: Dictionary[Vector2i, Array] = {}
## The wall's line in world xz: through _centre along _axis, _normal
## across it, the wave's front _lean (+1 or -1) along _normal.
var _centre := Vector2.ZERO
var _axis := Vector2.RIGHT
var _normal := Vector2.UP
var _lean: float = 1.0
## One station every CloudGrid.CELL along the line, and a bare one past
## each end: where along it, how far off it, its foot and top in the
## world, its columns, and its burn (1 standing, falling to 0 as it
## recedes; 0 always where the cubes have a gap).
var _station_t := PackedFloat32Array()
var _station_s := PackedFloat32Array()
var _station_foot := PackedFloat32Array()
var _station_top := PackedFloat32Array()
var _station_burn := PackedFloat32Array()
var _station_columns: Array[Array] = []
## PROFILE smoothed, and each point's share of the way along it, its
## thickness, height share and reach toward the lip.
var _profile := PackedVector2Array()
var _profile_share := PackedFloat32Array()
var _profile_thickness := PackedFloat32Array()
var _lip: int = 0
var _crest: int = 0
var _tip: int = TIP * PROFILE_STEPS
## Seconds since it was placed, in game time, so a slow frame (the
## first one, building the mesh) can't skip the rise.
var _age: float = 0.0
var _risen: bool = false
var _strength: float = 1.0
var _material: ShaderMaterial
var _mesh := ArrayMesh.new()
## Each station's height now, for the shaders.
var _heights_image: Image
var _heights := ImageTexture.new()


func _ready() -> void:
	for emitter: GPUParticles3D in _emitters():
		var process := emitter.process_material.duplicate() as ParticleProcessMaterial
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
		emitter.process_material = process
		emitter.emitting = false
	_smooth_profile()
	_material = _make_material(SHEET_SHADER, _sheet, _mesh)
	_material.set_shader_parameter("ripples", ripples)


func _make_material(shader: Shader, instance: MeshInstance3D, mesh: ArrayMesh) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("streaks", streaks)
	material.set_shader_parameter("heights", _heights)
	instance.mesh = mesh
	instance.material_override = material
	# On the units' layer, which the water's decal on the ground leaves
	# out, or it would paint itself up the wave's feet.
	instance.layers = 1 << (Unit.RENDER_LAYER - 1)
	return material


func _materials() -> Array[ShaderMaterial]:
	return [_material]


func _exit_tree() -> void:
	for key in _keys:
		if _fronts.has(key) and _fronts[key][0] == get_instance_id():
			_fronts.erase(key)


func _emitters() -> Array[GPUParticles3D]:
	return [_spray, _drips]


## Raises the wave over cells (CloudCells). Called once, right after the
## wall is placed: an emitter's amount can't change later without it
## restarting.
func show_cubes(cells: Array) -> void:
	_age = 0.0
	var spans: Dictionary[Vector2i, Vector2] = {}
	for cell in cells:
		_keys.append(cell.key)
		var column := Vector2i(cell.key.x, cell.key.z)
		if not _columns.has(column):
			_columns[column] = []
			spans[column] = Vector2(INF, -INF)
		_columns[column].append(cell.key)
		spans[column] = Vector2(minf(spans[column].x, cell.key.y * CloudGrid.CELL), maxf(spans[column].y, (cell.key.y + 1) * CloudGrid.CELL))
	if _columns.is_empty():
		return
	_find_line()
	_face_as_before()
	_lay_stations(spans)
	_record_front()
	_heights_image = Image.create(_station_t.size(), 1, false, Image.FORMAT_RF)
	_heights.set_image(_heights_image)
	for material in _materials():
		material.set_shader_parameter("station_count", float(_station_t.size()))
	_rebuild()
	_update_heights()
	var length: float = _station_t[_station_t.size() - 1] - _station_t[0]
	var counts: Array[float] = [spray_per_metre * length, drips_per_metre * length]
	var emitters := _emitters()
	for e in emitters.size():
		emitters[e].amount = maxi(2, roundi(counts[e]))
		emitters[e].visibility_aabb = _mesh.get_aabb().grow(3.0)


## Faces the wave's front away from point (its caster), so the curl hangs
## over the far side.
func lean_away_from(point: Vector3) -> void:
	var side: float = (Vector2(point.x, point.z) - _centre).dot(_normal)
	_lean = -signf(side) if side != 0.0 else 1.0
	_record_front()
	_rebuild()
	if _risen:
		_emit_from_points()


## Stops the water in cells; a stretch of the wave sinks once all its
## columns' cubes go.
func recede_cubes(cells: Array) -> void:
	for cell in cells:
		var column := Vector2i(cell.key.x, cell.key.z)
		if _columns.has(column):
			_columns[column].erase(cell.key)
	if _risen:
		_emit_from_points()


func dissipate() -> void:
	for emitter: GPUParticles3D in _emitters():
		emitter.emitting = false
	var tween := create_tween()
	tween.tween_property(self, "_strength", 0.0, fade_seconds)
	# Long enough for the last spray to settle.
	tween.tween_interval(maxf(_spray.lifetime - fade_seconds, 0.0))
	tween.tween_callback(queue_free)


## The line the cubes run along: through their columns' middle, along
## the way they spread most.
func _find_line() -> void:
	var points: Array[Vector2] = []
	for column: Vector2i in _columns:
		points.append((Vector2(column) + Vector2.ONE * 0.5) * CloudGrid.CELL)
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	_centre = sum / points.size()
	var xx: float = 0.0
	var zz: float = 0.0
	var xz: float = 0.0
	for p in points:
		var d: Vector2 = p - _centre
		xx += d.x * d.x
		zz += d.y * d.y
		xz += d.x * d.y
	var angle: float = 0.5 * atan2(2.0 * xz, xx - zz)
	_axis = Vector2(cos(angle), sin(angle))
	_normal = Vector2(-_axis.y, _axis.x)


## A wall raised over cubes another wave held (a reaction turning it into
## Electrified Wall of Water) faces the way that one did.
func _face_as_before() -> void:
	for key in _keys:
		if _fronts.has(key):
			var front: Vector2 = _fronts[key][1]
			_lean = signf(front.dot(_normal)) if front.dot(_normal) != 0.0 else 1.0
			return


func _record_front() -> void:
	for key in _keys:
		_fronts[key] = [get_instance_id(), _normal * _lean]


func _lay_stations(spans: Dictionary[Vector2i, Vector2]) -> void:
	var lowest: float = INF
	var highest: float = -INF
	var along: Dictionary[Vector2i, Vector2] = {}
	for column: Vector2i in _columns:
		var d: Vector2 = (Vector2(column) + Vector2.ONE * 0.5) * CloudGrid.CELL - _centre
		along[column] = Vector2(d.dot(_axis), d.dot(_normal))
		lowest = minf(lowest, along[column].x)
		highest = maxf(highest, along[column].x)
	var step: float = CloudGrid.CELL
	# A bare station half a cube past each end, where the wave meets nothing.
	var first: float = lowest - step
	var count: int = roundi((highest - lowest) / step) + 3
	for i in count:
		_station_t.append(first + i * step)
		_station_s.append(0.0)
		_station_foot.append(NAN)
		_station_top.append(NAN)
		_station_burn.append(0.0)
		_station_columns.append([])
	var offsets: Dictionary[int, Array] = {}
	for column: Vector2i in _columns:
		var i: int = clampi(roundi((along[column].x - first) / step), 1, count - 2)
		_station_columns[i].append(column)
		offsets.get_or_add(i, []).append(along[column].y)
		var foot: float = _station_foot[i]
		var top: float = _station_top[i]
		_station_foot[i] = spans[column].x if is_nan(foot) else minf(foot, spans[column].x)
		_station_top[i] = spans[column].y if is_nan(top) else maxf(top, spans[column].y)
		_station_burn[i] = 1.0
	for i: int in offsets:
		var s: float = 0.0
		for o: float in offsets[i]:
			s += o
		_station_s[i] = s / offsets[i].size()
	# A station with no cubes (a gap, or an end) takes its ground from
	# the nearest that has some, and stays sunk.
	for i in count:
		if not is_nan(_station_foot[i]):
			continue
		for reach in count:
			for j: int in [i - reach, i + reach]:
				if j >= 0 and j < count and not _station_columns[j].is_empty():
					_station_foot[i] = _station_foot[j]
					_station_top[i] = _station_top[j]
					_station_s[i] = _station_s[j]
					break
			if not is_nan(_station_foot[i]):
				break


func _smooth_profile() -> void:
	_profile.clear()
	_profile_thickness.clear()
	var n: int = PROFILE.size()
	for i in n - 1:
		var p0: Vector2 = PROFILE[maxi(i - 1, 0)]
		var p1: Vector2 = PROFILE[i]
		var p2: Vector2 = PROFILE[i + 1]
		var p3: Vector2 = PROFILE[mini(i + 2, n - 1)]
		for k in PROFILE_STEPS:
			var f: float = float(k) / PROFILE_STEPS
			_profile.append(p1.cubic_interpolate(p2, p0, p3, f))
			_profile_thickness.append(lerpf(THICKNESS[i], THICKNESS[i + 1], f))
	_profile.append(PROFILE[n - 1])
	_profile_thickness.append(THICKNESS[n - 1])
	# Shares by the way along it at the nominal height, so the crest, lip
	# and feet fall where the shader expects them on a full-height wall.
	_profile_share.resize(_profile.size())
	var total: float = 0.0
	_profile_share[0] = 0.0
	for j in range(1, _profile.size()):
		total += (_scaled(_profile[j], NOMINAL_HEIGHT) - _scaled(_profile[j - 1], NOMINAL_HEIGHT)).length()
		_profile_share[j] = total
	for j in _profile.size():
		_profile_share[j] /= total
	for j in _profile.size():
		if _profile[j].x > _profile[_lip].x:
			_lip = j
		if _profile[j].y > _profile[_crest].y:
			_crest = j


func _scaled(point: Vector2, height: float) -> Vector2:
	return Vector2(point.x, point.y * height)


## Station i's height now, 0..1: rising from the middle out, sunk as it
## recedes, tapered at the ends, collapsing as the whole wave goes.
func _station_height(i: int) -> float:
	var t: float = _station_t[i]
	var reach: float = maxf(absf(_station_t[0]), absf(_station_t[_station_t.size() - 1]))
	var rise: float = clampf((_age - rise_spread * absf(t) / maxf(reach, 0.001)) / maxf(rise_seconds, 0.001), 0.0, 1.0)
	rise = rise * rise * (3.0 - 2.0 * rise)
	var end: float = minf(t - _station_t[0], _station_t[_station_t.size() - 1] - t)
	var tapered: float = smoothstep(0.0, taper, end)
	return _station_burn[i] * rise * tapered * _strength


## Where cross-section point p (PROFILE's units) of station i sits in the
## world, standing at height h (0..1).
func _place(i: int, p: Vector2, h: float = 1.0) -> Vector3:
	var height: float = (_station_top[i] - _station_foot[i]) * h
	var depth: float = lerpf(0.35, 1.0, h) * clampf(_station_top[i] - _station_foot[i], 1.0, NOMINAL_HEIGHT) / NOMINAL_HEIGHT
	var across: float = _station_s[i] + p.x * depth * _lean
	var flat: Vector2 = _centre + _axis * _station_t[i] + _normal * across
	return Vector3(flat.x, _station_foot[i] + p.y * height, flat.y)


## Where profile point j of station i sits in the world at height h (0..1).
func _point(i: int, j: int, h: float) -> Vector3:
	return _place(i, _profile[j], h)


func _rebuild() -> void:
	if _station_t.is_empty():
		return
	var lip_x: float = _profile[_lip].x
	var attrs: Array[Vector4] = []
	for j in _profile.size():
		attrs.append(Vector4(_profile_share[j], _profile_thickness[j], _profile[j].y, clampf(_profile[j].x / lip_x, 0.0, 1.0)))
	_mesh.clear_surfaces()
	_add_strip(_mesh, _profile, attrs)
	_sheet.custom_aabb = _mesh.get_aabb().grow(1.0)


## Adds a surface to mesh: path (PROFILE's units) swept along the
## stations at full height, attrs (water_wall.gdshaderinc's CUSTOM1) for
## each of its points.
func _add_strip(mesh: ArrayMesh, path: PackedVector2Array, attrs: Array[Vector4]) -> void:
	var stations: int = _station_t.size()
	var rows: int = (stations - 1) * ROWS_PER_STATION + 1
	var points: int = path.size()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var custom0 := PackedFloat32Array()
	var custom1 := PackedFloat32Array()
	vertices.resize(rows * points)
	normals.resize(rows * points)
	tangents.resize(rows * points * 4)
	uvs.resize(rows * points)
	custom0.resize(rows * points * 4)
	custom1.resize(rows * points * 4)
	var to_local_basis: Basis = global_transform.basis.inverse()
	var origin: Vector3 = global_position
	var across := Vector3(_normal.x, 0.0, _normal.y) * _lean
	var along_local: Vector3 = (to_local_basis * Vector3(_axis.x, 0.0, _axis.y)).normalized()
	for r in rows:
		var u: float = float(r) / ROWS_PER_STATION
		var i0: int = mini(floori(u), stations - 1)
		var i1: int = mini(i0 + 1, stations - 1)
		var f: float = u - i0
		var t: float = lerpf(_station_t[i0], _station_t[i1], f)
		var foot: Vector3 = to_local_basis * (_place(i0, Vector2.ZERO).lerp(_place(i1, Vector2.ZERO), f) - origin)
		var run: float = 0.0
		var previous := Vector3.ZERO
		for j in points:
			var world: Vector3 = _place(i0, path[j]).lerp(_place(i1, path[j]), f)
			var before: Vector3 = _place(i0, path[maxi(j - 1, 0)]).lerp(_place(i1, path[maxi(j - 1, 0)]), f)
			var after: Vector3 = _place(i0, path[mini(j + 1, points - 1)]).lerp(_place(i1, path[mini(j + 1, points - 1)]), f)
			if j > 0:
				run += world.distance_to(previous)
			previous = world
			# Across the sheet, in the plane the cross-section lies in.
			var down_path: Vector3 = after - before
			var flat: float = down_path.dot(across)
			var normal: Vector3 = (across * down_path.y - Vector3.UP * flat).normalized()
			if normal == Vector3.ZERO:
				normal = across
			var local_normal: Vector3 = to_local_basis * normal
			var index: int = r * points + j
			vertices[index] = to_local_basis * (world - origin)
			normals[index] = local_normal
			# The tangent runs along the wall, the binormal down the path.
			var tangent: Vector3 = (along_local - local_normal * along_local.dot(local_normal)).normalized()
			var sign: float = 1.0 if local_normal.cross(tangent).dot(to_local_basis * down_path) >= 0.0 else -1.0
			tangents[index * 4] = tangent.x
			tangents[index * 4 + 1] = tangent.y
			tangents[index * 4 + 2] = tangent.z
			tangents[index * 4 + 3] = sign
			uvs[index] = Vector2(t, run)
			custom0[index * 4] = foot.x
			custom0[index * 4 + 1] = foot.y
			custom0[index * 4 + 2] = foot.z
			custom0[index * 4 + 3] = u
			custom1[index * 4] = attrs[j].x
			custom1[index * 4 + 1] = attrs[j].y
			custom1[index * 4 + 2] = attrs[j].z
			custom1[index * 4 + 3] = attrs[j].w
	var indices := PackedInt32Array()
	for r in rows - 1:
		for j in points - 1:
			var a: int = r * points + j
			var b: int = a + points
			indices.append_array([a, b, a + 1, a + 1, b, b + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = custom0
	arrays[Mesh.ARRAY_CUSTOM1] = custom1
	arrays[Mesh.ARRAY_INDEX] = indices
	var format: int = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, format)


## Each station's height now into the shaders' texture.
func _update_heights() -> void:
	for i in _station_t.size():
		_heights_image.set_pixel(i, 0, Color(_station_height(i), 0.0, 0.0))
	_heights.update(_heights_image)


## Where on the standing wave (full height) spray and drips start, in
## this node's space.
func _emit_from_points() -> void:
	var spray := PackedVector3Array()
	var drips := PackedVector3Array()
	for i in _station_t.size():
		if _station_burn[i] < 1.0 or not _standing(i):
			continue
		spray.append(to_local(_point(i, _crest, 1.0)))
		spray.append(to_local(_point(i, _lip, 1.0)))
		drips.append(to_local(_point(i, _tip, 1.0)))
	var sets: Array[PackedVector3Array] = [spray, drips]
	var emitters := _emitters()
	var front := Vector3(_normal.x, 0.0, _normal.y) * _lean
	for e in emitters.size():
		var process := emitters[e].process_material as ParticleProcessMaterial
		if sets[e].is_empty():
			emitters[e].emitting = false
			continue
		var image := Image.create_from_data(sets[e].size(), 1, false, Image.FORMAT_RGBF, sets[e].to_byte_array())
		process.emission_point_texture = ImageTexture.create_from_image(image)
		process.emission_point_count = sets[e].size()
		if emitters[e] == _spray:
			process.direction = (front * 0.6 + Vector3.UP).normalized()
		emitters[e].emitting = _strength > 0.0


## Whether any of station i's columns still has cubes.
func _standing(i: int) -> bool:
	for column: Vector2i in _station_columns[i]:
		if not _columns[column].is_empty():
			return true
	return false


func _physics_process(delta: float) -> void:
	if _station_t.is_empty():
		return
	_age += delta
	var changed: bool = not _risen or _strength < 1.0
	if not _risen and _age > rise_spread + rise_seconds:
		_risen = true
		_emit_from_points()
	for i in _station_t.size():
		if _station_burn[i] > 0.0 and not _standing(i):
			_station_burn[i] = maxf(_station_burn[i] - delta / recede_seconds, 0.0)
			changed = true
	if changed:
		_update_heights()
	var up: Vector3 = (global_transform.basis.inverse() * Vector3.UP).normalized()
	var strength: float = clampf(_strength * 1.5, 0.0, 1.0)
	for material in _materials():
		material.set_shader_parameter("strength", strength)
		material.set_shader_parameter("up_local", up)

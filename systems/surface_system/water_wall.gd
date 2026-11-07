extends Node3D
## The Wall of Water visual, drawn to the CloudGrid cubes of one cast
## (show_cubes()): one sheet of water (water_wall.gdshader) shaped as a
## breaking wave caught at its peak, the crest curled over toward the far
## side from its caster (lean_away_from()), with water running up its
## back, over the lip and down its face without end. It follows the cubes:
## stepping up a stair, cut where a wall stopped it, tapering at its ends.
## It rises from its middle out. Spray hangs off the crest, drips fall
## from the lip and foam churns at its feet. Columns run out recede
## (recede_cubes()): that stretch of the wave sinks over recede_seconds.
## When the last go, dissipate(): the wave collapses and fades, and it
## frees itself. The water left on the ground is Water's own visual.

const SHEET_SHADER: Shader = preload("res://systems/surface_system/water_wall.gdshader")

## The wave's cross-section, x metres toward its front (away from its
## caster) from the wall's line, y its height as a fraction of the wall's:
## back foot, up the back, the crest, out to the lip, back under it into
## the barrel and down the face to the front foot.
const PROFILE: Array[Vector2] = [
	Vector2(-0.7, 0.0), Vector2(-0.64, 0.18), Vector2(-0.5, 0.42),
	Vector2(-0.26, 0.68), Vector2(0.08, 0.88), Vector2(0.55, 0.99),
	Vector2(1.05, 0.98), Vector2(1.5, 0.88), Vector2(1.82, 0.7),
	Vector2(1.94, 0.5), Vector2(1.84, 0.4), Vector2(1.58, 0.47),
	Vector2(1.2, 0.53), Vector2(0.82, 0.46), Vector2(0.56, 0.3),
	Vector2(0.52, 0.13), Vector2(0.66, 0.0),
]
## Points between each two of PROFILE's, smoothed through them.
const PROFILE_STEPS: int = 4
## The wall height PROFILE's 0..1 shares are laid out for.
const NOMINAL_HEIGHT: float = 4.0

## The tiling noise the water's streaks scroll through.
@export var streaks: Texture2D
## The Electrified Wall of Water's crackle, 0 for plain water.
@export var crackle: float = 0.0
@export var spray_per_metre: float = 4.0
@export var drips_per_metre: float = 6.0
@export var foam_per_metre: float = 3.0
## How long the wave takes to rise, and how long the rising takes to run
## from its middle out to its ends.
@export var rise_seconds: float = 0.9
@export var rise_spread: float = 0.35
## How long a receding stretch takes to sink.
@export var recede_seconds: float = 1.0
## How long the whole wave takes to collapse at the end.
@export var fade_seconds: float = 1.2
## How far in from each end the wave tapers down to nothing.
@export var taper: float = 0.7

## Which way each cube's wave faces, kept by cube so the wall a reaction
## turns it into (Electrified Wall of Water) faces the same way:
## key -> [the visual's instance id, the front as a world xz direction].
static var _fronts: Dictionary = {}

@onready var _sheet: MeshInstance3D = $Sheet
@onready var _spray: GPUParticles3D = $Spray
@onready var _drips: GPUParticles3D = $Drips
@onready var _foam: GPUParticles3D = $Foam

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
## PROFILE smoothed, and each point's share of the way along it.
var _profile := PackedVector2Array()
var _profile_share := PackedFloat32Array()
var _lip: int = 0
var _crest: int = 0
var _born: float = 0.0
var _risen: bool = false
var _strength: float = 1.0
var _material: ShaderMaterial
var _mesh := ArrayMesh.new()


func _ready() -> void:
	for emitter: GPUParticles3D in _emitters():
		var process := emitter.process_material.duplicate() as ParticleProcessMaterial
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
		emitter.process_material = process
		emitter.emitting = false
	_smooth_profile()
	_material = ShaderMaterial.new()
	_material.shader = SHEET_SHADER
	_material.set_shader_parameter("streaks", streaks)
	_material.set_shader_parameter("crackle", crackle)
	_sheet.mesh = _mesh
	_sheet.material_override = _material
	# On the units' layer, which the water's decal on the ground leaves
	# out, or it would paint itself up the wave's feet.
	_sheet.layers = 1 << (Unit.RENDER_LAYER - 1)


func _exit_tree() -> void:
	for key in _keys:
		if _fronts.has(key) and _fronts[key][0] == get_instance_id():
			_fronts.erase(key)


func _emitters() -> Array[GPUParticles3D]:
	return [_spray, _drips, _foam]


## Raises the wave over cells (CloudCells). Called once, right after the
## wall is placed: an emitter's amount can't change later without it
## restarting.
func show_cubes(cells: Array) -> void:
	_born = Time.get_ticks_msec() / 1000.0
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
	_rebuild()
	var length: float = _station_t[_station_t.size() - 1] - _station_t[0]
	var counts: Array[float] = [spray_per_metre * length, drips_per_metre * length, foam_per_metre * length]
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
	# Long enough for the last drips to land.
	tween.tween_interval(maxf(_drips.lifetime - fade_seconds, 0.0))
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
	var n: int = PROFILE.size()
	for i in n - 1:
		var p0: Vector2 = PROFILE[maxi(i - 1, 0)]
		var p1: Vector2 = PROFILE[i]
		var p2: Vector2 = PROFILE[i + 1]
		var p3: Vector2 = PROFILE[mini(i + 2, n - 1)]
		for k in PROFILE_STEPS:
			_profile.append(p1.cubic_interpolate(p2, p0, p3, float(k) / PROFILE_STEPS))
	_profile.append(PROFILE[n - 1])
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
func _station_height(i: int, now: float) -> float:
	var t: float = _station_t[i]
	var reach: float = maxf(absf(_station_t[0]), absf(_station_t[_station_t.size() - 1]))
	var rise: float = clampf((now - _born - rise_spread * absf(t) / maxf(reach, 0.001)) / maxf(rise_seconds, 0.001), 0.0, 1.0)
	rise = rise * rise * (3.0 - 2.0 * rise)
	var end: float = minf(t - _station_t[0], _station_t[_station_t.size() - 1] - t)
	var tapered: float = smoothstep(0.0, taper, end)
	return _station_burn[i] * rise * tapered * _strength


## Where profile point j of station i sits in the world at height h (0..1).
func _point(i: int, j: int, h: float) -> Vector3:
	var height: float = (_station_top[i] - _station_foot[i]) * h
	var depth: float = lerpf(0.35, 1.0, h) * clampf(_station_top[i] - _station_foot[i], 1.0, NOMINAL_HEIGHT) / NOMINAL_HEIGHT
	var across: float = _station_s[i] + _profile[j].x * depth * _lean
	var flat: Vector2 = _centre + _axis * _station_t[i] + _normal * across
	return Vector3(flat.x, _station_foot[i] + _profile[j].y * height, flat.y)


func _rebuild() -> void:
	if _station_t.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var stations: int = _station_t.size()
	var points: int = _profile.size()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	vertices.resize(stations * points)
	normals.resize(stations * points)
	uvs.resize(stations * points)
	uv2s.resize(stations * points)
	var to_local_basis: Basis = global_transform.basis.inverse()
	var origin: Vector3 = global_position
	for i in stations:
		var h: float = _station_height(i, now)
		var run: float = 0.0
		var across := Vector3(_normal.x, 0.0, _normal.y) * _lean
		for j in points:
			var world: Vector3 = _point(i, j, h)
			var before: Vector3 = _point(i, maxi(j - 1, 0), h)
			var after: Vector3 = _point(i, mini(j + 1, points - 1), h)
			if j > 0:
				run += world.distance_to(before)
			# Across the sheet, in the plane the cross-section lies in.
			var tangent: Vector3 = after - before
			var flat: float = tangent.dot(across)
			var normal: Vector3 = (across * tangent.y - Vector3.UP * flat).normalized()
			if normal == Vector3.ZERO:
				normal = across
			var index: int = i * points + j
			vertices[index] = to_local_basis * (world - origin)
			normals[index] = to_local_basis * normal
			uvs[index] = Vector2(_station_t[i], run)
			uv2s[index] = Vector2(_profile_share[j], h)
	var indices := PackedInt32Array()
	for i in stations - 1:
		for j in points - 1:
			var a: int = i * points + j
			var b: int = a + points
			indices.append_array([a, b, a + 1, a + 1, b, b + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


## Where on the standing wave (full height) spray, drips and foam start,
## in this node's space.
func _emit_from_points() -> void:
	var spray := PackedVector3Array()
	var drips := PackedVector3Array()
	var foam := PackedVector3Array()
	for i in _station_t.size():
		if _station_burn[i] < 1.0 or not _standing(i):
			continue
		spray.append(to_local(_point(i, _crest, 1.0)))
		spray.append(to_local(_point(i, _lip, 1.0)))
		drips.append(to_local(_point(i, _lip, 1.0)))
		drips.append(to_local(_point(i, mini(_lip + 2, _profile.size() - 1), 1.0)))
		foam.append(to_local(_point(i, _profile.size() - 1, 1.0)))
		foam.append(to_local(_point(i, 0, 1.0)))
	var sets: Array[PackedVector3Array] = [spray, drips, foam]
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
			process.direction = (front + Vector3.UP * 0.5).normalized()
		elif emitters[e] == _foam:
			process.direction = (front + Vector3.UP).normalized()
		emitters[e].emitting = _strength > 0.0


## Whether any of station i's columns still has cubes.
func _standing(i: int) -> bool:
	for column: Vector2i in _station_columns[i]:
		if not _columns[column].is_empty():
			return true
	return false


func _process(delta: float) -> void:
	if _station_t.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var changed: bool = not _risen or _strength < 1.0
	if not _risen and now > _born + rise_spread + rise_seconds:
		_risen = true
		_emit_from_points()
	for i in _station_t.size():
		if _station_burn[i] > 0.0 and not _standing(i):
			_station_burn[i] = maxf(_station_burn[i] - delta / recede_seconds, 0.0)
			changed = true
	if changed:
		_rebuild()
	_material.set_shader_parameter("strength", clampf(_strength * 1.5, 0.0, 1.0))

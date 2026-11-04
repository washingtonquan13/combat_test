extends Node3D
## The Wall of Fire visual, drawn to the CloudGrid cubes of one cast
## (show_cubes()): Flames stand through every cube, so the wall is solid
## fire from the ground to its top and takes the shape the grid gave it —
## cut off where a wall stopped it, stepping up a stair. A few big Core flames
## rise from the foot of each column and carry the wall's bulk, the small
## Flames licking over them. Sparks fly up
## out of it and dark Smoke rolls off it; the Light flickers orange along
## it. Cubes run out recede (recede_cubes()): no new flames are born
## there and the ones burning die on their own short lives. When the last
## go, dissipate(): everything stops, the light fades, and it frees
## itself. The burning ground left behind is Fire's own visual.

## How thickly each layer burns, per cube.
@export var flames_per_cube: float = 4.0
## Big Core flames per column of cubes: the wall's bulk.
@export var core_per_column: float = 0.8
@export var sparks_per_cube: float = 1.5
@export var smoke_per_cube: float = 0.6
## Birth points scattered per cube.
@export var points_per_cube: int = 4
## The flame tongue each Flames particle draws: a half-tube this wide
## and tall, narrowing to its tip by tongue_taper and leaning forward
## by tongue_lean there.
@export var tongue_width: float = 1.3
@export var tongue_height: float = 2.2
@export_range(0.0, 1.0) var tongue_taper: float = 0.4
@export var tongue_lean: float = 0.3
## The Core flames' tongue, as big as the wall is tall.
@export var core_width: float = 2.4
@export var core_height: float = 3.8
## How far the light's energy swings either side of its authored value.
@export var flicker: float = 0.3
## How long the light takes to fade out at the end.
@export var fade_seconds: float = 1.5

@onready var _flames: GPUParticles3D = $Flames
@onready var _core: GPUParticles3D = $Core
@onready var _sparks: GPUParticles3D = $Sparks
@onready var _smoke: GPUParticles3D = $Smoke
@onready var _light: OmniLight3D = $Light

## Cube keys still burning -> their birth points, in this node's space.
var _points: Dictionary[Vector3i, PackedVector3Array] = {}
## The bottom cube of each column -> its Core birth point.
var _core_points: Dictionary[Vector3i, Vector3] = {}
var _light_energy: float
var _burning: float = 1.0


func _ready() -> void:
	_light_energy = _light.light_energy
	_flames.draw_pass_1 = _tongue_mesh((_flames.draw_pass_1 as PrimitiveMesh).material, tongue_width, tongue_height)
	_core.draw_pass_1 = _tongue_mesh((_core.draw_pass_1 as PrimitiveMesh).material, core_width, core_height)
	for emitter: GPUParticles3D in [_flames, _core, _sparks, _smoke]:
		var process := emitter.process_material.duplicate() as ParticleProcessMaterial
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
		emitter.process_material = process


## Burns through cells (CloudCells). Called once, right after the wall
## is placed: an emitter's amount can't change later without it
## restarting and every flame popping.
func show_cubes(cells: Array) -> void:
	var low := Vector3(INF, INF, INF)
	var high := -low
	var bottoms: Dictionary[Vector2i, Vector3i] = {}
	for cell in cells:
		var column := Vector2i(cell.key.x, cell.key.z)
		if not bottoms.has(column) or cell.key.y < bottoms[column].y:
			bottoms[column] = cell.key
		var centre: Vector3 = cell.centre()
		low = low.min(centre)
		high = high.max(centre)
		var points := PackedVector3Array()
		for i in points_per_cube:
			# Low in the cube: a tongue licks up a meter or so from where it's born.
			var jitter := Vector3(randf() - 0.5, randf() * 0.6 - 0.5, randf() - 0.5) * CloudGrid.CELL
			points.append(to_local(centre + jitter))
		_points[cell.key] = points
	for key: Vector3i in bottoms.values():
		_core_points[key] = to_local(CloudGrid.centre_of(key) - Vector3(0.0, CloudGrid.CELL * 0.5, 0.0))
	var counts: Array[float] = [flames_per_cube * cells.size(), core_per_column * bottoms.size(),
			sparks_per_cube * cells.size(), smoke_per_cube * cells.size()]
	var emitters: Array[GPUParticles3D] = [_flames, _core, _sparks, _smoke]
	var box := AABB(to_local(low), high - low).grow(4.0)
	for e in emitters.size():
		emitters[e].amount = maxi(2, roundi(counts[e]))
		emitters[e].visibility_aabb = box
	_emit_from_points()
	_light.position = to_local((low + high) * 0.5)
	_light.omni_range = maxf(high.x - low.x, high.z - low.z) * 0.6 + 3.0


## Stops new flames in cells; the ones burning there die out on their own.
func recede_cubes(cells: Array) -> void:
	for cell in cells:
		_points.erase(cell.key)
		_core_points.erase(cell.key)
	_emit_from_points()


func _emit_from_points() -> void:
	var all := PackedVector3Array()
	for points in _points.values():
		all.append_array(points)
	_set_points([_flames, _sparks, _smoke], all)
	_set_points([_core], PackedVector3Array(_core_points.values()))


func _set_points(emitters: Array[GPUParticles3D], points: PackedVector3Array) -> void:
	if points.is_empty():
		for emitter in emitters:
			emitter.emitting = false
		return
	var image := Image.create_from_data(points.size(), 1, false, Image.FORMAT_RGBF, points.to_byte_array())
	var texture := ImageTexture.create_from_image(image)
	for emitter in emitters:
		var process := emitter.process_material as ParticleProcessMaterial
		process.emission_point_texture = texture
		process.emission_point_count = points.size()


## A curved half-tube, its foot a little below the particle and its
## flame texture wrapped round the curve, so a tongue has depth from any
## angle. Its random spin (the process material's angle) turns each one
## a different way.
func _tongue_mesh(material: Material, width: float, height: float) -> ArrayMesh:
	const ROWS := 10
	const SIDES := 8
	var foot := -height * 0.07
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for row in ROWS + 1:
		var h := float(row) / ROWS
		var radius := width * 0.5 * (1.0 - tongue_taper * h)
		for side in SIDES + 1:
			var u := float(side) / SIDES
			var angle := (u - 0.5) * PI
			vertices.append(Vector3(sin(angle) * radius, foot + h * height, cos(angle) * radius * 0.6 + tongue_lean * h * h))
			uvs.append(Vector2(u, 1.0 - h))
	for row in ROWS:
		for side in SIDES:
			var a := row * (SIDES + 1) + side
			var b := a + SIDES + 1
			indices.append_array([a, b, a + 1, a + 1, b, b + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


func _process(_delta: float) -> void:
	var t: float = Time.get_ticks_msec() / 1000.0
	var swing: float = sin(t * 11.0) * 0.5 + sin(t * 17.3 + 1.3) * 0.3 + sin(t * 29.1 + 2.1) * 0.2
	_light.light_energy = _light_energy * (1.0 + swing * flicker) * _burning


func dissipate() -> void:
	for emitter: GPUParticles3D in [_flames, _core, _sparks, _smoke]:
		emitter.emitting = false
	var tween := create_tween()
	tween.tween_property(self, "_burning", 0.0, fade_seconds)
	# Long enough for the last smoke to finish rising.
	tween.tween_interval(maxf(_smoke.lifetime - fade_seconds, 0.0))
	tween.tween_callback(queue_free)

extends Node3D
## The Wall of Fire visual, drawn to the CloudGrid cubes of one cast
## (show_cubes()): the Volume is one live mass of fire (fire_volume.gdshader)
## burning over the cubes' columns, so the wall is solid fire from the
## ground to its top and takes the shape the grid gave it — cut off where a
## wall stopped it, stepping up a stair. Sparks fly up out of it and dark
## Smoke rolls off it; the Light flickers orange along it. Columns run out
## recede (recede_cubes()): their fire dies down over recede_seconds. When
## the last go, dissipate(): everything stops, the fire and light fade,
## and it frees itself. The burning ground left behind is Fire's own visual.

const VOLUME_SHADER: Shader = preload("res://systems/surface_system/fire_volume.gdshader")

## The tiling noise the fire rises through.
@export var noise: Texture3D
@export var sparks_per_cube: float = 1.5
@export var smoke_per_cube: float = 0.6
## Birth points scattered per cube.
@export var points_per_cube: int = 4
## How far past the cubes, sideways and up, the fire's box reaches.
@export var box_margin: float = 1.0
## How long a receding column's fire takes to die down.
@export var recede_seconds: float = 1.0
## How far the light's energy swings either side of its authored value.
@export var flicker: float = 0.3
## How long the fire and light take to fade out at the end.
@export var fade_seconds: float = 1.5

@onready var _sparks: GPUParticles3D = $Sparks
@onready var _smoke: GPUParticles3D = $Smoke
@onready var _light: OmniLight3D = $Light
@onready var _volume: MeshInstance3D = $Volume

## Cube keys still burning -> their birth points, in this node's space.
var _points: Dictionary[Vector3i, PackedVector3Array] = {}
## Each column's cubes still burning.
var _columns: Dictionary[Vector2i, Array] = {}
## Each column's burn: 1 while it holds, falling to 0 as it recedes.
var _burn: Dictionary[Vector2i, float] = {}
## Each column's foot and top, in the world: a dying column keeps the
## height it had.
var _spans: Dictionary[Vector2i, Vector2] = {}
var _first_column := Vector2i.ZERO
var _column_image: Image
var _column_texture: ImageTexture
var _material: ShaderMaterial
var _light_energy: float
var _burning: float = 1.0


func _ready() -> void:
	_light_energy = _light.light_energy
	for emitter: GPUParticles3D in [_sparks, _smoke]:
		var process := emitter.process_material.duplicate() as ParticleProcessMaterial
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
		emitter.process_material = process


## Burns through cells (CloudCells). Called once, right after the wall
## is placed: an emitter's amount can't change later without it
## restarting and every flame popping.
func show_cubes(cells: Array) -> void:
	var low := Vector3(INF, INF, INF)
	var high := -low
	for cell in cells:
		var column := Vector2i(cell.key.x, cell.key.z)
		if not _columns.has(column):
			_columns[column] = []
			_burn[column] = 1.0
		_columns[column].append(cell.key)
		var centre: Vector3 = cell.centre()
		low = low.min(centre)
		high = high.max(centre)
		var points := PackedVector3Array()
		for i in points_per_cube:
			var jitter := Vector3(randf() - 0.5, randf() * 0.6 - 0.5, randf() - 0.5) * CloudGrid.CELL
			points.append(to_local(centre + jitter))
		_points[cell.key] = points
	var counts: Array[float] = [sparks_per_cube * cells.size(), smoke_per_cube * cells.size()]
	var emitters: Array[GPUParticles3D] = [_sparks, _smoke]
	var box := AABB(to_local(low), high - low).grow(4.0)
	for e in emitters.size():
		emitters[e].amount = maxi(2, roundi(counts[e]))
		emitters[e].visibility_aabb = box
	_emit_from_points()
	_light.position = to_local((low + high) * 0.5)
	_light.omni_range = maxf(high.x - low.x, high.z - low.z) * 0.6 + 3.0
	_build_volume(low, high)


## Stops the fire in cells; their columns die down once all their cubes go.
func recede_cubes(cells: Array) -> void:
	for cell in cells:
		_points.erase(cell.key)
		var column := Vector2i(cell.key.x, cell.key.z)
		if _columns.has(column):
			_columns[column].erase(cell.key)
	_emit_from_points()
	_write_columns()


## The Volume's box round the cubes (low and high their outermost centres)
## and the texture of their columns it burns over.
func _build_volume(low: Vector3, high: Vector3) -> void:
	var half := CloudGrid.CELL * 0.5
	var box_low := to_local(low) - Vector3(half + box_margin, half, half + box_margin)
	var box_high := to_local(high) + Vector3(half + box_margin, half + box_margin, half + box_margin)
	var size := box_high - box_low
	var centre := (box_low + box_high) * 0.5
	var first := CloudGrid.key_of(low)
	var last := CloudGrid.key_of(high)
	# A spare column all round, empty, so the fuel fades off the edges.
	_first_column = Vector2i(first.x - 1, first.z - 1)
	var count := Vector2i(last.x - first.x + 3, last.z - first.z + 3)
	_column_image = Image.create(count.x, count.y, false, Image.FORMAT_RGBAF)
	_column_texture = ImageTexture.create_from_image(_column_image)
	_write_columns()
	var mesh := BoxMesh.new()
	mesh.size = size
	_material = ShaderMaterial.new()
	_material.shader = VOLUME_SHADER
	# Over the burning ground's smoke under it, which would darken its heart.
	_material.render_priority = 1
	_material.set_shader_parameter("noise", noise)
	_material.set_shader_parameter("columns_soft", _column_texture)
	_material.set_shader_parameter("columns", _column_texture)
	var origin := to_local(Vector3(_first_column.x, 0.0, _first_column.y) * CloudGrid.CELL)
	_material.set_shader_parameter("columns_origin", Vector2(origin.x, origin.z))
	_material.set_shader_parameter("columns_count", Vector2(count) * CloudGrid.CELL)
	_material.set_shader_parameter("box_size", size)
	_material.set_shader_parameter("box_offset", centre)
	_material.set_shader_parameter("world_offset", to_global(centre))
	mesh.material = _material
	_volume.mesh = mesh
	# On the units' layer, which the burning ground's decal leaves out, or
	# its char would show through the fire's heart.
	_volume.layers = 1 << (Unit.RENDER_LAYER - 1)
	_volume.position = centre


## Each column's burn, foot and top into the columns texture.
func _write_columns() -> void:
	if _column_image == null:
		return
	_column_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for column: Vector2i in _columns:
		var keys: Array = _columns[column]
		if keys.is_empty() and _burn[column] <= 0.0:
			continue
		if not keys.is_empty():
			var span := Vector2(INF, -INF)
			for key: Vector3i in keys:
				span = Vector2(minf(span.x, key.y * CloudGrid.CELL), maxf(span.y, (key.y + 1) * CloudGrid.CELL))
			_spans[column] = span
		var foot: float = to_local(Vector3(0.0, _spans[column].x, 0.0)).y
		var top: float = to_local(Vector3(0.0, _spans[column].y, 0.0)).y
		_column_image.set_pixelv(column - _first_column, Color(_burn[column], foot, top, 1.0))
	_column_texture.update(_column_image)


func _emit_from_points() -> void:
	var all := PackedVector3Array()
	for points in _points.values():
		all.append_array(points)
	if all.is_empty():
		for emitter: GPUParticles3D in [_sparks, _smoke]:
			emitter.emitting = false
		return
	var image := Image.create_from_data(all.size(), 1, false, Image.FORMAT_RGBF, all.to_byte_array())
	var texture := ImageTexture.create_from_image(image)
	for emitter: GPUParticles3D in [_sparks, _smoke]:
		var process := emitter.process_material as ParticleProcessMaterial
		process.emission_point_texture = texture
		process.emission_point_count = all.size()


func _process(delta: float) -> void:
	var t: float = Time.get_ticks_msec() / 1000.0
	var swing: float = sin(t * 11.0) * 0.5 + sin(t * 17.3 + 1.3) * 0.3 + sin(t * 29.1 + 2.1) * 0.2
	_light.light_energy = _light_energy * (1.0 + swing * flicker) * _burning
	if _material:
		_material.set_shader_parameter("strength", _burning)
	var changed := false
	for column: Vector2i in _columns:
		if _columns[column].is_empty() and _burn[column] > 0.0:
			_burn[column] = maxf(_burn[column] - delta / recede_seconds, 0.0)
			changed = true
	if changed:
		_write_columns()


func dissipate() -> void:
	for emitter: GPUParticles3D in [_sparks, _smoke]:
		emitter.emitting = false
	var tween := create_tween()
	tween.tween_property(self, "_burning", 0.0, fade_seconds)
	# Long enough for the last smoke to finish rising.
	tween.tween_interval(maxf(_smoke.lifetime - fade_seconds, 0.0))
	tween.tween_callback(queue_free)

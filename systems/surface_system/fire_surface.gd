extends DecalSurface
## The Fire visual: the Volume is one short live mass of dying flame
## (fire_volume.gdshader) burning over the patch's cells, a box round them
## with a texel per cell. Each cell's fire spreads in and recedes on the
## same clock DecalSurface keeps for its film, so fire cast into fire pools
## into one, and a surface laid over it puts its cells out. Sparks fly up,
## Smoke rises, Haze shimmers the air and the Light flickers orange over
## it. Going out stops the emitters and fades the fire, light and haze.
## The scorch film is still drawn - the cell lifecycle runs on it - but
## fire.tscn sets the decal's cull_mask to 0, so no char shows.

## The flame's look; its shader is fire_volume.gdshader. Each fire takes a copy.
@export var volume_material: ShaderMaterial
## How high the flame stands over each cell.
@export var flame_height: float = 0.9
@export var sparks_per_square_meter: float = 6.0
@export var smoke_per_square_meter: float = 1.0
## Emission points scattered over each cell.
@export var points_per_cell: int = 4
## How far the light's energy swings either side of its authored value.
@export var flicker: float = 0.3

@onready var _volume: MeshInstance3D = $Volume
@onready var _sparks: GPUParticles3D = $Sparks
@onready var _smoke: GPUParticles3D = $Smoke
@onready var _haze: MeshInstance3D = $Haze
@onready var _light: OmniLight3D = $Light

var _light_energy: float
var _burning: float = 1.0
var _material: ShaderMaterial
## The columns texture's first cell, and its image.
var _first_cell := Vector2i.ZERO
var _column_image: Image
var _column_texture: ImageTexture
## Each cell's foot and top, in the Volume's space.
var _spans: Dictionary[Vector2i, Vector2] = {}


func _ready() -> void:
	super()
	_light_energy = _light.light_energy
	for emitter: GPUParticles3D in [_sparks, _smoke]:
		var process := emitter.process_material.duplicate() as ParticleProcessMaterial
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
		emitter.process_material = process
	_haze.mesh = _haze.mesh.duplicate()
	_material = volume_material.duplicate() as ShaderMaterial


## Spreads what burns over the cells, in meters.
func _cells_shown(cells: Array[SurfaceCell]) -> void:
	var points := PackedVector3Array()
	var low := Vector2(INF, INF)
	var high := -low
	var floor_y: float = INF
	for cell in cells:
		var centre: Vector3 = cell.centre()
		low = low.min(Vector2(centre.x, centre.z))
		high = high.max(Vector2(centre.x, centre.z))
		floor_y = minf(floor_y, cell.y)
		for i in points_per_cell:
			var jitter := Vector3(randf() - 0.5, 0.0, randf() - 0.5) * SurfaceGrid.CELL
			points.append(centre + jitter - global_position)
	var area: float = cells.size() * SurfaceGrid.CELL * SurfaceGrid.CELL
	var counts: Array[int] = [maxi(6, roundi(area * sparks_per_square_meter)), maxi(4, roundi(area * smoke_per_square_meter))]
	# Shared: the points are in each emitter's own space, so Smoke, raised
	# above the others, keeps its height over them.
	var spread: ImageTexture = _point_texture(points)
	var emitters: Array[GPUParticles3D] = [_sparks, _smoke]
	for e in emitters.size():
		var emitter: GPUParticles3D = emitters[e]
		var process := emitter.process_material as ParticleProcessMaterial
		process.emission_point_texture = spread
		process.emission_point_count = points.size()
		if emitter.amount != counts[e]:
			emitter.amount = counts[e]
	# Haze and light stand over the middle of the patch, on its floor.
	var middle := (low + high) * 0.5
	var extent := (high - low) + Vector2.ONE * SurfaceGrid.CELL
	var base := Vector3(middle.x, floor_y, middle.y) - global_position
	_haze.position = base
	(_haze.mesh as QuadMesh).size.x = maxf(extent.x, extent.y) * 1.1
	_light.position = base + Vector3(0.0, 1.2, 0.0)
	_light.omni_range = maxf(extent.x, extent.y) * 0.75 + 2.0
	_build_volume(cells)


## The Volume's box round the cells, and the texture of them it burns over.
func _build_volume(cells: Array[SurfaceCell]) -> void:
	var low := Vector2i(1 << 30, 1 << 30)
	var high := -low
	var y_low: float = INF
	var y_high: float = -INF
	for cell in cells:
		low = low.min(cell.key)
		high = high.max(cell.key)
		y_low = minf(y_low, cell.y)
		y_high = maxf(y_high, cell.y)
	# A spare cell all round, empty, so the fuel fades off the edges.
	_first_cell = low - Vector2i.ONE
	var count: Vector2i = high - low + Vector2i(3, 3)
	var box_low := Vector3(_first_cell.x * SurfaceGrid.CELL, y_low - 0.05, _first_cell.y * SurfaceGrid.CELL)
	var size := Vector3(count.x * SurfaceGrid.CELL, y_high - y_low + flame_height + 0.3, count.y * SurfaceGrid.CELL)
	var centre: Vector3 = box_low + size * 0.5
	_spans.clear()
	for cell in cells:
		var foot: float = cell.y - centre.y
		_spans[cell.key] = Vector2(foot, foot + flame_height)
	_column_image = Image.create(count.x, count.y, false, Image.FORMAT_RGBAF)
	_column_texture = ImageTexture.create_from_image(_column_image)
	_write_columns(_now())
	var mesh := BoxMesh.new()
	mesh.size = size
	# Over the smoke, which would darken its heart.
	_material.render_priority = 1
	_material.set_shader_parameter("columns_soft", _column_texture)
	_material.set_shader_parameter("columns", _column_texture)
	_material.set_shader_parameter("columns_origin", Vector2(box_low.x - centre.x, box_low.z - centre.z))
	_material.set_shader_parameter("columns_count", Vector2(count) * SurfaceGrid.CELL)
	_material.set_shader_parameter("box_size", size)
	_material.set_shader_parameter("box_offset", Vector3.ZERO)
	_material.set_shader_parameter("world_offset", centre)
	mesh.material = _material
	_volume.mesh = mesh
	# On the units' layer, which ground decals leave out: they would paint
	# over the fire.
	_volume.layers = 1 << (Unit.RENDER_LAYER - 1)
	_volume.global_position = centre


## Each cell's burn, foot and top into the columns texture: its burn rises
## as it spreads in and falls as it recedes, as the film's mask does. A
## spare cell next to a burning one takes its height, so the soft edge of
## the fuel has somewhere to stand.
func _write_columns(now: float) -> void:
	_column_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var size: Vector2i = _column_image.get_size()
	var ramp: float = maxf(spread_seconds * 0.4, 0.001)
	for key: Vector2i in _spans:
		var span: Vector2 = _spans[key]
		for step: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var near: Vector2i = key + step - _first_cell
			if not _spans.has(key + step) and near.x >= 0 and near.y >= 0 and near.x < size.x and near.y < size.y:
				_column_image.set_pixelv(near, Color(0.0, span.x, span.y, 1.0))
	for key: Vector2i in _spans:
		var burn: float = 0.0
		if _live.has(key):
			var arrival: float = clampf((now - _arrive.get(key, -INF)) / ramp, 0.0, 1.0)
			arrival = arrival * arrival * (3.0 - 2.0 * arrival)
			var recede: float = clampf((now - _dying[key]) / recede_seconds, 0.0, 1.0) if _dying.has(key) else 0.0
			burn = arrival * (1.0 - recede)
		var span: Vector2 = _spans[key]
		_column_image.set_pixelv(key - _first_cell, Color(burn, span.x, span.y, 1.0))
	_column_texture.update(_column_image)


func _point_texture(points: PackedVector3Array) -> ImageTexture:
	var image := Image.create(points.size(), 1, false, Image.FORMAT_RGBF)
	for i in points.size():
		image.set_pixel(i, 0, Color(points[i].x, points[i].y, points[i].z))
	return ImageTexture.create_from_image(image)


func _process(delta: float) -> void:
	super(delta)
	if not is_inside_tree():
		return
	var t: float = Time.get_ticks_msec() / 1000.0
	var swing: float = sin(t * 11.0) * 0.5 + sin(t * 17.3 + 1.3) * 0.3 + sin(t * 29.1 + 2.1) * 0.2
	_light.light_energy = _light_energy * (1.0 + swing * flicker) * _burning
	_haze.set_instance_shader_parameter("burning", _burning)
	_material.set_shader_parameter("strength", _burning)
	if _column_image == null:
		return
	var now: float = _now()
	var animating: bool = not _dying.is_empty()
	for key in _arrive:
		if now - _arrive[key] < spread_seconds * 0.4:
			animating = true
			break
	if animating:
		_write_columns(now)


func dissipate() -> void:
	for emitter: GPUParticles3D in [_sparks, _smoke]:
		emitter.emitting = false
	create_tween().tween_property(self, "_burning", 0.0, recede_seconds * 0.6)
	super()

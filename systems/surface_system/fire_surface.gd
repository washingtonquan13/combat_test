extends DecalSurface
## The Fire visual: DecalSurface draws the ground burning - a looping
## glow under dark crust - and charring as it goes out. On top, Flames
## burn across the patch's cells, Sparks fly up, Smoke rises, Haze
## shimmers the air and the Light flickers orange over it. Going out
## stops the emitters and fades the light and haze, then the scorch
## recedes as any film does.

## How thickly the flames stand over the patch.
@export var flames_per_square_meter: float = 3.0
@export var sparks_per_square_meter: float = 6.0
@export var smoke_per_square_meter: float = 1.0
## Emission points scattered over each cell.
@export var points_per_cell: int = 4
## How far in from the outline the flames start, in meters: the scorch's
## edge crumbles away (scorch_film's crumble_m), and a flame past the
## solid char stands on bare ground. A patch too small for that burns on
## its deepest cells.
@export var flame_inset_m: float = 0.7
## How far the light's energy swings either side of its authored value.
@export var flicker: float = 0.3

@onready var _flames: GPUParticles3D = $Flames
@onready var _sparks: GPUParticles3D = $Sparks
@onready var _smoke: GPUParticles3D = $Smoke
@onready var _haze: MeshInstance3D = $Haze
@onready var _light: OmniLight3D = $Light

var _light_energy: float
var _burning: float = 1.0


func _ready() -> void:
	super()
	_light_energy = _light.light_energy
	for emitter: GPUParticles3D in [_flames, _sparks, _smoke]:
		var process := emitter.process_material.duplicate() as ParticleProcessMaterial
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
		emitter.process_material = process
	_haze.mesh = _haze.mesh.duplicate()


## Spreads what burns over the cells, in meters.
func _cells_shown(cells: Array[SurfaceCell]) -> void:
	var points := PackedVector3Array()
	var depths: Dictionary[Vector2i, float] = _depths()
	var deepest: float = 0.0
	for cell in cells:
		deepest = maxf(deepest, depths.get(cell.key, 0.0))
	var inset: float = minf(flame_inset_m, deepest)
	var flame_points := PackedVector3Array()
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
			if depths.get(cell.key, 0.0) >= inset:
				flame_points.append(centre + Vector3(randf() - 0.5, 0.0, randf() - 0.5) * SurfaceGrid.CELL - global_position)
	var area: float = cells.size() * SurfaceGrid.CELL * SurfaceGrid.CELL
	var counts: Array[int] = [maxi(8, roundi(area * flames_per_square_meter)),
			maxi(6, roundi(area * sparks_per_square_meter)), maxi(4, roundi(area * smoke_per_square_meter))]
	# Shared: the points are in each emitter's own space, so Smoke, raised
	# above the others, keeps its height over them.
	var spread: ImageTexture = _point_texture(points)
	var textures: Array[ImageTexture] = [_point_texture(flame_points), spread, spread]
	var sizes: Array[int] = [flame_points.size(), points.size(), points.size()]
	var emitters: Array[GPUParticles3D] = [_flames, _sparks, _smoke]
	for e in emitters.size():
		var emitter: GPUParticles3D = emitters[e]
		var process := emitter.process_material as ParticleProcessMaterial
		process.emission_point_texture = textures[e]
		process.emission_point_count = sizes[e]
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


func dissipate() -> void:
	for emitter: GPUParticles3D in [_flames, _sparks, _smoke]:
		emitter.emitting = false
	create_tween().tween_property(self, "_burning", 0.0, recede_seconds * 0.6)
	super()

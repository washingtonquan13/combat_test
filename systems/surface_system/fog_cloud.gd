extends Node3D
## The Fog Cloud visual, drawn to the CloudGrid cubes of one cast
## (show_cubes()): every layer's puffs are born at points scattered
## through the cubes, so the cloud takes the shape the grid gave it — up
## a stairwell, flat under a ceiling, cut off at a wall. Cubes taken or
## run out recede (recede_cubes()): their puffs thin away in place, the
## rest stay. When the last go, dissipate(): the cloud spreads a little,
## lifts, and thins away from its edges in, the way real fog burns off,
## then frees itself. Sight is already clear by then; this is only the
## look. The colors are per scene, and every GPUParticles3D child gets
## them, so Darkness is this cloud inked, plus a layer of tendrils
## (darkness_tendril.gdshader).

@export var lit_color: Color = Color(0.86, 0.88, 0.9)
@export var shade_color: Color = Color(0.52, 0.56, 0.62)
@export var opacity: float = 0.6
@export var seconds: float = 3.5
@export var spread: float = 1.35
@export var lift: float = 0.6
## Each layer's authored amount is its puffs per this many cubes.
@export var authored_cubes: float = 50.0
## Birth points scattered per cube.
@export var points_per_cube: int = 4
## How long a cube's puffs take to thin away when it recedes.
@export var recede_seconds: float = 2.0

var _layers: Array[GPUParticles3D] = []
var _materials: Array[ShaderMaterial] = []
## Cube keys still shown -> their birth points.
var _points: Dictionary[Vector3i, PackedVector3Array] = {}
## Receding cube key -> the time it started, in seconds.
var _receding: Dictionary[Vector3i, float] = {}
var _low := Vector3i.ZERO
var _dims := Vector3i.ONE
var _images: Array[Image] = []
var _mask: ImageTexture3D
## Where the cubes are, from where this cloud was when shown: the mask
## stays on them while the cloud drifts as it dissipates.
var _shown_at := Transform3D.IDENTITY


func _ready() -> void:
	_layers.assign(find_children("*", "GPUParticles3D", false))
	for layer in _layers:
		layer.set_instance_shader_parameter("lit_color", lit_color)
		layer.set_instance_shader_parameter("shade_color", shade_color)
		layer.set_instance_shader_parameter("opacity", opacity)
		# Each cloud its own: the scene's resources are shared by every cast.
		var process := layer.process_material.duplicate() as ParticleProcessMaterial
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
		layer.process_material = process
		var material := (layer.draw_pass_1 as PrimitiveMesh).material.duplicate() as ShaderMaterial
		layer.material_override = material
		_materials.append(material)
	set_process(false)


## Shows the cloud over cells (CloudCells). Called once, right after the
## cloud is placed: a layer's amount can't change later without the
## emitter restarting and every puff popping.
func show_cubes(cells: Array) -> void:
	var low := Vector3i.MAX
	var high := Vector3i.MIN
	var rng := RandomNumberGenerator.new()
	for cell in cells:
		low = low.min(cell.key)
		high = high.max(cell.key)
		var points := PackedVector3Array()
		for i in points_per_cube:
			var jitter := Vector3(rng.randf_range(-0.4, 0.4), rng.randf_range(-0.4, 0.4), rng.randf_range(-0.4, 0.4))
			points.append(to_local(CloudGrid.centre_of(cell.key) + jitter * CloudGrid.CELL))
		_points[cell.key] = points
	_low = low
	_dims = high - low + Vector3i.ONE
	_shown_at = global_transform

	var box := AABB(to_local(Vector3(low) * CloudGrid.CELL), Vector3(_dims) * CloudGrid.CELL).grow(3.0)
	for layer in _layers:
		layer.amount = maxi(4, roundi(layer.amount * cells.size() / authored_cubes))
		layer.visibility_aabb = box
	_emit_from_points()

	_images.clear()
	for z in _dims.z:
		_images.append(Image.create_empty(_dims.x, _dims.y, false, Image.FORMAT_R8))
	_mask = ImageTexture3D.new()
	_mask.create(Image.FORMAT_R8, _dims.x, _dims.y, _dims.z, false, _images)
	for material in _materials:
		material.set_shader_parameter("cube_mask", _mask)
	_place_mask()


## Thins the puffs of cells away; the cloud's other cubes stay.
func recede_cubes(cells: Array) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	for cell in cells:
		if _points.erase(cell.key):
			_receding[cell.key] = now
	_emit_from_points()
	set_process(true)


func _process(_delta: float) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	for key in _receding.keys():
		var t: float = clampf((now - _receding[key]) / recede_seconds, 0.0, 1.0)
		var at: Vector3i = key - _low
		_images[at.z].set_pixel(at.x, at.y, Color(t, 0.0, 0.0))
		if t >= 1.0:
			_receding.erase(key)
	_mask.update(_images)
	if _receding.is_empty():
		set_process(false)


## New puffs are born only in the cubes still shown; none left stops them.
func _emit_from_points() -> void:
	var all := PackedVector3Array()
	for points in _points.values():
		all.append_array(points)
	if all.is_empty():
		for layer in _layers:
			layer.emitting = false
		return
	var image := Image.create_from_data(all.size(), 1, false, Image.FORMAT_RGBF, all.to_byte_array())
	var texture := ImageTexture.create_from_image(image)
	for layer in _layers:
		var process := layer.process_material as ParticleProcessMaterial
		process.emission_point_texture = texture
		process.emission_point_count = all.size()


## World point -> the mask's 0..1 box, through where the cloud was when
## shown, so the cubes stay put however the cloud has moved since.
func _place_mask() -> void:
	var size := Vector3(_dims) * CloudGrid.CELL
	var to_box := Transform3D(Basis.from_scale(Vector3.ONE / size), -Vector3(_low) * CloudGrid.CELL / size)
	var space := Projection(to_box * _shown_at * global_transform.affine_inverse())
	for material in _materials:
		material.set_shader_parameter("mask_space", space)


## The puffs keep living (no emitting = false): their own lifetime fades
## would run on a clock of their own and pop puffs out mid-drift.
func dissipate() -> void:
	var tween := create_tween()
	tween.tween_method(_set_progress.bind(scale, position.y), 0.0, 1.0, seconds)
	tween.tween_callback(queue_free)


## Drift decelerates (fast at first, like a gust lifting it) while the
## shader thins at the same rate, so nothing sits still waiting.
func _set_progress(t: float, start_scale: Vector3, start_y: float) -> void:
	var drift: float = 1.0 - (1.0 - t) * (1.0 - t)
	scale = start_scale * lerpf(1.0, spread, drift)
	position.y = start_y + lift * start_scale.y * drift
	for layer in _layers:
		layer.set_instance_shader_parameter("dissipate", t)
	if _mask:
		_place_mask()

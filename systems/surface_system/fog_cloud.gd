extends Node3D
## The Fog Cloud visual, drawn to the CloudGrid cubes of one cast
## (show_cubes()): every layer's puffs are born at points scattered
## through the cubes, so the cloud takes the shape the grid gave it — up
## a stairwell, flat under a ceiling, cut off at a wall. It gathers out
## from where it was cast: each cube's puffs thicken in a little after the
## nearer ones', while the whole cloud billows out to its size. Cubes taken or
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
## Each layer's authored amount is its puffs per this many cubic metres.
@export var authored_volume: float = 50.0
## Birth points scattered per cubic metre; a cube gets its share, a
## fraction of one by chance.
@export var points_per_cubic_metre: float = 4.0
## How long a cube's puffs take to thin away when it recedes.
@export var recede_seconds: float = 2.0
## How long the cloud takes to gather, from its first cube to its last.
@export var appear_seconds: float = 1.4
## The cloud's size when it starts gathering, against its full size.
@export var appear_scale: float = 0.75

var _layers: Array[GPUParticles3D] = []
var _materials: Array[ShaderMaterial] = []
## Cube keys still shown -> their birth points.
var _points: Dictionary[Vector3i, PackedVector3Array] = {}
## Receding cube key -> the time it started, in seconds.
var _receding: Dictionary[Vector3i, float] = {}
## Gathering cube key -> the time it starts thickening in, in seconds.
var _arriving: Dictionary[Vector3i, float] = {}
var _appear: Tween
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
	var now: float = Time.get_ticks_msec() / 1000.0
	var reach: float = CloudGrid.CELL
	var volume: float = cells.size() * pow(CloudGrid.CELL, 3.0)
	var share: float = points_per_cubic_metre * pow(CloudGrid.CELL, 3.0)
	for cell in cells:
		reach = maxf(reach, global_position.distance_to(CloudGrid.centre_of(cell.key)))
	for cell in cells:
		# Half the time is the spread out from the cast point, half each
		# cube's own thickening.
		var d: float = global_position.distance_to(CloudGrid.centre_of(cell.key)) / reach
		_arriving[cell.key] = now + appear_seconds * 0.5 * d
		low = low.min(cell.key)
		high = high.max(cell.key)
		var points := PackedVector3Array()
		for i in floori(share + rng.randf()):
			var jitter := Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5)
			points.append(to_local(CloudGrid.centre_of(cell.key) + jitter * CloudGrid.CELL))
		_points[cell.key] = points
	_low = low
	_dims = high - low + Vector3i.ONE
	_shown_at = global_transform

	var box := AABB(to_local(Vector3(low) * CloudGrid.CELL), Vector3(_dims) * CloudGrid.CELL).grow(3.0)
	for layer in _layers:
		layer.amount = maxi(4, roundi(layer.amount * volume / authored_volume))
		layer.visibility_aabb = box
	_emit_from_points()

	_images.clear()
	for z in _dims.z:
		var image := Image.create_empty(_dims.x, _dims.y, false, Image.FORMAT_R8)
		image.fill(Color(1.0, 0.0, 0.0))
		_images.append(image)
	_mask = ImageTexture3D.new()
	_mask.create(Image.FORMAT_R8, _dims.x, _dims.y, _dims.z, false, _images)
	for material in _materials:
		material.set_shader_parameter("cube_mask", _mask)
	_place_mask()
	set_process(true)
	# Billows out to its size; the mask keeps to the cubes meanwhile.
	var full: Vector3 = scale
	scale = full * appear_scale
	_appear = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_appear.tween_property(self, "scale", full, appear_seconds)


## Thins the puffs of cells away; the cloud's other cubes stay.
func recede_cubes(cells: Array) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	for cell in cells:
		if _points.erase(cell.key):
			# A cube still gathering thins from as thick as it got.
			var at: Vector3i = cell.key - _low
			_receding[cell.key] = now - _images[at.z].get_pixel(at.x, at.y).r * recede_seconds
			_arriving.erase(cell.key)
	_emit_from_points()
	set_process(true)


func _process(_delta: float) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	for key in _arriving.keys():
		var t: float = clampf((now - _arriving[key]) / (appear_seconds * 0.5), 0.0, 1.0)
		var at: Vector3i = key - _low
		_images[at.z].set_pixel(at.x, at.y, Color(1.0 - t * t * (3.0 - 2.0 * t), 0.0, 0.0))
		if t >= 1.0:
			_arriving.erase(key)
	for key in _receding.keys():
		var t: float = clampf((now - _receding[key]) / recede_seconds, 0.0, 1.0)
		var at: Vector3i = key - _low
		_images[at.z].set_pixel(at.x, at.y, Color(t, 0.0, 0.0))
		if t >= 1.0:
			_receding.erase(key)
	_mask.update(_images)
	if _appear and _appear.is_running():
		_place_mask()
	elif _receding.is_empty() and _arriving.is_empty():
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
	if _appear and _appear.is_running():
		_appear.kill()
	var tween := create_tween()
	tween.tween_method(_set_progress.bind(scale, position.y), 0.0, 1.0, seconds)
	tween.tween_callback(queue_free)


## Drift decelerates (fast at first, like a gust lifting it) and the
## shader thins on the same curve, so the cloud fades as it spreads
## rather than spreading first and fading after.
func _set_progress(t: float, start_scale: Vector3, start_y: float) -> void:
	var drift: float = 1.0 - (1.0 - t) * (1.0 - t)
	scale = start_scale * lerpf(1.0, spread, drift)
	position.y = start_y + lift * start_scale.y * drift
	for layer in _layers:
		layer.set_instance_shader_parameter("dissipate", drift)
	if _mask:
		_place_mask()

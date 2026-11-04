extends Node3D
## The Wall of Fire visual, drawn to the CloudGrid cubes of one cast
## (show_cubes()): Flames stand through every cube, so the wall is solid
## fire from the ground to its top and takes the shape the grid gave it —
## cut off where a wall stopped it, stepping up a stair. Sparks fly up
## out of it and dark Smoke rolls off it; the Light flickers orange along
## it. Cubes run out recede (recede_cubes()): no new flames are born
## there and the ones burning die on their own short lives. When the last
## go, dissipate(): everything stops, the light fades, and it frees
## itself. The burning ground left behind is Fire's own visual.

## How thickly each layer burns, per cube.
@export var flames_per_cube: float = 6.0
@export var sparks_per_cube: float = 1.5
@export var smoke_per_cube: float = 0.6
## Birth points scattered per cube.
@export var points_per_cube: int = 4
## How far the light's energy swings either side of its authored value.
@export var flicker: float = 0.3
## How long the light takes to fade out at the end.
@export var fade_seconds: float = 1.5

@onready var _flames: GPUParticles3D = $Flames
@onready var _sparks: GPUParticles3D = $Sparks
@onready var _smoke: GPUParticles3D = $Smoke
@onready var _light: OmniLight3D = $Light

## Cube keys still burning -> their birth points, in this node's space.
var _points: Dictionary[Vector3i, PackedVector3Array] = {}
var _light_energy: float
var _burning: float = 1.0


func _ready() -> void:
	_light_energy = _light.light_energy
	for emitter: GPUParticles3D in [_flames, _sparks, _smoke]:
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
		var centre: Vector3 = cell.centre()
		low = low.min(centre)
		high = high.max(centre)
		var points := PackedVector3Array()
		for i in points_per_cube:
			# Low in the cube: a tongue licks up a meter or so from where it's born.
			var jitter := Vector3(randf() - 0.5, randf() * 0.6 - 0.5, randf() - 0.5) * CloudGrid.CELL
			points.append(to_local(centre + jitter))
		_points[cell.key] = points
	var counts: Array[float] = [flames_per_cube, sparks_per_cube, smoke_per_cube]
	var emitters: Array[GPUParticles3D] = [_flames, _sparks, _smoke]
	var box := AABB(to_local(low), high - low).grow(3.0)
	for e in emitters.size():
		emitters[e].amount = maxi(4, roundi(counts[e] * cells.size()))
		emitters[e].visibility_aabb = box
	_emit_from_points()
	_light.position = to_local((low + high) * 0.5)
	_light.omni_range = maxf(high.x - low.x, high.z - low.z) * 0.6 + 3.0


## Stops new flames in cells; the ones burning there die out on their own.
func recede_cubes(cells: Array) -> void:
	for cell in cells:
		_points.erase(cell.key)
	_emit_from_points()


func _emit_from_points() -> void:
	var all := PackedVector3Array()
	for points in _points.values():
		all.append_array(points)
	if all.is_empty():
		for emitter: GPUParticles3D in [_flames, _sparks, _smoke]:
			emitter.emitting = false
		return
	var image := Image.create_from_data(all.size(), 1, false, Image.FORMAT_RGBF, all.to_byte_array())
	var texture := ImageTexture.create_from_image(image)
	for emitter: GPUParticles3D in [_flames, _sparks, _smoke]:
		var process := emitter.process_material as ParticleProcessMaterial
		process.emission_point_texture = texture
		process.emission_point_count = all.size()


func _process(_delta: float) -> void:
	var t: float = Time.get_ticks_msec() / 1000.0
	var swing: float = sin(t * 11.0) * 0.5 + sin(t * 17.3 + 1.3) * 0.3 + sin(t * 29.1 + 2.1) * 0.2
	_light.light_energy = _light_energy * (1.0 + swing * flicker) * _burning


func dissipate() -> void:
	for emitter: GPUParticles3D in [_flames, _sparks, _smoke]:
		emitter.emitting = false
	var tween := create_tween()
	tween.tween_property(self, "_burning", 0.0, fade_seconds)
	# Long enough for the last smoke to finish rising.
	tween.tween_interval(maxf(_smoke.lifetime - fade_seconds, 0.0))
	tween.tween_callback(queue_free)

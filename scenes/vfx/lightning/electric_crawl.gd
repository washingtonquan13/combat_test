extends Node3D
## Charge running through something that is not itself a bolt: a puddle
## of electrified water, a cloud of electrified steam. Short painted arcs
## (lightning_arcs.gd, flipbook bolts) snap between points of the thing,
## each living a few hundredths of a second, then gone; a moment later
## another snaps somewhere else. They overlap and come in bursts, so the
## charge skitters rather than strobing in step. One light flickers with
## them.
##
## The owner says where the thing is by setting `points` (world points:
## a puddle's cell centres on its floor, a cloud's cube centres) whenever
## they change, and `strength` (0..1) as it gathers or fades. With
## `hug_floor` the arcs keep low over the points' heights, bowing up a
## little, so they run over the water rather than through the floor.
## Visual only.

const Arcs := preload("res://scenes/vfx/lightning/lightning_arcs.gd")
## Painted bolts (tools/lightning_flipbook.py), 2 x 8 frames.
const FLIPBOOK: Texture2D = preload("res://assets/vfx/lightning/lightning_flipbook.png")

## Arcs alive at once per point, on average (more points, more arcs).
@export var arcs_per_point: float = 0.08
@export var max_arcs: int = 14
## How far an arc reaches, metres.
@export var min_length: float = 0.5
@export var max_length: float = 1.6
## How long one arc shows, seconds.
@export var arc_seconds: Vector2 = Vector2(0.04, 0.12)
## A painted arc's half width per metre of its length.
@export var width_per_metre: float = 0.12
@export var roughness: float = 0.16
## Chance that an arc grows branches.
@export var fork_chance: float = 0.5
## Keep low over the points (a puddle) instead of anywhere between them.
@export var hug_floor: bool = false
## How high a floor arc rides, and how much it bows up in its middle.
@export var floor_lift: float = 0.04
@export var floor_bow: float = 0.12
## Chance per second of a surge: a burst of arcs at once, the light
## flaring with it.
@export var surges_per_second: float = 1.2
@export var surge_arcs: int = 5
@export var gain: float = 1.0
@export var light_energy: float = 1.2
@export var light_color: Color = Color(0.6, 0.72, 1.0)

## World points the arcs run between. Set by the owner.
var points: PackedVector3Array = PackedVector3Array():
	set(value):
		points = value
		_place_light()
## 0..1: how much charge shows, as the owner gathers or fades.
var strength: float = 1.0

## One arc that is showing, and until when.
class Live:
	var arcs: Array[Arcs.Arc]
	var until: float

var _arcs: Arcs
var _light: OmniLight3D
var _live: Array[Live] = []
var _age: float = 0.0
var _since_surge: float = 10.0


func _ready() -> void:
	_arcs = Arcs.new()
	_arcs.use_flipbook(FLIPBOOK, 2, 8)
	# Arcs riding a few centimetres over the water: the bolt shader's
	# usual soft fade near what's behind would wipe them out.
	_arcs.material.set_shader_parameter("soft_distance", 0.03 if hug_floor else 0.2)
	add_child(_arcs)
	_light = OmniLight3D.new()
	_light.light_color = light_color
	_light.light_energy = 0.0
	add_child(_light)
	_place_light()


func _process(delta: float) -> void:
	_age += delta
	_since_surge += delta
	var changed: bool = false
	for i in range(_live.size() - 1, -1, -1):
		if _live[i].until <= _age:
			_live.remove_at(i)
			changed = true
	if strength > 0.01 and points.size() >= 2:
		# Keeps about `wanted` arcs alive: each frame, enough new ones to
		# replace those dying at the arcs' average life.
		var wanted: float = minf(max_arcs, maxf(2.0, points.size() * arcs_per_point)) * strength
		var mean_life: float = (arc_seconds.x + arc_seconds.y) * 0.5
		var births: float = wanted * delta / mean_life
		var count: int = floori(births + randf())
		if randf() < surges_per_second * delta:
			count += surge_arcs
			_since_surge = 0.0
		for i in count:
			var live: Live = _new_arc()
			if live != null:
				_live.append(live)
				changed = true
	if changed:
		var all: Array[Arcs.Arc] = []
		for live in _live:
			all.append_array(live.arcs)
		_arcs.show_arcs(all)
	var flare: float = exp(-_since_surge / 0.08)
	var crackle: float = clampf(float(_live.size()) / 4.0, 0.0, 1.0)
	_arcs.set_brightness(gain * strength * (1.0 + flare), gain * 0.8 * strength * (1.0 + flare))
	_light.light_energy = light_energy * strength * (crackle * randf_range(0.5, 1.0) + 2.5 * flare)


## An arc from a random point to another in reach, with its branches,
## or null if no other point is in reach.
func _new_arc() -> Live:
	var start: Vector3 = points[randi() % points.size()]
	var end: Vector3 = start
	var reach: float = 0.0
	# A few tries for a partner the right distance off.
	for attempt in 6:
		var other: Vector3 = points[randi() % points.size()]
		var d: float = start.distance_to(other)
		if d >= min_length and d <= max_length:
			end = other
			reach = d
			break
		if d > reach and d <= max_length:
			end = other
			reach = d
	if reach < SurfaceGrid.CELL:
		return null
	var a: Vector3 = to_local(start)
	var b: Vector3 = to_local(end)
	var path: PackedVector3Array = Arcs.channel(a, b, 3, roughness)
	if hug_floor:
		# Flat over the water, bowing up a little between the ends, never
		# below either end's floor.
		var n: int = path.size()
		for i in n:
			var t: float = float(i) / float(n - 1)
			var floor_y: float = lerpf(a.y, b.y, t)
			path[i].y = floor_y + floor_lift + floor_bow * sin(t * PI) * randf_range(0.3, 1.0)
	var arc := Arcs.Arc.new(path, maxf(reach * width_per_metre, 0.05))
	arc.weight = randf_range(0.5, 1.0)
	arc.frame = randi()
	arc.root_fade = 0.1
	arc.tip_fade = randf() < 0.4
	var live := Live.new()
	live.arcs = [arc]
	if randf() < fork_chance:
		var bias := Vector3.ZERO if not hug_floor else Vector3(0.0, -0.6, 0.0)
		for branch in Arcs.fork(arc, 0.08, reach * 0.5, 3, roughness, arc.half_width * 0.6, bias):
			branch.frame = randi()
			if hug_floor:
				for i in branch.points.size():
					branch.points[i].y = maxf(branch.points[i].y, minf(a.y, b.y) + floor_lift)
			live.arcs.append(branch)
	live.until = _age + randf_range(arc_seconds.x, arc_seconds.y)
	return live


## The light over the middle of the points, reaching across them.
func _place_light() -> void:
	if _light == null or points.is_empty():
		return
	var low: Vector3 = points[0]
	var high: Vector3 = points[0]
	for p in points:
		low = low.min(p)
		high = high.max(p)
	_light.global_position = (low + high) * 0.5 + Vector3.UP * 0.6
	_light.omni_range = maxf(3.0, (high - low).length() * 0.6 + 2.0)

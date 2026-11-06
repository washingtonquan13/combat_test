extends Node3D
## One lightning strike from the sky to this node's position, drawn by
## lightning_bolt.gdshader. It plays on its own from the moment it
## enters the tree and frees itself when it is done.
##
## A strike runs like real lightning:
##  1. The stepped leader: a dim, branching channel works its way down
##     from the cloud in jerky steps (leader_seconds).
##  2. The return stroke: when the leader touches the ground, the main
##     channel blazes, and a light flashes at the impact point.
##  3. Restrokes: one to three more flashes down the SAME channel,
##     each a little dimmer, with the fine kinks jittered so it crackles.
##     The branches go dark after the first stroke.
## The arcs themselves are drawn by lightning_arcs.gd.

const Arcs := preload("res://scenes/vfx/lightning/lightning_arcs.gd")

## Metres from the ground up to where the channel starts.
@export var height: float = 30.0
## How far sideways, at most, the top sits from the impact point.
@export var lean: float = 5.0
## Halvings of the main channel. 7 gives 129 points.
@export_range(3, 9) var generations: int = 7
## Sideways push of each midpoint, as a fraction of its segment's length.
@export var roughness: float = 0.22
## Half widths of the ribbons (core plus halo), metres.
@export var main_half_width: float = 0.35
@export var branch_half_width: float = 0.2
## Chance a point on the main channel forks a branch.
@export var branch_chance: float = 0.08
@export var leader_seconds: float = 0.3
## Main channel brightness at the peak of the first stroke.
@export var stroke_gain: float = 6.0
## Light energy at the peak of the first stroke.
@export var light_energy: float = 14.0
@export var light_range: float = 22.0
@export var light_color: Color = Color(0.75, 0.82, 1.0)

var _bolt: Arcs
var _light: OmniLight3D
var _main: PackedVector3Array
var _branches: Array[Arcs.Arc] = []
var _leader_steps: PackedVector2Array  # (seconds, reveal)
var _strokes: PackedVector2Array  # (seconds, peak)
var _age: float = 0.0
var _life: float = 1.0
var _shown_stroke: int = -1


func _ready() -> void:
	_bolt = Arcs.new()
	add_child(_bolt)
	_light = OmniLight3D.new()
	_light.position = Vector3(0.0, 1.5, 0.0)
	_light.omni_range = light_range
	_light.light_color = light_color
	_light.shadow_enabled = true
	_light.light_energy = 0.0
	add_child(_light)
	_plan()
	_rebuild(true, 0.0)
	_process(0.0)


## Shape and timeline for this strike.
func _plan() -> void:
	var angle: float = randf() * TAU
	var top := Vector3(cos(angle), 0.0, sin(angle)) * randf_range(0.3, 1.0) * lean
	top.y = height
	_main = Arcs.channel(top, Vector3.ZERO, generations, roughness)
	_branches.clear()
	_fork(_main, 0, branch_chance, main_half_width)
	# The leader comes down in irregular steps.
	_leader_steps = PackedVector2Array()
	var count: int = randi_range(9, 15)
	var weights: PackedFloat32Array = []
	var total: float = 0.0
	for i in count:
		var w: float = randf_range(0.4, 1.6)
		weights.append(w)
		total += w
	var reached: float = 0.0
	for i in count:
		reached += weights[i] / total
		_leader_steps.append(Vector2(leader_seconds * float(i) / float(count), reached))
	# The first stroke, then one to three more down the same channel.
	_strokes = PackedVector2Array([Vector2(leader_seconds, 1.0)])
	var t: float = leader_seconds
	var peak: float = 1.0
	for i in randi_range(1, 3):
		t += randf_range(0.06, 0.16)
		peak *= randf_range(0.55, 0.85)
		_strokes.append(Vector2(t, peak))
	_life = t + 0.6


## Branches off `parent`, recursing one level into each branch.
func _fork(parent: PackedVector3Array, depth: int, chance: float, half_width: float) -> void:
	var n: int = parent.size()
	for i in range(int(n * 0.08), int(n * 0.85)):
		if randf() >= chance:
			continue
		var start: Vector3 = parent[i]
		var along: Vector3 = (parent[mini(i + 1, n - 1)] - parent[maxi(i - 1, 0)]).normalized()
		var out := Vector3(randfn(0.0, 1.0), 0.0, randfn(0.0, 1.0)).normalized()
		var dir: Vector3 = (along + out * randf_range(0.6, 1.4)).normalized()
		# Branches lean downward like the leader that made them.
		dir.y = minf(dir.y, -0.25)
		dir = dir.normalized()
		var reach: float = randf_range(0.12, 0.3) * height * (1.0 - float(i) / n) / (depth + 1.0)
		var end: Vector3 = start + dir * reach
		end.y = maxf(end.y, 0.3)
		var points: PackedVector3Array = Arcs.channel(start, end, maxi(generations - 2 - depth, 3), roughness * 1.2)
		var branch := _arc(points, half_width)
		branch.branch = true
		branch.tip_fade = true
		_branches.append(branch)
		if depth == 0:
			_fork(points, 1, chance * 1.5, half_width * 0.6)


## An arc revealed top down: its reveal coordinate is the drop from the cloud.
func _arc(points: PackedVector3Array, half_width: float) -> Arcs.Arc:
	var arc := Arcs.Arc.new(points, half_width)
	for p in points:
		arc.reveals.append(clampf(1.0 - p.y / height, 0.0, 1.0))
	return arc


## Rebuilds the mesh. Restrokes jitter every point a little, and drop
## the branches.
func _rebuild(with_branches: bool, jitter: float) -> void:
	var main := _arc(Arcs.jittered(_main, jitter) if jitter > 0.0 else _main, main_half_width)
	# The main channel fades out into the cloud at the top.
	main.root_fade = 0.08
	var arcs: Array[Arcs.Arc] = [main]
	if with_branches:
		arcs.append_array(_branches)
	_bolt.show_arcs(arcs)


func _process(delta: float) -> void:
	_age += delta
	if _age >= _life:
		queue_free()
		return
	# Which stroke is the latest one so far; a new one reshapes the bolt.
	var latest: int = -1
	for i in _strokes.size():
		if _age >= _strokes[i].x:
			latest = i
	if latest != _shown_stroke:
		_shown_stroke = latest
		if latest >= 1:
			_rebuild(false, 0.06)
	var flash: float = 0.0
	for i in latest + 1:
		var dt: float = _age - _strokes[i].x
		flash = maxf(flash, _strokes[i].y * (exp(-dt / 0.03) + 0.18 * exp(-dt / 0.15)))
	var reveal: float = 1.0
	var tip: float = 0.0
	var leader_glow: float = 0.0
	if latest < 0:
		reveal = 0.0
		for step in _leader_steps:
			if _age >= step.x:
				reveal = step.y
		tip = 2.0
		leader_glow = 0.35
	var first_dt: float = maxf(_age - leader_seconds, 0.0)
	var branch_glow: float = 0.35 if latest < 0 else 2.0 * exp(-first_dt / 0.05)
	_bolt.set_reveal(reveal, tip)
	_bolt.set_brightness(leader_glow + flash * stroke_gain, branch_glow)
	# The leader flickers the light faintly; the strokes flash it.
	var leader_light: float = randf_range(0.2, 0.6) * reveal if latest < 0 else 0.0
	_light.light_energy = leader_light + flash * light_energy

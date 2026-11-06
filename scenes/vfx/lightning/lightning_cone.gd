extends Node3D
## A cone of electricity sprayed from this node's position, for a cone
## attack like ConeTargeting's (pass its length and half_angle()). Many
## short forked arcs leap from the hand to random points inside the cone,
## and every `reroll_seconds` they are all thrown away and made again, so
## the spray crackles. Units caught in the cone always draw an arc or two.
## One flickering light lights the scene. Plays once and frees itself.
##
## Visual only: what is hit, and the damage, is the ability's business.

const Arcs := preload("res://scenes/vfx/lightning/lightning_arcs.gd")

## Arcs into empty space each reroll.
@export var spray_arcs: int = 7
## Arcs to each caught unit each reroll.
@export var arcs_per_target: int = 2
@export var reroll_seconds: float = 0.05
## How long the cone sprays, then how long it takes to die away.
@export var hold_seconds: float = 0.9
@export var fade_seconds: float = 0.25
## How fast the first arcs leap out to full length.
@export var grow_seconds: float = 0.08
@export var main_half_width: float = 0.14
@export var branch_half_width: float = 0.08
@export var roughness: float = 0.2
@export var branch_chance: float = 0.08
## Arc brightness at full strength.
@export var gain: float = 1.2
@export var light_energy: float = 3.0
@export var light_color: Color = Color(0.7, 0.8, 1.0)

var _arcs: Arcs
var _light: OmniLight3D
var _direction: Vector3 = Vector3.FORWARD
var _length: float = 9.0
var _half_angle: float = 0.45
var _targets: PackedVector3Array = PackedVector3Array()
var _age: float = 0.0
var _since_reroll: float = 0.0
var _playing: bool = false


func _ready() -> void:
	_arcs = Arcs.new()
	add_child(_arcs)
	_light = OmniLight3D.new()
	_light.light_color = light_color
	_light.shadow_enabled = true
	_light.light_energy = 0.0
	add_child(_light)
	set_process(_playing)


## Starts the spray. `direction` is the cone's axis in world space,
## `targets` the world points (e.g. chests) of the units it catches.
func play(direction: Vector3, length: float, half_angle: float, targets: PackedVector3Array = PackedVector3Array()) -> void:
	_direction = direction.normalized()
	_length = length
	_half_angle = half_angle
	_targets = targets
	_age = 0.0
	_playing = true
	if is_node_ready():
		set_process(true)
		_reroll()
		_process(0.0)


func _process(delta: float) -> void:
	if not _playing:
		return
	_age += delta
	_since_reroll += delta
	var life: float = hold_seconds + fade_seconds
	if _age >= life:
		queue_free()
		return
	if _since_reroll >= reroll_seconds or _arcs.mesh == null:
		_reroll()
	var strength: float = 1.0 - smoothstep(hold_seconds, life, _age)
	# Each new set of arcs flashes, then sags until the next.
	var crackle: float = 0.65 + 0.35 * exp(-_since_reroll / 0.025)
	_arcs.set_reveal(clampf(_age / grow_seconds, 0.0, 1.0), 1.5 if _age < grow_seconds else 0.0)
	_arcs.set_brightness(gain * strength * crackle, gain * 0.7 * strength * crackle)
	_light.light_energy = light_energy * strength * randf_range(0.55, 1.0)
	_light.omni_range = _length * 1.1


## Throws the arcs away and makes a new set.
func _reroll() -> void:
	_since_reroll = 0.0
	var to_local: Basis = global_basis.inverse()
	var axis: Vector3 = to_local * _direction
	var side: Vector3 = axis.cross(Vector3.UP)
	if side.length_squared() < 1e-4:
		side = axis.cross(Vector3.RIGHT)
	side = side.normalized()
	var up: Vector3 = side.cross(axis).normalized()
	var arcs: Array[Arcs.Arc] = []
	for i in spray_arcs:
		# Angle spread evenly over the cone's cross-section; reach mostly far.
		var off: float = _half_angle * sqrt(randf())
		var around: float = randf() * TAU
		var dir: Vector3 = (axis * cos(off) + (side * cos(around) + up * sin(around)) * sin(off)).normalized()
		_add_arc(arcs, dir * _length * randf_range(0.35, 1.0), randf_range(0.45, 1.0))
	for target in _targets:
		var local: Vector3 = to_local * (target - global_position)
		for i in arcs_per_target:
			_add_arc(arcs, local + Vector3(randfn(0.0, 0.15), randfn(0.0, 0.25), randfn(0.0, 0.15)), randf_range(0.8, 1.2))
	_arcs.show_arcs(arcs)
	# The light sits where the spray is thickest.
	_light.position = axis * _length * 0.3


func _add_arc(arcs: Array[Arcs.Arc], end: Vector3, weight: float) -> void:
	var halvings: int = 5 if end.length() > 3.0 else 4
	var arc := Arcs.Arc.new(Arcs.channel(Vector3.ZERO, end, halvings, roughness), main_half_width)
	arc.weight = weight
	arc.reveal_to = end.length() / _length
	# Every arc starts at the hand: fade them in so they do not pile up
	# into one white blob there.
	arc.root_fade = 0.25
	arcs.append(arc)
	var bias: Vector3 = end.normalized() * 0.5
	arcs.append_array(Arcs.fork(arc, branch_chance, end.length() * 0.4, halvings - 1, roughness, branch_half_width, bias))

extends Node3D
## A cone of electricity blasted from this node's position, for a cone
## attack like ConeTargeting's (pass its length and half_angle()).
##
## The blast has a source and a body:
##  - a churning plasma orb at the hand (ball_lightning.gd's core),
##    which flares as the blast fires;
##  - a few thick trunks leaving the hand, splitting into many thinner
##    arcs that spray out to random points in the cone. Each arc is a
##    painted flipbook bolt (lightning_flipbook.gdshader), forks and all;
##  - a faint glowing haze filling the cone (lightning_cone_haze.gdshader).
## Every `reroll_seconds` the arcs are thrown away and made again, so the
## spray crackles. Units caught in the cone always draw an arc or two.
## One flickering light lights the scene. Plays once and frees itself.
##
## Visual only: what is hit, and the damage, is the ability's business.

const Arcs := preload("res://scenes/vfx/lightning/lightning_arcs.gd")
const Ball := preload("res://scenes/vfx/lightning/ball_lightning.gd")
const HAZE_SHADER: Shader = preload("res://scenes/vfx/lightning/lightning_cone_haze.gdshader")
## Painted bolts (tools/lightning_flipbook.py), 2 x 8 frames.
const FLIPBOOK: Texture2D = preload("res://assets/vfx/lightning/lightning_flipbook.png")

## Thick arcs leaving the hand, which the spray splits off from.
@export var trunks: int = 3
## How far along the cone the trunks reach, as a fraction of its length.
@export var trunk_reach: float = 0.4
## Trunks are this much wider than spray arcs of the same length.
@export var trunk_width: float = 1.4
## Arcs into empty space each reroll.
@export var spray_arcs: int = 5
## Arcs to each caught unit each reroll.
@export var arcs_per_target: int = 2
@export var reroll_seconds: float = 0.05
## How long the cone sprays, then how long it takes to die away.
@export var hold_seconds: float = 0.9
@export var fade_seconds: float = 0.25
## How fast the first arcs leap out to full length.
@export var grow_seconds: float = 0.08
## A painted arc's half width per metre of its length. The painting's
## zigzag scales with it.
@export var width_per_metre: float = 0.11
## How much the arcs bend; the painting carries the fine zigzag.
@export var roughness: float = 0.08
## Arc brightness at full strength.
@export var gain: float = 0.9
@export var light_energy: float = 3.0
@export var light_color: Color = Color(0.7, 0.8, 1.0)
## The plasma orb at the hand.
@export var orb_radius: float = 0.38
## Brightness of the haze filling the cone.
@export var haze_strength: float = 0.5
## How hard the first instant kicks: orb, haze and light flare this much
## over the hold, dying away over `kick_seconds`.
@export var kick: float = 2.0
@export var kick_seconds: float = 0.12

var _arcs: Arcs
var _light: OmniLight3D
var _orb: MeshInstance3D
var _orb_material: ShaderMaterial
var _haze: MeshInstance3D
var _haze_material: ShaderMaterial
var _trunk_arcs: Array[Arcs.Arc] = []
var _direction: Vector3 = Vector3.FORWARD
var _length: float = 9.0
var _half_angle: float = 0.45
var _targets: PackedVector3Array = PackedVector3Array()
var _age: float = 0.0
var _since_reroll: float = 0.0
var _playing: bool = false


func _ready() -> void:
	_arcs = Arcs.new()
	_arcs.use_flipbook(FLIPBOOK, 2, 8)
	add_child(_arcs)
	_light = OmniLight3D.new()
	_light.light_color = light_color
	_light.shadow_enabled = true
	_light.light_energy = 0.0
	add_child(_light)
	_orb = Ball.make_core()
	_orb_material = _orb.material_override
	# Hotter in the middle than a free ball: it is the blast's source.
	_orb_material.set_shader_parameter("core_strength", 7.0)
	_orb_material.set_shader_parameter("haze_strength", 0.6)
	add_child(_orb)
	_haze_material = ShaderMaterial.new()
	_haze_material.shader = HAZE_SHADER
	var noise := NoiseTexture2D.new()
	noise.seamless = true
	var fast := FastNoiseLite.new()
	fast.frequency = 0.03
	noise.noise = fast
	_haze_material.set_shader_parameter("noise", noise)
	_haze = MeshInstance3D.new()
	_haze.material_override = _haze_material
	_haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_haze)
	_orb.visible = _playing
	_haze.visible = _playing
	if _playing:
		_start()
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
		_start()


func _start() -> void:
	set_process(true)
	_orb.visible = true
	_haze.visible = true
	_shape_haze()
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
	# The first instant kicks, then the blast settles into the hold.
	var punch: float = 1.0 + kick * exp(-_age / kick_seconds)
	# Each new set of arcs flashes, then sags until the next.
	var crackle: float = 0.65 + 0.35 * exp(-_since_reroll / 0.025)
	var reveal: float = clampf(_age / grow_seconds, 0.0, 1.0)
	_arcs.set_reveal(reveal, 1.5 if _age < grow_seconds else 0.0)
	_arcs.set_brightness(gain * strength * crackle, gain * 0.7 * strength * crackle)
	_light.light_energy = light_energy * strength * punch * randf_range(0.55, 1.0)
	_light.omni_range = _length * 1.1
	var wobble: float = 1.0 + 0.08 * sin(_age * 23.0) + 0.06 * randf_range(-1.0, 1.0)
	_orb.scale = Vector3.ONE * orb_radius * wobble * lerpf(0.4, 1.0, strength) * sqrt(punch)
	_orb_material.set_shader_parameter("time", _age)
	_orb_material.set_shader_parameter("strength", strength * punch * crackle)
	_haze_material.set_shader_parameter("time", _age)
	_haze_material.set_shader_parameter("reveal", reveal)
	_haze_material.set_shader_parameter("strength", haze_strength * strength * sqrt(punch) * randf_range(0.8, 1.0))


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
	# The trunks: thick, close to the axis, part way out.
	_trunk_arcs.clear()
	for i in trunks:
		var end: Vector3 = _cone_direction(axis, side, up, 0.4) * _length * trunk_reach * randf_range(0.7, 1.1)
		var trunk := Arcs.Arc.new(Arcs.channel(Vector3.ZERO, end, 2, roughness), end.length() * width_per_metre * trunk_width)
		trunk.weight = 0.8
		trunk.frame = randi()
		trunk.reveal_to = end.length() / _length
		# The orb hides where the trunks meet; a short fade keeps them
		# from piling up past it.
		trunk.root_fade = 0.12
		_trunk_arcs.append(trunk)
		arcs.append(trunk)
	for i in spray_arcs:
		# Reach mostly far.
		_add_arc(arcs, _cone_direction(axis, side, up, 1.0) * _length * randf_range(0.35, 1.0), randf_range(0.45, 1.0))
	for target in _targets:
		var local: Vector3 = to_local * (target - global_position)
		for i in arcs_per_target:
			_add_arc(arcs, local + Vector3(randfn(0.0, 0.15), randfn(0.0, 0.25), randfn(0.0, 0.15)), randf_range(0.8, 1.2))
	_arcs.show_arcs(arcs)
	# The light sits where the spray is thickest.
	_light.position = axis * _length * 0.2


## A random direction inside the cone, spread evenly over its cross
## section; `spread` narrows it toward the axis.
func _cone_direction(axis: Vector3, side: Vector3, up: Vector3, spread: float) -> Vector3:
	var off: float = _half_angle * spread * sqrt(randf())
	var around: float = randf() * TAU
	return (axis * cos(off) + (side * cos(around) + up * sin(around)) * sin(off)).normalized()


## A painted arc to `end`, split off a point on the trunk pointing nearest it,
## so the spray fans out from the trunks rather than from the hand.
func _add_arc(arcs: Array[Arcs.Arc], end: Vector3, weight: float) -> void:
	var start: Vector3 = Vector3.ZERO
	var best: float = -2.0
	for trunk in _trunk_arcs:
		var n: int = trunk.points.size()
		var facing: float = trunk.points[n - 1].normalized().dot(end.normalized())
		if facing > best:
			best = facing
			start = trunk.points[clampi(int(n * randf_range(0.45, 1.0)), 0, n - 1)]
	# A target close to the hand: split off near the hand instead.
	if start.length() >= end.length() * 0.8:
		start = end * randf_range(0.1, 0.3)
	var reach: float = start.distance_to(end)
	var arc := Arcs.Arc.new(Arcs.channel(start, end, 2, roughness), reach * width_per_metre)
	arc.weight = weight
	arc.frame = randi()
	arc.reveal_from = start.length() / _length
	arc.reveal_to = end.length() / _length
	# Fade in where it leaves the trunk, so it reads as a split, not a knot.
	arc.root_fade = 0.12
	arcs.append(arc)


## Sizes and aims the haze to the cone being played.
func _shape_haze() -> void:
	var mesh := CylinderMesh.new()
	mesh.height = _length
	mesh.top_radius = orb_radius * 0.5
	mesh.bottom_radius = tan(_half_angle) * _length
	mesh.radial_segments = 32
	mesh.rings = 8
	mesh.cap_top = false
	mesh.cap_bottom = false
	_haze.mesh = mesh
	_haze_material.set_shader_parameter("height", _length)
	var axis: Vector3 = (global_basis.inverse() * _direction).normalized()
	# The mesh's +Y (its narrow top) points back at the hand.
	var y: Vector3 = -axis
	var x: Vector3 = y.cross(Vector3.UP)
	if x.length_squared() < 1e-4:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	_haze.transform = Transform3D(Basis(x, y, x.cross(y)), axis * _length * 0.5)

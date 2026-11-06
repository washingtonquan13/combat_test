extends Node3D
## A ball of lightning at this node's position: a churning plasma core
## (ball_lightning_core.gdshader), short arcs crawling over its surface,
## and now and then an arc that jumps from the ball to the ground or to a
## nearby point. One flickering light, which flares on each jump.
##
## Move the node to move the ball. It lives `life_seconds` (0: until
## dissipate() is called), then shrinks away and frees itself.
## Visual only: what it touches or damages is the ability's business.

const Arcs := preload("res://scenes/vfx/lightning/lightning_arcs.gd")
const CORE_SHADER: Shader = preload("res://scenes/vfx/lightning/ball_lightning_core.gdshader")

@export var radius: float = 0.4
@export var life_seconds: float = 0.0
@export var grow_seconds: float = 0.25
@export var fade_seconds: float = 0.3
## Arcs crawling over the surface at once.
@export var surface_arcs: int = 4
@export var reroll_seconds: float = 0.06
## Chance, per reroll, that an arc jumps out of the ball.
@export var jump_chance: float = 0.12
## Furthest a jump can reach.
@export var jump_range: float = 3.0
@export var light_energy: float = 2.0
@export var light_range: float = 6.0
@export var light_color: Color = Color(0.65, 0.7, 1.0)

## World points jumps may also strike, besides the ground below.
var targets: PackedVector3Array = PackedVector3Array()

var _core: MeshInstance3D
var _core_material: ShaderMaterial
var _arcs: Arcs
var _light: OmniLight3D
var _age: float = 0.0
var _since_reroll: float = 0.0
var _since_jump: float = 10.0
var _dying_at: float = -1.0


## A plasma core: a unit sphere wearing ball_lightning_core.gdshader.
## Scale it to size; drive the material's "time" and "strength".
## The electric cone uses one at the hand.
static func make_core() -> MeshInstance3D:
	var material := ShaderMaterial.new()
	material.shader = CORE_SHADER
	var noise := NoiseTexture3D.new()
	noise.width = 64
	noise.height = 64
	noise.depth = 64
	noise.seamless = true
	var fast := FastNoiseLite.new()
	fast.frequency = 0.04
	fast.fractal_octaves = 2
	noise.noise = fast
	material.set_shader_parameter("noise", noise)
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	var core := MeshInstance3D.new()
	core.mesh = sphere
	core.material_override = material
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return core


func _ready() -> void:
	_core = make_core()
	_core_material = _core.material_override
	add_child(_core)
	_arcs = Arcs.new()
	add_child(_arcs)
	_light = OmniLight3D.new()
	_light.light_color = light_color
	_light.omni_range = light_range
	_light.shadow_enabled = true
	add_child(_light)
	if life_seconds > 0.0:
		_dying_at = life_seconds
	_reroll()
	_process(0.0)


## Starts the ball shrinking away; it frees itself when gone.
func dissipate() -> void:
	if _dying_at < 0.0 or _dying_at > _age:
		_dying_at = _age


func _process(delta: float) -> void:
	_age += delta
	_since_reroll += delta
	_since_jump += delta
	var strength: float = smoothstep(0.0, grow_seconds, _age)
	if _dying_at >= 0.0:
		var gone: float = (_age - _dying_at) / fade_seconds
		if gone >= 1.0:
			queue_free()
			return
		strength *= 1.0 - clampf(gone, 0.0, 1.0)
	if _since_reroll >= reroll_seconds:
		_reroll()
	# The ball breathes and shivers; a jump makes it flare.
	var flare: float = exp(-_since_jump / 0.05)
	var wobble: float = 1.0 + 0.06 * sin(_age * 9.0) + 0.04 * randf_range(-1.0, 1.0)
	_core.scale = Vector3.ONE * radius * wobble * lerpf(0.3, 1.0, strength)
	_core_material.set_shader_parameter("time", _age)
	_core_material.set_shader_parameter("strength", strength * (randf_range(0.85, 1.05) + flare))
	var crackle: float = 0.6 + 0.4 * exp(-_since_reroll / 0.025)
	_arcs.set_brightness(0.8 * strength * crackle, (1.2 + 3.0 * flare) * strength)
	_light.light_energy = light_energy * strength * (randf_range(0.7, 1.0) + 3.0 * flare)


## New surface arcs, and maybe a jump.
func _reroll() -> void:
	_since_reroll = 0.0
	var arcs: Array[Arcs.Arc] = []
	for i in surface_arcs:
		arcs.append(_surface_arc())
	if randf() < jump_chance:
		var jump: Arcs.Arc = _jump_arc()
		if jump != null:
			arcs.append(jump)
			_since_jump = 0.0
	# A jump stays drawn until the next reroll, which is all it needs.
	_arcs.show_arcs(arcs)


## An arc from one point on the ball to another not far off, hugging the
## surface a little outside it.
func _surface_arc() -> Arcs.Arc:
	var a: Vector3 = _random_unit()
	var b: Vector3 = (a + _random_unit() * randf_range(1.0, 1.6)).normalized()
	var points: PackedVector3Array = Arcs.channel(a * radius, b * radius, 4, 0.28)
	var n: int = points.size()
	for i in n:
		var t: float = float(i) / float(n - 1)
		var lift: float = 1.0 + 0.25 * sin(t * PI)
		points[i] = points[i].normalized() * radius * lift
	var arc := Arcs.Arc.new(points, 0.12)
	arc.weight = randf_range(0.4, 1.0)
	arc.tip_fade = true
	return arc


## An arc from the ball's surface to the ground below or a target in
## reach, or null if nothing is in reach.
func _jump_arc() -> Arcs.Arc:
	var ends: PackedVector3Array = PackedVector3Array()
	for target in targets:
		if target.distance_to(global_position) <= jump_range:
			ends.append(target)
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var down: Vector3 = Vector3(randf_range(-0.6, 0.6), -1.0, randf_range(-0.6, 0.6)).normalized()
	var query := PhysicsRayQueryParameters3D.create(global_position, global_position + down * jump_range)
	var hit: Dictionary = space.intersect_ray(query)
	if not hit.is_empty():
		ends.append(hit.position)
	if ends.is_empty():
		return null
	var end: Vector3 = global_transform.affine_inverse() * ends[randi() % ends.size()]
	var start: Vector3 = end.normalized() * radius
	var arc := Arcs.Arc.new(Arcs.channel(start, end, 5, 0.22), 0.12)
	# Drawn with the branches' brightness, so it can flare on its own.
	arc.branch = true
	return arc


static func _random_unit() -> Vector3:
	return Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0)).normalized()

extends Node3D
## A cone of frost blasted from this node's position, for a cone attack
## like ConeTargeting's (pass its length and half_angle()). The ice
## counterpart of lightning_cone.gd.
##
##  - a cold mist rolling out from the hand, filling the cone
##    (frost_mist.gdshader, raymarched like the electric cone's body);
##  - a spray of glittering frost blown along it;
##  - ice crystals bursting out of whatever the cone hits (floor, walls,
##    units), a wave of them rushing outward from the hand. Each hit
##    grows a small cluster, angled away from the surface and leaning
##    with the blast, bigger the farther out it is;
##  - hoarfrost painted over the ground under the cone (a decal);
##  - after a beat the crystals shatter, and shards fall; the hoarfrost
##    thaws away after.
## One cold light. Plays once and frees itself.
##
## Visual only: what is hit, and the damage, is the ability's business.
## Crystals grow on physics bodies, so pass the caster in `exclude`.

const Crystals := preload("res://scenes/vfx/ice/ice_crystals.gd")
const MIST_SHADER: Shader = preload("res://scenes/vfx/ice/frost_mist.gdshader")

## How long the cone sprays.
@export var hold_seconds: float = 0.6
## When the crystals shatter, from the start, and how long that takes.
@export var shatter_at: float = 1.6
@export var shatter_seconds: float = 0.35
## How long the mist takes to clear after the spray stops.
@export var mist_fade_seconds: float = 0.6
## How long the hoarfrost takes to thaw once the crystals shatter.
@export var thaw_seconds: float = 1.2
## How fast the wave of crystals rushes out, metres a second.
@export var wave_speed: float = 18.0
## Rays cast into the cone to find where crystals grow.
@export var rays: int = 46
## Points inside the cone whose ground below freezes over, so frost
## carpets the floor under the blast and not only where a ray lands.
@export var ground_samples: int = 36
## Extra rays at each caught unit.
@export var rays_per_target: int = 2
## Crystal length near the hand and at the cone's end.
@export var crystal_near: float = 0.25
@export var crystal_far: float = 0.75
@export var mist_strength: float = 0.5
@export var light_energy: float = 2.5
@export var light_color: Color = Color(0.55, 0.8, 1.0)
## Physics bodies the crystals do not grow on (the caster).
var exclude: Array[RID] = []

var _crystals: Crystals
var _mist: MeshInstance3D
var _mist_material: ShaderMaterial
var _spray: CPUParticles3D
var _shards: CPUParticles3D
var _light: OmniLight3D
var _frost: Decal
var _direction: Vector3 = Vector3.FORWARD
var _length: float = 9.0
var _half_angle: float = 0.45
var _targets: PackedVector3Array = PackedVector3Array()
var _age: float = 0.0
var _shattered: bool = false
var _playing: bool = false


func _ready() -> void:
	_crystals = Crystals.new()
	# Crystals stay where they grew, in world space.
	_crystals.top_level = true
	add_child(_crystals)
	_crystals.global_transform = Transform3D.IDENTITY
	_mist_material = ShaderMaterial.new()
	_mist_material.shader = MIST_SHADER
	var noise := NoiseTexture3D.new()
	noise.width = 64
	noise.height = 64
	noise.depth = 64
	noise.seamless = true
	var fast := FastNoiseLite.new()
	fast.frequency = 0.05
	fast.fractal_octaves = 3
	noise.noise = fast
	_mist_material.set_shader_parameter("noise", noise)
	_mist = MeshInstance3D.new()
	# A unit box; the shader stretches it around the cone.
	_mist.mesh = BoxMesh.new()
	_mist.material_override = _mist_material
	_mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mist)
	_spray = _make_spray()
	add_child(_spray)
	_shards = _make_shards()
	add_child(_shards)
	_frost = Decal.new()
	_frost.texture_albedo = _frost_texture()
	_frost.modulate = Color(0.85, 0.94, 1.0, 0.0)
	_frost.normal_fade = 0.4
	_frost.upper_fade = 0.2
	_frost.lower_fade = 0.2
	add_child(_frost)
	_light = OmniLight3D.new()
	_light.light_color = light_color
	_light.light_energy = 0.0
	add_child(_light)
	_mist.visible = _playing
	if _playing:
		_start()
	set_process(_playing)


## Starts the blast. `direction` is the cone's axis in world space,
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
	_mist.visible = true
	_shape_mist()
	_grow_crystals()
	var axis: Vector3 = (global_basis.inverse() * _direction).normalized()
	_spray.direction = axis
	_spray.spread = rad_to_deg(_half_angle) * 0.8
	_spray.emitting = true
	_shape_frost()
	_light.position = axis * _length * 0.3
	_light.omni_range = _length
	_process(0.0)


func _process(delta: float) -> void:
	if not _playing:
		return
	_age += delta
	if _age >= shatter_at + maxf(shatter_seconds + _shards.lifetime, thaw_seconds):
		queue_free()
		return
	if _age >= hold_seconds:
		_spray.emitting = false
	var mist_life: float = hold_seconds + mist_fade_seconds
	var mist: float = smoothstep(0.0, 0.08, _age) * (1.0 - smoothstep(hold_seconds, mist_life, _age))
	_mist.visible = mist > 0.0
	_mist_material.set_shader_parameter("time", _age)
	_mist_material.set_shader_parameter("reveal", clampf(_age / 0.25, 0.0, 1.0) * 1.2)
	_mist_material.set_shader_parameter("strength", mist_strength * mist)
	_light.light_energy = light_energy * (1.0 - smoothstep(hold_seconds * 0.5, shatter_at, _age)) * randf_range(0.9, 1.0)
	var wave: float = _length / wave_speed
	_frost.modulate.a = 0.75 * smoothstep(0.05, 0.05 + wave, _age) * (1.0 - smoothstep(shatter_at, shatter_at + thaw_seconds, _age))
	_crystals.set_time(_age)
	_crystals.set_shatter(clampf((_age - shatter_at) / shatter_seconds, 0.0, 1.0))
	if not _shattered and _age >= shatter_at:
		_shattered = true
		if not _crystals.centres.is_empty():
			var local := PackedVector3Array()
			for c in _crystals.centres:
				local.append(to_local(c))
			_shards.emission_points = local
			_shards.amount = clampi(local.size() * 5, 8, 400)
			_shards.restart()
			_shards.emitting = true


## Casts rays into the cone and grows a cluster of crystals where each hits.
func _grow_crystals() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = global_position
	var side: Vector3 = _direction.cross(Vector3.UP)
	if side.length_squared() < 1e-4:
		side = _direction.cross(Vector3.RIGHT)
	side = side.normalized()
	var up: Vector3 = side.cross(_direction).normalized()
	var aims: Array[Vector3] = []
	for i in rays:
		aims.append(_cone_direction(side, up))
	for target in _targets:
		for i in rays_per_target:
			aims.append((target + Vector3(randfn(0.0, 0.2), randfn(0.0, 0.35), randfn(0.0, 0.2)) - from).normalized())
	for aim in aims:
		var query := PhysicsRayQueryParameters3D.create(from, from + aim * _length)
		query.exclude = exclude
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			continue
		_cluster(hit.position, hit.normal, aim, from.distance_to(hit.position))
	for i in ground_samples:
		var point: Vector3 = from + _cone_direction(side, up) * _length * sqrt(randf_range(0.04, 1.0))
		var reach := PhysicsRayQueryParameters3D.create(from, point)
		reach.exclude = exclude
		# Behind a wall: the blast never got there.
		if not space.intersect_ray(reach).is_empty():
			continue
		var down := PhysicsRayQueryParameters3D.create(point, point + Vector3.DOWN * 3.0)
		down.exclude = exclude
		var ground: Dictionary = space.intersect_ray(down)
		if ground.is_empty():
			continue
		var travel: Vector3 = (ground.position - from).normalized()
		_cluster(ground.position, ground.normal, travel, from.distance_to(ground.position))
	_crystals.build()


## A few crystals frozen onto a surface at `at`, struck by the blast
## travelling along `aim`, `distance` from the hand.
func _cluster(at: Vector3, normal: Vector3, aim: Vector3, distance: float) -> void:
	var along: float = clampf(distance / _length, 0.0, 1.0)
	# Flat on the surface, for spreading the cluster's roots.
	var tangent: Vector3 = normal.cross(aim)
	if tangent.length_squared() < 1e-4:
		tangent = normal.cross(Vector3.RIGHT if absf(normal.x) < 0.9 else Vector3.UP)
	tangent = tangent.normalized()
	var bitangent: Vector3 = normal.cross(tangent)
	var start: float = 0.05 + distance / wave_speed
	for i in randi_range(2, 5):
		var root: Vector3 = at + (tangent * randfn(0.0, 1.0) + bitangent * randfn(0.0, 1.0)) * 0.12 * (0.6 + along)
		# Out of the surface, leaning with the blast, a little wild.
		var axis: Vector3 = (normal + aim * 0.4 + Vector3(randfn(0.0, 0.3), randfn(0.0, 0.3), randfn(0.0, 0.3))).normalized()
		if axis.dot(normal) < 0.5:
			axis = (axis + normal).normalized()
		var length: float = lerpf(crystal_near, crystal_far, along) * randf_range(0.55, 1.2)
		_crystals.add_crystal(root, axis, length, length * randf_range(0.18, 0.28), start + randf() * 0.06)


## A random direction inside the cone, spread evenly over its cross section.
func _cone_direction(side: Vector3, up: Vector3) -> Vector3:
	var off: float = _half_angle * sqrt(randf())
	var around: float = randf() * TAU
	return (_direction * cos(off) + (side * cos(around) + up * sin(around)) * sin(off)).normalized()


## Sizes and aims the mist to the cone being played.
func _shape_mist() -> void:
	var r: float = tan(_half_angle) * _length * 1.02
	# The shader moves the box's corners, so culling needs the real size.
	_mist.custom_aabb = AABB(Vector3(-r, -r, -_length), Vector3(2.0 * r, 2.0 * r, _length))
	_mist_material.set_shader_parameter("cone_length", _length)
	_mist_material.set_shader_parameter("half_angle", _half_angle)
	_mist_material.set_shader_parameter("noise_offset", Vector3(randf(), randf(), randf()))
	var axis: Vector3 = (global_basis.inverse() * _direction).normalized()
	var up: Vector3 = Vector3.UP if absf(axis.y) < 0.99 else Vector3.RIGHT
	# The mist's -Z runs along the cone, its origin at the hand.
	_mist.transform = Transform3D(Basis.looking_at(axis, up), Vector3.ZERO)


## Lays the hoarfrost decal flat under the cone, its apex at the hand.
## It projects straight down onto whatever is below, a few metres deep.
func _shape_frost() -> void:
	var flat := Vector3(_direction.x, 0.0, _direction.z)
	if flat.length_squared() < 1e-4:
		_frost.visible = false
		return
	flat = flat.normalized()
	var reach: float = _length * cos(atan(_direction.y / Vector2(_direction.x, _direction.z).length()))
	var width: float = 2.0 * tan(_half_angle) * reach * 1.1
	_frost.size = Vector3(width, 6.0, reach)
	_frost.top_level = true
	# The decal's +Z is the texture's bottom edge, where the apex is drawn.
	var basis := Basis.looking_at(flat, Vector3.UP)
	_frost.global_transform = Transform3D(basis, global_position + flat * reach * 0.5 + Vector3.DOWN * 1.0)


## The hoarfrost's picture: a wedge of patchy frost, its apex at the
## bottom edge, feathery and broken at its sides and far end.
func _frost_texture() -> ImageTexture:
	var size: int = 128
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = randi()
	noise.frequency = 0.06
	noise.fractal_octaves = 4
	for y in size:
		var along: float = 1.0 - (y + 0.5) / size
		for x in size:
			var across: float = absf((x + 0.5) / size * 2.0 - 1.0)
			var n: float = noise.get_noise_2d(x, y) * 0.5 + 0.5
			var edge: float = along * 0.95 - across + (n - 0.5) * 0.35
			var a: float = smoothstep(0.0, 0.12, edge) * smoothstep(1.0, 0.75, along + (n - 0.5) * 0.3)
			a *= smoothstep(0.25, 0.65, n) * 0.7 + 0.3
			image.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## Glittering frost blown along the cone.
func _make_spray() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.amount = 400
	p.lifetime = 0.7
	p.local_coords = false
	p.initial_velocity_min = 7.0
	p.initial_velocity_max = 14.0
	p.damping_min = 6.0
	p.damping_max = 10.0
	p.gravity = Vector3(0.0, -0.6, 0.0)
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.2
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.3))
	grow.add_point(Vector2(0.3, 1.0))
	grow.add_point(Vector2(1.0, 1.6))
	p.scale_amount_curve = grow
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.95, 0.98, 1.0, 1.0))
	ramp.set_color(1, Color(0.5, 0.75, 1.0, 0.0))
	p.color_ramp = ramp
	var quad := QuadMesh.new()
	quad.size = Vector2(0.08, 0.08)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _soft_dot()
	material.albedo_color = Color(1.4, 1.6, 2.0)
	quad.material = material
	p.mesh = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


## Shards of ice tumbling down when the crystals shatter.
func _make_shards() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 1.0
	p.lifetime = 0.9
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINTS
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 4.0
	p.gravity = Vector3(0.0, -12.0, 0.0)
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.angular_velocity_min = -400.0
	p.angular_velocity_max = 400.0
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.3
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.85, 0.95, 1.0, 1.0))
	ramp.add_point(0.7, Color(0.7, 0.88, 1.0, 0.9))
	ramp.set_color(ramp.get_point_count() - 1, Color(0.6, 0.8, 1.0, 0.0))
	p.color_ramp = ramp
	var shard := PrismMesh.new()
	shard.size = Vector3(0.05, 0.1, 0.03)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.1
	material.emission_enabled = true
	material.emission = Color(0.35, 0.65, 1.0)
	material.emission_energy_multiplier = 0.8
	shard.material = material
	p.mesh = shard
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


func _soft_dot() -> Texture2D:
	var dot := GradientTexture2D.new()
	dot.width = 32
	dot.height = 32
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(0.5, 0.0)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.add_point(0.25, Color(1, 1, 1, 0.6))
	g.set_color(g.get_point_count() - 1, Color(1, 1, 1, 0))
	dot.gradient = g
	return dot

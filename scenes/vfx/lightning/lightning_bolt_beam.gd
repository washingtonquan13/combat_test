extends Node3D
## Visual for Lightning Bolt (BeamStep, abilities/lightning_bolt.tres), in
## the manner of a Witch Bolt tether rather than a sky strike:
##  1. The launch: as the bolt leaves the hand a backblast goes off just
##     in front of it, like Fire Bolt's but electric and bigger: white and
##     blue flares, a jet of sparks along the shot, a spray blown back past
##     the hand, forked arcs spitting off it and a ring punching out.
##     Meanwhile a thick leader jerks out to the target over reach time.
##  2. The connect: the target flashes and sprays sparks.
##  3. The tether: three thin strands braided around the line hold for a
##     moment, writhing and re-crackling every few frames, then fade.
## The strands keep close to the straight line (a slow twist plus a little
## jag), so the bolt reads as aimed, not wild. The arcs are drawn by
## lightning_arcs.gd, in world space.

const Arcs := preload("res://scenes/vfx/lightning/lightning_arcs.gd")

@export_range(3, 9) var generations: int = 6
## Jag of each strand, as a fraction of its segments' length.
@export var roughness: float = 0.07
@export var strands: int = 3
## How far the braid swings off the line at its middle, metres.
@export var braid_radius: float = 0.14
## Full twists of the braid along the bolt.
@export var braid_turns: float = 2.5
## The leader's half width; the main strand eases from this to
## main_half_width once the tether holds.
@export var leader_half_width: float = 0.32
@export var main_half_width: float = 0.16
@export var strand_half_width: float = 0.09
## How long the tether holds after connecting, and fades after that.
@export var hold_time: float = 0.55
@export var fade_time: float = 0.25
## Seconds between re-crackles while held.
@export var crackle_every: float = 0.045
## Main channel brightness at the connect flash.
@export var stroke_gain: float = 4.0
## Brightness while held, before flicker.
@export var hold_gain: float = 1.6
@export var light_energy: float = 6.0
@export var light_range: float = 8.0
@export var light_color: Color = Color(0.75, 0.82, 1.0)
@export var hot_color: Color = Color(0.92, 0.95, 1.0)
## How far ahead of the hand the backblast goes off, metres.
@export var launch_gap: float = 0.35

var _bolt: Arcs
var _hand_light: OmniLight3D
var _hit_light: OmniLight3D
var _from: Vector3
var _to: Vector3
var _reach: float = 0.1
var _leader_steps: PackedVector2Array  # (seconds, reveal)
var _age: float = 0.0
var _connected: bool = false
var _next_crackle: float = 0.0
var _twist: float = 0.0
var _firing: bool = false
var _blast_point: Vector3


## BeamStep's entry point: from the hand to the target, arriving after
## reach_time.
func fire(from: Vector3, to: Vector3, reach_time: float, _caster: Unit, _launch_from: CharacterModel.Anchor) -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_from = from
	_to = to
	_reach = maxf(reach_time, 0.02)
	_bolt = Arcs.new()
	add_child(_bolt)
	_hand_light = _light_at(from)
	_hit_light = _light_at(to)
	_plan_leader()
	_twist = randf() * TAU
	var leader: Array[Arcs.Arc] = _braid(1)
	leader[0].half_width = leader_half_width
	_blast_point = from + (to - from).normalized() * launch_gap
	_bolt.show_arcs(leader + _spits(_blast_point))
	_launch(_blast_point)
	_firing = true
	_process(0.0)


func _light_at(at: Vector3) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.omni_range = light_range
	light.light_color = light_color
	light.light_energy = 0.0
	add_child(light)
	light.global_position = at
	return light


## The leader jerks out in irregular steps.
func _plan_leader() -> void:
	_leader_steps = PackedVector2Array()
	var count: int = randi_range(5, 8)
	var weights: PackedFloat32Array = []
	var total: float = 0.0
	for i in count:
		var w: float = randf_range(0.4, 1.6)
		weights.append(w)
		total += w
	var reached: float = 0.0
	for i in count:
		reached += weights[i] / total
		_leader_steps.append(Vector2(_reach * float(i) / float(count), reached))


## `count` strands from hand to target: each a gentle helix around the
## line (strands evenly spaced round it), plus a small jag, pinched to
## nothing at both ends. The first strand is the main one.
func _braid(count: int) -> Array[Arcs.Arc]:
	var along: Vector3 = (_to - _from).normalized()
	var side: Vector3 = along.cross(Vector3.UP)
	if side.length_squared() < 1e-4:
		side = along.cross(Vector3.RIGHT)
	side = side.normalized()
	var up: Vector3 = side.cross(along).normalized()
	var out: Array[Arcs.Arc] = []
	for k in count:
		var pts: PackedVector3Array = Arcs.channel(_from, _to, generations, roughness)
		var n: int = pts.size()
		var phase: float = _twist + TAU * float(k) / float(maxi(count, 1))
		var radius: float = braid_radius * (0.5 if k == 0 else 1.0)
		for i in n:
			var t: float = float(i) / float(n - 1)
			var angle: float = phase + t * braid_turns * TAU
			pts[i] += (side * cos(angle) + up * sin(angle)) * radius * sin(PI * t)
		var width: float = strand_half_width
		if k == 0:
			width = lerpf(main_half_width, leader_half_width, exp(-maxf(_age - _reach, 0.0) / 0.12))
		var arc := Arcs.Arc.new(_held_up(pts), width)
		arc.weight = 1.0 if k == 0 else 0.6
		arc.reveal_from = 0.0
		arc.reveal_to = 1.0
		out.append(arc)
	return out


## Nothing dips far below the straight line from hand to target: a bolt
## fired at hand height would otherwise go under the floor and show a gap.
func _held_up(points: PackedVector3Array) -> PackedVector3Array:
	var line: Vector3 = _to - _from
	var length_sq: float = maxf(line.length_squared(), 1e-5)
	for i in points.size():
		var t: float = clampf((points[i] - _from).dot(line) / length_sq, 0.0, 1.0)
		var on_line: float = lerpf(_from.y, _to.y, t)
		if points[i].y < on_line:
			points[i].y = on_line + (points[i].y - on_line) * 0.15
	return points


func _process(delta: float) -> void:
	if not _firing:
		return
	_age += delta
	if _age >= _reach + hold_time + fade_time:
		queue_free()
		return
	if _age < _reach:
		var reveal: float = 0.0
		for step in _leader_steps:
			if _age >= step.x:
				reveal = step.y
		_bolt.set_reveal(reveal, 2.5)
		_bolt.set_brightness(2.2 * randf_range(0.85, 1.15), 3.5 * exp(-_age / 0.08))
		_hand_light.light_energy = randf_range(0.7, 1.2) * light_energy * 0.6
		return
	if not _connected:
		_connected = true
		_connect()
	var held: float = _age - _reach
	if held >= _next_crackle:
		_next_crackle = held + crackle_every * randf_range(0.7, 1.3)
		_twist += randf_range(0.6, 1.4)
		var fade_now: float = 1.0 - clampf((held - hold_time) / fade_time, 0.0, 1.0)
		_bolt.show_arcs(_braid(strands) + _hand_crackle())
		_hand_glow(fade_now)
	var fade: float = 1.0 - clampf((held - hold_time) / fade_time, 0.0, 1.0)
	var flicker: float = randf_range(0.75, 1.25)
	var flash: float = exp(-held / 0.05)
	_bolt.set_reveal(1.0, 0.0)
	_bolt.set_brightness((hold_gain * flicker + stroke_gain * flash) * fade, 1.8 * flicker * fade)
	_hand_light.light_energy = light_energy * (0.4 * flicker + flash) * fade
	_hit_light.light_energy = light_energy * (0.6 * flicker + flash) * fade


## Forked arcs spitting off the blast, mostly back and out past the hand,
## drawn as branches so they flare with the launch and die with it.
func _spits(at: Vector3) -> Array[Arcs.Arc]:
	var forward: Vector3 = (_to - _from).normalized()
	var out: Array[Arcs.Arc] = []
	for i in randi_range(6, 8):
		var dir := Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0)).normalized()
		dir = (dir - forward * 0.9).normalized()
		var arc := Arcs.Arc.new(Arcs.channel(at, at + dir * randf_range(0.35, 0.9), 4, 0.3), randf_range(0.04, 0.07))
		arc.branch = true
		arc.tip_fade = true
		out.append(arc)
	return out


## While the tether holds, the hand keeps crackling: one or two short
## arcs off the blast point, redrawn with every re-crackle.
func _hand_crackle() -> Array[Arcs.Arc]:
	var forward: Vector3 = (_to - _from).normalized()
	var out: Array[Arcs.Arc] = []
	for i in randi_range(1, 2):
		var dir := Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0)).normalized()
		dir = (dir - forward * 0.6).normalized()
		var arc := Arcs.Arc.new(Arcs.channel(_blast_point, _blast_point + dir * randf_range(0.2, 0.45), 3, 0.3), randf_range(0.03, 0.05))
		arc.branch = true
		arc.tip_fade = true
		out.append(arc)
	return out


## A small glow pulsing at the hand with each re-crackle, now and then
## spitting a few sparks; shrinks as the tether fades.
func _hand_glow(fade: float) -> void:
	if fade <= 0.05:
		return
	VfxBits.flash(_blast_point, light_color, 0.55 * fade * randf_range(0.8, 1.2), 2.2, 0.07)
	if randf() < 0.3:
		VfxBits.burst(_blast_point, _spark_colors(), 0.03, 4.0, 4, 0.2, Vector2(1.5, 3.5), -3.0, 6.0)


## The backblast as the bolt leaves the hand: a white-hot flare inside a
## wide blue one, a hard flash of light round the caster, a jet of sparks
## along the shot, a heavy spray blown back past the hand, and two rings
## punching out across the line.
func _launch(at: Vector3) -> void:
	var forward: Vector3 = (_to - _from).normalized()
	VfxBits.flash(at, hot_color, 1.1, 5.0, 0.12)
	VfxBits.flash(at, light_color, 2.1, 2.8, 0.28)
	VfxBits.light_flash(at, light_color, 7.0, 6.0, 0.28)
	var jet := VfxBits.burst(at, _spark_colors(), 0.08, 4.0, 24, 0.18, Vector2(5.0, 10.0), 0.0, 9.0)
	_aim(jet, forward, 12.0)
	var back := VfxBits.burst(at, _spark_colors(), 0.04, 4.5, 50, 0.4, Vector2(3.0, 6.5), -3.0, 6.0)
	_aim(back, -forward, 60.0)
	var glow := VfxBits.burst(at, PackedColorArray([Color(1.0, 1.1, 1.4, 0.9), Color(light_color, 0.5), Color(light_color, 0.0)]),
		0.35, 2.0, 8, 0.28, Vector2(1.0, 2.5), 0.0, 5.0)
	_aim(glow, -forward, 85.0)
	_shock_ring(at, forward, 0.7, 0.22)
	_shock_ring(at + forward * 0.2, forward, 0.45, 0.15)


## A thin ring across the line of the shot, punching out and fading.
func _shock_ring(at: Vector3, forward: Vector3, size: float, time: float) -> void:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.9
	torus.outer_radius = 1.0
	torus.rings = 32
	torus.ring_segments = 6
	ring.mesh = torus
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(light_color, 1.0) * 3.0
	ring.material_override = material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	WorldManager.spawn_parent().add_child(ring)
	ring.global_position = at
	# The torus lies in its XZ plane: turn its axis (Y) along the shot.
	ring.global_basis = Basis(Quaternion(Vector3.UP, forward))
	ring.scale = Vector3.ONE * 0.08
	var tween := ring.create_tween().set_parallel()
	tween.tween_property(ring, "scale", Vector3(size, 0.2, size), time).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(material, "albedo_color", Color(light_color, 0.0), time).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(ring.queue_free)


func _aim(emitter: GPUParticles3D, direction: Vector3, spread: float) -> void:
	var process := emitter.process_material as ParticleProcessMaterial
	process.direction = direction
	process.spread = spread


## The connect: a flash and spark spray at the target.
func _connect() -> void:
	VfxBits.flash(_to, light_color, 0.9, 3.0, 0.2)
	VfxBits.burst(_to, _spark_colors(), 0.04, 4.0, 30, 0.35, Vector2(3.0, 7.0), -4.0, 6.0)


func _spark_colors() -> PackedColorArray:
	return PackedColorArray([Color(1.6, 1.7, 2.0, 1.0), light_color, Color(light_color, 0.0)])

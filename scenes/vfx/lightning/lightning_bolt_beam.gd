extends Node3D
## Visual for Lightning Bolt (BeamStep, abilities/lightning_bolt.tres), in
## the manner of a Witch Bolt tether rather than a sky strike:
##  1. The leader: one bolt jerks out from the hand over the beam's reach
##     time.
##  2. The connect: a backblast flares just in front of the hand, sparks
##     spray back past it, and the target flashes.
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
	_bolt.show_arcs(_braid(1))
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
		var arc := Arcs.Arc.new(_held_up(pts), main_half_width if k == 0 else strand_half_width)
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
		_bolt.set_reveal(reveal, 2.0)
		_bolt.set_brightness(0.6, 0.0)
		_hand_light.light_energy = randf_range(0.4, 1.0) * light_energy * 0.2
		return
	if not _connected:
		_connected = true
		_connect()
	var held: float = _age - _reach
	if held >= _next_crackle:
		_next_crackle = held + crackle_every * randf_range(0.7, 1.3)
		_twist += randf_range(0.6, 1.4)
		_bolt.show_arcs(_braid(strands))
	var fade: float = 1.0 - clampf((held - hold_time) / fade_time, 0.0, 1.0)
	var flicker: float = randf_range(0.75, 1.25)
	var flash: float = exp(-held / 0.05)
	_bolt.set_reveal(1.0, 0.0)
	_bolt.set_brightness((hold_gain * flicker + stroke_gain * flash) * fade, 0.0)
	_hand_light.light_energy = light_energy * (0.4 * flicker + flash) * fade
	_hit_light.light_energy = light_energy * (0.6 * flicker + flash) * fade


## The connect: a backblast just in front of the hand with sparks thrown
## back past it, and a flash and spark spray at the target.
func _connect() -> void:
	var along: Vector3 = (_to - _from).normalized()
	var blast: Vector3 = _from + along * 0.3
	VfxBits.flash(blast, light_color, 0.7, 3.0, 0.18)
	var back := VfxBits.burst(blast, _spark_colors(), 0.03, 4.0, 22, 0.3, Vector2(2.5, 5.0), -2.0, 7.0)
	var process := back.process_material as ParticleProcessMaterial
	process.direction = -along
	process.spread = 55.0
	VfxBits.flash(_to, light_color, 0.9, 3.0, 0.2)
	VfxBits.burst(_to, _spark_colors(), 0.04, 4.0, 30, 0.35, Vector2(3.0, 7.0), -4.0, 6.0)


func _spark_colors() -> PackedColorArray:
	return PackedColorArray([Color(1.6, 1.7, 2.0, 1.0), light_color, Color(light_color, 0.0)])

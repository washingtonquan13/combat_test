extends Node3D
## Visual for Magic Missile (PathedProjectileStep, abilities/magic_missile.tres):
## three glowing magenta darts flying the one route together, braided
## around it - each swings out sideways and up and back, a third of a
## turn apart from the others - with a ribbon trail behind each. They
## start together at the hand and come back together on the target, so
## they land as the one hit the spell is. On arrival they go out in a
## violet pop of sparks.
##
## Purely a look: the darts are one projectile to the rules (one route,
## one hit, the damage unchanged). Built in code like the other spell
## visuals (see VfxBits).

@export var bolt_color: Color = Color(0.9, 0.35, 1.0)
@export var core_color: Color = Color(1.0, 0.85, 1.0)
@export var dart_count: int = 3
## How far a dart swings out from the route at its widest, in metres.
@export var weave: float = 0.32
## Metres flown per full turn of the braid.
@export var wavelength: float = 3.2
## Metres over which the darts spread out after launch and close in
## before the hit.
@export var gather: float = 1.6
@export var trail_lifetime: float = 0.14

var _darts: Array[Node3D] = []
var _trails: Array[RibbonTrail] = []
var _light: OmniLight3D


func _ready() -> void:
	for i in dart_count:
		var dart := Node3D.new()
		add_child(dart)
		_build_dart(dart)
		_darts.append(dart)
	_light = OmniLight3D.new()
	_light.light_color = bolt_color
	_light.light_energy = 1.2
	_light.omni_range = 2.5
	add_child(_light)


## A bright pinched core, stretched along the flight, in a soft glow,
## trailing a ribbon.
func _build_dart(dart: Node3D) -> void:
	var core := VfxBits.glow(dart, core_color, 0.16, 4.0, 1.2)
	core.name = &"Core"
	var halo := VfxBits.glow(dart, bolt_color, 0.5, 1.6, 2.4)
	halo.name = &"Halo"
	var trail := RibbonTrail.new()
	trail.lifetime = trail_lifetime
	trail.width = 0.1
	trail.color = bolt_color
	trail.energy = 2.5
	dart.add_child(trail)
	_trails.append(trail)


## PathedProjectileStep calls this each frame: t is 0..1 along a route
## of `length` metres.
func set_flight_progress(t: float, length: float) -> void:
	var flown: float = t * length
	var left: float = length - flown
	var spread: float = clamp(min(flown, left) / max(gather, 0.01), 0.0, 1.0)
	spread = spread * spread * (3.0 - 2.0 * spread)
	var turn: float = TAU * flown / max(wavelength, 0.01)
	for i in _darts.size():
		var angle: float = turn + TAU * i / _darts.size()
		_darts[i].position = Vector3(cos(angle) * weave, sin(angle) * weave * 0.7, 0.0) * spread


## The darts go out in a violet pop; their trails age out after them.
func arrive() -> void:
	var at: Vector3 = global_position
	for dart in _darts:
		dart.get_node(^"Core").visible = false
		dart.get_node(^"Halo").visible = false
	for trail in _trails:
		trail.emitting = false
	_light.visible = false
	VfxBits.flash(at, bolt_color, 1.1, 3.0, 0.25)
	VfxBits.light_flash(at, bolt_color, 3.0, 4.0, 0.3)
	VfxBits.burst(at, PackedColorArray([Color(1.6, 1.2, 1.8, 1.0), bolt_color, Color(bolt_color, 0.0)]),
		0.08, 3.0, 28, 0.4, Vector2(2.0, 5.0), -2.0, 6.0)
	await get_tree().create_timer(trail_lifetime + 0.05).timeout

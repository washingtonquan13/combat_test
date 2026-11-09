extends "res://systems/surface_system/water_wall.gd"
## Electrified Wall of Water: the same wave, faced the same way as the
## one the lightning struck, with bolts jumping again and again along the
## crest or from the lip's point down the face under it, flashing a blue
## light with each. Stretches that recede carry no
## more charge; as the wave collapses the strikes die away with it.

const LightningArcs = preload("res://scenes/vfx/lightning/lightning_arcs.gd")

## Bolts started per second along the whole wall.
@export var strikes_per_second: float = 5.0
## Chance a bolt flashes again as it fades.
@export var restrike_chance: float = 0.5
## How long one flash shows.
@export var flash_seconds: float = 0.09
@export var light_energy: float = 3.0
@export var light_color: Color = Color(0.5, 0.7, 1.0)

var _arcs: LightningArcs
var _light: OmniLight3D
var _flash_left: float = 0.0
var _restrikes: int = 0
var _glow: float = 0.0


func _ready() -> void:
	super()
	_arcs = LightningArcs.new()
	# The arcs are built in world space.
	_arcs.top_level = true
	add_child(_arcs)
	_arcs.global_transform = Transform3D.IDENTITY
	_arcs.set_reveal(2.0, 0.0)
	_light = OmniLight3D.new()
	_light.light_color = light_color
	_light.light_energy = 0.0
	_light.omni_range = 5.0
	_light.shadow_enabled = false
	_light.top_level = true
	add_child(_light)


func _physics_process(delta: float) -> void:
	super(delta)
	if _station_t.is_empty():
		return
	_flash_left -= delta
	if _flash_left <= 0.0 and _arcs.mesh:
		if _restrikes > 0:
			_restrikes -= 1
			_strike()
		else:
			_arcs.show_arcs([] as Array[LightningArcs.Arc])
	elif _risen and randf() < strikes_per_second * _strength * delta:
		_restrikes = 0
		while _restrikes < 3 and randf() < restrike_chance:
			_restrikes += 1
		_strike()
	_glow *= exp(-14.0 * delta)
	_light.light_energy = light_energy * _glow * _strength


## A bolt along the crest, or across the hollow, at a stretch
## still standing.
func _strike() -> void:
	var standing: Array[int] = []
	for i in _station_t.size():
		if _station_burn[i] >= 1.0 and _standing(i):
			standing.append(i)
	if standing.is_empty():
		_arcs.show_arcs([] as Array[LightningArcs.Arc])
		return
	var i: int = standing[randi() % standing.size()]
	var a: Vector3
	var b: Vector3
	if randf() < 0.6:
		# Along the crest, a metre or two.
		var j: int = clampi(i + (randi_range(4, 8) * (1 if randf() < 0.5 else -1)), 0, _station_t.size() - 1)
		a = _point(i, _crest, 1.0)
		b = _point(j, clampi(_crest + randi_range(-4, 4), 0, _profile.size() - 1), 1.0)
	else:
		# From the lip's point down the face under it.
		a = _point(i, _tip, 1.0)
		b = _point(i, randi_range(BACK_WALL.x * PROFILE_STEPS, BACK_WALL.y * PROFILE_STEPS), 1.0)
	var arc := LightningArcs.Arc.new(LightningArcs.channel(a, b, 4, 0.35), 0.06)
	arc.reveal_to = 1.0
	_arcs.show_arcs([arc] as Array[LightningArcs.Arc])
	_arcs.set_brightness(1.0, 0.6)
	_flash_left = flash_seconds
	_glow = 1.0
	_light.global_position = a.lerp(b, 0.5)

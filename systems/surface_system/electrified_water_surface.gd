extends DecalSurface
## Electrified Water: the water film, glowing, with charge skittering
## over it (electric_crawl.gd), no crackle painted in the water itself: painted arcs snapping between the
## puddle's cells, low over the water, and a light flickering with them.
## Only cells that have spread in and are not receding carry charge, so
## the arcs gather with the puddle and die back as it goes.

const Crawl := preload("res://scenes/vfx/lightning/electric_crawl.gd")

## How often the charged cells are looked over again, seconds.
const REFRESH_SECONDS: float = 0.1

var _crawl: Crawl
var _since_refresh: float = REFRESH_SECONDS


func _ready() -> void:
	super()
	_crawl = Crawl.new()
	_crawl.hug_floor = true
	# Bolts arching up out of the pool, held long enough to see.
	_crawl.arcs_per_point = 0.08
	_crawl.max_arcs = 10
	_crawl.min_length = 1.0
	_crawl.max_length = 2.6
	_crawl.arc_seconds = Vector2(0.1, 0.3)
	_crawl.floor_bow = 0.45
	_crawl.surge_arcs = 3
	_crawl.surges_per_second = 2.0
	# Placed in world space: the decal's box moves as the puddle redraws.
	_crawl.top_level = true
	add_child(_crawl)


func _process(delta: float) -> void:
	super(delta)
	_since_refresh += delta
	if _since_refresh < REFRESH_SECONDS or _crawl == null:
		return
	_since_refresh = 0.0
	var now: float = _now()
	var charged := PackedVector3Array()
	for key in _live:
		if _dying.has(key) or _arrive.get(key, -INF) > now:
			continue
		charged.append(_live[key].centre())
	_crawl.points = charged
	_crawl.strength = clampf(float(charged.size()) / maxf(1.0, float(_live.size())), 0.0, 1.0)

extends "res://systems/surface_system/fog_cloud.gd"
## Electrified Steam: the steam cloud, tinted and flickering, with charge
## flashing through it (electric_crawl.gd): painted arcs snapping between
## the cloud's cubes, inside it, and a light flickering with them. Cubes
## that recede carry no more charge; as the cloud burns off the arcs die
## away ahead of it.

const Crawl := preload("res://scenes/vfx/lightning/electric_crawl.gd")

var _crawl: Crawl


func _ready() -> void:
	super()
	_crawl = Crawl.new()
	_crawl.arcs_per_point = 0.04
	_crawl.max_arcs = 10
	_crawl.min_length = 0.8
	_crawl.max_length = 2.2
	_crawl.light_energy = 1.6
	# Placed in world space: the cloud billows and drifts, the cubes don't.
	_crawl.top_level = true
	add_child(_crawl)


func show_cubes(cells: Array) -> void:
	super(cells)
	_charge()


func recede_cubes(cells: Array) -> void:
	super(cells)
	_charge()


func dissipate() -> void:
	super()
	if _crawl:
		create_tween().tween_property(_crawl, "strength", 0.0, seconds * 0.4)


## Charge runs between the cubes still shown.
func _charge() -> void:
	var centres := PackedVector3Array()
	for key in _points:
		centres.append(CloudGrid.centre_of(key))
	_crawl.points = centres

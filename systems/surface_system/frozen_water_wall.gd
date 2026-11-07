extends "res://systems/surface_system/water_wall.gd"
## Frozen Wall of Water: the wave the cold caught, standing where it was
## and faced the same way, turning to ice from its feet up. Where the ice
## reaches, the water stops; no spray, no drips.

## How long the ice takes to creep from the feet to the lip.
@export var freeze_seconds: float = 0.8

var _ice: float = 0.0


func _ready() -> void:
	super()
	# Any moment will do for where the water stands still.
	_material.set_shader_parameter("frozen_at", randf_range(0.0, 100.0))


## Already standing: it was the water wave a moment ago.
func show_cubes(cells: Array) -> void:
	super(cells)
	_age = rise_spread + rise_seconds
	if not _station_t.is_empty():
		_update_heights()


func _emit_from_points() -> void:
	pass


func _process(delta: float) -> void:
	super(delta)
	if _ice < 1.0:
		_ice = minf(_ice + delta / freeze_seconds, 1.0)
		_material.set_shader_parameter("ice", _ice)

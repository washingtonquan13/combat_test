class_name DownedTracker
extends VBoxContainer
## Over a Downed unit: Downed's two tracks (DeathRollsBehavior) as three
## green bars toward stable and three red toward death, swapped for the
## stable icon once the unit is stable. Hidden whenever the unit is not
## Downed.
##
## A Control under the unit's Node3D draws on that unit's own world
## viewport, so it is placed each frame through that viewport's camera.

## Defaults to the parent unit.
@export var unit: Unit
## Meters above the unit's origin — low, since a Downed unit is lying
## down.
@export var height: float = 1.2
@export var stable_on: StyleBox
@export var stable_off: StyleBox
@export var death_on: StyleBox
@export var death_off: StyleBox

@onready var _tracks: Control = %Tracks
@onready var _stable_bars: Array[Node] = %StableBars.get_children()
@onready var _death_bars: Array[Node] = %DeathBars.get_children()
@onready var _stable_icon: Control = %StableIcon


func _ready() -> void:
	if unit == null:
		unit = get_parent() as Unit
	visible = false
	set_process(false)
	if unit == null:
		return
	unit.downed_changed.connect(_refresh.unbind(1))
	unit.downed_tally_changed.connect(_refresh.unbind(1))
	unit.status_applied.connect(_refresh.unbind(2))
	unit.status_removed.connect(_refresh.unbind(2))
	unit.died.connect(_refresh.unbind(1))
	# The unit's status manager is set up in its own _ready, after ours.
	_refresh.call_deferred()


func _refresh() -> void:
	visible = unit.is_downed()
	set_process(visible)
	if not visible:
		return
	var stable: bool = unit.is_stable()
	_tracks.visible = not stable
	_stable_icon.visible = stable
	var tally: Dictionary = unit.downed_tally()
	_fill(_stable_bars, tally.get("stable", 0), stable_on, stable_off)
	_fill(_death_bars, tally.get("death", 0), death_on, death_off)
	reset_size()
	_place()


func _fill(bars: Array[Node], count: int, on: StyleBox, off: StyleBox) -> void:
	for i in bars.size():
		(bars[i] as Control).add_theme_stylebox_override("panel", on if i < count else off)


func _process(_delta: float) -> void:
	_place()


func _place() -> void:
	if not is_inside_tree():
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	var point: Vector3 = unit.global_position + Vector3.UP * height
	if camera == null or camera.is_position_behind(point):
		modulate.a = 0.0
		return
	modulate.a = 1.0
	position = (camera.unproject_position(point) - Vector2(size.x * 0.5, size.y)).round()
